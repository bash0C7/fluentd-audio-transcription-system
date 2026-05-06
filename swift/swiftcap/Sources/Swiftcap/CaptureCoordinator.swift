// swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

@available(macOS 26.0, *)
actor CaptureCoordinator {
    let spoolDir: URL
    private var recorders: [String: RotatingRecorder] = [:]
    private var transcribers: [String: TranscriberWrapper] = [:]
    private var sounds: [String: SoundAnalyzerWrapper] = [:]
    private var stateWriter: SpoolWriter
    private let quickWriter: SpoolWriter
    private let finalWriter: SpoolWriter
    private let soundWriter: SpoolWriter
    private var rotateTask: Task<Void, Never>?
    private let micEngine = AVAudioEngine()
    private var screenStream: SCStream?
    private var screenDelegate: ScreenStreamDelegate?
    // SCStream.addStreamOutput retains the output only weakly; without a
    // strong property here the inline-created ScreenAudioOutput would be
    // ARC-released as soon as addStreamOutput returns, and ScreenCaptureKit
    // would log "streamOutput NOT found. Dropping frame" for every buffer.
    private var screenAudioOutput: ScreenAudioOutput?
    private static let targetFormat: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    init(spoolDir: URL) {
        self.spoolDir = spoolDir
        try? FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        self.stateWriter = SpoolWriter(url: spoolDir.appendingPathComponent("state.jsonl"))
        self.quickWriter = SpoolWriter(url: spoolDir.appendingPathComponent("quick.jsonl"))
        self.finalWriter = SpoolWriter(url: spoolDir.appendingPathComponent("final.jsonl"))
        self.soundWriter = SpoolWriter(url: spoolDir.appendingPathComponent("sound.jsonl"))
    }

    func start(locale: Locale) async throws {
        for ch in ["mic", "screen"] {
            recorders[ch] = RotatingRecorder(channel: ch, spoolDir: spoolDir)
            transcribers[ch] = try await TranscriberWrapper(channel: ch, locale: locale,
                                                            quickWriter: quickWriter,
                                                            finalWriter: finalWriter)
            try recorders[ch]?.start()
        }

        for ch in ["mic", "screen"] {
            sounds[ch] = try SoundAnalyzerWrapper(channel: ch, writer: soundWriter, format: Self.targetFormat)
        }

        try await startMic()
        try await startScreen()
        scheduleAutoRotate(every: 300)
    }

    func rotateAll(reason: String) async {
        for (ch, recorder) in recorders {
            await rotate(channel: ch, recorder: recorder, reason: reason)
        }
        for ch in ["mic", "screen"] {
            recorders[ch] = RotatingRecorder(channel: ch, spoolDir: spoolDir)
            try? recorders[ch]?.start()
        }
    }

    /// Stops mic capture and the screen audio stream so no more buffers are
    /// in flight, then runs the same rotateAll path. Used at shutdown — without
    /// stopping the engines first, late buffers arrive between markAsFinished
    /// and finishWriting completion, leaving the CAF without a packet table
    /// (afinfo: "audio packets: 0", AVAudioFile fails to open).
    func shutdownRotate(reason: String) async {
        micEngine.stop()
        if let stream = screenStream {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                stream.stopCapture { _ in cont.resume() }
            }
        }
        screenStream = nil
        for (ch, recorder) in recorders {
            await rotate(channel: ch, recorder: recorder, reason: reason)
        }
        recorders.removeAll()
    }

    func acknowledgeAndDelete(paths: [String]) {
        for p in paths {
            let url = URL(fileURLWithPath: p)
            try? FileManager.default.removeItem(at: url)
            try? stateWriter.append([
                "ts": Date().timeIntervalSince1970,
                "kind": "deleted",
                "path": p
            ])
        }
    }

    private func rotate(channel: String, recorder: RotatingRecorder, reason: String) async {
        FileHandle.standardError.write("rotate[\(channel)]: finalize begin\n".data(using: .utf8)!)
        let finalized: (path: String, bytes: Int) = await withCheckedContinuation { (cont: CheckedContinuation<(String, Int), Never>) in
            recorder.finalize { url in
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
                cont.resume(returning: (url.path, bytes))
            }
        }
        FileHandle.standardError.write("rotate[\(channel)]: finalize done bytes=\(finalized.bytes)\n".data(using: .utf8)!)
        try? stateWriter.append([
            "ts": Date().timeIntervalSince1970,
            "kind": "rotated",
            "channel": channel,
            "path": finalized.path,
            "bytes": finalized.bytes,
            "reason": reason
        ])
    }

    private func scheduleAutoRotate(every seconds: TimeInterval) {
        rotateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.rotateAll(reason: "auto")
            }
        }
    }

    private func startMic() async throws {
        let format = Self.targetFormat
        let input = micEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity)!
            var error: NSError?
            converter?.convert(to: outBuffer, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            Task { await self.feed(channel: "mic", buffer: outBuffer, time: time) }
        }
        try micEngine.start()
    }

    private func feed(channel: String, buffer: AVAudioPCMBuffer, time: AVAudioTime) async {
        try? recorders[channel]?.append(buffer)
        transcribers[channel]?.append(buffer)
        sounds[channel]?.append(buffer, at: time)
    }

    private func startScreen() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            FileHandle.standardError.write("startScreen: no display available\n".data(using: .utf8)!)
            return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        let delegate = ScreenStreamDelegate()
        screenDelegate = delegate
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        let audioOutput = ScreenAudioOutput(coordinator: self)
        screenAudioOutput = audioOutput
        try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        screenStream = stream
        FileHandle.standardError.write("startScreen: capturing display=\(display.displayID) requested 16kHz mono\n".data(using: .utf8)!)
    }

    fileprivate func feedScreen(buffer: AVAudioPCMBuffer, time: AVAudioTime) async {
        await feed(channel: "screen", buffer: buffer, time: time)
    }
}

@available(macOS 26.0, *)
final class ScreenAudioOutput: NSObject, SCStreamOutput {
    private weak var coordinator: CaptureCoordinator?
    private var bufferCount = 0
    private var conversionFailureCount = 0
    init(coordinator: CaptureCoordinator) { self.coordinator = coordinator }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        bufferCount += 1
        if bufferCount == 1 {
            FileHandle.standardError.write("ScreenAudioOutput: first buffer received format=\(String(describing: sb.formatDescription))\n".data(using: .utf8)!)
        }
        guard let pcm = sb.toAVAudioPCMBuffer() else {
            conversionFailureCount += 1
            if conversionFailureCount == 1 || conversionFailureCount % 200 == 0 {
                FileHandle.standardError.write("ScreenAudioOutput: toAVAudioPCMBuffer returned nil (count=\(conversionFailureCount))\n".data(using: .utf8)!)
            }
            return
        }
        let time = AVAudioTime(sampleTime: sb.presentationTimeStamp.value, atRate: pcm.format.sampleRate)
        let coord = coordinator
        Task { [pcm, time] in
            await coord?.feedScreen(buffer: pcm, time: time)
        }
    }
}

@available(macOS 26.0, *)
final class ScreenStreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("SCStream stopped with error: \(error)\n".data(using: .utf8)!)
    }
}

extension CMSampleBuffer {
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(self,
                                                                       bufferListSizeNeededOut: nil,
                                                                       bufferListOut: &audioBufferList,
                                                                       bufferListSize: MemoryLayout<AudioBufferList>.size,
                                                                       blockBufferAllocator: nil,
                                                                       blockBufferMemoryAllocator: nil,
                                                                       flags: 0,
                                                                       blockBufferOut: &blockBuffer) == noErr else { return nil }
        let format = AVAudioFormat(streamDescription: CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription!)!)!
        let frames = AVAudioFrameCount(numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        if let mData = audioBufferList.mBuffers.mData,
           let dst = pcm.floatChannelData?[0] {
            memcpy(dst, mData, Int(audioBufferList.mBuffers.mDataByteSize))
        }
        return pcm
    }
}

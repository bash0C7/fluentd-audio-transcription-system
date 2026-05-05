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
        let finalized: (path: String, bytes: Int) = await withCheckedContinuation { (cont: CheckedContinuation<(String, Int), Never>) in
            recorder.finalize { url in
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
                cont.resume(returning: (url.path, bytes))
            }
        }
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
        try? await transcribers[channel]?.append(buffer)
        sounds[channel]?.append(buffer, at: time)
    }

    private func startScreen() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(ScreenAudioOutput(coordinator: self), type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        screenStream = stream
    }

    fileprivate func feedScreen(buffer: AVAudioPCMBuffer, time: AVAudioTime) async {
        await feed(channel: "screen", buffer: buffer, time: time)
    }
}

@available(macOS 26.0, *)
final class ScreenAudioOutput: NSObject, SCStreamOutput {
    private weak var coordinator: CaptureCoordinator?
    init(coordinator: CaptureCoordinator) { self.coordinator = coordinator }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let pcm = sb.toAVAudioPCMBuffer() else { return }
        let time = AVAudioTime(sampleTime: sb.presentationTimeStamp.value, atRate: pcm.format.sampleRate)
        let coord = coordinator
        Task { [pcm, time] in
            await coord?.feedScreen(buffer: pcm, time: time)
        }
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

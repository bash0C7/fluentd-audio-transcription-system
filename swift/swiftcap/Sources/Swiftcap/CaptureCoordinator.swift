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
    private let emitter: RecordEmitter
    private var rotateTask: Task<Void, Never>?
    private let micEngine = AVAudioEngine()
    private var screenStream: SCStream?
    private var screenDelegate: ScreenStreamDelegate?
    // SCStream.addStreamOutput retains the output only weakly; without a
    // strong property here the inline-created ScreenAudioOutput would be
    // ARC-released as soon as addStreamOutput returns, and ScreenCaptureKit
    // would log "streamOutput NOT found. Dropping frame" for every buffer.
    private var screenAudioOutput: ScreenAudioOutput?
    let sessions: SessionTracker

    // Tracks whether the screen channel is currently capturing. Set true after
    // startScreen succeeds, cleared by handleScreenStreamStopped or shutdownRotate.
    // Internal (not private) so tests can drive the active-state path without
    // needing a real SCStream.
    internal var screenChannelActive: Bool = false

    #if DEBUG
    internal func markScreenActiveForTesting() {
        screenChannelActive = true
    }
    #endif

    init(spoolDir: URL, emitter: RecordEmitter, sessions: SessionTracker = SessionTracker()) {
        self.spoolDir = spoolDir
        self.emitter = emitter
        self.sessions = sessions
        try? FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
    }

    func start(locale: Locale) async throws {
        let sat = await sessions.currentSessionStartedAt
        emitter.emit(stream: "state", record: [
            "ts": Date().timeIntervalSince1970,
            "kind": "session_started",
            "session_started_at": sat
        ])

        for ch in ["mic", "screen"] {
            recorders[ch] = RotatingRecorder(channel: ch, spoolDir: spoolDir)
            transcribers[ch] = try await TranscriberWrapper(
                channel: ch, locale: locale,
                emitter: emitter,
                sessionStartedAtProvider: { [weak self] in
                    await self?.sessions.currentSessionStartedAt ?? 0
                })
            try recorders[ch]?.start()
        }

        // Screen SoundAnalyzerWrapper has a fixed format (matches
        // SCStreamConfiguration). The mic SoundAnalyzerWrapper is created
        // inside startMic() once micEngine.inputNode's format is queried —
        // touching micEngine.inputNode here, before SCStream is configured,
        // activates the shared audio subsystem and triggers SCStream
        // -3805 "application connection interrupted" with a leaked task
        // continuation. Keep the inputNode access inside startMic only.
        let screenFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000,
                                         channels: 1,
                                         interleaved: false)!
        sounds["screen"] = try SoundAnalyzerWrapper(channel: "screen", emitter: emitter, format: screenFormat)

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
        screenAudioOutput = nil
        screenDelegate = nil
        screenChannelActive = false
        for (ch, recorder) in recorders {
            await rotate(channel: ch, recorder: recorder, reason: reason)
        }
        recorders.removeAll()
    }

    /// Called when the user presses 区切る in the web UI. Finalizes all active
    /// recorders for the current session, advances SessionTracker to a new
    /// session_started_at, restarts recorders so the next CAF rotation belongs
    /// to the new session, and emits session_finalized + session_started state
    /// events. The just-finalized session_started_at is what the web worker
    /// will look up to spawn `swiftcap retranscribe`.
    func handleBoundary(now: TimeInterval = Date().timeIntervalSince1970) async {
        for (ch, recorder) in recorders {
            await rotate(channel: ch, recorder: recorder, reason: "boundary")
        }
        let prevSat = await sessions.rollover(now: now)
        emitter.emit(stream: "state", record: [
            "ts": now,
            "kind": "session_finalized",
            "session_started_at": prevSat,
            "ended_at": now
        ])
        emitter.emit(stream: "state", record: [
            "ts": now,
            "kind": "session_started",
            "session_started_at": now
        ])
        for ch in ["mic", "screen"] {
            recorders[ch] = RotatingRecorder(channel: ch, spoolDir: spoolDir)
            try? recorders[ch]?.start()
        }
    }

    /// Toggle mic-channel mute. SessionTracker holds the flag; the live mic
    /// AVAudioEngine tap is removed/reinstalled so no buffers reach the
    /// recorder/transcriber/sound analyzer for the mic channel during mute.
    /// Screen channel and current session_started_at are unaffected.
    func handleMuteToggle() async {
        let nowMuted = await sessions.toggleMute()
        let sat = await sessions.currentSessionStartedAt
        if micEngine.isRunning {
            if nowMuted {
                micEngine.inputNode.removeTap(onBus: 0)
            } else {
                installMicTap()
            }
        }
        emitter.emit(stream: "state", record: [
            "ts": Date().timeIntervalSince1970,
            "kind": "mute_changed",
            "session_started_at": sat,
            "mic_muted": nowMuted
        ])
    }

    /// Extracted from startMic() so handleMuteToggle can re-install the tap
    /// after an unmute. Engine itself is not stopped — installTap is enough
    /// to resume buffer flow.
    private func installMicTap() {
        let input = micEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            Task { await self.feed(channel: "mic", buffer: buffer, time: time) }
        }
    }

    func acknowledgeAndDelete(paths: [String]) {
        for p in paths {
            let url = URL(fileURLWithPath: p)
            try? FileManager.default.removeItem(at: url)
            emitter.emit(stream: "state", record: [
                "ts": Date().timeIntervalSince1970,
                "kind": "deleted",
                "path": p
            ])
        }
    }

    private func rotate(channel: String, recorder: RotatingRecorder, reason: String) async {
        FileHandle.standardError.write("rotate[\(channel)]: finalize begin\n".data(using: .utf8)!)
        let finalized: (path: String, bytes: Int, startedAt: TimeInterval, endedAt: TimeInterval) =
            await withCheckedContinuation { (cont: CheckedContinuation<(String, Int, TimeInterval, TimeInterval), Never>) in
                recorder.finalize { url, startedAt, endedAt in
                    let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                    let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
                    cont.resume(returning: (url.path, bytes, startedAt, endedAt))
                }
            }
        FileHandle.standardError.write("rotate[\(channel)]: finalize done bytes=\(finalized.bytes)\n".data(using: .utf8)!)
        let sat = await sessions.currentSessionStartedAt
        emitter.emit(stream: "state", record: [
            "ts": Date().timeIntervalSince1970,
            "kind": "rotated",
            "channel": channel,
            "path": finalized.path,
            "bytes": finalized.bytes,
            "started_at": finalized.startedAt,
            "ended_at": finalized.endedAt,
            "session_started_at": sat,
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
        let input = micEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        sounds["mic"] = try SoundAnalyzerWrapper(channel: "mic", emitter: emitter, format: inputFormat)
        let firstBufferLogged = ConvertOnce()
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            if firstBufferLogged.fire() {
                FileHandle.standardError.write(
                    "MicAudioOutput: first buffer received format=\(buffer.format) frameLength=\(buffer.frameLength)\n".data(using: .utf8)!
                )
            }
            // Pass the native buffer through to all consumers. RotatingRecorder's
            // AVAssetWriter encoder resamples to AAC HE 16kHz mono internally,
            // TranscriberWrapper resamples once to its analyzerFormat on the
            // SpeechAnalyzer side, and SoundAnalyzerWrapper is now initialized
            // with this same native format. This eliminates the prior two-stage
            // convert (input → 16kHz Float32 → analyzerFormat) that Apple's
            // BringingAdvancedSpeechToTextCapabilitiesToYourApp sample avoids.
            Task { await self.feed(channel: "mic", buffer: buffer, time: time) }
        }
        try micEngine.start()
        FileHandle.standardError.write(
            "startMic: input running format=\(inputFormat) (native pass-through)\n".data(using: .utf8)!
        )

        // Loud failure if no buffer arrives within 5s — prevents silent silence
        // (the bug observed in 2026-05-06 E5 where mic captured nothing for 22 minutes).
        try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        if !firstBufferLogged.isFired {
            throw NSError(
                domain: "swiftcap.mic",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no mic buffer in 5s — check Microphone permission and System Settings → Privacy & Security → Microphone"]
            )
        }
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
        delegate.coordinator = self
        screenDelegate = delegate
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        let audioOutput = ScreenAudioOutput(coordinator: self)
        screenAudioOutput = audioOutput
        try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        screenStream = stream
        screenChannelActive = true
        FileHandle.standardError.write("startScreen: capturing display=\(display.displayID) requested 16kHz mono\n".data(using: .utf8)!)
    }

    fileprivate func feedScreen(buffer: AVAudioPCMBuffer, time: AVAudioTime) async {
        await feed(channel: "screen", buffer: buffer, time: time)
    }

    /// Called when SCStream emits didStopWithError. Marks the screen channel as
    /// dead, emits a loud channel_failed event, finalizes any in-flight screen
    /// recorder one last time, and drops screen-side state. Mic continues.
    /// Idempotent: the screenChannelActive guard ensures repeated calls no-op.
    func handleScreenStreamStopped(error: Error) async {
        guard screenChannelActive else { return }
        screenChannelActive = false

        FileHandle.standardError.write(
            "handleScreenStreamStopped: marking screen channel as dead, mic continues. error=\(error)\n"
                .data(using: .utf8)!
        )

        emitter.emit(stream: "state", record: [
            "ts": Date().timeIntervalSince1970,
            "kind": "channel_failed",
            "channel": "screen",
            "reason": "scstream_error",
            "error": "\(error)"
        ])

        screenStream = nil
        screenAudioOutput = nil
        screenDelegate = nil

        if let r = recorders["screen"] {
            await rotate(channel: "screen", recorder: r, reason: "channel_failed")
            recorders["screen"] = nil
        }
        transcribers["screen"] = nil
        sounds["screen"] = nil
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
    weak var coordinator: CaptureCoordinator?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("SCStream stopped with error: \(error)\n".data(using: .utf8)!)
        if let coord = coordinator {
            Task { await coord.handleScreenStreamStopped(error: error) }
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

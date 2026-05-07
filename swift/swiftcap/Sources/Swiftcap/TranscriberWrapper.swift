// swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift
@preconcurrency import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class TranscriberWrapper: @unchecked Sendable {
    private let channel: String
    private let locale: Locale
    private let quickWriter: SpoolWriter
    private let finalWriter: SpoolWriter
    let sessionStartedAtProvider: @Sendable () async -> TimeInterval
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    // SpeechAnalyzer's required input format is queried at init time via
    // bestAvailableAudioFormat. macOS 26 traps with "Audio sample data must be
    // 16-bit signed integers" when the buffer format does not match.
    private let analyzerFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    // Single long-lived input sequence — SpeechAnalyzer rejects re-entrant
    // analyzeSequence with `Cannot simultaneously analyze multiple input
    // sequences`. We yield each buffer to one continuation and call start()
    // on it exactly once.
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    init(channel: String, locale: Locale, quickWriter: SpoolWriter, finalWriter: SpoolWriter,
         sessionStartedAtProvider: @escaping @Sendable () async -> TimeInterval = { 0 }) async throws {
        self.channel = channel
        self.locale = locale
        self.quickWriter = quickWriter
        self.finalWriter = finalWriter
        self.sessionStartedAtProvider = sessionStartedAtProvider
        self.transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        try await Self.ensureModelInstalled(transcriber: transcriber, locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "swiftcap.transcriber", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no compatible audio format for SpeechTranscriber on locale \(locale.identifier)"])
        }
        self.analyzerFormat = format
        FileHandle.standardError.write("transcriber[\(channel)] analyzerFormat=\(format)\n".data(using: .utf8)!)

        let analyzerRef = analyzer
        Task {
            do {
                try await analyzerRef.start(inputSequence: stream)
            } catch {
                FileHandle.standardError.write("analyzer.start[\(channel)] error: \(error)\n".data(using: .utf8)!)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let transcriptId = UUID().uuidString
                    let text = String(result.text.characters)
                    let now = Date().timeIntervalSince1970
                    let startedAt = result.range.start.seconds
                    let endedAt = result.range.end.seconds
                    let sat = await self.sessionStartedAtProvider()
                    if result.isFinal {
                        try? self.finalWriter.append([
                            "ts": now,
                            "ch": self.channel,
                            "kind": "final",
                            "text": text,
                            "started_at": startedAt,
                            "ended_at": endedAt,
                            "language": self.locale.identifier(.bcp47),
                            "transcript_id": transcriptId,
                            "session_started_at": sat
                        ])
                    } else {
                        try? self.quickWriter.append([
                            "ts": now,
                            "ch": self.channel,
                            "kind": "volatile",
                            "text": text,
                            "transcript_id": transcriptId,
                            "session_started_at": sat
                        ])
                    }
                }
            } catch {
                FileHandle.standardError.write("transcriber[\(self.channel)] results error: \(error)\n".data(using: .utf8)!)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let target = convertToAnalyzerFormat(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: target))
    }

    private func convertToAnalyzerFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.isEqual(analyzerFormat) { return buffer }
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        // Mirror BufferConversion.swift in the Apple sample app: size the
        // output by frameLength (actual data) × sample-rate ratio, and
        // signal `.noDataNow` after the single input buffer is consumed
        // so the converter terminates cleanly without hanging on
        // perceived end-of-stream.
        let sampleRateRatio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let scaledOutFrames = Double(buffer.frameLength) * sampleRateRatio
        let outCapacity = AVAudioFrameCount(scaledOutFrames.rounded(.up))
        guard outCapacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outCapacity)
        else { return nil }
        var err: NSError?
        // ConvertOnce is Sendable-safe; strict concurrency disallows
        // capturing `var` flags in the @Sendable input block.
        let consumed = ConvertOnce()
        let status = converter.convert(to: out, error: &err) { _, inputStatusPointer in
            if consumed.fire() {
                inputStatusPointer.pointee = .haveData
                return buffer
            }
            inputStatusPointer.pointee = .noDataNow
            return nil
        }
        return status != .error ? out : nil
    }

    func finalize() async throws {
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    private static func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else {
            throw NSError(domain: "swiftcap", code: 1, userInfo: [NSLocalizedDescriptionKey: "locale not supported"])
        }
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else { return }
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
    }
}

// One-shot latch used to gate AVAudioConverter's input callback to a single yield.
final class ConvertOnce: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
    /// Read-only check whether fire() has been called.
    var isFired: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}

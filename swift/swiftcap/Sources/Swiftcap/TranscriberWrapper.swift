// swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift
@preconcurrency import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class TranscriberWrapper: @unchecked Sendable {
    private let channel: String
    private let quickWriter: SpoolWriter
    private let finalWriter: SpoolWriter
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputBuilder: AnalyzerInputSequence
    // SpeechAnalyzer's required input format is queried at init time via
    // bestAvailableAudioFormat. macOS 26 traps with "Audio sample data must be
    // 16-bit signed integers" when the buffer format does not match.
    private let analyzerFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(channel: String, locale: Locale, quickWriter: SpoolWriter, finalWriter: SpoolWriter) async throws {
        self.channel = channel
        self.quickWriter = quickWriter
        self.finalWriter = finalWriter
        self.transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.inputBuilder = AnalyzerInputSequence()
        try await Self.ensureModelInstalled(transcriber: transcriber, locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "swiftcap.transcriber", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no compatible audio format for SpeechTranscriber on locale \(locale.identifier)"])
        }
        self.analyzerFormat = format
        FileHandle.standardError.write("transcriber[\(channel)] analyzerFormat=\(format)\n".data(using: .utf8)!)
        Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let transcriptId = UUID().uuidString
                    let text = String(result.text.characters)
                    if result.isFinal {
                        try? self.finalWriter.append([
                            "ts": Date().timeIntervalSince1970,
                            "ch": self.channel,
                            "kind": "final",
                            "text": text,
                            "transcript_id": transcriptId
                        ])
                    } else {
                        try? self.quickWriter.append([
                            "ts": Date().timeIntervalSince1970,
                            "ch": self.channel,
                            "kind": "volatile",
                            "text": text,
                            "transcript_id": transcriptId
                        ])
                    }
                }
            } catch {
                FileHandle.standardError.write("transcriber error: \(error)\n".data(using: .utf8)!)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) async throws {
        guard let target = convertToAnalyzerFormat(buffer) else { return }
        _ = try await analyzer.analyzeSequence(inputBuilder.append(target))
    }

    private func convertToAnalyzerFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.isEqual(analyzerFormat) { return buffer }
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converter else { return nil }
        let inSr = buffer.format.sampleRate
        let outSr = analyzerFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameCapacity) * outSr / inSr)
        guard outCapacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outCapacity)
        else { return nil }
        var err: NSError?
        let consumed = ConvertOnce()
        converter.convert(to: out, error: &err) { _, status in
            if consumed.fire() {
                status.pointee = .haveData
                return buffer
            }
            status.pointee = .endOfStream
            return nil
        }
        return err == nil ? out : nil
    }

    func finalize() async throws {
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

// AnalyzerInputSequence wraps each AVAudioPCMBuffer as a SpeechAnalyzer-compatible
// AnalyzerInput sequence. SpeechAnalyzer.analyzeSequence requires an AsyncSequence
// whose element type is AnalyzerInput.
@available(macOS 26.0, *)
final class AnalyzerInputSequence {
    func append(_ buffer: AVAudioPCMBuffer) -> AsyncStream<AnalyzerInput> {
        AsyncStream { continuation in
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
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
}

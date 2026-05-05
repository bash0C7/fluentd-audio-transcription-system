// swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift
import AVFoundation
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
        try await ensureModelInstalled(locale: locale)
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
        _ = try await analyzer.analyzeSequence(inputBuilder.append(buffer))
    }

    func finalize() async throws {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    private func ensureModelInstalled(locale: Locale) async throws {
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

// swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift
@preconcurrency import AVFoundation
import Foundation
import Speech
import SQLite3

@available(macOS 26.0, *)
struct RetranscribeCommand {
    let sessionId: Int
    let locale: Locale
    let pass: Int

    static func parse(args: [String]) -> RetranscribeCommand? {
        var sid: Int? = nil
        var locale = Locale(identifier: "ja-JP")
        var pass = 2
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--session-id":
                guard i + 1 < args.count, let n = Int(args[i + 1]) else { return nil }
                sid = n; i += 2
            case "--locale":
                guard i + 1 < args.count else { return nil }
                locale = Locale(identifier: args[i + 1]); i += 2
            case "--pass":
                guard i + 1 < args.count, let n = Int(args[i + 1]) else { return nil }
                pass = n; i += 2
            default:
                i += 1
            }
        }
        guard let sid else { return nil }
        return RetranscribeCommand(sessionId: sid, locale: locale, pass: pass)
    }
}

@available(macOS 26.0, *)
extension RetranscribeCommand {
    /// Production entry: looks up audio_segments by session_id, expands blobs
    /// to tmp CAFs, calls runForFixture. Caller provides DB path.
    func run(dbPath: String, socketPath: String) async throws {
        let blobs = try Self.fetchAudioSegmentBlobs(dbPath: dbPath, sessionId: sessionId)
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftcap-retr-\(sessionId)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        var files: [URL] = []
        for (i, blob) in blobs.enumerated() {
            let f = tmpRoot.appendingPathComponent("seg-\(i).caf")
            try blob.write(to: f)
            files.append(f)
        }
        try await runForFixture(audioFiles: files, socketPath: socketPath)
    }

    /// Test-friendly entry: takes already-on-disk audio files and runs them
    /// through one shared SpeechAnalyzer instance via start(inputSequence:),
    /// feeding each file's frames in order and finalizing at the end.
    func runForFixture(audioFiles: [URL], socketPath: String) async throws {
        // Mirror TranscriberWrapper: create transcriber + analyzer, ensure model
        // installed, obtain bestAvailableAudioFormat before starting the stream.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Ensure locale model is available; gracefully skip if not installed.
        do {
            try await Self.ensureModelInstalled(transcriber: transcriber, locale: locale)
        } catch {
            FileHandle.standardError.write(
                "retranscribe: locale model not installed (\(error)), emitting retranscribe_done with no results\n"
                    .data(using: .utf8)!)
            do {
                let client = try ControlSocketClient(socketPath: socketPath)
                defer { client.close() }
                try? client.emit(stream: "state", record: [
                    "ts": Date().timeIntervalSince1970,
                    "kind": "retranscribe_done",
                    "session_id": sessionId
                ])
            } catch {
                FileHandle.standardError.write("retranscribe: cannot connect to \(socketPath): \(error)\n".data(using: .utf8)!)
                throw error
            }
            return
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "swiftcap.retranscribe", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "no compatible audio format for locale \(locale.identifier)"])
        }

        // Single long-lived input stream — same pattern as TranscriberWrapper.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Start the analyzer on the stream in a background task.
        let analyzerTask = Task {
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                FileHandle.standardError.write("retranscribe: analyzer.start error: \(error)\n".data(using: .utf8)!)
            }
        }

        // Collect final (non-volatile) results in parallel.
        let collectTask: Task<[String], Error> = Task {
            var out: [String] = []
            for try await result in transcriber.results {
                if result.isFinal {
                    out.append(String(result.text.characters))
                }
            }
            return out
        }

        // Feed all audio files' frames into the stream.
        for fileURL in audioFiles {
            let avFile = try AVAudioFile(forReading: fileURL)
            let fileFormat = avFile.processingFormat
            let totalFrames = AVAudioFrameCount(avFile.length)
            guard totalFrames > 0 else { continue }

            // Convert to analyzerFormat if needed, using the same AVAudioConverter
            // approach as TranscriberWrapper.
            let needsConversion = !fileFormat.isEqual(analyzerFormat)
            let converter: AVAudioConverter? = needsConversion
                ? AVAudioConverter(from: fileFormat, to: analyzerFormat)
                : nil
            if needsConversion { converter?.primeMethod = .none }

            // Read in chunks to keep memory reasonable.
            let chunkFrames: AVAudioFrameCount = 4096
            var framesRemaining = totalFrames
            while framesRemaining > 0 {
                let readFrames = min(chunkFrames, framesRemaining)
                guard let readBuf = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: readFrames) else { break }
                try avFile.read(into: readBuf, frameCount: readFrames)
                guard readBuf.frameLength > 0 else { break }
                framesRemaining -= readBuf.frameLength

                let outBuf: AVAudioPCMBuffer
                if let conv = converter {
                    let sampleRateRatio = analyzerFormat.sampleRate / fileFormat.sampleRate
                    let outCapacity = AVAudioFrameCount((Double(readBuf.frameLength) * sampleRateRatio).rounded(.up))
                    guard outCapacity > 0,
                          let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outCapacity)
                    else { continue }
                    var convErr: NSError?
                    let latch = ConvertOnce()
                    let status = conv.convert(to: converted, error: &convErr) { _, inputStatusPointer in
                        if latch.fire() {
                            inputStatusPointer.pointee = .haveData
                            return readBuf
                        }
                        inputStatusPointer.pointee = .noDataNow
                        return nil
                    }
                    guard status != .error else { continue }
                    outBuf = converted
                } else {
                    outBuf = readBuf
                }
                continuation.yield(AnalyzerInput(buffer: outBuf))
            }
        }

        // Signal end-of-input and finalize.
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await analyzerTask.value

        let texts = try await collectTask.value

        let client: ControlSocketClient
        do {
            client = try ControlSocketClient(socketPath: socketPath)
        } catch {
            FileHandle.standardError.write("retranscribe: cannot connect to \(socketPath): \(error)\n".data(using: .utf8)!)
            throw error
        }
        defer { client.close() }
        for text in texts {
            try? client.emit(stream: "final", record: [
                "ts": Date().timeIntervalSince1970,
                "kind": "final",
                "ch": "mic",
                "text": text,
                "language": locale.identifier(.bcp47),
                "pass": pass,
                "session_id": sessionId
            ])
        }
        try? client.emit(stream: "state", record: [
            "ts": Date().timeIntervalSince1970,
            "kind": "retranscribe_done",
            "session_id": sessionId
        ])
    }

    fileprivate static func fetchAudioSegmentBlobs(dbPath: String, sessionId: Int) throws -> [Data] {
        var dbPtr: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &dbPtr, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = dbPtr else {
            throw NSError(domain: "swiftcap.retranscribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "open db failed: \(dbPath)"])
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT blob FROM audio_segments WHERE session_id=? ORDER BY started_at ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw NSError(domain: "swiftcap.retranscribe", code: 2)
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(sessionId))
        var out: [Data] = []
        while sqlite3_step(s) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(s, 0) {
                let n = sqlite3_column_bytes(s, 0)
                out.append(Data(bytes: bytes, count: Int(n)))
            }
        }
        return out
    }

    private static func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else {
            throw NSError(domain: "swiftcap.retranscribe", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "locale not supported: \(locale.identifier)"])
        }
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else { return }
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
    }
}

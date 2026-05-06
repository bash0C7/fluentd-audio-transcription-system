// swift/swiftcap/Sources/Swiftcap/main.swift
import Foundation

@available(macOS 26.0, *)
@main
struct Swiftcap {
    static func main() async {
        let spoolDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWIFTCAP_SPOOL"]
            ?? NSString(string: "~/Library/Application Support/audio-transcription/spool").expandingTildeInPath)
        let locale = Locale(identifier: ProcessInfo.processInfo.environment["SWIFTCAP_LOCALE"] ?? "ja-JP")

        FileHandle.standardError.write("swiftcap starting spool=\(spoolDir.path) locale=\(locale.identifier)\n".data(using: .utf8)!)
        let coordinator = CaptureCoordinator(spoolDir: spoolDir)
        do {
            try await coordinator.start(locale: locale)
        } catch {
            FileHandle.standardError.write("startup failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        FileHandle.standardError.write("swiftcap ready\n".data(using: .utf8)!)

        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        hupSource.setEventHandler { Task { await coordinator.rotateAll(reason: "hup") } }
        signal(SIGHUP, SIG_IGN)
        hupSource.resume()

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler {
            Task {
                await coordinator.rotateAll(reason: "shutdown")
                exit(0)
            }
        }
        signal(SIGTERM, SIG_IGN)
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSource.setEventHandler {
            Task {
                await coordinator.rotateAll(reason: "shutdown")
                exit(0)
            }
        }
        signal(SIGINT, SIG_IGN)
        intSource.resume()

        let ackReader = AckReader(url: spoolDir.appendingPathComponent("ack.jsonl"))
        Task {
            while true {
                if let consumed = try? ackReader.readNew(), !consumed.isEmpty {
                    await coordinator.acknowledgeAndDelete(paths: consumed)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        try? await Task.sleep(nanoseconds: UInt64.max)
    }
}

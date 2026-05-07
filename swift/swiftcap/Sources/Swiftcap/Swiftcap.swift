// swift/swiftcap/Sources/Swiftcap/main.swift
import Foundation

@available(macOS 26.0, *)
@main
struct Swiftcap {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv.first == "retranscribe" {
            let subArgs = Array(argv.dropFirst())
            guard let cmd = RetranscribeCommand.parse(args: subArgs) else {
                FileHandle.standardError.write("usage: swiftcap retranscribe --session-id N [--locale ja-JP] [--pass 2]\n".data(using: .utf8)!)
                exit(2)
            }
            let retranscribeSpoolDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWIFTCAP_SPOOL"]
                ?? NSString(string: "~/Library/Application Support/audio-transcription/spool").expandingTildeInPath)
            let dbPath = ProcessInfo.processInfo.environment["DB_PATH"] ?? "db/meeting_log.sqlite"
            do {
                try await cmd.run(dbPath: dbPath, spoolDir: retranscribeSpoolDir)
                exit(0)
            } catch {
                FileHandle.standardError.write("retranscribe failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }

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

        let shutdown: @Sendable () -> Void = {
            Task {
                FileHandle.standardError.write("shutdown: stopping engines + rotating\n".data(using: .utf8)!)
                await coordinator.shutdownRotate(reason: "shutdown")
                FileHandle.standardError.write("shutdown: done, exiting\n".data(using: .utf8)!)
                exit(0)
            }
        }

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler(handler: shutdown)
        signal(SIGTERM, SIG_IGN)
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSource.setEventHandler(handler: shutdown)
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

        let controlReader = ControlReader(
            controlURL: spoolDir.appendingPathComponent("control.jsonl"),
            posURL: spoolDir.appendingPathComponent(".pos.control"))
        Task {
            while true {
                if let events = try? controlReader.readNew(), !events.isEmpty {
                    for ev in events {
                        switch ev["kind"] as? String {
                        case "boundary":
                            await coordinator.handleBoundary()
                        case "mute_toggle":
                            await coordinator.handleMuteToggle()
                        default:
                            FileHandle.standardError.write("control: unknown kind \(ev)\n".data(using: .utf8)!)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        try? await Task.sleep(nanoseconds: UInt64.max)
    }
}

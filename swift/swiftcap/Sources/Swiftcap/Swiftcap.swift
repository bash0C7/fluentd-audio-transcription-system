// swift/swiftcap/Sources/Swiftcap/Swiftcap.swift
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
        let socketPath = ProcessInfo.processInfo.environment["SWIFTCAP_SOCKET_PATH"]
            ?? spoolDir.appendingPathComponent("swiftcap.sock").path
        let locale = Locale(identifier: ProcessInfo.processInfo.environment["SWIFTCAP_LOCALE"] ?? "ja-JP")

        FileHandle.standardError.write(
            "swiftcap starting spool=\(spoolDir.path) socket=\(socketPath) locale=\(locale.identifier)\n".data(using: .utf8)!)

        let emitter = StdoutEmitter()
        let coordinator = CaptureCoordinator(spoolDir: spoolDir, emitter: emitter)

        do {
            try await coordinator.start(locale: locale)
        } catch {
            FileHandle.standardError.write("startup failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        let controlSocket: ControlSocket
        do {
            controlSocket = try ControlSocket(socketPath: socketPath)
            try controlSocket.start(
                onBoundary: { Task { await coordinator.handleBoundary() } },
                onMuteToggle: { Task { await coordinator.handleMuteToggle() } },
                onAck: { paths in Task { await coordinator.acknowledgeAndDelete(paths: paths) } },
                emitter: emitter
            )
        } catch {
            FileHandle.standardError.write("controlsocket failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        emitter.emit(stream: "state", record: [
            "ts": Date().timeIntervalSince1970,
            "kind": "swiftcap_ready"
        ])
        FileHandle.standardError.write("swiftcap ready\n".data(using: .utf8)!)

        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        hupSource.setEventHandler { Task { await coordinator.rotateAll(reason: "hup") } }
        signal(SIGHUP, SIG_IGN)
        hupSource.resume()

        let shutdown: @Sendable () -> Void = {
            Task {
                FileHandle.standardError.write("shutdown: stopping engines + rotating\n".data(using: .utf8)!)
                await coordinator.shutdownRotate(reason: "shutdown")
                controlSocket.stop()
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

        try? await Task.sleep(nanoseconds: UInt64.max)
    }
}

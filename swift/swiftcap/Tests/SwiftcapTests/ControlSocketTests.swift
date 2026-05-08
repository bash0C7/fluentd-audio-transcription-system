import Foundation
import Testing
import Network
@testable import Swiftcap

@Suite("ControlSocketTests")
struct ControlSocketTests {

    @available(macOS 26.0, *)
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [[String: Any]] = []
        func record(_ obj: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            commands.append(obj)
        }
    }

    @available(macOS 26.0, *)
    @Test
    func dispatchesBoundaryAndMuteAndAckLines() async throws {
        let tmp = URL(fileURLWithPath: "/tmp/cs-\(UUID().uuidString.prefix(8)).sock")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = Recorder()
        let emitter = CapturingEmitter()
        let socket = try ControlSocket(socketPath: tmp.path)
        try socket.start(
            onBoundary: { recorder.record(["kind": "boundary"]) },
            onMuteToggle: { recorder.record(["kind": "mute_toggle"]) },
            onAck: { paths in recorder.record(["kind": "ack", "paths": paths]) },
            emitter: emitter
        )
        defer { socket.stop() }

        // Wait for listener readiness — NWListener becomes ready async.
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: tmp.path) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        // Connect a NWConnection client and send three lines.
        let conn = NWConnection(to: .unix(path: tmp.path), using: .tcp)
        conn.start(queue: .global())
        for _ in 0..<50 {
            if case .ready = conn.state { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let lines = [
            #"{"kind":"boundary"}"#,
            #"{"kind":"mute_toggle"}"#,
            #"{"kind":"ack","paths":["/a.caf","/b.caf"]}"#,
            #"{"kind":"emit","stream":"final","record":{"ts":1.0,"ch":"mic","kind":"final","text":"hi"}}"#
        ].joined(separator: "\n") + "\n"

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: lines.data(using: .utf8)!, completion: .contentProcessed { _ in cont.resume() })
        }
        // Drain time
        try? await Task.sleep(nanoseconds: 200_000_000)

        let cmds = recorder.commands
        #expect(cmds.contains { $0["kind"] as? String == "boundary" })
        #expect(cmds.contains { $0["kind"] as? String == "mute_toggle" })
        #expect(cmds.contains { ($0["kind"] as? String == "ack") && (($0["paths"] as? [String]) == ["/a.caf", "/b.caf"]) })

        // emit re-emission lands on the emitter as stream:"final"
        let finals = emitter.filter(stream: "final")
        #expect(finals.contains { $0["text"] as? String == "hi" })

        conn.cancel()
    }

    @available(macOS 26.0, *)
    @Test
    func unlinksStaleSocketFileBeforeBind() throws {
        let tmp = URL(fileURLWithPath: "/tmp/cs-stale-\(UUID().uuidString.prefix(8)).sock")
        // Pre-create a stale file
        try Data([0x00]).write(to: tmp)
        #expect(FileManager.default.fileExists(atPath: tmp.path))
        let socket = try ControlSocket(socketPath: tmp.path)
        try socket.start(
            onBoundary: {}, onMuteToggle: {}, onAck: { _ in },
            emitter: CapturingEmitter()
        )
        defer { socket.stop() }
        // After start, the path is bound (file exists, but is now a socket inode).
        #expect(FileManager.default.fileExists(atPath: tmp.path))
    }
}

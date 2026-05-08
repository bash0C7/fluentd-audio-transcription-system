import Foundation
import Testing
@testable import Swiftcap

@Suite("ControlSocketClientTests")
struct ControlSocketClientTests {

    @available(macOS 26.0, *)
    @Test
    func emitWritesEmitJsonLineToServer() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctrl-client-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let captured = CapturingEmitter()
        let socket = try ControlSocket(socketPath: tmp.path)
        try socket.start(
            onBoundary: {}, onMuteToggle: {}, onAck: { _ in },
            emitter: captured
        )
        defer { socket.stop() }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: tmp.path) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let client = try ControlSocketClient(socketPath: tmp.path)
        try client.emit(stream: "final", record: ["ts": 1.0, "ch": "mic", "kind": "final", "text": "ok"])
        try client.emit(stream: "state", record: ["ts": 2.0, "kind": "retranscribe_done", "session_id": 7])
        client.close()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let finals = captured.filter(stream: "final")
        #expect(finals.contains { $0["text"] as? String == "ok" })
        let states = captured.filter(stream: "state")
        #expect(states.contains { $0["kind"] as? String == "retranscribe_done" && $0["session_id"] as? Int == 7 })
    }

    @available(macOS 26.0, *)
    @Test
    func connectFailureThrows() {
        let bogus = "/nonexistent/dir/swiftcap.sock"
        #expect(throws: (any Error).self) {
            _ = try ControlSocketClient(socketPath: bogus)
        }
    }
}

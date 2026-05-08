import Testing
import Foundation
@testable import Swiftcap

@Suite("RetranscribeCommandTests")
struct RetranscribeCommandTests {
    @Test func parseArgsRequiresSessionId() {
        guard #available(macOS 26.0, *) else { return }
        let result = RetranscribeCommand.parse(args: ["--locale", "ja-JP"])
        #expect(result == nil, "missing --session-id should fail to parse")
    }

    @Test func parseArgsHappyPath() {
        guard #available(macOS 26.0, *) else { return }
        let res = RetranscribeCommand.parse(args: [
            "--session-id", "42", "--locale", "ja-JP", "--pass", "2"
        ])
        #expect(res != nil)
        #expect(res?.sessionId == 42)
        #expect(res?.locale.identifier == "ja-JP")
        #expect(res?.pass == 2)
    }

    @Test func parseArgsDefaults() {
        guard #available(macOS 26.0, *) else { return }
        let res = RetranscribeCommand.parse(args: ["--session-id", "7"])
        #expect(res != nil)
        #expect(res?.sessionId == 7)
        #expect(res?.pass == 2)
        #expect(res?.locale.identifier == "ja-JP")
    }

    @Test func runForFixtureEmitsFinalAndRetranscribeDoneViaSocket() async throws {
        guard #available(macOS 26.0, *) else { return }
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repoRoot.appendingPathComponent("test/fixtures/synthetic_e5_audio.aiff")
        guard FileManager.default.fileExists(atPath: fixture.path) else { return }

        let sockPath = NSString(string: "/tmp/retr-\(UUID().uuidString).sock").expandingTildeInPath
        defer { try? FileManager.default.removeItem(atPath: sockPath) }

        let captured = CapturingEmitter()
        let socket = try ControlSocket(socketPath: sockPath)
        try socket.start(
            onBoundary: {}, onMuteToggle: {}, onAck: { _ in },
            emitter: captured
        )
        defer { socket.stop() }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: sockPath) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let cmd = RetranscribeCommand(sessionId: 1, locale: Locale(identifier: "ja-JP"), pass: 2)
        try await cmd.runForFixture(audioFiles: [fixture], socketPath: sockPath)

        try? await Task.sleep(nanoseconds: 300_000_000)
        let finals = captured.filter(stream: "final")
        #expect(finals.contains { ($0["pass"] as? Int) == 2 && ($0["kind"] as? String) == "final" })
        let states = captured.filter(stream: "state")
        #expect(states.contains { $0["kind"] as? String == "retranscribe_done" })
    }
}

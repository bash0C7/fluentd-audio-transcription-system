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

    @Test func runForFixtureWritesFinalJsonlPass2() async throws {
        guard #available(macOS 26.0, *) else { return }
        // Repo root → test/fixtures/synthetic_e5_audio.aiff
        let here = URL(fileURLWithPath: #filePath)
        // #filePath = .../fluentd-audio-transcription-system/swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift
        // 5 x deletingLastPathComponent → fluentd-audio-transcription-system/ (repo root)
        let repoRoot = here
            .deletingLastPathComponent()  // removes RetranscribeCommandTests.swift → SwiftcapTests/
            .deletingLastPathComponent()  // SwiftcapTests → Tests/
            .deletingLastPathComponent()  // Tests → swiftcap/
            .deletingLastPathComponent()  // swiftcap → swift/
            .deletingLastPathComponent()  // swift → repo root
        let fixture = repoRoot.appendingPathComponent("test/fixtures/synthetic_e5_audio.aiff")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            // If the fixture isn't there, skip rather than fail.
            // (the test environment may not have the AIFF file)
            return
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cmd = RetranscribeCommand(sessionId: 1,
                                      locale: Locale(identifier: "ja-JP"),
                                      pass: 2)
        try await cmd.runForFixture(audioFiles: [fixture], spoolDir: tmp)

        let final = (try? String(contentsOf: tmp.appendingPathComponent("final.jsonl"), encoding: .utf8)) ?? ""
        // We expect at least one final.jsonl line tagged pass=2
        #expect(final.contains("\"pass\":2"))
        #expect(final.contains("\"kind\":\"final\""))
        let state = (try? String(contentsOf: tmp.appendingPathComponent("state.jsonl"), encoding: .utf8)) ?? ""
        #expect(state.contains("\"kind\":\"retranscribe_done\""))
    }
}

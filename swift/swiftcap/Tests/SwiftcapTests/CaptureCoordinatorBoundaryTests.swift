import Testing
import Foundation
@testable import Swiftcap

@Suite("CaptureCoordinatorBoundaryTests")
struct CaptureCoordinatorBoundaryTests {
    @Test func handleBoundaryEmitsSessionFinalizedAndAdvancesSession() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tracker = SessionTracker(now: 1000.0)
        let emitter = CapturingEmitter()
        let coord = CaptureCoordinator(spoolDir: tmp, emitter: emitter, sessions: tracker)
        await coord.handleBoundary(now: 2000.0)
        let next = await tracker.currentSessionStartedAt
        #expect(next == 2000.0)
        let states = emitter.filter(stream: "state")
        #expect(states.contains { ($0["kind"] as? String) == "session_finalized" && ($0["session_started_at"] as? Double) == 1000.0 })
        #expect(states.contains { ($0["kind"] as? String) == "session_started" && ($0["session_started_at"] as? Double) == 2000.0 })
    }

    @Test func handleMuteToggleFlipsAndEmitsEvent() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tracker = SessionTracker(now: 1000.0)
        let emitter = CapturingEmitter()
        let coord = CaptureCoordinator(spoolDir: tmp, emitter: emitter, sessions: tracker)
        await coord.handleMuteToggle()
        let muted1 = await tracker.isMicMuted
        #expect(muted1)
        await coord.handleMuteToggle()
        let muted2 = await tracker.isMicMuted
        #expect(!muted2)
        let states = emitter.filter(stream: "state")
        #expect(states.contains { ($0["kind"] as? String) == "mute_changed" })
    }
}

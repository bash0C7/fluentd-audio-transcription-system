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
        let coord = CaptureCoordinator(spoolDir: tmp, sessions: tracker)
        await coord.handleBoundary(now: 2000.0)
        let next = await tracker.currentSessionStartedAt
        #expect(next == 2000.0)
        let stateRaw = (try? String(contentsOf: tmp.appendingPathComponent("state.jsonl"), encoding: .utf8)) ?? ""
        let lines = stateRaw.split(separator: "\n").map(String.init)
        let finalized = lines.first { $0.contains("session_finalized") }
        #expect(finalized != nil)
        #expect(finalized?.contains("\"session_started_at\":1000") == true)
        let started = lines.first { $0.contains("session_started") && $0.contains("\"session_started_at\":2000") }
        #expect(started != nil)
    }
}

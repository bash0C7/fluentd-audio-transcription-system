// swift/swiftcap/Tests/SwiftcapTests/SessionTrackerTests.swift
import Foundation
import Testing
@testable import Swiftcap

// Note: @available cannot be applied to @Suite/@Test directly (Swift Testing
// macro restriction). Each test guards SessionTracker usage with
// `guard #available(macOS 26.0, *) else { return }` instead.
@Suite
struct SessionTrackerTests {
    @Test
    func initialStateRecordingNotMuted() async {
        guard #available(macOS 26.0, *) else { return }
        let t = SessionTracker(now: 1000.0)
        let started = await t.currentSessionStartedAt
        #expect(started == 1000.0)
        let muted = await t.isMicMuted
        #expect(!muted)
    }

    @Test
    func rolloverAdvancesStartedAt() async {
        guard #available(macOS 26.0, *) else { return }
        let t = SessionTracker(now: 1000.0)
        let prev = await t.rollover(now: 1500.0)
        #expect(prev == 1000.0)
        let next = await t.currentSessionStartedAt
        #expect(next == 1500.0)
    }

    @Test
    func muteToggleFlipsFlag() async {
        guard #available(macOS 26.0, *) else { return }
        let t = SessionTracker(now: 1000.0)
        let after1 = await t.toggleMute()
        #expect(after1 == true)
        let after2 = await t.toggleMute()
        #expect(after2 == false)
    }

    @Test
    func rolloverPreservesMuteState() async {
        guard #available(macOS 26.0, *) else { return }
        let t = SessionTracker(now: 1000.0)
        _ = await t.toggleMute()
        _ = await t.rollover(now: 2000.0)
        let muted = await t.isMicMuted
        #expect(muted, "mute state should survive session rollover")
    }
}

// swift/swiftcap/Sources/Swiftcap/SessionTracker.swift
import Foundation

@available(macOS 26.0, *)
actor SessionTracker {
    private(set) var currentSessionStartedAt: TimeInterval
    private(set) var isMicMuted: Bool = false

    init(now: TimeInterval = Date().timeIntervalSince1970) {
        self.currentSessionStartedAt = now
    }

    /// Advances to a new session. Returns the previous session's started_at
    /// so the caller can emit a session_finalized event for it.
    func rollover(now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        let prev = currentSessionStartedAt
        currentSessionStartedAt = now
        return prev
    }

    /// Flips the mute flag and returns the new value.
    func toggleMute() -> Bool {
        isMicMuted.toggle()
        return isMicMuted
    }
}

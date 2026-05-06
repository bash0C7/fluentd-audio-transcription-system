// swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorChannelFailureTests.swift
import Foundation
import Testing
@testable import Swiftcap

@available(macOS 26.0, *)
@Suite
struct CaptureCoordinatorChannelFailureTests {
    private func makeTmpDir() -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func readStateLines(_ dir: URL) -> [[String: Any]] {
        let url = dir.appendingPathComponent("state.jsonl")
        guard let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8) else { return [] }
        return str.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
    }

    @Test
    func handleScreenStreamStopped_emitsChannelFailedEvent() async throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coord = CaptureCoordinator(spoolDir: tmp)
        await coord.markScreenActiveForTesting()

        let err = NSError(domain: "test", code: -3815, userInfo: [NSLocalizedDescriptionKey: "no display"])
        await coord.handleScreenStreamStopped(error: err)

        let events = readStateLines(tmp).filter { ($0["kind"] as? String) == "channel_failed" }
        #expect(events.count == 1)
        #expect((events.first?["channel"] as? String) == "screen")
        #expect((events.first?["reason"] as? String) == "scstream_error")
    }

    @Test
    func handleScreenStreamStopped_isIdempotent() async throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coord = CaptureCoordinator(spoolDir: tmp)
        await coord.markScreenActiveForTesting()

        let err = NSError(domain: "test", code: -3815, userInfo: nil)
        await coord.handleScreenStreamStopped(error: err)
        await coord.handleScreenStreamStopped(error: err)

        let events = readStateLines(tmp).filter { ($0["kind"] as? String) == "channel_failed" }
        #expect(events.count == 1, "second call must be no-op (no duplicate channel_failed)")
    }

    @Test
    func handleScreenStreamStopped_isNoOpWhenScreenInactive() async throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coord = CaptureCoordinator(spoolDir: tmp)
        // never mark active

        let err = NSError(domain: "test", code: -3815, userInfo: nil)
        await coord.handleScreenStreamStopped(error: err)

        let events = readStateLines(tmp).filter { ($0["kind"] as? String) == "channel_failed" }
        #expect(events.isEmpty, "must not emit channel_failed when screen channel was never active")
    }
}

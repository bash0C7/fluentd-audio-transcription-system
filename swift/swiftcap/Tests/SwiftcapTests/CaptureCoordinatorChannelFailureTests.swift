import Foundation
import Testing
@testable import Swiftcap

@Suite
struct CaptureCoordinatorChannelFailureTests {
    private func makeTmpDir() -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test
    func handleScreenStreamStopped_emitsChannelFailedEvent() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let emitter = CapturingEmitter()
        let coord = CaptureCoordinator(spoolDir: tmp, emitter: emitter)
        await coord.markScreenActiveForTesting()
        let err = NSError(domain: "test", code: -3815, userInfo: [NSLocalizedDescriptionKey: "no display"])
        await coord.handleScreenStreamStopped(error: err)
        let events = emitter.filter(stream: "state").filter { ($0["kind"] as? String) == "channel_failed" }
        #expect(events.count == 1)
        #expect((events.first?["channel"] as? String) == "screen")
        #expect((events.first?["reason"] as? String) == "scstream_error")
    }

    @Test
    func handleScreenStreamStopped_isIdempotent() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let emitter = CapturingEmitter()
        let coord = CaptureCoordinator(spoolDir: tmp, emitter: emitter)
        await coord.markScreenActiveForTesting()
        let err = NSError(domain: "test", code: -3815, userInfo: nil)
        await coord.handleScreenStreamStopped(error: err)
        await coord.handleScreenStreamStopped(error: err)
        let events = emitter.filter(stream: "state").filter { ($0["kind"] as? String) == "channel_failed" }
        #expect(events.count == 1, "second call must be no-op (no duplicate channel_failed)")
    }

    @Test
    func handleScreenStreamStopped_isNoOpWhenScreenInactive() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let emitter = CapturingEmitter()
        let coord = CaptureCoordinator(spoolDir: tmp, emitter: emitter)
        let err = NSError(domain: "test", code: -3815, userInfo: nil)
        await coord.handleScreenStreamStopped(error: err)
        let events = emitter.filter(stream: "state").filter { ($0["kind"] as? String) == "channel_failed" }
        #expect(events.isEmpty, "must not emit channel_failed when screen channel was never active")
    }
}

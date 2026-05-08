# Slim swiftcap stdio + unix socket I/O — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace swiftcap's `spool/*.jsonl` + `.pos.*` file interchange with a one-way stdout JSON-line stream and a single unix domain socket (`spool/swiftcap.sock`) for control / ack / retranscribe-emit. Keep swiftcap as the TCC anchor; move the surrounding plumbing into a new `in_swiftcap` fluentd input plugin. Eliminate the legacy paths entirely (no compat shims).

**Architecture:** swiftcap (Swift binary, owns `Info.plist`-based TCC consent) is spawned as a fluentd child. swiftcap writes records to stdout as `{"stream":"quick"|"final"|"sound"|"state", …}` JSON lines; in_swiftcap reads them and routes to `audio.<stream>` tags. swiftcap listens on `spool/swiftcap.sock` (NWListener `.unix`) for boundary / mute / ack / emit commands. `swiftcap retranscribe` connects to the same socket as a one-shot client. fluentd's data flow becomes pure 1-way ingest; no back-channel through fluentd.

**Tech Stack:** Swift 6.3 (`Foundation`, `Network.framework`), Ruby 4.0.3, fluentd 1.18, Test::Unit / `fluent-test-driver`, swift-testing (`@Suite` / `@Test`).

**Reference spec:** `docs/superpowers/specs/2026-05-08-slim-swiftcap-stdio-design.md`

---

## File map

### New files

| Path | Purpose |
| --- | --- |
| `swift/swiftcap/Sources/Swiftcap/StdoutEmitter.swift` | `RecordEmitter` protocol + `StdoutEmitter` concrete — emit JSON line to `FileHandle.standardOutput` |
| `swift/swiftcap/Sources/Swiftcap/ControlSocket.swift` | `NWListener.using(.unix(…))` server that dispatches socket lines to coordinator + emitter |
| `swift/swiftcap/Sources/Swiftcap/ControlSocketClient.swift` | Tiny client used by `RetranscribeCommand` to write `{"kind":"emit",…}` lines |
| `swift/swiftcap/Tests/SwiftcapTests/StdoutEmitterTests.swift` | TDD test for `StdoutEmitter` via a `Pipe`-driven file handle |
| `swift/swiftcap/Tests/SwiftcapTests/ControlSocketTests.swift` | TDD test for `ControlSocket` via tmp socket path |
| `swift/swiftcap/Tests/SwiftcapTests/ControlSocketClientTests.swift` | TDD test for client by pairing it with a tmp listener |
| `lib/fluent/plugin/in_swiftcap.rb` | New fluentd input plugin — spawns swiftcap, reads stdout, emits records |
| `test/fluent/test_in_swiftcap.rb` | TDD test for in_swiftcap with a fake stub binary |

### Deleted files

| Path | Reason |
| --- | --- |
| `swift/swiftcap/Sources/Swiftcap/SpoolWriter.swift` | Replaced by `StdoutEmitter` |
| `swift/swiftcap/Sources/Swiftcap/ControlReader.swift` | Replaced by `ControlSocket` |
| `swift/swiftcap/Sources/Swiftcap/AckReader.swift` | Replaced by `ControlSocket` ack handler |
| `swift/swiftcap/Tests/SwiftcapTests/SpoolWriterTests.swift` | Source removed |
| `swift/swiftcap/Tests/SwiftcapTests/ControlReaderTests.swift` | Source removed |
| `swift/swiftcap/Tests/SwiftcapTests/AckReaderTests.swift` | Source removed |
| `plists/dev.bash0c7.audio-transcription.swiftcap.plist.erb` | swiftcap is no longer a standalone launchd job |

### Modified files

| Path | Change |
| --- | --- |
| `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift` | Replace 4 `SpoolWriter` instances with one injected `RecordEmitter`; route by `stream:` parameter |
| `swift/swiftcap/Sources/Swiftcap/Swiftcap.swift` | Remove `ControlReader` Task and `AckReader` polling Task; wire `ControlSocket`; emit `state.swiftcap_ready` |
| `swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift` | Replace `SpoolWriter` writes with `ControlSocketClient.emit(stream:record:)`; loud stderr + non-zero exit on connect failure |
| `swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift` | Switch fixture assertion target from spool files to a tmp listener that captures emit records |
| `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorBoundaryTests.swift` | Inject `CapturingEmitter` instead of using a tmp spool dir |
| `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorChannelFailureTests.swift` | Same |
| `swift/swiftcap/Tests/SwiftcapTests/SessionTrackerTests.swift` | Same (if it touches writers) |
| `lib/fluent/plugin/out_sqlite_meeting_log.rb` | Replace `ack.jsonl` append with `UNIXSocket.open(swiftcap_socket_path)` write; rename config key |
| `test/fluent/test_out_sqlite_meeting_log.rb` | Switch ack assertion from `ack.jsonl` lines to a tmp listener |
| `web/app.rb` | `append_control` becomes `socket_control_send` writing to `swiftcap_socket_path` (env: `SWIFTCAP_SOCKET_PATH`) |
| `test/web/test_session_control_routes.rb` | Switch boundary/mute assertion from `control.jsonl` to a tmp listener |
| `config/fluent.conf` | Replace 4 `<source @type tail>` blocks with one `<source @type swiftcap>`; rename `ack_path` → `swiftcap_socket_path` |
| `Rakefile` | Delete `start:swiftcap` / `stop:swiftcap`; update `start:all`; remove `swiftcap` from `WAIT_SEC` |
| `scripts/setup.rb` | Drop swiftcap plist generation; only render fluentd + web plists |
| `lib/audio_transcription/synthetic_e5.rb` | `count_rotated` reads `audio_segments` rows; `count_ack` checks CAF deletion (file no longer exists); `verify_l5_processes` no longer checks `swiftcap` pid |
| `README.md` | Full rewrite of Architecture, Running, Setup, Design Choices sections |

---

## Stdout protocol reference (used in tasks below)

A swiftcap stdout line is exactly one JSON object plus `\n`, written via a single `FileHandle.standardOutput.write` call:

```
{"stream":"quick"|"final"|"sound"|"state", <…all current row fields…>}
```

The outer `stream` field selects the fluentd tag (`audio.<stream>`); every other field is identical to today's per-file row schema.

## Socket protocol reference

```
{"kind":"boundary"}
{"kind":"mute_toggle"}
{"kind":"ack","paths":["/abs/path/foo.caf", …]}
{"kind":"emit","stream":"final"|"state","record":{…full record…}}
```

For `kind:"emit"`, swiftcap writes `{"stream": <stream>, …record fields…}` to its own stdout (re-emission).

---

## Phase A — swiftcap Swift side

### Task 1: RecordEmitter protocol + StdoutEmitter

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/StdoutEmitter.swift`
- Create: `swift/swiftcap/Tests/SwiftcapTests/StdoutEmitterTests.swift`

- [ ] **Step 1: RED — write the failing test**

Create `swift/swiftcap/Tests/SwiftcapTests/StdoutEmitterTests.swift`:

```swift
import Foundation
import Testing
@testable import Swiftcap

@Suite("StdoutEmitterTests")
struct StdoutEmitterTests {
    @Test
    func emitsJsonLineWithStreamFieldAndTrailingNewline() throws {
        let pipe = Pipe()
        let emitter = StdoutEmitter(handle: pipe.fileHandleForWriting)
        emitter.emit(stream: "quick", record: ["ts": 1.0, "ch": "mic", "text": "hi"])
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
        let obj = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(obj?["stream"] as? String == "quick")
        #expect(obj?["ch"] as? String == "mic")
        #expect(obj?["text"] as? String == "hi")
        #expect(s.hasSuffix("\n"))
    }

    @Test
    func emitsTwoLinesAsTwoSyscalls() throws {
        let pipe = Pipe()
        let emitter = StdoutEmitter(handle: pipe.fileHandleForWriting)
        emitter.emit(stream: "state", record: ["ts": 1.0, "kind": "session_started"])
        emitter.emit(stream: "final", record: ["ts": 2.0, "ch": "mic", "kind": "final", "text": "ok"])
        try pipe.fileHandleForWriting.close()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd swift/swiftcap && swift test --filter StdoutEmitterTests 2>&1 | tail -20
```

Expected: build error — `StdoutEmitter` not found.

- [ ] **Step 3: Commit RED**

```bash
git add swift/swiftcap/Tests/SwiftcapTests/StdoutEmitterTests.swift
git commit -m "test: add failing spec for StdoutEmitter (Phase A.1 RED)"
```

- [ ] **Step 4: GREEN — minimal implementation**

Create `swift/swiftcap/Sources/Swiftcap/StdoutEmitter.swift`:

```swift
// swift/swiftcap/Sources/Swiftcap/StdoutEmitter.swift
import Foundation

protocol RecordEmitter: Sendable {
    func emit(stream: String, record: [String: Any])
}

final class StdoutEmitter: RecordEmitter, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle = FileHandle.standardOutput) {
        self.handle = handle
    }

    func emit(stream: String, record: [String: Any]) {
        var withStream = record
        withStream["stream"] = stream
        guard let data = try? JSONSerialization.data(withJSONObject: withStream, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: line)
    }
}

final class CapturingEmitter: RecordEmitter, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(stream: String, record: [String: Any])] = []

    func emit(stream: String, record: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        records.append((stream, record))
    }

    func snapshot() -> [(stream: String, record: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    func filter(stream: String) -> [[String: Any]] {
        snapshot().filter { $0.stream == stream }.map { $0.record }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd swift/swiftcap && swift test --filter StdoutEmitterTests 2>&1 | tail -20
```

Expected: PASS (2 tests).

- [ ] **Step 6: Commit GREEN**

```bash
git add swift/swiftcap/Sources/Swiftcap/StdoutEmitter.swift
git commit -m "feat(swiftcap): add StdoutEmitter + CapturingEmitter (Phase A.1 GREEN)"
```

---

### Task 2: CaptureCoordinator accepts injected RecordEmitter

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`
- Modify: `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorBoundaryTests.swift`
- Modify: `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorChannelFailureTests.swift`

- [ ] **Step 1: RED — convert one existing CaptureCoordinator test to use CapturingEmitter**

Read `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorBoundaryTests.swift` and pick the smallest test that asserts on a spool file. Replace its tmp-spool-dir + file-read assertion with construction of `CapturingEmitter()`, passing it into `CaptureCoordinator(spoolDir:emitter:sessions:)`, and asserting on `emitter.filter(stream: "state")` for the rotated/session_finalized/session_started events.

Example pattern (apply to whichever test currently asserts state.jsonl content):

```swift
let emitter = CapturingEmitter()
let coord = CaptureCoordinator(spoolDir: tmp, emitter: emitter)
// … exercise …
let stateRows = emitter.filter(stream: "state")
#expect(stateRows.contains { $0["kind"] as? String == "rotated" })
```

- [ ] **Step 2: Run the converted test to verify it fails**

```bash
cd swift/swiftcap && swift test --filter CaptureCoordinatorBoundary 2>&1 | tail -20
```

Expected: build error — `CaptureCoordinator` doesn't accept `emitter:`.

- [ ] **Step 3: Commit RED**

```bash
git add swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorBoundaryTests.swift
git commit -m "test: drive CaptureCoordinator with injected RecordEmitter (Phase A.2 RED)"
```

- [ ] **Step 4: GREEN — modify CaptureCoordinator to accept and use a RecordEmitter**

Edit `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`:

1. Add init parameter: `init(spoolDir: URL, emitter: RecordEmitter, sessions: SessionTracker = SessionTracker())`.
2. Replace `private var stateWriter: SpoolWriter`, `private let quickWriter: SpoolWriter`, `private let finalWriter: SpoolWriter`, `private let soundWriter: SpoolWriter` with a single `private let emitter: RecordEmitter`.
3. In `init`, store `self.emitter = emitter`. Remove the four `SpoolWriter(url: …)` calls.
4. Replace every `try? stateWriter.append([…])` with `emitter.emit(stream: "state", record: [...])`. Same for `quickWriter` → `stream:"quick"`, `finalWriter` → `stream:"final"`, `soundWriter` → `stream:"sound"`.
5. Pass `emitter` (instead of writer arguments) into `TranscriberWrapper.init`. Modify `TranscriberWrapper` to take `emitter: RecordEmitter` and replace its two `try? quickWriter.append(...)` / `try? finalWriter.append(...)` calls with `emitter.emit(stream:"quick"|"final", record:[...])`. Remove the `quickWriter`/`finalWriter` properties.
6. Same for `SoundAnalyzerWrapper` if it currently takes a `SpoolWriter`. Switch its constructor to take `emitter: RecordEmitter` and call `emitter.emit(stream:"sound", record:[...])`.

- [ ] **Step 5: Update the other CaptureCoordinator tests that still construct it the old way**

Grep for `CaptureCoordinator(spoolDir:` and update each call site to pass an `emitter:`. Most will use `CapturingEmitter()`. The integration in `Swiftcap.swift` is fixed in Task 5.

```bash
grep -rn 'CaptureCoordinator(spoolDir:' swift/swiftcap/
```

- [ ] **Step 6: Run all swift tests to verify**

```bash
cd swift/swiftcap && swift test 2>&1 | tail -30
```

Expected: PASS (all CaptureCoordinator + Wrapper tests; SpoolWriter / ControlReader / AckReader tests still pass since they're unchanged at this point).

- [ ] **Step 7: Commit GREEN**

```bash
git add swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift \
        swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift \
        swift/swiftcap/Sources/Swiftcap/SoundAnalyzerWrapper.swift \
        swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorBoundaryTests.swift \
        swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorChannelFailureTests.swift \
        swift/swiftcap/Tests/SwiftcapTests/SessionTrackerTests.swift
git commit -m "feat(swiftcap): CaptureCoordinator emits via RecordEmitter (Phase A.2 GREEN)"
```

---

### Task 3: ControlSocket — NWListener `.unix` server

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/ControlSocket.swift`
- Create: `swift/swiftcap/Tests/SwiftcapTests/ControlSocketTests.swift`

- [ ] **Step 1: RED — write failing test**

Create `swift/swiftcap/Tests/SwiftcapTests/ControlSocketTests.swift`:

```swift
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
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctrl-sock-\(UUID().uuidString).sock")
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
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctrl-stale-\(UUID().uuidString).sock")
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd swift/swiftcap && swift test --filter ControlSocketTests 2>&1 | tail -20
```

Expected: build error — `ControlSocket` not found.

- [ ] **Step 3: Commit RED**

```bash
git add swift/swiftcap/Tests/SwiftcapTests/ControlSocketTests.swift
git commit -m "test: add failing spec for ControlSocket (Phase A.3 RED)"
```

- [ ] **Step 4: GREEN — implement ControlSocket**

Create `swift/swiftcap/Sources/Swiftcap/ControlSocket.swift`:

```swift
// swift/swiftcap/Sources/Swiftcap/ControlSocket.swift
import Foundation
import Network

@available(macOS 26.0, *)
final class ControlSocket: @unchecked Sendable {
    private let socketPath: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "swiftcap.controlsocket")

    init(socketPath: String) throws {
        self.socketPath = socketPath
        // Unlink stale file so bind succeeds.
        try? FileManager.default.removeItem(atPath: socketPath)
        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = endpoint
        self.listener = try NWListener(using: params)
    }

    func start(
        onBoundary: @escaping @Sendable () -> Void,
        onMuteToggle: @escaping @Sendable () -> Void,
        onAck: @escaping @Sendable ([String]) -> Void,
        emitter: RecordEmitter
    ) throws {
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn,
                onBoundary: onBoundary,
                onMuteToggle: onMuteToggle,
                onAck: onAck,
                emitter: emitter)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func accept(
        _ conn: NWConnection,
        onBoundary: @escaping @Sendable () -> Void,
        onMuteToggle: @escaping @Sendable () -> Void,
        onAck: @escaping @Sendable ([String]) -> Void,
        emitter: RecordEmitter
    ) {
        let buffer = Buffer()
        conn.start(queue: queue)
        receive(conn, buffer: buffer,
                onBoundary: onBoundary,
                onMuteToggle: onMuteToggle,
                onAck: onAck,
                emitter: emitter)
    }

    private func receive(
        _ conn: NWConnection,
        buffer: Buffer,
        onBoundary: @escaping @Sendable () -> Void,
        onMuteToggle: @escaping @Sendable () -> Void,
        onAck: @escaping @Sendable ([String]) -> Void,
        emitter: RecordEmitter
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                buffer.append(data)
                while let line = buffer.takeLine() {
                    self?.dispatch(line: line,
                                   onBoundary: onBoundary,
                                   onMuteToggle: onMuteToggle,
                                   onAck: onAck,
                                   emitter: emitter)
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self?.receive(conn, buffer: buffer,
                          onBoundary: onBoundary,
                          onMuteToggle: onMuteToggle,
                          onAck: onAck,
                          emitter: emitter)
        }
    }

    private func dispatch(
        line: Data,
        onBoundary: @Sendable () -> Void,
        onMuteToggle: @Sendable () -> Void,
        onAck: @Sendable ([String]) -> Void,
        emitter: RecordEmitter
    ) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        switch obj["kind"] as? String {
        case "boundary":
            onBoundary()
        case "mute_toggle":
            onMuteToggle()
        case "ack":
            if let paths = obj["paths"] as? [String] { onAck(paths) }
        case "emit":
            if let stream = obj["stream"] as? String,
               let record = obj["record"] as? [String: Any] {
                emitter.emit(stream: stream, record: record)
            }
        default:
            FileHandle.standardError.write(
                "ControlSocket: unknown kind \(obj)\n".data(using: .utf8)!)
        }
    }

    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }
        func takeLine() -> Data? {
            lock.lock(); defer { lock.unlock() }
            guard let nl = data.firstIndex(of: 0x0A) else { return nil }
            let line = data[data.startIndex..<nl]
            data = data[data.index(after: nl)...]
            return Data(line)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd swift/swiftcap && swift test --filter ControlSocketTests 2>&1 | tail -20
```

Expected: PASS (2 tests).

- [ ] **Step 6: Commit GREEN**

```bash
git add swift/swiftcap/Sources/Swiftcap/ControlSocket.swift
git commit -m "feat(swiftcap): add ControlSocket NWListener .unix server (Phase A.3 GREEN)"
```

---

### Task 4: ControlSocketClient — line writer to swiftcap.sock

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/ControlSocketClient.swift`
- Create: `swift/swiftcap/Tests/SwiftcapTests/ControlSocketClientTests.swift`

- [ ] **Step 1: RED — failing test**

Create `swift/swiftcap/Tests/SwiftcapTests/ControlSocketClientTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd swift/swiftcap && swift test --filter ControlSocketClientTests 2>&1 | tail -20
```

Expected: build error — `ControlSocketClient` not found.

- [ ] **Step 3: Commit RED**

```bash
git add swift/swiftcap/Tests/SwiftcapTests/ControlSocketClientTests.swift
git commit -m "test: add failing spec for ControlSocketClient (Phase A.4 RED)"
```

- [ ] **Step 4: GREEN — implement ControlSocketClient**

Create `swift/swiftcap/Sources/Swiftcap/ControlSocketClient.swift`. Use a synchronous BSD `socket` + `connect` + `write` for simplicity — the client is short-lived and we don't need NWConnection overhead:

```swift
// swift/swiftcap/Sources/Swiftcap/ControlSocketClient.swift
import Foundation
import Darwin

@available(macOS 26.0, *)
final class ControlSocketClient {
    private let fd: Int32

    init(socketPath: String) throws {
        let f = socket(AF_UNIX, SOCK_STREAM, 0)
        guard f >= 0 else {
            throw NSError(domain: "ControlSocketClient", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(String(cString: strerror(errno)))"])
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(f)
            throw NSError(domain: "ControlSocketClient", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"])
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            for (i, b) in pathBytes.enumerated() {
                rawBuf[i] = b
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(f, sa, len)
            }
        }
        guard rc == 0 else {
            let err = String(cString: strerror(errno))
            close(f)
            throw NSError(domain: "ControlSocketClient", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "connect() to \(socketPath) failed: \(err)"])
        }
        self.fd = f
    }

    func emit(stream: String, record: [String: Any]) throws {
        let payload: [String: Any] = ["kind": "emit", "stream": stream, "record": record]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try writeAll(line)
    }

    func sendBoundary() throws { try writeKind("boundary") }
    func sendMuteToggle() throws { try writeKind("mute_toggle") }
    func sendAck(paths: [String]) throws {
        let payload: [String: Any] = ["kind": "ack", "paths": paths]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try writeAll(line)
    }

    private func writeKind(_ kind: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["kind": kind], options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try writeAll(line)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buf in
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), remaining)
                if written < 0 {
                    throw NSError(domain: "ControlSocketClient", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "write() failed: \(String(cString: strerror(errno)))"])
                }
                offset += written
                remaining -= written
            }
        }
    }

    func close() {
        Darwin.close(fd)
    }

    deinit { close() }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd swift/swiftcap && swift test --filter ControlSocketClientTests 2>&1 | tail -20
```

Expected: PASS (2 tests).

- [ ] **Step 6: Commit GREEN**

```bash
git add swift/swiftcap/Sources/Swiftcap/ControlSocketClient.swift
git commit -m "feat(swiftcap): add ControlSocketClient (Phase A.4 GREEN)"
```

---

### Task 5: Wire ControlSocket into Swiftcap.swift main + emit swiftcap_ready

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/Swiftcap.swift`

This task is integration wiring; existing tests don't fail without it because `Swiftcap.swift` (the `@main`) is not unit-tested. The acceptance gate is `swift build -c release` succeeding. Single commit.

- [ ] **Step 1: Edit `Swiftcap.swift`**

Replace the file's contents with this version (the changes vs. the original: drop `AckReader`/`ControlReader` + their polling tasks, instantiate `StdoutEmitter` and pass it to the coordinator and to a `ControlSocket`, emit `swiftcap_ready` after `coordinator.start` returns):

```swift
// swift/swiftcap/Sources/Swiftcap/Swiftcap.swift
import Foundation

@available(macOS 26.0, *)
@main
struct Swiftcap {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv.first == "retranscribe" {
            let subArgs = Array(argv.dropFirst())
            guard let cmd = RetranscribeCommand.parse(args: subArgs) else {
                FileHandle.standardError.write("usage: swiftcap retranscribe --session-id N [--locale ja-JP] [--pass 2]\n".data(using: .utf8)!)
                exit(2)
            }
            let socketPath = ProcessInfo.processInfo.environment["SWIFTCAP_SOCKET_PATH"]
                ?? defaultSocketPath()
            let dbPath = ProcessInfo.processInfo.environment["DB_PATH"] ?? "db/meeting_log.sqlite"
            do {
                try await cmd.run(dbPath: dbPath, socketPath: socketPath)
                exit(0)
            } catch {
                FileHandle.standardError.write("retranscribe failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        let spoolDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWIFTCAP_SPOOL"]
            ?? NSString(string: "~/Library/Application Support/audio-transcription/spool").expandingTildeInPath)
        let socketPath = ProcessInfo.processInfo.environment["SWIFTCAP_SOCKET_PATH"]
            ?? spoolDir.appendingPathComponent("swiftcap.sock").path
        let locale = Locale(identifier: ProcessInfo.processInfo.environment["SWIFTCAP_LOCALE"] ?? "ja-JP")

        FileHandle.standardError.write(
            "swiftcap starting spool=\(spoolDir.path) socket=\(socketPath) locale=\(locale.identifier)\n".data(using: .utf8)!)

        let emitter = StdoutEmitter()
        let coordinator = CaptureCoordinator(spoolDir: spoolDir, emitter: emitter)

        do {
            try await coordinator.start(locale: locale)
        } catch {
            FileHandle.standardError.write("startup failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        // Open the socket before announcing readiness so any client (web,
        // out_sqlite_meeting_log, retranscribe) that connects right after
        // ready will be accepted.
        let controlSocket: ControlSocket
        do {
            controlSocket = try ControlSocket(socketPath: socketPath)
            try controlSocket.start(
                onBoundary: { Task { await coordinator.handleBoundary() } },
                onMuteToggle: { Task { await coordinator.handleMuteToggle() } },
                onAck: { paths in Task { await coordinator.acknowledgeAndDelete(paths: paths) } },
                emitter: emitter
            )
        } catch {
            FileHandle.standardError.write("controlsocket failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        emitter.emit(stream: "state", record: [
            "ts": Date().timeIntervalSince1970,
            "kind": "swiftcap_ready"
        ])
        FileHandle.standardError.write("swiftcap ready\n".data(using: .utf8)!)

        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        hupSource.setEventHandler { Task { await coordinator.rotateAll(reason: "hup") } }
        signal(SIGHUP, SIG_IGN)
        hupSource.resume()

        let shutdown: @Sendable () -> Void = {
            Task {
                FileHandle.standardError.write("shutdown: stopping engines + rotating\n".data(using: .utf8)!)
                await coordinator.shutdownRotate(reason: "shutdown")
                controlSocket.stop()
                FileHandle.standardError.write("shutdown: done, exiting\n".data(using: .utf8)!)
                exit(0)
            }
        }

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler(handler: shutdown)
        signal(SIGTERM, SIG_IGN)
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSource.setEventHandler(handler: shutdown)
        signal(SIGINT, SIG_IGN)
        intSource.resume()

        try? await Task.sleep(nanoseconds: UInt64.max)
    }

    private static func defaultSocketPath() -> String {
        let spool = ProcessInfo.processInfo.environment["SWIFTCAP_SPOOL"]
            ?? NSString(string: "~/Library/Application Support/audio-transcription/spool").expandingTildeInPath
        return URL(fileURLWithPath: spool).appendingPathComponent("swiftcap.sock").path
    }
}
```

- [ ] **Step 2: Run swift build to verify**

```bash
cd swift/swiftcap && swift build -c release 2>&1 | tail -10
```

Expected: build succeeds. (Tests still pass because the integration uses interfaces verified in Tasks 1–4.)

- [ ] **Step 3: Commit**

```bash
git add swift/swiftcap/Sources/Swiftcap/Swiftcap.swift
git commit -m "feat(swiftcap): wire ControlSocket + StdoutEmitter into main, emit swiftcap_ready"
```

---

### Task 6: RetranscribeCommand → ControlSocketClient

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift`
- Modify: `swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift`

- [ ] **Step 1: RED — rewrite the fixture test to assert via socket listener**

Replace `runForFixtureWritesFinalJsonlPass2` in `swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift` with:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd swift/swiftcap && swift test --filter RetranscribeCommandTests/runForFixtureEmitsFinalAndRetranscribeDoneViaSocket 2>&1 | tail -20
```

Expected: build error — `runForFixture(audioFiles:socketPath:)` not found.

- [ ] **Step 3: Commit RED**

```bash
git add swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift
git commit -m "test: drive RetranscribeCommand via socket emit (Phase A.6 RED)"
```

- [ ] **Step 4: GREEN — modify RetranscribeCommand**

Edit `swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift`:

1. Replace `func run(dbPath:spoolDir:)` with `func run(dbPath: String, socketPath: String)`. The fixture-extraction logic is unchanged; pass `socketPath` to `runForFixture`.
2. Replace `func runForFixture(audioFiles:spoolDir:)` with `func runForFixture(audioFiles: [URL], socketPath: String)`.
3. Inside `runForFixture`, delete the `SpoolWriter(url: spoolDir.appendingPathComponent("final.jsonl"))` and `SpoolWriter(url: spoolDir.appendingPathComponent("state.jsonl"))` lines.
4. After the `do { try await Self.ensureModelInstalled… } catch { … }` block, replace the `try stateWriter.append([...])` call with:

   ```swift
   let client: ControlSocketClient
   do {
       client = try ControlSocketClient(socketPath: socketPath)
   } catch {
       FileHandle.standardError.write("retranscribe: cannot connect to \(socketPath): \(error)\n".data(using: .utf8)!)
       throw error
   }
   defer { client.close() }
   try? client.emit(stream: "state", record: [
       "ts": Date().timeIntervalSince1970,
       "kind": "retranscribe_done",
       "session_id": sessionId
   ])
   return
   ```

5. Move the `ControlSocketClient` instantiation to the start of the success path too. After `let texts = try await collectTask.value`, replace the loop:

   ```swift
   let client = try ControlSocketClient(socketPath: socketPath)
   defer { client.close() }
   for text in texts {
       try? client.emit(stream: "final", record: [
           "ts": Date().timeIntervalSince1970,
           "kind": "final",
           "ch": "mic",
           "text": text,
           "language": locale.identifier(.bcp47),
           "pass": pass,
           "session_id": sessionId
       ])
   }
   try? client.emit(stream: "state", record: [
       "ts": Date().timeIntervalSince1970,
       "kind": "retranscribe_done",
       "session_id": sessionId
   ])
   ```

   (Top-level fail-fast on connect — propagate the error out so `Swiftcap.swift`'s retranscribe entry exits non-zero.)

- [ ] **Step 5: Update the `Swiftcap.swift` retranscribe path to pass `socketPath:`**

Already done in Task 5 (`try await cmd.run(dbPath:dbPath, socketPath:socketPath)`).

- [ ] **Step 6: Run all swift tests to verify**

```bash
cd swift/swiftcap && swift test 2>&1 | tail -30
```

Expected: PASS (RetranscribeCommandTests + everything else built so far).

- [ ] **Step 7: Commit GREEN**

```bash
git add swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift
git commit -m "feat(swiftcap): RetranscribeCommand emits via ControlSocketClient (Phase A.6 GREEN)"
```

---

### Task 7: Delete legacy Swift sources + tests

**Files:**
- Delete: `swift/swiftcap/Sources/Swiftcap/SpoolWriter.swift`
- Delete: `swift/swiftcap/Sources/Swiftcap/ControlReader.swift`
- Delete: `swift/swiftcap/Sources/Swiftcap/AckReader.swift`
- Delete: `swift/swiftcap/Tests/SwiftcapTests/SpoolWriterTests.swift`
- Delete: `swift/swiftcap/Tests/SwiftcapTests/ControlReaderTests.swift`
- Delete: `swift/swiftcap/Tests/SwiftcapTests/AckReaderTests.swift`

Single-commit cleanup; nothing references these after Tasks 1–6.

- [ ] **Step 1: Delete the files**

```bash
git rm swift/swiftcap/Sources/Swiftcap/SpoolWriter.swift \
       swift/swiftcap/Sources/Swiftcap/ControlReader.swift \
       swift/swiftcap/Sources/Swiftcap/AckReader.swift \
       swift/swiftcap/Tests/SwiftcapTests/SpoolWriterTests.swift \
       swift/swiftcap/Tests/SwiftcapTests/ControlReaderTests.swift \
       swift/swiftcap/Tests/SwiftcapTests/AckReaderTests.swift
```

- [ ] **Step 2: Run all swift tests to confirm nothing broke**

```bash
cd swift/swiftcap && swift test 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git commit -m "chore(swiftcap): remove SpoolWriter / ControlReader / AckReader and their tests"
```

---

## Phase B — fluentd Ruby side

### Task 8: in_swiftcap fluentd input plugin

**Files:**
- Create: `lib/fluent/plugin/in_swiftcap.rb`
- Create: `test/fluent/test_in_swiftcap.rb`

The plugin will be tested with a small "fake binary" — a shell script that writes a deterministic sequence of stdout JSON lines and stays alive. The plugin must (a) parse and emit each line, (b) wait for `swiftcap_ready` before reporting itself ready, (c) drain stderr to the logger, (d) SIGTERM + wait the child on shutdown.

- [ ] **Step 1: RED — write the failing test**

Create `test/fluent/test_in_swiftcap.rb`:

```ruby
# test/fluent/test_in_swiftcap.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/input'
require 'fluent/plugin/in_swiftcap'
require 'tmpdir'
require 'fileutils'
require 'json'

class TestInSwiftcap < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('in-swiftcap-')
    @bin = File.join(@tmp, 'fake_swiftcap')
    File.write(@bin, <<~SH)
      #!/usr/bin/env bash
      echo '{"stream":"state","ts":1.0,"kind":"swiftcap_ready"}'
      echo '{"stream":"quick","ts":2.0,"ch":"mic","kind":"volatile","text":"hi","transcript_id":"u1","session_started_at":0.0}'
      echo '{"stream":"final","ts":3.0,"ch":"mic","kind":"final","text":"hi.","started_at":1.0,"ended_at":2.0,"language":"ja-JP","transcript_id":"u1","session_started_at":0.0}'
      # Stay alive so the plugin can SIGTERM us at shutdown.
      trap 'exit 0' TERM
      sleep 30
    SH
    FileUtils.chmod(0o755, @bin)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver
    config = %(
      swiftcap_bin #{@bin}
      spool_dir #{@tmp}
      socket_path #{File.join(@tmp, 'swiftcap.sock')}
      ready_timeout 10
    )
    Fluent::Test::Driver::Input.new(Fluent::Plugin::SwiftcapInput).configure(config)
  end

  def test_emits_one_event_per_stream_with_audio_prefix_tag
    d = create_driver
    d.run(timeout: 5, expect_emits: 3, shutdown: true) {}
    events = d.events
    tags = events.map { |t, _, _| t }
    assert_includes tags, 'audio.state'
    assert_includes tags, 'audio.quick'
    assert_includes tags, 'audio.final'

    state_record = events.find { |t, _, _| t == 'audio.state' }[2]
    assert_equal 'swiftcap_ready', state_record['kind']
    assert_nil state_record['stream'], 'stream field should be stripped before emit'

    final_record = events.find { |t, _, _| t == 'audio.final' }[2]
    assert_equal 'hi.', final_record['text']
  end

  def test_fails_start_when_swiftcap_ready_does_not_arrive
    silent_bin = File.join(@tmp, 'silent_swiftcap')
    File.write(silent_bin, "#!/usr/bin/env bash\nsleep 30\n")
    FileUtils.chmod(0o755, silent_bin)
    d = Fluent::Test::Driver::Input.new(Fluent::Plugin::SwiftcapInput).configure(%(
      swiftcap_bin #{silent_bin}
      spool_dir #{@tmp}
      socket_path #{File.join(@tmp, 'silent.sock')}
      ready_timeout 1
    ))
    err = assert_raises(Fluent::ConfigError, RuntimeError, StandardError) do
      d.run(timeout: 5, shutdown: true) {}
    end
    assert_match(/swiftcap_ready/, err.message)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rake test TEST=test/fluent/test_in_swiftcap.rb 2>&1 | tail -20
```

Expected: load error — `cannot load such file -- fluent/plugin/in_swiftcap`.

- [ ] **Step 3: Commit RED**

```bash
git add test/fluent/test_in_swiftcap.rb
git commit -m "test: add failing spec for in_swiftcap plugin (Phase B.8 RED)"
```

- [ ] **Step 4: GREEN — implement in_swiftcap**

Create `lib/fluent/plugin/in_swiftcap.rb`:

```ruby
# lib/fluent/plugin/in_swiftcap.rb
require 'fluent/plugin/input'
require 'json'
require 'open3'
require 'fileutils'

module Fluent
  module Plugin
    class SwiftcapInput < Fluent::Plugin::Input
      Fluent::Plugin.register_input('swiftcap', self)

      helpers :thread

      config_param :swiftcap_bin, :string
      config_param :spool_dir, :string
      config_param :locale, :string, default: 'ja-JP'
      config_param :socket_path, :string
      config_param :ready_timeout, :integer, default: 30

      ALLOWED_STREAMS = %w[quick final sound state].freeze
      SHUTDOWN_GRACE_SEC = 15

      def configure(conf)
        super
        FileUtils.mkdir_p(@spool_dir)
      end

      def start
        super
        env = {
          'SWIFTCAP_SPOOL' => @spool_dir,
          'SWIFTCAP_LOCALE' => @locale,
          'SWIFTCAP_SOCKET_PATH' => @socket_path
        }
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(env, @swiftcap_bin)
        @stdin.close

        @ready_queue = Queue.new
        thread_create(:swiftcap_stdout) { read_stdout_loop }
        thread_create(:swiftcap_stderr) { read_stderr_loop }

        ready = nil
        deadline = Time.now + @ready_timeout
        while Time.now < deadline
          begin
            ready = @ready_queue.pop(true)
            break
          rescue ThreadError
            sleep 0.05
          end
        end
        unless ready == :ready
          stop_child
          raise "swiftcap did not emit swiftcap_ready within #{@ready_timeout}s"
        end
        log.info "swiftcap ready (pid=#{@wait_thread.pid})"
      end

      def shutdown
        stop_child
        super
      end

      private

      def read_stdout_loop
        @stdout.each_line do |line|
          next if line.strip.empty?
          handle_stdout_line(line)
        end
      rescue IOError
        # pipe closed during shutdown
      end

      def handle_stdout_line(line)
        record = JSON.parse(line)
        stream = record.delete('stream')
        unless ALLOWED_STREAMS.include?(stream)
          log.warn "in_swiftcap: unknown or missing stream field: #{line.strip}"
          return
        end
        if stream == 'state' && record['kind'] == 'swiftcap_ready'
          @ready_queue << :ready
        end
        time = (record['ts'] || Time.now.to_f).to_f
        router.emit("audio.#{stream}", Fluent::EventTime.from_time(Time.at(time)), record)
      rescue JSON::ParserError => e
        log.warn "in_swiftcap: bad JSON line: #{e.message}: #{line.strip}"
      end

      def read_stderr_loop
        @stderr.each_line do |line|
          log.warn "swiftcap[stderr]: #{line.chomp}"
        end
      rescue IOError
        # ignore
      end

      def stop_child
        return unless @wait_thread
        pid = @wait_thread.pid
        return unless pid && pid > 0
        begin
          Process.kill('TERM', pid)
        rescue Errno::ESRCH
          return
        end
        deadline = Time.now + SHUTDOWN_GRACE_SEC
        until Time.now > deadline
          break unless process_alive?(pid)
          sleep 0.2
        end
        if process_alive?(pid)
          log.warn "swiftcap did not exit within #{SHUTDOWN_GRACE_SEC}s; sending SIGKILL (pid=#{pid})"
          Process.kill('KILL', pid) rescue nil
        end
        @wait_thread.join rescue nil
        File.delete(@socket_path) if File.exist?(@socket_path)
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bundle exec rake test TEST=test/fluent/test_in_swiftcap.rb 2>&1 | tail -20
```

Expected: PASS (2 tests).

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/fluent/plugin/in_swiftcap.rb
git commit -m "feat(fluentd): add in_swiftcap input plugin (Phase B.8 GREEN)"
```

---

### Task 9: out_sqlite_meeting_log ack via socket

**Files:**
- Modify: `lib/fluent/plugin/out_sqlite_meeting_log.rb`
- Modify: `test/fluent/test_out_sqlite_meeting_log.rb`

- [ ] **Step 1: RED — modify the existing test to use a tmp UNIX socket listener**

Replace the `@ack_path` setup and ack assertions in `test/fluent/test_out_sqlite_meeting_log.rb`. Add this helper at the top of the test class:

```ruby
require 'socket'

class TestOutSqliteMeetingLog < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('out-sqlite-')
    @db_path = File.join(@tmp, 'm.sqlite')
    @sock_path = File.join(@tmp, 'swiftcap.sock')
    AudioTranscription::Migrator.new(@db_path).run
    @server = UNIXServer.new(@sock_path)
    @ack_lines = []
    @ack_thread = Thread.new do
      loop do
        client = @server.accept
        client.each_line { |l| @ack_lines << l }
        client.close
      rescue StandardError
        break
      end
    end
  end

  def teardown
    @server.close rescue nil
    @ack_thread.kill rescue nil
    FileUtils.remove_entry(@tmp)
  end

  def create_driver
    Fluent::Test::Driver::Output.new(Fluent::Plugin::SqliteMeetingLogOutput)
      .configure(<<~CONF)
        db_path #{@db_path}
        swiftcap_socket_path #{@sock_path}
      CONF
  end

  # … keep existing test_writes_quick_… etc unchanged …

  def test_segment_ack_lands_on_socket
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'rotated', 'channel' => 'mic', 'path' => '/spool/mic-1.caf',
        'started_at' => 1.0, 'ended_at' => 2.0,
        'duration_sec' => 1.0, 'codec' => 'aac', 'sample_rate' => 16000,
        'bytes' => 4, 'blob' => "\x00\x01\x02\x03"
      })
    end
    Thread.pass; sleep 0.1  # allow ack thread to drain
    assert_equal 1, @ack_lines.size
    parsed = JSON.parse(@ack_lines.first)
    assert_equal 'ack', parsed['kind']
    assert_equal ['/spool/mic-1.caf'], parsed['paths']
  end
end
```

(Note: `test_segment_ack_lands_on_socket` replaces whatever existing test asserted on `ack.jsonl` — typically named like `test_segment_writes_ack_jsonl`. Delete the old test method.)

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rake test TEST=test/fluent/test_out_sqlite_meeting_log.rb 2>&1 | tail -20
```

Expected: failure — config option `swiftcap_socket_path` unknown OR ack still goes to file.

- [ ] **Step 3: Commit RED**

```bash
git add test/fluent/test_out_sqlite_meeting_log.rb
git commit -m "test: assert ack lands on swiftcap socket (Phase B.9 RED)"
```

- [ ] **Step 4: GREEN — modify the plugin**

Edit `lib/fluent/plugin/out_sqlite_meeting_log.rb`:

1. At line 14, replace:
   ```ruby
   config_param :ack_path, :string, default: nil
   ```
   with:
   ```ruby
   config_param :swiftcap_socket_path, :string, default: nil
   ```

2. At the top, add `require 'socket'` next to the other requires.

3. Replace the `if @ack_path && record['path']` block in `handle_segment` (around lines 129–135):
   ```ruby
   if @swiftcap_socket_path && record['path']
     send_ack([record['path']])
   end
   ```

4. Add a private method:
   ```ruby
   def send_ack(paths)
     UNIXSocket.open(@swiftcap_socket_path) do |sock|
       sock.puts JSON.generate({ 'kind' => 'ack', 'paths' => paths })
     end
   rescue StandardError => e
     log.warn "ack to swiftcap socket failed: #{e.class}: #{e.message}"
   end
   ```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bundle exec rake test TEST=test/fluent/test_out_sqlite_meeting_log.rb 2>&1 | tail -20
```

Expected: PASS (all out_sqlite tests).

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/fluent/plugin/out_sqlite_meeting_log.rb
git commit -m "feat(fluentd): out_sqlite_meeting_log sends ack via swiftcap.sock (Phase B.9 GREEN)"
```

---

### Task 10: web/app.rb boundary + mute via socket

**Files:**
- Modify: `web/app.rb`
- Modify: `test/web/test_session_control_routes.rb`

- [ ] **Step 1: RED — rewrite the relevant tests to use a tmp UNIX listener**

Replace `setup` / `teardown` / `control_lines` / boundary / mute tests in `test/web/test_session_control_routes.rb`:

```ruby
require 'socket'

class TestSessionControlRoutes < Test::Unit::TestCase
  include Rack::Test::Methods

  def setup
    @tmp = Dir.mktmpdir('session-routes-')
    @db_path = File.join(@tmp, 'meeting_log.sqlite')
    @spool_dir = File.join(@tmp, 'spool')
    @sock_path = File.join(@spool_dir, 'swiftcap.sock')
    FileUtils.mkdir_p(@spool_dir)
    AudioTranscription::Migrator.new(@db_path).run

    @server = UNIXServer.new(@sock_path)
    @ctrl_lines = []
    @ctrl_thread = Thread.new do
      loop do
        client = @server.accept
        client.each_line { |l| @ctrl_lines << l }
        client.close
      rescue StandardError
        break
      end
    end

    ENV['DB_PATH'] = @db_path
    ENV['SPOOL_DIR'] = @spool_dir
    ENV['SWIFTCAP_SOCKET_PATH'] = @sock_path
    ENV['SKIP_RETRANSCRIBE_WORKER'] = '1'
    require_relative '../../web/app'
  end

  def teardown
    @server.close rescue nil
    @ctrl_thread.kill rescue nil
    FileUtils.remove_entry(@tmp)
    %w[DB_PATH SPOOL_DIR SWIFTCAP_SOCKET_PATH SKIP_RETRANSCRIBE_WORKER].each { |k| ENV.delete(k) }
  end

  def app
    TranscriptionWeb
  end

  def default_host
    'localhost'
  end

  def test_post_boundary_writes_kind_to_swiftcap_socket
    post '/api/session/boundary'
    assert_equal 202, last_response.status
    sleep 0.1
    assert_equal 1, @ctrl_lines.size
    parsed = JSON.parse(@ctrl_lines.first)
    assert_equal 'boundary', parsed['kind']
  end

  def test_post_mute_writes_mute_toggle_to_swiftcap_socket
    post '/api/session/mute'
    assert_equal 202, last_response.status
    sleep 0.1
    parsed = JSON.parse(@ctrl_lines.first)
    assert_equal 'mute_toggle', parsed['kind']
  end

  # … leave the existing /current /recent tests unchanged …
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rake test TEST=test/web/test_session_control_routes.rb 2>&1 | tail -20
```

Expected: failures — boundary/mute still write to control.jsonl.

- [ ] **Step 3: Commit RED**

```bash
git add test/web/test_session_control_routes.rb
git commit -m "test: assert boundary/mute land on swiftcap socket (Phase B.10 RED)"
```

- [ ] **Step 4: GREEN — modify web/app.rb**

In `web/app.rb`, replace the `helpers do … append_control(kind) … end` block (lines 28–46) with:

```ruby
  helpers do
    def db
      @db ||= SQLite3::Database.new(ENV.fetch('DB_PATH', 'db/meeting_log.sqlite'), readonly: true).tap do |d|
        d.results_as_hash = true
      end
    end

    def spool_dir
      ENV.fetch('SPOOL_DIR',
        '/Users/bash/Library/Application Support/audio-transcription/spool')
    end

    def swiftcap_socket_path
      ENV.fetch('SWIFTCAP_SOCKET_PATH', File.join(spool_dir, 'swiftcap.sock'))
    end

    def send_control(kind)
      require 'socket'
      UNIXSocket.open(swiftcap_socket_path) do |sock|
        sock.puts JSON.generate({ 'kind' => kind })
      end
    end
  end
```

Update the two endpoint blocks (lines 48–60):

```ruby
  post '/api/session/boundary' do
    send_control('boundary')
    status 202
    content_type :json
    { status: 'queued' }.to_json
  end

  post '/api/session/mute' do
    send_control('mute_toggle')
    status 202
    content_type :json
    { status: 'queued' }.to_json
  end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bundle exec rake test TEST=test/web/test_session_control_routes.rb 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 6: Commit GREEN**

```bash
git add web/app.rb
git commit -m "feat(web): boundary/mute endpoints write to swiftcap.sock (Phase B.10 GREEN)"
```

---

## Phase C — config and infrastructure

### Task 11: fluent.conf rewrite

**Files:**
- Modify: `config/fluent.conf`

Single commit; the change is mechanical and existing tests already cover the plugin behavior.

- [ ] **Step 1: Replace `config/fluent.conf` contents**

```aconf
# config/fluent.conf

<source>
  @type swiftcap
  swiftcap_bin "#{ENV['SWIFTCAP_BIN']}"
  spool_dir "#{ENV['SPOOL_DIR'] || '/Users/bash/Library/Application Support/audio-transcription/spool'}"
  locale "#{ENV['SWIFTCAP_LOCALE'] || 'ja-JP'}"
  socket_path "#{ENV['SPOOL_DIR'] || '/Users/bash/Library/Application Support/audio-transcription/spool'}/swiftcap.sock"
</source>

<filter audio.state>
  @type audio_state
</filter>

<filter audio.final>
  @type natural_language_mac
  stopwords_path "#{ENV['STOPWORDS_PATH'] || File.expand_path('config/stopwords.yml', Dir.pwd)}"
</filter>

<filter audio.final>
  @type foundation_model_mac
</filter>

<match audio.{quick,final,sound,state}>
  @type sqlite_meeting_log
  db_path "#{ENV['DB_PATH'] || 'db/meeting_log.sqlite'}"
  swiftcap_socket_path "#{ENV['SPOOL_DIR'] || '/Users/bash/Library/Application Support/audio-transcription/spool'}/swiftcap.sock"
  webhook_url "#{ENV['WEBHOOK_URL'] || 'http://localhost:9292/_internal/notify'}"
</match>
```

- [ ] **Step 2: Run all unit tests to confirm**

```bash
bundle exec rake test 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add config/fluent.conf
git commit -m "chore(config): single in_swiftcap source, swiftcap_socket_path on out_sqlite"
```

---

### Task 12: Rakefile cleanup

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Apply edits**

Apply these edits to `Rakefile`:

1. Remove `'swiftcap' => 30,` from `WAIT_SEC` (line 28):

   ```ruby
   WAIT_SEC = { 'fluentd' => 60, 'web' => 10, 'caffeinate' => 5 }.freeze
   ```

2. Delete the entire `desc 'Start swiftcap …' / task :swiftcap do … end` block in `namespace :start` (lines 65–78).

3. Update `desc 'Start fluentd as daemon …' / task fluentd: 'db:migrate' do` (line 80). Replace the `%w[quick.jsonl final.jsonl sound.jsonl state.jsonl].each { |f| FileUtils.touch(File.join(SPOOL_DIR, f)) }` block with a swiftcap-build precondition and removing leftover spool jsonl files:

   ```ruby
   desc 'Start fluentd as daemon (writes pidfile via -d, no screen wrapping)'
   task fluentd: 'db:migrate' do
     unless File.executable?(SWIFTCAP_BIN)
       sh 'cd swift/swiftcap && swift build -c release'
     end
     FileUtils.mkdir_p([SPOOL_DIR, LOG_DIR, RUN_DIR, File.dirname(DB_PATH)])
     # Strip any leftover legacy spool files (in_tail era) so they cannot
     # confuse the new in_swiftcap pipeline.
     %w[quick.jsonl final.jsonl sound.jsonl state.jsonl control.jsonl ack.jsonl].each do |f|
       File.delete(File.join(SPOOL_DIR, f)) rescue nil
     end
     Dir.glob(File.join(SPOOL_DIR, '.pos.*')).each { |f| File.delete(f) rescue nil }
     pidfile = File.join(RUN_DIR, 'fluentd.pid')
     File.delete(pidfile) if File.exist?(pidfile) && !process_alive?(File.read(pidfile).to_i)
     abort "fluentd appears to be running (pid=#{File.read(pidfile)})" if File.exist?(pidfile)
     sh({
       'SPOOL_DIR' => SPOOL_DIR,
       'DB_PATH' => DB_PATH,
       'SWIFTCAP_BIN' => SWIFTCAP_BIN
     }, "bundle exec fluentd -c config/fluent.conf -p lib/fluent/plugin -d #{pidfile} -o #{LOG_DIR}/fluentd.log")
     20.times { break if File.exist?(pidfile); sleep 0.2 }
     abort "fluentd failed to write pidfile" unless File.exist?(pidfile)
     puts "started: fluentd (pid=#{File.read(pidfile)}, log: #{LOG_DIR}/fluentd.log)"
   end
   ```

4. Update `task all: %w[start:caffeinate start:swiftcap start:fluentd start:web]` (line 110):

   ```ruby
   desc 'Start 3 services (caffeinate, fluentd → spawns swiftcap, web)'
   task all: %w[start:caffeinate start:fluentd start:web]
   ```

5. Delete the `desc 'Stop audio-swiftcap …' / task :swiftcap do … end` block in `namespace :stop` (lines 113–116).

6. Update the `task all: %w[stop:swiftcap stop:fluentd stop:web stop:caffeinate]` line:

   ```ruby
   desc 'Stop 3 services in graceful order (fluentd first stops swiftcap; caffeinate last)'
   task all: %w[stop:fluentd stop:web stop:caffeinate]
   ```

- [ ] **Step 2: Run a smoke check (sanity)**

```bash
bundle exec rake -T 2>&1 | grep -E 'start|stop' | head
```

Expected: no `start:swiftcap` / `stop:swiftcap` listed.

- [ ] **Step 3: Commit**

```bash
git add Rakefile
git commit -m "chore(rake): remove start:swiftcap / stop:swiftcap, fluentd builds and spawns it"
```

---

### Task 13: Delete swiftcap plist + update setup.rb

**Files:**
- Delete: `plists/dev.bash0c7.audio-transcription.swiftcap.plist.erb`
- Modify: `scripts/setup.rb`

- [ ] **Step 1: Delete the plist**

```bash
git rm plists/dev.bash0c7.audio-transcription.swiftcap.plist.erb
```

- [ ] **Step 2: Edit `scripts/setup.rb` to render only fluentd + web**

Change the `%w[swiftcap fluentd web]` line to `%w[fluentd web]`:

```ruby
%w[fluentd web].each do |name|
  template = File.read(File.join(REPO_ROOT, "plists/dev.bash0c7.audio-transcription.#{name}.plist.erb"))
  rendered = ERB.new(template).result(binding)
  dest = File.join(LAUNCH_AGENTS, "dev.bash0c7.audio-transcription.#{name}.plist")
  File.write(dest, rendered)
  uid = `id -u`.strip
  system("launchctl bootout gui/#{uid} #{dest} 2>/dev/null")
  system("launchctl bootstrap gui/#{uid} #{dest}", exception: true)
  puts "loaded: #{dest}"
end

puts 'all 2 LaunchAgents loaded. open http://localhost:9292/'
```

Also update the fluentd plist template (`plists/dev.bash0c7.audio-transcription.fluentd.plist.erb`) to add `SWIFTCAP_BIN` to its `EnvironmentVariables`:

```xml
  <key>EnvironmentVariables</key>
  <dict>
    <key>SPOOL_DIR</key>     <string><%= spool_dir %></string>
    <key>DB_PATH</key>       <string><%= db_path %></string>
    <key>SWIFTCAP_BIN</key>  <string><%= swiftcap_bin %></string>
    <key>WEBHOOK_URL</key>   <string>http://localhost:9292/_internal/notify</string>
  </dict>
```

- [ ] **Step 3: Commit**

```bash
git add scripts/setup.rb plists/dev.bash0c7.audio-transcription.fluentd.plist.erb
git commit -m "chore(setup): drop swiftcap LaunchAgent, fluentd plist gains SWIFTCAP_BIN"
```

---

### Task 14: synthetic_e5 verification updates

**Files:**
- Modify: `lib/audio_transcription/synthetic_e5.rb`

The synthetic E5 currently reads `spool/state.jsonl` (`count_rotated`) and `spool/ack.jsonl` (`count_ack`). Both files no longer exist.

New semantics:
- `count_rotated` → query `audio_segments` (each rotated CAF inserts one row).
- `count_ack` → count CAFs deleted from `spool/` since baseline (acknowledgeAndDelete unlinks the file).
- `verify_l5_processes` → drop `swiftcap` from the leftover-pid scan.

- [ ] **Step 1: Apply edits**

In `lib/audio_transcription/synthetic_e5.rb`:

1. `capture_baseline` — replace `@baseline[:rotated_count] = count_rotated` and `@baseline[:ack_count] = count_ack` with:

   ```ruby
   @baseline[:rotated_count] = count_audio_segments
   @baseline[:cafs_present] = Dir.glob(File.join(@spool_dir, '*.caf')).map { |p| File.basename(p) }.to_set
   ```

2. Replace `count_rotated` / `count_ack` definitions with:

   ```ruby
   def count_audio_segments
     with_db do |db|
       db.get_first_value('SELECT COUNT(*) FROM audio_segments')
     end
   rescue SQLite3::SQLException
     0
   end

   # An ack causes swiftcap to delete the CAF. Compare against baseline-set
   # to count files that were present then but absent now.
   def count_acked_via_deletion
     present_now = Dir.glob(File.join(@spool_dir, '*.caf')).map { |p| File.basename(p) }.to_set
     # A "baseline-then-rotated" CAF: was rotated during the run (so it
     # appeared) and is now gone (so it was acked + deleted). Use audio_segments
     # rows minus current CAF count to estimate.
     count_audio_segments - present_now.size
   end
   ```

3. `verify_l4_ack` — rewrite:

   ```ruby
   def verify_l4_ack
     # In the new model, swiftcap deletes a CAF the moment it receives an
     # ack. So a successful ack manifests as: an audio_segments row exists
     # but its referenced CAF is no longer present on disk.
     reached_parity = wait_until(timeout: 15.0, poll: 0.3) do
       acked = count_acked_via_deletion
       rotated = count_audio_segments - @baseline[:rotated_count]
       acked >= rotated && rotated > 0
     end
     fail!(:L4, "ack-driven CAF deletion never caught up to rotated count (polled 15s)") unless reached_parity
   end
   ```

4. `verify_l5_processes` — drop `swiftcap` from the pgrep:

   ```ruby
   stragglers = `pgrep -f 'fluentd -c config|puma -C web|caffeinate -dimsu'`.lines.map(&:strip).reject(&:empty?)
   ```

5. `count_transcripts_with_time` is unchanged.

6. Add `require 'set'` near the top.

- [ ] **Step 2: Run synthetic_e5 unit tests (verify_helpers, wait_until)**

```bash
bundle exec rake test TEST=test/test_synthetic_e5_verify_helpers.rb 2>&1 | tail -10
bundle exec rake test TEST=test/test_synthetic_e5_wait_until.rb 2>&1 | tail -10
```

Expected: PASS (helpers tests don't depend on the changed methods, but verify nothing else regressed).

- [ ] **Step 3: Commit**

```bash
git add lib/audio_transcription/synthetic_e5.rb
git commit -m "chore(e5): rebase rotated/ack verification on audio_segments + CAF deletion"
```

---

### Task 15: README full rewrite

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the file**

Replace `README.md` with a version reflecting the new architecture (single example shown — the engineer should adapt prose to match the spec). Key sections to fix:

```markdown
# fluentd-audio-transcription-system

Always-on meeting audio capture, on-device transcription, and live visualization for macOS 26+.

## Overview

The system continuously captures both microphone and system audio, transcribes them on-device via Apple SpeechAnalyzer, derives entity / edge structure from the transcripts via Apple NaturalLanguage and Apple Foundation Models, persists everything to SQLite WAL, and streams the live state to a three-pane web UI rendered with PicoRuby:wasm + Three.js.

No cloud APIs, no translation, no third-party LLM service. Everything that runs is either an Apple framework on the user's Mac, a Ruby gem in this repository's sibling layout, or fluentd.

## Architecture

```
fluentd (with in_swiftcap input plugin)
  ├─ spawns swiftcap (Swift binary, owns macOS TCC consent)
  │    swiftcap stdout ──┐ JSON lines: {"stream":"quick"|"final"|"sound"|"state", …}
  │                       ▼
  │    in_swiftcap reads stdout → emits audio.<stream> records
  │
  └─ filter chain (audio_state / natural_language_mac / foundation_model_mac)
       ↓
     out_sqlite_meeting_log  ──→ SQLite WAL + HTTP webhook
                              └─ ack to spool/swiftcap.sock (CAFs deleted on ack)

spool/
  ├─ swiftcap.sock      (unix domain socket — boundary / mute / ack / retranscribe-emit)
  └─ *.caf              (rotated audio segments, retained until acked)

web (sinatra + faye-websocket + puma)
  ├─ POST /api/session/boundary → swiftcap.sock {"kind":"boundary"}
  ├─ POST /api/session/mute     → swiftcap.sock {"kind":"mute_toggle"}
  └─ retranscribe worker spawns swiftcap retranscribe (one-shot client of swiftcap.sock)

Chrome (PicoRuby:wasm + Three.js + 3d-force-graph)
  ┌──────────┬──────────┬─────────────┐
  │ Quick    │ Perfect  │ Network     │
  └──────────┴──────────┴─────────────┘
```

## Requirements

- macOS 26 (Tahoe) on Apple Silicon
- Apple Intelligence enabled with on-device foundation model downloaded
- Swift 6.3+ via swiftly
- Ruby 4.0.3 (rbenv)
- Sibling repos in ghq layout: `../rb-natural-language-mac`, `../rb-foundation-model-mac`, `../swift_gem`

The first runtime startup triggers macOS permission prompts under the swiftcap binary identity (`dev.bash0c7.swiftcap`) for Screen Recording, Microphone, and Speech Recognition.

## Setup

```bash
bundle config set --local path vendor/bundle
bundle install
bundle exec rake db:migrate
bundle exec ruby scripts/setup.rb       # generates LaunchAgents (fluentd, web) and builds swiftcap
```

## Running

```bash
bundle exec rake start:all    # caffeinate + fluentd (which spawns swiftcap) + web
bundle exec rake status       # list audio-* screen sessions
bundle exec rake logs[fluentd] | rake logs[web] | rake logs[caffeinate]
bundle exec rake stop:all
```

The web UI is at <http://localhost:9292/>. Three components run as detached `screen` sessions; swiftcap is no longer a separate `screen` session — fluentd's `in_swiftcap` plugin owns it as a child process.

## Verifying

System is functional when, after `say -v Kyoko こんにちは`, the Quick / Perfect / Graph panes at <http://localhost:9292/> populate within their usual latencies (Quick within ~2 s, Perfect within a few seconds, Graph as content accrues).

## Design Choices

- **Single-process audio capture.** swiftcap is the TCC anchor: its embedded `Info.plist` is what macOS attributes Screen Recording / Microphone / Speech Recognition consents to. Everything that doesn't need TCC lives in Ruby.
- **stdio + unix socket I/O.** swiftcap streams records to fluentd via stdout JSON lines; control / ack / retranscribe-emit go through `spool/swiftcap.sock`. There are no `*.jsonl` files between processes.
- **No translation.** Locale stays as captured.
- **On-device only.**

## Development

```bash
bundle exec rake test                    # Ruby unit tests
cd swift/swiftcap && swift test          # Swift unit tests
bundle exec rake test:e5_synthetic       # 30s synthetic E2E
```

## Status

The two verification paths above are confirmed end-to-end. Backlog: `docs/superpowers/specs/2026-05-07-next-version-backlog.md`.

## License

Apache 2.0
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): rewrite for stdio + unix socket architecture"
```

---

## Phase D — verification

### Task 16: All-tests gate

- [ ] **Step 1: Run full Ruby test suite**

```bash
bundle exec rake test 2>&1 | tail -20
```

Expected: all GREEN.

- [ ] **Step 2: Run full Swift test suite**

```bash
cd swift/swiftcap && swift test 2>&1 | tail -20
```

Expected: all GREEN.

If anything fails: do NOT mark the plan complete. Diagnose and fix in a new commit per the bug; come back to this step.

---

### Task 17: synthetic_e5 acceptance gate

- [ ] **Step 1: Build swiftcap release**

```bash
cd swift/swiftcap && swift build -c release 2>&1 | tail -5
```

- [ ] **Step 2: Run mini-E5**

```bash
bundle exec rake test:e5_synthetic 2>&1 | tail -20
```

Expected: `mini-E5 PASS — all 5 layers verified`. The runner internally does `start:all` → `afplay 30s` → `stop:all` → asserts L1–L5.

- [ ] **Step 3: If it fails**

Surface the exact failures, capture `tmp/log/fluentd.log` and `tmp/log/swiftcap.log`, and fix root causes (do NOT skip layers).

---

### Task 18: Manual UI verification

- [ ] **Step 1: Start the system**

```bash
bundle exec rake start:all
```

- [ ] **Step 2: Open the web UI**

Open <http://localhost:9292/> in a browser.

- [ ] **Step 3: Trigger speech**

```bash
say -v Kyoko こんにちは。今日は良い天気ですね。
```

Expected within ~5 s:
- Quick pane shows volatile transcripts during speech.
- Perfect pane shows the final sentence after silence.
- Graph pane gains nodes/edges as entities accrue.

- [ ] **Step 4: Test boundary + mute**

In the web UI, click the 区切る (boundary) button. Expected: a `session_finalized` + `session_started` pair flows through; new transcripts in the next utterance appear under the new session in the side panel.

Click the mute button. Expected: subsequent `say -v Kyoko …` produces NO mic-channel transcripts. Click again to unmute and confirm transcripts return.

- [ ] **Step 5: Test retranscribe**

In the web UI, trigger a retranscribe of the most recently finalized session. Expected: pass=2 final transcripts appear in the Perfect pane.

- [ ] **Step 6: Stop and verify clean shutdown**

```bash
bundle exec rake stop:all
bundle exec rake status   # should print "no audio-* sessions running"
ls spool/                 # should contain only *.caf (no swiftcap.sock, no *.jsonl)
```

---

## Self-Review (run before merge)

- [ ] All 18 tasks ticked.
- [ ] `git log feat/slim-swiftcap-stdio-2026-05-08 ^main --oneline` shows the TDD commit cadence (RED / GREEN / REFACTOR or single-commit infra).
- [ ] No reference to `SpoolWriter` / `ControlReader` / `AckReader` / `control.jsonl` / `ack.jsonl` / `quick.jsonl` / `final.jsonl` / `sound.jsonl` / `state.jsonl` / `start:swiftcap` / `swiftcap.plist` remains anywhere except in the design + plan docs.
- [ ] `grep -rn 'spool/.*\.jsonl' lib config web swift Rakefile scripts test 2>&1 | grep -v 'docs/'` — no hits.
- [ ] `grep -rn 'ack_path' .` — no hits except the `git log` migration note.
- [ ] README accurately describes the new shape only.

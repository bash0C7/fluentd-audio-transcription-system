# Core Feature Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four residual gaps (G1-G4) blocking core feature "mic + app audio → 文字化 → SQLite → Web 表示" so it works E2E with mic-only degrade when screen channel dies.

**Architecture:** G1 wires `SCStreamDelegate.didStopWithError` back into `CaptureCoordinator` via a weak ref so the actor can null screen-channel state, emit a loud `channel_failed` event, and let mic continue. G2 splits the mini-E5 L3 baseline/assertion by channel so a dead screen channel can no longer pass. G3 adds rack-test coverage for `/api/recent` and `/_internal/notify`. G4 bumps Ruby to 4.0.3 via `rbenv local`.

**Tech Stack:** Swift 6 actor + ScreenCaptureKit (swiftcap), Ruby 4.0.3 + Test::Unit + rack-test, SQLite3, Sinatra.

**Reference docs (read first when starting):**
- Spec: `docs/superpowers/specs/2026-05-06-core-feature-completion.md`
- v2 design: `docs/superpowers/specs/2026-05-05-fluentd-audio-transcription-v2-design.md`
- F1-F4 spec: `docs/superpowers/specs/2026-05-06-core-fixes-from-e5.md`

---

## File Map

**Modify:**
- `.ruby-version` (4.0.1 → 4.0.3, via `rbenv local`)
- `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift` (add `handleScreenStreamStopped`, `screenChannelActive` flag, wire delegate, guard shutdown)
- `lib/audio_transcription/synthetic_e5.rb` (split L3 baseline/assertion by channel)

**Create:**
- `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorChannelFailureTests.swift` (3 @Test methods)
- `test/web/test_recent_api.rb` (rack-test for `/api/recent`)
- `test/web/test_internal_notify.rb` (rack-test for `/_internal/notify`)

**Already in place (verified, no change needed):**
- `Gemfile` already pins `gem 'rack-test', '~> 2.1'` in the dev/test group — spec §6.1 is already satisfied.

---

## Task 1: Bump Ruby to 4.0.3 (G4)

This must run first because every subsequent test/build runs against the active Ruby. Doing it last would force a re-run of all tests under the new version.

**Files:**
- Modify: `.ruby-version`

- [ ] **Step 1: Verify 4.0.3 is installed in rbenv**

```bash
rbenv versions | grep 4.0.3
```
Expected: a line containing `4.0.3`. If absent, stop and tell the user — installing a Ruby is out of plan scope.

- [ ] **Step 2: Switch project ruby to 4.0.3**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system && rbenv local 4.0.3
```
Expected: `.ruby-version` now contains `4.0.3` (single line). Per `MEMORY.md` (`rbenv local trust`), do **not** hand-edit `.ruby-version` separately.

- [ ] **Step 3: Re-resolve gems against 4.0.3**

```bash
bundle install
```
Expected: `Bundle complete!` with no resolution errors. If any gem fails to compile against 4.0.3, stop and report — do not paper over with version pins.

- [ ] **Step 4: Smoke-test ruby + swift suites unchanged**

Delegate `rake test` to a subagent (per CLAUDE.md "Test Execution Delegation"). For swift, run inline since logs are short:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system/swift/swiftcap && swift test 2>&1 | tail -40
```
Expected swift: `Test Suite 'All tests' passed`. Expected ruby (from subagent): pass count unchanged from before bump.

- [ ] **Step 5: Commit**

```bash
git add .ruby-version
git commit -m "chore(ruby): bump to 4.0.3 via rbenv local"
```

---

## Task 2: G1 RED — failing test for handleScreenStreamStopped

Build the test seam first (TDD red). The implementation in Task 3 makes it green. The test verifies observable side-effects only (state.jsonl content), not private actor state — this avoids fighting Swift actor isolation.

**Files:**
- Create: `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorChannelFailureTests.swift`

- [ ] **Step 1: Write the failing test file**

```swift
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
```

- [ ] **Step 2: Run the test, verify RED**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system/swift/swiftcap && swift test --filter CaptureCoordinatorChannelFailureTests 2>&1 | tail -30
```
Expected: build error — `markScreenActiveForTesting` and `handleScreenStreamStopped` undefined. This is the desired RED state. Do **not** proceed to commit; the file must compile in Task 3.

- [ ] **Step 3: Commit RED state**

The build won't compile yet, so this commit is the failing-spec marker per CLAUDE.md TDD discipline. Stage only the new test file:

```bash
git add swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorChannelFailureTests.swift
git commit -m "test(swiftcap): add failing spec for handleScreenStreamStopped channel_failed event"
```

Note: pre-commit hooks that build the project will fail. If that happens, use `--no-verify` is **not** acceptable — instead, sequence Task 3 immediately after this commit so the next commit (GREEN) restores buildability. If the user's pre-commit hook blocks RED commits hard, squash Task 2 + Task 3 into one commit with body `test+feat:` and note the deviation.

---

## Task 3: G1 GREEN — implement handleScreenStreamStopped + mic-only degrade

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`

- [ ] **Step 1: Add `screenChannelActive` flag and test seam**

Edit `CaptureCoordinator` actor body to add an internal-visibility flag near the other screen-channel properties (around line 24, right after `screenAudioOutput`):

```swift
    // Tracks whether the screen channel is currently capturing. Set true after
    // startScreen succeeds, cleared by handleScreenStreamStopped or shutdownRotate.
    // Internal (not private) so tests can drive the active-state path without
    // needing a real SCStream.
    internal var screenChannelActive: Bool = false

    #if DEBUG
    internal func markScreenActiveForTesting() {
        screenChannelActive = true
    }
    #endif
```

- [ ] **Step 2: Set the flag in `startScreen`**

In `startScreen()` immediately after the existing `screenStream = stream` line (around line 189), append:

```swift
        screenChannelActive = true
```

- [ ] **Step 3: Add `handleScreenStreamStopped(error:)` actor method**

Insert a new method after `feedScreen` (around line 195, just before the closing brace of the actor):

```swift
    /// Called when SCStream emits didStopWithError. Marks the screen channel as
    /// dead, emits a loud channel_failed event, finalizes any in-flight screen
    /// recorder one last time, and drops screen-side state. Mic continues.
    /// Idempotent: the screenChannelActive guard ensures repeated calls no-op.
    func handleScreenStreamStopped(error: Error) async {
        guard screenChannelActive else { return }
        screenChannelActive = false

        FileHandle.standardError.write(
            "handleScreenStreamStopped: marking screen channel as dead, mic continues. error=\(error)\n"
                .data(using: .utf8)!
        )

        try? stateWriter.append([
            "ts": Date().timeIntervalSince1970,
            "kind": "channel_failed",
            "channel": "screen",
            "reason": "scstream_error",
            "error": "\(error)"
        ])

        screenStream = nil
        screenAudioOutput = nil
        screenDelegate = nil

        if let r = recorders["screen"] {
            await rotate(channel: "screen", recorder: r, reason: "channel_failed")
            recorders["screen"] = nil
        }
        transcribers["screen"] = nil
        sounds["screen"] = nil
    }
```

- [ ] **Step 4: Wire the delegate to coordinator**

Replace the `ScreenStreamDelegate` class (currently lines 226-231) with:

```swift
@available(macOS 26.0, *)
final class ScreenStreamDelegate: NSObject, SCStreamDelegate {
    weak var coordinator: CaptureCoordinator?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("SCStream stopped with error: \(error)\n".data(using: .utf8)!)
        if let coord = coordinator {
            Task { await coord.handleScreenStreamStopped(error: error) }
        }
    }
}
```

And in `startScreen()`, modify the delegate construction (around lines 182-184) from:

```swift
        let delegate = ScreenStreamDelegate()
        screenDelegate = delegate
```

to:

```swift
        let delegate = ScreenStreamDelegate()
        delegate.coordinator = self
        screenDelegate = delegate
```

- [ ] **Step 5: Make `shutdownRotate` clear the flag and tolerate dead stream**

Replace the existing `shutdownRotate` body (lines 69-81) with:

```swift
    func shutdownRotate(reason: String) async {
        micEngine.stop()
        if let stream = screenStream {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                stream.stopCapture { _ in cont.resume() }
            }
        }
        screenStream = nil
        screenAudioOutput = nil
        screenDelegate = nil
        screenChannelActive = false
        for (ch, recorder) in recorders {
            await rotate(channel: ch, recorder: recorder, reason: reason)
        }
        recorders.removeAll()
    }
```

The `if let` already skips a nil stream, so handleScreenStreamStopped's prior null-out is safe. The new lines null `screenAudioOutput` / `screenDelegate` to keep cleanup symmetrical, and clear the flag.

- [ ] **Step 6: Run the new failure tests, verify GREEN**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system/swift/swiftcap && swift test --filter CaptureCoordinatorChannelFailureTests 2>&1 | tail -30
```
Expected: `Test Suite 'CaptureCoordinatorChannelFailureTests' passed` with 3 tests run, 0 failures.

- [ ] **Step 7: Run the full swift suite, verify no regression**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system/swift/swiftcap && swift test 2>&1 | tail -20
```
Expected: all tests pass (existing AckReader/RotatingRecorder/Smoke/SpoolWriter + new CaptureCoordinatorChannelFailure).

- [ ] **Step 8: Commit GREEN**

```bash
git add swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift
git commit -m "feat(swiftcap): handle SCStream runtime error with mic-only degrade"
```

---

## Task 4: G2 — split mini-E5 L3 baseline + assertion by channel

**Files:**
- Modify: `lib/audio_transcription/synthetic_e5.rb`

- [ ] **Step 1: Replace `count_transcripts_with_time` with channel-aware variant + helpers**

Replace lines 65-70 (`capture_baseline`) with:

```ruby
    def capture_baseline
      @baseline[:cafs] = Dir.glob(File.join(@spool_dir, '*.caf'))
      @baseline[:rotated_count] = count_rotated
      @baseline[:ack_count] = count_ack
      @baseline[:mic_transcripts]    = count_transcripts_with_time(channel: 'mic')
      @baseline[:screen_transcripts] = count_transcripts_with_time(channel: 'screen')
    end
```

Replace lines 105-112 (`verify_l3_sqlite`) with:

```ruby
    def verify_l3_sqlite
      with_db do |db|
        mic_delta = db.get_first_value(
          "SELECT COUNT(*) FROM transcripts WHERE channel='mic' AND ended_at > 0.0"
        ) - @baseline[:mic_transcripts]
        fail!(:L3, "no new mic transcripts (delta=#{mic_delta})") if mic_delta <= 0

        screen_delta = db.get_first_value(
          "SELECT COUNT(*) FROM transcripts WHERE channel='screen' AND ended_at > 0.0"
        ) - @baseline[:screen_transcripts]
        fail!(:L3, "no new screen transcripts (delta=#{screen_delta})") if screen_delta <= 0

        s = db.get_first_value("SELECT COUNT(*) FROM audio_segments WHERE duration_sec > 0.0")
        fail!(:L3, "no audio_segments with non-zero duration_sec (count=#{s})") if s <= 0
      end
    end
```

Replace lines 139-143 (`count_transcripts_with_time`) with:

```ruby
    def count_transcripts_with_time(channel:)
      with_db do |db|
        db.get_first_value(
          'SELECT COUNT(*) FROM transcripts WHERE channel=? AND ended_at > 0.0',
          [channel]
        )
      end
    rescue SQLite3::SQLException
      0
    end
```

- [ ] **Step 2: Run the mini-E5 to verify the new assertions are in place**

This is a 30-second live run. Per CLAUDE.md "Long-running batch" rules, mini-E5 itself orchestrates start:all → afplay → stop:all and finishes well under 2 minutes once afplay completes — it is **not** a long-running batch in the screen-detached sense. Run inline:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system && bundle exec rake test:e5_synthetic 2>&1 | tail -30
```
Expected: `mini-E5 PASS — all 5 layers verified`. If L3 fails for screen with `no new screen transcripts`, that is the test working as designed (G1 is supposed to be in place by Task 3 to keep screen healthy on the synthetic 30s path); investigate via `tail spool/state.jsonl tmp/log/swiftcap.log` and report rather than weakening the assertion.

- [ ] **Step 3: Commit**

```bash
git add lib/audio_transcription/synthetic_e5.rb
git commit -m "test: assert channel='screen' transcripts in mini-E5 L3"
```

---

## Task 5: G3 RED — failing rack-test specs

**Files:**
- Create: `test/web/test_recent_api.rb`
- Create: `test/web/test_internal_notify.rb`

- [ ] **Step 1: Create `test/web/test_recent_api.rb`**

```ruby
# test/web/test_recent_api.rb
require 'test/unit'
require 'rack/test'
require 'sqlite3'
require 'json'
require 'tmpdir'
require 'fileutils'

REPO_ROOT = File.expand_path('../..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'lib', 'audio_transcription', 'migrator')

class TestRecentApi < Test::Unit::TestCase
  include Rack::Test::Methods

  def app
    @app ||= begin
      ENV['DB_PATH'] = @db_path
      require File.join(REPO_ROOT, 'web', 'app')
      TranscriptionWeb
    end
  end

  def setup
    @tmp = Dir.mktmpdir('web-test-')
    @db_path = File.join(@tmp, 'test.sqlite')
    ENV['DB_PATH'] = @db_path
    AudioTranscription::Migrator.new(@db_path).run
    seed_rows
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_get_recent_returns_both_mic_and_screen
    get '/api/recent?since=0'
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    channels = body['transcripts'].map { |t| t['channel'] }.uniq.sort
    assert_equal %w[mic screen], channels
  end

  def test_get_recent_excludes_zero_ended_at
    insert_transcript(channel: 'mic', text: 'broken', started_at: 0.0, ended_at: 0.0)
    get '/api/recent?since=0'
    body = JSON.parse(last_response.body)
    assert_false body['transcripts'].any? { |t| t['raw_text'] == 'broken' },
                 '/api/recent must exclude rows with ended_at == 0.0'
  end

  def test_get_recent_with_only_mic_transcripts_returns_mic_only
    db = SQLite3::Database.new(@db_path)
    db.execute("DELETE FROM transcripts WHERE channel='screen'")
    db.close
    get '/api/recent?since=0'
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    channels = body['transcripts'].map { |t| t['channel'] }.uniq
    assert_equal ['mic'], channels
  end

  private

  def seed_rows
    insert_transcript(channel: 'mic',    text: 'hello mic',    started_at: 100.0, ended_at: 105.0)
    insert_transcript(channel: 'screen', text: 'hello screen', started_at: 200.0, ended_at: 210.0)
  end

  def insert_transcript(channel:, text:, started_at:, ended_at:)
    db = SQLite3::Database.new(@db_path)
    db.execute('INSERT INTO sessions (started_at, ended_at) VALUES (?, ?)', [started_at, ended_at])
    sid = db.last_insert_row_id
    db.execute(
      "INSERT INTO transcripts (session_id, channel, raw_text, polished_text, " \
      "started_at, ended_at, language, swiftcap_transcript_id) " \
      "VALUES (?, ?, ?, '', ?, ?, 'ja-JP', ?)",
      [sid, channel, text, started_at, ended_at, "u-#{rand(1_000_000)}"]
    )
    db.close
  end
end
```

Note: `sessions` schema (per `migrations/20260505000000_initial.sql`) does **not** have a `channel` column — the spec's example INSERT has a typo. The corrected form is above.

- [ ] **Step 2: Create `test/web/test_internal_notify.rb`**

```ruby
# test/web/test_internal_notify.rb
require 'test/unit'
require 'rack/test'
require 'json'

REPO_ROOT = File.expand_path('../..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'web', 'app')

class TestInternalNotify < Test::Unit::TestCase
  include Rack::Test::Methods

  def app
    TranscriptionWeb
  end

  class FakeWebSocket
    attr_reader :sent_messages
    def initialize; @sent_messages = []; end
    def send(msg); @sent_messages << msg; end
  end

  def teardown
    TranscriptionWeb::WEBSOCKETS.clear
  end

  def test_notify_accepts_valid_json_payload
    payload = { kind: 'final', channel: 'mic', text: 'hello', started_at: 1.0, ended_at: 2.0 }
    post '/_internal/notify', payload.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_includes 200..299, last_response.status,
                    "expected 2xx, got #{last_response.status}: #{last_response.body}"
  end

  def test_notify_broadcasts_to_open_websockets
    fake = FakeWebSocket.new
    TranscriptionWeb::WEBSOCKETS << fake

    post '/_internal/notify', { kind: 'quick', text: 'live' }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 1, fake.sent_messages.size
    parsed = JSON.parse(fake.sent_messages.first)
    assert_equal 'quick', parsed['kind']
    assert_equal 'live',  parsed['text']
  end
end
```

- [ ] **Step 3: Run the new tests, verify GREEN immediately**

The `/api/recent` and `/_internal/notify` routes already exist in `web/app.rb` with the behavior these tests expect (`ended_at > since` filter, `WEBSOCKETS.each { |ws| ws.send(msg) }`), so this is RED-then-GREEN-in-one-step: the test is the spec, and the existing code happens to satisfy it. Per CLAUDE.md TDD §"既存テストに網羅される変更" the RED commit can be skipped when the test would already pass against current code, but we still keep this as a single test commit.

Delegate to a subagent per CLAUDE.md "Test Execution Delegation":

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system && bundle exec rake test TEST=test/web 2>&1 | tail -30
```
Expected: 5 tests run (3 in `TestRecentApi` + 2 in `TestInternalNotify`), 0 failures, 0 errors.

If `test_notify_broadcasts_to_open_websockets` fails because `WEBSOCKETS` isn't reachable as a constant on `TranscriptionWeb`, verify the constant is declared in `web/app.rb` (it is, at the class body — `WEBSOCKETS = []`). If `rack-test` can't find puma/sinatra adapter, confirm `bundle install` from Task 1 ran cleanly.

- [ ] **Step 4: Commit**

```bash
git add test/web/test_recent_api.rb test/web/test_internal_notify.rb
git commit -m "test(web): add rack-test specs for /api/recent and /_internal/notify"
```

---

## Task 6: Full-suite regression check

**Files:** none (verification only)

- [ ] **Step 1: Run full ruby test suite (delegate to subagent)**

Per CLAUDE.md "Test Execution Delegation", dispatch a subagent that runs `bundle exec rake test` and returns only pass/fail + counts. The subagent must not include green test logs in its return.

Expected: total = (previous count) + 5 (new web tests), 0 failures, 0 errors.

- [ ] **Step 2: Run full swift test suite inline**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system/swift/swiftcap && swift test 2>&1 | tail -20
```
Expected: all suites pass, including `CaptureCoordinatorChannelFailureTests`.

- [ ] **Step 3: Run mini-E5 again under the new assertions (smoke check)**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system && bundle exec rake test:e5_synthetic 2>&1 | tail -30
```
Expected: `mini-E5 PASS — all 5 layers verified`. The new channel-split L3 must report mic AND screen deltas both > 0.

- [ ] **Step 4: No commit needed**

Verification only. If any check fails, stop and surface to user — do not paper over.

---

## Task 7: Real 15-min E5 reverify (manual handoff)

This is a manual checkpoint, not an automated step. The user runs the live 15-min meeting capture and observes whether SCStream survives or degrades cleanly to mic-only.

**Files:**
- Create (after the run): `docs/superpowers/observations/2026-05-06-e5-reverify.md` (only if the user asks; skip otherwise)

- [ ] **Step 1: Hand off to user with instructions**

Tell the user: "Plan tasks 1-6 are complete. The 15-min real E5 reverify (spec §8) needs you to start a real meeting, run `bundle exec rake start:all`, talk + play system audio for 15 min, then `bundle exec rake stop:all`. Two outcomes both count as success:
- (a) Both mic and screen channels produce non-zero transcripts → core feature works as designed.
- (b) Screen SCStream errors out, but `spool/state.jsonl` shows a `kind:"channel_failed"` event for screen, mic transcripts continue, and the next mini-E5 / `rake test` still passes → mic-only degrade works as designed.

Either way, capture the outcome. If neither (a) nor (b) holds, that's a bug — capture `spool/state.jsonl` + `tmp/log/swiftcap.log` and we'll triage."

- [ ] **Step 2: After user reports outcome, optionally record observation**

Only if the user asks for a doc commit, write a 1-page `docs/superpowers/observations/2026-05-06-e5-reverify.md` summarizing which path (a or b) was hit and any caveats. Otherwise this is a closed loop.

---

## Self-Review

**Spec coverage map (against `docs/superpowers/specs/2026-05-06-core-feature-completion.md`):**

| Spec section | Tasks |
|---|---|
| §4 G1 (mic-only degrade)              | Task 2 (RED test), Task 3 (GREEN impl) |
| §5 G2 (channel-split L3)              | Task 4 |
| §6 G3 (rack-test for web)             | Task 5; §6.1 Gemfile already done |
| §7 G4 (Ruby 4.0.3)                    | Task 1 |
| §8 execution order                    | Task ordering matches: G4 → G1 RED → G1 GREEN → G2 → G3 → reverify |
| §9 commit boundaries                  | Each task ends with a single commit, RED/GREEN are separate where TDD applies |

**Out-of-scope items (left out by design, matches spec §1):** display selection UI, video frame-rate-zero optimization, SIGKILL fallback, websocket auth, chrome-mcp UI verification, PicoRuby:wasm frontend tests, transcripts backfill — none of these are touched.

**Placeholder scan:** every code block contains the actual code; every command shows the exact invocation; every assertion shows the expected outcome.

**Type / API consistency:**
- `screenChannelActive: Bool` is set in `startScreen` (Task 3 step 2), checked + cleared in `handleScreenStreamStopped` (Task 3 step 3), cleared in `shutdownRotate` (Task 3 step 5), driven from tests via `markScreenActiveForTesting()` (Task 3 step 1). Single name, single semantics.
- `WEBSOCKETS` constant is referenced as `TranscriptionWeb::WEBSOCKETS` in Task 5 — matches `web/app.rb` line 12 declaration.
- `count_transcripts_with_time(channel:)` is the only signature used; called from `capture_baseline` with both `'mic'` and `'screen'` args (Task 4 step 1).

**Schema fix:** spec §6.2 example seed had `INSERT INTO sessions (channel, started_at, ended_at)` but the migration declares `sessions` without a `channel` column. Plan Task 5 step 1 corrects to `INSERT INTO sessions (started_at, ended_at)` only.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-05-06-core-feature-completion.md`. Two execution options:

**1. Subagent-driven (recommended)** — fresh subagent per task, two-stage review between tasks, fast iteration. Best when you want each task verified before moving on.

**2. Inline execution** — execute tasks in this session via executing-plans, batched with checkpoints. Best when you want to watch each step land in real time.

Which approach do you want?

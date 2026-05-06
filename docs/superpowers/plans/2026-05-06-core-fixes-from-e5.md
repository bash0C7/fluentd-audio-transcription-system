# Core fixes from E5 (2026-05-06) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore mic recording, fix data contract leaks, and make `stop:all` graceful via PID files — so a 30-minute real meeting captures end-to-end without silent failure.

**Architecture:** Four convergent fixes (F1: mic observability, F2: data contract, F3: ack observation, F4: graceful PID-based stop) with TDD discipline (RED→GREEN→REFACTOR commits). Verified by a synthetic mini-E5 acceptance task that exercises all 5 layers in 30 seconds.

**Tech Stack:** Swift 6 (swiftcap, AVAudioEngine, ScreenCaptureKit, SpeechAnalyzer / Testing framework), Ruby 4.0.1 (Rakefile, Fluentd 1.18 plugins, test-unit), SQLite 3, macOS `afplay` / `screen` / `caffeinate`.

**Spec:** `docs/superpowers/specs/2026-05-06-core-fixes-from-e5.md`

---

## File Structure

### Files to create

| Path | Responsibility |
|---|---|
| `tmp/run/` | runtime PID file directory (gitignored) |
| `test/test_rake_lifecycle.rb` | Rake stop:* lifecycle tests with fake long-running processes |
| `test/fixtures/synthetic_e5_audio.wav` | 30s sine sweep WAV played through speakers during mini-E5 |
| `lib/audio_transcription/synthetic_e5.rb` | mini-E5 orchestration helper (start, play, sleep, stop, assert 5 layers) |
| `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorObservabilityTests.swift` | F1 process-level test for startMic stderr log |

### Files to modify

| Path | Change |
|---|---|
| `Rakefile` | rewrite `start:*` + `stop:*` to use PID files; add `start:caffeinate` / `stop:caffeinate`; add `test:e5_synthetic` |
| `web/puma.rb` | add `pidfile` DSL line |
| `.gitignore` | add `/tmp/run/` (already covered by `/tmp/` but explicit for clarity) |
| `swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift` | add `startedAt` storage; change `finalize` callback signature to `(URL, TimeInterval, TimeInterval) -> Void` |
| `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift` | startMic startup log + 5s first-buffer timeout; rotate emits `started_at`/`ended_at` in state.jsonl |
| `swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift` | final.jsonl emit adds `started_at` / `ended_at` / `language` from `result.audioTimeRange` and locale |
| `swift/swiftcap/Tests/SwiftcapTests/RotatingRecorderTests.swift` | update finalize callback expectations |
| `lib/fluent/plugin/filter_audio_state.rb` | drop `File.mtime` fallback; warn-and-drop events lacking `started_at`/`ended_at` |
| `test/fluent/test_filter_audio_state.rb` | update existing test to provide time fields; add new RED test for missing-fields drop |
| `test/fluent/test_out_sqlite_meeting_log.rb` | add explicit assertion that `transcripts.ended_at != 0.0` is persisted |

---

## Branch Setup

### Task 0: Create feature branch

**Files:** working tree only

- [ ] **Step 0.1: Confirm clean working tree before branching**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system
git status
```

Expected: `nothing to commit, working tree clean` (the only untracked path is `.claude/` which is fine to leave). If unexpected dirty files exist, surface them and stop.

- [ ] **Step 0.2: Create branch**

```bash
git switch -c feat/core-fixes-2026-05-06
```

Expected: `Switched to a new branch 'feat/core-fixes-2026-05-06'`

- [ ] **Step 0.3: Commit the design + plan docs (already in working tree)**

```bash
git add docs/superpowers/specs/2026-05-06-core-fixes-from-e5.md docs/superpowers/plans/2026-05-06-core-fixes-from-e5.md
git commit -m "docs: spec and plan for E5-driven core fixes"
```

Expected: 1 commit, 2 files added.

---

## F4: Graceful PID-based stop:all

### Task 1: tmp/run infrastructure + .gitignore

**Files:**
- Create: `tmp/run/.keep`
- Modify: `.gitignore`

- [ ] **Step 1.1: Create `tmp/run/.keep`** (so directory exists in fresh checkouts)

```bash
mkdir -p tmp/run
touch tmp/run/.keep
```

- [ ] **Step 1.2: Update `.gitignore` so the directory is tracked but contents are not**

Edit `.gitignore`. Currently it has `/tmp/` which excludes everything. Change:

```diff
 /spool/
-/tmp/
+/tmp/*
+!/tmp/run/
+/tmp/run/*
+!/tmp/run/.keep
 /.superpowers/
```

- [ ] **Step 1.3: Verify**

```bash
git status --porcelain | grep tmp/run/.keep
git check-ignore tmp/run/foo.pid
```

Expected: `.keep` is staged (untracked → tracked), `tmp/run/foo.pid` is matched as ignored.

- [ ] **Step 1.4: Commit**

```bash
git add .gitignore tmp/run/.keep
git commit -m "chore(tmp): track tmp/run/.keep; ignore PID files"
```

---

### Task 2: F4 RED test — `test/test_rake_lifecycle.rb`

**Files:**
- Create: `test/test_rake_lifecycle.rb`

- [ ] **Step 2.1: Write the failing test**

```ruby
# test/test_rake_lifecycle.rb
require 'test/unit'
require 'rake'
require 'fileutils'
require 'tmpdir'

class TestRakeLifecycle < Test::Unit::TestCase
  REPO_ROOT = File.expand_path('..', __dir__)

  def setup
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake.load_rakefile(File.join(REPO_ROOT, 'Rakefile'))
    @run_dir = File.join(REPO_ROOT, 'tmp', 'run')
    FileUtils.mkdir_p(@run_dir)
    @leftover_pids = []
  end

  def teardown
    @leftover_pids.each do |pid|
      Process.kill('KILL', pid) rescue nil
    end
  end

  # Spawns a process that responds to SIGTERM by exiting cleanly.
  # Writes its PID to the named pidfile so stop helper can find it.
  def spawn_graceful(name)
    pidfile = File.join(@run_dir, "#{name}.pid")
    pid = Process.spawn('ruby', '-e', %(
      File.write(#{pidfile.inspect}, Process.pid)
      trap('TERM') { exit 0 }
      loop { sleep 0.1 }
    ))
    @leftover_pids << pid
    # Wait until pid file is written
    20.times { break if File.exist?(pidfile); sleep 0.1 }
    [pid, pidfile]
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def test_stop_via_pidfile_kills_graceful_process_and_removes_pidfile
    pid, pidfile = spawn_graceful('lifecycle-test')

    # Invoke stop helper directly (helper lives in Rakefile after Task 3)
    stop_via_pidfile('lifecycle-test', 5, has_screen: false)

    # Assertions
    assert !alive?(pid), "process #{pid} should be dead after stop_via_pidfile"
    assert !File.exist?(pidfile), "pidfile should be removed"
  end

  def test_stop_via_pidfile_aborts_when_term_ignored
    pidfile = File.join(@run_dir, 'stubborn.pid')
    pid = Process.spawn('ruby', '-e', %(
      File.write(#{pidfile.inspect}, Process.pid)
      trap('TERM', 'IGNORE')
      loop { sleep 0.1 }
    ))
    @leftover_pids << pid
    20.times { break if File.exist?(pidfile); sleep 0.1 }

    assert_raise(SystemExit) do
      stop_via_pidfile('stubborn', 1, has_screen: false)
    end
    # process must still be alive — we did NOT escalate to SIGKILL
    assert alive?(pid), "stubborn process must remain alive (no SIGKILL fallback)"
  end
end
```

- [ ] **Step 2.2: Run to confirm RED**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system
bundle exec rake test TEST=test/test_rake_lifecycle.rb 2>&1 | tail -20
```

Expected: failures with `NoMethodError: undefined method 'stop_via_pidfile'` or similar. RED confirmed.

- [ ] **Step 2.3: Commit RED**

```bash
git add test/test_rake_lifecycle.rb
git commit -m "test: add failing spec for stop_via_pidfile helper"
```

---

### Task 3: F4 GREEN — `stop_via_pidfile` helper in Rakefile

**Files:**
- Modify: `Rakefile:1-100` (whole namespace block + helpers)

- [ ] **Step 3.1: Add helpers to top of Rakefile** (above `namespace :start`)

After existing `LOG_DIR = File.join(REPO_ROOT, 'tmp', 'log')` line, add:

```ruby
RUN_DIR = File.join(REPO_ROOT, 'tmp', 'run')

# wait_sec table per CLAUDE.md graceful-shutdown discipline
# (CAF rotation, fluentd buffer flush, puma drain, etc).
WAIT_SEC = { 'swiftcap' => 30, 'fluentd' => 60, 'web' => 10, 'caffeinate' => 5 }.freeze

def process_alive?(pid)
  return false if pid.nil? || pid <= 0
  Process.kill(0, pid)
  true
rescue Errno::ESRCH, Errno::EPERM
  false
end

# Graceful, single-SIGTERM stop. Reads pidfile, sends TERM, waits up to wait_sec.
# Aborts (no SIGKILL escalation) if the process refuses to exit — silent SIGKILL
# during graceful drain costs transcripts.
def stop_via_pidfile(name, wait_sec, has_screen: true)
  pidfile = File.join(RUN_DIR, "#{name}.pid")
  if File.exist?(pidfile)
    pid = File.read(pidfile).to_i
    if process_alive?(pid)
      puts "stopping #{name} (pid=#{pid}), waiting up to #{wait_sec}s for graceful shutdown..."
      begin
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        # raced — process already gone
      end
      deadline = Time.now + wait_sec
      sleep(0.2) while process_alive?(pid) && Time.now < deadline
      if process_alive?(pid)
        abort "#{name} did not exit within #{wait_sec}s (pid=#{pid}). Investigate — do NOT SIGKILL: graceful drain failure indicates a bug in the service."
      end
      puts "stopped: #{name}"
    else
      puts "stale pidfile for #{name} (pid=#{pid} not alive)"
    end
    File.delete(pidfile) rescue nil
  else
    puts "no pidfile: #{name}"
  end
  system("screen -X -S audio-#{name} quit > /dev/null 2>&1") if has_screen
end
```

- [ ] **Step 3.2: Run RED test again to confirm GREEN**

```bash
bundle exec rake test TEST=test/test_rake_lifecycle.rb 2>&1 | tail -10
```

Expected: 2 tests, 0 failures, 0 errors.

- [ ] **Step 3.3: Commit GREEN**

```bash
git add Rakefile
git commit -m "feat(rake): add stop_via_pidfile helper with SIGTERM+wait, no SIGKILL"
```

---

### Task 4: F4 puma — pidfile DSL + Rakefile integration

**Files:**
- Modify: `web/puma.rb`
- Modify: `Rakefile` `namespace :start` `:web` task and `namespace :stop` `:web` task

- [ ] **Step 4.1: Update `web/puma.rb` with `pidfile` DSL**

```ruby
# web/puma.rb
port ENV.fetch('PORT', 9292)
threads 4, 8
environment ENV.fetch('RACK_ENV', 'development')
plugin :tmp_restart
pidfile File.expand_path('../tmp/run/puma.pid', __dir__)
```

- [ ] **Step 4.2: Update `Rakefile` `start:web` task**

Replace existing `start:web` body with:

```ruby
  desc 'Start puma web server in screen session "audio-web"'
  task web: 'db:migrate' do
    FileUtils.mkdir_p([LOG_DIR, RUN_DIR, File.dirname(DB_PATH)])
    sh "screen -dmS audio-web bash -c 'cd #{REPO_ROOT} && DB_PATH=#{DB_PATH} bundle exec puma -C web/puma.rb web/config.ru > #{LOG_DIR}/web.log 2>&1; echo DONE: exit=$? >> #{LOG_DIR}/web.log'"
    puts "started: audio-web (log: #{LOG_DIR}/web.log → http://localhost:9292/)"
  end
```

(No change in shell command — puma writes its own pidfile via DSL.)

- [ ] **Step 4.3: Replace `stop:web` task body**

```ruby
  desc 'Stop audio-web (graceful via puma pidfile)'
  task :web do
    stop_via_pidfile('web', WAIT_SEC['web'], has_screen: true)
  end
```

(Remove the old `pkill -TERM -x puma` + sleep 3 + screen quit block.)

- [ ] **Step 4.4: Manual verify — start, hit, stop**

```bash
bundle exec rake start:web
sleep 3
ls tmp/run/puma.pid && cat tmp/run/puma.pid
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9292/
bundle exec rake stop:web
ls tmp/run/puma.pid 2>&1 || echo "pidfile cleaned ✓"
pgrep -f "puma -C web/puma.rb" || echo "puma fully gone ✓"
```

Expected: puma started, pidfile exists, curl 200, pidfile cleaned, no puma left.

- [ ] **Step 4.5: Commit**

```bash
git add web/puma.rb Rakefile
git commit -m "feat(web): use puma pidfile DSL; rake stop:web via stop_via_pidfile"
```

---

### Task 5: F4 fluentd — daemon mode (`-d <pidfile>`)

**Files:**
- Modify: `Rakefile` `start:fluentd` and `stop:fluentd` tasks

- [ ] **Step 5.1: Replace `start:fluentd` task body**

```ruby
  desc 'Start fluentd as daemon (writes pidfile via -d, no screen wrapping)'
  task fluentd: 'db:migrate' do
    FileUtils.mkdir_p([SPOOL_DIR, LOG_DIR, RUN_DIR, File.dirname(DB_PATH)])
    %w[quick.jsonl final.jsonl sound.jsonl state.jsonl].each do |f|
      FileUtils.touch(File.join(SPOOL_DIR, f))
    end
    pidfile = File.join(RUN_DIR, 'fluentd.pid')
    File.delete(pidfile) if File.exist?(pidfile) && !process_alive?(File.read(pidfile).to_i)
    abort "fluentd appears to be running (pid=#{File.read(pidfile)})" if File.exist?(pidfile)
    sh({
      'SPOOL_DIR' => SPOOL_DIR,
      'DB_PATH' => DB_PATH
    }, "bundle exec fluentd -c config/fluent.conf -p lib/fluent/plugin -d #{pidfile} -o #{LOG_DIR}/fluentd.log")
    # fluentd -d backgrounds itself; rake's sh returns when daemonization completes.
    20.times { break if File.exist?(pidfile); sleep 0.2 }
    abort "fluentd failed to write pidfile" unless File.exist?(pidfile)
    puts "started: fluentd (pid=#{File.read(pidfile)}, log: #{LOG_DIR}/fluentd.log)"
  end
```

- [ ] **Step 5.2: Replace `stop:fluentd` task body**

```ruby
  desc 'Stop fluentd (graceful via pidfile, no screen)'
  task :fluentd do
    stop_via_pidfile('fluentd', WAIT_SEC['fluentd'], has_screen: false)
  end
```

- [ ] **Step 5.3: Manual verify**

```bash
bundle exec rake start:fluentd
sleep 3
cat tmp/run/fluentd.pid
ps -p $(cat tmp/run/fluentd.pid) || echo "fluentd not running"
bundle exec rake stop:fluentd
ls tmp/run/fluentd.pid 2>&1 || echo "pidfile cleaned ✓"
pgrep -f "fluentd -c config/fluent.conf" || echo "fluentd fully gone ✓"
```

Expected: fluentd starts as daemon, pidfile cleaned on stop, no leftover process.

- [ ] **Step 5.4: Commit**

```bash
git add Rakefile
git commit -m "feat(fluent): rake start/stop:fluentd via daemon mode pidfile"
```

---

### Task 6: F4 swiftcap + caffeinate — bash wrapper PID

**Files:**
- Modify: `Rakefile` `start:swiftcap` and `stop:swiftcap` tasks; add `start:caffeinate` and `stop:caffeinate`

- [ ] **Step 6.1: Replace `start:swiftcap` body**

```ruby
  desc 'Start swiftcap in screen session "audio-swiftcap" with PID file'
  task :swiftcap do
    unless File.executable?(SWIFTCAP_BIN)
      sh 'cd swift/swiftcap && swift build -c release'
    end
    FileUtils.mkdir_p([SPOOL_DIR, LOG_DIR, RUN_DIR])
    locale = ENV['SWIFTCAP_LOCALE'] || 'ja-JP'
    pidfile = File.join(RUN_DIR, 'swiftcap.pid')
    sh "screen -dmS audio-swiftcap bash -c 'echo $$ > #{pidfile}; SWIFTCAP_SPOOL=#{SPOOL_DIR} SWIFTCAP_LOCALE=#{locale} exec #{SWIFTCAP_BIN} > #{LOG_DIR}/swiftcap.log 2>&1; echo DONE: exit=$? >> #{LOG_DIR}/swiftcap.log'"
    20.times { break if File.exist?(pidfile); sleep 0.2 }
    puts "started: audio-swiftcap (pid=#{File.read(pidfile).strip rescue '?'}, log: #{LOG_DIR}/swiftcap.log)"
  end
```

(Note: `bash -c 'echo $$ > pidfile; ... exec ...'` writes the bash's PID, then `exec` replaces bash with swiftcap so the PID is correct.)

- [ ] **Step 6.2: Replace `stop:swiftcap` body**

```ruby
  desc 'Stop audio-swiftcap (graceful via pidfile + screen quit)'
  task :swiftcap do
    stop_via_pidfile('swiftcap', WAIT_SEC['swiftcap'], has_screen: true)
  end
```

- [ ] **Step 6.3: Add `start:caffeinate` and `stop:caffeinate`**

Inside `namespace :start`:

```ruby
  desc 'Start caffeinate (-dimsu) in screen session to prevent sleep during E5'
  task :caffeinate do
    FileUtils.mkdir_p([LOG_DIR, RUN_DIR])
    pidfile = File.join(RUN_DIR, 'caffeinate.pid')
    sh "screen -dmS audio-caffeinate bash -c 'echo $$ > #{pidfile}; exec caffeinate -dimsu > #{LOG_DIR}/caffeinate.log 2>&1; echo DONE: exit=$? >> #{LOG_DIR}/caffeinate.log'"
    20.times { break if File.exist?(pidfile); sleep 0.2 }
    puts "started: audio-caffeinate (pid=#{File.read(pidfile).strip rescue '?'})"
  end
```

Inside `namespace :stop`:

```ruby
  desc 'Stop audio-caffeinate (graceful via pidfile + screen quit)'
  task :caffeinate do
    stop_via_pidfile('caffeinate', WAIT_SEC['caffeinate'], has_screen: true)
  end
```

- [ ] **Step 6.4: Update `start:all` and `stop:all` to include caffeinate**

```ruby
  desc 'Start all 4 services (swiftcap, fluentd, web, caffeinate)'
  task all: %w[start:caffeinate start:swiftcap start:fluentd start:web]
```

```ruby
  desc 'Stop all 4 services in graceful order (swiftcap first stops new data; caffeinate last)'
  task all: %w[stop:swiftcap stop:fluentd stop:web stop:caffeinate]
```

- [ ] **Step 6.5: Manual verify (full cycle)**

```bash
bundle exec rake start:all
sleep 5
ls tmp/run/*.pid
bundle exec rake status
bundle exec rake stop:all
ls tmp/run/*.pid 2>&1 || echo "all pidfiles cleaned ✓"
pgrep -f "swiftcap|fluentd -c config|puma -C web|caffeinate -dimsu" || echo "all services gone ✓"
```

Expected: 4 pidfiles after start, none after stop, no straggler.

- [ ] **Step 6.6: Commit**

```bash
git add Rakefile
git commit -m "feat(rake): swiftcap+caffeinate pidfile via bash exec wrapper; reorder start/stop:all"
```

---

### Task 7: F4 REFACTOR — remove `GRACEFUL_PROCS` map

**Files:**
- Modify: `Rakefile` `namespace :stop` block

- [ ] **Step 7.1: Remove obsolete code**

In `namespace :stop`, delete the `GRACEFUL_PROCS = { ... }` constant and the `%w[swiftcap fluentd web].each do |name| ... end` dynamic block (Task 4-6 replaced them with explicit task definitions).

- [ ] **Step 7.2: Verify all stop tasks still work**

```bash
bundle exec rake -T stop
```

Expected: lists `stop:caffeinate`, `stop:fluentd`, `stop:swiftcap`, `stop:web`, `stop:all`.

- [ ] **Step 7.3: Run full lifecycle test once more**

```bash
bundle exec rake test TEST=test/test_rake_lifecycle.rb
```

Expected: 2 tests pass.

- [ ] **Step 7.4: Commit**

```bash
git add Rakefile
git commit -m "refactor(rake): drop obsolete GRACEFUL_PROCS dynamic stop block"
```

---

## F1: Mic input observability

### Task 8: F1 GREEN — startMic startup log + first-buffer log + 5s timeout

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift:124-140`

(F1 unit testing AVAudioEngine startup is impractical without invasive injection — see spec §4. We rely on the synthetic mini-E5 in Task 13 to verify the new log lines appear and that mic produces non-silent CAF. This task adds the observability code only.)

- [ ] **Step 8.1: Replace `startMic()` body** in `CaptureCoordinator.swift`

```swift
    private func startMic() async throws {
        let format = Self.targetFormat
        let input = micEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: format)
        let firstBufferLogged = ConvertOnce()
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            if firstBufferLogged.fire() {
                FileHandle.standardError.write(
                    "MicAudioOutput: first buffer received format=\(buffer.format)\n".data(using: .utf8)!
                )
            }
            let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity)!
            var error: NSError?
            converter?.convert(to: outBuffer, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            Task { await self.feed(channel: "mic", buffer: outBuffer, time: time) }
        }
        try micEngine.start()
        FileHandle.standardError.write(
            "startMic: input running format=\(inputFormat) → \(format)\n".data(using: .utf8)!
        )

        // Loud failure if no buffer arrives within 5s — prevents silent silence
        // (the bug observed in 2026-05-06 E5 where mic captured nothing for 22 minutes).
        try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        // After 5s, firstBufferLogged.fire() returns false if it was already
        // tripped by the tap (good); returns true if no buffer ever fired (bad — fail).
        let neverFired = ConvertOnce()
        // We can't inspect ConvertOnce.fired directly; re-check by attempting fire on a
        // proxy. Simpler: flip the contract to a checker.
        // (Note: this implementation uses a separate sentinel in next step — see §8.2.)
    }
```

(The `firstBufferLogged` ConvertOnce is reused as both a once-gate AND a "did fire?" check. Since `ConvertOnce.fired` is private, we add an `isFired` accessor in the next step.)

- [ ] **Step 8.2: Add `isFired` accessor to `ConvertOnce`** in `TranscriberWrapper.swift:133-143`

Replace:

```swift
final class ConvertOnce: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
    /// Read-only check whether fire() has been called.
    var isFired: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}
```

- [ ] **Step 8.3: Use `isFired` for the timeout check** in `startMic()` end (replace from "// Loud failure if no buffer..." comment to end of function):

```swift
        try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        if !firstBufferLogged.isFired {
            throw NSError(
                domain: "swiftcap.mic",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no mic buffer in 5s — check Microphone permission and System Settings → Privacy & Security → Microphone"]
            )
        }
    }
```

- [ ] **Step 8.4: Build & smoke**

```bash
cd swift/swiftcap && swift build -c release
cd ../..
ls -la swift/swiftcap/.build/release/swiftcap
```

Expected: build succeeds, binary exists.

- [ ] **Step 8.5: Run swiftcap binary briefly** to confirm log lines (manual on local machine with mic granted)

```bash
mkdir -p /tmp/swiftcap-smoke && rm -f /tmp/swiftcap-smoke/*.{caf,jsonl}
SWIFTCAP_SPOOL=/tmp/swiftcap-smoke timeout 8 swift/swiftcap/.build/release/swiftcap 2>&1 | grep -E "startMic|MicAudioOutput|startScreen"
```

Expected (if mic permission OK):
```
startMic: input running format=...
MicAudioOutput: first buffer received format=...
startScreen: capturing display=... requested 16kHz mono
ScreenAudioOutput: first buffer received format=...
```

If mic permission missing, the binary exits with `Error: no mic buffer in 5s — check Microphone permission ...`. That **is** the desired loud failure.

- [ ] **Step 8.6: Commit**

```bash
git add swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift
git commit -m "fix(swiftcap): startMic startup+first-buffer logs and 5s loud-failure timeout"
```

---

## F2: Data contract completeness

### Task 9: F2 GREEN+REFACTOR — RotatingRecorder carries startedAt/endedAt

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift`
- Modify: `swift/swiftcap/Tests/SwiftcapTests/RotatingRecorderTests.swift`

- [ ] **Step 9.1: Update existing test to expect new callback signature (RED)**

Replace existing tests in `RotatingRecorderTests.swift` to use new `(URL, TimeInterval, TimeInterval)` callback:

```swift
// swift/swiftcap/Tests/SwiftcapTests/RotatingRecorderTests.swift
import Foundation
import AVFoundation
import Testing
@testable import Swiftcap

@Suite
struct RotatingRecorderTests {
    @Test
    func finalizeProducesCAFFile() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = RotatingRecorder(channel: "mic", spoolDir: tmp)
        try recorder.start(at: Date(timeIntervalSince1970: 1735689600))
        let buffer = try makeSilentBuffer(seconds: 1)
        try recorder.append(buffer)

        let result: (url: URL, startedAt: TimeInterval, endedAt: TimeInterval) =
            await withCheckedContinuation { (cont: CheckedContinuation<(URL, TimeInterval, TimeInterval), Never>) in
                recorder.finalize { url, startedAt, endedAt in
                    cont.resume(returning: (url, startedAt, endedAt))
                }
            }
        #expect(result.url.lastPathComponent.hasPrefix("mic-"))
        #expect(result.url.lastPathComponent.hasSuffix(".caf"))
        #expect(FileManager.default.fileExists(atPath: result.url.path))
    }

    @Test
    func finalizeCallbackCarriesStartedAndEndedAt() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let startDate = Date(timeIntervalSince1970: 1735689600)
        let recorder = RotatingRecorder(channel: "mic", spoolDir: tmp)
        try recorder.start(at: startDate)
        try recorder.append(try makeSilentBuffer(seconds: 1))

        let beforeFinalize = Date().timeIntervalSince1970
        let result = await withCheckedContinuation { (cont: CheckedContinuation<(URL, TimeInterval, TimeInterval), Never>) in
            recorder.finalize { url, startedAt, endedAt in
                cont.resume(returning: (url, startedAt, endedAt))
            }
        }

        #expect(result.1 == startDate.timeIntervalSince1970, "startedAt must equal start(at:) date")
        #expect(result.2 >= beforeFinalize, "endedAt must be >= time finalize was called")
    }

    @Test
    func appendedBufferProducesNonEmptyCAF() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = RotatingRecorder(channel: "mic", spoolDir: tmp)
        try recorder.start(at: Date(timeIntervalSince1970: 1735689600))
        try recorder.append(try makeSilentBuffer(seconds: 1))

        let result = await withCheckedContinuation { (cont: CheckedContinuation<(URL, TimeInterval, TimeInterval), Never>) in
            recorder.finalize { url, startedAt, endedAt in
                cont.resume(returning: (url, startedAt, endedAt))
            }
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: result.0.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(bytes > 1024, "expected encoded CAF to be > 1KB, got \(bytes) bytes")

        let opened = try AVAudioFile(forReading: result.0)
        #expect(opened.length > 0, "AVAudioFile reports zero frames")
    }

    private func makeSilentBuffer(seconds: Int) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        return buf
    }
}
```

- [ ] **Step 9.2: Run swift test to confirm RED**

```bash
cd swift/swiftcap && swift test 2>&1 | tail -20
```

Expected: compile errors / test failures around `finalize { url, startedAt, endedAt in ... }` because callback type doesn't match.

- [ ] **Step 9.3: Update `RotatingRecorder` to match new callback signature (GREEN)**

Replace `RotatingRecorder.swift`:

```swift
// swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift
@preconcurrency import AVFoundation
import Foundation

final class RotatingRecorder: @unchecked Sendable {
    private let channel: String
    private let spoolDir: URL
    private var currentURL: URL?
    private var assetWriter: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startedAt: TimeInterval = 0
    private let queue = DispatchQueue(label: "swiftcap.recorder")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(channel: String, spoolDir: URL) {
        self.channel = channel
        self.spoolDir = spoolDir
    }

    func start(at date: Date = Date()) throws {
        try queue.sync {
            let stamp = Self.formatter.string(from: date)
            let url = spoolDir.appendingPathComponent("\(channel)-\(stamp).caf")
            currentURL = url
            startedAt = date.timeIntervalSince1970
            let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC_HE,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 16000,
                AVEncoderBitRateKey: 32000
            ]
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            writerInput.expectsMediaDataInRealTime = true
            writer.add(writerInput)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            self.assetWriter = writer
            self.input = writerInput
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self,
                  let input = self.input,
                  input.isReadyForMoreMediaData,
                  let sampleBuffer = buffer.toCMSampleBuffer() else { return }
            input.append(sampleBuffer)
        }
    }

    func finalize(_ completion: @escaping @Sendable (URL, TimeInterval, TimeInterval) -> Void) {
        queue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let input = self.input,
                  let url = self.currentURL else { return }
            let startedAt = self.startedAt
            input.markAsFinished()
            writer.finishWriting {
                let endedAt = Date().timeIntervalSince1970
                self.assetWriter = nil
                self.input = nil
                self.currentURL = nil
                completion(url, startedAt, endedAt)
            }
        }
    }
}

// (toCMSampleBuffer extension unchanged — keep below this line)
```

(Keep the `extension AVAudioPCMBuffer { func toCMSampleBuffer() ... }` below unchanged.)

- [ ] **Step 9.4: Run swift test to confirm GREEN**

```bash
cd swift/swiftcap && swift test 2>&1 | tail -20
```

Expected: 3 RotatingRecorder tests pass.

- [ ] **Step 9.5: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system
git add swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift swift/swiftcap/Tests/SwiftcapTests/RotatingRecorderTests.swift
git commit -m "feat(swiftcap): RotatingRecorder finalize callback carries startedAt/endedAt"
```

---

### Task 10: F2 GREEN — CaptureCoordinator emits started_at/ended_at in state.jsonl rotated

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift:95-113`

- [ ] **Step 10.1: Replace `rotate(channel:recorder:reason:)` body**

```swift
    private func rotate(channel: String, recorder: RotatingRecorder, reason: String) async {
        FileHandle.standardError.write("rotate[\(channel)]: finalize begin\n".data(using: .utf8)!)
        let finalized: (path: String, bytes: Int, startedAt: TimeInterval, endedAt: TimeInterval) =
            await withCheckedContinuation { (cont: CheckedContinuation<(String, Int, TimeInterval, TimeInterval), Never>) in
                recorder.finalize { url, startedAt, endedAt in
                    let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                    let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
                    cont.resume(returning: (url.path, bytes, startedAt, endedAt))
                }
            }
        FileHandle.standardError.write("rotate[\(channel)]: finalize done bytes=\(finalized.bytes)\n".data(using: .utf8)!)
        try? stateWriter.append([
            "ts": Date().timeIntervalSince1970,
            "kind": "rotated",
            "channel": channel,
            "path": finalized.path,
            "bytes": finalized.bytes,
            "started_at": finalized.startedAt,
            "ended_at": finalized.endedAt,
            "reason": reason
        ])
    }
```

- [ ] **Step 10.2: Build to confirm**

```bash
cd swift/swiftcap && swift build -c release 2>&1 | tail -5
```

Expected: clean build, no warnings about unused values.

- [ ] **Step 10.3: Run tests**

```bash
swift test 2>&1 | tail -10
```

Expected: all swift tests pass (RotatingRecorder + Smoke + others).

- [ ] **Step 10.4: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system
git add swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift
git commit -m "feat(swiftcap): emit started_at/ended_at in state.jsonl rotated event"
```

---

### Task 11: F2 GREEN — TranscriberWrapper emits started_at/ended_at/language in final.jsonl

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift`

- [ ] **Step 11.1: Capture locale on init and use in emit**

Modify `TranscriberWrapper`:

1. Add `private let locale: Locale` stored property after `private let channel: String`.
2. In `init`, after the existing line `self.channel = channel`, add: `self.locale = locale`.
3. Replace the `for try await result in self.transcriber.results` block (line 57-77) with:

```swift
                for try await result in self.transcriber.results {
                    let transcriptId = UUID().uuidString
                    let text = String(result.text.characters)
                    let now = Date().timeIntervalSince1970
                    let startedAt = result.range.start.seconds
                    let endedAt = result.range.end.seconds
                    if result.isFinal {
                        try? self.finalWriter.append([
                            "ts": now,
                            "ch": self.channel,
                            "kind": "final",
                            "text": text,
                            "started_at": startedAt,
                            "ended_at": endedAt,
                            "language": self.locale.identifier(.bcp47),
                            "transcript_id": transcriptId
                        ])
                    } else {
                        try? self.quickWriter.append([
                            "ts": now,
                            "ch": self.channel,
                            "kind": "volatile",
                            "text": text,
                            "transcript_id": transcriptId
                        ])
                    }
                }
```

(`result.range` returns a `CMTimeRange` for `.audioTimeRange` attributeOption — `.start.seconds` and `.end.seconds` give Double seconds since the start of the analyzer input sequence. SpeechTranscriber `attributeOptions: [.audioTimeRange]` is already configured at line 32.)

- [ ] **Step 11.2: Build to confirm API**

```bash
cd swift/swiftcap && swift build -c release 2>&1 | tail -10
```

If `result.range` is not the correct API, the build fails with a clear message. Likely candidates if it differs: `result.audioTimeRange`, `result.timeRange`. Adjust based on compiler error and re-build. The point is: take `started_at`/`ended_at` from the SpeechTranscriber result's audio-time-range attribute.

- [ ] **Step 11.3: Run swift tests**

```bash
swift test 2>&1 | tail -10
```

Expected: pass.

- [ ] **Step 11.4: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system
git add swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift
git commit -m "feat(swiftcap): emit started_at/ended_at/language in final.jsonl"
```

---

### Task 12: F2 — filter_audio_state strict contract (drop on missing fields)

**Files:**
- Modify: `lib/fluent/plugin/filter_audio_state.rb`
- Modify: `test/fluent/test_filter_audio_state.rb`

- [ ] **Step 12.1: Update RED test for strict drop**

Replace `test/fluent/test_filter_audio_state.rb` with:

```ruby
# test/fluent/test_filter_audio_state.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_audio_state'
require 'fileutils'
require 'tmpdir'

class TestFilterAudioState < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('audio-state-')
    @caf = File.join(@tmp, 'mic-20260505-120000.caf')
    File.binwrite(@caf, "FAKE_CAF_BYTES_ ")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver(conf = '')
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::AudioStateFilter).configure(conf)
  end

  def test_rotated_event_loads_blob_and_emits_segment
    d = create_driver
    started_at = 1000.0
    ended_at = 1305.0
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'ts' => Time.now.to_f,
        'kind' => 'rotated',
        'channel' => 'mic',
        'path' => @caf,
        'bytes' => File.size(@caf),
        'started_at' => started_at,
        'ended_at' => ended_at
      })
    end
    events = d.filtered_records
    assert_equal 1, events.size
    rec = events.first
    assert_equal 'mic', rec['channel']
    assert_equal @caf, rec['path']
    assert_equal File.binread(@caf).bytesize, rec['blob'].bytesize
    assert_equal 'aac', rec['codec']
    assert_equal 16000, rec['sample_rate']
    assert_equal started_at, rec['started_at']
    assert_equal ended_at, rec['ended_at']
    assert_in_delta (ended_at - started_at), rec['duration_sec'], 0.001
  end

  def test_rotated_event_without_time_fields_is_dropped
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'ts' => Time.now.to_f,
        'kind' => 'rotated',
        'channel' => 'mic',
        'path' => @caf,
        'bytes' => File.size(@caf)
        # NO started_at / ended_at — must be dropped under new contract
      })
    end
    assert_equal 0, d.filtered_records.size, 'rotated event without time fields must be dropped'
  end

  def test_non_rotated_events_are_dropped
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, { 'kind' => 'heartbeat' })
    end
    assert_equal 0, d.filtered_records.size
  end
end
```

- [ ] **Step 12.2: Run to confirm RED on the new drop test**

```bash
bundle exec rake test TEST=test/fluent/test_filter_audio_state.rb 2>&1 | tail -10
```

Expected: `test_rotated_event_without_time_fields_is_dropped` fails (because filter currently fills mtime fallback and emits the record).

- [ ] **Step 12.3: Update `lib/fluent/plugin/filter_audio_state.rb` to strict mode**

Replace whole file:

```ruby
# lib/fluent/plugin/filter_audio_state.rb
require 'fluent/plugin/filter'

module Fluent
  module Plugin
    class AudioStateFilter < Fluent::Plugin::Filter
      Fluent::Plugin.register_filter('audio_state', self)

      def filter(_tag, _time, record)
        return nil unless record['kind'] == 'rotated'
        path = record['path']
        return nil unless path && File.file?(path)
        unless record['started_at'] && record['ended_at']
          log.warn 'rotated event missing started_at/ended_at, dropping (contract violation)', record: record.reject { |k, _| k == 'blob' }
          return nil
        end
        blob = File.binread(path)
        started_at = record['started_at'].to_f
        ended_at = record['ended_at'].to_f
        {
          'channel' => record['channel'],
          'path' => path,
          'started_at' => started_at,
          'ended_at' => ended_at,
          'duration_sec' => ended_at - started_at,
          'codec' => 'aac',
          'sample_rate' => 16000,
          'bytes' => blob.bytesize,
          'blob' => blob
        }
      end
    end
  end
end
```

- [ ] **Step 12.4: Run tests to confirm GREEN**

```bash
bundle exec rake test TEST=test/fluent/test_filter_audio_state.rb 2>&1 | tail -10
```

Expected: 3 tests, 0 failures.

- [ ] **Step 12.5: Add explicit non-zero ended_at assertion in out_sqlite_meeting_log test**

Edit `test/fluent/test_out_sqlite_meeting_log.rb`. After the existing `test_writes_final_creates_session_and_transcript` test, add:

```ruby
  def test_final_persists_nonzero_started_and_ended_at
    d = create_driver
    started_at = 5000.123
    ended_at = 5005.456
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, {
        'ch' => 'screen', 'kind' => 'final', 'text' => 'hello',
        'started_at' => started_at, 'ended_at' => ended_at, 'language' => 'ja-JP',
        'transcript_id' => 'u-final-time'
      })
    end
    db = SQLite3::Database.new(@db_path, readonly: true)
    db.results_as_hash = true
    begin
      row = db.execute('SELECT started_at, ended_at, language FROM transcripts WHERE swiftcap_transcript_id=?', ['u-final-time']).first
      assert_not_nil row
      assert_in_delta started_at, row['started_at'], 0.001
      assert_in_delta ended_at, row['ended_at'], 0.001
      assert_equal 'ja-JP', row['language']
    ensure
      db.close
    end
  end
```

- [ ] **Step 12.6: Run all Ruby tests**

```bash
bundle exec rake test 2>&1 | tail -10
```

Expected: all pass (existing + new).

- [ ] **Step 12.7: Commit**

```bash
git add lib/fluent/plugin/filter_audio_state.rb test/fluent/test_filter_audio_state.rb test/fluent/test_out_sqlite_meeting_log.rb
git commit -m "feat(fluent): enforce started_at/ended_at contract in filter_audio_state"
```

---

## Synthetic mini-E5 (acceptance test)

### Task 13: mini-E5 fixture WAV + rake task

**Files:**
- Create: `test/fixtures/synthetic_e5_audio.wav` (binary)
- Create: `lib/audio_transcription/synthetic_e5.rb`
- Modify: `Rakefile` (add `test:e5_synthetic`)

- [ ] **Step 13.1: Generate fixture WAV** (30s sine sweep, ≈30 KB)

Use macOS built-ins (no external dep):

```bash
mkdir -p test/fixtures
# 30-second 440Hz pure tone, 16kHz mono, signed 16-bit PCM WAV (~960KB; use `say` if you want voice)
ruby -e '
require "fileutils"
sample_rate = 16000
duration_sec = 30
num_samples = sample_rate * duration_sec
# WAV header (44 bytes) + data
data = (0...num_samples).map { |i|
  freq = 200 + (1000 * i / num_samples.to_f) # 200Hz → 1200Hz sweep
  amp = 16000
  ((Math.sin(2 * Math::PI * freq * i / sample_rate.to_f)) * amp).to_i
}.pack("s<*")
File.open("test/fixtures/synthetic_e5_audio.wav", "wb") do |f|
  f.write("RIFF")
  f.write([36 + data.bytesize].pack("V"))
  f.write("WAVEfmt ")
  f.write([16, 1, 1, sample_rate, sample_rate * 2, 2, 16].pack("VvvVVvv"))
  f.write("data")
  f.write([data.bytesize].pack("V"))
  f.write(data)
end
puts "wrote: " + File.size("test/fixtures/synthetic_e5_audio.wav").to_s + " bytes"
'
```

Expected: `wrote: 960044 bytes` (or similar, ~960 KB).

- [ ] **Step 13.2: Verify with afplay (briefly, listen for tone)**

```bash
afplay -t 1 test/fixtures/synthetic_e5_audio.wav  # plays 1 second
```

Expected: hear a short tone.

- [ ] **Step 13.3: Create `lib/audio_transcription/synthetic_e5.rb`**

```ruby
# lib/audio_transcription/synthetic_e5.rb
require 'sqlite3'
require 'json'

module AudioTranscription
  class SyntheticE5
    LAYERS = %i[L1_swiftcap L2_fluentd L3_sqlite L4_ack L5_processes].freeze

    SILENCE_RMS_THRESHOLD = 200  # for Int16 PCM samples; below ≈ silent room
    REPO_ROOT = File.expand_path('../..', __dir__)

    attr_reader :failures

    def initialize(repo_root: REPO_ROOT)
      @repo_root = repo_root
      @spool_dir = File.join(@repo_root, 'spool')
      @db_path   = File.join(@repo_root, 'db', 'meeting_log.sqlite')
      @log_dir   = File.join(@repo_root, 'tmp', 'log')
      @run_dir   = File.join(@repo_root, 'tmp', 'run')
      @fixture   = File.join(@repo_root, 'test', 'fixtures', 'synthetic_e5_audio.wav')
      @failures  = []
      @baseline  = {}
    end

    # Run the whole flow and return failures (empty array == pass).
    def run
      capture_baseline
      sh('bundle exec rake start:all') or fail!(:start, 'start:all failed')
      sleep 5
      afplay_pid = Process.spawn('afplay', @fixture, [:out, :err] => '/dev/null')
      sleep 30
      Process.kill('TERM', afplay_pid) rescue nil
      Process.wait(afplay_pid) rescue nil
      sh('bundle exec rake stop:all') or fail!(:stop, 'stop:all failed')
      verify_layers
      @failures
    end

    private

    def capture_baseline
      @baseline[:cafs] = Dir.glob(File.join(@spool_dir, '*.caf'))
      @baseline[:rotated_count] = count_rotated
      @baseline[:ack_count] = count_ack
      @baseline[:transcripts_with_time] = count_transcripts_with_time
    end

    def verify_layers
      verify_l1_swiftcap
      verify_l2_fluentd
      verify_l3_sqlite
      verify_l4_ack
      verify_l5_processes
    end

    def verify_l1_swiftcap
      new_cafs = Dir.glob(File.join(@spool_dir, '*.caf')) - @baseline[:cafs]
      mics = new_cafs.select { |p| File.basename(p).start_with?('mic-') }
      screens = new_cafs.select { |p| File.basename(p).start_with?('screen-') }
      fail!(:L1, 'no new mic-*.caf produced during synthetic run') if mics.empty?
      fail!(:L1, 'no new screen-*.caf produced during synthetic run') if screens.empty?
      mics.each do |p|
        rms = caf_rms(p)
        fail!(:L1, "mic CAF rms=#{rms} <= silence threshold #{SILENCE_RMS_THRESHOLD} (#{File.basename(p)})") if rms <= SILENCE_RMS_THRESHOLD
      end
      screens.each do |p|
        rms = caf_rms(p)
        fail!(:L1, "screen CAF rms=#{rms} <= silence threshold #{SILENCE_RMS_THRESHOLD} (#{File.basename(p)})") if rms <= SILENCE_RMS_THRESHOLD
      end
    end

    def verify_l2_fluentd
      log_path = File.join(@log_dir, 'fluentd.log')
      return fail!(:L2, "fluentd.log missing at #{log_path}") unless File.exist?(log_path)
      bad = File.foreach(log_path).select do |line|
        line =~ /\[(error|warn)\]/ && line !~ /Oj is not installed/
      end
      fail!(:L2, "fluentd.log contains #{bad.size} unexpected error/warn lines:\n#{bad.first(5).join}") unless bad.empty?
    end

    def verify_l3_sqlite
      with_db do |db|
        t = db.get_first_value("SELECT COUNT(*) FROM transcripts WHERE ended_at > 0.0") - @baseline[:transcripts_with_time]
        fail!(:L3, "no new transcripts with non-zero ended_at (delta=#{t})") if t <= 0
        s = db.get_first_value("SELECT COUNT(*) FROM audio_segments WHERE duration_sec > 0.0")
        fail!(:L3, "no audio_segments with non-zero duration_sec (count=#{s})") if s <= 0
      end
    end

    def verify_l4_ack
      rotated = count_rotated - @baseline[:rotated_count]
      ack = count_ack - @baseline[:ack_count]
      fail!(:L4, "ack count #{ack} != rotated count #{rotated} (1:1 expected)") if ack != rotated
    end

    def verify_l5_processes
      remaining = Dir.glob(File.join(@run_dir, '*.pid')).reject { |p| File.basename(p) == '.keep' }
      fail!(:L5, "leftover pid files: #{remaining.map { |p| File.basename(p) }.join(', ')}") unless remaining.empty?
      stragglers = `pgrep -f 'swiftcap|fluentd -c config|puma -C web|caffeinate -dimsu'`.lines.map(&:strip).reject(&:empty?)
      fail!(:L5, "leftover processes: pids=#{stragglers.join(',')}") unless stragglers.empty?
    end

    def count_rotated
      path = File.join(@spool_dir, 'state.jsonl')
      return 0 unless File.exist?(path)
      File.foreach(path).count { |l| l.include?('"kind":"rotated"') }
    end

    def count_ack
      path = File.join(@spool_dir, 'ack.jsonl')
      return 0 unless File.exist?(path)
      File.foreach(path).count
    end

    def count_transcripts_with_time
      with_db { |db| db.get_first_value('SELECT COUNT(*) FROM transcripts WHERE ended_at > 0.0') }
    rescue SQLite3::SQLException
      0
    end

    def with_db
      db = SQLite3::Database.new(@db_path, readonly: true)
      yield db
    ensure
      db&.close
    end

    # Returns the RMS energy of a CAF file's PCM data, or 0 if decode fails.
    # Uses `afconvert` (macOS standard) to dump to s16-LE then computes RMS.
    def caf_rms(path)
      tmp = "/tmp/caf-rms-#{Process.pid}.raw"
      ok = system("afconvert -f WAVE -d LEI16 -c 1 -r 16000 #{path.shellescape} #{tmp}.wav > /dev/null 2>&1")
      return 0 unless ok
      data = File.binread("#{tmp}.wav")
      pcm = data[44..]  # strip RIFF header
      samples = pcm.unpack('s<*')
      return 0 if samples.empty?
      sumsq = samples.reduce(0) { |acc, s| acc + s * s }
      Math.sqrt(sumsq.to_f / samples.size).to_i
    ensure
      File.delete("#{tmp}.wav") rescue nil
    end

    def sh(cmd)
      system(cmd)
    end

    def fail!(layer, msg)
      @failures << "[#{layer}] #{msg}"
      $stderr.puts "FAIL #{layer}: #{msg}"
    end
  end
end
```

(`require 'shellwords'` is implicit via `String#shellescape` after `require 'shellwords'` — add `require 'shellwords'` near the top.)

- [ ] **Step 13.4: Add `shellwords` require** (top of `synthetic_e5.rb`)

```ruby
require 'shellwords'
```

(Add after `require 'json'`.)

- [ ] **Step 13.5: Add `test:e5_synthetic` rake task**

Append to `Rakefile` (outside any namespace):

```ruby
namespace :test do
  desc 'Run synthetic 30s mini-E5 acceptance: start:all → afplay 30s → stop:all → assert 5 layers'
  task :e5_synthetic do
    require_relative 'lib/audio_transcription/synthetic_e5'
    failures = AudioTranscription::SyntheticE5.new.run
    if failures.empty?
      puts 'mini-E5 PASS — all 5 layers verified'
    else
      abort "mini-E5 FAIL:\n#{failures.join("\n")}"
    end
  end
end
```

- [ ] **Step 13.6: Run mini-E5** (manual, requires mic permission, audible speakers)

```bash
bundle exec rake test:e5_synthetic
```

Expected: `mini-E5 PASS — all 5 layers verified`.

If it fails:
- L1 mic RMS too low → check System Settings → Privacy & Security → Microphone for swiftcap permission
- L1 screen RMS too low → speakers muted? check `afplay` running, system audio routing
- L2 errors in fluentd.log → may be unrelated (e.g., Apple Foundation Model guardrail). Adjust filter pattern in `verify_l2_fluentd` if needed.
- L3 zero new transcripts → swiftcap → fluentd pipeline broken; check `tmp/log/swiftcap.log` and `fluentd.log`.
- L4 ack mismatch → F3 observation: dupe persisted past F4 fix. Adds idempotency in a follow-up plan.
- L5 leftover process → F4 stop helper bug; investigate which service didn't drain in wait_sec window.

- [ ] **Step 13.7: Commit**

```bash
git add test/fixtures/synthetic_e5_audio.wav lib/audio_transcription/synthetic_e5.rb Rakefile
git commit -m "test: add synthetic mini-E5 acceptance task (5-layer verification)"
```

---

## F3: Ack closure observation (no code change unless observed)

### Task 14: Run mini-E5 once and record F3 outcome

- [ ] **Step 14.1: After Task 13 passes, run mini-E5 a second time**

```bash
bundle exec rake test:e5_synthetic
```

- [ ] **Step 14.2: Inspect ack:rotated ratio explicitly**

```bash
echo "rotated: $(grep -c '"kind":"rotated"' spool/state.jsonl)"
echo "ack:     $(wc -l < spool/ack.jsonl)"
sort spool/ack.jsonl | grep -oE 'spool/[^"]+\.caf' | sort | uniq -c | sort -rn | head
```

Expected: ack count == rotated count, no path appearing more than once in the unique-count.

- [ ] **Step 14.3: Document outcome**

Append a 1-paragraph note to `docs/superpowers/specs/2026-05-06-core-fixes-from-e5.md` §6 stating the observed result. If pass: F3 is closed by F4. If fail: open a follow-up plan for plugin idempotency.

```bash
# After editing the spec to add the note:
git add docs/superpowers/specs/2026-05-06-core-fixes-from-e5.md
git commit -m "docs: record F3 observation outcome from mini-E5 run"
```

---

## Final verification

### Task 15: Run full test suite + open PR

- [ ] **Step 15.1: Run all tests**

```bash
bundle exec rake test 2>&1 | tail -5
cd swift/swiftcap && swift test 2>&1 | tail -5 && cd ../..
```

Expected: all pass.

- [ ] **Step 15.2: Run mini-E5 final pass**

```bash
bundle exec rake test:e5_synthetic
```

Expected: `mini-E5 PASS — all 5 layers verified`.

- [ ] **Step 15.3: Push branch and open PR**

```bash
git push -u origin feat/core-fixes-2026-05-06
gh pr create --title "feat: core fixes from 2026-05-06 E5 (mic input, contract, graceful stop)" --body "$(cat <<'EOF'
## Summary
- F1: swiftcap mic startup log + 5s first-buffer timeout (silent failure → loud failure)
- F2: full data contract — `started_at` / `ended_at` / `language` in final.jsonl + state.jsonl rotated
- F3: ack 1:1 verified by mini-E5 (no plugin changes needed if observed pass)
- F4: PID-file based graceful stop:all (puma DSL, fluentd `-d`, swiftcap/caffeinate bash wrapper); SIGTERM-only, no SIGKILL escalation
- mini-E5 acceptance test (`rake test:e5_synthetic`) — 30s 5-layer verification

## Test plan
- [x] `bundle exec rake test` — Ruby unit tests pass
- [x] `cd swift/swiftcap && swift test` — Swift unit tests pass
- [x] `bundle exec rake test:e5_synthetic` — mini-E5 acceptance pass
- [ ] Real 30-min E5 (manual, post-merge preflight)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review (per writing-plans skill)

### Spec coverage

- §1 scope (F1-F4 + mini-E5) → Tasks 8 (F1), 9-12 (F2), 14 (F3 obs), 1-7 (F4), 13 (mini-E5). ✓
- §3 unbreakable principles P1-P5 → P1 (F1 + mini-E5 RMS), P2 (Task 12 strict drop), P3 (TDD commits per task), P4 (Task 3 stop helper aborts, no SIGKILL), P5 (Task 4 puma DSL, Task 5 fluentd `-d`). ✓
- §7.4 wait timings (30/60/10/5) → Task 3 `WAIT_SEC` map. ✓
- §8 mini-E5 5-layer assertions → Task 13 `verify_l1`–`verify_l5`. ✓

### Placeholder scan

- No "TBD", "TODO" in plan body. ✓
- `silence_threshold` is concrete (`SILENCE_RMS_THRESHOLD = 200`). ✓
- `result.range` API in Task 11 has fallback note (compiler error → adjust to `result.audioTimeRange`/`result.timeRange`); this is non-ideal but documents the actual API check. ✓ (with caveat)

### Type consistency

- `RotatingRecorder.finalize` callback `(URL, TimeInterval, TimeInterval) -> Void` used in Task 9 (definition), Task 10 (caller). ✓
- `stop_via_pidfile(name, wait_sec, has_screen:)` signature consistent across Tasks 3, 4, 5, 6. ✓
- `WAIT_SEC` keys (`'swiftcap'`, `'fluentd'`, `'web'`, `'caffeinate'`) match task names in `stop:*`. ✓

### Outstanding caveats

- **Task 11 SpeechTranscriber.result API**: `result.range.start.seconds` is the most likely API (CMTimeRange-style), but if the actual API is different (e.g., `result.audioTimeRange.start.seconds`), the build fails with a clear error and the engineer adjusts. Documented in step 11.2.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-06-core-fixes-from-e5.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks, fast iteration. Best for keeping the main session lean.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review. Best for tight feedback loops on tricky steps.

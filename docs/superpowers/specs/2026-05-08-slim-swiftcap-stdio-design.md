# Slim swiftcap: stdio + unix socket I/O

Date: 2026-05-08
Branch: `feat/slim-swiftcap-stdio-2026-05-08`

## Goal

Eliminate the file-based interchange (`spool/quick.jsonl`, `final.jsonl`,
`sound.jsonl`, `state.jsonl`, `control.jsonl`, `ack.jsonl` and their
`.pos.*` files) between swiftcap and the rest of the system. Replace it
with a one-way stdio data stream and a single unix domain socket for
control / ack / retranscribe-emit. Keep swiftcap as the TCC anchor — its
embedded `Info.plist` continues to own the macOS Screen Recording /
Microphone / Speech Recognition consents — but reduce its responsibility
to "capture + transcription + audio I/O", letting the surrounding plumbing
move into a new fluentd input plugin.

`rb-apple-sdk-mac` was evaluated as a path to dissolve swiftcap into pure
Ruby. Rejected: the KB has no coverage for `SpeechAnalyzer`, `SCStream`,
`AVAudioEngine`, or `SNAudioStreamAnalyzer`, and the Swift-native
async-sequence / delegate patterns those frameworks rely on are outside
what the dynamic dispatcher currently bridges. Returning to the question
later (after rb-apple-sdk-mac extends its KB and async support) is fine;
this spec is the right step for now.

## Non-goals

- No changes to the SQLite schema or web UI rendering.
- No changes to filter plugins (`filter_audio_state`,
  `filter_natural_language_mac`, `filter_foundation_model_mac`).
- No backwards-compatibility shims. Old spool jsonl paths, ControlReader
  / AckReader code, and the swiftcap launchd plist are deleted outright.
  README is rewritten to describe the new shape only.

## Architecture

```
                 spool/*.caf  (rotated audio, retained for retranscribe)
                       ▲
                       │
┌──────────────────────┴────┐
│ swiftcap (Swift binary,   │
│ TCC anchor, dev.bash0c7…) │
│                            │
│  stdout ─ JSON lines ──────┼──→ in_swiftcap (fluentd input plugin)
│                            │       └─ router.emit("audio.<stream>", …)
│                            │              ├─ filter_audio_state
│                            │              ├─ filter_natural_language_mac
│                            │              ├─ filter_foundation_model_mac
│                            │              └─ out_sqlite_meeting_log ──→ DB + HTTP webhook
│                            │                                  │
│  spool/swiftcap.sock ◀─────┼──── ack {"kind":"ack","paths":…} ┘
│  (NWListener .unix)        │
│         ▲                  │
└─────────┼──────────────────┘
          │
          ├── boundary  / mute_toggle  ←── sinatra (web)
          └── emit (final / state) ←─── swiftcap retranscribe (one-shot client)
```

Three processes total at runtime: fluentd (which spawns swiftcap as a
child), web (sinatra+puma), caffeinate. swiftcap is no longer launched
independently via screen.

## Stdio protocol

### swiftcap → stdout (records)

One JSON object per line, terminated with `\n`, written via
`FileHandle.standardOutput.write` (single syscall per line — bypasses
stdio block buffering).

```jsonc
{"stream":"quick","ts":1746678234.123,"ch":"mic","kind":"volatile","text":"…","transcript_id":"…","session_started_at":1746678200.0}
{"stream":"final","ts":1746678234.456,"ch":"mic","kind":"final","text":"…","started_at":1.2,"ended_at":3.4,"language":"ja-JP","transcript_id":"…","session_started_at":1746678200.0}
{"stream":"sound","ts":1746678234.789,"ch":"mic","kind":"speech",…}
{"stream":"state","ts":1746678200.0,"kind":"session_started","session_started_at":1746678200.0}
{"stream":"state","ts":1746678234.0,"kind":"rotated","channel":"mic","path":"/…/mic_*.caf","bytes":…,"started_at":…,"ended_at":…,"session_started_at":…,"reason":"auto"}
{"stream":"state","ts":…,"kind":"swiftcap_ready"}
```

- Outer `stream` field: `"quick"` | `"final"` | `"sound"` | `"state"`.
  in_swiftcap removes it and emits the rest under `audio.<stream>`.
- Inner `kind`, all other fields: identical to today's per-file row
  schemas. Filters and the SQLite output plugin require no changes.
- `state.swiftcap_ready` is the readiness handshake: emitted by main once
  `coordinator.start(locale:)` returns. in_swiftcap blocks `start()`
  until this row is observed (or a timeout fires).

### stderr

Logs only. in_swiftcap drains stderr in a thread and forwards each line
to `log.warn` (so swiftcap can never SIGPIPE on a closed stderr).

## swiftcap.sock protocol

`NWListener.using(.unix(path: "<spool_dir>/swiftcap.sock"))` listens on a
unix domain stream socket. swiftcap unlinks any stale file before
binding. Permissions inherit from the spool directory (which is already
owner-private); no explicit chmod needed.

Multiple concurrent client connections allowed (web + out_sqlite +
retranscribe may all be writing concurrently). Each connection feeds
`\n`-terminated JSON lines; swiftcap reads them in arrival order and
dispatches to its actor. Partial trailing lines on connection close are
discarded.

```jsonc
// State-mutating commands
{"kind":"boundary"}
{"kind":"mute_toggle"}
{"kind":"ack","paths":["/abs/path/mic_xxx.caf", "/abs/path/screen_xxx.caf"]}

// Data passthrough (only retranscribe uses this today)
{"kind":"emit","stream":"final","record":{"ts":…,"kind":"final","ch":"mic","text":"…","language":"ja-JP","pass":2,"session_id":42}}
{"kind":"emit","stream":"state","record":{"ts":…,"kind":"retranscribe_done","session_id":42}}
```

For `kind:"emit"`, swiftcap re-emits the inner `record` to its own
stdout, with the outer `stream` field added. This keeps fluentd's
ingestion path single-source: every record observed by in_swiftcap came
from swiftcap's stdout, regardless of whether it originated in live
capture or in a one-shot retranscribe client.

## Component-level changes

### swiftcap (Swift)

| File | Action |
| --- | --- |
| `Sources/Swiftcap/SpoolWriter.swift` | Delete. |
| `Sources/Swiftcap/ControlReader.swift` | Delete. |
| `Sources/Swiftcap/AckReader.swift` | Delete. |
| `Sources/Swiftcap/StdoutEmitter.swift` | New. `RecordEmitter` protocol + `StdoutEmitter` concrete impl writing single-syscall JSON lines to `FileHandle.standardOutput`. |
| `Sources/Swiftcap/ControlSocket.swift` | New. `NWListener.using(.unix(…))` server. On each line dispatches to coordinator (`handleBoundary`, `handleMuteToggle`, `acknowledgeAndDelete`) or directly to the emitter (`emit`). |
| `Sources/Swiftcap/ControlSocketClient.swift` | New. Tiny client used only by `RetranscribeCommand` to write `{"kind":"emit",…}` lines to `swiftcap.sock`. |
| `Sources/Swiftcap/CaptureCoordinator.swift` | Replace four `SpoolWriter` instances with one `RecordEmitter`. Existing `try? stateWriter.append([...])` etc become `emitter.emit(stream:"state", record:[...])`. Behavior unchanged. |
| `Sources/Swiftcap/Swiftcap.swift` | Drop the ControlReader Task and the AckReader polling Task. Wire `ControlSocket(path: spool/swiftcap.sock).start(coordinator:emitter:)`. After `coordinator.start(locale:)` returns, emit `{"stream":"state","kind":"swiftcap_ready",…}`. |
| `Sources/Swiftcap/RetranscribeCommand.swift` | Replace `SpoolWriter(url: spool/final.jsonl)` and `SpoolWriter(url: spool/state.jsonl)` writes with `ControlSocketClient(path: spool/swiftcap.sock).emit(stream:"final"\|"state", record:…)`. On socket connect failure, write a loud error to stderr and exit non-zero so the spawning web worker logs it. |
| `Tests/SwiftcapTests/SpoolWriterTests.swift` | Delete (or rewrite as `StdoutEmitterTests` driving a `Pipe`). |
| `Tests/SwiftcapTests/ControlReaderTests.swift` | Delete. |
| `Tests/SwiftcapTests/AckReaderTests.swift` | Delete. |
| `Tests/SwiftcapTests/ControlSocketTests.swift` | New. tmp socket path → bind → connect → JSON line → assert handler invocation. |
| `Tests/SwiftcapTests/RetranscribeCommandTests.swift` | Switch assertions from spool file contents to a tmp listener that captures emitted records. |
| `Tests/SwiftcapTests/{Smoke,Boundary,ChannelFailure,Rotating,SessionTracker}*.swift` | Inject a `CapturingEmitter` instead of a tmp spool dir; assertions become record-list comparisons. |

### fluentd plugins (Ruby)

| File | Action |
| --- | --- |
| `lib/fluent/plugin/in_swiftcap.rb` | New. Config: `swiftcap_bin`, `spool_dir`, `locale`, `socket_path`. Spawns swiftcap with `Open3.popen3`. Reads stdout line-by-line, parses JSON, removes `stream`, emits `audio.<stream>` to the router. Drains stderr in a thread to `log.warn`. Blocks startup until `state.swiftcap_ready` line observed (configurable timeout, default 30s). On shutdown sends SIGTERM and waits for child exit, escalating to SIGKILL after 15s. Removes `socket_path` if leftover after exit. |
| `lib/fluent/plugin/out_sqlite_meeting_log.rb` | Replace ack.jsonl append with `UNIXSocket.open(swiftcap_socket_path) { _1.puts JSON.dump({kind:"ack", paths: …}) }`. Add `swiftcap_socket_path` config option. Remove `ack_path` config option. |
| `lib/fluent/plugin/filter_audio_state.rb` | No change. |
| `lib/fluent/plugin/filter_natural_language_mac.rb` | No change. |
| `lib/fluent/plugin/filter_foundation_model_mac.rb` | No change. |

### fluent.conf

Replace the four `<source @type tail>` blocks with one `<source @type swiftcap>` block. Update the `<match>` to use `swiftcap_socket_path` instead of `ack_path`.

```aconf
<source>
  @type swiftcap
  swiftcap_bin "#{ENV['SWIFTCAP_BIN']}"
  spool_dir "#{ENV['SPOOL_DIR']}"
  locale "#{ENV['SWIFTCAP_LOCALE'] || 'ja-JP'}"
  socket_path "#{ENV['SPOOL_DIR']}/swiftcap.sock"
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
  swiftcap_socket_path "#{ENV['SPOOL_DIR']}/swiftcap.sock"
  webhook_url "#{ENV['WEBHOOK_URL'] || 'http://localhost:9292/_internal/notify'}"
</match>
```

### web

| File | Action |
| --- | --- |
| `web/app.rb` `POST /api/session/boundary` | Replace `control.jsonl` append with `UNIXSocket.open(socket_path) { _1.puts JSON.dump({kind:"boundary"}) }`. |
| `web/app.rb` `POST /api/session/mute` | Same pattern, `{"kind":"mute_toggle"}`. |
| `web/app.rb` retranscribe worker | No change. The worker still spawns `swiftcap retranscribe …`; the retranscribe binary connects to the socket itself. |
| `web/assets/app.rb` (PicoRuby:wasm client) | No change. `state.retranscribe_done` events still arrive through the fluentd webhook → WebSocket. |

### Rakefile / plists / scripts

| Item | Action |
| --- | --- |
| `Rakefile` task `start:swiftcap` | Delete. |
| `Rakefile` task `stop:swiftcap` | Delete. |
| `Rakefile` `logs[swiftcap]` mapping | Delete. |
| `Rakefile` task `start:fluentd` | Keep the `swift build -c release` precondition (so in_swiftcap finds an up-to-date binary at spawn). |
| `Rakefile` task `start:all` | Three components (fluentd, web, caffeinate). |
| `plists/dev.bash0c7.audio-transcription.swiftcap.plist.erb` | Delete. |
| `scripts/setup.rb` | Drop the swiftcap plist generation step. |

### README

Full rewrite of architecture diagram, "Running" section, and the
pipeline description in the overview. Add a Design Choices entry
explaining the stdio + unix socket model. Add a one-line note that
`spool/*.jsonl` and `spool/.pos.*` from previous installs should be
removed (`rm -f spool/*.jsonl spool/.pos.*`) on first start with the
new layout.

### Migration

No automated migration. Operators (just bash0C7) `rm -f spool/*.jsonl
spool/.pos.*` once before the first `rake start:all` on the new
codebase. The new code never reads those paths so leftover files are
inert but uselessly occupy disk; the README documents the cleanup.

## Risks and mitigations

| # | Risk | Mitigation |
| --- | --- | --- |
| 1 | Stale `swiftcap.sock` from a previous unclean exit | swiftcap unlinks the socket path before `NWListener.start()` |
| 2 | swiftcap dies before emitting `swiftcap_ready` | in_swiftcap times out (30s default) → fluentd start fails loudly; stderr drain captures whatever swiftcap printed |
| 3 | TCC consent attribution to the wrong process | swiftcap binary calls the APIs, so the prompt is keyed to `dev.bash0c7.swiftcap` (unchanged from today). Documented in README Setup. |
| 4 | Pipe backpressure if fluentd hangs | Acceptable: fluentd hang already kills the pipeline. swiftcap actor queue absorbs short bursts. |
| 5 | Retranscribe socket connect failure | Loud stderr error from retranscribe + non-zero exit; web worker logs. The CAF blobs are still in DB / disk so a retry works. |
| 6 | Multiple concurrent socket writers | NWListener accepts multiple connections; per-connection lines feed into the same actor in arrival order. |
| 7 | Out-of-band stop:all leaves a stale screen session named `audio-swiftcap` | `start:swiftcap` and `stop:swiftcap` are deleted, so no new screen sessions are created. Operators clean up any leftover from older code paths once. |

## Shutdown sequence

1. `rake stop:fluentd` → fluentd receives SIGTERM.
2. `in_swiftcap.shutdown` sends SIGTERM to the swiftcap child.
3. swiftcap's existing SIGTERM handler runs `coordinator.shutdownRotate(reason:"shutdown")` → engines stopped → recorders finalized → exits 0. (No dedicated "shutdown_done" event — exit code is the signal.)
4. in_swiftcap waits up to 15s for child exit; escalates to SIGKILL otherwise.
5. in_swiftcap unlinks `swiftcap.sock` if still present.

## Test approach (TDD slicing)

Each slice follows t-wada style RED / GREEN / REFACTOR commit boundaries
per `~/dev/src/CLAUDE.md`. Trivial config typos and pure renames may be
single-commit. The slices below are dependency-ordered; the detailed
implementation plan in `docs/superpowers/plans/` will refine each into
specific test cases.

1. `StdoutEmitter` + `RecordEmitter` protocol — Pipe-driven test.
2. `CaptureCoordinator` accepts an injected `RecordEmitter` — convert tmp-dir-based tests to `CapturingEmitter`.
3. `ControlSocket` listener — tmp socket path, client write, handler invocation assertion.
4. `Swiftcap.swift` main rewiring + `swiftcap_ready` emission.
5. `RetranscribeCommand` → `ControlSocketClient` — tmp listener captures emitted records.
6. `in_swiftcap` fluentd plugin — fake binary spawn + stdout emit + driver assert.
7. `out_sqlite_meeting_log` socket ack — fake socket listener captures ack paths.
8. `web/app.rb` boundary / mute → socket — fake listener verifies payload.
9. `fluent.conf` rewrite + `Rakefile` cleanup + `plists` deletion + README rewrite — each a separate commit.

## Acceptance gate

- `bundle exec rake test` GREEN.
- `swift test` (under `swift/swiftcap/`) GREEN.
- `bundle exec rake test:e5_synthetic` PASS (5-layer synthetic E2E).
- Manual: `bundle exec rake start:all`, then `say -v Kyoko こんにちは`, observe Quick / Perfect / Graph panes at `http://localhost:9292/` populating within their usual latencies.
- Manual: `POST /api/session/boundary` and `POST /api/session/mute` from the web UI both reach swiftcap and produce the expected state events.
- Manual: trigger a retranscribe of a recent session in the web UI; observe the pass=2 final records reach the DB and the UI re-renders the Perfect pane accordingly.

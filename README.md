# fluentd-audio-transcription-system

Always-on meeting audio capture, on-device transcription, and live visualization for macOS 26+.

## Overview

The system continuously captures both microphone and system audio, transcribes them on-device via Apple SpeechAnalyzer, derives entity / edge structure from the transcripts via Apple NaturalLanguage and Apple Foundation Models (on-device LLM inference), persists everything to SQLite WAL, and streams the live state to a three-pane web UI rendered with PicoRuby:wasm + Three.js.

No cloud APIs, no translation, no third-party LLM service. Everything that runs is either an Apple framework on the user's Mac, a Ruby gem in this repository's sibling layout, or fluentd.

## Architecture

```
fluentd  (with in_swiftcap input plugin)
  ├─ spawns swiftcap (Swift binary, owns macOS TCC consent — Screen / Mic / Speech)
  │    swiftcap stdout ──→ JSON lines: {"stream":"quick"|"final"|"sound"|"state", …}
  │                              │
  │    in_swiftcap reads stdout, emits records under audio.<stream> tags
  │
  └─ filter chain (audio_state / natural_language_mac / foundation_model_mac)
       └─ out_sqlite_meeting_log ──→ SQLite WAL + HTTP webhook to web
                                  └─ ack to spool/swiftcap.sock (CAF deleted on ack)

spool/
  ├─ swiftcap.sock      (unix domain socket — boundary / mute_toggle / ack / retranscribe-emit)
  └─ *.caf              (rotated audio segments, deleted by swiftcap on ack)

web (sinatra + faye-websocket + puma)
  ├─ POST /api/session/boundary → swiftcap.sock {"kind":"boundary"}
  ├─ POST /api/session/mute     → swiftcap.sock {"kind":"mute_toggle"}
  └─ retranscribe worker spawns `swiftcap retranscribe …` (one-shot client of swiftcap.sock)

Chrome (PicoRuby:wasm + Three.js + 3d-force-graph)
  ┌──────────┬──────────┬─────────────┐
  │ Quick    │ Perfect  │ Network     │
  │ pane     │ pane     │ Graph pane  │
  └──────────┴──────────┴─────────────┘
```

Design and implementation references live under `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Requirements

- macOS 26 (Tahoe) on Apple Silicon — required at runtime
- macOS 15 (Sequoia) with Xcode Command Line Tools 26.x SDK — sufficient for build verification only
- Apple Intelligence enabled, with the on-device foundation model fully downloaded (Settings → Apple Intelligence & Siri). Required by `rb-foundation-model-mac` for on-device LLM inference.
- Swift 6.3+, installed via [swiftly](https://www.swift.org/install/macos/)
- Ruby 4.0.3 (managed by rbenv via `.ruby-version`)
- Sibling repositories cloned alongside this one in the standard ghq layout: `../rb-natural-language-mac`, `../rb-foundation-model-mac`, `../swift_gem`

The first runtime startup triggers macOS permission prompts for Screen Recording, Microphone, and Speech Recognition under the swiftcap binary identity (`dev.bash0c7.swiftcap`) — all three must be approved.

## Setup

```bash
bundle config set --local path vendor/bundle
bundle install
bundle exec rake db:migrate
bundle exec ruby scripts/setup.rb       # generates LaunchAgents (fluentd, web) and builds swiftcap
```

`scripts/setup.rb` builds the `swiftcap` Swift binary (`swift build -c release` under `swift/swiftcap/`) and renders LaunchAgent plists for fluentd and web. swiftcap itself is not a separate LaunchAgent — fluentd's `in_swiftcap` input plugin spawns it as a child process.

## Running

All processes are launched as detached `screen` sessions through Rake. The standard development workflow:

- `bundle exec rake start:all` — starts caffeinate, fluentd (which spawns swiftcap), and web concurrently
- `bundle exec rake status` — lists which `audio-*` screen sessions are alive
- `bundle exec rake logs[fluentd]` — tails the named component's log; `[web]` and `[caffeinate]` are also valid
- `bundle exec rake stop:all` — gracefully stops every component (single SIGTERM, generous wait window per component, no SIGKILL escalation)

Per-component variants exist as `start:<name>` / `stop:<name>` for `fluentd`, `web`, and `caffeinate`. The spool lives at `./spool/`, the database at `./db/meeting_log.sqlite`, and process logs at `./tmp/log/` — all of those paths are gitignored.

After `start:all`, the live web UI is available at `http://localhost:9292/`, presenting Quick, Perfect, and Graph panes side by side.

> Important: launching the web component outside of `rake start:web` requires exporting `SPOOL_DIR`, `SWIFTCAP_BIN`, and `DB_PATH` first.

## Verifying

A live system is considered functional when the three panes at `http://localhost:9292/` render text and graph content during either a real meeting or a simple synthesized utterance such as `say -v Kyoko こんにちは`. Quick should populate within a second or two, Perfect within a few seconds, and the Graph pane should accumulate nodes (entities) and edges as content accrues.

## Design Choices

- **No translation.** Japanese stays Japanese, English stays English. The transcription pipeline preserves the original locale.
- **Single perfect-path strategy.** Apple SpeechAnalyzer drives both the volatile (Quick) and final (Perfect) streams; Apple Foundation Models drives entity-relation extraction. Whisper and other third-party transcription engines are not used.
- **Channel-based speaker labeling.** The microphone channel is treated as `self`, the screen channel as `remote`. No diarization model.
- **SQLite + WAL with `_sqlite_mcp_meta`.** The schema is intentionally compatible with `chiebukuro-mcp`, so the database can be queried as long-term memory by other tools in the same family.
- **On-device only.** All ML inference (transcription, language detection, tokenization, NER, FM generation) runs against Apple frameworks on the local machine. Nothing leaves the device.
- **stdio + unix socket I/O between swiftcap and fluentd.** swiftcap streams records to fluentd via a one-way stdout JSON-line stream; control / ack / retranscribe-emit go through `spool/swiftcap.sock`. There are no `*.jsonl` interchange files. swiftcap is the single TCC anchor binary; everything that doesn't need TCC consent lives in Ruby.

## Development

Ruby unit tests run with `bundle exec rake test`. Swift unit tests run from `swift/swiftcap/` with `swift test`. The end-to-end synthetic acceptance harness is `bundle exec rake test:e5_synthetic`, which boots the full pipeline against a fixture audio file and verifies five layers (swiftcap CAF output, fluentd ingest, SQLite persistence, ack-driven CAF deletion, process lifecycle).

The repo follows a `screen -dmS` long-running pattern for Rake-launched components; logs land under `tmp/longrun/<name>.log` with a `DONE:` sentinel on completion.

## Status

The two verification paths described under "Verifying" are confirmed to work end-to-end. Ongoing investigation candidates and open questions are tracked in `docs/superpowers/specs/2026-05-07-next-version-backlog.md`.

## License

Apache 2.0

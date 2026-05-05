# fluentd-audio-transcription-system

macOS 26+ 上で動く、会議音声の常時キャプチャ・文字起こし・可視化システム。

## アーキテクチャ概要

```
swiftcap (Swift CLI)
  └─ ScreenCaptureKit + AVAudioEngine
     ├─ CAF/AAC rotating recorder
     ├─ SpeechAnalyzer/SpeechTranscriber (volatile + final)
     └─ SNAudioStreamAnalyzer
  ↓ spool/{quick,final,sound,state}.jsonl + *.caf
fluentd
  └─ in_tail × 4 → filter_audio_state / natural_language_mac /
     foundation_model_mac → out_sqlite_meeting_log
  ↓ SQLite WAL + ack.jsonl + HTTP webhook
web (sinatra + faye-websocket + puma)
  ↓ WebSocket
Chrome (PicoRuby:wasm + Three.js + 3d-force-graph)
  ┌──────────┬──────────┬─────────────┐
  │ Quick    │ Perfect  │ Network     │
  │ pane     │ pane     │ Graph pane  │
  └──────────┴──────────┴─────────────┘
```

詳細は `docs/superpowers/specs/2026-05-05-fluentd-audio-transcription-v2-design.md` 参照。実装計画は `docs/superpowers/plans/2026-05-05-fluentd-audio-transcription-v2.md` 参照。

## 前提

- macOS 26 (Tahoe) / Apple Silicon ── ランタイム実行に必須
- macOS 15 (Sequoia) + Xcode CLT 26.x SDK ── ビルド検証だけなら可
- Swift 6.3+ ([swiftly](https://www.swift.org/install/macos/) 経由推奨)
- Ruby 4.0.1 (rbenv)
- ローカル ghq layout で `../rb-natural-language-mac` `../rb-foundation-model-mac` `../swift_gem` が clone 済み
- Ollama（`gemma4:e2b` 等）が `localhost:11434` で起動（`rb-foundation-model-mac` 仮実装が利用）

## セットアップ

```bash
git clone https://github.com/bash0C7/fluentd-audio-transcription-system
cd fluentd-audio-transcription-system
bundle config set --local path vendor/bundle
bundle install
bundle exec rake db:migrate
bundle exec ruby scripts/setup.rb
```

初回起動時に macOS から「画面収録」「マイク」「音声認識」の許諾ダイアログが出る。すべて承認。

## 確認

```
open http://localhost:9292/
```

Quick / Perfect / Graph の 3 カラムが現れる。実会議や `say -v Kyoko こんにちは` で動作確認。

## マニュアル起動（LaunchAgent 不使用）

開発時や常駐させたくないときは rake で `screen -dmS` セッションとして起動：

```bash
bundle exec rake start:all      # swiftcap + fluentd + web
bundle exec rake status         # 動いてるセッションを確認
bundle exec rake "logs[fluentd]"  # ログを tail （[swiftcap] / [web] も可）
bundle exec rake stop:all       # 全停止
```

個別の `start:swiftcap` / `start:fluentd` / `start:web`、停止は対応する `stop:<name>`。spool は `./spool/`、DB は `./db/meeting_log.sqlite`、ログは `./tmp/log/` に出る（すべて gitignored）。

## 設計上の選択

- 翻訳しない（日本語/英語そのまま）
- 完璧経路は Apple SpeechAnalyzer + Foundation Models のみ（Strategy P, Whisper 不採用）
- 話者識別はチャンネルベース（mic = self, screen = remote）
- DB は SQLite WAL、`_sqlite_mcp_meta` で chiebukuro-mcp 互換

## 開発

```bash
bundle exec rake test         # Ruby 側ユニットテスト
cd swift/swiftcap && swift test  # Swift 側ユニットテスト
```

## ライセンス

Apache 2.0

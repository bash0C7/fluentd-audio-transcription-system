# fluentd-audio-transcription-system v2 設計書

- 作成日: 2026-05-05
- 対象: macOS 26 (Tahoe) / Apple Silicon
- 旧仕様: `specification/specification.md`（PyCall + MLX Whisper 構成）からの破壊的書き換え

## 1. 目的とユースケース

ローカル macOS 上で常時起動する音声キャプチャ・文字起こし・可視化システム。三系統の利用シーンを順次満たす：

1. **MVP**: オンライン会議（Zoom / Meet / Teams 等）。画面音声と自分のマイクを 2 系統並行録音し、リアルタイム文字起こしと話者識別（チャンネルベース）、議事録素材化を行う。
2. **将来**: オフライン対面会議（マイク 1 本 + 話者分離）、個人ライフログ（24h 連続）、AR / AI グラス相互運用。
3. 並行して **chiebukuro-mcp の新ドメイン**として将来クエリ可能になるよう、SQLite を read-only で他プロセスから参照できる構成にしておく。

翻訳は行わない。日本語または英語で入力された音声をそのまま日本語または英語のテキストとして出力する。

## 2. アーキテクチャ全景

```
┌──────────────────────────── macOS（常時起動・LaunchAgents）──────────────────────────┐
│                                                                                     │
│  swiftcap (Swift CLI / 新規)                                                        │
│  ├── ScreenCaptureKit  → screen ch                                                  │
│  ├── AVAudioEngine     → mic ch                                                     │
│  │   ↓ per-channel:                                                                 │
│  │     ① AVAssetWriter による CAF/AAC 16kHz mono rotating recorder                  │
│  │     ② SpeechTranscriber (volatileResults + final) ※ macOS 26 SpeechAnalyzer 経由 │
│  │     ③ SNAudioStreamAnalyzer + MLSoundIdentifierVersion1                          │
│  │   ↓ ファイル出力 spool/                                                          │
│  │     mic-YYYYMMDD-HHMMSS.caf                                                      │
│  │     screen-YYYYMMDD-HHMMSS.caf      (5min 自動 rotate, SIGHUP でも即 rotate)     │
│  │     quick.jsonl   (volatileResults)                                              │
│  │     final.jsonl   (finalized + audioTimeRange)                                   │
│  │     sound.jsonl   (SNStreamAnalyzer ラベル)                                      │
│  │     state.jsonl   (swiftcap → rotated/heartbeat/deleted)                         │
│  │     ack.jsonl     (fluentd → consumed)                                           │
│  │                                                                                  │
│  ↓ ファイル経由で疎結合                                                             │
│                                                                                     │
│  fluentd (writer 専門・LaunchAgent)                                                 │
│  ├── in_tail × 4  →  parse                                                          │
│  ├── filter_audio_state            (rotated CAF を BLOB 読込)                       │
│  ├── filter_natural_language_mac   (MVP G2: NLTagger 名詞句抽出)                    │
│  ├── filter_foundation_model_mac   (polished_text 補完, 当面 Ollama)                │
│  └── out_sqlite_meeting_log        (WAL writer)                                     │
│                                                                                     │
│  meeting_log.sqlite                                                                 │
│  └─ _sqlite_mcp_meta あり → 将来 chiebukuro-mcp ドメイン化対応                       │
│                                                                                     │
│  web-frontend (sinatra + faye-websocket / 別 LaunchAgent, reader)                   │
│  ├── HTTP   /api/recent                                                             │
│  ├── HTTP   /api/sessions/:id                                                       │
│  ├── HTTP   /api/audio/:segment_id                                                  │
│  └── WS     /stream                                                                 │
└──────────────────────────────────────────────────────────────────────────────────────┘
   ↓
Chrome (手動起動)
  PicoRuby:wasm + Three.js + 3d-force-graph
  ┌──────────┬──────────┬─────────────┐
  │ Quick    │ Perfect  │ Network     │
  │ pane     │ pane     │ Graph pane  │
  └──────────┴──────────┴─────────────┘
```

疎結合点はすべて **ファイル**（spool/）と **SQLite**（reader open）で、各プロセスは独立に再起動できる。

## 3. キャプチャ層: swiftcap

新規 Swift CLI バイナリ。本リポジトリ `swift/swiftcap/` に独立 Swift Package として配置。`swift_gem` には依存しない（Ruby から呼ばないため）。

### 3.1 担当範囲

- ScreenCaptureKit による画面音声キャプチャ（他アプリ音声）
- AVAudioEngine によるマイクキャプチャ
- 各 channel での 3 種の async 並列タスク
  - `AVAssetWriter` ベース rotating recorder（CAF コンテナ + AAC 64 kbps + 16 kHz + mono）
  - `SpeechAnalyzer` + `SpeechTranscriber`（`reportingOptions: [.volatileResults]`, `attributeOptions: [.audioTimeRange]`, `locale: "ja-JP"` をデフォルト、設定で上書き可）
  - `SNAudioStreamAnalyzer` + `SNClassifySoundRequest(.version1)`
- ローテ契機: 5 分経過 OR `SIGHUP` 受信
- ローテ後の処理: 旧ファイルを `state.jsonl` に `kind:"rotated"` 行で append → fluentd の `in_tail` がこれを拾って `filter_audio_state` が CAF を BLOB 化して DB に書く → fluentd 側 `out_sqlite_meeting_log` が書込完了後に **`ack.jsonl` に `{kind:"consumed", path}` 行を append** → swiftcap が `ack.jsonl` を `in_tail` 的に追従しており、`consumed` 通知を見たら該当 CAF を `unlink(2)` し、`state.jsonl` に `{kind:"deleted", path}` を残す
- ファイル所有: `state.jsonl` は swiftcap のみが書く / `ack.jsonl` は fluentd のみが書く（writer の所有権を 1 プロセスに固定し、append-only ロックを不要化）

### 3.2 出力ファイル契約

すべて UTF-8 / JSON Lines / append-only（読み手の `in_tail` に整合）。各ファイルの writer は 1 プロセスに固定する。

| ファイル | 行スキーマ | Writer |
|---|---|---|
| `quick.jsonl` | `{ts, ch, kind:"volatile", text, transcript_id}` | swiftcap |
| `final.jsonl` | `{ts, ch, kind:"final", text, started_at, ended_at, language, transcript_id}` | swiftcap |
| `sound.jsonl` | `{ts, ch, started_at, ended_at, label, confidence}` | swiftcap |
| `state.jsonl` | `{ts, kind:"rotated"|"heartbeat"|"deleted", channel?, path?, started_at?, ended_at?, bytes?}` | swiftcap |
| `ack.jsonl`  | `{ts, kind:"consumed", path}` | fluentd |

`transcript_id` は swiftcap 側で UUIDv7（時刻ソート可能）採番。`ch` は `"mic"` または `"screen"`。`ts` は浮動小数点 unix epoch 秒。

### 3.3 TCC / 権限

Mach-O に Info.plist 相当を埋め込み、初回起動でユーザに許諾ダイアログを出す。

- `NSScreenCaptureUsageDescription`（ScreenCaptureKit）
- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`（SpeechAnalyzer も同じ Speech 系の TCC を要求）

署名は `Apple Development` 識別がある場合は優先、なければ ad-hoc 署名にフォールバック（`rb-speech-mac` の `extconf.rb` パターンを踏襲）。

### 3.4 シグナル

- `SIGHUP`: 即時 rotate（全 channel）
- `SIGTERM`: 進行中ファイルを finalize して終了
- `SIGINT`: 同上

## 4. 処理層: fluentd

本リポジトリ内蔵の Ruby plugin で完結（独立 gem 化はしない、肥大化したら切り出し）。

### 4.1 plugin 一覧

| plugin | 種別 | 役割 | 入力 tag | 出力 tag |
|---|---|---|---|---|
| `in_tail` × 4 | 既存標準 | spool/ の 4 ファイルを tail | — | `audio.quick` / `audio.final` / `audio.sound` / `audio.state` |
| `filter_audio_state`（新規） | filter | `audio.state` の rotated 行から CAF を BLOB 読込 | `audio.state` | `audio.segment` |
| `filter_natural_language_mac`（新規） | filter | `audio.final` に `entities[]` を生やす | `audio.final` | `audio.final` |
| `filter_foundation_model_mac`（新規） | filter | `audio.final` に `polished_text` を生やす | `audio.final` | `audio.final` |
| `out_sqlite_meeting_log`（新規） | output | tag 別に対応テーブルへ INSERT、書込後に web プロセスへ HTTP POST 通知（`webhook_url` config）、CAF 取り込み完了時は `ack.jsonl` に `consumed` 行を append、session 区切り判定（4.4） | `audio.{segment,final,sound,quick}` | — |

### 4.2 既存 plugin の処遇

| repo | 操作 |
|---|---|
| `fluent-plugin-audio-recorder` | GitHub archive |
| `fluent-plugin-audio-transcoder` | GitHub archive |
| `fluent-plugin-audio-transcriber` | GitHub archive |
| `rb-record-transcribe-mac` | GitHub archive（本 repo に集約） |

archive は読み取り専用化のみ（HEAD 削除はしない、旧 clone を壊さないため）。各 README に本 repo への移行誘導を 1 行追記。

### 4.3 グラフ抽出パイプライン（MVP G2）

`filter_natural_language_mac` 内で：

1. `final.text` を `NaturalLanguageMac.tag` で形態素解析
2. `Noun` 系のタグを名詞句として抽出
3. 自前 stopwords YAML（リポ同梱、初期セットは小さく開始、肥大化したら DB へ）でフィルタ
4. 同一 final 内（同一 utterance 内）で出現した名詞句ペアの共起エッジを `entity_edges` に upsert（weight += 1.0、`last_observed_at = now`）

時間減衰は **DB に書く時には適用しない**。読み手（web フロント）が描画時に `weight * exp(-Δt/τ)` を計算する（τ=30 分初期値、調整可）。

将来 G3（Foundation Model でのトピック層）は別 filter を後段に挿入することで拡張する（MVP では実装しない）。

### 4.4 session 区切りの規則

`out_sqlite_meeting_log` は `audio.final` を書き込む際、直前の同 channel の `transcripts.ended_at` から **10 分以上空いていれば**新規 `sessions` 行を作成して `session_id` をその新 id に振る。それ以外は最新の `sessions.id` を再利用する。閾値はリポ内 `config/fluent.conf` の plugin パラメタで調整可（初期値 600 秒）。

`sessions.title` / `sessions.summary` は MVP では空のまま。将来 G3 と同等の Foundation Model filter で session 終了後（次 session 作成時）に遡って埋める。

## 5. 永続化層: SQLite

### 5.1 ファイルレイアウト

`~/Library/Application Support/audio-transcription/db/meeting_log.sqlite`

`PRAGMA journal_mode=WAL`、`PRAGMA synchronous=NORMAL`、`PRAGMA mmap_size=268435456`（256 MB）、`PRAGMA foreign_keys=ON`。

### 5.2 スキーマ

```sql
CREATE TABLE _sqlite_mcp_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO _sqlite_mcp_meta(key, value) VALUES
  ('db:meeting_log',
   '会議・会話の文字起こしと音声、抽出エンティティ、共起グラフを保持する。SpeechAnalyzer/Foundation Models 由来の構造化済みデータ。'),
  ('table:audio_segments',
   '録音ファイル本体。CAF/AAC, 16 kHz mono。HUP または 5 分自動の rotate 単位。'),
  ('table:transcripts',
   '会話の確定セグメント。channel で話者識別、polished_text が補完済み完璧版。'),
  ('table:sound_labels',
   'SoundAnalysis のラベリング結果。'),
  ('table:entities',
   '会話から抽出された固有名詞・専門用語・トピック。'),
  ('table:entity_edges',
   'エンティティ間の共起グラフ。weight は時間減衰可。'),
  ('table:sessions',
   '会議単位（無音 N 分以上で区切り）。FM 生成の title/summary 保持。');

CREATE TABLE audio_segments (
  id INTEGER PRIMARY KEY,
  channel TEXT NOT NULL,           -- 'mic' | 'screen'
  started_at REAL NOT NULL,
  ended_at   REAL NOT NULL,
  duration_sec REAL,
  codec TEXT NOT NULL,             -- 'aac'
  sample_rate INTEGER,             -- 16000
  bytes INTEGER NOT NULL,
  blob BLOB NOT NULL
);
CREATE INDEX idx_audio_segments_started ON audio_segments(started_at);

CREATE TABLE sessions (
  id INTEGER PRIMARY KEY,
  started_at REAL NOT NULL,
  ended_at REAL,
  title TEXT,
  summary TEXT
);

CREATE TABLE transcripts (
  id INTEGER PRIMARY KEY,
  audio_segment_id INTEGER REFERENCES audio_segments(id),
  session_id INTEGER REFERENCES sessions(id),
  channel TEXT NOT NULL,
  speaker TEXT,                    -- 'self' | 'remote' | NULL
  started_at REAL NOT NULL,
  ended_at   REAL NOT NULL,
  language TEXT,
  raw_text TEXT NOT NULL,
  polished_text TEXT,
  source TEXT NOT NULL DEFAULT 'speech_transcriber',
  swiftcap_transcript_id TEXT      -- swiftcap 採番の UUID
);
CREATE INDEX idx_transcripts_started ON transcripts(started_at);
CREATE INDEX idx_transcripts_session ON transcripts(session_id);

CREATE VIRTUAL TABLE transcripts_fts USING fts5(
  raw_text, polished_text,
  content='transcripts', content_rowid='id', tokenize='unicode61'
);

CREATE TABLE sound_labels (
  id INTEGER PRIMARY KEY,
  audio_segment_id INTEGER REFERENCES audio_segments(id),
  channel TEXT NOT NULL,
  started_at REAL NOT NULL,
  ended_at   REAL NOT NULL,
  label TEXT NOT NULL,
  confidence REAL NOT NULL
);

CREATE TABLE entities (
  id INTEGER PRIMARY KEY,
  transcript_id INTEGER REFERENCES transcripts(id),
  text TEXT NOT NULL,
  kind TEXT NOT NULL,              -- 'term' | 'person' | 'org' | 'topic'
  start_offset INTEGER,
  end_offset INTEGER,
  observed_at REAL NOT NULL
);
CREATE INDEX idx_entities_text ON entities(text);
CREATE INDEX idx_entities_observed ON entities(observed_at);

CREATE TABLE entity_edges (
  id INTEGER PRIMARY KEY,
  src TEXT NOT NULL,
  dst TEXT NOT NULL,
  weight REAL NOT NULL DEFAULT 1.0,
  last_observed_at REAL NOT NULL,
  UNIQUE(src, dst)
);
```

### 5.3 マイグレーション運用

`migrations/<timestamp>_<title>.sql` に DDL 単純運用。Ruby ヘルパで `applied_migrations` テーブルを使った冪等適用。

### 5.4 サイズ試算

オンライン会議想定 1 日 3 時間 × 2 チャンネル × CAF/AAC 64 kbps / 16 kHz / mono：

- 1 日: 約 168 MB
- 1 ヶ月（営業日 20 日）: 約 3.4 GB
- 1 年: 約 40 GB
- 512 GB ストレージ: 約 12 年

文字起こしテキストおよびエンティティは 1 日数 MB 規模で誤差。

ライフログ用途（24h 連続）に展開する場合は audio_segments を旧データから順次 Parquet 等の冷凍庫に移送する tier ダウン機構を将来追加する（MVP 外）。

## 6. 表示層: web

`web/` ディレクトリ。

### 6.1 サーバ（Ruby）

`sinatra` + `faye-websocket`。`puma` で起動。SQLite は readonly で open。

エンドポイント:

- `GET /` index.html 配信
- `GET /assets/*` 静的ファイル（PicoRuby:wasm, three.js, 3d-force-graph）
- `GET /api/recent?since=<unix>` 直近イベントの bulk 取得（初回ロード用）
- `GET /api/sessions/:id` 議事録 JSON
- `GET /api/audio/:segment_id` `Content-Type: audio/x-caf` で BLOB stream
- `WS  /stream` WebSocket、live push

### 6.2 ライブ通知の起点

fluentd の `out_sqlite_meeting_log` に **HTTP POST 通知出力**を兼ねる（`webhook_url` config）。web プロセスはこの POST を受けて WebSocket クライアント全員に broadcast する。

選択理由: SQLite の `update_hook` を別プロセスから安定に拾うのは pragma の都合上面倒で、fluentd 側で確実に書いた直後に明示的 notify する方が決定的。

### 6.3 WebSocket メッセージ契約

```jsonl
{"type":"quick",         "ch":"mic",    "text":"…", "ts":...}
{"type":"final",         "ch":"mic",    "transcript_id":N, "raw":"…", "ts":...}
{"type":"polished",      "transcript_id":N, "text":"…"}
{"type":"entity",        "transcript_id":N, "entities":[{"text":"...","kind":"term"}]}
{"type":"edge",          "src":"…", "dst":"…", "weight":1.2, "last_observed_at":...}
{"type":"sound",         "ch":"screen", "label":"laughter", "confidence":0.9, "ts":...}
{"type":"audio_segment", "id":N, "channel":"mic", "started_at":..., "duration_sec":...}
```

### 6.4 フロントエンド

`web/index.html` 1 ファイルから始める。assets は `web/assets/` 直下。

- CSS Grid 3 カラム: `grid-template-columns: 1fr 1fr 1.5fr`
- 左: Quick pane（volatile を上書き、final 確定で下にフラッシュ）
- 中央: Perfect pane（final + polished、speaker 別の alternating bg）
- 右: Network Graph（`3d-force-graph`、ノードクリックで該当 transcript 行へ cross-highlight）

PicoRuby:wasm が WebSocket subscribe を一手に引き受け、DOM 更新と `forceGraph.graphData(...)` 更新を行う。グラフ描画前に `requestAnimationFrame` 内で時間減衰 `weight *= exp(-Δt/τ)` を適用（τ=1800 秒）。

## 7. プロセス監督: launchd

`~/Library/LaunchAgents/` に 3 plist：

- `dev.bash0c7.audio-transcription.swiftcap.plist`
- `dev.bash0c7.audio-transcription.fluentd.plist`
- `dev.bash0c7.audio-transcription.web.plist`

共通設定:

- `KeepAlive=true`
- `RunAtLoad=true`
- `StandardOutPath` / `StandardErrorPath` を `~/Library/Logs/audio-transcription/<name>.log`
- 起動順序の依存は持たせない（互いに tolerant に設計）：
  - swiftcap は単独で動く（fluentd 落ち中はファイルが spool に溜まるだけ）
  - fluentd は `in_tail` で末尾追従、再起動時は position file から復旧
  - web は WAL readonly で open、SQLite なければ HTTP 503 を返す

`scripts/setup.rb` で plist 生成 + `launchctl bootstrap gui/<uid> <plist>` を行う。

## 8. リポジトリ構成

```
fluentd-audio-transcription-system/
├── README.md                          # 旧来から書き換え
├── CLAUDE.md
├── Gemfile                            # fluentd, sinatra, sqlite3, rb-natural-language-mac, rb-foundation-model-mac, faye-websocket, puma
├── Rakefile                           # build / test / setup タスク
├── docs/
│   └── superpowers/specs/
│       └── 2026-05-05-fluentd-audio-transcription-v2-design.md  # 本書
├── swift/
│   └── swiftcap/                      # 独立 Swift Package
│       ├── Package.swift
│       └── Sources/Swiftcap/...
├── lib/
│   └── fluent/
│       └── plugin/
│           ├── filter_audio_state.rb
│           ├── filter_natural_language_mac.rb
│           ├── filter_foundation_model_mac.rb
│           └── out_sqlite_meeting_log.rb
├── web/
│   ├── app.rb                         # sinatra
│   ├── config.ru
│   ├── views/
│   │   └── index.erb
│   └── assets/
│       ├── picoruby.wasm
│       ├── app.rb                     # PicoRuby:wasm 上で動く
│       ├── three.min.js
│       └── 3d-force-graph.min.js
├── config/
│   ├── fluent.conf
│   └── stopwords.yml
├── migrations/
│   └── 20260505000000_initial.sql
├── scripts/
│   └── setup.rb                       # plist 生成 + launchctl bootstrap
├── plists/
│   ├── dev.bash0c7.audio-transcription.swiftcap.plist.erb
│   ├── dev.bash0c7.audio-transcription.fluentd.plist.erb
│   └── dev.bash0c7.audio-transcription.web.plist.erb
└── test/
    ├── fluentd/                       # plugin の test-unit
    └── web/
```

## 9. テスト方針

- **fluentd plugin**: `test-unit` + `Fluent::Test::FilterTest` 等の標準ヘルパで単体テスト。 `rake test` で実行。本リポ内蔵 plugin 全 4 種それぞれの fixture JSONL から in/out を assert。
- **swiftcap**: `swift test` で unit。Speech / SoundAnalysis / ScreenCaptureKit の framework 呼び出し部はプロトコル抽象化してテスト時はモック注入。テストでも実機録音はしない（CI 不要、手動 e2e のみ）。
- **web**: sinatra app 単体は `rack-test`、フロントエンドの PicoRuby:wasm は `rake server` で手動確認（自動化しない、MVP では）。
- **DB**: `migrations/` 適用 + `_sqlite_mcp_meta` 整合性のテストを 1 本。

`bundle exec rake test` を Ruby 側のエントリーポイントとし、長時間 batch には CLAUDE.md のロングバッチパターン（`screen -dmS`）を適用。

## 10. MVP スコープと非スコープ

### MVP に入れる

- swiftcap（録音 + SpeechAnalyzer/SpeechTranscriber + SoundAnalysis）
- fluentd 4 plugin
- SQLite 全テーブル + FTS5 + `_sqlite_mcp_meta`
- web 3 カラム + WebSocket + 3d-force-graph
- launchd plist 3 枚と `setup.rb`
- グラフ抽出 G2（NLTagger ベース共起 + stopwords）
- chiebukuro-mcp readonly 連携の互換性確保（meta テーブルと WAL）

### 明示的に非 MVP（拡張ポイントは確保）

- ファイル再 transcribe（Speech フォールバック）
- Whisper 併用（戦略 R）
- 画面音声内の話者分離
- Foundation Model でのトピックレイヤ（G3）
- AR グラス連携
- ライフログ 24h 向け tier ダウン
- 話者埋め込み（sqlite-vec）
- フロントエンドの自動テスト

これらが将来入る余地：

- fluentd filter chain の挿入位置
- `entities.kind` の値拡張
- audio_segments の `codec` カラム
- スキーマは増殖前提（マイグレーションで増設可）

## 11. 移行手順（作業順）

1. 旧構成（PyCall + MLX Whisper + ffmpeg ffmpeg-python venv）の停止と退避
2. 既存 fluent-plugin-audio-* / rb-record-transcribe-mac の archive 化
3. 本リポを破壊的書き換え（旧 setup.rb / templates/ / specification/ を削除、本書を唯一の仕様とする）
4. swiftcap Swift Package 新設、smoke 録音と SpeechTranscriber on-device 起動を確認
5. SQLite migrations 0001 で全テーブル作成、`_sqlite_mcp_meta` 投入
6. fluentd plugin 4 種を順次実装（state → final → entity 抽出 → polished）、各 plugin 単体 RED→GREEN→REFACTOR
7. web/ sinatra app + assets + PicoRuby:wasm + 3d-force-graph で 3 カラム描画
8. plist 3 枚 + setup.rb で launchctl bootstrap
9. 手動 e2e（実会議 30 分）でクイック・完璧・グラフが連動することを確認

## 12. 参照

- WWDC25 セッション: Bringing advanced speech-to-text to your app with SpeechAnalyzer
- Apple Developer Documentation: SpeechAnalyzer / SpeechTranscriber / SNAudioStreamAnalyzer / ScreenCaptureKit / AVAudioEngine
- 既存資産: `swift_gem`, `rb-speech-mac`, `rb-natural-language-mac`, `rb-sound-analysis-mac`, `rb-foundation-model-mac`, `chiebukuro-mcp`, `cloud-knowledge-db`, `picoruby-wasm-ai-repl`, `ruby_sound_visualizer`

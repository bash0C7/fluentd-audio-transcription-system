# Core feature completion (2026-05-06) — 設計

> 2026-05-06 の 15 分実会議 E5 で F1-F4 修正後の状態を検証した結果、core feature「**mic + app audio (画面収録経由) → 文字化 → SQLite → Web 表示**」が screen channel の runtime 障害で片肺となる現象を確認。本 spec は残ギャップを **1 統合スコープ**で潰す。設計書 v2 (`docs/superpowers/specs/2026-05-05-fluentd-audio-transcription-v2-design.md`) と F1-F4 spec (`docs/superpowers/specs/2026-05-06-core-fixes-from-e5.md`) を絶対 reference とする。

---

## 1. 目的とスコープ

### 目的

mic と app audio (system audio via ScreenCaptureKit) の **両 channel で音声 → 文字化 → SQLite 保存 → Web 表示** が E2E で動作する状態にする。さらに **runtime 中の silent failure を排除**し、screen channel が死んでも mic は継続録音・文字化される mic-only degrade を実装する。

### スコープ（このひとつの spec で扱う）

- **G1**: SCStream runtime error (-3815 等) の silent failure 排除 → **mic-only degrade**
- **G2**: screen channel の E2E 検証強化（mini-E5 で `transcripts.channel='screen'` row 増加 assertion）
- **G3**: Web 表示の自動検証（rack-test で `/api/recent` と `/_internal/notify` の broadcast path）
- **G4**: Ruby 4.0.3 化（`rbenv local` 1 行）

### Out-of-scope（明示）

- **画面収録対象の選択 UI**（display 一覧 / window 単位 / アプリ単位）。core feature の充足には現状の「先頭 display 全体・音声のみ取得」で十分（user 確認: 録画は不要、音声が取れれば OK）。複数 display 管理は別 spec。
- **ScreenCaptureKit 映像 capture 抑止の最適化**（`SCStreamConfiguration` で frame rate 0 等にして音声 only モードを厳密化する余地）。core feature 阻害ではないため別 issue。
- **F4 の SIGKILL fallback 追加**（P4 原則維持、graceful drain 失敗は bug として可視化）。
- **WebSocket `/_internal/notify` の auth 追加**（local-only 用途、外部公開なし）。
- **chrome-mcp 経由の UI 視認自動化**（chrome MCP permission flow が別セッションで要修復、本 spec は rack-test レベルまで）。
- **PicoRuby:wasm frontend の自動 test**（v2-design §10 で MVP 外と明記、依然 manual）。
- **既存 transcripts/audio_segments の backfill**（古いデータは時間 0.0 のまま残置、本 spec の修正後は新データから正しく入る）。

---

## 2. E5 観察 → 修正のマッピング

| 観察 issue | 根本原因 | 修正 |
|---|---|---|
| 15 分 E5 で screen channel が 5 連続 0-byte caf rotation | SCStream が -3815 で停止後、`ScreenStreamDelegate.didStopWithError` が stderr 出力のみ。`CaptureCoordinator` は通知を受けず、screen recorder の auto-rotate (300s) が dead stream で 0-byte caf を生成し続ける | **G1** |
| mini-E5 (synthetic) は PASS、本番 E5 で screen failure 検出できず | mini-E5 L3 は SQLite の transcripts 全体カウントのみ、channel 別の row 増加検証がない。30 秒 synthetic で SCStream が落ちる条件を再現していない | **G2** |
| Web 表示動作未検証（chrome-mcp permission denied） | v2-design §10 で web 自動 test は MVP 外と明記、test/web/ ディレクトリ自体存在せず | **G3**（スコープ昇格） |
| Ruby 4.0.1 固定（dev-env は 4.0.3 もインストール済） | プロジェクト `.ruby-version` が `4.0.1` のまま | **G4** |

---

## 3. 不変原則（追加分）

既存 P1-P5（F1-F4 spec で確立）は引き続き維持。本 spec で追加：

- **P6**: silent failure は startup でも **runtime** でも禁止。runtime の障害は loud event（state.jsonl `kind:"channel_failed"`）+ stderr log + 該当 channel の rotate 停止で可視化する。プロセス全停止はしない。
- **P7**: mic channel と screen channel は **独立**。片方が failed しても他方は録音・文字化・保存・表示を継続する。
- **P8**: 「**録画は不要、音声のみ取得で十分**」が user 要件（2026-05-06 確認）。screen 録音対象は先頭 display 全体（現行 `SCShareableContent.current.displays.first`）でよく、selection UI は本 spec 範囲外。

---

## 4. G1: SCStream runtime error → mic-only degrade

### 該当 file

- `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift:171-196` (`startScreen` + `ScreenStreamDelegate`)
- `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift:225-231` (`ScreenStreamDelegate` 既存実装)

### 現状（E5 観測）

```swift
final class ScreenStreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("SCStream stopped with error: \(error)\n".data(using: .utf8)!)
    }
}
```

これは log-and-forget sink。delegate は coordinator への参照を持たず、error 通知が伝搬しない。結果、`screenStream` は dead 参照のまま生存し、auto-rotate timer (300s) が `recorder.finalize()` を呼び続け、AVAssetWriter が **0-byte caf** を吐き続ける。

### 修正方針: mic-only degrade（user 確認済 = (c)）

SCStream runtime error 受信時：

1. **state.jsonl に `kind:"channel_failed"` event を emit**（loud event）
2. **stderr に degrade log 出力**
3. **screen channel の `screenStream` / `screenAudioOutput` / `recorders["screen"]` 等を null 化**
4. **mic 側は何もせず継続**（auto-rotate timer は走り続けるが screen 側 dict が空なので no-op）
5. **shutdownRotate** は `screenStream != nil` チェックを足し、既に死んでる stream に `stopCapture` を呼ばない

### 修正詳細

#### 4.1 ScreenStreamDelegate に coordinator weak ref を追加

```swift
final class ScreenStreamDelegate: NSObject, SCStreamDelegate {
    weak var coordinator: CaptureCoordinator?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("SCStream stopped with error: \(error)\n".data(using: .utf8)!)
        Task { await coordinator?.handleScreenStreamStopped(error: error) }
    }
}
```

#### 4.2 startScreen で delegate.coordinator 設定

`CaptureCoordinator.swift:182-184` の delegate 構築箇所で：

```swift
let delegate = ScreenStreamDelegate()
delegate.coordinator = self
screenDelegate = delegate
```

#### 4.3 CaptureCoordinator に handleScreenStreamStopped(error:) 追加

```swift
func handleScreenStreamStopped(error: Error) async {
    // already nulled (e.g. shutdown path also calls): no-op idempotent
    guard screenStream != nil else { return }

    FileHandle.standardError.write(
        "handleScreenStreamStopped: marking screen channel as dead, mic continues. error=\(error)\n"
            .data(using: .utf8)!
    )

    // emit loud channel_failed event to state.jsonl (P6)
    try? stateWriter.append([
        "ts": Date().timeIntervalSince1970,
        "kind": "channel_failed",
        "channel": "screen",
        "reason": "scstream_error",
        "error": "\(error)"
    ])

    // null all screen-channel state so subsequent rotate / shutdown skip cleanly
    screenStream = nil
    screenAudioOutput = nil
    screenDelegate = nil

    // finalize current screen recorder one last time (in-flight buffer flush)
    // then drop the recorder entirely. After this, rotateAll() finds no
    // screen recorder and naturally skips the channel.
    if let r = recorders["screen"] {
        await rotate(channel: "screen", recorder: r, reason: "channel_failed")
        recorders["screen"] = nil
    }
    transcribers["screen"] = nil
    sounds["screen"] = nil
}
```

#### 4.4 shutdownRotate で dead stream への stopCapture を skip

`CaptureCoordinator.swift:65-78` 付近の shutdown 処理を：

```swift
if let s = screenStream {
    try? await s.stopCapture()
    screenStream = nil
}
// (既存) mic engine stop、両 channel rotate
```

`screenStream` が既に nil（handleScreenStreamStopped で null 化された後）なら no-op。

### Web 表示への channel_failed 反映（G3 と連携）

`state.jsonl` の `kind:"channel_failed"` event は本 spec 内では **fluentd で処理しない**（filter_audio_state は `kind:"rotated"` のみ pass-through）。Web に「screen 死亡」バッジを出す機能追加は別 spec。

ただし G3 の rack-test で **screen channel の transcripts が無い場合に `/api/recent` が 200 で mic-only な response を返す** 動作だけは検証する。

### テスト

- `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorChannelFailureTests.swift`（新設）
  - `test_handleScreenStreamStopped_emitsChannelFailedEvent`: state writer mock で `kind:"channel_failed"` event が emit
  - `test_handleScreenStreamStopped_nullsScreenStreamAndDelegate`: 呼び出し後 `screenStream` / `screenAudioOutput` / `screenDelegate` がいずれも nil
  - `test_handleScreenStreamStopped_isIdempotent`: 2 回呼んでも 2 回目以降 no-op（重複 channel_failed event 出ない）
- 実 SCStream の -3815 は実機 hardware 状況依存で deterministic test 困難 → **本番 E5 reverify** で観察 layer として担保

---

## 5. G2: screen channel E2E 検証強化

### 該当 file

- `lib/audio_transcription/synthetic_e5.rb` (`verify_l3_sqlite` および baseline capture)

### 現状

`verify_l3_sqlite` は transcripts と audio_segments の **全体カウント**のみ：

```ruby
t = db.get_first_value("SELECT COUNT(*) FROM transcripts WHERE ended_at > 0.0") - @baseline[:transcripts_with_time]
fail!(:L3, "no new transcripts with non-zero ended_at (delta=#{t})") if t <= 0
```

mic と screen のどちらかでも増えれば PASS してしまう。本番 E5 で screen が 0-byte で transcripts が mic only でも mini-E5 は気づけない。

### 修正

baseline capture と verify を **channel 別**に分割：

```ruby
def capture_baseline
  @baseline[:cafs] = Dir.glob(File.join(@spool_dir, '*.caf'))
  @baseline[:rotated_count] = count_rotated
  @baseline[:ack_count] = count_ack
  @baseline[:mic_transcripts] = count_transcripts_with_time(channel: 'mic')
  @baseline[:screen_transcripts] = count_transcripts_with_time(channel: 'screen')
end

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

def count_transcripts_with_time(channel:)
  with_db { |db| db.get_first_value(
    'SELECT COUNT(*) FROM transcripts WHERE channel=? AND ended_at > 0.0',
    [channel]
  ) }
rescue SQLite3::SQLException
  0
end
```

mini-E5 の synthetic 30 秒では `afplay` が speakers 経由で再生 → SCStream が system audio として capture → screen channel transcripts が必ず生まれる前提（既存設計）。channel 別 assertion 追加で **screen channel が壊れた瞬間に mini-E5 が FAIL する**。

### テスト

- mini-E5 を 1 回走らせて 5/5 PASS を確認（runtime 検証、code 単体 test なし）

---

## 6. G3: Web 表示の自動検証

### 該当 file

- `Gemfile`（test group に rack-test 追加）
- `test/web/test_recent_api.rb`（新設）
- `test/web/test_internal_notify.rb`（新設）

### スコープ昇格の根拠

v2-design §9 で「sinatra app 単体は `rack-test`、frontend は manual」と明記されているが、実装が無い。本 spec で **rack-test 部分のみ**実装する（frontend PicoRuby:wasm 自動 test は依然 MVP 外）。

### 修正

#### 6.1 Gemfile に rack-test 追加

```ruby
group :test do
  gem 'rack-test'
  # ... 既存 gem
end
```

#### 6.2 test/web/test_recent_api.rb 新設

```ruby
require 'test/unit'
require 'rack/test'
require 'sqlite3'
require 'json'
require 'tmpdir'
require 'fileutils'

class TestRecentApi < Test::Unit::TestCase
  include Rack::Test::Methods

  REPO_ROOT = File.expand_path('../..', __dir__)

  def app
    @app ||= begin
      ENV['DB_PATH'] = @db_path
      load File.join(REPO_ROOT, 'web', 'app.rb')
      TranscriptionWeb
    end
  end

  def setup
    @tmp = Dir.mktmpdir('web-test-')
    @db_path = File.join(@tmp, 'test.sqlite')
    seed_schema
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
    refute body['transcripts'].any? { |t| t['raw_text'] == 'broken' },
           '/api/recent must exclude rows with ended_at == 0.0'
  end

  def test_get_recent_with_only_mic_transcripts_returns_mic_only
    # screen channel の row が無い状態でも 200 で mic only response (G1 mic-only degrade のあり方)
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

  def seed_schema
    # ... migrate.rb と同等の最小 schema 実行（transcripts, audio_segments, sessions, entities, entity_edges）
  end

  def seed_rows
    insert_transcript(channel: 'mic',    text: 'hello mic',    started_at: 100.0, ended_at: 105.0)
    insert_transcript(channel: 'screen', text: 'hello screen', started_at: 200.0, ended_at: 210.0)
  end

  def insert_transcript(channel:, text:, started_at:, ended_at:)
    db = SQLite3::Database.new(@db_path)
    # session 1 件 ensure
    sid = db.execute(
      'INSERT INTO sessions (channel, started_at, ended_at) VALUES (?, ?, ?)',
      [channel, started_at, ended_at]
    ).then { db.last_insert_row_id }
    db.execute(
      "INSERT INTO transcripts (session_id, channel, raw_text, polished_text, " \
      "started_at, ended_at, language, swiftcap_transcript_id) " \
      "VALUES (?, ?, ?, '', ?, ?, 'ja-JP', ?)",
      [sid, channel, text, started_at, ended_at, "u-#{rand(1000000)}"]
    )
    db.close
  end
end
```

#### 6.3 test/web/test_internal_notify.rb 新設

```ruby
require 'test/unit'
require 'rack/test'
require 'json'

class TestInternalNotify < Test::Unit::TestCase
  include Rack::Test::Methods

  REPO_ROOT = File.expand_path('../..', __dir__)

  def app
    @app ||= begin
      load File.join(REPO_ROOT, 'web', 'app.rb')
      TranscriptionWeb
    end
  end

  def test_notify_accepts_valid_json_payload
    payload = { kind: 'final', channel: 'mic', text: 'hello', started_at: 1.0, ended_at: 2.0 }
    post '/_internal/notify', payload.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_includes 200..299, last_response.status,
                    "expected 2xx, got #{last_response.status}: #{last_response.body}"
  end

  def test_notify_broadcasts_to_open_websockets
    # WEBSOCKETS const に mock socket を入れる、post して send が呼ばれること assert
    fake = FakeWebSocket.new
    web_app = TranscriptionWeb
    web_app::WEBSOCKETS << fake
    begin
      post '/_internal/notify', { kind: 'quick', text: 'live' }.to_json,
           { 'CONTENT_TYPE' => 'application/json' }
      assert_equal 1, fake.sent_messages.size
    ensure
      web_app::WEBSOCKETS.clear
    end
  end

  class FakeWebSocket
    attr_reader :sent_messages
    def initialize; @sent_messages = []; end
    def send(msg); @sent_messages << msg; end
  end
end
```

### テスト

- `bundle exec rake test` で `test/web/*` が自動走行
- `test/web/` 配下 2 file が all GREEN

---

## 7. G4: Ruby 4.0.3 化

### 該当 file

- `.ruby-version`（`4.0.1` → `4.0.3`、`rbenv local` で書き換え）

### 修正

`rbenv local 4.0.3` を実行する。これ 1 行で `.ruby-version` の書き換えと version 切替が atomic に走る（P8 原則）。続いて：

```bash
bundle install
bundle exec rake test
cd swift/swiftcap && swift test && cd ../..
```

regression が出ないことを確認。出た場合は別 issue。

### テスト

- `bundle exec rake test` 全 PASS
- `swift test` 全 PASS
- mini-E5 は後続 task で実走（end-to-end 確認）

---

## 8. 実行順序

```
G4 Ruby 4.0.3 化
  ↓ 全 task の base
G1 SCStream runtime error → mic-only degrade（最重要）
  ↓ runtime silent failure 排除
G2 mini-E5 channel='screen' assertion 強化
  ↓ G1 検証用、screen 死亡を mini-E5 で検出可能に
G3 Web 自動 test（rack-test）
  ↓ Web 動作 baseline 確立
本番 E5 reverify
  → 15 分実会議で screen 録音中に SCStream 障害が再発しない場合: 5/5 PASS、core feature 完動
  → 再発した場合: state.jsonl の channel_failed event と SQLite mic-only row、Web rack-test 全部 PASS であることを確認、mic-only degrade 動作の物証として記録
```

---

## 9. Commit 境界（CLAUDE.md TDD 規律準拠）

| Phase | 想定 commit |
|---|---|
| spec/plan | (1) `docs:` spec and plan for core feature completion |
| G4 Ruby bump | (1) `chore(ruby):` bump to 4.0.3 via rbenv local |
| G1 RED | (1) `test(swiftcap):` add failing spec for handleScreenStreamStopped |
| G1 GREEN | (1) `feat(swiftcap):` handle SCStream runtime error with mic-only degrade |
| G1 REFACTOR | (任意) `refactor(swiftcap):` extract channel finalize helper（必要な場合のみ） |
| G2 | (1) `test:` assert channel='screen' transcripts in mini-E5 L3 |
| G3 RED | (1) `test(web):` add failing rack-test specs for /api/recent and /_internal/notify |
| G3 GREEN | (1) `chore(test):` add rack-test gem; web routes already pass（既存 routes 動作前提なら code 変更ゼロで GREEN） |
| 観察 | (1) `docs:` record real E5 reverify outcome |

合計 7-9 commits、半日相当の plan。

### branch / PR

- 単一 feature branch `feat/core-feature-completion-2026-05-06`
- PR 1 本にまとめ、以下を merge 条件：
  - `bundle exec rake test` 全 PASS（Ruby 4.0.3 上）
  - `cd swift/swiftcap && swift test` 全 PASS
  - `bundle exec rake test:e5_synthetic` 5/5 PASS（mic + screen 別 assertion）
  - 本番 E5 reverify で core feature 動作確認（mic 継続録音 + screen 健常時は両 channel transcripts、screen 障害時は mic-only degrade と channel_failed event）

---

## 10. 参照

- 設計書 v2: `docs/superpowers/specs/2026-05-05-fluentd-audio-transcription-v2-design.md`
- F1-F4 spec: `docs/superpowers/specs/2026-05-06-core-fixes-from-e5.md`
- F1-F4 plan: `docs/superpowers/plans/2026-05-06-core-fixes-from-e5.md`
- 2026-05-06 実会議 E5 観察: 本セッションの 5-layer verification 結果（mic PASS / screen 5 連続 0-byte caf rotation / SCStream error -3815 = "取り込みを行うディスプレイまたはウインドウが見つかりませんでした"）
- ScreenCaptureKit `SCStreamError` reference（Apple Developer Documentation）

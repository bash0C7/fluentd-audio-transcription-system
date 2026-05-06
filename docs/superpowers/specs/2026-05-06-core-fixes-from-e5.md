# Core fixes from E5 (2026-05-06) — 設計

> 2026-05-06 に実会議想定の 30 分 E5 (`bundle exec rake start:all` → 22 分間 YouTube + Safari でキャプチャ → `stop:all`) を実施した結果、**5 つの観測 issue を 4 つの核心修正に集約**した spec。設計書 v2 (`docs/superpowers/specs/2026-05-05-fluentd-audio-transcription-v2-design.md`) の data contract への準拠を絶対 reference とする。

---

## 1. 目的とスコープ

### 目的

実会議で **mic から人声が録音され、文字化が損なわれず、graceful に停止できる** 状態を取り戻す。E5 で観測された silent failure / contract 違反 / process leak を「当たり前の標準パターン」で潰す。

### スコープ（このひとつの spec で扱う）

- **F1**: swiftcap mic input の startup log + first-buffer 観測（`startScreen` との対称化）
- **F2**: swiftcap data contract 完全実装（`final.jsonl` / `state.jsonl rotated` の `started_at` / `ended_at` / `language` emit）
- **F3**: fluentd ack 重複の **観察**（F4 fix 後に再現するか確認、code 変更は条件付き）
- **F4**: Rakefile `stop:all` の **PID file ベース graceful shutdown**（service 標準機能利用、SIGKILL escalation なし）
- **synthetic mini-E5**: 5 layer 統合 acceptance test (`rake test:e5_synthetic`)

### Out-of-scope（明示）

- web frontend / `/api/recent` ルート変更（F2 で `ended_at` が埋まれば現行動作）
- AppleFoundationModel guardrailViolation 対策
- 既存 262 transcripts / 26 audio_segments の backfill（古いデータは時間 0.0 のまま残置、E5 再走で新データから正しく入る）
- fluentd の zero-downtime restart (SIGUSR2 経由 reload) ※本 spec は stop のみ

---

## 2. E5 観察 → 核心修正のマッピング

| 観察 issue | 根本原因 | 修正 |
|---|---|---|
| mic indicator 出ず、mic transcripts 断片（最長 23 文字） | `startMic()` に startScreen 相当の startup / first-buffer 観測 log が無く silent failure を検出できなかった | **F1** |
| transcripts.ended_at / audio_segments.duration_sec / sessions.ended_at 全 0.0 | swiftcap が `final.jsonl` / `state.jsonl rotated` に `started_at` / `ended_at` / `language` を emit していない | **F2** |
| web `/api/recent` 0 件返却 | F2 の派生（`WHERE ended_at > since` で全除外） | **F2 で同時解決** |
| ack.jsonl 重複（同 caf に 2 行 consumed） | F4 で smoke 残骸 fluentd が殺せず、E5 fluentd と並列で同 `state.jsonl` を tail | **F3 (F4 後に観察)** |
| stop:all で puma + fluentd 残存 | `pkill -TERM -x` の process name 不一致 / 3 秒 sleep 不足で graceful flush 中断 | **F4** |

---

## 3. 不変原則

- **P1**: mic は当たり前に録れる。silent failure は CI / test で検出可能にする。
- **P2**: data contract は設計書 v2 (line 88-92) を絶対 reference とする。実装が乖離していれば実装を直す。
- **P3**: TDD 螺旋 (RED / GREEN / REFACTOR) の commit 境界規律を 4 修正全てで守る。
- **P4**: graceful shutdown を中断しない。data drain 中の SIGKILL は文字化損失。SIGTERM + 十分な wait のみ。
- **P5**: Built-in standard 機能を優先（puma `pidfile` DSL、fluentd `-d` daemon）。custom 拡張は最小に。

---

## 4. F1: swiftcap mic input 観測性の対称化

### 該当 file

`swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift:124-140` (`startMic()`)

### 現状

`installTap` および `try micEngine.start()` のコードは存在する (line 129, 139)。しかし `startScreen()` (line 148-168) と非対称で、startup の stderr log および first-buffer log が無く、mic input の死活が外部から観測できない。E5 で 22 分間 silent failure に気付けなかった。

### 修正

1. `startMic()` 末尾、`try micEngine.start()` 直後に startup log を stderr に出力：
   ```swift
   FileHandle.standardError.write(
     "startMic: input running format=\(inputFormat) → \(format)\n".data(using: .utf8)!
   )
   ```
2. `installTap` の callback 内で **first buffer 到着時のみ 1 回** stderr に出力（`ScreenAudioOutput: first buffer received` と同形式）：
   ```swift
   MicAudioOutput: first buffer received format=<...>
   ```
   `ConvertOnce` 相当の once-fire ガードを使用。
3. `startMic()` から **5 秒以内に first buffer が到着しなければ throws**（silent silence は launch 失敗扱い）。
   - 実装: `Task` で 5 秒タイマ起動、once-fire ガードが立っていなければ `throw NSError(domain: "swiftcap.mic", code: -1, userInfo: [NSLocalizedDescriptionKey: "no mic buffer in 5s"])`。

### テスト

- `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorTests.swift` (新設)
  - `test_startMic_emitsStartupLogAfterStart`: stderr capture して `startMic:` 行が出ること
  - `test_startMic_throwsIfNoBufferIn5s`: 入力ノードが zero-channel 等の状況を擬似的に作って throw を assert
- 実 mic 入力の deterministic test は TCC / hardware 依存で困難なため、**実音声 assertion は §8 synthetic mini-E5 で担保**。

---

## 5. F2: swiftcap data contract 完全実装

### 該当 file

- `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift:95-115` (rotation の state.jsonl emit)
- `swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift:61-64` (final.jsonl emit)
- `swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift` (startedAt 保持の追加)
- `lib/fluent/plugin/filter_audio_state.rb:9-22` (File.mtime fallback 削除)

### 設計書 v2 の絶対 contract（再宣言）

| event | 必須 field |
|---|---|
| `final.jsonl` | `ts, ch, kind:"final", text, started_at, ended_at, language, transcript_id` |
| `state.jsonl` rotated | `ts, kind:"rotated", channel, path, started_at, ended_at, bytes, reason?` |

### 修正

1. **`RotatingRecorder` に `startedAt: TimeInterval` を保持**：
   - `start(at: Date)` で `startedAt = date.timeIntervalSince1970` を代入
   - `finalize` の completion callback signature を `(URL, startedAt, endedAt) -> Void` に変更（既存呼び出し側で受ける）
2. **`CaptureCoordinator.rotate(...)`** で受けた `startedAt`/`endedAt` を state.jsonl の rotated event dict に追加：
   ```swift
   stateWriter.append([
     "ts": now,
     "kind": "rotated",
     "channel": channel,
     "path": url.path,
     "started_at": startedAt,
     "ended_at": endedAt,
     "bytes": bytes,
     "reason": reason,
   ])
   ```
3. **`TranscriberWrapper.swift:61-64`** で SpeechTranscriber の result から `audioTimeRange` を取り、final.jsonl emit 時に追加：
   ```swift
   try? finalWriter.append([
     "ts": now,
     "ch": channel,
     "kind": "final",
     "text": text,
     "started_at": result.audioTimeRange.start.seconds,
     "ended_at": result.audioTimeRange.end.seconds,
     "language": locale.identifier,  // "ja-JP" 等
     "transcript_id": transcriptId,
   ])
   ```
4. **`filter_audio_state.rb:14-15`** の `File.mtime` fallback を **削除**。契約欠落時は filter で隠蔽せず、event を warn log + drop する：
   ```ruby
   def filter(_tag, _time, record)
     return nil unless record['kind'] == 'rotated'
     unless record['started_at'] && record['ended_at']
       log.warn "rotated event missing started_at/ended_at, dropping", record: record
       return nil
     end
     # ... 以降は既存の BLOB 化処理
   end
   ```

### テスト

- `swift/swiftcap/Tests/SwiftcapTests/RotatingRecorderTests.swift`:
  - `test_finalize_callbackCarriesStartedAndEndedAt`: `start` 後 `finalize` の callback で `(url, startedAt, endedAt)` 全部受け取れる
- `test/fluent/test_out_sqlite_meeting_log.rb`:
  - `test_transcripts_endedAt_persisted_nonZero`: handle_final に `started_at: 100.0, ended_at: 105.0` を含む record を渡して INSERT 後の SELECT で確認

---

## 6. F3: ack 重複の観察方針

### 仮説

E5 中、smoke 起動時の fluentd worker (PID 91760) が F4 の signal 失敗で生き残り、E5 fluentd worker (PID 96215) と同じ `spool/state.jsonl` を tail。同じ rotated event を 2 worker が処理 → ack.jsonl に 2 行追記。**F4 fix で並列 fluentd が出ない世界になれば自然消滅**。

### スコープ判定

- 本 spec では **code 変更を予約しない**
- §8 synthetic mini-E5 の post-condition で `wc -l ack.jsonl == count of rotated caf in state.jsonl` を assert
- assert pass: F3 完了、追加 fix 不要
- assert fail: 別 spec で `out_sqlite_meeting_log` plugin に idempotency（ack.jsonl の path Set memoize で skip）追加

### 観察結果（2026-05-06、F4 fix 後）

mini-E5 を 4 回連続実行した結果、**新規 run で生成された 8 caf rotation event に対し ack.jsonl が 8 行（完全 1:1）**。仮説通り F3 は F4 (PID-based graceful stop) の症状であった。

- 旧 ack.jsonl に残る 8 件の dupe entry は F4 fix 前の 30 分 E5 由来の歴史的残骸（smoke の fluentd 残骸が新規 fluentd と並列で同一 state.jsonl を tail していた時期のもの）
- F4 fix 後、stop:all が PID 経由で確実に fluentd を 1 instance のみで kill する世界では並列 worker の発生機会無し
- → **F3 は plugin 変更不要、closed**

---

## 7. F4: Rakefile stop:all の graceful PID-file shutdown

### 該当 file

- `Rakefile:26-78` (`namespace :start` / `namespace :stop`)
- `web/puma.rb` (puma の pidfile DSL 追加)

### 設計

#### 7.1 PID file 取得（service 別 standard 機能優先）

| service | 取得方法 | 実装 |
|---|---|---|
| **puma** | built-in `pidfile` DSL | `web/puma.rb` に `pidfile File.expand_path("../tmp/run/puma.pid", __dir__)` 1 行追加 |
| **fluentd** | built-in `-d <pidfile>` (daemon mode) | 起動 cmd: `bundle exec fluentd -c config/fluent.conf -p lib/fluent/plugin -d tmp/run/fluentd.pid`。screen wrapping 廃止（`rake logs[fluentd]` は既に `tail -f` なので UX 不変） |
| **swiftcap** | bash wrapper | `screen -dmS audio-swiftcap bash -c 'echo $$ > tmp/run/swiftcap.pid; exec swiftcap ...'` |
| **caffeinate** | bash wrapper | 同上 (`tmp/run/caffeinate.pid`) |

#### 7.2 `tmp/run/` ディレクトリ

- `start:*` task の前段で `FileUtils.mkdir_p('tmp/run')` を ensure
- `.gitignore` に `tmp/run/` 追加

#### 7.3 stop helper

```ruby
def stop_via_pidfile(name, wait_sec, has_screen: true)
  pidfile = File.join(REPO_ROOT, 'tmp', 'run', "#{name}.pid")
  if File.exist?(pidfile)
    pid = File.read(pidfile).to_i
    if pid > 0 && process_alive?(pid)
      puts "stopping #{name} (pid=#{pid}), waiting up to #{wait_sec}s for graceful shutdown..."
      Process.kill('TERM', pid)
      deadline = Time.now + wait_sec
      sleep(0.2) while process_alive?(pid) && Time.now < deadline
      if process_alive?(pid)
        abort "#{name} did not exit within #{wait_sec}s (pid=#{pid}). Investigate; do NOT SIGKILL — graceful shutdown failure indicates a bug."
      end
      puts "stopped: #{name}"
    end
    File.delete(pidfile) rescue nil
  else
    puts "no pidfile: #{name}"
  end
  system("screen -X -S audio-#{name} quit > /dev/null 2>&1") if has_screen
end

def process_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH, Errno::EPERM
  false
end
```

#### 7.4 service 別 wait 時間（graceful drain 余裕）

| service | wait_sec | 根拠 |
|---|---|---|
| swiftcap | 30 | rotation finalize（AVAssetWriter / Speech analyzer finalize）|
| fluentd | 60 | buffer flush + SQLite commit + ack.jsonl 書き込み |
| puma | 10 | request drain |
| caffeinate | 5 | OS power assertion 解除 |

#### 7.5 stop:all の順序

```ruby
task all: %w[stop:swiftcap stop:fluentd stop:web stop:caffeinate]
```

**順序が重要**：swiftcap を最初に止めないと新しい rotated event が emit されて fluentd の drain が終わらない。fluentd → puma → caffeinate と続く。

#### 7.6 SIGKILL fallback は持たない

P4 不変原則。SIGTERM が効かない場合は graceful 設計のバグなので可視化（abort）する。SIGKILL で隠蔽すると data 損失（fluentd: buffered events、swiftcap: in-progress caf）。

### テスト

- `test/test_rake_lifecycle.rb` (新設)
  - 4 service それぞれに対し:
    1. `Process.spawn` で fake long-running process 起動 → PID file 書き込み
    2. `Rake::Task['stop:<name>'].invoke`
    3. PID file 削除済み + process 死亡 を assert
  - fake process は `ruby -e 'trap("TERM"){exit}; loop{sleep 0.1}'` で SIGTERM gracefully に応答するもの

---

## 8. Synthetic mini-E5（統合 acceptance test）

### 目的

5 layer の integration を **30 秒で網羅** し、本番 E5 (実会議) の preflight として常用。CLAUDE.md の global "Debug Principles" の「silent failure を可視化」要件への直接的応答。

### task: `rake test:e5_synthetic`

```
1. tmp/run/, spool/, db/ の baseline snapshot 取得
2. rake start:all (4 service)
3. afplay test/fixtures/synthetic_e5_audio.wav &  # 既知音を speakers 経由で再生
4. sleep 30
5. rake stop:all
6. 5 layer assertion 実行（fail 時 stderr に詳細）:
   L1 swiftcap:
     - spool/mic-*.caf と spool/screen-*.caf がそれぞれ 1 個以上存在
     - 各 caf の RMS energy > silence_threshold（mic 死活判定）
   L2 fluentd:
     - tmp/log/fluentd.log に [error] / [warn] が無い（既知 [info] "Oj is not installed" 除く）
   L3 SQLite:
     - SELECT COUNT(*) FROM transcripts WHERE ended_at > 0.0  -- > 0
     - SELECT COUNT(*) FROM audio_segments WHERE duration_sec > 0.0  -- > 0
     - SELECT COUNT(*) FROM sessions WHERE ended_at > 0.0  -- > 0
   L4 ack closure (F3 観察):
     - wc -l spool/ack.jsonl == grep -c '"kind":"rotated"' spool/state.jsonl
   L5 process / pid 残存:
     - tmp/run/*.pid が全て削除されている
     - pgrep で puma / fluentd / swiftcap / caffeinate -dimsu の残存無し
7. baseline 復元（generated caf / db row は残す、F2 検証用に活用）
```

### test fixture

- `test/fixtures/synthetic_e5_audio.wav`: 30 秒の sine sweep 等、commit 可能な著作権 free な WAV。10〜20 KB 程度。
- macOS `afplay` を使用（標準 CLI、追加依存なし）。

### 実行ルール

- **default `rake test` には含めない**（実 audio device / TCC / SQLite write を伴うため CI 不可）
- **手動実行のみ**: `rake test:e5_synthetic` を本番 E5 直前に走らせる preflight
- CLAUDE.md の test execution delegation 規律対象外（subagent 不要、結果を直接観察したいから）

---

## 9. 実行順序

```
F4 (stop:all PID-file rewrite)
  ↓ 後続 test 走行で process leak しない土台を最初に
F1 (mic startup observability)
  ↓ user の絶対要件、core 機能復旧
F2 (data contract 実装)
  ↓ web 復活、session 区切り機能化
synthetic mini-E5 task 追加
  ↓ 5 layer 統合 acceptance、本番 E5 preflight
F3 観察
  → mini-E5 で ack 1:1 通る → spec 完了
  → 通らない → 別 spec で plugin idempotency 追加
```

---

## 10. Commit 境界（CLAUDE.md TDD 規律準拠）

| Phase | 想定 commit |
|---|---|
| F4 PID infra | (1) `test:` test_rake_lifecycle RED → (2) `feat(rake):` PID write/read GREEN → (3) `refactor:` 4 service stop helper 統合 |
| F1 observability | (1) `test(swiftcap):` first-buffer timeout RED → (2) `fix(swiftcap):` startMic log + first-buffer GREEN → (3) `refactor:` mic/screen log helper 統合（必要時のみ） |
| F2 contract | (1) `test:` transcripts.ended_at != 0.0 RED → (2) `feat(swiftcap):` started_at/ended_at/language emit GREEN → (3) `feat(fluent):` filter_audio_state fallback 削除（契約強制） |
| mini-E5 | (1) `test:` test/fixtures/synthetic_e5_audio.wav 追加 + rake test:e5_synthetic タスク |
| F3 観察 | spec 内では code 変更なし。観察のみ |

合計 12〜13 commits、半日〜1 日相当の plan。

### branch / PR

- 単一 feature branch `feat/core-fixes-2026-05-06` で 4 fix 統合
- PR 1 本にまとめ、`rake test:e5_synthetic` の pass を merge 条件
- mini-E5 は user 手動実行（screen / 実 device）

---

## 11. 参照

- 設計書 v2: `docs/superpowers/specs/2026-05-05-fluentd-audio-transcription-v2-design.md`
- 実装計画 v2: `docs/superpowers/plans/2026-05-05-fluentd-audio-transcription-v2.md`
- E5 観察: 本 conversation の Phase 4 verification 結果
- fluent-package v5.2.0 zero-downtime restart: <https://www.clear-code.com/blog/2024/12/27/fluent-package-v5.2.0.html>

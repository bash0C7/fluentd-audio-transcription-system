# 2026-05-06 Release-quality follow-ups

> 2026-05-06 E5 reverify (`docs/superpowers/observations/2026-05-06-e5-reverify.md`)
> で release 品質を一旦達成したあとに残った 3 件の follow-up を一括で潰す
> spec。README に記された "Quick / Perfect / Graph 3 ペインのライブ動作 +
> rake test pass" を MINIMUM スコープとして崩さない、を最優先。

---

## A. mini-E5 single-run-must-pass hardening

### 現象

`bundle exec rake test:mini_e5` が 30 秒 synthetic 再生 → 5 層 verify を
回す。Task 4 の reverify では「3 回目で PASS」になるパターンが観測された。
失敗は random、再起動だけで通るので transient timing flake。

### 仮説（候補 3 つ）

1. **start:all 後の固定 `sleep 5` が短い** ── fluentd config parse +
   in_tail open まで 5 秒で間に合わないと、afplay 終了までに最初の
   rotate 通知が in_tail に hit せず、L4 の rotated:ack=1:1 が崩れる。
2. **stop:all 直後すぐ verify** ── fluentd の最後の `out_sqlite_meeting_log`
   commit + ack.jsonl 書き込みが完了していない瞬間に verify_l4 が走り、
   rotated > ack で fail。
3. **swiftcap finalize 待ちなし** ── afplay 終了後、SpeechAnalyzer の最終
   transcript が finalize されて final.jsonl + ended_at>0 になるまで
   1〜2 秒の余裕が要る（rotated はすでに出ているが finalize は遅延）。

### 改善

`lib/audio_transcription/synthetic_e5.rb` の固定 sleep を **condition-based
wait** に置換：

- `wait_until_fluentd_ready` ── `tmp/log/fluentd.log` に
  `fluentd worker is now running` が出るまで (timeout 30 s, poll 0.2 s)
- `wait_until_rotated_increased` ── stop 前に L1/L2 が回るための grace
- `wait_until_ack_matches_rotated` ── verify_l4 内で polling (timeout 15 s)

固定 timeout はすべて十分余裕あり値。「polling 中に PASS したら即進む」
を実現する。

### 検証

`bundle exec rake test:mini_e5` を **5 連続単独 PASS** で hardening 達成
判定。screen detach パターンで long-run。

---

## B. /app.rb production cache busting

### 現象

PicoRuby:wasm は HTTP fetch した Ruby source を browser に bytecode
キャッシュするのと、Sinatra の static serve (`set :public_folder`) が
ETag のみで強い cache busting を持たない組み合わせで、
**`web/assets/app.rb` を編集してもブラウザが古い bytecode を流し続ける**
リスクがある。本セッション中も繰り返し詰まった (`app_v2.rb` `v3` `v4` `t1`
`t2` の rename workaround)。

### 改善

`web/views/index.erb` の `<script type="text/ruby" src="/app.rb">` を
**content hash 付き URL** に置換：

```erb
<script type="text/ruby" src="/app.rb?v=<%= app_rb_version %>"></script>
```

`app_rb_version` は `web/app.rb` 側 helper で `web/assets/app.rb` の
SHA-256 先頭 12 文字を返す。Sinatra プロセス起動時に 1 度計算して memoize
（再起動で更新）。

### 検証 (TDD)

`test/web/test_index_cache_busting.rb` (新規) で rack-test：

1. RED: `GET /` レスポンス body に `/app.rb?v=` で始まる URL が含まれる
2. RED: app.rb の content を変えると version 文字列が変わる
   (helper を直接 unit-test、ファイルを stub せずに本物書き換え + 再 hash 計算経路を
   テスト関数として呼べる構造にする)

GREEN: helper 実装 + index.erb 修正。

### スコープ外

`/style.css` も同じ問題を持ちうるが、release 品質クリティカルではない
ので外す。app.rb のみ。

---

## C. observations/ index

### 現象

これまでの 2 大観察 — `d4fd97b` の F3/F4 (mini-E5 dupe ack 真因確認) と
本セッションの E5 reverify — がそれぞれ別場所に記述されていて、新規
contributor が時系列・主題で navigate しづらい。

- F3/F4 観察は **specs** 側（`2026-05-06-core-fixes-from-e5.md` 末尾の
  「観察結果」節）に埋め込まれている
- E5 reverify は **observations/** 側（`2026-05-06-e5-reverify.md`）に
  独立 doc として置いてある

### 改善

`docs/superpowers/observations/INDEX.md` を新規作成。各観察に対して：

- date / title / 1 行 summary / source path

を pointer 形式で並べる。pointer は `..` 経由で specs 側にも飛ばせる
(F3/F4 observation は spec 内 anchor 指定)。

将来 observation 増えたら追記する単純な index、移動はしない（履歴を保つ）。

### 検証

doc only。`grep -l '^# ' docs/superpowers/observations/` で漏れがないか
目視確認するだけ。

---

## 実行順

1. C → 軽い、まず先に context を整える
2. B → TDD 1 サイクル
3. A → 実装後 5 回 mini-E5 走らせる long-run

各タスクで RED/GREEN/REFACTOR は分ける。3 タスク独立なので順序入れ替え可。

---

## D. SpeechAnalyzer 使い方の Apple sample 準拠化（A の root-cause fix）

### 現象

A の hardening (固定 sleep → condition wait + L2 whitelist + L3 mic
delta soft化) を適用しても、5x mini-E5 long-run で
`L3: no new mic transcripts (delta=0)` が 4/5 run で fail。緩和の
判断は「30s window で SpeechAnalyzer の言語 confidence threshold は
確率的」を仮定していたが、Apple 公式 SpeechAnalyzer サンプル
(`/Users/bash/Downloads/BringingAdvancedSpeechToTextCapabilitiesToYourApp`)
を読み合わせた結果、実は **AVAudioConverter callback の使い方が誤って
いて mic 経路の出力 buffer が常に frameLength=0** という根本問題が
判明。screen 経路は `CMSampleBuffer.toAVAudioPCMBuffer` 内で
`pcm.frameLength = frames` を明示設定しているため通っていた。

### 根本原因 2 つ

**問題 1**: `CaptureCoordinator.startMic` の AVAudioConverter input
block が永続的に `.haveData` を返し続け、終端 `.noDataNow` を出さない。

```swift
// 旧 (壊れている)
converter?.convert(to: outBuffer, error: &error) { _, status in
    status.pointee = .haveData
    return buffer
}
```

`.haveData` を返し続けると converter は「まだ input が来る」と認識
して output frame を確定せず `outBuffer.frameLength = 0` のまま
return される。SpeechAnalyzer に空 buffer が流れて transcript ゼロ。

**問題 2**: 出力 buffer の frameCapacity を `buffer.frameCapacity` で
計算している (実データ量 `frameLength` ではない)。サンプル
`BufferConversion.swift` は `Double(buffer.frameLength) *
sampleRateRatio` で計算している。capacity ベースだと resample 結果
で余剰領域が出てフォーマット不整合のリスク。

### 改善

**`startMic` と `convertToAnalyzerFormat` の両方** をサンプル準拠に
書き換える：

- frameLength × (outSr / inSr) で出力 capacity を計算
- 既存 `ConvertOnce` を使った 1 回フラグで、2 回目以降の input
  callback で `.noDataNow` + nil を返す（Swift 6 strict concurrency
  で `var bufferProcessed` が @Sendable closure に capture できない
  ため、Sendable-safe な `ConvertOnce` で代替）
- `converter.primeMethod = .none` (timestamp drift 回避、サンプル準拠)
- convert status `.error` を呼び出し側で握って早期 return

### 緩和 commit との関係

A の commit `73e9879` (RED) / `ab07201` (GREEN) で入れた L2 whitelist
+ L3 mic-delta soft化 は **safety net として残す**。理由：

- D の fix で mic transcript 頻度は大幅向上見込みだが、30s window で
  poisson 的に 0 になる確率はゼロにならない（実会議 1 件/分 ペース
  でも 30s で 0 件 = 約 60% だった、fix 後ペース上昇しても完全消滅
  はしない）
- L2 guardrailViolation whitelist は別観察（Apple Foundation Model
  の挙動）で、D とは無関係

### 検証

`swift build` + `swift test` (既存 unit test スイート) → mini-E5 5x
single-run-must-pass で実機 verify。緩和なしでも 5/5 PASS なら緩和
revert を検討。緩和込みで 5/5 PASS が安定なら現状維持。

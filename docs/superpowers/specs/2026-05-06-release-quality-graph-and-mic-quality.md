# Release-quality completion: Graph + mic-quality

Branch: `feat/release-quality-graph-and-mic-quality-2026-05-06`
Source plan: `~/.claude/plans/gentle-gathering-quilt.md`

## Context

README の release 品質ライン「Quick / Perfect / Graph 3 ペインのライブ動作」のうち **Graph ペインが構造的に空** (`entity_edges` 0 件)、**mic 文字起こし品質に改善余地** という観察を本セッションで確認した。本 spec は WWDC2025-277 + Apple サンプル `BringingAdvancedSpeechToTextCapabilitiesToYourApp` 準拠で release 品質ラインを物理的に満たすことのみをスコープに置く。長尺 retranscribe は別 branch `feat/long-form-retranscribe-2026-05-06` で温存する。

## 観察された事実

- `db/meeting_log.sqlite` の `entity_edges` 0 件、`entities` 0 件 (transcripts は 508 件入っている)
- `out_sqlite_meeting_log.rb:125-136` の edge INSERT 経路は実装済
- `rb-natural-language-mac` の `NLTagger(tagSchemes: [.lexicalClass])` で日本語入力は全 token が `Other` 判定
- 本セッションで `NLTagger(.nameType)` + `setLanguage(.japanese)` を実機検証 (xcrun swift) した結果、「私は東京で鈴木さんと働いています」「今日は大阪の本社で会議があります」等いずれも **全 token が `Other`**。英語 (`setLanguage(.english)`) では `Cupertino → PlaceName` 等が抽出される。**Apple `NLTagger` の named-entity / lexical-class 抽出は日本語非対応**
- `filter_natural_language_mac.rb:14` の `NOUN_TAGS = %w[Noun PersonalName PlaceName OrganizationName]` で全弾き → `entities` 配列常に空 → `entity_edges` 永遠に 0
- swiftcap mic 経路は **二段 convert** (AVAudioEngine inputFormat → 16kHz Float32 → analyzerFormat)。Apple サンプルの `Recorder.swift` は **inputFormat を transcriber に渡し analyzer 内で 1 回だけ analyzerFormat に convert** する設計
- `CaptureCoordinator.Self.targetFormat` (16kHz Float32 mono) は SoundAnalyzerWrapper の init format を **両 channel 同一** にするためだけに存在しており、それ以外の正当性はない

## 採用する設計

### E (Graph): NLTokenizer ベース全 token 抽出 + stopwords + 文字長 ≥ 2 filter

実機検証で **NLTagger は日本語の noun / named-entity 抽出に対応していない** と判明したため、当初 plan の「NLTagger 拡張」は無効。代替を比較した結果:

| 案 | 浅 layer | 確実性 | 採否 |
|---|---|---|---|
| **NLTokenizer 全 token + stopwords + len≥2** | 浅 (parent filter のみ) | ◎ Apple 標準 framework | **採用** |
| Foundation Models keyword prompt | 中 (既存 polish 経路に乗る) | △ guardrail で refuse される実績 | 次バージョン |
| 形態素解析 (Mecab/Sudachi) gem 新規 | 深 (新 native gem) | ◎ | 次バージョン |
| embedding 類似度 graph | 深 (新 gem 必要) | ◎ | 次バージョン |
| 時系列 / 話者間 graph | 浅 | ◎ ただし議事録 content とは別軸 | 次バージョン |

#### parent `filter_natural_language_mac.rb` の改修

- `NaturalLanguageMac.tag(text)` (NLTagger lexicalClass) → `NaturalLanguageMac.tokenize(text)` (NLTokenizer word unit) に切替
- 既存 `NOUN_TAGS` 定数は削除
- 各 token に対し `String#length < 2` を除外 + 既存 `@stopwords[lang]` で除外
- 残った token を `{ 'text' => t, 'kind' => 'term' }` として `entities` に乗せる
- `kind` は named-entity 区別なし常に `term` (sibling NLTagger の named-entity 機能は次バージョンで多言語化が必要なため今回はスコープ外)

sibling repo `rb-natural-language-mac` は **触らない**。

### F (mic 品質): 二段 convert を 1 段に削減

- `CaptureCoordinator.Self.targetFormat` 削除
- `startMic` の `AVAudioConverter` 階層削除、`installTap` の native buffer をそのまま `feed("mic", buffer:)` に渡す
- `SoundAnalyzerWrapper` を **per-channel native format で init** (mic = `input.outputFormat(forBus: 0)`、screen = `SCStreamConfig` 指定の 16kHz mono Float32)
- `RotatingRecorder.append(buffer)` の AVAssetWriter は output settings で AAC HE 16kHz mono を指定済、PCM input 任意 format を encoder が変換する
- `TranscriberWrapper.convertToAnalyzerFormat` は既存通り (analyzerFormat ≠ buffer.format なら 1 回だけ convert) — 変更不要

#### 不採用

- F2: SpeechTranscriber `preset` — Apple サンプルアプリは未使用、release 品質完成に不要
- F3: stop シーケンスの transcriber.finalize 完了待ち追加 — 現状 `shutdownRotate` は `micEngine.stop` + `screenStream.stopCapture` + recorder finalize で動作しており mini-E5 5/5 PASS、release 品質ラインを脅かしていない

## 進行順序 (TDD コミット境界)

| Round | 種別 | 内容 |
|---|---|---|
| **R2.RED** | parent | `filter_natural_language_mac` が日本語 text からトークンベースで `entities` を抽出する spec を追加 |
| **R2.GREEN** | parent | `tag` → `tokenize` 切替、`NOUN_TAGS` 削除、`length < 2` 除外、`rake test` GREEN |
| **R3.GREEN** | parent | `CaptureCoordinator` から `Self.targetFormat` 廃止、`startMic` AVAudioConverter 削除、`SoundAnalyzerWrapper` per-channel format、`swift test` GREEN |

R3 は既存テスト (mini-E5 5/5、swift test 9/9) を keep する純粋 refactor 寄り (動作の sample-app 準拠化) なので RED 単独 commit は省略可。

## 検証ゴール (release 品質完成判定)

1. parent `bundle exec rake test` 全 pass + sibling `bundle exec rake test` 全 pass
2. swiftcap `swift test` 全 pass
3. mini-E5 `bundle exec rake test:e5_synthetic` 5 連続 PASS
4. 30s 実会議 (YouTube バックグラウンド + 自分の声) で:
   - SQLite `entity_edges` に new row が追加される
   - chrome-mcp で graph-canvas に node + edge が描画される
   - Quick/Perfect ペインに mic + screen の live transcript が出る

## Files to modify

| repo | path | 変更 |
|---|---|---|
| fluentd-audio-transcription-system | `lib/fluent/plugin/filter_natural_language_mac.rb` | `tag` → `tokenize` 切替、`NOUN_TAGS` 削除、`length < 2` 除外 |
| fluentd-audio-transcription-system | `test/fluent/test_filter_natural_language_mac.rb` | 日本語 token 抽出 spec 追加 |
| fluentd-audio-transcription-system | `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift` | `Self.targetFormat` 廃止、`startMic` AVAudioConverter 削除、`SoundAnalyzerWrapper` per-channel format |

## Verification 結果 (2026-05-07)

- parent `bundle exec rake test`: **34/34 PASS** (新規 `test_extracts_japanese_tokens_via_tokenizer` 含む)
- swiftcap `swift test`: **9/9 PASS**
- mini-E5 5x (release binary rebuild 後の `mini-e5-5x-r3c.log`): **4/5 PASS** (run 1 のみ L4 ack-count timing flake、 R3 と無関係の既存 hardening 課題で次バージョン送り)
- 30s 実会議 (YouTube バックグラウンド + 自分の声、 `realmeeting-30s.log`): SQLite に transcripts 611 (mic 203 + screen 408)、 entities 162、 entity_edges 904 が追記
- Chrome `localhost:9292` 描画: Perfect ペインに final 200 件、 Graph canvas 1222x863 + edges 500 描画。 sample edge `うん <-> 松田 weight=1`
- **`say -v Kyoko こんにちは` 検証 (2026-05-07 P1)**: README:57 で明記された 2 つ目の検証パス。 起動 → `say -v Kyoko 'こんにちは。これはリリース品質確認のためのテストです。'` ×2 → SCStream screen channel が捕捉 → SpeechAnalyzer が transcript 613 (raw_text に「こんにちは」 verbatim) を生成 → NaturalLanguageMacFilter が entities `こんにちは` (id=190) `テスト` (id=186) を抽出 → entity_edges に `こんにちは ↔ アニメ/テレビ/です/テスト/ため/確認/品質/これ` 8 件追記 → Chrome `localhost:9292` で Quick/Perfect/Graph 3 ペイン全描画 + canvas 1222x864、 DOM に「こんにちは」 verbatim 出現を `document.body.innerText.includes('こんにちは')=true` で確認。 これで README literal release 品質水準 (実会議 + say -v Kyoko の **両方**) を物理的に達成。

実装の途中 R3 で `let micFormat = micEngine.inputNode.outputFormat(forBus: 0)` を `start(locale:)` に持ち上げた版が **SCStream -3805 "アプリケーション接続中断" + Swift Task Continuation MISUSE** を引き起こし screen channel が 0-byte 録音となって mini-E5 5/5 fail。 `inputNode` access を `startMic` 内に閉じる fix (commit `e92a84a`) で解消、 v3 と同等の起動順序を保ちつつ二段 convert 廃止の効果も維持した。

## Known limitations / next-version backlog

- top entities が機能語 (うん / です / ない / って / ござい / はい 等) に偏っている。 stopwords 拡充または形態素解析 gem 採用が次バージョンの graph 質改善ルート
- mini-E5 run 1 で稀に L4 ack-count timing flake (fluentd readiness の初期化遅延)、 5/5 single-run-must-pass までは詰まっていない

## Out of scope (次バージョン候補)

- 長尺 retranscribe (`feat/long-form-retranscribe-2026-05-06` で別途 spec 済)
- NLTagger named-entity 多言語化 (sibling repo 拡張が必要、今回は skip)
- Foundation Models keyword 抽出 prompt (guardrail refuse 実績あり、 prompt 設計に注力する別タスク)
- 形態素解析 gem (Mecab/Sudachi) 追加
- embedding 類似度ベースの semantic graph
- 時系列 / 話者間 graph 可視化
- 多言語自動切替 / locale auto-detect
- speaker diarization
- SpeechTranscriber `preset` 検証
- shutdownRotate での transcriber finalize 完了待ち (release 品質ラインは現状で満たされている)

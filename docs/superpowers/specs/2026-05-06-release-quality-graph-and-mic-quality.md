# Release-quality completion: Graph + mic-quality

Branch: `feat/release-quality-graph-and-mic-quality-2026-05-06`
Source plan: `~/.claude/plans/gentle-gathering-quilt.md`

## Context

README の release 品質ライン「Quick / Perfect / Graph 3 ペインのライブ動作」のうち **Graph ペインが構造的に空** (`entity_edges` 0 件)、**mic 文字起こし品質に改善余地** という観察を本セッションで確認した。本 spec は WWDC2025-277 + Apple サンプル `BringingAdvancedSpeechToTextCapabilitiesToYourApp` 準拠で release 品質ラインを物理的に満たすことのみをスコープに置く。長尺 retranscribe は別 branch `feat/long-form-retranscribe-2026-05-06` で温存する。

## 観察された事実

- `db/meeting_log.sqlite` の `entity_edges` 0 件、`entities` 0 件 (transcripts は 508 件入っている)
- `out_sqlite_meeting_log.rb:125-136` の edge INSERT 経路は実装済
- `rb-natural-language-mac` の `NLTagger(tagSchemes: [.lexicalClass])` で日本語入力は全 token が `OtherWord` 判定
- `filter_natural_language_mac.rb:14` の `NOUN_TAGS = %w[Noun PersonalName PlaceName OrganizationName]` で全弾き → `entities` 配列常に空 → `entity_edges` 永遠に 0
- `filter_natural_language_mac.rb:27` で `lang = record['language'] || 'ja'` を取得しているが `tag` 呼び出しに渡していない
- swiftcap mic 経路は **二段 convert** (AVAudioEngine inputFormat → 16kHz Float32 → analyzerFormat)。Apple サンプルの `Recorder.swift` は **inputFormat を transcriber に渡し analyzer 内で 1 回だけ analyzerFormat に convert** する設計
- `CaptureCoordinator.Self.targetFormat` (16kHz Float32 mono) は SoundAnalyzerWrapper の init format を **両 channel 同一** にするためだけに存在しており、それ以外の正当性はない

## 採用する設計

### E (Graph): NLTagger を `.nameTypeOrLexicalClass` + `setLanguage(.japanese)` 化

選択肢の比較:
- **E1: NLTagger 拡張** (採用) — Apple 標準フレームワークの API 切り替えのみ、互換維持可能
- E2: Foundation Models guided entity extraction — `rb-foundation-model-mac` に Generable 相当の structured output API がない、prompt + JSON parse は guardrail で refused されやすい (既存 polish 経路で 9 warn/15min 実績)、release 品質完成スコープには重い
- E3: Mecab/Sudachi 形態素解析 gem 新規追加 — sibling repo 構成が膨らむ、Apple 標準を使い切ってから検討

#### sibling repo `rb-natural-language-mac` の API 設計

- `performTag(text:, languageCode:)` に拡張、`NLTagger(tagSchemes: [.nameTypeOrLexicalClass])`、`languageCode` 非空なら `setLanguage(_:range:)`
- C ABI に `natural_language_mac_tag_lang(text, language_code)` を追加 (既存の 1 引数 `natural_language_mac_tag` も保持)
- Ruby 側で `NaturalLanguageMac.tag(text, lang = nil)` 一本化 (`lang` あれば C ABI の 2 引数版に dispatch、nil/empty なら従来 1 引数版)

#### parent `filter_natural_language_mac.rb` の改修

- `tagged = NaturalLanguageMac.tag(text)` → `tagged = NaturalLanguageMac.tag(text, lang)`

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
| **R1.RED** | sibling | 日本語入力で `Noun`/`PersonalName` 判定が返る spec を追加、`tag(text, lang)` 2 引数 API を期待 |
| **R1.GREEN** | sibling | `performTag(text:, languageCode:)` 化、C ABI 追加、Ruby `tag(text, lang = nil)`、`rake test` GREEN |
| **R2.RED** | parent | `filter_natural_language_mac` が `record['language']` を `NaturalLanguageMac.tag` の第 2 引数に渡す spec を追加 |
| **R2.GREEN** | parent | filter 1 行修正、`rake test` GREEN |
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
| rb-natural-language-mac | `ext/natural_language_mac/Sources/NaturalLanguageMac/NaturalLanguageMac.swift` | `performTag` 拡張 |
| rb-natural-language-mac | `ext/natural_language_mac/Sources/NaturalLanguageMac/NaturalLanguageMacBridge.swift` | C ABI に `natural_language_mac_tag_lang` 追加 |
| rb-natural-language-mac | `ext/natural_language_mac/natural_language_mac.c` | `tag` を arity -1 化 (1〜2 引数) |
| rb-natural-language-mac | `test/natural_language_mac/nlp_test.rb` | 日本語 noun spec 追加 |
| fluentd-audio-transcription-system | `lib/fluent/plugin/filter_natural_language_mac.rb` | `tag(text, lang)` 呼び出し |
| fluentd-audio-transcription-system | `test/fluent/test_filter_natural_language_mac.rb` (新規) | filter spec |
| fluentd-audio-transcription-system | `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift` | `Self.targetFormat` 廃止、`startMic` AVAudioConverter 削除、`SoundAnalyzerWrapper` per-channel format |

## Out of scope (次バージョン候補)

- 長尺 retranscribe (`feat/long-form-retranscribe-2026-05-06` で別途 spec 済)
- E2 / E3 (上記比較で却下)
- 多言語自動切替 / locale auto-detect
- speaker diarization
- SpeechTranscriber `preset` 検証
- shutdownRotate での transcriber finalize 完了待ち (release 品質ラインは現状で満たされている)

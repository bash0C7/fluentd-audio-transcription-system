# Next-version backlog

Branch この spec が指す対象: **次バージョン候補のうちどれを採用するかは別途 design check の上で決定**。 個別実装に入る前に、必ず本 spec 冒頭の必達条件を読み直すこと。

## 必達条件 (絶対必須・後退禁止)

**README に記載されている release 品質水準を後退させる変更は禁止する。**

README が定義する release 品質水準は明確で 1 行しかない:

> 「Quick / Perfect / Graph の 3 カラムが現れる。実会議や `say -v Kyoko こんにちは` で動作確認。」 (`README.md:57`)

これを物理的に満たした最後の動作確認は 2026-05-07 の `feat/release-quality-graph-and-mic-quality-2026-05-06` ブランチ (merge commit `2288d42`)。 verify 結果は `docs/superpowers/specs/2026-05-06-release-quality-graph-and-mic-quality.md` の "Verification 結果" セクションに記録済み。

次バージョンの **どの作業を採用する場合でも**、 着手前と完了前にこの必達条件チェックを実施すること:

1. **着手前 (実装方針確定時)**:
   - 提案する変更が Quick / Perfect / Graph 3 ペインのどれかを **データが流れない** 状態に陥らせる経路を作っていないか
   - SCStream / AVAudioEngine / SpeechAnalyzer / fluentd / SQLite / WebSocket / PicoRuby のいずれの layer にも regression を作らないか
2. **完了前 (merge 直前)**:
   - parent `bundle exec rake test` 全 PASS
   - swiftcap `swift test` 全 PASS
   - mini-E5 `bundle exec rake test:e5_synthetic` を 5 連続実行し最低 4/5 PASS (前バージョンと同等以上)
   - 30s 実会議 (YouTube バックグラウンド + 自分の声) で `localhost:9292` の Graph canvas に node + edge が描画され、 Quick/Perfect ペインが空でない
   - SQLite で `SELECT COUNT(*) FROM entity_edges` が前バージョン水準以上

**これらが 1 つでも満たされない変更は merge しない。** release 品質水準への後退は次バージョンとしてもバグであり、 即 revert する。

## 残課題一覧 (採用判断は個別 spec で実施)

### A. Graph 質改善 (release 品質強化方向)

現状 top entities が機能語に偏る (うん / です / ない / って / ござい / はい / ちょっと 等)。 entity_edges 904 件は出ているので release 品質ラインは満たしているが、 視覚情報量は低い。

| 案 | 浅 layer | 確実性 | 必達条件への影響 |
|---|---|---|---|
| **A1: stopwords 拡充** (`config/stopwords.yml` に機能語追加) | 浅 (config のみ) | ◎ | release 品質維持、 ノイズ削減のみ |
| **A2: 形態素解析 gem (Mecab/Sudachi) 新規追加** | 深 (新 native gem) | ◎ | sibling 構成膨張、 NLTokenizer リプレース時に必達条件チェック必須 |
| **A3: Foundation Models keyword 抽出 prompt** | 中 (既存 polish 経路に乗る) | △ guardrail で refuse 9/15min 実績 | refuse 多発で entities 0 に退化する risk → 必達条件への regression risk あり |
| **A4: embedding 類似度 graph** | 深 (新 gem) | ◎ | 既存 entities 経路を残したまま追加なら必達条件維持可 |

最浅で release 品質強化方向は **A1**。 採用は個別 spec で。

### B. mini-E5 single-run-must-pass まで詰める

現状 mini-E5 5 連続実行で run 1 のみ稀に L4 ack-count timing flake (fluentd readiness の初期化遅延)。 release 品質ライン (3 ペイン動作) 自体は脅かしていないが、 必達条件チェック (5 連続最低 4/5 PASS) のマージンを削ぐ。

- B1: fluentd ready 検知を ack.jsonl の最初の出現で代替
- B2: startup 順序を fluentd → swiftcap (現状逆順) に入れ替える
- B3: mini-E5 の `start_at` baseline を「fluentd worker is now running」 ログ出現後に固定

### C. mic 品質さらなる改善

R3 で二段 convert を廃止し native pass-through に変更済。 ただし mini-E5 fixture (13.27s 音声 × 30s window) では mic delta>0 が 5 run 中 1 run のみ観測。 短い fixture では SpeechTranscriber の language confidence が dominate するため measurable な改善は見えない。 実会議 (30s+) では mic 203 件出ており release 品質達成。 さらなる改善候補:

- C1: SpeechTranscriber の `transcriptionOptions` / `reportingOptions` の WWDC 線にあるフラグを実機で検証 (`.priorWords` 等)
- C2: shutdownRotate での `transcribers[ch]?.finalize()` 完了待ち追加 (現状 `await transcriber.finalize()` を await していないため shutdown 直前 1-2 句が最終化されない可能性)
- C3: SpeechTranscriber `preset` API (Apple サンプル app は未使用、 Apple ドキュメントに記載のみ)

### D. sibling repo 機能拡張

`rb-natural-language-mac` の NLTagger は named-entity 抽出が **英語に対しては機能** する (`Cupertino → PlaceName` 検証済)。 多言語切替の枠組みを sibling 側で持たせれば parent filter から `lang` 別 dispatch が可能。

- D1: `tag(text, lang)` 2 引数 API を sibling に追加し `.nameType` schema で named entity を返す。 日本語入力では空配列、 英語入力では PlaceName/PersonalName/OrganizationName を返す
- D2: parent filter で `lang.start_with?('en')` の場合のみ D1 を活用、 日本語は現行 NLTokenizer 経路維持

### E. semantic / temporal graph layers

A1-A4 で entity 抽出を改善した上で、 graph の意味付けを多軸化する候補:

- E1: 時系列 graph (発言の時系列フロー、 連続する発言を edge で連結)
- E2: 話者間 graph (mic ↔ screen の対話構造、 「自分の声と youtube 内容の連動」 を可視化)
- E3: 音響特徴 graph (`sound.jsonl` の SNClassificationResult を node 化、 Speech / Music / Laughter 遷移)

### F. 長尺 retranscribe (post-meeting full-pass)

別 branch `feat/long-form-retranscribe-2026-05-06` で spec のみ commit 済 (`6e98496`)。 ライブ動作とは独立した post-processing path。

### G. その他

- G1: 多言語自動切替 / locale auto-detect (現状 `SWIFTCAP_LOCALE=ja-JP` 固定)
- G2: speaker diarization
- G3: LaunchAgent plist 化 (README は「マニュアル起動」 と但書済、 必須でない)

## 進め方

- 各候補は **1 候補 1 spec** で個別ファイルに切り出し、 採用前に **必達条件チェック** (本 spec 冒頭) を実施
- 複数候補をまとめて実装するブランチは禁止 (regression の原因切り分けが不能になる)
- spec ファイル名は `docs/superpowers/specs/<YYYY-MM-DD>-<scope>.md` で日付プレフィクスを付ける

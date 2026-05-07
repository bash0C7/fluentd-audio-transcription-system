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

## 完了済 (2026-05-07 時点)

| 項目 | コミット / spec | 効果 |
|---|---|---|
| **P1: README literal release 品質水準** (`say -v Kyoko こんにちは` で 3 ペイン live + transcript + entities + edges) | `e52eff0`、 `2026-05-06-release-quality-graph-and-mic-quality.md` "Verification 結果" | README 2 つ目の検証パスを物理達成、 必達条件 baseline 確立 |
| **A1: stopwords 拡充** (機能語 16 語追加 + BCP-47 locale 正規化 + UTF-8 encoding tag) | merge `5898517`、 `2026-05-07-a1-stopwords-expansion.md` | Graph perceived quality 向上 (機能語 leak 0 件)、 隠れ encoding bug 2 件解消 |
| **B (P2): mini-E5 single-run-must-pass** | `23c6a60` (deferred-policy 記録)、 § B 参照 | baseline 計測 5/5 PASS、 B1/B2/B3 実装不要 |
| **Graph キャプション human-readable 化** (SpriteText 常時表示 + nodeLabel hover、 frontend のみ) | `c57a54f` | 「描画されとるけど判別不可能」 状態を解消、 ノードラベル (日本語 entity 文字列) が常時可視 |

## 残課題一覧 (採用判断は個別 spec で実施)

### A. Graph 質改善 (release 品質強化方向)

A1 完了後の現状: 機能語 leak 0、 content 中心の entities。 さらに Graph 表現力を上げたい場合の候補:

| 案 | 浅 layer | 確実性 | 必達条件への影響 |
|---|---|---|---|
| ~~**A1: stopwords 拡充**~~ ✅ done (`5898517`) | 浅 (config のみ) | ◎ | release 品質維持、 機能語 leak 0 件達成 |
| **A2: 形態素解析 gem (Mecab/Sudachi) 新規追加** | 深 (新 native gem) | ◎ | sibling 構成膨張、 NLTokenizer リプレース時に必達条件チェック必須 |
| **A3: Foundation Models keyword 抽出 prompt** | 中 (既存 polish 経路に乗る) | △ guardrail で refuse 9/15min 実績 | refuse 多発で entities 0 に退化する risk → 必達条件への regression risk あり |
| **A4: embedding 類似度 graph** | 深 (新 gem) | ◎ | 既存 entities 経路を残したまま追加なら必達条件維持可 |

A1 完了で機能語ノイズは解消したので、 これ以上の Graph 強化は **investment-effect 薄**。 観察対象: 実会議 30 分以上の連続稼働で content entities の頻度分布が長尾になるか。 偏りが残るなら A2 (形態素) > A4 (embedding) > A3 (FM) の優先で個別 spec 切り出し。

### B. mini-E5 single-run-must-pass まで詰める ✅ verified 5/5 (2026-05-07)

> **Status: 既達成**。 P2 として個別 spec 切り出し前の baseline 計測で **5 連続 PASS** を確認、 候補 B1/B2/B3 いずれも実装不要。

直近の release-quality completion 系 commit (R3 mic 二段 convert 廃止 + scope cleanup) を merge した後の baseline 計測 (`tmp/longrun/mini-e5-p2-baseline.log`):

```
run 1 mini-E5 PASS — all 5 layers verified
run 2 mini-E5 PASS — all 5 layers verified
run 3 mini-E5 PASS — all 5 layers verified
run 4 mini-E5 PASS — all 5 layers verified
run 5 mini-E5 PASS — all 5 layers verified
```

旧来 r3c run で観測した L4 `ack count 61 != rotated count 2` flake は再現せず。 pos 整備状態 + R3 後の swiftcap 起動安定性の組み合わせで自然解消したと判断。 候補 B1-B3 は 「実装したらより堅牢」 ではあるが現状で release 品質ラインの margin (5/5) を超えており、 投資効果薄。 **再 flake 観測されたら個別 spec で着手** という deferred policy。

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

## 推奨される次の一手 (優先順)

P1/A1/B 完了後の view からみた次のテーマ。 全て個別 spec 必須:

1. **C2: shutdown finalize 待ち** — 浅 (1 await 追加)、 mic 品質が確率事象から確定事象になる、 必達条件 regression risk 低
2. **F: 長尺 retranscribe** — `feat/long-form-retranscribe-2026-05-06` に spec 1 commit 済 (`6e98496`)、 ライブと独立 path なので必達条件への risk なし
3. **D1+D2: 英語入力 named entity** — sibling NLTagger `.nameType` で実機検証済 (Cupertino → PlaceName)、 日本語経路は touch せず追加できる
4. **E1: 時系列 graph edge** — A1 で content 中心になった entities を時系列で連結、 graph 情報量を「いつ何が出たか」 へ拡張
5. **G1: locale auto-detect** — 多言語入力の現実的需要、 BCP-47 経路は A1 で正規化済なので config 拡張のみで済む可能性

下位 (現状投資効果薄):
- A2/A3/A4 (機能語 leak 0 件達成済、 form factor 改善は user feedback 待ち)
- C1/C3 (WWDC 線上の API、 release 品質には未到達 layer)
- E2/E3 (graph 多軸化、 まず E1 で時系列軸を入れる方が効果大)
- G2 (speaker diarization、 実装コスト高)
- G3 (LaunchAgent plist、 README で「マニュアル起動」 と但書済、 必須でない)

## 進め方

- 各候補は **1 候補 1 spec** で個別ファイルに切り出し、 採用前に **必達条件チェック** (本 spec 冒頭) を実施
- 複数候補をまとめて実装するブランチは禁止 (regression の原因切り分けが不能になる)
- spec ファイル名は `docs/superpowers/specs/<YYYY-MM-DD>-<scope>.md` で日付プレフィクスを付ける

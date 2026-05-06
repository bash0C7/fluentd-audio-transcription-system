# A1: Stopwords expansion (Graph perceived quality)

Source backlog: `docs/superpowers/specs/2026-05-07-next-version-backlog.md` § A1。
README literal release 品質水準 (3 ペイン live + 実会議 / `say -v Kyoko こんにちは` 双方検証済) を **後退させずに** Graph ペインの perceived quality を上げる。

## 必達条件チェック (本 spec 着手前)

- [x] 親 backlog spec の 必達条件 (3 ペイン live、 ack flow、 entity_edges 出現) を読み直した
- [x] 本変更は **config/stopwords.yml の拡張のみ** で entity 経路 (NLTokenizer + length≥2 + stopwords filter) には触らない → SCStream / AVAudioEngine / SpeechAnalyzer / fluentd / SQLite / WebSocket / PicoRuby のいずれにも regression を作らない
- [x] entity_edges 数の前バージョン水準維持確認は完了前に SQL 比較する

## Context

リリース品質完成 commit (`2288d42`) 後の実会議 + `say -v Kyoko` で観測した entities top 40 は機能語が dominate:

| 順位 | text | cnt | 種別 |
|---|---|---|---|
| 1 | うん | 21 | 既 stopword (filtered) |
| 2 | です | 15 | **未 stopword** (filler 助動詞) |
| 3 | はい | 9 | 既 stopword |
| 4 | ちょっと | 8 | **未 stopword** (filler) |
| 5 | ます | 8 | **未 stopword** (助動詞語尾) |
| 6 | ない | 7 | **未 stopword** (否定助動詞) |
| 7 | これ | 5 | 既 stopword |
| 8 | ござい | 5 | **未 stopword** (助動詞断片) |
| 9 | バー | 5 | content (keep) |
| 10 | 時間 | 5 | content (keep) |
| 11 | って | 4 | **未 stopword** (引用助詞) |
| ... |
| 14 | ありがとう | 3 | content (keep — 意味あり) |
| 15 | いう | 3 | **未 stopword** (「という」 断片) |
| 16 | けど | 3 | **未 stopword** (接続助詞) |
| 17 | じゃ | 3 | **未 stopword** (「では」 縮約) |

機能語は graph の node を埋めるだけで edge の意味量を希釈する。 stopword 拡張で除去すれば release 品質ライン (3 ペインに「Graph」 が描画) は維持しつつ、 描画される node が content 中心になる。

## 採用する設計

### config/stopwords.yml `ja:` セクションに追記する語

機能語 / filler / 助動詞断片に絞る。 content word (説明 / 時間 / バー / さん / 早く / 本当 / 行っ / 思っ etc.) は **絶対に削らない**。

追加候補:

- **助動詞 / 助動詞断片**: です / ます / ない / ござい / てる / でき
- **filler / 接続詞**: ちょっと / って / けど / じゃ / いう / だけ / もう / まあ / ほんと / なるほど (← 内容語近いが filler)
- **存在動詞 (graph 上意味薄)**: ある / いる
- **疑問副詞**: どう (← 文脈次第で content だが top 40 では filler 文脈)

合計 16 語追加。

### スコープ外 (judgement call で keep)

- とりあえず → adverb で content っぽい
- 行っ / 思っ / 言っ / 出 etc. → 動詞語幹 / 連用形、 graph 上 content 寄与あり
- 早く / 本当 / 説明 / ありがとう / 時間 / バー / さん / 松田 / 議事 etc. → content そのもの

### 不採用候補

- でき → 「できた」 等 content 寄りに使われる場合あり、 stopword は過剰
- とりあえず → adverb、 content として残す

## TDD 進行

| Round | 種別 | 内容 |
|---|---|---|
| RED-A | test | `test/fluent/test_filter_natural_language_mac.rb` に **production `config/stopwords.yml` を直接 load** する spec を追加し、 機能語が drop される + content word は残ることを assert |
| GREEN-A | config | `config/stopwords.yml` の `ja:` セクションに 16 語追加 |
| RED-B | test | `language='ja-JP'` (BCP-47 locale) で同等動作を assert する spec 追加 |
| GREEN-B | filter (1 行) | `filter_natural_language_mac.rb` で `lang.split('-').first.downcase` 正規化 |

### Scope 拡張 (Round B)

実装中に発見: 実環境 swiftcap は `language='ja-JP'` を emit、 filter は `@stopwords[lang]` で lookup → `ja-JP` key 不在で **全 stopword が miss、 ja stopwords 0 件適用** という pre-existing bug。 Round A 単独では release 品質水準への寄与 0 (config 増やしても lookup miss)。 Round B で 1 行 normalize 追加し scope 拡張。 Filter 経路 (entry point 1 line) のみ touch、 SCStream / AVAudioEngine / SpeechAnalyzer / fluentd / SQLite / WebSocket / PicoRuby いずれにも regression 経路なし。

### Scope 拡張 (Round C: encoding bug)

Round B 適用後の実環境 verification で **stopwords が依然 0 件 filter** していると判明。 fluentd diagnostic instrumentation (token 級の log 追加) で発覚した真因:

- fluentd の起動コマンドラインに `-Eascii-8bit:ascii-8bit` 含まれる (`ps -ef | grep fluentd` 確認、 `bundle exec fluentd` の bootstrap が付加)
- この startup 状態で `YAML.load_file` は **strings を ASCII-8BIT tagged で返す**
- `Set#include?` は encoding-aware なので、 ASCII-8BIT の `'けど'` ≠ UTF-8 の `'けど'` (バイト一致でも encoding 違いで false 判定)
- `NaturalLanguageMac.tokenize` 由来の token は UTF-8 tagged
- 結果: `@stopwords['ja'].include?(token)` 永遠に false → 全 token 通過

unit test 環境 (`bundle exec ruby` default UTF-8) では再現しないため pre-existing で気づかれなかった。

#### Fix

`configure` 内の `YAML.load_file(@stopwords_path)` を `YAML.safe_load(File.read(@stopwords_path, encoding: 'UTF-8'))` に置換。 host process の `-E` flag に依存せず常に UTF-8 で stopwords を保持。

R は config + 1 行 refactor 寄りなので 別 REFACTOR commit はスキップ可。

## Files to modify

| path | 変更 |
|---|---|
| `test/fluent/test_filter_natural_language_mac.rb` | production stopwords.yml load + ja-JP locale spec |
| `config/stopwords.yml` | ja: に 16 語追加 |
| `lib/fluent/plugin/filter_natural_language_mac.rb` | language code 正規化 1 行 (`.split('-').first.downcase`) + UTF-8 explicit YAML 読み込み |

## 検証ゴール (完了前必達条件チェック)

1. parent `bundle exec rake test` 全 PASS (新 spec 含む)
2. swiftcap `swift test` 全 PASS (touch しないので変わらず)
3. mini-E5 5 連続 ≥ 4/5 PASS (config の YAML 1 階層追加なので readiness 影響は無い想定)
4. 30s 実会議 + `say -v Kyoko` で:
   - SQLite `SELECT COUNT(*) FROM entity_edges` が前バージョン水準以上 (機能語は edges に乗らんようになるが content edge は残る; むしろ noise 減で query 質改善)
   - top entities から 「うん / です / ます / ない / ござい / ちょっと / って」 が消えて content 中心になる
   - localhost:9292 Graph canvas に node + edge 描画 (3 ペイン live keep)

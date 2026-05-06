# Observations Index

実装中に得られた「設計時には未知だった事実・現実の挙動・発見した不具合の根本
原因」を時系列で並べた索引。仕様 (`../specs/`) や実装計画 (`../plans/`) では
なく、**実機を回した結果わかったこと** を残す場所。

新規 observation を書いたらこのファイルに 1 行追加すること。古い entry の
場所は移動しない（履歴を壊さないため）。

---

## 2026-05

| date | title | summary | source |
|------|-------|---------|--------|
| 2026-05-06 | E5 core feature reverify | 15 分実会議 + YouTube 流しっぱなし E2E。capture 経路は健全、Web 表示層に PicoRuby:wasm bridge 起因の 3 defect (three.js 二重 load / fetch block 形 / message handler property 直接アクセス) を発見・修正。Graph 復活 + live WS E2E test 追加で release 品質達成。 | [2026-05-06-e5-reverify.md](2026-05-06-e5-reverify.md) |
| 2026-05-06 | F3 closed by F4 (mini-E5 dupe ack 真因) | mini-E5 で観測された ack.jsonl の dupe entry は plugin idempotency の問題ではなく、F4 の graceful PID-stop 不在で smoke 起動 fluentd が新規 fluentd と並列で同一 state.jsonl を tail していた歴史的残骸。F4 fix 後 8 rotation : 8 ack の 1:1 を確認し F3 closed。 | [../specs/2026-05-06-core-fixes-from-e5.md](../specs/2026-05-06-core-fixes-from-e5.md#観察結果2026-05-06f4-fix-後) |

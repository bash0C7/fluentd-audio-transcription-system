# 2026-05-07 Web-controlled session boundary + rollover + mute

> 既存の swiftcap ライブ経路 (volatile + final via SpeechAnalyzer) は
> 「launch から shutdown まで常時 capture」 のモデル。これを
> **web から MTG 単位で制御** できるように拡張する。
>
> 動機: 常時収録は文字起こし量が膨大で MTG 単位での見直し・retranscribe
> 起動が困難。一方スポット収録は録り逃しが起きやすい。両者の
> 「いいところどり」 として「launch 時に即 recording、 user が web から
> "区切る" を打つたび session が rollover、 区切られた session の CAF
> 群を長尺 SpeechAnalyzer に投入して post-hoc 高精度 transcript を得る」
> モデルを採る。
>
> あわせて mic ミュート toggle (Zoom 風、 同 session 内で mic ch だけ
> on/off) を web に置く。
>
> スコープ: web → swiftcap 制御プロトコル、 session lifecycle 管理、
> 長尺転写 kickoff の責任分担、 必要 schema 追加。 別 branch
> `feat/long-form-retranscribe-2026-05-06` の F spec
> (`2026-05-06-long-form-retranscribe.md`) はこの spec に subset として
> 取り込まれる (audio_segment 単位 retranscribe は Phase 2 別 spec で
> 復活させる前提)。

---

## 必達 (絶対必須・後退禁止)

backlog `2026-05-07-next-version-backlog.md` の必達条件をそのまま継承:

- README "Quick / Perfect / Graph 3 ペインのライブ動作" を **壊さない**
- `bundle exec rake test` / `swift test` 全 PASS 維持
- `bundle exec rake test:e5_synthetic` 5 連続実行 ≥ 4/5 PASS
- 30s 実会議で 3 ペインに live data + Graph に node + edge
- `SELECT COUNT(*) FROM entity_edges` 前バージョン水準以上
- 既存 SQLite schema を破壊的変更しない (column / index 追加のみ可)

**特に**: default state を `recording` にすることで、 「launch して何も
触らずとも live 3 ペインが流れる」 既存動作は維持される。 web の
session control bar は加飾、 既存 capture 経路を壊さない。

---

## 採用した設計選択 (brainstorming で確定)

| 軸 | 選択 | 不採用案 |
|---|---|---|
| Session lifecycle | **β rollover** (区切り = 現 session finalize + 即 N+1 開始) | α ハードカット (idle 復帰)、 γ ハイブリッド |
| Launch 直後 | **recording (auto session 1)** | idle 待ち |
| Mute semantics | **mic ch のみ止める (Zoom 風)、 session 維持** | 両 ch 止める、 表示だけ止める |
| 長尺転写の入力単位 | **β analyzer 共用 sequential** (1 instance に複数 AVAudioFile を analyzeSequence で連投) | α 連結 1 本 (merge step 必要)、 γ 1 本ずつ独立 (文脈保持なし) |
| Web → swiftcap 制御プロトコル | **α spool/control.jsonl + FSEvents** | β HTTP listen、 γ Unix socket、 δ signal、 ε 再起動 |
| 長尺転写 kickoff 責任 | **δ web (Sinatra) が swiftcap retranscribe を spawn** | α swiftcap 自身が子 spawn、 β swiftcap inline async、 γ fluentd out_exec |

---

## 詳細設計

### 1. State machine

```
[launch]
  ↓ swiftcap 起動: sessions に新 row INSERT (started_at=now, ended_at=NULL, status='active')
  ↓ swiftcap.current_session_id = N
  ↓ AVAudioEngine + SpeechTranscriber + SoundAnalyzer 既存通り起動
[recording]  ← default
  ├ control.jsonl から {kind:"boundary"} 検知:
  │   1. RotatingRecorder.finalize() で現 CAF close (既存 rotate と同じ手順)
  │   2. spool/state.jsonl append {kind:"session_finalized", session_id:N, ended_at:now}
  │   3. fluentd → out_sqlite が sessions.ended_at + status='finalized' を update
  │   4. swiftcap が sessions に新 row INSERT 相当の state event を出す
  │      ({kind:"session_started", session_id:N+1, started_at:now})
  │   5. current_session_id = N+1
  │   6. 同じ rotation 動作で session N+1 の CAF を書き始める
  │   → mute 状態は持ち越す (toggle されとらん限り変えない)
  └ control.jsonl から {kind:"mute_toggle"} 検知:
      - mic 入力 tap を on ⇄ off
      - 実装: AVAudioEngine の mic input node に対する installTap/removeTap
        (engine 自体は止めない、 screen ch は影響なし)
      - SpeechTranscriber mic ch / SoundAnalyzer mic ch は無音 buffer を受ける
        (mute 中は events 出ない)
      → 状態: muted ⇄ recording (session_id 不変)
```

### 2. Control plane (spool/control.jsonl)

**Format** (JSONL、 web append-only、 swiftcap が tail):

```jsonl
{"ts":1715xxxxx.xxx, "kind":"boundary"}
{"ts":1715xxxxx.xxx, "kind":"mute_toggle"}
```

**swiftcap 側読み取り**:
- 起動時に `tmp/swiftcap_control.pos` から byte offset を読む (なければ
  `control.jsonl` の末尾 = 起動より前の event は無視)
- FSEvents で `spool/control.jsonl` の write を検知、 offset から
  新規行を JSONDecoder で 1 件ずつ読み、 処理後に offset 永続化
- 処理は serial (同時に複数 event 来ても 1 個ずつ消化)

**swiftcap 出力** (state.jsonl):
- 既存の `state.jsonl` に新 kind 追加: `session_started`, `session_finalized`,
  `mute_changed`, `retranscribe_done`
- 既存 fluentd `filter_audio_state` が pass-through できるように
  schema 拡張は spec 末尾の "schema delta" 参照

**web 側書き込み**:
- Sinatra route `POST /api/session/boundary` / `POST /api/session/mute`
  が `control.jsonl` に append
- file lock 不要 (append + JSONL は POSIX 上 atomic を期待)

### 3. 長尺転写 (swiftcap retranscribe subcommand)

新規ファイル: `swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift`
変更: `Swiftcap.swift` の main で arg dispatch (F spec の構造を流用)

```
swiftcap retranscribe \
  --session-id <int>   \   // 必須、 sessions.id
  --locale <bcp47>     \   // 既定 ja-JP (環境変数 SWIFTCAP_LOCALE で上書き)
  --pass <int>             // 既定 2
```

処理フロー:

```swift
1. SQLite から sessions[N] と紐づく audio_segments 全件取得
   (WHERE session_id = N ORDER BY started_at ASC)
2. 各 audio_segments.blob を tmp ディレクトリに展開 (CAF として AVAudioFile で開ける形)
3. SpeechTranscriber(locale, options=[.audioTimeRange]) を init
   (volatileResults 不要、 final だけ)
4. SpeechAnalyzer(modules:[transcriber]) を 1 個作る
5. async let result = transcriber.results.reduce(...) でアセンブル
6. for caf in cafs { try await analyzer.analyzeSequence(from: caf) }
7. await analyzer.finalizeAndFinishThroughEndOfInput()
8. 各 result を spool/final.jsonl に append:
     {kind:"final", text, started_at, ended_at, language,
      session_id:N, audio_segment_id:<primary overlap>, pass:2}
9. spool/state.jsonl append {kind:"retranscribe_done", session_id:N}
10. tmp の CAF 展開を削除 (cleanup)
```

実装ポイント:
- `analyzer.analyzeSequence(from:)` を 1 instance に複数回呼ぶことで、
  Apple WWDC2025-277 が想定する long-form context 共有が効く
- transcripts row 単位は **SpeechTranscriber が返す result 1 個 = 1 row**
  (live 経路と同じ粒度)。 session 全体を 1 row に集約はしない (UI で
  細分された行を上書き表示するため、 既存 Perfect ペインの DOM
  パターンを流用)
- audio_segment_id は result の `audioTimeRange.start` を
  audio_segments の `started_at/ended_at` 範囲と突き合わせて 1 件に解決
  (Swift 側で SQL `WHERE session_id=N AND started_at <= ts < ended_at`
  を 1 回引く。 fluentd 側の filter_audio_state を再実装はしない)
- pass=2 row は live pass=1 row と同 audio_segment を指す別 row として
  共存 (out_sqlite_meeting_log で UPDATE せず INSERT)

### 4. Web (Sinatra) 拡張

#### 4-1. 制御 route

```ruby
post '/api/session/boundary' do
  File.open(File.join(spool_dir, 'control.jsonl'), 'a') do |f|
    f.write({ts: Time.now.to_f, kind: 'boundary'}.to_json + "\n")
  end
  status 202
  { status: 'queued' }.to_json
end

post '/api/session/mute' do
  File.open(File.join(spool_dir, 'control.jsonl'), 'a') do |f|
    f.write({ts: Time.now.to_f, kind: 'mute_toggle'}.to_json + "\n")
  end
  status 202
  { status: 'queued' }.to_json
end
```

#### 4-2. 状態取得 route

```ruby
get '/api/session/current' do
  # 直近 active session を返す
  row = db.get_first_row(<<~SQL)
    SELECT id, started_at, status FROM sessions
    WHERE status='active' ORDER BY started_at DESC LIMIT 1
  SQL
  content_type :json
  row.to_json
end

get '/api/session/recent' do
  # 直近 N 件 (ヘッダの 「転写中 / 完了」 バッジ用)
  rows = db.execute(<<~SQL, [10])
    SELECT id, started_at, ended_at, status FROM sessions
    ORDER BY started_at DESC LIMIT ?
  SQL
  content_type :json
  rows.to_json
end
```

#### 4-3. 転写 worker (Sinatra app に同居する Thread)

```ruby
Thread.new do
  loop do
    finalized = db.execute(<<~SQL)
      SELECT id FROM sessions WHERE status='finalized'
      ORDER BY ended_at ASC LIMIT 1
    SQL
    if finalized.empty?
      sleep 5
      next
    end
    sid = finalized[0]['id']
    pidfile = File.join(repo_root, 'tmp/run', "retranscribe-#{sid}.pid")
    next if File.exist?(pidfile) && pid_alive?(pidfile)

    db.execute('UPDATE sessions SET status=? WHERE id=?', ['transcribing', sid])
    pid = Process.spawn('swiftcap', 'retranscribe', '--session-id', sid.to_s,
                        out: STDOUT, err: STDERR)
    File.write(pidfile, pid.to_s)
    Process.detach(pid)
    # status='done' は state.jsonl の retranscribe_done を fluentd 経由で受けて update
    sleep 1
  end
end
```

(F spec の pidfile pattern 流用)

#### 4-4. UI 増分

`web/views/index.erb` のヘッダに session control bar を追加:

```html
<header class="session-bar">
  <span class="session-id">Session #<%= current_session_id %></span>
  <span class="started">開始 <%= started_at_local %></span>
  <span class="rec-state" id="rec-state">●REC</span>
  <button id="boundary-btn">区切る</button>
  <button id="mute-btn">🎤 ミュート</button>
  <span class="recent-sessions" id="recent-sessions">
    <!-- WebSocket push で更新: 「#42 ⏳ 転写中」 / 「#41 ✅」 -->
  </span>
</header>
```

PicoRuby:wasm 側 (`web/assets/app.rb`) に:
- 区切るボタン → `fetch('/api/session/boundary', {method:'POST'})`
- ミュートボタン → `fetch('/api/session/mute', {method:'POST'})` + 自身の見た目 toggle (確定は state.jsonl 由来の WebSocket push を待つ)
- WebSocket message kind に `session_started`, `session_finalized`,
  `mute_changed`, `retranscribe_done` を分岐させ、 ヘッダ要素を更新

Quick / Perfect / Graph ペインの挙動は **本 spec では変えない**。
境界で clear せず、 そのまま流れ続ける。 「ペイン UX 再設計」 は
別 spec ((3) Quick UI 再設計、 backlog 項目化済) で扱う。

---

## DB schema delta

新 migration: `migrations/20260507000000_session_control.sql`

```sql
-- 1. sessions に status 追加
ALTER TABLE sessions ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
  -- 'active'       recording 中 (区切られとらん)
  -- 'finalized'    区切られた、 retranscribe 待機
  -- 'transcribing' retranscribe 走行中
  -- 'done'         retranscribe 完了

CREATE INDEX idx_sessions_status ON sessions(status);

-- 2. audio_segments に session_id FK 追加 (現状ない)
ALTER TABLE audio_segments ADD COLUMN session_id INTEGER REFERENCES sessions(id);
CREATE INDEX idx_audio_segments_session ON audio_segments(session_id);

-- 3. transcripts に pass 追加 (F spec から流用)
ALTER TABLE transcripts ADD COLUMN pass INTEGER NOT NULL DEFAULT 1;
  -- 1 = live SpeechAnalyzer 経路
  -- 2 = post-hoc retranscribe 経路
```

`_sqlite_mcp_meta` の sessions 説明文も update:

```sql
UPDATE _sqlite_mcp_meta SET value =
  '会議単位（web から user-trigger で区切り）。 status は active/finalized/transcribing/done。 FM 生成の title/summary 保持。'
WHERE key = 'table:sessions';

INSERT OR REPLACE INTO _sqlite_mcp_meta(key, value) VALUES
  ('column:transcripts.pass',
   '1=live SpeechAnalyzer、 2=post-hoc 長尺 retranscribe。 同 audio_segment_id × pass 違いは別 row として残す。');
```

---

## 失敗 / 復旧 semantics

| 障害 | 挙動 / 復旧 |
|---|---|
| swiftcap 起動時、 status='active' な前回 session が残っとる | 起動時に `UPDATE sessions SET status='finalized', ended_at=COALESCE(ended_at, now)` で巻き取り。 関連 CAF があれば worker が retranscribe queue に拾う。 CAF 0 件なら status='done' に直接 set |
| swiftcap 再起動中に web から control.jsonl への append | `tmp/swiftcap_control.pos` の保存 offset から再開、 取り逃しなし |
| 転写 worker が起動済 session を再 spawn しそうになる | pidfile + `pid_alive?` チェック、 alive なら skip |
| swiftcap retranscribe crash | spool/state.jsonl に retranscribe_done が出てない → 一定時間 (Phase 2 で 30 分 timeout) 後に worker が status='finalized' に巻き戻し、 再 queue。 Phase 1 では pidfile 残骸を手動削除 |
| 区切り済 session に新規 final.jsonl pass=1 が来る | swiftcap rotation は session 単位で止まるので発生しない (RotatingRecorder.finalize 後、 新 session の CAF に切り替わる) |
| web crash | session control bar が見えんくなるだけ。 swiftcap は capture 続行、 control.jsonl に書き込めんので boundary/mute は受け付けられない (web 復旧後再開) |
| user が連打 (boundary 連続 push) | control.jsonl に複数 row、 swiftcap が serial 消化、 ただし RotatingRecorder.finalize の所要時間 (~数十 ms) より速い連打は事実上 1 回扱い (空の session が間に挟まる) |

---

## RED-GREEN 順序

各 step で RED commit / GREEN commit を分ける (CLAUDE.md TDD コミット境界規律)。

1. **schema migration** ── pass / audio_segments.session_id / sessions.status 列の RED migrator test (idempotent migration、 既存 row への DEFAULT 適用、 既存 indexes 影響なし)
2. **swiftcap control.jsonl reader** ── unit test (fixture control.jsonl を渡して boundary / mute_toggle event が parse される、 offset 永続化)
3. **swiftcap mute toggle (mic only)** ── unit test (AVAudioEngine の mic input tap が installTap/removeTap で切り替わる、 screen ch tap は影響なし)
4. **swiftcap session lifecycle** ── unit test (boundary 受信で RotatingRecorder.finalize 呼ばれ、 session_started/session_finalized state.jsonl 出力、 current_session_id incremented)
5. **swiftcap retranscribe subcommand** ── unit test (実 CAF fixture を session 1 件分食わせて final.jsonl pass=2 row が出る、 retranscribe_done state event)
6. **fluentd filter_audio_state pass / session_id 透過** ── 既存テストに 1 case 追加 (session_id, pass フィールドが含まれる record の pass-through)
7. **out_sqlite_meeting_log** ── transcripts INSERT で pass / session_id / audio_segment_id を保存、 sessions table に status update が反映される
8. **web /api/session/boundary, /api/session/mute** ── rack-test (POST 202、 control.jsonl に正しい kind が append される)
9. **web /api/session/current, /api/session/recent** ── rack-test (active session 取得、 直近 N 件取得)
10. **web 転写 worker** ── 単体 test (status='finalized' な session を見つけて Process.spawn、 pidfile 作成、 重複 spawn skip)
11. **PicoRuby:wasm UI** ── 既存 frontend test の枠組みで、 ボタン押下 → POST 発火 / WebSocket message 受信で UI 更新
12. **mini-E5 e5_synthetic** ── 既存 fixture を新 schema 上で 5 連続 PASS 確認 (regression check)、 30s 実会議 verify

---

## 検証

backlog 必達条件チェックを **着手前 / 完了前** の双方で実施:

- 着手前: 本 spec の各 layer (Swift / fluentd / SQLite / WebSocket / PicoRuby) が Quick/Perfect/Graph ペインのデータ流入を絶たないこと
- 完了前 (merge 直前):
  - parent `bundle exec rake test` 全 PASS
  - swiftcap `swift test` 全 PASS
  - mini-E5 `bundle exec rake test:e5_synthetic` 5 連続 PASS
  - 30s 実会議 (YouTube バックグラウンド + 自分の声) で `localhost:9292` の Graph canvas に node + edge、 Quick/Perfect 空でない
  - SQLite `SELECT COUNT(*) FROM entity_edges` 前バージョン水準以上
  - **新規**: web から「区切る」 を押すと session N が status='finalized' → 'transcribing' → 'done' に遷移、 transcripts に pass=2 row が追加される
  - **新規**: web から「ミュート」 を押すと mic ch の final.jsonl が止まり、 screen ch は流れ続ける、 解除で mic 復活

---

## スコープ外 / Phase 2

- audio_segment 単位の単発 retranscribe UI (F spec の Phase 2 に相当、 別 spec で復活させる)
- 1 session 内の partial retranscribe (途中 N 分間だけ)
- session label の手動編集 UI
- session 履歴 viewer (左 sidebar で過去 session 一覧クリック → ペイン切替)
- 転写 queue の cancel / retry UI
- 無音検知での自動区切り (manual 制御に置き換えたので意図的に削除)
- 多言語自動切替 / locale auto detect
- speaker diarization
- swiftcap retranscribe の crash timeout 自動巻き戻し (Phase 1 では手動)
- (3) Quick UI 再設計 / (2) hallucination 削減 / (5) Gemini Nano augmentation は本 spec の subsequent

---

## 開始判断

main へ本 spec を merge してから着手すること。 新 branch:
`feat/web-session-control-and-rollover-2026-05-07`。

別 branch `feat/long-form-retranscribe-2026-05-06` の F spec とは設計上の
重複があるが、 本 spec が上位互換 (session 単位 vs audio_segment 単位)。
F branch の spec は履歴として残しつつ、 Phase 2 で audio_segment 単位
retranscribe UI を再開する際に再参照する。

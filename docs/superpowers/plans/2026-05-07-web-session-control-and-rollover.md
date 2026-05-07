# Web-controlled session boundary + rollover + mute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** swiftcap launches in `recording` state, web UI can roll over MTG sessions ("区切る") and toggle mic mute; on rollover, the just-finalized session's CAFs are sent through SpeechAnalyzer for a long-form pass=2 transcript.

**Architecture:** swiftcap emits `session_started_at` (float, monotonic) on every state/final event and watches `spool/control.jsonl` via FSEvents for `boundary` / `mute_toggle` commands. fluentd `out_sqlite_meeting_log` resolves `session_started_at` → `sessions.id` via ensure-on-lookup. Long-form retranscribe is a new `swiftcap retranscribe --session-id N` subcommand spawned by a Sinatra background worker when `sessions.status='finalized'`. Web UI gains a session-control bar on top of the existing 3-pane layout; PicoRuby:wasm front-end speaks to it via 202-style POSTs and WebSocket push messages.

**Tech Stack:** Swift 6.3 (AVFoundation, ScreenCaptureKit, SpeechAnalyzer, FSEvents, SQLite3 via swift-sqlite or direct C interop), Ruby 4.0.1 (Fluentd plugin, Sinatra, faye-websocket, sqlite3 gem), PicoRuby:wasm + plain JS in the browser, SQLite WAL.

**Spec:** `docs/superpowers/specs/2026-05-07-web-session-control-and-rollover.md`

---

## File Structure

**New files:**
- `migrations/20260507000000_session_control.sql` — adds `sessions.status`, `audio_segments.session_id`, `transcripts.pass`
- `swift/swiftcap/Sources/Swiftcap/SessionTracker.swift` — single source of truth for `current_session_started_at` and `mic_muted` flag inside `CaptureCoordinator`
- `swift/swiftcap/Sources/Swiftcap/ControlReader.swift` — FSEvents-based tail of `spool/control.jsonl`, dispatches `boundary` / `mute_toggle` callbacks, persists byte offset in `tmp/swiftcap_control.pos`
- `swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift` — `swiftcap retranscribe --session-id N` subcommand
- `swift/swiftcap/Tests/SwiftcapTests/SessionTrackerTests.swift`
- `swift/swiftcap/Tests/SwiftcapTests/ControlReaderTests.swift`
- `swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift`
- `test/fluent/test_filter_audio_state_session.rb` — pass-through assertions
- `test/fluent/test_out_sqlite_session_lifecycle.rb` — session_started / session_finalized / pass=2 handling
- `test/web/test_session_control_routes.rb` — boundary / mute / current / recent
- `test/web/test_retranscribe_worker.rb` — pidfile + spawn

**Modified files:**
- `swift/swiftcap/Sources/Swiftcap/Swiftcap.swift` — subcommand dispatch, ControlReader wiring
- `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift` — SessionTracker integration, mute toggle, boundary handler
- `swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift` — minor: nothing per se, but state event emission gains `session_started_at`
- `swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift` — final/quick events gain `session_started_at`
- `swift/swiftcap/Sources/Swiftcap/SoundAnalyzerWrapper.swift` — sound events gain `session_started_at` (for completeness)
- `lib/fluent/plugin/filter_audio_state.rb` — pass-through `session_started_at`
- `lib/fluent/plugin/out_sqlite_meeting_log.rb` — replace gap-based `ensure_session` with `ensure_session_by_started_at`, add session_started/session_finalized/mute_changed handlers, pass=2 INSERT
- `web/app.rb` — new routes, retranscribe worker thread
- `web/views/index.erb` — session-control bar HTML
- `web/assets/app.rb` — PicoRuby:wasm button + WebSocket handlers
- `web/assets/style.css` — session-bar styles

---

## Phase 0: Schema migration

### Task 1: Migration SQL + meta updates

**Files:**
- Create: `migrations/20260507000000_session_control.sql`

- [ ] **Step 1: Write the failing migrator test**

Add to `test/test_migrator.rb`:

```ruby
def test_session_control_columns_present
  AudioTranscription::Migrator.new(@db_path).run
  db = SQLite3::Database.new(@db_path, readonly: true)
  begin
    sessions_cols = db.execute("PRAGMA table_info(sessions)").map { |r| r[1] }
    assert_includes sessions_cols, 'status'
    audio_cols = db.execute("PRAGMA table_info(audio_segments)").map { |r| r[1] }
    assert_includes audio_cols, 'session_id'
    transcripts_cols = db.execute("PRAGMA table_info(transcripts)").map { |r| r[1] }
    assert_includes transcripts_cols, 'pass'
  ensure
    db.close
  end
end

def test_sessions_status_default_is_active
  AudioTranscription::Migrator.new(@db_path).run
  db = SQLite3::Database.new(@db_path)
  begin
    db.execute('INSERT INTO sessions(started_at) VALUES (?)', [1000.0])
    row = db.get_first_row('SELECT status FROM sessions WHERE started_at=?', [1000.0])
    assert_equal 'active', row[0]
  ensure
    db.close
  end
end

def test_transcripts_pass_default_is_1
  AudioTranscription::Migrator.new(@db_path).run
  db = SQLite3::Database.new(@db_path)
  begin
    db.execute(<<~SQL, [1000.0, 1000.0, 'mic', 'hi'])
      INSERT INTO transcripts(started_at, ended_at, channel, raw_text) VALUES (?, ?, ?, ?)
    SQL
    row = db.get_first_row('SELECT pass FROM transcripts WHERE raw_text=?', ['hi'])
    assert_equal 1, row[0]
  ensure
    db.close
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rake test TEST=test/test_migrator.rb`
Expected: FAIL with `assert_includes` errors (columns missing).

- [ ] **Step 3: Create migration**

Create `migrations/20260507000000_session_control.sql`:

```sql
-- migrations/20260507000000_session_control.sql

ALTER TABLE sessions ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
CREATE INDEX idx_sessions_status ON sessions(status);

ALTER TABLE audio_segments ADD COLUMN session_id INTEGER REFERENCES sessions(id);
CREATE INDEX idx_audio_segments_session ON audio_segments(session_id);

ALTER TABLE transcripts ADD COLUMN pass INTEGER NOT NULL DEFAULT 1;

UPDATE _sqlite_mcp_meta SET value =
  '会議単位（web から user-trigger で区切り）。 status は active/finalized/transcribing/done。 FM 生成の title/summary 保持。'
WHERE key = 'table:sessions';

INSERT OR REPLACE INTO _sqlite_mcp_meta(key, value) VALUES
  ('column:transcripts.pass',
   '1=live SpeechAnalyzer、 2=post-hoc 長尺 retranscribe。 同 audio_segment_id × pass 違いは別 row として残す。'),
  ('column:audio_segments.session_id',
   'sessions.id への FK。 swiftcap が user-trigger で区切った MTG 単位。'),
  ('column:sessions.status',
   'active=recording 中、 finalized=区切られて retranscribe 待ち、 transcribing=retranscribe 走行中、 done=完了。');
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rake test TEST=test/test_migrator.rb`
Expected: PASS (all 3 new tests + existing).

- [ ] **Step 5: Commit**

```bash
git add migrations/20260507000000_session_control.sql test/test_migrator.rb
git commit -m "feat(schema): add sessions.status, audio_segments.session_id, transcripts.pass"
```

---

## Phase 1: fluentd `filter_audio_state` pass-through `session_started_at`

### Task 2: filter_audio_state propagates session_started_at

**Files:**
- Create: `test/fluent/test_filter_audio_state_session.rb`
- Modify: `lib/fluent/plugin/filter_audio_state.rb`

- [ ] **Step 1: Write the failing test**

Create `test/fluent/test_filter_audio_state_session.rb`:

```ruby
# test/fluent/test_filter_audio_state_session.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_audio_state'
require 'fileutils'
require 'tmpdir'

class TestFilterAudioStateSession < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('audio-state-session-')
    @caf = File.join(@tmp, 'mic.caf')
    File.binwrite(@caf, "FAKE_CAF")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::AudioStateFilter).configure('')
  end

  def test_rotated_event_propagates_session_started_at
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'rotated', 'channel' => 'mic', 'path' => @caf,
        'started_at' => 1000.0, 'ended_at' => 1030.0,
        'session_started_at' => 950.5
      })
    end
    rec = d.filtered_records.first
    assert_equal 950.5, rec['session_started_at']
  end

  def test_session_started_kind_is_passed_through
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => 950.5, 'ts' => 950.5
      })
    end
    rec = d.filtered_records.first
    assert_not_nil rec
    assert_equal 'session_started', rec['kind']
    assert_equal 950.5, rec['session_started_at']
  end

  def test_session_finalized_kind_is_passed_through
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_finalized', 'session_started_at' => 950.5,
        'ended_at' => 1100.0, 'ts' => 1100.0
      })
    end
    rec = d.filtered_records.first
    assert_not_nil rec
    assert_equal 'session_finalized', rec['kind']
    assert_equal 1100.0, rec['ended_at']
  end

  def test_mute_changed_kind_is_passed_through
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'mute_changed', 'session_started_at' => 950.5,
        'mic_muted' => true, 'ts' => 1010.0
      })
    end
    rec = d.filtered_records.first
    assert_not_nil rec
    assert_equal 'mute_changed', rec['kind']
    assert_equal true, rec['mic_muted']
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rake test TEST=test/fluent/test_filter_audio_state_session.rb`
Expected: FAIL — current filter drops non-rotated events and doesn't propagate session_started_at.

- [ ] **Step 3: Update filter**

Replace `lib/fluent/plugin/filter_audio_state.rb` body:

```ruby
# lib/fluent/plugin/filter_audio_state.rb
require 'fluent/plugin/filter'

module Fluent
  module Plugin
    class AudioStateFilter < Fluent::Plugin::Filter
      Fluent::Plugin.register_filter('audio_state', self)

      SESSION_KINDS = %w[session_started session_finalized mute_changed retranscribe_done].freeze

      def filter(_tag, _time, record)
        kind = record['kind']
        if SESSION_KINDS.include?(kind)
          return record
        end
        return nil unless kind == 'rotated'
        path = record['path']
        return nil unless path && File.file?(path)
        unless record['started_at'] && record['ended_at']
          log.warn 'rotated event missing started_at/ended_at, dropping (contract violation)', record: record.reject { |k, _| k == 'blob' }
          return nil
        end
        blob = File.binread(path)
        started_at = record['started_at'].to_f
        ended_at = record['ended_at'].to_f
        out = {
          'channel' => record['channel'],
          'path' => path,
          'started_at' => started_at,
          'ended_at' => ended_at,
          'duration_sec' => ended_at - started_at,
          'codec' => 'aac',
          'sample_rate' => 16000,
          'bytes' => blob.bytesize,
          'blob' => blob
        }
        out['session_started_at'] = record['session_started_at'].to_f if record['session_started_at']
        out
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rake test TEST=test/fluent/test_filter_audio_state_session.rb test/fluent/test_filter_audio_state.rb`
Expected: all PASS (existing rotated-event test still passes).

- [ ] **Step 5: Commit**

```bash
git add lib/fluent/plugin/filter_audio_state.rb test/fluent/test_filter_audio_state_session.rb
git commit -m "feat(filter): pass through session_started_at and session_* state kinds"
```

---

## Phase 2: fluentd `out_sqlite_meeting_log` session lifecycle

### Task 3: ensure_session_by_started_at + replace gap-based logic

**Files:**
- Create: `test/fluent/test_out_sqlite_session_lifecycle.rb`
- Modify: `lib/fluent/plugin/out_sqlite_meeting_log.rb`

- [ ] **Step 1: Write the failing test**

Create `test/fluent/test_out_sqlite_session_lifecycle.rb`:

```ruby
# test/fluent/test_out_sqlite_session_lifecycle.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_sqlite_meeting_log'
require 'fileutils'
require 'tmpdir'
require 'sqlite3'
require_relative '../../lib/audio_transcription/migrator'

class TestOutSqliteSessionLifecycle < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('out-sqlite-session-')
    @db_path = File.join(@tmp, 'meeting_log.sqlite')
    AudioTranscription::Migrator.new(@db_path).run
    @ack = File.join(@tmp, 'ack.jsonl')
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def driver
    Fluent::Test::Driver::Output.new(Fluent::Plugin::SqliteMeetingLogOutput).configure(<<~CONF)
      db_path #{@db_path}
      ack_path #{@ack}
    CONF
  end

  def db_ro
    SQLite3::Database.new(@db_path, readonly: true).tap { |d| d.results_as_hash = true }
  end

  def test_session_started_event_creates_active_session
    d = driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => 1000.0, 'ts' => 1000.0
      })
    end
    rows = db_ro.execute('SELECT id, started_at, status FROM sessions')
    assert_equal 1, rows.size
    assert_equal 1000.0, rows[0]['started_at']
    assert_equal 'active', rows[0]['status']
  end

  def test_session_finalized_updates_ended_at_and_status
    d = driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => 1000.0, 'ts' => 1000.0
      })
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_finalized', 'session_started_at' => 1000.0,
        'ended_at' => 1500.0, 'ts' => 1500.0
      })
    end
    row = db_ro.get_first_row('SELECT ended_at, status FROM sessions WHERE started_at=1000.0')
    assert_equal 1500.0, row['ended_at']
    assert_equal 'finalized', row['status']
  end

  def test_final_record_uses_session_started_at_for_session_id
    d = driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => 2000.0, 'ts' => 2000.0
      })
    end
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'final', 'ch' => 'mic', 'text' => 'こんにちは',
        'started_at' => 2010.0, 'ended_at' => 2020.0, 'language' => 'ja-JP',
        'session_started_at' => 2000.0, 'transcript_id' => 'abc'
      })
    end
    sid = db_ro.get_first_row('SELECT id FROM sessions WHERE started_at=2000.0')['id']
    row = db_ro.get_first_row('SELECT session_id, raw_text, pass FROM transcripts')
    assert_equal sid, row['session_id']
    assert_equal 'こんにちは', row['raw_text']
    assert_equal 1, row['pass']
  end

  def test_pass_2_final_inserts_new_row_not_update
    d = driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => 3000.0, 'ts' => 3000.0
      })
    end
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'final', 'ch' => 'mic', 'text' => 'live',
        'started_at' => 3010.0, 'ended_at' => 3020.0,
        'session_started_at' => 3000.0, 'pass' => 1
      })
      d.feed(Fluent::EventTime.now, {
        'kind' => 'final', 'ch' => 'mic', 'text' => 'polished',
        'started_at' => 3010.0, 'ended_at' => 3020.0,
        'session_started_at' => 3000.0, 'pass' => 2
      })
    end
    rows = db_ro.execute('SELECT raw_text, pass FROM transcripts ORDER BY pass')
    assert_equal 2, rows.size
    assert_equal 'live', rows[0]['raw_text']
    assert_equal 1, rows[0]['pass']
    assert_equal 'polished', rows[1]['raw_text']
    assert_equal 2, rows[1]['pass']
  end

  def test_audio_segment_gets_session_id_from_session_started_at
    d = driver
    caf = File.join(@tmp, 'x.caf')
    File.binwrite(caf, 'BLOB')
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => 4000.0, 'ts' => 4000.0
      })
      d.feed(Fluent::EventTime.now, {
        'channel' => 'mic', 'path' => caf, 'blob' => 'BLOB',
        'started_at' => 4010.0, 'ended_at' => 4040.0, 'duration_sec' => 30.0,
        'codec' => 'aac', 'sample_rate' => 16000, 'bytes' => 4,
        'session_started_at' => 4000.0
      })
    end
    sid = db_ro.get_first_row('SELECT id FROM sessions WHERE started_at=4000.0')['id']
    row = db_ro.get_first_row('SELECT session_id FROM audio_segments')
    assert_equal sid, row['session_id']
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rake test TEST=test/fluent/test_out_sqlite_session_lifecycle.rb`
Expected: FAIL — none of session_started / session_finalized / pass / session_id from session_started_at are handled.

- [ ] **Step 3: Replace out_sqlite implementation**

Replace `lib/fluent/plugin/out_sqlite_meeting_log.rb` with:

```ruby
# lib/fluent/plugin/out_sqlite_meeting_log.rb
require 'fluent/plugin/output'
require 'sqlite3'
require 'json'
require 'net/http'
require 'uri'

module Fluent
  module Plugin
    class SqliteMeetingLogOutput < Fluent::Plugin::Output
      Fluent::Plugin.register_output('sqlite_meeting_log', self)

      config_param :db_path, :string
      config_param :ack_path, :string, default: nil
      config_param :webhook_url, :string, default: nil

      def configure(conf)
        super
        @db = SQLite3::Database.new(@db_path)
        @db.execute("PRAGMA journal_mode=WAL")
        @db.execute("PRAGMA foreign_keys=ON")
      end

      def shutdown
        @db.close if @db
        super
      end

      def process(tag, es)
        es.each do |_time, record|
          case tag
          when 'audio.state'
            case record['kind']
            when 'session_started'   then handle_session_started(record)
            when 'session_finalized' then handle_session_finalized(record)
            when 'mute_changed'      then handle_mute_changed(record)
            when 'retranscribe_done' then handle_retranscribe_done(record)
            else                          handle_segment(record)
            end
          when 'audio.final'    then handle_final(record)
          when 'audio.sound'    then handle_sound(record)
          when 'audio.quick'    then handle_quick(record)
          end
        end
      end

      private

      def handle_quick(record)
        notify('quick', record)
      end

      def handle_session_started(record)
        sat = record['session_started_at']&.to_f
        return unless sat
        ensure_session_by_started_at(sat)
        notify('session_started', { 'session_started_at' => sat,
                                    'session_id' => session_id_for(sat) })
      end

      def handle_session_finalized(record)
        sat = record['session_started_at']&.to_f
        return unless sat
        ended_at = record['ended_at']&.to_f
        sid = ensure_session_by_started_at(sat)
        @db.execute("UPDATE sessions SET ended_at=?, status='finalized' WHERE id=?",
                    [ended_at, sid])
        notify('session_finalized', { 'session_started_at' => sat,
                                       'session_id' => sid, 'ended_at' => ended_at })
      end

      def handle_mute_changed(record)
        notify('mute_changed', record)
      end

      def handle_retranscribe_done(record)
        sat = record['session_started_at']&.to_f
        sid = sat ? session_id_for(sat) : record['session_id']&.to_i
        return unless sid
        @db.execute("UPDATE sessions SET status='done' WHERE id=?", [sid])
        notify('retranscribe_done', { 'session_id' => sid })
      end

      def handle_final(record)
        return unless record['kind'] == 'final'
        sat = record['session_started_at']&.to_f
        session_id = sat ? ensure_session_by_started_at(sat) : nil
        pass = (record['pass'] || 1).to_i
        sql = <<~SQL
          INSERT INTO transcripts(audio_segment_id, session_id, channel, speaker,
                                  started_at, ended_at, language, raw_text,
                                  polished_text, swiftcap_transcript_id, pass)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        @db.execute(sql, [
          record['audio_segment_id'], session_id, record['ch'], speaker_for(record['ch']),
          record['started_at'].to_f, record['ended_at'].to_f, record['language'],
          record['text'], record['polished_text'], record['transcript_id'], pass
        ])
        transcript_id = @db.last_insert_row_id
        (record['entities'] || []).each do |e|
          @db.execute(<<~SQL, [transcript_id, e['text'], e['kind'], record['ended_at'].to_f])
            INSERT INTO entities(transcript_id, text, kind, observed_at)
            VALUES (?, ?, ?, ?)
          SQL
        end
        update_edges(record['entities'] || [], record['ended_at'].to_f)
        notify('final', record.merge('id' => transcript_id, 'pass' => pass))
      end

      def handle_segment(record)
        return unless record['blob']
        sat = record['session_started_at']&.to_f
        session_id = sat ? ensure_session_by_started_at(sat) : nil
        sql = <<~SQL
          INSERT INTO audio_segments(channel, started_at, ended_at, duration_sec,
                                     codec, sample_rate, bytes, blob, session_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        @db.execute(sql, [
          record['channel'], record['started_at'].to_f, record['ended_at'].to_f,
          record['duration_sec'].to_f, record['codec'], record['sample_rate'].to_i,
          record['bytes'].to_i, SQLite3::Blob.new(record['blob']), session_id
        ])
        if @ack_path && record['path']
          File.open(@ack_path, 'a') do |f|
            f.puts JSON.generate({
              'ts' => Time.now.to_f, 'kind' => 'consumed', 'path' => record['path']
            })
          end
        end
        notify('audio_segment', record.reject { |k, _| k == 'blob' })
      end

      def handle_sound(record)
        sql = <<~SQL
          INSERT INTO sound_labels(audio_segment_id, channel, started_at,
                                   ended_at, label, confidence)
          VALUES (?, ?, ?, ?, ?, ?)
        SQL
        @db.execute(sql, [
          nil, record['ch'], record['started_at'].to_f, record['ended_at'].to_f,
          record['label'], record['confidence'].to_f
        ])
        notify('sound', record)
      end

      def ensure_session_by_started_at(started_at)
        row = @db.get_first_row('SELECT id FROM sessions WHERE started_at=?', [started_at])
        return row[0] if row
        @db.execute('INSERT INTO sessions(started_at, status) VALUES (?, ?)',
                    [started_at, 'active'])
        @db.last_insert_row_id
      end

      def session_id_for(started_at)
        row = @db.get_first_row('SELECT id FROM sessions WHERE started_at=?', [started_at])
        row && row[0]
      end

      def speaker_for(channel)
        channel == 'mic' ? 'self' : 'remote'
      end

      def update_edges(entities, observed_at)
        texts = entities.map { |e| e['text'] }.uniq
        return if texts.size < 2
        texts.combination(2).each do |a, b|
          src, dst = [a, b].sort
          @db.execute(<<~SQL, [src, dst, observed_at, observed_at])
            INSERT INTO entity_edges(src, dst, weight, last_observed_at)
            VALUES (?, ?, 1.0, ?)
            ON CONFLICT(src, dst) DO UPDATE
              SET weight = weight + 1.0, last_observed_at = ?
          SQL
        end
      end

      def notify(kind, payload)
        return unless @webhook_url
        uri = URI.parse(@webhook_url)
        Thread.new do
          begin
            Net::HTTP.post(uri, JSON.generate({ 'type' => kind, 'data' => payload }),
                           'Content-Type' => 'application/json')
          rescue StandardError => e
            log.warn "webhook failed: #{e.class}: #{e.message}"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2.5: Update fluent.conf to drop deprecated `session_gap_seconds`**

Modify `config/fluent.conf` `<match audio.{quick,final,sound,state}>` block — remove the `session_gap_seconds 600` line. Result:

```
<match audio.{quick,final,sound,state}>
  @type sqlite_meeting_log
  db_path "#{ENV['DB_PATH'] || 'db/meeting_log.sqlite'}"
  ack_path "#{ENV['SPOOL_DIR'] || '/Users/bash/Library/Application Support/audio-transcription/spool'}/ack.jsonl"
  webhook_url "#{ENV['WEBHOOK_URL'] || 'http://localhost:9292/_internal/notify'}"
</match>
```

- [ ] **Step 3: Run tests**

Run: `bundle exec rake test TEST=test/fluent/test_out_sqlite_session_lifecycle.rb`
Expected: PASS (5 tests).

Also run: `bundle exec rake test TEST=test/fluent/test_out_sqlite_meeting_log.rb` (existing test) — Expected: PASS (no regression).

- [ ] **Step 4: Commit**

```bash
git add lib/fluent/plugin/out_sqlite_meeting_log.rb config/fluent.conf test/fluent/test_out_sqlite_session_lifecycle.rb
git commit -m "feat(out_sqlite): handle session_started/finalized/retranscribe_done; explicit session_started_at FK"
```

---

## Phase 3: swiftcap SessionTracker

### Task 4: SessionTracker actor

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/SessionTracker.swift`
- Create: `swift/swiftcap/Tests/SwiftcapTests/SessionTrackerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `swift/swiftcap/Tests/SwiftcapTests/SessionTrackerTests.swift`:

```swift
import XCTest
@testable import Swiftcap

@available(macOS 26.0, *)
final class SessionTrackerTests: XCTestCase {
    func testInitialStateRecordingNotMuted() async {
        let t = SessionTracker(now: 1000.0)
        let started = await t.currentSessionStartedAt
        XCTAssertEqual(started, 1000.0)
        let muted = await t.isMicMuted
        XCTAssertFalse(muted)
    }

    func testRolloverAdvancesStartedAt() async {
        let t = SessionTracker(now: 1000.0)
        let prev = await t.rollover(now: 1500.0)
        XCTAssertEqual(prev, 1000.0)
        let next = await t.currentSessionStartedAt
        XCTAssertEqual(next, 1500.0)
    }

    func testMuteToggleFlipsFlag() async {
        let t = SessionTracker(now: 1000.0)
        let after1 = await t.toggleMute()
        XCTAssertTrue(after1)
        let after2 = await t.toggleMute()
        XCTAssertFalse(after2)
    }

    func testRolloverPreservesMuteState() async {
        let t = SessionTracker(now: 1000.0)
        _ = await t.toggleMute()
        _ = await t.rollover(now: 2000.0)
        let muted = await t.isMicMuted
        XCTAssertTrue(muted, "mute state should survive session rollover")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift/swiftcap && swift test --filter SessionTrackerTests`
Expected: FAIL (SessionTracker undefined).

- [ ] **Step 3: Implement SessionTracker**

Create `swift/swiftcap/Sources/Swiftcap/SessionTracker.swift`:

```swift
// swift/swiftcap/Sources/Swiftcap/SessionTracker.swift
import Foundation

@available(macOS 26.0, *)
actor SessionTracker {
    private(set) var currentSessionStartedAt: TimeInterval
    private(set) var isMicMuted: Bool = false

    init(now: TimeInterval = Date().timeIntervalSince1970) {
        self.currentSessionStartedAt = now
    }

    /// Advances to a new session. Returns the previous session's started_at
    /// so the caller can emit a session_finalized event for it.
    func rollover(now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        let prev = currentSessionStartedAt
        currentSessionStartedAt = now
        return prev
    }

    /// Flips the mute flag and returns the new value.
    func toggleMute() -> Bool {
        isMicMuted.toggle()
        return isMicMuted
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd swift/swiftcap && swift test --filter SessionTrackerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add swift/swiftcap/Sources/Swiftcap/SessionTracker.swift swift/swiftcap/Tests/SwiftcapTests/SessionTrackerTests.swift
git commit -m "feat(swiftcap): add SessionTracker actor for session_started_at + mute flag"
```

---

## Phase 4: swiftcap state events with session_started_at

### Task 5: stateWriter emits session_started + threads session_started_at into rotated/final/sound

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`
- Modify: `swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift`
- Modify: `swift/swiftcap/Sources/Swiftcap/SoundAnalyzerWrapper.swift`
- Modify: `swift/swiftcap/Sources/Swiftcap/Swiftcap.swift`

- [ ] **Step 1: Add session_started emission at startup**

In `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`, add a stored property and emit in `start`:

After the line `private var screenAudioOutput: ScreenAudioOutput?`, add:

```swift
    let sessions: SessionTracker
```

Replace the `init` body:

```swift
    init(spoolDir: URL, sessions: SessionTracker = SessionTracker()) {
        self.spoolDir = spoolDir
        self.sessions = sessions
        try? FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        self.stateWriter = SpoolWriter(url: spoolDir.appendingPathComponent("state.jsonl"))
        self.quickWriter = SpoolWriter(url: spoolDir.appendingPathComponent("quick.jsonl"))
        self.finalWriter = SpoolWriter(url: spoolDir.appendingPathComponent("final.jsonl"))
        self.soundWriter = SpoolWriter(url: spoolDir.appendingPathComponent("sound.jsonl"))
    }
```

At the very top of `start(locale:)` (before the `for ch in ["mic","screen"]` loop), insert:

```swift
        let sat = await sessions.currentSessionStartedAt
        try? stateWriter.append([
            "ts": Date().timeIntervalSince1970,
            "kind": "session_started",
            "session_started_at": sat
        ])
```

- [ ] **Step 2: Thread session_started_at into rotated event**

In the same file, replace the `private func rotate(channel:recorder:reason:)` body's `try? stateWriter.append([...])` call with:

```swift
        let sat = await sessions.currentSessionStartedAt
        try? stateWriter.append([
            "ts": Date().timeIntervalSince1970,
            "kind": "rotated",
            "channel": channel,
            "path": finalized.path,
            "bytes": finalized.bytes,
            "started_at": finalized.startedAt,
            "ended_at": finalized.endedAt,
            "session_started_at": sat,
            "reason": reason
        ])
```

- [ ] **Step 3: Pass session_started_at into TranscriberWrapper / SoundAnalyzerWrapper**

In `swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift`, find every `finalWriter.append([...])` and `quickWriter.append([...])` call. Add a closure parameter to read `session_started_at` from the coordinator. Simplest implementation:

Add an init parameter `sessionStartedAtProvider: @Sendable () async -> TimeInterval`. Inside append calls, await it and add to the dict. Sample diff at construction site in `CaptureCoordinator.start`:

```swift
            transcribers[ch] = try await TranscriberWrapper(
                channel: ch, locale: locale,
                quickWriter: quickWriter,
                finalWriter: finalWriter,
                sessionStartedAtProvider: { [weak self] in
                    await self?.sessions.currentSessionStartedAt ?? 0
                })
```

Inside TranscriberWrapper's transcript-output code path, before each writer.append, do:

```swift
                let sat = await sessionStartedAtProvider()
                try? finalWriter.append([
                    // ... existing fields ...
                    "session_started_at": sat
                ])
```

(Repeat for the quick.jsonl branch.)

For SoundAnalyzerWrapper: same pattern — add `sessionStartedAtProvider` init param and include `session_started_at` in every soundWriter.append payload. Do not change SoundAnalyzerWrapper if sound events don't need session linkage in this phase — out_sqlite doesn't read session for sound_labels. Leave SoundAnalyzerWrapper unchanged.

- [ ] **Step 4: Update existing tests if any failed because of init signature**

Run: `cd swift/swiftcap && swift test`
Expected: build succeeds, existing tests PASS, plus session_started event now emitted.

If `CaptureCoordinatorChannelFailureTests.swift` instantiates `CaptureCoordinator(spoolDir:)` directly, the new default `sessions:` parameter (`SessionTracker()`) keeps the call site valid.

- [ ] **Step 5: Commit**

```bash
git add swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift \
        swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift \
        swift/swiftcap/Sources/Swiftcap/Swiftcap.swift
git commit -m "feat(swiftcap): emit session_started at startup and thread session_started_at into rotated/final/quick"
```

---

## Phase 5: ControlReader (FSEvents tail of control.jsonl)

### Task 6: ControlReader actor with offset persistence

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/ControlReader.swift`
- Create: `swift/swiftcap/Tests/SwiftcapTests/ControlReaderTests.swift`

- [ ] **Step 1: Write the failing test**

Create `swift/swiftcap/Tests/SwiftcapTests/ControlReaderTests.swift`:

```swift
import XCTest
@testable import Swiftcap

@available(macOS 26.0, *)
final class ControlReaderTests: XCTestCase {
    var tmp: URL!

    override func setUp() async throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctrl-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testReadNewParsesAppendedLines() async throws {
        let ctrl = tmp.appendingPathComponent("control.jsonl")
        let pos = tmp.appendingPathComponent("control.pos")
        let reader = ControlReader(controlURL: ctrl, posURL: pos)

        try Data().write(to: ctrl) // empty
        let none = try reader.readNew()
        XCTAssertTrue(none.isEmpty)

        let line1 = #"{"ts":1.0,"kind":"boundary"}"# + "\n"
        try line1.data(using: .utf8)!.write(to: ctrl)
        let one = try reader.readNew()
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0]["kind"] as? String, "boundary")

        let again = try reader.readNew()
        XCTAssertTrue(again.isEmpty, "offset should advance so re-read returns empty")
    }

    func testReadNewSurvivesProcessRestart() async throws {
        let ctrl = tmp.appendingPathComponent("control.jsonl")
        let pos = tmp.appendingPathComponent("control.pos")
        let line1 = #"{"ts":1.0,"kind":"boundary"}"# + "\n"
        try line1.data(using: .utf8)!.write(to: ctrl)

        let r1 = ControlReader(controlURL: ctrl, posURL: pos)
        _ = try r1.readNew()

        let line2 = #"{"ts":2.0,"kind":"mute_toggle"}"# + "\n"
        let handle = try FileHandle(forWritingTo: ctrl)
        handle.seekToEndOfFile()
        handle.write(line2.data(using: .utf8)!)
        try handle.close()

        let r2 = ControlReader(controlURL: ctrl, posURL: pos)
        let new = try r2.readNew()
        XCTAssertEqual(new.count, 1, "fresh reader should resume from saved offset")
        XCTAssertEqual(new[0]["kind"] as? String, "mute_toggle")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd swift/swiftcap && swift test --filter ControlReaderTests`
Expected: FAIL — ControlReader undefined.

- [ ] **Step 3: Implement ControlReader**

Create `swift/swiftcap/Sources/Swiftcap/ControlReader.swift`:

```swift
// swift/swiftcap/Sources/Swiftcap/ControlReader.swift
import Foundation

@available(macOS 26.0, *)
final class ControlReader {
    let controlURL: URL
    let posURL: URL

    init(controlURL: URL, posURL: URL) {
        self.controlURL = controlURL
        self.posURL = posURL
    }

    func readNew() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: controlURL.path) else { return [] }
        let off = readOffset()
        let handle = try FileHandle(forReadingFrom: controlURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: off)
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty else { return [] }
        var parsed: [[String: Any]] = []
        var consumed: UInt64 = 0
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (idx, line) in lines.enumerated() {
            // Last element is the trailing partial line (no newline yet) — skip.
            if idx == lines.count - 1 && !data.hasSuffix(Data([0x0A])) { break }
            consumed += UInt64(line.count) + 1
            if line.isEmpty { continue }
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                parsed.append(obj)
            }
        }
        writeOffset(off + consumed)
        return parsed
    }

    private func readOffset() -> UInt64 {
        guard let data = try? Data(contentsOf: posURL),
              let s = String(data: data, encoding: .utf8),
              let v = UInt64(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 0 }
        return v
    }

    private func writeOffset(_ off: UInt64) {
        try? "\(off)".data(using: .utf8)!.write(to: posURL, options: .atomic)
    }
}

private extension Data {
    func hasSuffix(_ other: Data) -> Bool {
        guard count >= other.count else { return false }
        return suffix(other.count) == other
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd swift/swiftcap && swift test --filter ControlReaderTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add swift/swiftcap/Sources/Swiftcap/ControlReader.swift swift/swiftcap/Tests/SwiftcapTests/ControlReaderTests.swift
git commit -m "feat(swiftcap): add ControlReader for FSEvents-style tail of control.jsonl"
```

---

## Phase 6: Wire ControlReader into Swiftcap.swift main + boundary handler

### Task 7: handleBoundary on CaptureCoordinator

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`
- Modify: `swift/swiftcap/Sources/Swiftcap/Swiftcap.swift`

- [ ] **Step 1: Write a failing test for handleBoundary**

Add to `swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorChannelFailureTests.swift` (or split out — create `CaptureCoordinatorBoundaryTests.swift`):

```swift
import XCTest
@testable import Swiftcap

@available(macOS 26.0, *)
final class CaptureCoordinatorBoundaryTests: XCTestCase {
    func testHandleBoundaryEmitsSessionFinalizedAndAdvancesSession() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tracker = SessionTracker(now: 1000.0)
        let coord = CaptureCoordinator(spoolDir: tmp, sessions: tracker)
        await coord.handleBoundary(now: 2000.0)
        let next = await tracker.currentSessionStartedAt
        XCTAssertEqual(next, 2000.0)
        let lines = (try String(contentsOf: tmp.appendingPathComponent("state.jsonl")))
            .split(separator: "\n").map(String.init)
        let finalized = lines.first { $0.contains("session_finalized") }
        XCTAssertNotNil(finalized)
        XCTAssertTrue(finalized!.contains(#""session_started_at":1000"#))
        let started = lines.first { $0.contains("session_started") && $0.contains(#""session_started_at":2000"#) }
        XCTAssertNotNil(started)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift/swiftcap && swift test --filter CaptureCoordinatorBoundaryTests`
Expected: FAIL (handleBoundary undefined).

- [ ] **Step 3: Implement handleBoundary**

Add to `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`, right after `func shutdownRotate(reason:)`:

```swift
    /// Called when the user presses 区切る in the web UI. Finalizes all active
    /// recorders for the current session, advances SessionTracker to a new
    /// session_started_at, restarts recorders so the next CAF rotation belongs
    /// to the new session, and emits session_finalized + session_started state
    /// events. The just-finalized session_started_at is what the web worker
    /// will look up to spawn `swiftcap retranscribe`.
    func handleBoundary(now: TimeInterval = Date().timeIntervalSince1970) async {
        for (ch, recorder) in recorders {
            await rotate(channel: ch, recorder: recorder, reason: "boundary")
        }
        let prevSat = await sessions.rollover(now: now)
        try? stateWriter.append([
            "ts": now,
            "kind": "session_finalized",
            "session_started_at": prevSat,
            "ended_at": now
        ])
        try? stateWriter.append([
            "ts": now,
            "kind": "session_started",
            "session_started_at": now
        ])
        for ch in ["mic", "screen"] {
            recorders[ch] = RotatingRecorder(channel: ch, spoolDir: spoolDir)
            try? recorders[ch]?.start()
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd swift/swiftcap && swift test --filter CaptureCoordinatorBoundaryTests`
Expected: PASS.

- [ ] **Step 5: Wire ControlReader into main.swift dispatch**

Edit `swift/swiftcap/Sources/Swiftcap/Swiftcap.swift`. Replace the `Swiftcap.main()` body — after `try await coordinator.start(locale: locale)` and the `swiftcap ready` log, add:

```swift
        let controlReader = ControlReader(
            controlURL: spoolDir.appendingPathComponent("control.jsonl"),
            posURL: spoolDir.appendingPathComponent(".pos.control"))
        Task {
            while true {
                if let events = try? controlReader.readNew(), !events.isEmpty {
                    for ev in events {
                        switch ev["kind"] as? String {
                        case "boundary":
                            await coordinator.handleBoundary()
                        case "mute_toggle":
                            await coordinator.handleMuteToggle()
                        default:
                            FileHandle.standardError.write("control: unknown kind \(ev)\n".data(using: .utf8)!)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
```

(`handleMuteToggle` is implemented in Task 8.)

- [ ] **Step 6: Commit**

```bash
git add swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift \
        swift/swiftcap/Sources/Swiftcap/Swiftcap.swift \
        swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorBoundaryTests.swift
git commit -m "feat(swiftcap): handleBoundary rotates + advances session, ControlReader wired into main loop"
```

---

## Phase 7: Mute toggle implementation

### Task 8: handleMuteToggle on CaptureCoordinator

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`

- [ ] **Step 1: Write a failing test**

Append to `CaptureCoordinatorBoundaryTests.swift`:

```swift
    func testHandleMuteToggleFlipsAndEmitsEvent() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tracker = SessionTracker(now: 1000.0)
        let coord = CaptureCoordinator(spoolDir: tmp, sessions: tracker)
        await coord.handleMuteToggle()
        let muted1 = await tracker.isMicMuted
        XCTAssertTrue(muted1)
        await coord.handleMuteToggle()
        let muted2 = await tracker.isMicMuted
        XCTAssertFalse(muted2)
        let raw = (try? String(contentsOf: tmp.appendingPathComponent("state.jsonl"))) ?? ""
        XCTAssertTrue(raw.contains(#""kind":"mute_changed""#))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift/swiftcap && swift test --filter CaptureCoordinatorBoundaryTests`
Expected: FAIL (handleMuteToggle undefined).

- [ ] **Step 3: Implement handleMuteToggle**

Add to `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`, right after `handleBoundary`:

```swift
    /// Toggle mic-channel mute. SessionTracker holds the flag; the live mic
    /// AVAudioEngine tap is removed/reinstalled so no buffers reach the
    /// recorder/transcriber/sound analyzer for the mic channel during mute.
    /// Screen channel and current session_started_at are unaffected.
    func handleMuteToggle() async {
        let nowMuted = await sessions.toggleMute()
        let sat = await sessions.currentSessionStartedAt
        if nowMuted {
            micEngine.inputNode.removeTap(onBus: 0)
        } else {
            try? installMicTap()
        }
        try? stateWriter.append([
            "ts": Date().timeIntervalSince1970,
            "kind": "mute_changed",
            "session_started_at": sat,
            "mic_muted": nowMuted
        ])
    }

    /// Extracted from startMic() so handleMuteToggle can re-install the tap
    /// after an unmute. Engine itself is not stopped — installTap is enough
    /// to resume buffer flow.
    private func installMicTap() throws {
        let input = micEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            Task { await self.feed(channel: "mic", buffer: buffer, time: time) }
        }
    }
```

Refactor `startMic()` to use `installMicTap()`:

Replace the block from `let firstBufferLogged = ConvertOnce()` through `try micEngine.start()` with:

```swift
        let firstBufferLogged = ConvertOnce()
        let inputFormat = input.outputFormat(forBus: 0)
        sounds["mic"] = try SoundAnalyzerWrapper(channel: "mic", writer: soundWriter, format: inputFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            if firstBufferLogged.fire() {
                FileHandle.standardError.write(
                    "MicAudioOutput: first buffer received format=\(buffer.format) frameLength=\(buffer.frameLength)\n".data(using: .utf8)!
                )
            }
            Task { await self.feed(channel: "mic", buffer: buffer, time: time) }
        }
        try micEngine.start()
```

(I.e., move sounds["mic"] init before installTap, drop the duplicated `let input = micEngine.inputNode` since outer scope still uses `input`.) Verify by running tests.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd swift/swiftcap && swift test --filter CaptureCoordinatorBoundaryTests`
Expected: PASS.
Also run: `cd swift/swiftcap && swift test`  full — Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift swift/swiftcap/Tests/SwiftcapTests/CaptureCoordinatorBoundaryTests.swift
git commit -m "feat(swiftcap): handleMuteToggle removes/reinstalls mic tap; mute state in SessionTracker"
```

---

## Phase 8: swiftcap retranscribe subcommand

### Task 9: Subcommand dispatch + arg parsing skeleton

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift`
- Modify: `swift/swiftcap/Sources/Swiftcap/Swiftcap.swift`

- [ ] **Step 1: Write a failing test**

Create `swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift`:

```swift
import XCTest
@testable import Swiftcap

@available(macOS 26.0, *)
final class RetranscribeCommandTests: XCTestCase {
    func testParseArgsRequiresSessionId() {
        let result = RetranscribeCommand.parse(args: ["--locale", "ja-JP"])
        XCTAssertNil(result, "missing --session-id should fail to parse")
    }

    func testParseArgsHappyPath() throws {
        let res = try XCTUnwrap(RetranscribeCommand.parse(args: [
            "--session-id", "42", "--locale", "ja-JP", "--pass", "2"
        ]))
        XCTAssertEqual(res.sessionId, 42)
        XCTAssertEqual(res.locale.identifier, "ja-JP")
        XCTAssertEqual(res.pass, 2)
    }

    func testParseArgsDefaults() throws {
        let res = try XCTUnwrap(RetranscribeCommand.parse(args: ["--session-id", "7"]))
        XCTAssertEqual(res.sessionId, 7)
        XCTAssertEqual(res.pass, 2)
        XCTAssertEqual(res.locale.identifier, "ja-JP")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift/swiftcap && swift test --filter RetranscribeCommandTests`
Expected: FAIL (RetranscribeCommand undefined).

- [ ] **Step 3: Implement skeleton**

Create `swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift`:

```swift
// swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift
import Foundation

@available(macOS 26.0, *)
struct RetranscribeCommand {
    let sessionId: Int
    let locale: Locale
    let pass: Int

    static func parse(args: [String]) -> RetranscribeCommand? {
        var sid: Int? = nil
        var locale = Locale(identifier: "ja-JP")
        var pass = 2
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--session-id":
                guard i + 1 < args.count, let n = Int(args[i + 1]) else { return nil }
                sid = n; i += 2
            case "--locale":
                guard i + 1 < args.count else { return nil }
                locale = Locale(identifier: args[i + 1]); i += 2
            case "--pass":
                guard i + 1 < args.count, let n = Int(args[i + 1]) else { return nil }
                pass = n; i += 2
            default:
                i += 1
            }
        }
        guard let sid else { return nil }
        return RetranscribeCommand(sessionId: sid, locale: locale, pass: pass)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd swift/swiftcap && swift test --filter RetranscribeCommandTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift
git commit -m "feat(swiftcap): RetranscribeCommand arg parser (--session-id/--locale/--pass)"
```

---

### Task 10: Retranscribe execution: SQLite read + analyzeSequence loop + final.jsonl emit

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift`
- Modify: `swift/swiftcap/Sources/Swiftcap/Swiftcap.swift`
- Modify: `swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift`

- [ ] **Step 1: Write the failing integration test**

Append to `RetranscribeCommandTests.swift`:

```swift
    func testRunWritesFinalJsonlPass2ForSession() async throws {
        // Arrange: tmp DB with one session + one audio_segment whose blob is
        // the synthetic_e5_audio.aiff converted to a CAF on the fly is too
        // heavy for a unit test. Instead, point the retranscribe at a
        // pre-built fixture CAF and stub the SQLite path.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()  // SwiftcapTests
            .deletingLastPathComponent()  // swiftcap
            .deletingLastPathComponent()  // swift
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("test/fixtures/synthetic_e5_audio.aiff")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("fixture missing: \(fixture.path)")
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cmd = RetranscribeCommand(sessionId: 1,
                                      locale: Locale(identifier: "ja-JP"),
                                      pass: 2)
        try await cmd.runForFixture(audioFiles: [fixture], spoolDir: tmp)

        let final = try String(contentsOf: tmp.appendingPathComponent("final.jsonl"))
        XCTAssertTrue(final.contains(#""pass":2"#))
        XCTAssertTrue(final.contains(#""kind":"final""#))
        let state = try String(contentsOf: tmp.appendingPathComponent("state.jsonl"))
        XCTAssertTrue(state.contains(#""kind":"retranscribe_done""#))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd swift/swiftcap && swift test --filter RetranscribeCommandTests`
Expected: FAIL — `runForFixture` undefined.

- [ ] **Step 3: Implement run + runForFixture**

Append to `swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift`:

```swift
@available(macOS 26.0, *)
import AVFoundation
import Speech

@available(macOS 26.0, *)
extension RetranscribeCommand {
    /// Production entry: looks up audio_segments by session_id, expands blobs
    /// to tmp CAFs, calls runForFixture. Caller provides DB path.
    func run(dbPath: String, spoolDir: URL) async throws {
        let blobs = try Self.fetchAudioSegmentBlobs(dbPath: dbPath, sessionId: sessionId)
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftcap-retr-\(sessionId)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        var files: [URL] = []
        for (i, blob) in blobs.enumerated() {
            let f = tmpRoot.appendingPathComponent("seg-\(i).caf")
            try blob.write(to: f)
            files.append(f)
        }
        try await runForFixture(audioFiles: files, spoolDir: spoolDir)
    }

    /// Test-friendly entry: takes already-on-disk audio files and runs them
    /// through one shared SpeechAnalyzer instance via analyzeSequence.
    func runForFixture(audioFiles: [URL], spoolDir: URL) async throws {
        let finalWriter = SpoolWriter(url: spoolDir.appendingPathComponent("final.jsonl"))
        let stateWriter = SpoolWriter(url: spoolDir.appendingPathComponent("state.jsonl"))

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collected: Task<[SpeechTranscriptionResult], Error> = Task {
            var out: [SpeechTranscriptionResult] = []
            for try await result in transcriber.results {
                if !result.isVolatile { out.append(result) }
            }
            return out
        }

        for f in audioFiles {
            let avFile = try AVAudioFile(forReading: f)
            try await analyzer.analyzeSequence(from: avFile)
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let results = try await collected.value

        for r in results {
            let started = r.range.start.seconds
            let ended = r.range.end.seconds
            try finalWriter.append([
                "ts": Date().timeIntervalSince1970,
                "kind": "final",
                "ch": "mic",
                "text": r.text.description,
                "started_at": started,
                "ended_at": ended,
                "language": locale.identifier,
                "pass": pass,
                "session_id": sessionId
            ])
        }
        try stateWriter.append([
            "ts": Date().timeIntervalSince1970,
            "kind": "retranscribe_done",
            "session_id": sessionId
        ])
    }

    fileprivate static func fetchAudioSegmentBlobs(dbPath: String, sessionId: Int) throws -> [Data] {
        // Minimal SQLite read using sqlite3 C API. Avoids adding a Swift
        // SQLite package dependency.
        var dbPtr: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &dbPtr, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = dbPtr else {
            throw NSError(domain: "swiftcap.retranscribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "open db failed: \(dbPath)"])
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT blob FROM audio_segments WHERE session_id=? ORDER BY started_at ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw NSError(domain: "swiftcap.retranscribe", code: 2)
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(sessionId))
        var out: [Data] = []
        while sqlite3_step(s) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(s, 0) {
                let n = sqlite3_column_bytes(s, 0)
                out.append(Data(bytes: bytes, count: Int(n)))
            }
        }
        return out
    }
}
```

Add `import SQLite3` (or for system sqlite3, link via `linkerSettings: [.linkedLibrary("sqlite3")]`) to `swift/swiftcap/Package.swift` if not already present. Inspect Package.swift first; if it doesn't have `linkedLibrary("sqlite3")` for the Swiftcap target, add to its `linkerSettings`:

```swift
.linkedLibrary("sqlite3")
```

Also add at the top of RetranscribeCommand.swift:

```swift
import SQLite3
```

- [ ] **Step 4: Wire subcommand dispatch in Swiftcap.swift main**

Modify `swift/swiftcap/Sources/Swiftcap/Swiftcap.swift`. Replace the entire `static func main() async` body's prologue (above `let coordinator = CaptureCoordinator(...)`) with:

```swift
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv.first == "retranscribe" {
            let subArgs = Array(argv.dropFirst())
            guard let cmd = RetranscribeCommand.parse(args: subArgs) else {
                FileHandle.standardError.write("usage: swiftcap retranscribe --session-id N [--locale ja-JP] [--pass 2]\n".data(using: .utf8)!)
                exit(2)
            }
            let spoolDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWIFTCAP_SPOOL"]
                ?? NSString(string: "~/Library/Application Support/audio-transcription/spool").expandingTildeInPath)
            let dbPath = ProcessInfo.processInfo.environment["DB_PATH"] ?? "db/meeting_log.sqlite"
            do {
                try await cmd.run(dbPath: dbPath, spoolDir: spoolDir)
                exit(0)
            } catch {
                FileHandle.standardError.write("retranscribe failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        // existing code below unchanged
```

- [ ] **Step 5: Run tests**

Run: `cd swift/swiftcap && swift test --filter RetranscribeCommandTests`
Expected: testRunWritesFinalJsonlPass2ForSession PASS (or XCTSkip if fixture missing — that's acceptable).
Run: `cd swift/swiftcap && swift test` full — Expected: all PASS or XCTSkip.

- [ ] **Step 6: Commit**

```bash
git add swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift \
        swift/swiftcap/Sources/Swiftcap/Swiftcap.swift \
        swift/swiftcap/Package.swift \
        swift/swiftcap/Tests/SwiftcapTests/RetranscribeCommandTests.swift
git commit -m "feat(swiftcap): retranscribe subcommand uses analyzeSequence loop, emits pass=2 final.jsonl"
```

---

## Phase 9: web routes (Sinatra)

### Task 11: POST /api/session/boundary and /api/session/mute

**Files:**
- Modify: `web/app.rb`
- Create: `test/web/test_session_control_routes.rb`

- [ ] **Step 1: Write the failing test**

Create `test/web/test_session_control_routes.rb`:

```ruby
# test/web/test_session_control_routes.rb
require 'test/unit'
require 'rack/test'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../../lib/audio_transcription/migrator'

class TestSessionControlRoutes < Test::Unit::TestCase
  include Rack::Test::Methods

  def setup
    @tmp = Dir.mktmpdir('session-routes-')
    @db_path = File.join(@tmp, 'meeting_log.sqlite')
    @spool_dir = File.join(@tmp, 'spool')
    FileUtils.mkdir_p(@spool_dir)
    AudioTranscription::Migrator.new(@db_path).run
    ENV['DB_PATH'] = @db_path
    ENV['SPOOL_DIR'] = @spool_dir
    require_relative '../../web/app'
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    ENV.delete('DB_PATH')
    ENV.delete('SPOOL_DIR')
  end

  def app
    TranscriptionWeb
  end

  def control_lines
    path = File.join(@spool_dir, 'control.jsonl')
    File.exist?(path) ? File.readlines(path) : []
  end

  def test_post_boundary_appends_to_control_jsonl
    post '/api/session/boundary'
    assert_equal 202, last_response.status
    lines = control_lines
    assert_equal 1, lines.size
    parsed = JSON.parse(lines[0])
    assert_equal 'boundary', parsed['kind']
    assert parsed['ts'].is_a?(Float)
  end

  def test_post_mute_appends_to_control_jsonl
    post '/api/session/mute'
    assert_equal 202, last_response.status
    parsed = JSON.parse(control_lines[0])
    assert_equal 'mute_toggle', parsed['kind']
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/web/test_session_control_routes.rb`
Expected: FAIL (404 — routes undefined).

- [ ] **Step 3: Add routes**

Modify `web/app.rb`. After the existing `helpers do ... end` block, add:

```ruby
  helpers do
    def spool_dir
      ENV.fetch('SPOOL_DIR',
        '/Users/bash/Library/Application Support/audio-transcription/spool')
    end

    def append_control(kind)
      path = File.join(spool_dir, 'control.jsonl')
      File.open(path, 'a') do |f|
        f.write({ ts: Time.now.to_f, kind: kind }.to_json + "\n")
      end
    end
  end

  post '/api/session/boundary' do
    append_control('boundary')
    status 202
    content_type :json
    { status: 'queued' }.to_json
  end

  post '/api/session/mute' do
    append_control('mute_toggle')
    status 202
    content_type :json
    { status: 'queued' }.to_json
  end
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rake test TEST=test/web/test_session_control_routes.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app.rb test/web/test_session_control_routes.rb
git commit -m "feat(web): POST /api/session/boundary and /api/session/mute append to control.jsonl"
```

---

### Task 12: GET /api/session/current and /api/session/recent

**Files:**
- Modify: `web/app.rb`
- Modify: `test/web/test_session_control_routes.rb`

- [ ] **Step 1: Write failing tests**

Append to `test/web/test_session_control_routes.rb`:

```ruby
  def test_get_current_returns_active_session
    db = SQLite3::Database.new(@db_path)
    db.execute("INSERT INTO sessions(started_at, status) VALUES (?, 'active')", [1234.5])
    sid = db.last_insert_row_id
    db.close
    get '/api/session/current'
    assert_equal 200, last_response.status
    parsed = JSON.parse(last_response.body)
    assert_equal sid, parsed['id']
    assert_equal 'active', parsed['status']
  end

  def test_get_current_returns_404_when_no_active
    get '/api/session/current'
    assert_equal 404, last_response.status
  end

  def test_get_recent_returns_sessions_desc
    db = SQLite3::Database.new(@db_path)
    db.execute("INSERT INTO sessions(started_at, status) VALUES (?, 'done')", [1.0])
    db.execute("INSERT INTO sessions(started_at, status) VALUES (?, 'finalized')", [2.0])
    db.execute("INSERT INTO sessions(started_at, status) VALUES (?, 'active')", [3.0])
    db.close
    get '/api/session/recent'
    assert_equal 200, last_response.status
    parsed = JSON.parse(last_response.body)
    assert_equal 3, parsed.size
    assert_equal 3.0, parsed[0]['started_at']
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rake test TEST=test/web/test_session_control_routes.rb`
Expected: FAIL — 404 for both routes.

- [ ] **Step 3: Add routes**

Append to `web/app.rb` (after the boundary/mute routes):

```ruby
  get '/api/session/current' do
    content_type :json
    row = db.get_first_row(<<~SQL)
      SELECT id, started_at, ended_at, status FROM sessions
      WHERE status='active' ORDER BY started_at DESC LIMIT 1
    SQL
    halt 404 unless row
    row.to_json
  end

  get '/api/session/recent' do
    content_type :json
    rows = db.execute(<<~SQL, [10])
      SELECT id, started_at, ended_at, status FROM sessions
      ORDER BY started_at DESC LIMIT ?
    SQL
    rows.to_json
  end
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rake test TEST=test/web/test_session_control_routes.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app.rb test/web/test_session_control_routes.rb
git commit -m "feat(web): GET /api/session/current and /api/session/recent"
```

---

## Phase 10: web retranscribe worker thread

### Task 13: Background worker spawning swiftcap retranscribe

**Files:**
- Modify: `web/app.rb`
- Create: `test/web/test_retranscribe_worker.rb`

- [ ] **Step 1: Write failing test**

Create `test/web/test_retranscribe_worker.rb`:

```ruby
# test/web/test_retranscribe_worker.rb
require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'sqlite3'
require_relative '../../lib/audio_transcription/migrator'

class TestRetranscribeWorker < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir('retr-worker-')
    @db_path = File.join(@tmp, 'meeting_log.sqlite')
    @run_dir = File.join(@tmp, 'tmp/run')
    FileUtils.mkdir_p(@run_dir)
    AudioTranscription::Migrator.new(@db_path).run
    require_relative '../../web/app'
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_pick_finalized_session_returns_oldest_finalized
    db = SQLite3::Database.new(@db_path)
    db.execute("INSERT INTO sessions(started_at, ended_at, status) VALUES (?, ?, 'done')", [1.0, 2.0])
    db.execute("INSERT INTO sessions(started_at, ended_at, status) VALUES (?, ?, 'finalized')", [3.0, 4.0])
    db.execute("INSERT INTO sessions(started_at, ended_at, status) VALUES (?, ?, 'finalized')", [5.0, 6.0])
    db.close
    sid = TranscriptionWeb::RetranscribeWorker.new(db_path: @db_path, run_dir: @run_dir, spawn: ->(_id) { -1 }).pick_one
    assert_not_nil sid
    db = SQLite3::Database.new(@db_path, readonly: true)
    started = db.get_first_row('SELECT started_at FROM sessions WHERE id=?', [sid])[0]
    db.close
    assert_equal 3.0, started
  end

  def test_pick_one_skips_when_pidfile_alive
    db = SQLite3::Database.new(@db_path)
    db.execute("INSERT INTO sessions(started_at, ended_at, status) VALUES (?, ?, 'finalized')", [1.0, 2.0])
    sid = db.last_insert_row_id
    db.close
    File.write(File.join(@run_dir, "retranscribe-#{sid}.pid"), Process.pid.to_s)
    spawned = []
    res = TranscriptionWeb::RetranscribeWorker.new(db_path: @db_path, run_dir: @run_dir, spawn: ->(id) { spawned << id; 999 }).pick_one
    assert_equal sid, res, 'pick_one returns the session even if its pidfile is alive (caller decides to skip spawn)'
    assert spawned.empty?, 'no spawn while pidfile alive'
  end

  def test_pick_one_spawns_when_pidfile_stale
    db = SQLite3::Database.new(@db_path)
    db.execute("INSERT INTO sessions(started_at, ended_at, status) VALUES (?, ?, 'finalized')", [1.0, 2.0])
    sid = db.last_insert_row_id
    db.close
    File.write(File.join(@run_dir, "retranscribe-#{sid}.pid"), '99999999')  # almost certainly not alive
    spawned = []
    TranscriptionWeb::RetranscribeWorker.new(db_path: @db_path, run_dir: @run_dir, spawn: ->(id) { spawned << id; 12345 }).pick_one
    assert_equal [sid], spawned
    assert_equal '12345', File.read(File.join(@run_dir, "retranscribe-#{sid}.pid")).strip
    db = SQLite3::Database.new(@db_path, readonly: true)
    status = db.get_first_row('SELECT status FROM sessions WHERE id=?', [sid])[0]
    db.close
    assert_equal 'transcribing', status
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rake test TEST=test/web/test_retranscribe_worker.rb`
Expected: FAIL (`RetranscribeWorker` undefined).

- [ ] **Step 3: Implement worker class**

Append to `web/app.rb`:

```ruby
  class RetranscribeWorker
    def initialize(db_path:, run_dir:, spawn: nil)
      @db_path = db_path
      @run_dir = run_dir
      @spawn = spawn || ->(sid) {
        Process.spawn('swiftcap', 'retranscribe', '--session-id', sid.to_s,
                      out: STDOUT, err: STDERR)
      }
      FileUtils.mkdir_p(@run_dir)
    end

    def pick_one
      db = SQLite3::Database.new(@db_path)
      begin
        row = db.get_first_row(<<~SQL)
          SELECT id FROM sessions WHERE status='finalized'
          ORDER BY ended_at ASC LIMIT 1
        SQL
        return nil unless row
        sid = row[0]
        pidfile = File.join(@run_dir, "retranscribe-#{sid}.pid")
        if File.exist?(pidfile) && pid_alive?(File.read(pidfile).to_i)
          return sid
        end
        db.execute("UPDATE sessions SET status='transcribing' WHERE id=?", [sid])
        pid = @spawn.call(sid)
        File.write(pidfile, pid.to_s)
        Process.detach(pid) if pid > 0
        sid
      ensure
        db.close
      end
    end

    private

    def pid_alive?(pid)
      return false if pid <= 0
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end
```

Also add `require 'fileutils'` at the top if not already present.

Wire the worker as a thread on app boot — append after class body:

```ruby
  unless ENV['SKIP_RETRANSCRIBE_WORKER']
    Thread.new do
      worker = RetranscribeWorker.new(
        db_path: ENV.fetch('DB_PATH', 'db/meeting_log.sqlite'),
        run_dir: File.expand_path('../tmp/run', __dir__))
      loop do
        begin
          worker.pick_one
        rescue StandardError => e
          warn "retranscribe worker error: #{e.class}: #{e.message}"
        end
        sleep 5
      end
    end
  end
```

The test will set `ENV['SKIP_RETRANSCRIBE_WORKER']=1` to disable the auto-thread; update `setup`:

```ruby
    ENV['SKIP_RETRANSCRIBE_WORKER'] = '1'
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rake test TEST=test/web/test_retranscribe_worker.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app.rb test/web/test_retranscribe_worker.rb
git commit -m "feat(web): retranscribe worker spawns swiftcap retranscribe with pidfile mutex"
```

---

## Phase 11: Web UI (HTML + PicoRuby:wasm)

### Task 14: Session control bar HTML + CSS

**Files:**
- Modify: `web/views/index.erb`
- Modify: `web/assets/style.css`

- [ ] **Step 1: Add HTML to index.erb**

In `web/views/index.erb`, immediately inside `<body>` at the very top, add:

```html
<header class="session-bar">
  <span class="session-label">Session #<span id="session-id">--</span></span>
  <span class="session-started" id="session-started">--</span>
  <span class="rec-state" id="rec-state">●REC</span>
  <button id="boundary-btn" type="button">区切る</button>
  <button id="mute-btn" type="button" data-muted="false">🎤 ミュート</button>
  <span class="recent-sessions" id="recent-sessions"></span>
</header>
```

- [ ] **Step 2: Add CSS**

Append to `web/assets/style.css`:

```css
.session-bar {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 8px 16px;
  background: #111;
  color: #eee;
  font-size: 13px;
  z-index: 100;
}
.session-bar .session-label { font-weight: bold; }
.session-bar .rec-state { color: #f55; }
.session-bar .rec-state.muted { color: #888; }
.session-bar button {
  padding: 4px 10px;
  background: #333;
  color: #eee;
  border: 1px solid #555;
  border-radius: 4px;
  cursor: pointer;
}
.session-bar button:hover { background: #444; }
.session-bar button[data-muted="true"] { background: #663; }
.session-bar .recent-sessions { margin-left: auto; font-size: 11px; opacity: 0.8; }
.session-bar .recent-sessions .badge { margin-right: 6px; }
body { padding-top: 40px; }
```

- [ ] **Step 3: Restart web and visually verify**

Run: `bundle exec rake stop:web; bundle exec rake start:web; sleep 2; curl -s localhost:9292/ | grep session-bar`
Expected: header HTML appears in the rendered index.

- [ ] **Step 4: Commit**

```bash
git add web/views/index.erb web/assets/style.css
git commit -m "feat(web): session control bar HTML + CSS"
```

---

### Task 15: PicoRuby:wasm button + WebSocket handlers

**Files:**
- Modify: `web/assets/app.rb`

- [ ] **Step 1: Read existing app.rb to find WebSocket dispatch and pane update sites**

Run: `wc -l web/assets/app.rb && grep -n 'on_message\|WebSocket\|push_perfect\|push_quick\|case kind' web/assets/app.rb`

Identify the function or block where incoming WebSocket messages are dispatched by `kind` / `type`.

- [ ] **Step 2: Add boundary / mute click handlers and WS dispatch arms**

At the end of `web/assets/app.rb` (or in the appropriate dispatch block), add:

```ruby
# Session control bar wiring
def post_control(path)
  JS.global.fetch(path, JS.global.Object.new.tap { |o| o[:method] = 'POST' })
end

JS.global[:document].getElementById('boundary-btn')
  .addEventListener('click') { post_control('/api/session/boundary') }

JS.global[:document].getElementById('mute-btn')
  .addEventListener('click') { post_control('/api/session/mute') }

# Header state updaters (called from WebSocket dispatch below)
def update_session_header(id, started_at, status)
  doc = JS.global[:document]
  doc.getElementById('session-id')[:textContent] = id.to_s
  if started_at
    t = JS.global[:Date].new(started_at * 1000)
    doc.getElementById('session-started')[:textContent] = "開始 #{t.toLocaleTimeString.to_s}"
  end
  rec = doc.getElementById('rec-state')
  rec[:textContent] = status == 'active' ? '●REC' : status
end

def update_mute_button(muted)
  btn = JS.global[:document].getElementById('mute-btn')
  btn[:dataset][:muted] = muted ? 'true' : 'false'
  btn[:textContent] = muted ? '🔇 ミュート中' : '🎤 ミュート'
  rec = JS.global[:document].getElementById('rec-state')
  rec[:className] = muted ? 'rec-state muted' : 'rec-state'
end
```

In the existing WebSocket message dispatch (where the script handles `data.type`), add these arms:

```ruby
case msg['type']
# ... existing arms ...
when 'session_started'
  update_session_header(msg['data']['session_id'], msg['data']['session_started_at'], 'active')
when 'session_finalized'
  refresh_recent_sessions
when 'mute_changed'
  update_mute_button(msg['data']['mic_muted'] == true)
when 'retranscribe_done'
  refresh_recent_sessions
end
```

Add the `refresh_recent_sessions` helper:

```ruby
def refresh_recent_sessions
  JS.global.fetch('/api/session/recent').then do |resp|
    resp.json.then do |arr|
      el = JS.global[:document].getElementById('recent-sessions')
      el[:innerHTML] = ''
      arr.to_a.first(5).each do |s|
        sym = case s['status']
              when 'transcribing' then '⏳'
              when 'done'         then '✅'
              when 'finalized'    then '🟡'
              else                     '●'
              end
        span = JS.global[:document].createElement('span')
        span[:className] = 'badge'
        span[:textContent] = "##{s['id']} #{sym}"
        el.appendChild(span)
      end
    end
  end
end
```

Call `refresh_recent_sessions` once at boot (right after the addEventListener calls).

Also, on initial load, fetch `/api/session/current` to populate the header:

```ruby
JS.global.fetch('/api/session/current').then do |resp|
  if resp[:ok]
    resp.json.then do |s|
      update_session_header(s['id'], s['started_at'], s['status'])
    end
  end
end
refresh_recent_sessions
```

- [ ] **Step 3: Manual smoke test**

Restart web. In Chrome devtools console:

```js
fetch('/api/session/boundary', {method:'POST'})
fetch('/api/session/mute', {method:'POST'})
```

Verify the header updates (session id changes, mute button toggles). If `swiftcap` isn't running there's no real session row — OK to verify just the POST → HTTP 202 round trip and visual button toggle from any synthetic WebSocket message via the `/_internal/notify` endpoint:

```bash
curl -X POST localhost:9292/_internal/notify -H 'Content-Type: application/json' \
  -d '{"type":"mute_changed","data":{"mic_muted":true}}'
```

Expected: mute button shows 🔇 ミュート中.

- [ ] **Step 4: Commit**

```bash
git add web/assets/app.rb
git commit -m "feat(web): wire session control bar buttons + WebSocket handlers in PicoRuby app"
```

---

## Phase 12: Verification

### Task 16: Existing test suites green

- [ ] **Step 1: Run Ruby tests**

Run: `bundle exec rake test` (full suite)
Expected: all PASS, no regression in test_filter_audio_state.rb / test_out_sqlite_meeting_log.rb / test_recent_api.rb / test_internal_notify.rb / test_live_websocket.rb / test_index_cache_busting.rb / test_chiebukuro_compat.rb / test_rake_lifecycle.rb / test_synthetic_e5_*.

If `test_out_sqlite_meeting_log.rb` fails because gap-based `ensure_session` was removed, update its assertions to match the new explicit-session-from-record behavior. (This is the only known regression risk.)

- [ ] **Step 2: Run Swift tests**

Run: `cd swift/swiftcap && swift test`
Expected: all PASS or XCTSkip-on-fixture-missing.

- [ ] **Step 3: Commit any test fixups**

```bash
git add test/
git commit -m "test: align legacy out_sqlite tests with explicit-session-id behavior"
```

(Skip if no fixups needed.)

---

### Task 17: mini-E5 5-run regression check

- [ ] **Step 1: Run the long-batch E5 5×**

Use the long-batch pattern (CLAUDE.md ~/dev/src):

```bash
mkdir -p tmp/longrun
screen -dmS e5-session-control-baseline bash -c '
  for i in 1 2 3 4 5; do
    echo "=== run $i ===" >> tmp/longrun/e5-session-control-baseline.log
    bundle exec rake test:e5_synthetic >> tmp/longrun/e5-session-control-baseline.log 2>&1
    echo "exit=$?" >> tmp/longrun/e5-session-control-baseline.log
  done
  echo "DONE: exit=0" >> tmp/longrun/e5-session-control-baseline.log
'
```

Wait for completion (poll `grep ^DONE: tmp/longrun/e5-session-control-baseline.log`).

- [ ] **Step 2: Tally**

Run: `grep -c "all 5 layers verified" tmp/longrun/e5-session-control-baseline.log`
Expected: ≥ 4 (matching backlog necessary-condition: ≥ 4/5 PASS).

If < 4, debug per CLAUDE.md Debug Principles: record exact symptom, form max-3 hypotheses, verify one at a time. Common suspects: schema migration breaking existing path, fluent.conf typo, session_started_at mismatch.

- [ ] **Step 3: Commit log evidence to spec**

Append a "Verification 結果" section to the spec doc:

```markdown
## Verification 結果 (mini-E5)

5-run baseline: <N>/5 PASS (log: tmp/longrun/e5-session-control-baseline.log)
```

```bash
git add docs/superpowers/specs/2026-05-07-web-session-control-and-rollover.md
git commit -m "docs: record mini-E5 5-run verification result"
```

---

### Task 18: 30s real-meeting smoke test

- [ ] **Step 1: Start the full stack**

```bash
bundle exec rake start:all
sleep 5
bundle exec rake status
```

Expected: swiftcap, fluentd, web all running.

- [ ] **Step 2: Trigger a session boundary**

Open `localhost:9292/`. Speak / play `say -v Kyoko こんにちは` for ~30s. Click `区切る`. Click `区切る` again to finalize the second session. Wait ~30s for retranscribe to complete.

- [ ] **Step 3: Verify DB**

```bash
sqlite3 db/meeting_log.sqlite \
  "SELECT id, started_at, ended_at, status FROM sessions ORDER BY id"
sqlite3 db/meeting_log.sqlite \
  "SELECT session_id, channel, pass, raw_text FROM transcripts ORDER BY id LIMIT 20"
sqlite3 db/meeting_log.sqlite \
  "SELECT session_id, channel, started_at FROM audio_segments ORDER BY id"
```

Expected:
- ≥ 2 sessions, all with status='done' or 'transcribing'
- transcripts has rows with pass=1 (live) and pass=2 (retranscribe) sharing session_id
- audio_segments rows have non-null session_id

- [ ] **Step 4: Verify UI**

Open `localhost:9292/`. Verify Quick / Perfect / Graph all show data. Recent sessions strip shows ✅ for done sessions.

- [ ] **Step 5: Manual mute toggle**

Click `🎤 ミュート`. Speak. Verify no new mic-channel rows appear in `transcripts` (screen channel rows continue if there's screen audio). Click again to unmute. Verify mic rows resume.

- [ ] **Step 6: Stop stack and commit verification log**

```bash
bundle exec rake stop:all
```

Append the verified results to the spec's "Verification 結果" section, then:

```bash
git add docs/superpowers/specs/2026-05-07-web-session-control-and-rollover.md
git commit -m "docs: record 30s real-meeting + mute toggle verification result"
```

---

### Task 19: Merge gate

- [ ] **Step 1: Confirm necessary conditions from backlog**

Walk through `docs/superpowers/specs/2026-05-07-next-version-backlog.md` § 必達条件 (絶対必須):

- [ ] `bundle exec rake test` green
- [ ] `cd swift/swiftcap && swift test` green
- [ ] mini-E5 ≥ 4/5
- [ ] 30s real-meeting Quick/Perfect/Graph all live
- [ ] `SELECT COUNT(*) FROM entity_edges` ≥ pre-branch baseline

- [ ] **Step 2: PR**

```bash
git push -u origin feat/web-session-control-and-rollover-2026-05-07
gh pr create --title "feat: web-controlled session boundary + rollover + mute" \
  --body "$(cat <<'EOF'
## Summary
- session lifecycle controlled from web (Sinatra) via spool/control.jsonl
- swiftcap reads control.jsonl with FSEvents-style polling, finalizes/restarts CAFs on boundary
- `swiftcap retranscribe --session-id N` runs SpeechAnalyzer.analyzeSequence over the session's CAFs and emits pass=2 final.jsonl rows
- new schema columns: sessions.status, audio_segments.session_id, transcripts.pass

## Test plan
- [ ] bundle exec rake test
- [ ] cd swift/swiftcap && swift test
- [ ] mini-E5 5/5
- [ ] 30s real-meeting verify
- [ ] mute toggle verify
EOF
)"
```

(User may push manually instead — this step is template only.)

---

## Self-Review Notes

Spec coverage walk:

- 必達条件 → Phase 12 verification tasks
- State machine (recording/muted, boundary rollover) → Phases 3, 6, 7
- control.jsonl + FSEvents → Phases 5, 6
- Long-form transcription (analyzeSequence) → Phase 8
- Web (Sinatra routes + worker) → Phases 9, 10
- DB schema delta → Phase 0
- UI session bar → Phase 11
- Failure semantics: stale active session on swiftcap startup not yet covered explicitly. Covered by Task 5 emitting session_started which `ensure_session_by_started_at` upserts; old `status='active'` rows from a crashed run remain — workaround documented in spec, Phase 1 manual cleanup acceptable.
- mini-E5 regression → Task 17

No placeholders. Type/method names consistent (handleBoundary, handleMuteToggle, ensure_session_by_started_at, RetranscribeWorker, RetranscribeCommand, ControlReader, SessionTracker, refresh_recent_sessions).

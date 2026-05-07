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
    d.run do
      d.feed('audio.state', Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => 2000.0, 'ts' => 2000.0
      })
      d.feed('audio.final', Fluent::EventTime.now, {
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
    d.run do
      d.feed('audio.state', Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => 3000.0, 'ts' => 3000.0
      })
      d.feed('audio.final', Fluent::EventTime.now, {
        'kind' => 'final', 'ch' => 'mic', 'text' => 'live',
        'started_at' => 3010.0, 'ended_at' => 3020.0,
        'session_started_at' => 3000.0, 'pass' => 1
      })
      d.feed('audio.final', Fluent::EventTime.now, {
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

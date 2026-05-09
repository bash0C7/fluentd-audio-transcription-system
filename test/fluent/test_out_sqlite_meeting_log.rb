# test/fluent/test_out_sqlite_meeting_log.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_sqlite_meeting_log'
require 'tmpdir'
require 'fileutils'
require 'sqlite3'
require_relative '../../lib/audio_transcription/migrator'

class TestOutSqliteMeetingLog < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('out-sqlite-')
    @db_path = File.join(@tmp, 'm.sqlite')
    @caf_path = File.join(@tmp, 'mic-1.caf')
    AudioTranscription::Migrator.new(@db_path).run
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver
    Fluent::Test::Driver::Output.new(Fluent::Plugin::SqliteMeetingLogOutput)
      .configure(<<~CONF)
        db_path #{@db_path}
      CONF
  end

  def test_writes_quick_event_idempotently_no_persistence
    d = create_driver
    d.run(default_tag: 'audio.quick') do
      d.feed(Fluent::EventTime.now, { 'ch' => 'mic', 'text' => 'volatile preview', 'transcript_id' => 'u1' })
    end
    db = SQLite3::Database.new(@db_path, readonly: true)
    begin
      count = db.execute("SELECT COUNT(*) FROM transcripts").flatten.first
      assert_equal 0, count, 'volatile must not persist'
    ensure
      db.close
    end
  end

  def test_writes_final_creates_transcript_and_entities
    d = create_driver
    now = Time.now.to_f
    sat = now - 100.0
    d.run do
      d.feed('audio.state', Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => sat, 'ts' => sat
      })
      d.feed('audio.final', Fluent::EventTime.now, {
        'ch' => 'mic', 'kind' => 'final', 'text' => 'こんにちは',
        'started_at' => now, 'ended_at' => now + 1.0, 'language' => 'ja',
        'transcript_id' => 'u-final-1', 'polished_text' => 'こんにちは。',
        'session_started_at' => sat,
        'entities' => [{'text' => 'こんにちは', 'kind' => 'term'}]
      })
    end
    db = SQLite3::Database.new(@db_path, readonly: true)
    db.results_as_hash = true
    begin
      transcripts = db.execute("SELECT * FROM transcripts")
      sessions = db.execute("SELECT * FROM sessions")
      entities = db.execute("SELECT * FROM entities")
      assert_equal 1, transcripts.size
      assert_equal 1, sessions.size
      assert_equal 'こんにちは。', transcripts.first['polished_text']
      assert_equal 1, entities.size
    ensure
      db.close
    end
  end

  def test_final_persists_nonzero_started_and_ended_at
    d = create_driver
    started_at = 5000.123
    ended_at = 5005.456
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, {
        'ch' => 'screen', 'kind' => 'final', 'text' => 'hello',
        'started_at' => started_at, 'ended_at' => ended_at, 'language' => 'ja-JP',
        'transcript_id' => 'u-final-time'
      })
    end
    db = SQLite3::Database.new(@db_path, readonly: true)
    db.results_as_hash = true
    begin
      row = db.execute('SELECT started_at, ended_at, language FROM transcripts WHERE swiftcap_transcript_id=?', ['u-final-time']).first
      assert_not_nil row
      assert_in_delta started_at, row['started_at'], 0.001
      assert_in_delta ended_at, row['ended_at'], 0.001
      assert_equal 'ja-JP', row['language']
    ensure
      db.close
    end
  end

  def test_segment_unlinks_caf_after_insert
    File.binwrite(@caf_path, "fakecaf")
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'rotated', 'channel' => 'mic', 'path' => @caf_path,
        'started_at' => 1.0, 'ended_at' => 2.0,
        'duration_sec' => 1.0, 'codec' => 'aac', 'sample_rate' => 16000,
        'bytes' => 7, 'blob' => "fakecaf"
      })
    end
    assert !File.exist?(@caf_path), "CAF should have been deleted by out_sqlite_meeting_log after insert"
  end

  def test_session_started_at_creates_distinct_sessions_per_started_at
    d = create_driver
    t0 = 1000.0
    t1 = 2000.0
    d.run do
      d.feed('audio.state', Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => t0, 'ts' => t0
      })
      d.feed('audio.state', Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => t1, 'ts' => t1
      })
      d.feed('audio.final', Fluent::EventTime.now, {
        'ch' => 'mic', 'kind' => 'final', 'text' => 'a',
        'started_at' => t0 + 1, 'ended_at' => t0 + 2,
        'session_started_at' => t0, 'transcript_id' => 'a'
      })
      d.feed('audio.final', Fluent::EventTime.now, {
        'ch' => 'mic', 'kind' => 'final', 'text' => 'b',
        'started_at' => t1 + 1, 'ended_at' => t1 + 2,
        'session_started_at' => t1, 'transcript_id' => 'b'
      })
    end
    db = SQLite3::Database.new(@db_path, readonly: true)
    begin
      sessions = db.execute("SELECT COUNT(*) FROM sessions").flatten.first
      assert_equal 2, sessions
    ensure
      db.close
    end
  end
end

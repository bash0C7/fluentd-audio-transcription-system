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
    ENV['SKIP_RETRANSCRIBE_WORKER'] = '1'
    require_relative '../../web/app'
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    ENV.delete('SKIP_RETRANSCRIBE_WORKER')
  end

  def test_pick_one_returns_oldest_finalized
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

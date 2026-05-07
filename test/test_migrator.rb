# test/test_migrator.rb
require 'test/unit'
require 'fileutils'
require 'tmpdir'
require 'sqlite3'
require_relative '../lib/audio_transcription/migrator'
class TestMigrator < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir('migrator-test-')
    @db_path = File.join(@tmp, 'meeting_log.sqlite')
  end
  def teardown
    FileUtils.remove_entry(@tmp)
  end
  def test_run_applies_initial_migration
    AudioTranscription::Migrator.new(@db_path).run
    db = SQLite3::Database.new(@db_path, readonly: true)
    begin
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").flatten
      assert_includes tables, 'audio_segments'
      assert_includes tables, 'transcripts'
      assert_includes tables, '_sqlite_mcp_meta'
    ensure
      db.close
    end
  end
  def test_run_is_idempotent
    AudioTranscription::Migrator.new(@db_path).run
    db = SQLite3::Database.new(@db_path, readonly: true)
    count_after_first = nil
    begin
      count_after_first = db.execute("SELECT COUNT(*) FROM applied_migrations").flatten.first
    ensure
      db.close
    end
    AudioTranscription::Migrator.new(@db_path).run
    db = SQLite3::Database.new(@db_path, readonly: true)
    begin
      count_after_second = db.execute("SELECT COUNT(*) FROM applied_migrations").flatten.first
      assert_equal count_after_first, count_after_second
    ensure
      db.close
    end
  end
  def test_meta_descriptions_present
    AudioTranscription::Migrator.new(@db_path).run
    db = SQLite3::Database.new(@db_path, readonly: true)
    begin
      rows = db.execute("SELECT key FROM _sqlite_mcp_meta ORDER BY key").flatten
      assert_includes rows, 'db:meeting_log'
      assert_includes rows, 'table:transcripts'
    ensure
      db.close
    end
  end

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
end

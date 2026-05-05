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
    AudioTranscription::Migrator.new(@db_path).run
    db = SQLite3::Database.new(@db_path, readonly: true)
    begin
      count = db.execute("SELECT COUNT(*) FROM applied_migrations").flatten.first
      assert_equal 1, count
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
end

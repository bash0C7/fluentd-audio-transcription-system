# test/test_chiebukuro_compat.rb
require 'test/unit'
require 'fileutils'
require 'tmpdir'
require 'sqlite3'
require_relative '../lib/audio_transcription/migrator'

class TestChiebukuroCompat < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir('chiebukuro-compat-')
    @db_path = File.join(@tmp, 'meeting_log.sqlite')
    AudioTranscription::Migrator.new(@db_path).run
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_readonly_open_does_not_raise
    db = SQLite3::Database.new(@db_path, readonly: true)
    db.results_as_hash = true
    begin
      db.execute("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    ensure
      db.close
    end
  end

  def test_meta_table_introspectable
    db = SQLite3::Database.new(@db_path, readonly: true)
    db.results_as_hash = true
    begin
      rows = db.execute("SELECT key, value FROM _sqlite_mcp_meta WHERE key='db:meeting_log'")
      refute_empty rows
      assert_match(/会話/, rows.first['value'])
    ensure
      db.close
    end
  end
end

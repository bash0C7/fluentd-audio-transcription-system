# test/web/test_recent_api.rb
require 'test/unit'
require 'rack/test'
require 'sqlite3'
require 'json'
require 'tmpdir'
require 'fileutils'

REPO_ROOT = File.expand_path('../..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'lib', 'audio_transcription', 'migrator')

class TestRecentApi < Test::Unit::TestCase
  include Rack::Test::Methods

  def app
    @app ||= begin
      ENV['DB_PATH'] = @db_path
      require File.join(REPO_ROOT, 'web', 'app')
      TranscriptionWeb
    end
  end

  def default_host
    'localhost'
  end

  def setup
    @tmp = Dir.mktmpdir('web-test-')
    @db_path = File.join(@tmp, 'test.sqlite')
    ENV['DB_PATH'] = @db_path
    AudioTranscription::Migrator.new(@db_path).run
    seed_rows
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_get_recent_returns_both_mic_and_screen
    get '/api/recent?since=0'
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    channels = body['transcripts'].map { |t| t['channel'] }.uniq.sort
    assert_equal %w[mic screen], channels
  end

  def test_get_recent_excludes_zero_ended_at
    insert_transcript(channel: 'mic', text: 'broken', started_at: 0.0, ended_at: 0.0)
    get '/api/recent?since=0'
    body = JSON.parse(last_response.body)
    assert_false body['transcripts'].any? { |t| t['raw_text'] == 'broken' },
                 '/api/recent must exclude rows with ended_at == 0.0'
  end

  def test_get_recent_with_only_mic_transcripts_returns_mic_only
    db = SQLite3::Database.new(@db_path)
    db.execute("DELETE FROM transcripts WHERE channel='screen'")
    db.close
    get '/api/recent?since=0'
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    channels = body['transcripts'].map { |t| t['channel'] }.uniq
    assert_equal ['mic'], channels
  end

  private

  def seed_rows
    insert_transcript(channel: 'mic',    text: 'hello mic',    started_at: 100.0, ended_at: 105.0)
    insert_transcript(channel: 'screen', text: 'hello screen', started_at: 200.0, ended_at: 210.0)
  end

  def insert_transcript(channel:, text:, started_at:, ended_at:)
    db = SQLite3::Database.new(@db_path)
    db.execute('INSERT INTO sessions (started_at, ended_at) VALUES (?, ?)', [started_at, ended_at])
    sid = db.last_insert_row_id
    db.execute(
      "INSERT INTO transcripts (session_id, channel, raw_text, polished_text, " \
      "started_at, ended_at, language, swiftcap_transcript_id) " \
      "VALUES (?, ?, ?, '', ?, ?, 'ja-JP', ?)",
      [sid, channel, text, started_at, ended_at, "u-#{rand(1_000_000)}"]
    )
    db.close
  end
end

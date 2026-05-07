# test/web/test_session_control_routes.rb
require 'test/unit'
require 'rack/test'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'sqlite3'
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
    ENV['SKIP_RETRANSCRIBE_WORKER'] = '1'
    require_relative '../../web/app'
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    ENV.delete('DB_PATH')
    ENV.delete('SPOOL_DIR')
    ENV.delete('SKIP_RETRANSCRIBE_WORKER')
  end

  def app
    TranscriptionWeb
  end

  def default_host
    'localhost'
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
end

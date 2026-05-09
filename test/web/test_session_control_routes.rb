# test/web/test_session_control_routes.rb
require 'test/unit'
require 'rack/test'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'sqlite3'
require 'socket'
require_relative '../../lib/audio_transcription/migrator'

class TestSessionControlRoutes < Test::Unit::TestCase
  include Rack::Test::Methods

  def setup
    @tmp = Dir.mktmpdir('session-routes-')
    @db_path = File.join(@tmp, 'meeting_log.sqlite')
    @spool_dir = File.join(@tmp, 'spool')
    # macOS unix socket path limit is 104 bytes; use /tmp with short name
    @sock_path = "/tmp/sctest-#{Process.pid}.sock"
    FileUtils.mkdir_p(@spool_dir)
    AudioTranscription::Migrator.new(@db_path).run

    File.delete(@sock_path) if File.exist?(@sock_path)
    @server = UNIXServer.new(@sock_path)
    @ctrl_lines = []
    @ctrl_thread = Thread.new do
      loop do
        client = @server.accept
        client.each_line { |l| @ctrl_lines << l }
        client.close
      rescue StandardError
        break
      end
    end

    ENV['DB_PATH'] = @db_path
    ENV['SPOOL_DIR'] = @spool_dir
    ENV['SWIFTCAP_SOCKET_PATH'] = @sock_path
    ENV['SKIP_RETRANSCRIBE_WORKER'] = '1'
    require_relative '../../web/app'
  end

  def teardown
    @server.close rescue nil
    @ctrl_thread.kill rescue nil
    File.delete(@sock_path) if File.exist?(@sock_path)
    FileUtils.remove_entry(@tmp)
    %w[DB_PATH SPOOL_DIR SWIFTCAP_SOCKET_PATH SKIP_RETRANSCRIBE_WORKER].each { |k| ENV.delete(k) }
  end

  def app
    TranscriptionWeb
  end

  def default_host
    'localhost'
  end

  def test_post_boundary_writes_kind_to_swiftcap_socket
    post '/api/session/boundary'
    assert_equal 202, last_response.status
    sleep 0.1
    assert_equal 1, @ctrl_lines.size
    parsed = JSON.parse(@ctrl_lines.first)
    assert_equal 'boundary', parsed['kind']
  end

  def test_post_mute_writes_mute_toggle_to_swiftcap_socket
    post '/api/session/mute'
    assert_equal 202, last_response.status
    sleep 0.1
    parsed = JSON.parse(@ctrl_lines.first)
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

# test/web/test_live_websocket.rb
#
# Real-puma + real-WebSocket integration test for the live broadcast path.
# rack-test (test_internal_notify.rb) verifies the route's broadcast loop
# in isolation but cannot exercise the WebSocket transport — that's the
# gap that hid the rendering bug surfaced by the 2026-05-06 reverify.
# This test boots puma in a subprocess, opens a real Faye::WebSocket::Client
# to /stream, POSTs to /_internal/notify, and asserts the message arrives.

require 'test/unit'
require 'eventmachine'
require 'faye/websocket'
require 'net/http'
require 'tmpdir'
require 'fileutils'
require 'socket'
require 'json'
require 'timeout'

REPO_ROOT = File.expand_path('../..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'lib', 'audio_transcription', 'migrator')

class TestLiveWebSocket < Test::Unit::TestCase
  PUMA_BOOT_TIMEOUT = 20
  WS_TEST_TIMEOUT   = 10

  def setup
    @tmp = Dir.mktmpdir('ws-e2e-')
    @db_path = File.join(@tmp, 'test.sqlite')
    AudioTranscription::Migrator.new(@db_path).run
    @port = find_free_port
    # Spawn puma directly with CLI flags (no -C web/puma.rb) to avoid the
    # project pidfile and to keep this test self-contained.
    @puma_pid = Process.spawn(
      { 'DB_PATH' => @db_path },
      'bundle', 'exec', 'puma',
      '-b', "tcp://127.0.0.1:#{@port}",
      '-w', '0', '-t', '1:1',
      File.join(REPO_ROOT, 'web', 'config.ru'),
      [:out, :err] => '/dev/null',
      chdir: REPO_ROOT
    )
    wait_for_puma
  end

  def teardown
    if @puma_pid
      Process.kill('TERM', @puma_pid) rescue nil
      begin
        Timeout.timeout(10) { Process.wait(@puma_pid) }
      rescue Timeout::Error
        Process.kill('KILL', @puma_pid) rescue nil
        Process.wait(@puma_pid) rescue nil
      end
    end
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_post_to_internal_notify_broadcasts_to_websocket_client
    received = []
    em_error = nil

    EM.run do
      ws = Faye::WebSocket::Client.new("ws://127.0.0.1:#{@port}/stream")

      ws.on(:open) do |_event|
        # POST runs in its own thread so EM stays responsive for the
        # subsequent broadcast frame.
        Thread.new do
          begin
            Net::HTTP.post(
              URI("http://127.0.0.1:#{@port}/_internal/notify"),
              JSON.generate('type' => 'quick', 'data' => { 'text' => 'PROBE-FROM-TEST' }),
              'Content-Type' => 'application/json'
            )
          rescue => e
            em_error = e
            EM.stop
          end
        end
      end

      ws.on(:message) do |event|
        received << event.data
        ws.close
        EM.stop
      end

      ws.on(:error) do |event|
        em_error = RuntimeError.new("websocket error: #{event.message}")
        EM.stop
      end

      EM.add_timer(WS_TEST_TIMEOUT) { EM.stop }
    end

    raise em_error if em_error
    assert_equal 1, received.size,
                 "expected exactly one broadcast frame, got #{received.size}"

    parsed = JSON.parse(received.first)
    assert_equal 'quick', parsed['type']
    assert_equal 'PROBE-FROM-TEST', parsed['data']['text']
  end

  private

  def find_free_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_for_puma
    deadline = Time.now + PUMA_BOOT_TIMEOUT
    while Time.now < deadline
      begin
        sock = TCPSocket.new('127.0.0.1', @port)
        sock.close
        # Confirm the Sinatra app is actually responding, not just that
        # the listener exists.
        res = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/api/recent?since=0"))
        return if res.code.to_i.between?(200, 299)
      rescue Errno::ECONNREFUSED, EOFError, Errno::EADDRNOTAVAIL
        # not ready yet
      end
      sleep 0.2
    end
    raise "puma did not boot within #{PUMA_BOOT_TIMEOUT}s on port #{@port}"
  end
end

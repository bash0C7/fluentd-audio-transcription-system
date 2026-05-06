# test/web/test_internal_notify.rb
require 'test/unit'
require 'rack/test'
require 'json'

REPO_ROOT = File.expand_path('../..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'web', 'app')

class TestInternalNotify < Test::Unit::TestCase
  include Rack::Test::Methods

  def app
    TranscriptionWeb
  end

  def default_host
    'localhost'
  end

  class FakeWebSocket
    attr_reader :sent_messages
    def initialize; @sent_messages = []; end
    def send(msg); @sent_messages << msg; end
  end

  def teardown
    TranscriptionWeb::WEBSOCKETS.clear
  end

  def test_notify_accepts_valid_json_payload
    payload = { kind: 'final', channel: 'mic', text: 'hello', started_at: 1.0, ended_at: 2.0 }
    post '/_internal/notify', payload.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_includes 200..299, last_response.status,
                    "expected 2xx, got #{last_response.status}: #{last_response.body}"
  end

  def test_notify_broadcasts_to_open_websockets
    fake = FakeWebSocket.new
    TranscriptionWeb::WEBSOCKETS << fake

    post '/_internal/notify', { kind: 'quick', text: 'live' }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }

    assert_equal 1, fake.sent_messages.size
    parsed = JSON.parse(fake.sent_messages.first)
    assert_equal 'quick', parsed['kind']
    assert_equal 'live',  parsed['text']
  end
end

# test/web/test_index_cache_busting.rb
#
# Index page must reference /app.rb with a content-hash query string so
# browser HTTP caching cannot serve a stale PicoRuby:wasm bytecode after
# we ship a new version of web/assets/app.rb.
require 'test/unit'
require 'rack/test'
require 'tmpdir'
require 'fileutils'
require 'digest'

REPO_ROOT = File.expand_path('../..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'lib', 'audio_transcription', 'migrator')

class TestIndexCacheBusting < Test::Unit::TestCase
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
    @tmp = Dir.mktmpdir('web-cache-test-')
    @db_path = File.join(@tmp, 'test.sqlite')
    ENV['DB_PATH'] = @db_path
    AudioTranscription::Migrator.new(@db_path).run
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_index_references_app_rb_with_content_hash_query_string
    get '/'
    assert_equal 200, last_response.status
    assert_match %r{src="/app\.rb\?v=[0-9a-f]{12}"}, last_response.body,
                 'index.erb must include a 12-hex-char SHA-256 prefix as cache-busting query'
  end

  def test_app_rb_version_matches_actual_asset_content
    expected = Digest::SHA256.hexdigest(File.read(File.join(REPO_ROOT, 'web', 'assets', 'app.rb')))[0, 12]
    get '/'
    assert_match %r{src="/app\.rb\?v=#{expected}"}, last_response.body,
                 'version string in index.erb must equal SHA-256(web/assets/app.rb)[0,12]'
  end
end

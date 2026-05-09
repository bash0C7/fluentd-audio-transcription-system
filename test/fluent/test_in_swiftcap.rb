# test/fluent/test_in_swiftcap.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/input'
require 'fluent/plugin/in_swiftcap'
require 'tmpdir'
require 'fileutils'
require 'json'

class TestInSwiftcap < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('in-swiftcap-')
    @bin = File.join(@tmp, 'fake_swiftcap')
    File.write(@bin, <<~SH)
      #!/usr/bin/env bash
      echo '{"stream":"state","ts":1.0,"kind":"swiftcap_ready"}'
      echo '{"stream":"quick","ts":2.0,"ch":"mic","kind":"volatile","text":"hi","transcript_id":"u1","session_started_at":0.0}'
      echo '{"stream":"final","ts":3.0,"ch":"mic","kind":"final","text":"hi.","started_at":1.0,"ended_at":2.0,"language":"ja-JP","transcript_id":"u1","session_started_at":0.0}'
      # Stay alive so the plugin can SIGTERM us at shutdown.
      trap 'exit 0' TERM
      sleep 30
    SH
    FileUtils.chmod(0o755, @bin)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver
    config = %(
      swiftcap_bin #{@bin}
      spool_dir #{@tmp}
      socket_path #{File.join(@tmp, 'swiftcap.sock')}
      ready_timeout 10
    )
    Fluent::Test::Driver::Input.new(Fluent::Plugin::SwiftcapInput).configure(config)
  end

  def test_emits_one_event_per_stream_with_audio_prefix_tag
    d = create_driver
    d.run(timeout: 5, expect_emits: 3, shutdown: true) {}
    events = d.events
    tags = events.map { |t, _, _| t }
    assert_includes tags, 'audio.state'
    assert_includes tags, 'audio.quick'
    assert_includes tags, 'audio.final'

    state_record = events.find { |t, _, _| t == 'audio.state' }[2]
    assert_equal 'swiftcap_ready', state_record['kind']
    assert_nil state_record['stream'], 'stream field should be stripped before emit'

    final_record = events.find { |t, _, _| t == 'audio.final' }[2]
    assert_equal 'hi.', final_record['text']
  end

  def test_fails_start_when_swiftcap_ready_does_not_arrive
    silent_bin = File.join(@tmp, 'silent_swiftcap')
    File.write(silent_bin, "#!/usr/bin/env bash\nsleep 30\n")
    FileUtils.chmod(0o755, silent_bin)
    d = Fluent::Test::Driver::Input.new(Fluent::Plugin::SwiftcapInput).configure(%(
      swiftcap_bin #{silent_bin}
      spool_dir #{@tmp}
      socket_path #{File.join(@tmp, 'silent.sock')}
      ready_timeout 1
    ))
    err = assert_raises(Fluent::ConfigError, RuntimeError, StandardError) do
      d.run(timeout: 5, shutdown: true) {}
    end
    assert_match(/swiftcap_ready/, err.message)
  end
end

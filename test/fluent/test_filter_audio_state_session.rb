# test/fluent/test_filter_audio_state_session.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_audio_state'
require 'fileutils'
require 'tmpdir'

class TestFilterAudioStateSession < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('audio-state-session-')
    @caf = File.join(@tmp, 'mic.caf')
    File.binwrite(@caf, "FAKE_CAF")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::AudioStateFilter).configure('')
  end

  def test_rotated_event_propagates_session_started_at
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'rotated', 'channel' => 'mic', 'path' => @caf,
        'started_at' => 1000.0, 'ended_at' => 1030.0,
        'session_started_at' => 950.5
      })
    end
    rec = d.filtered_records.first
    assert_equal 950.5, rec['session_started_at']
  end

  def test_session_started_kind_is_passed_through
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_started', 'session_started_at' => 950.5, 'ts' => 950.5
      })
    end
    rec = d.filtered_records.first
    assert_not_nil rec
    assert_equal 'session_started', rec['kind']
    assert_equal 950.5, rec['session_started_at']
  end

  def test_session_finalized_kind_is_passed_through
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'session_finalized', 'session_started_at' => 950.5,
        'ended_at' => 1100.0, 'ts' => 1100.0
      })
    end
    rec = d.filtered_records.first
    assert_not_nil rec
    assert_equal 'session_finalized', rec['kind']
    assert_equal 1100.0, rec['ended_at']
  end

  def test_mute_changed_kind_is_passed_through
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'mute_changed', 'session_started_at' => 950.5,
        'mic_muted' => true, 'ts' => 1010.0
      })
    end
    rec = d.filtered_records.first
    assert_not_nil rec
    assert_equal 'mute_changed', rec['kind']
    assert_equal true, rec['mic_muted']
  end
end

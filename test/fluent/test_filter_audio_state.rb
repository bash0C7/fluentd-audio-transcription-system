# test/fluent/test_filter_audio_state.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_audio_state'
require 'fileutils'
require 'tmpdir'

class TestFilterAudioState < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('audio-state-')
    @caf = File.join(@tmp, 'mic-20260505-120000.caf')
    File.binwrite(@caf, "FAKE_CAF_BYTES_ ")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver(conf = '')
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::AudioStateFilter).configure(conf)
  end

  def test_rotated_event_loads_blob_and_emits_segment
    d = create_driver
    started_at = 1000.0
    ended_at = 1305.0
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'ts' => Time.now.to_f,
        'kind' => 'rotated',
        'channel' => 'mic',
        'path' => @caf,
        'bytes' => File.size(@caf),
        'started_at' => started_at,
        'ended_at' => ended_at
      })
    end
    events = d.filtered_records
    assert_equal 1, events.size
    rec = events.first
    assert_equal 'mic', rec['channel']
    assert_equal @caf, rec['path']
    assert_equal File.binread(@caf).bytesize, rec['blob'].bytesize
    assert_equal 'aac', rec['codec']
    assert_equal 16000, rec['sample_rate']
    assert_equal started_at, rec['started_at']
    assert_equal ended_at, rec['ended_at']
    assert_in_delta (ended_at - started_at), rec['duration_sec'], 0.001
  end

  def test_rotated_event_without_time_fields_is_dropped
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, {
        'ts' => Time.now.to_f,
        'kind' => 'rotated',
        'channel' => 'mic',
        'path' => @caf,
        'bytes' => File.size(@caf)
      })
    end
    assert_equal 0, d.filtered_records.size, 'rotated event without time fields must be dropped'
  end

  def test_non_rotated_events_are_dropped
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Fluent::EventTime.now, { 'kind' => 'heartbeat' })
    end
    assert_equal 0, d.filtered_records.size
  end
end

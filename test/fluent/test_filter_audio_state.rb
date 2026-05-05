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
    d.run(default_tag: 'audio.state') do
      d.feed(Time.now.to_f, {
        'ts' => Time.now.to_f,
        'kind' => 'rotated',
        'channel' => 'mic',
        'path' => @caf,
        'bytes' => File.size(@caf)
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
  end

  def test_non_rotated_events_are_dropped
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Time.now.to_f, { 'kind' => 'heartbeat' })
    end
    assert_equal 0, d.filtered_records.size
  end
end

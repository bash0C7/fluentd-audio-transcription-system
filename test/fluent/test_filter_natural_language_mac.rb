# test/fluent/test_filter_natural_language_mac.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_natural_language_mac'
require 'tmpdir'
require 'fileutils'

class TestFilterNaturalLanguageMac < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('nl-mac-')
    @stopwords = File.join(@tmp, 'stopwords.yml')
    File.write(@stopwords, "en:\n  - the\n  - a\nja:\n  - その\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::NaturalLanguageMacFilter)
      .configure("stopwords_path #{@stopwords}")
  end

  def test_extracts_noun_entities_and_drops_stopwords
    d = create_driver
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'final',
        'text' => 'The quick brown fox jumps.',
        'language' => 'en'
      })
    end
    rec = d.filtered_records.first
    assert_kind_of Array, rec['entities']
    texts = rec['entities'].map { |e| e['text'] }
    refute_includes texts, 'the'
    refute_includes texts, 'a'
  end
end

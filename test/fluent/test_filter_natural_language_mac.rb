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

  def test_extracts_japanese_tokens_via_tokenizer
    d = create_driver
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'final',
        'text' => '会議の議事録です',
        'language' => 'ja'
      })
    end
    rec = d.filtered_records.first
    assert_kind_of Array, rec['entities']
    texts = rec['entities'].map { |e| e['text'] }
    # NLTokenizer with word unit segments "議事録" into "議事" + "録",
    # so we assert on the leading multi-char span rather than the full
    # compound. Mecab-style morphological analysis is out of scope.
    assert_includes texts, '会議'
    assert_includes texts, '議事'
    refute_includes texts, 'の', 'single-char particle should be dropped by length>=2 filter'
    refute_includes texts, '録', 'single-char fragment should be dropped by length>=2 filter'
  end

  def test_production_stopwords_yml_drops_japanese_filler_words
    prod = File.expand_path('../../../config/stopwords.yml', __FILE__)
    d = Fluent::Test::Driver::Filter.new(Fluent::Plugin::NaturalLanguageMacFilter)
      .configure("stopwords_path #{prod}")
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'final',
        'text' => 'うんちょっとですね、ありがとうござい、ますよね。',
        'language' => 'ja'
      })
    end
    rec = d.filtered_records.first
    texts = rec['entities'].map { |e| e['text'] }
    %w[うん ちょっと です ござい ます].each do |w|
      refute_includes texts, w, "filler/auxiliary #{w} must be in production stopwords"
    end
    assert_includes texts, 'ありがとう', 'content word must be retained'
  end

  def test_bcp47_locale_language_codes_apply_stopwords
    prod = File.expand_path('../../../config/stopwords.yml', __FILE__)
    d = Fluent::Test::Driver::Filter.new(Fluent::Plugin::NaturalLanguageMacFilter)
      .configure("stopwords_path #{prod}")
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'final',
        'text' => 'うんちょっとですね、ありがとうござい、ますよね。',
        'language' => 'ja-JP'
      })
    end
    rec = d.filtered_records.first
    texts = rec['entities'].map { |e| e['text'] }
    %w[うん ちょっと です ござい ます].each do |w|
      refute_includes texts, w, "ja-JP must resolve to ja stopwords (BCP-47 region suffix)"
    end
    assert_includes texts, 'ありがとう'
  end
end

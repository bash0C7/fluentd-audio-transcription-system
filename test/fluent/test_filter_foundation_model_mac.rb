# test/fluent/test_filter_foundation_model_mac.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_foundation_model_mac'

class TestFilterFoundationModelMac < Test::Unit::TestCase
  class FakeFM
    def self.generate(prompt:, instructions:); "[polished] #{prompt.split(/\n/).last}"; end
  end

  def setup
    Fluent::Test.setup
  end

  def create_driver
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::FoundationModelMacFilter)
      .configure('')
  end

  def test_polishes_final_text
    d = create_driver
    d.instance.client = FakeFM
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, {
        'kind' => 'final',
        'text' => 'えーっと、その、コードレビューしてもらいたいです'
      })
    end
    rec = d.filtered_records.first
    assert_match(/^\[polished\]/, rec['polished_text'])
  end

  def test_passes_through_non_final
    d = create_driver
    d.instance.client = FakeFM
    d.run(default_tag: 'audio.final') do
      d.feed(Fluent::EventTime.now, { 'kind' => 'volatile', 'text' => 'foo' })
    end
    rec = d.filtered_records.first
    assert_nil rec['polished_text']
  end
end

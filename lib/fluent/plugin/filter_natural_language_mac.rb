# lib/fluent/plugin/filter_natural_language_mac.rb
require 'set'
require 'fluent/plugin/filter'
require 'natural_language_mac'
require 'yaml'

module Fluent
  module Plugin
    class NaturalLanguageMacFilter < Fluent::Plugin::Filter
      Fluent::Plugin.register_filter('natural_language_mac', self)

      config_param :stopwords_path, :string

      NOUN_TAGS = %w[Noun PersonalName PlaceName OrganizationName].freeze

      def configure(conf)
        super
        data = YAML.load_file(@stopwords_path) || {}
        @stopwords = {}
        data.each { |lang, words| @stopwords[lang.to_s] = (words || []).map(&:downcase).to_set }
      end

      def filter(_tag, _time, record)
        return record unless record['kind'] == 'final'
        text = record['text'].to_s
        return record if text.empty?
        lang = record['language'] || 'ja'
        tagged = NaturalLanguageMac.tag(text)
        words = []
        tagged.each_line do |line|
          token, kind = line.strip.split("\t", 2)
          next unless kind && NOUN_TAGS.include?(kind)
          next if @stopwords[lang]&.include?(token.downcase)
          words << { 'text' => token, 'kind' => kind == 'Noun' ? 'term' : kind.downcase }
        end
        record.merge('entities' => words)
      end
    end
  end
end

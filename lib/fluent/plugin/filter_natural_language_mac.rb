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

      def configure(conf)
        super
        data = YAML.load_file(@stopwords_path) || {}
        @stopwords = {}
        data.each { |lang, words| @stopwords[lang.to_s] = (words || []).map { |w| w.to_s.downcase }.to_set }
      end

      def filter(_tag, _time, record)
        return record unless record['kind'] == 'final'
        text = record['text'].to_s
        return record if text.empty?
        lang = record['language'] || 'ja'
        # NLTagger(.lexicalClass / .nameType) returns Other for every
        # Japanese token (verified empirically with xcrun swift), so we
        # rely on NLTokenizer + stopwords + length>=2 to populate
        # entities for both Japanese and English. See
        # docs/superpowers/specs/2026-05-06-release-quality-graph-and-mic-quality.md.
        words = NaturalLanguageMac.tokenize(text).each_line.filter_map do |line|
          token = line.strip
          next if token.length < 2
          next if @stopwords[lang]&.include?(token.downcase)
          { 'text' => token, 'kind' => 'term' }
        end
        record.merge('entities' => words)
      end
    end
  end
end

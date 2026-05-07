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
        # fluentd boots with `-Eascii-8bit:ascii-8bit`, which makes
        # YAML/json strings ASCII-8BIT. Set#include? is encoding-aware
        # so ASCII-8BIT 'けど' != UTF-8 'けど' and the NLTokenizer's
        # UTF-8 tokens silently miss. Re-tag every external string as
        # UTF-8 via force_utf8 below.
        data = YAML.load_file(@stopwords_path) || {}
        @stopwords = data.transform_keys(&:to_s).transform_values do |words|
          (words || []).map { |w| force_utf8(w).downcase }.to_set
        end
      end

      def filter(_tag, _time, record)
        return record unless record['kind'] == 'final'
        text = record['text'].to_s
        return record if text.empty?
        lang = force_utf8(record['language'] || 'ja').split('-').first.downcase
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

      private

      def force_utf8(s)
        s.to_s.dup.force_encoding(Encoding::UTF_8)
      end
    end
  end
end

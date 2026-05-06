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
        # YAML.load_file tag strings as ASCII-8BIT. Set membership is
        # encoding-aware, so ASCII-8BIT 'けど' != UTF-8 'けど' and the
        # NLTokenizer's UTF-8 tokens silently miss. Force-tag every
        # stopword as UTF-8 so Set#include? matches regardless of host
        # process default encoding.
        data = YAML.load_file(@stopwords_path) || {}
        @stopwords = {}
        data.each do |lang, words|
          @stopwords[lang.to_s] = (words || []).map { |w| w.to_s.dup.force_encoding(Encoding::UTF_8).downcase }.to_set
        end
      end

      def filter(_tag, _time, record)
        return record unless record['kind'] == 'final'
        text = record['text'].to_s
        return record if text.empty?
        lang = (record['language'] || 'ja').to_s.split('-').first.downcase
        # The token stream from NLTokenizer is always UTF-8, but record
        # values arriving from fluentd's @type json may be ASCII-8BIT
        # under -Eascii-8bit. Force lookup keys to UTF-8 too.
        lang = lang.dup.force_encoding(Encoding::UTF_8)
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

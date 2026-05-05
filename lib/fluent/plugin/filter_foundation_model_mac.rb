# lib/fluent/plugin/filter_foundation_model_mac.rb
require 'fluent/plugin/filter'
require 'foundation_model_mac'

module Fluent
  module Plugin
    class FoundationModelMacFilter < Fluent::Plugin::Filter
      Fluent::Plugin.register_filter('foundation_model_mac', self)

      INSTRUCTIONS = '入力された日本語または英語の発話を、意味を変えずに、言い淀み・フィラー・不要な敬語の重複を取り除いて読みやすく整える。短い場合はそのまま返す。1行で返す。'

      attr_accessor :client

      def configure(conf)
        super
        @client = AppleFoundationModel
      end

      def filter(_tag, _time, record)
        return record unless record['kind'] == 'final'
        text = record['text'].to_s
        return record if text.empty?
        polished = @client.generate(prompt: text, instructions: INSTRUCTIONS).to_s.strip
        record.merge('polished_text' => polished)
      end
    end
  end
end

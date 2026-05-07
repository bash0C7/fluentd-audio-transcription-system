# lib/fluent/plugin/filter_audio_state.rb
require 'fluent/plugin/filter'

module Fluent
  module Plugin
    class AudioStateFilter < Fluent::Plugin::Filter
      Fluent::Plugin.register_filter('audio_state', self)

      SESSION_KINDS = %w[session_started session_finalized mute_changed retranscribe_done].freeze

      def filter(_tag, _time, record)
        kind = record['kind']
        if SESSION_KINDS.include?(kind)
          return record
        end
        return nil unless kind == 'rotated'
        path = record['path']
        return nil unless path && File.file?(path)
        unless record['started_at'] && record['ended_at']
          log.warn 'rotated event missing started_at/ended_at, dropping (contract violation)', record: record.reject { |k, _| k == 'blob' }
          return nil
        end
        blob = File.binread(path)
        started_at = record['started_at'].to_f
        ended_at = record['ended_at'].to_f
        out = {
          'channel' => record['channel'],
          'path' => path,
          'started_at' => started_at,
          'ended_at' => ended_at,
          'duration_sec' => ended_at - started_at,
          'codec' => 'aac',
          'sample_rate' => 16000,
          'bytes' => blob.bytesize,
          'blob' => blob
        }
        out['session_started_at'] = record['session_started_at'].to_f if record['session_started_at']
        out
      end
    end
  end
end

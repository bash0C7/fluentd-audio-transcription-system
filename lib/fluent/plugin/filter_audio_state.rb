# lib/fluent/plugin/filter_audio_state.rb
require 'fluent/plugin/filter'

module Fluent
  module Plugin
    class AudioStateFilter < Fluent::Plugin::Filter
      Fluent::Plugin.register_filter('audio_state', self)

      def filter(_tag, _time, record)
        return nil unless record['kind'] == 'rotated'
        path = record['path']
        return nil unless path && File.file?(path)
        blob = File.binread(path)
        started_at = record['started_at'] || (File.mtime(path).to_f - (record['duration_sec'] || 0).to_f)
        ended_at = record['ended_at'] || File.mtime(path).to_f
        {
          'channel' => record['channel'],
          'path' => path,
          'started_at' => started_at,
          'ended_at' => ended_at,
          'duration_sec' => record['duration_sec'] || (ended_at - started_at),
          'codec' => 'aac',
          'sample_rate' => 16000,
          'bytes' => blob.bytesize,
          'blob' => blob
        }
      end
    end
  end
end

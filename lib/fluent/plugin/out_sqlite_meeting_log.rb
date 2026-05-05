# lib/fluent/plugin/out_sqlite_meeting_log.rb
require 'fluent/plugin/output'
require 'sqlite3'
require 'json'
require 'net/http'
require 'uri'

module Fluent
  module Plugin
    class SqliteMeetingLogOutput < Fluent::Plugin::Output
      Fluent::Plugin.register_output('sqlite_meeting_log', self)

      config_param :db_path, :string
      config_param :ack_path, :string, default: nil
      config_param :webhook_url, :string, default: nil
      config_param :session_gap_seconds, :integer, default: 600

      def configure(conf)
        super
        @db = SQLite3::Database.new(@db_path)
        @db.execute("PRAGMA journal_mode=WAL")
        @db.execute("PRAGMA foreign_keys=ON")
      end

      def shutdown
        @db.close if @db
        super
      end

      def process(tag, es)
        es.each do |_time, record|
          case tag
          when 'audio.state'    then handle_segment(record)
          when 'audio.final'    then handle_final(record)
          when 'audio.sound'    then handle_sound(record)
          when 'audio.quick'    then handle_quick(record)
          end
        end
      end

      private

      def handle_quick(record)
        notify('quick', record)
      end

      def handle_final(record)
        return unless record['kind'] == 'final'
        session_id = ensure_session(record['ch'], record['ended_at'].to_f)
        sql = <<~SQL
          INSERT INTO transcripts(audio_segment_id, session_id, channel, speaker,
                                  started_at, ended_at, language, raw_text,
                                  polished_text, swiftcap_transcript_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        @db.execute(sql, [
          nil, session_id, record['ch'], speaker_for(record['ch']),
          record['started_at'].to_f, record['ended_at'].to_f, record['language'],
          record['text'], record['polished_text'], record['transcript_id']
        ])
        transcript_id = @db.last_insert_row_id
        (record['entities'] || []).each do |e|
          ent_sql = <<~SQL
            INSERT INTO entities(transcript_id, text, kind, observed_at)
            VALUES (?, ?, ?, ?)
          SQL
          @db.execute(ent_sql, [transcript_id, e['text'], e['kind'], record['ended_at'].to_f])
        end
        update_edges(record['entities'] || [], record['ended_at'].to_f)
        notify('final', record.merge('id' => transcript_id))
      end

      def handle_segment(record)
        return unless record['blob']
        sql = <<~SQL
          INSERT INTO audio_segments(channel, started_at, ended_at, duration_sec,
                                     codec, sample_rate, bytes, blob)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        @db.execute(sql, [
          record['channel'], record['started_at'].to_f, record['ended_at'].to_f,
          record['duration_sec'].to_f, record['codec'], record['sample_rate'].to_i,
          record['bytes'].to_i, SQLite3::Blob.new(record['blob'])
        ])
        if @ack_path && record['path']
          File.open(@ack_path, 'a') do |f|
            f.puts JSON.generate({
              'ts' => Time.now.to_f, 'kind' => 'consumed', 'path' => record['path']
            })
          end
        end
        notify('audio_segment', record.reject { |k, _| k == 'blob' })
      end

      def handle_sound(record)
        sql = <<~SQL
          INSERT INTO sound_labels(audio_segment_id, channel, started_at,
                                   ended_at, label, confidence)
          VALUES (?, ?, ?, ?, ?, ?)
        SQL
        @db.execute(sql, [
          nil, record['ch'], record['started_at'].to_f, record['ended_at'].to_f,
          record['label'], record['confidence'].to_f
        ])
        notify('sound', record)
      end

      def ensure_session(channel, ended_at)
        row = @db.get_first_row(
          "SELECT id, ended_at FROM sessions ORDER BY id DESC LIMIT 1"
        )
        if row && row[1] && (ended_at - row[1].to_f) < @session_gap_seconds
          @db.execute("UPDATE sessions SET ended_at=? WHERE id=?", [ended_at, row[0]])
          row[0]
        else
          @db.execute("INSERT INTO sessions(started_at, ended_at) VALUES (?, ?)", [ended_at, ended_at])
          @db.last_insert_row_id
        end
      end

      def speaker_for(channel)
        channel == 'mic' ? 'self' : 'remote'
      end

      def update_edges(entities, observed_at)
        texts = entities.map { |e| e['text'] }.uniq
        return if texts.size < 2
        texts.combination(2).each do |a, b|
          src, dst = [a, b].sort
          edge_sql = <<~SQL
            INSERT INTO entity_edges(src, dst, weight, last_observed_at)
            VALUES (?, ?, 1.0, ?)
            ON CONFLICT(src, dst) DO UPDATE
              SET weight = weight + 1.0, last_observed_at = ?
          SQL
          @db.execute(edge_sql, [src, dst, observed_at, observed_at])
        end
      end

      def notify(kind, payload)
        return unless @webhook_url
        uri = URI.parse(@webhook_url)
        Thread.new do
          begin
            Net::HTTP.post(uri, JSON.generate({ 'type' => kind, 'data' => payload }),
                           'Content-Type' => 'application/json')
          rescue StandardError => e
            log.warn "webhook failed: #{e.class}: #{e.message}"
          end
        end
      end
    end
  end
end

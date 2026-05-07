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
          when 'audio.state'
            case record['kind']
            when 'session_started'   then handle_session_started(record)
            when 'session_finalized' then handle_session_finalized(record)
            when 'mute_changed'      then handle_mute_changed(record)
            when 'retranscribe_done' then handle_retranscribe_done(record)
            else                          handle_segment(record)
            end
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

      def handle_session_started(record)
        sat = record['session_started_at']&.to_f
        return unless sat
        ensure_session_by_started_at(sat)
        notify('session_started', { 'session_started_at' => sat,
                                    'session_id' => session_id_for(sat) })
      end

      def handle_session_finalized(record)
        sat = record['session_started_at']&.to_f
        return unless sat
        ended_at = record['ended_at']&.to_f
        sid = ensure_session_by_started_at(sat)
        @db.execute("UPDATE sessions SET ended_at=?, status='finalized' WHERE id=?",
                    [ended_at, sid])
        notify('session_finalized', { 'session_started_at' => sat,
                                       'session_id' => sid, 'ended_at' => ended_at })
      end

      def handle_mute_changed(record)
        notify('mute_changed', record)
      end

      def handle_retranscribe_done(record)
        sat = record['session_started_at']&.to_f
        sid = sat ? session_id_for(sat) : record['session_id']&.to_i
        return unless sid
        @db.execute("UPDATE sessions SET status='done' WHERE id=?", [sid])
        notify('retranscribe_done', { 'session_id' => sid })
      end

      def handle_final(record)
        return unless record['kind'] == 'final'
        sat = record['session_started_at']&.to_f
        session_id = if sat
                       ensure_session_by_started_at(sat)
                     elsif record['session_id']
                       record['session_id'].to_i
                     end
        pass = (record['pass'] || 1).to_i
        sql = <<~SQL
          INSERT INTO transcripts(audio_segment_id, session_id, channel, speaker,
                                  started_at, ended_at, language, raw_text,
                                  polished_text, swiftcap_transcript_id, pass)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        @db.execute(sql, [
          record['audio_segment_id'], session_id, record['ch'], speaker_for(record['ch']),
          record['started_at'].to_f, record['ended_at'].to_f, record['language'],
          record['text'], record['polished_text'], record['transcript_id'], pass
        ])
        transcript_id = @db.last_insert_row_id
        (record['entities'] || []).each do |e|
          @db.execute(<<~SQL, [transcript_id, e['text'], e['kind'], record['ended_at'].to_f])
            INSERT INTO entities(transcript_id, text, kind, observed_at)
            VALUES (?, ?, ?, ?)
          SQL
        end
        update_edges(record['entities'] || [], record['ended_at'].to_f)
        notify('final', record.merge('id' => transcript_id, 'pass' => pass))
      end

      def handle_segment(record)
        return unless record['blob']
        sat = record['session_started_at']&.to_f
        session_id = sat ? ensure_session_by_started_at(sat) : nil
        sql = <<~SQL
          INSERT INTO audio_segments(channel, started_at, ended_at, duration_sec,
                                     codec, sample_rate, bytes, blob, session_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        @db.execute(sql, [
          record['channel'], record['started_at'].to_f, record['ended_at'].to_f,
          record['duration_sec'].to_f, record['codec'], record['sample_rate'].to_i,
          record['bytes'].to_i, SQLite3::Blob.new(record['blob']), session_id
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

      def ensure_session_by_started_at(started_at)
        row = @db.get_first_row('SELECT id FROM sessions WHERE started_at=?', [started_at])
        return row[0] if row
        @db.execute('INSERT INTO sessions(started_at, status) VALUES (?, ?)',
                    [started_at, 'active'])
        @db.last_insert_row_id
      end

      def session_id_for(started_at)
        row = @db.get_first_row('SELECT id FROM sessions WHERE started_at=?', [started_at])
        row && row[0]
      end

      def speaker_for(channel)
        channel == 'mic' ? 'self' : 'remote'
      end

      def update_edges(entities, observed_at)
        texts = entities.map { |e| e['text'] }.uniq
        return if texts.size < 2
        texts.combination(2).each do |a, b|
          src, dst = [a, b].sort
          @db.execute(<<~SQL, [src, dst, observed_at, observed_at])
            INSERT INTO entity_edges(src, dst, weight, last_observed_at)
            VALUES (?, ?, 1.0, ?)
            ON CONFLICT(src, dst) DO UPDATE
              SET weight = weight + 1.0, last_observed_at = ?
          SQL
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

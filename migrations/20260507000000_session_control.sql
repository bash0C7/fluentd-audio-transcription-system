-- migrations/20260507000000_session_control.sql

ALTER TABLE sessions ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
CREATE INDEX idx_sessions_status ON sessions(status);

ALTER TABLE audio_segments ADD COLUMN session_id INTEGER REFERENCES sessions(id);
CREATE INDEX idx_audio_segments_session ON audio_segments(session_id);

ALTER TABLE transcripts ADD COLUMN pass INTEGER NOT NULL DEFAULT 1;

UPDATE _sqlite_mcp_meta SET value =
  '会議単位（web から user-trigger で区切り）。 status は active/finalized/transcribing/done。 FM 生成の title/summary 保持。'
WHERE key = 'table:sessions';

INSERT OR REPLACE INTO _sqlite_mcp_meta(key, value) VALUES
  ('column:transcripts.pass',
   '1=live SpeechAnalyzer、 2=post-hoc 長尺 retranscribe。 同 audio_segment_id × pass 違いは別 row として残す。'),
  ('column:audio_segments.session_id',
   'sessions.id への FK。 swiftcap が user-trigger で区切った MTG 単位。'),
  ('column:sessions.status',
   'active=recording 中、 finalized=区切られて retranscribe 待ち、 transcribing=retranscribe 走行中、 done=完了。');

-- migrations/20260505000000_initial.sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA mmap_size=268435456;
PRAGMA foreign_keys=ON;

CREATE TABLE _sqlite_mcp_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO _sqlite_mcp_meta(key, value) VALUES
  ('db:meeting_log',
   '会議・会話の文字起こしと音声、抽出エンティティ、共起グラフを保持する。SpeechAnalyzer/Foundation Models 由来の構造化済みデータ。'),
  ('table:audio_segments',
   '録音ファイル本体。CAF/AAC, 16 kHz mono。HUP または 5 分自動の rotate 単位。'),
  ('table:transcripts',
   '会話の確定セグメント。channel で話者識別、polished_text が補完済み完璧版。'),
  ('table:sound_labels',
   'SoundAnalysis のラベリング結果。'),
  ('table:entities',
   '会話から抽出された固有名詞・専門用語・トピック。'),
  ('table:entity_edges',
   'エンティティ間の共起グラフ。weight は時間減衰可。'),
  ('table:sessions',
   '会議単位（無音 N 分以上で区切り）。FM 生成の title/summary 保持。');

CREATE TABLE audio_segments (
  id INTEGER PRIMARY KEY,
  channel TEXT NOT NULL,
  started_at REAL NOT NULL,
  ended_at   REAL NOT NULL,
  duration_sec REAL,
  codec TEXT NOT NULL,
  sample_rate INTEGER,
  bytes INTEGER NOT NULL,
  blob BLOB NOT NULL
);
CREATE INDEX idx_audio_segments_started ON audio_segments(started_at);

CREATE TABLE sessions (
  id INTEGER PRIMARY KEY,
  started_at REAL NOT NULL,
  ended_at REAL,
  title TEXT,
  summary TEXT
);
CREATE INDEX idx_sessions_started ON sessions(started_at);

CREATE TABLE transcripts (
  id INTEGER PRIMARY KEY,
  audio_segment_id INTEGER REFERENCES audio_segments(id),
  session_id INTEGER REFERENCES sessions(id),
  channel TEXT NOT NULL,
  speaker TEXT,
  started_at REAL NOT NULL,
  ended_at   REAL NOT NULL,
  language TEXT,
  raw_text TEXT NOT NULL,
  polished_text TEXT,
  source TEXT NOT NULL DEFAULT 'speech_transcriber',
  swiftcap_transcript_id TEXT
);
CREATE INDEX idx_transcripts_started ON transcripts(started_at);
CREATE INDEX idx_transcripts_session ON transcripts(session_id);
CREATE INDEX idx_transcripts_audio_segment ON transcripts(audio_segment_id);

-- transcripts is write-once: polished_text is set at INSERT time by
-- filter_foundation_model_mac. No FTS5 sync triggers needed for this MVP.
CREATE VIRTUAL TABLE transcripts_fts USING fts5(
  raw_text, polished_text,
  content='transcripts', content_rowid='id', tokenize='unicode61'
);

CREATE TABLE sound_labels (
  id INTEGER PRIMARY KEY,
  audio_segment_id INTEGER REFERENCES audio_segments(id),
  channel TEXT NOT NULL,
  started_at REAL NOT NULL,
  ended_at   REAL NOT NULL,
  label TEXT NOT NULL,
  confidence REAL NOT NULL
);
CREATE INDEX idx_sound_labels_channel_started ON sound_labels(channel, started_at);

CREATE TABLE entities (
  id INTEGER PRIMARY KEY,
  transcript_id INTEGER REFERENCES transcripts(id),
  text TEXT NOT NULL,
  kind TEXT NOT NULL,
  start_offset INTEGER,
  end_offset INTEGER,
  observed_at REAL NOT NULL
);
CREATE INDEX idx_entities_text ON entities(text);
CREATE INDEX idx_entities_observed ON entities(observed_at);

CREATE TABLE entity_edges (
  id INTEGER PRIMARY KEY,
  src TEXT NOT NULL,
  dst TEXT NOT NULL,
  weight REAL NOT NULL DEFAULT 1.0,
  last_observed_at REAL NOT NULL,
  UNIQUE(src, dst)
);

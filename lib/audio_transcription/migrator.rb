# lib/audio_transcription/migrator.rb
require 'sqlite3'
require 'fileutils'
module AudioTranscription
  class Migrator
    MIGRATIONS_DIR = File.expand_path('../../migrations', __dir__)
    def initialize(db_path)
      @db_path = db_path
    end
    def run
      FileUtils.mkdir_p(File.dirname(@db_path))
      db = SQLite3::Database.new(@db_path)
      ensure_applied_table(db)
      applied = db.execute("SELECT version FROM applied_migrations").flatten
      Dir.glob(File.join(MIGRATIONS_DIR, '*.sql')).sort.each do |path|
        version = File.basename(path).split('_', 2).first
        next if applied.include?(version)
        sql = File.read(path)
        db.execute_batch(sql)
        db.execute("INSERT INTO applied_migrations(version, applied_at) VALUES (?, ?)",
                   [version, Time.now.to_f])
      end
      db.close
    end
    private
    def ensure_applied_table(db)
      db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS applied_migrations (
          version TEXT PRIMARY KEY,
          applied_at REAL NOT NULL
        );
      SQL
    end
  end
end

# fluentd-audio-transcription-system v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 26 上で常時起動する音声キャプチャ・文字起こし・可視化システムを 5 phase で構築する。

**Architecture:** Swift CLI (`swiftcap`) が ScreenCaptureKit + AVAudioEngine で 2 系統並行録音し、SpeechAnalyzer/SpeechTranscriber と SNAudioStreamAnalyzer の出力を JSONL でファイル吐き、fluentd が `in_tail` で拾って rb-natural-language-mac / rb-foundation-model-mac で enrich し SQLite WAL に書き、sinatra + WebSocket + PicoRuby:wasm + 3d-force-graph で 3 カラム表示する。各層は spool/ ファイルと SQLite で疎結合、launchd で個別常駐。

**Tech Stack:** Swift 6.3+ / SpeechAnalyzer / SoundAnalysis / ScreenCaptureKit / AVFoundation / Ruby 3.4 / fluentd v1.x / sqlite3 + FTS5 / sinatra / faye-websocket / puma / PicoRuby:wasm 4.x / Three.js / 3d-force-graph / launchd

**Source spec:** `docs/superpowers/specs/2026-05-05-fluentd-audio-transcription-v2-design.md`（変更時は spec を先に更新する）。

**TDD コミット規律:** RED（テストのみ）/ GREEN（最小実装）/ REFACTOR（任意）を独立コミット。`Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` を末尾に付ける。コミットメッセージは英語、conventional commits 形式（feat/fix/docs/chore/test/refactor）。

**ロングテスト規律:** `bundle exec rake test` は subagent に delegate（CLAUDE.md ルール）。単発（`-n` 指定）の集中テストのみ Bash 直叩き可。

**PicoRuby:wasm 制約:** `defined?` / `Hash#fetch` / `String#reverse` / `String#rjust` / inline `rescue` / `proc` / `lambda` 禁止。正規表現は ASCII-only なので日本語マッチには使わず plain String ops で。

---

## Phase A: Repo skeleton + DB foundation

ゴール: 旧コード削除、Gemfile/Rakefile、migrations infra、空 DB（全テーブル + `_sqlite_mcp_meta` + FTS5）が `bundle exec rake db:migrate` で生成される。chiebukuro-mcp readonly open テスト pass。

### Task A1: 旧コード削除と新ディレクトリ構造作成

**Files:**
- Delete: `setup.rb`
- Delete: `specification/` (3 files)
- Delete: `templates/` (6 ERB)
- Create: `swift/swiftcap/.gitkeep`
- Create: `lib/fluent/plugin/.gitkeep`
- Create: `web/.gitkeep`
- Create: `config/.gitkeep`
- Create: `migrations/.gitkeep`
- Create: `scripts/.gitkeep`
- Create: `plists/.gitkeep`
- Create: `test/.gitkeep`

- [ ] **Step 1: 旧ファイル削除と空ディレクトリ作成**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/fluentd-audio-transcription-system
git rm setup.rb
git rm -r specification templates
mkdir -p swift/swiftcap lib/fluent/plugin web config migrations scripts plists test
touch swift/swiftcap/.gitkeep lib/fluent/plugin/.gitkeep web/.gitkeep config/.gitkeep migrations/.gitkeep scripts/.gitkeep plists/.gitkeep test/.gitkeep
```

- [ ] **Step 2: コミット**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore: remove legacy v1 scaffolding and prepare v2 directories

Removes the PyCall+MLX Whisper era setup.rb, specification/, and
templates/. Adds empty directories for the v2 layout described in
docs/superpowers/specs/2026-05-05-fluentd-audio-transcription-v2-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task A2: Gemfile / .ruby-version / .gitignore / Rakefile

**Files:**
- Create: `.ruby-version`
- Create: `Gemfile`
- Create: `.gitignore`
- Create: `Rakefile`

- [ ] **Step 1: `.ruby-version`**

```bash
echo "3.4.1" > .ruby-version
```

- [ ] **Step 2: `Gemfile`**

```ruby
# Gemfile
source 'https://rubygems.org'

ruby '~> 3.4'

gem 'fluentd', '~> 1.18'
gem 'sqlite3', '~> 2.0'
gem 'sinatra', '~> 4.0'
gem 'puma', '~> 6.4'
gem 'faye-websocket', '~> 0.11'
gem 'rb-natural-language-mac', path: '../rb-natural-language-mac'
gem 'rb-foundation-model-mac', path: '../rb-foundation-model-mac'

group :development, :test do
  gem 'test-unit', '~> 3.6'
  gem 'rake', '~> 13.0'
  gem 'rack-test', '~> 2.1'
end
```

- [ ] **Step 3: `.gitignore`**

```
# .gitignore
/vendor/
/.bundle/
/Gemfile.lock
/spool/
/.superpowers/
/db/*.sqlite*
swift/swiftcap/.build/
swift/swiftcap/Package.resolved
*.log
.DS_Store
```

- [ ] **Step 4: `Rakefile`**

```ruby
# Rakefile
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.test_files = FileList['test/**/test_*.rb']
  t.verbose = true
end

namespace :db do
  desc 'Apply pending migrations'
  task :migrate do
    require_relative 'lib/audio_transcription/migrator'
    AudioTranscription::Migrator.new(ENV.fetch('DB_PATH', 'db/meeting_log.sqlite')).run
  end
end

task default: :test
```

- [ ] **Step 5: bundle install と確認**

```bash
bundle config set --local path vendor/bundle
bundle install
```

期待: `Gemfile.lock` 生成。`rb-natural-language-mac` と `rb-foundation-model-mac` は `path:` 指定でローカル参照に解決される。

- [ ] **Step 6: コミット**

```bash
git add .ruby-version Gemfile .gitignore Rakefile
git commit -m "$(cat <<'EOF'
chore: add Gemfile, Rakefile, ruby version pin, and gitignore

Pulls in fluentd, sqlite3, sinatra, puma, faye-websocket, and the
local rb-*-mac gems. Sets up the rake test task and the db:migrate
task that the migrator (next) will hook into.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task A3: Initial migration SQL

**Files:**
- Create: `migrations/20260505000000_initial.sql`

- [ ] **Step 1: マイグレーションSQL書き出し**

```sql
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
```

- [ ] **Step 2: コミット**

```bash
git add migrations/20260505000000_initial.sql
git commit -m "$(cat <<'EOF'
feat(db): add initial schema migration

Adds all spec §5.2 tables and the _sqlite_mcp_meta entries that make
the DB introspectable as a future chiebukuro-mcp domain.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task A4: Migrator (TDD)

**Files:**
- Create: `test/test_migrator.rb`
- Create: `lib/audio_transcription/migrator.rb`

- [ ] **Step 1: 失敗テスト作成（RED）**

```ruby
# test/test_migrator.rb
require 'test/unit'
require 'fileutils'
require 'tmpdir'
require 'sqlite3'
require_relative '../lib/audio_transcription/migrator'

class TestMigrator < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir('migrator-test-')
    @db_path = File.join(@tmp, 'meeting_log.sqlite')
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_run_applies_initial_migration
    AudioTranscription::Migrator.new(@db_path).run
    db = SQLite3::Database.new(@db_path, readonly: true)
    tables = db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").flatten
    assert_includes tables, 'audio_segments'
    assert_includes tables, 'transcripts'
    assert_includes tables, '_sqlite_mcp_meta'
    db.close
  end

  def test_run_is_idempotent
    AudioTranscription::Migrator.new(@db_path).run
    AudioTranscription::Migrator.new(@db_path).run
    db = SQLite3::Database.new(@db_path, readonly: true)
    count = db.execute("SELECT COUNT(*) FROM applied_migrations").flatten.first
    assert_equal 1, count
    db.close
  end

  def test_meta_descriptions_present
    AudioTranscription::Migrator.new(@db_path).run
    db = SQLite3::Database.new(@db_path, readonly: true)
    rows = db.execute("SELECT key FROM _sqlite_mcp_meta ORDER BY key").flatten
    assert_includes rows, 'db:meeting_log'
    assert_includes rows, 'table:transcripts'
    db.close
  end
end
```

- [ ] **Step 2: RED 確認（test を走らせて失敗させる）**

```bash
bundle exec ruby -Ilib -Itest test/test_migrator.rb
```

期待: `LoadError: cannot load such file -- audio_transcription/migrator` で失敗。

- [ ] **Step 3: RED コミット**

```bash
git add test/test_migrator.rb
git commit -m "$(cat <<'EOF'
test: add failing spec for migrator

Specifies that Migrator#run applies the initial migration, is
idempotent across repeated runs (via applied_migrations), and
populates _sqlite_mcp_meta with at least the db: and table: keys.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: 最小実装（GREEN）**

```ruby
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
```

- [ ] **Step 5: GREEN 確認**

```bash
bundle exec ruby -Ilib -Itest test/test_migrator.rb
```

期待: 3 tests, 0 failures.

- [ ] **Step 6: GREEN コミット**

```bash
git add lib/audio_transcription/migrator.rb
git commit -m "$(cat <<'EOF'
feat(db): implement Migrator with applied_migrations tracking

Reads migrations/*.sql in lexical order, applies any unseen versions
(prefix before first underscore is the version), records each in an
applied_migrations table for idempotency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task A5: chiebukuro-mcp 互換 readonly open テスト

**Files:**
- Create: `test/test_chiebukuro_compat.rb`

- [ ] **Step 1: テスト書き出し（RED にはせず、Migrator 完成済みを確認するスモーク）**

```ruby
# test/test_chiebukuro_compat.rb
require 'test/unit'
require 'fileutils'
require 'tmpdir'
require 'sqlite3'
require_relative '../lib/audio_transcription/migrator'

class TestChiebukuroCompat < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir('chiebukuro-compat-')
    @db_path = File.join(@tmp, 'meeting_log.sqlite')
    AudioTranscription::Migrator.new(@db_path).run
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_readonly_open_does_not_raise
    db = SQLite3::Database.new(@db_path, readonly: true)
    db.results_as_hash = true
    db.execute("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    db.close
  end

  def test_meta_table_introspectable
    db = SQLite3::Database.new(@db_path, readonly: true)
    db.results_as_hash = true
    rows = db.execute("SELECT key, value FROM _sqlite_mcp_meta WHERE key='db:meeting_log'")
    refute_empty rows
    assert_match(/会話/, rows.first['value'])
    db.close
  end
end
```

- [ ] **Step 2: テスト実行**

```bash
bundle exec ruby -Ilib -Itest test/test_chiebukuro_compat.rb
```

期待: 2 tests, 0 failures.

- [ ] **Step 3: コミット**

```bash
git add test/test_chiebukuro_compat.rb
git commit -m "$(cat <<'EOF'
test: verify readonly open and _sqlite_mcp_meta introspectability

Pins the contract that a future chiebukuro-mcp domain plugin can
open the DB readonly and read meta descriptions, matching the
SchemaResource pattern in chiebukuro-mcp.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task A6: db:migrate 動作確認（手動スモーク）

- [ ] **Step 1: 実行**

```bash
rm -f db/meeting_log.sqlite db/meeting_log.sqlite-shm db/meeting_log.sqlite-wal
bundle exec rake db:migrate
sqlite3 db/meeting_log.sqlite ".tables"
```

期待: テーブルが列挙される（`audio_segments transcripts entities ...`）。

- [ ] **Step 2: 異常なし確認後、Phase A 完了**

`bundle exec rake test` を subagent に走らせて all green を確認。

---

## Phase B: swiftcap Swift binary

ゴール: `swift run swiftcap` で `spool/` に CAF + JSONL 群が出てくる。HUP で即 rotate、`ack.jsonl` の `consumed` 行を見たら録音 CAF を unlink する。

> **設計判断:** ScreenCaptureKit / AVAudioEngine / SpeechAnalyzer / SNAudioStreamAnalyzer は実機・TCC 必須なので、unit test では薄い protocol abstraction を切って fake injection する範囲に留め、framework 直叩き部分は手動 e2e のみ。

### Task B1: Swift Package skeleton

**Files:**
- Create: `swift/swiftcap/Package.swift`
- Create: `swift/swiftcap/Sources/Swiftcap/main.swift`
- Create: `swift/swiftcap/Tests/SwiftcapTests/SmokeTests.swift`
- Create: `swift/swiftcap/.swift-version`

- [ ] **Step 1: `.swift-version`**

```bash
echo "6.3.1" > swift/swiftcap/.swift-version
```

- [ ] **Step 2: `Package.swift`**

```swift
// swift/swiftcap/Package.swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "swiftcap",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swiftcap", targets: ["Swiftcap"])
    ],
    targets: [
        .executableTarget(name: "Swiftcap", path: "Sources/Swiftcap"),
        .testTarget(name: "SwiftcapTests", dependencies: ["Swiftcap"], path: "Tests/SwiftcapTests")
    ]
)
```

- [ ] **Step 3: `main.swift` 仮実装**

```swift
// swift/swiftcap/Sources/Swiftcap/main.swift
import Foundation
print("swiftcap: starting")
```

- [ ] **Step 4: スモークテスト**

```swift
// swift/swiftcap/Tests/SwiftcapTests/SmokeTests.swift
import XCTest

final class SmokeTests: XCTestCase {
    func testOnePlusOne() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 5: ビルド確認**

```bash
cd swift/swiftcap
swift build
swift test
cd ../..
```

期待: build / test ともに pass。

- [ ] **Step 6: コミット**

```bash
git add swift/swiftcap/
git commit -m "$(cat <<'EOF'
chore(swiftcap): scaffold Swift Package

Adds a Swift Package executable target named swiftcap targeting
macOS 15+, with a smoke XCTest to confirm the toolchain is wired
up. Pinned to Swift 6.3.1 via .swift-version.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B2: SpoolWriter（JSONL append-only writer, TDD）

**Files:**
- Create: `swift/swiftcap/Tests/SwiftcapTests/SpoolWriterTests.swift`
- Create: `swift/swiftcap/Sources/Swiftcap/SpoolWriter.swift`

- [ ] **Step 1: 失敗テスト**

```swift
// swift/swiftcap/Tests/SwiftcapTests/SpoolWriterTests.swift
import XCTest
@testable import Swiftcap

final class SpoolWriterTests: XCTestCase {
    func testAppendsEachLineWithTrailingNewline() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = SpoolWriter(url: tmp.appendingPathComponent("quick.jsonl"))
        try writer.append(["ts": 1.0, "ch": "mic", "text": "hi"])
        try writer.append(["ts": 2.0, "ch": "mic", "text": "hello"])
        writer.close()

        let contents = try String(contentsOf: tmp.appendingPathComponent("quick.jsonl"))
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"text\":\"hi\""))
        XCTAssertTrue(lines[1].contains("\"text\":\"hello\""))
    }
}
```

- [ ] **Step 2: RED 確認**

```bash
cd swift/swiftcap && swift test --filter SpoolWriterTests
```

期待: `SpoolWriter` 未定義で fail。

- [ ] **Step 3: RED コミット**

```bash
git add swift/swiftcap/Tests/SwiftcapTests/SpoolWriterTests.swift
git commit -m "$(cat <<'EOF'
test(swiftcap): add failing spec for SpoolWriter JSONL append

Pins the spec §3.2 contract: each call to append writes one JSON
object terminated by a single newline.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: 最小実装**

```swift
// swift/swiftcap/Sources/Swiftcap/SpoolWriter.swift
import Foundation

final class SpoolWriter {
    private let url: URL
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "swiftcap.spoolwriter")

    init(url: URL) {
        self.url = url
    }

    func append(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try queue.sync {
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try FileHandle(forWritingTo: url)
                try handle?.seekToEnd()
            }
            try handle?.write(contentsOf: data)
            try handle?.write(contentsOf: Data([0x0A]))
        }
    }

    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }
}
```

- [ ] **Step 5: GREEN 確認**

```bash
cd swift/swiftcap && swift test --filter SpoolWriterTests
```

期待: pass。

- [ ] **Step 6: GREEN コミット**

```bash
git add swift/swiftcap/Sources/Swiftcap/SpoolWriter.swift
git commit -m "$(cat <<'EOF'
feat(swiftcap): implement SpoolWriter JSONL append

Serial dispatch queue serializes appends across all callers (capture
threads, HUP signal). Lazy file open on first write.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B3: AckReader（`ack.jsonl` を tail して consumed 通知を受ける, TDD）

**Files:**
- Create: `swift/swiftcap/Tests/SwiftcapTests/AckReaderTests.swift`
- Create: `swift/swiftcap/Sources/Swiftcap/AckReader.swift`

- [ ] **Step 1: 失敗テスト**

```swift
// swift/swiftcap/Tests/SwiftcapTests/AckReaderTests.swift
import XCTest
@testable import Swiftcap

final class AckReaderTests: XCTestCase {
    func testEmitsConsumedPaths() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ackUrl = tmp.appendingPathComponent("ack.jsonl")
        let line1 = #"{"ts":1.0,"kind":"consumed","path":"/spool/mic-1.caf"}"# + "\n"
        let line2 = #"{"ts":2.0,"kind":"consumed","path":"/spool/screen-2.caf"}"# + "\n"
        try (line1 + line2).data(using: .utf8)!.write(to: ackUrl)

        let reader = AckReader(url: ackUrl)
        let consumed = try reader.readNew()
        XCTAssertEqual(consumed, ["/spool/mic-1.caf", "/spool/screen-2.caf"])

        let again = try reader.readNew()
        XCTAssertEqual(again, [])
    }
}
```

- [ ] **Step 2: RED 確認**

```bash
cd swift/swiftcap && swift test --filter AckReaderTests
```

- [ ] **Step 3: RED コミット**

```bash
git add swift/swiftcap/Tests/SwiftcapTests/AckReaderTests.swift
git commit -m "$(cat <<'EOF'
test(swiftcap): add failing spec for AckReader consumed-path tail

readNew returns only newly appended consumed paths, never re-emits
already seen offsets.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: 最小実装**

```swift
// swift/swiftcap/Sources/Swiftcap/AckReader.swift
import Foundation

final class AckReader {
    private let url: URL
    private var offset: UInt64 = 0
    private var leftover: Data = Data()

    init(url: URL) {
        self.url = url
    }

    func readNew() throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let chunk = handle.readDataToEndOfFile()
        offset += UInt64(chunk.count)
        var data = leftover + chunk
        leftover = Data()

        var paths: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<nl]
            data = data[data.index(after: nl)...]
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["kind"] as? String == "consumed",
                  let path = obj["path"] as? String else { continue }
            paths.append(path)
        }
        leftover = data
        return paths
    }
}
```

- [ ] **Step 5: GREEN 確認 / コミット**

```bash
cd swift/swiftcap && swift test --filter AckReaderTests
```

```bash
git add swift/swiftcap/Sources/Swiftcap/AckReader.swift
git commit -m "$(cat <<'EOF'
feat(swiftcap): implement AckReader incremental tail

Tracks the byte offset across readNew calls so consumed paths are
emitted exactly once. Leftover-line buffer handles partial writes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B4: RotatingRecorder protocol + 実装（CAF/AAC 16kHz mono）

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift`
- Create: `swift/swiftcap/Tests/SwiftcapTests/RotatingRecorderTests.swift`

- [ ] **Step 1: テスト**

```swift
// swift/swiftcap/Tests/SwiftcapTests/RotatingRecorderTests.swift
import XCTest
import AVFoundation
@testable import Swiftcap

final class RotatingRecorderTests: XCTestCase {
    func testFinalizeProducesCAFFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = RotatingRecorder(channel: "mic", spoolDir: tmp)
        try recorder.start(at: Date(timeIntervalSince1970: 1735689600))
        let buffer = try makeSilentBuffer(seconds: 1)
        try recorder.append(buffer)

        let exp = expectation(description: "finalize")
        recorder.finalize { url in
            XCTAssertEqual(url.lastPathComponent, "mic-20260101-090000.caf")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    private func makeSilentBuffer(seconds: Int) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        return buf
    }
}
```

- [ ] **Step 2: RED 確認とコミット**

```bash
cd swift/swiftcap && swift test --filter RotatingRecorderTests
git add swift/swiftcap/Tests/SwiftcapTests/RotatingRecorderTests.swift
git commit -m "$(cat <<'EOF'
test(swiftcap): add failing spec for RotatingRecorder

Pins the filename format (channel-YYYYMMDD-HHMMSS.caf, JST-implied
timestamp from UTC offset of caller) and that finalize produces a
playable file on disk after a one-second silent buffer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: 最小実装**

```swift
// swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift
import AVFoundation
import Foundation

final class RotatingRecorder {
    private let channel: String
    private let spoolDir: URL
    private var currentURL: URL?
    private var assetWriter: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "swiftcap.recorder")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(channel: String, spoolDir: URL) {
        self.channel = channel
        self.spoolDir = spoolDir
    }

    func start(at date: Date = Date()) throws {
        try queue.sync {
            let stamp = Self.formatter.string(from: date)
            let url = spoolDir.appendingPathComponent("\(channel)-\(stamp).caf")
            currentURL = url
            let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 16000,
                AVEncoderBitRateKey: 64000
            ]
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            writerInput.expectsMediaDataInRealTime = true
            writer.add(writerInput)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            self.assetWriter = writer
            self.input = writerInput
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        try queue.sync {
            guard let input = self.input,
                  let sampleBuffer = buffer.toCMSampleBuffer() else { return }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            input.append(sampleBuffer)
        }
    }

    func finalize(_ completion: @escaping (URL) -> Void) {
        queue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let input = self.input,
                  let url = self.currentURL else { return }
            input.markAsFinished()
            writer.finishWriting {
                self.assetWriter = nil
                self.input = nil
                self.currentURL = nil
                completion(url)
            }
        }
    }
}

extension AVAudioPCMBuffer {
    func toCMSampleBuffer() -> CMSampleBuffer? {
        let asbd = format.streamDescription.pointee
        var format: CMFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil,
                                             asbd: asbd,
                                             layoutSize: 0,
                                             layout: nil,
                                             magicCookieSize: 0,
                                             magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)),
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreate(allocator: nil,
                                   dataBuffer: nil,
                                   dataReady: false,
                                   makeDataReadyCallback: nil,
                                   refcon: nil,
                                   formatDescription: format,
                                   sampleCount: CMItemCount(frameLength),
                                   sampleTimingEntryCount: 1,
                                   sampleTimingArray: [timing],
                                   sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil,
                                   sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer,
                                                              blockBufferAllocator: nil,
                                                              blockBufferMemoryAllocator: nil,
                                                              flags: 0,
                                                              bufferList: audioBufferList) == noErr else { return nil }
        return sampleBuffer
    }
}
```

- [ ] **Step 4: GREEN 確認とコミット**

```bash
cd swift/swiftcap && swift test --filter RotatingRecorderTests
git add swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift
git commit -m "$(cat <<'EOF'
feat(swiftcap): implement RotatingRecorder writing CAF/AAC

Single AVAssetWriter per active recording, AVAssetWriterInput in
real-time mode, 64 kbps AAC at 16 kHz mono. Filenames embed
channel and local-timezone YYYYMMDD-HHMMSS stamps. PCM buffers are
shimmed to CMSampleBuffer for AVAssetWriterInput consumption.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B5: TranscriberWrapper（SpeechAnalyzer + SpeechTranscriber を SpoolWriter にブリッジ）

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift`

> framework 直叩き部分の単体テストはスキップ（spec §9 方針）。本タスクは実装と手動 e2e のみ。

- [ ] **Step 1: 実装**

```swift
// swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class TranscriberWrapper {
    private let channel: String
    private let quickWriter: SpoolWriter
    private let finalWriter: SpoolWriter
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputBuilder: AnalyzerInputSequence

    init(channel: String, locale: Locale, quickWriter: SpoolWriter, finalWriter: SpoolWriter) async throws {
        self.channel = channel
        self.quickWriter = quickWriter
        self.finalWriter = finalWriter
        self.transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.inputBuilder = AnalyzerInputSequence()
        try await ensureModelInstalled(locale: locale)
        Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let transcriptId = UUID().uuidString
                    let text = String(result.text.characters)
                    if result.isFinal {
                        try? self.finalWriter.append([
                            "ts": Date().timeIntervalSince1970,
                            "ch": self.channel,
                            "kind": "final",
                            "text": text,
                            "transcript_id": transcriptId
                        ])
                    } else {
                        try? self.quickWriter.append([
                            "ts": Date().timeIntervalSince1970,
                            "ch": self.channel,
                            "kind": "volatile",
                            "text": text,
                            "transcript_id": transcriptId
                        ])
                    }
                }
            } catch {
                FileHandle.standardError.write("transcriber error: \(error)\n".data(using: .utf8)!)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) async throws {
        try await analyzer.analyzeSequence(from: inputBuilder.append(buffer))
    }

    func finalize() async throws {
        try await analyzer.finalizeAndFinishThroughEnd()
    }

    private func ensureModelInstalled(locale: Locale) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else {
            throw NSError(domain: "swiftcap", code: 1, userInfo: [NSLocalizedDescriptionKey: "locale not supported"])
        }
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else { return }
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
    }
}

// Placeholder until SpeechAnalyzer's actual sequence builder name is locked in.
// Adapter for the WWDC25 sample's input sequence pattern.
@available(macOS 26.0, *)
final class AnalyzerInputSequence {
    func append(_ buffer: AVAudioPCMBuffer) -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            continuation.yield(buffer)
            continuation.finish()
        }
    }
}
```

> 注: WWDC25 セッションの API シェイプに沿った仮実装。実機で API 名称が `analyzeSequence(from:)` ではなく別名だった場合は最小修正で合わせ込む。

- [ ] **Step 2: コンパイル確認**

```bash
cd swift/swiftcap && swift build
```

期待: build pass。

- [ ] **Step 3: コミット**

```bash
git add swift/swiftcap/Sources/Swiftcap/TranscriberWrapper.swift
git commit -m "$(cat <<'EOF'
feat(swiftcap): wrap SpeechAnalyzer/SpeechTranscriber with spool writers

Drives the WWDC25 SpeechAnalyzer pipeline with volatileResults and
audioTimeRange attribute options. volatile results land in
quick.jsonl, finalized results in final.jsonl. AssetInventory
ensures the locale model is installed on first run.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B6: SoundAnalyzerWrapper（SNAudioStreamAnalyzer）

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/SoundAnalyzerWrapper.swift`

- [ ] **Step 1: 実装**

```swift
// swift/swiftcap/Sources/Swiftcap/SoundAnalyzerWrapper.swift
import AVFoundation
import Foundation
import SoundAnalysis

final class SoundAnalyzerWrapper: NSObject, SNResultsObserving {
    private let channel: String
    private let writer: SpoolWriter
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat

    init(channel: String, writer: SpoolWriter, format: AVAudioFormat) throws {
        self.channel = channel
        self.writer = writer
        self.analyzer = SNAudioStreamAnalyzer(format: format)
        self.format = format
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        try analyzer.add(request, withObserver: self)
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult, let top = r.classifications.first else { return }
        try? writer.append([
            "ts": Date().timeIntervalSince1970,
            "ch": channel,
            "started_at": r.timeRange.start.seconds,
            "ended_at": r.timeRange.end.seconds,
            "label": top.identifier,
            "confidence": top.confidence
        ])
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {}
    func requestDidComplete(_ request: SNRequest) {}
}
```

- [ ] **Step 2: ビルドとコミット**

```bash
cd swift/swiftcap && swift build
git add swift/swiftcap/Sources/Swiftcap/SoundAnalyzerWrapper.swift
git commit -m "$(cat <<'EOF'
feat(swiftcap): wrap SNAudioStreamAnalyzer with classifier v1

Top-1 classification per analysis window, dropped into sound.jsonl
with confidence and time range. Uses MLSoundIdentifierVersion1
(300+ environmental sound labels).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B7: CaptureCoordinator（mic + screen channels の orchestrator）

**Files:**
- Create: `swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift`

- [ ] **Step 1: 実装**

```swift
// swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift
import AVFoundation
import Foundation
import ScreenCaptureKit

@available(macOS 26.0, *)
actor CaptureCoordinator {
    let spoolDir: URL
    private var recorders: [String: RotatingRecorder] = [:]
    private var transcribers: [String: TranscriberWrapper] = [:]
    private var sounds: [String: SoundAnalyzerWrapper] = [:]
    private var stateWriter: SpoolWriter
    private let quickWriter: SpoolWriter
    private let finalWriter: SpoolWriter
    private let soundWriter: SpoolWriter
    private var rotateTask: Task<Void, Never>?
    private let micEngine = AVAudioEngine()
    private var screenStream: SCStream?

    init(spoolDir: URL) {
        self.spoolDir = spoolDir
        try? FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        self.stateWriter = SpoolWriter(url: spoolDir.appendingPathComponent("state.jsonl"))
        self.quickWriter = SpoolWriter(url: spoolDir.appendingPathComponent("quick.jsonl"))
        self.finalWriter = SpoolWriter(url: spoolDir.appendingPathComponent("final.jsonl"))
        self.soundWriter = SpoolWriter(url: spoolDir.appendingPathComponent("sound.jsonl"))
    }

    func start(locale: Locale) async throws {
        for ch in ["mic", "screen"] {
            recorders[ch] = RotatingRecorder(channel: ch, spoolDir: spoolDir)
            transcribers[ch] = try await TranscriberWrapper(channel: ch, locale: locale,
                                                            quickWriter: quickWriter,
                                                            finalWriter: finalWriter)
            try recorders[ch]?.start()
        }

        try await startMic()
        try await startScreen()
        scheduleAutoRotate(every: 300)
    }

    func rotateAll(reason: String) async {
        for (ch, recorder) in recorders {
            await rotate(channel: ch, recorder: recorder, reason: reason)
        }
        for ch in ["mic", "screen"] {
            recorders[ch] = RotatingRecorder(channel: ch, spoolDir: spoolDir)
            try? recorders[ch]?.start()
        }
    }

    func acknowledgeAndDelete(paths: [String]) {
        for p in paths {
            let url = URL(fileURLWithPath: p)
            try? FileManager.default.removeItem(at: url)
            try? stateWriter.append([
                "ts": Date().timeIntervalSince1970,
                "kind": "deleted",
                "path": p
            ])
        }
    }

    private func rotate(channel: String, recorder: RotatingRecorder, reason: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            recorder.finalize { url in
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
                try? self.stateWriter.append([
                    "ts": Date().timeIntervalSince1970,
                    "kind": "rotated",
                    "channel": channel,
                    "path": url.path,
                    "bytes": bytes,
                    "reason": reason
                ])
                cont.resume()
            }
        }
    }

    private func scheduleAutoRotate(every seconds: TimeInterval) {
        rotateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.rotateAll(reason: "auto")
            }
        }
    }

    private func startMic() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let input = micEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: format)
        sounds["mic"] = try SoundAnalyzerWrapper(channel: "mic", writer: soundWriter, format: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity)!
            var error: NSError?
            converter?.convert(to: outBuffer, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            Task { await self.feed(channel: "mic", buffer: outBuffer, time: time) }
        }
        try micEngine.start()
    }

    private func feed(channel: String, buffer: AVAudioPCMBuffer, time: AVAudioTime) async {
        try? recorders[channel]?.append(buffer)
        try? await transcribers[channel]?.append(buffer)
        sounds[channel]?.append(buffer, at: time)
    }

    private func startScreen() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(ScreenAudioOutput(coordinator: self), type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        screenStream = stream
    }

    fileprivate func feedScreen(buffer: AVAudioPCMBuffer, time: AVAudioTime) async {
        await feed(channel: "screen", buffer: buffer, time: time)
    }
}

@available(macOS 26.0, *)
final class ScreenAudioOutput: NSObject, SCStreamOutput {
    private weak var coordinator: CaptureCoordinator?
    init(coordinator: CaptureCoordinator) { self.coordinator = coordinator }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let pcm = sb.toAVAudioPCMBuffer() else { return }
        let time = AVAudioTime(sampleTime: sb.presentationTimeStamp.value, atRate: pcm.format.sampleRate)
        Task { await coordinator?.feedScreen(buffer: pcm, time: time) }
    }
}

extension CMSampleBuffer {
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(self,
                                                                       bufferListSizeNeededOut: nil,
                                                                       bufferListOut: &audioBufferList,
                                                                       bufferListSize: MemoryLayout<AudioBufferList>.size,
                                                                       blockBufferAllocator: nil,
                                                                       blockBufferMemoryAllocator: nil,
                                                                       flags: 0,
                                                                       blockBufferOut: &blockBuffer) == noErr else { return nil }
        let format = AVAudioFormat(streamDescription: CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription!)!)!
        let frames = AVAudioFrameCount(numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        if let mData = audioBufferList.mBuffers.mData,
           let dst = pcm.floatChannelData?[0] {
            memcpy(dst, mData, Int(audioBufferList.mBuffers.mDataByteSize))
        }
        return pcm
    }
}
```

- [ ] **Step 2: ビルドとコミット**

```bash
cd swift/swiftcap && swift build
git add swift/swiftcap/Sources/Swiftcap/CaptureCoordinator.swift
git commit -m "$(cat <<'EOF'
feat(swiftcap): orchestrate mic + screen channels via CaptureCoordinator

Boots an AVAudioEngine for mic capture and an SCStream for screen
audio, fans each channel into RotatingRecorder, TranscriberWrapper,
and SoundAnalyzerWrapper. Auto-rotate task fires every 5 minutes.
state.jsonl records rotated/deleted events.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B8: main.swift（signals + ack reader loop + Info.plist）

**Files:**
- Modify: `swift/swiftcap/Sources/Swiftcap/main.swift`
- Create: `swift/swiftcap/Sources/Swiftcap/Info.plist`

- [ ] **Step 1: Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.bash0c7.swiftcap</string>
    <key>CFBundleName</key>
    <string>swiftcap</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Captures meeting audio from screen sharing.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Records your microphone for meeting transcription.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>On-device speech recognition for live transcription.</string>
</dict>
</plist>
```

- [ ] **Step 2: main.swift**

```swift
// swift/swiftcap/Sources/Swiftcap/main.swift
import Foundation

@available(macOS 26.0, *)
@main
struct Swiftcap {
    static func main() async {
        let spoolDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWIFTCAP_SPOOL"]
            ?? NSString(string: "~/Library/Application Support/audio-transcription/spool").expandingTildeInPath)
        let locale = Locale(identifier: ProcessInfo.processInfo.environment["SWIFTCAP_LOCALE"] ?? "ja-JP")

        let coordinator = CaptureCoordinator(spoolDir: spoolDir)
        do {
            try await coordinator.start(locale: locale)
        } catch {
            FileHandle.standardError.write("startup failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        hupSource.setEventHandler { Task { await coordinator.rotateAll(reason: "hup") } }
        signal(SIGHUP, SIG_IGN)
        hupSource.resume()

        let ackReader = AckReader(url: spoolDir.appendingPathComponent("ack.jsonl"))
        Task {
            while true {
                if let consumed = try? ackReader.readNew(), !consumed.isEmpty {
                    await coordinator.acknowledgeAndDelete(paths: consumed)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        try? await Task.sleep(nanoseconds: UInt64.max)
    }
}
```

- [ ] **Step 3: ビルドとコミット**

```bash
cd swift/swiftcap && swift build
git add swift/swiftcap/Sources/Swiftcap/main.swift swift/swiftcap/Sources/Swiftcap/Info.plist
git commit -m "$(cat <<'EOF'
feat(swiftcap): wire signals, ack-reader poll loop, and Info.plist

SIGHUP triggers rotateAll with reason='hup'. AckReader polls every
2s and deletes consumed CAFs. Info.plist embeds TCC usage strings
for ScreenCapture, Microphone, and SpeechRecognition.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B9: Info.plist Mach-O 埋め込みの linker 設定

**Files:**
- Modify: `swift/swiftcap/Package.swift`

- [ ] **Step 1: linker フラグ追加**

```swift
// swift/swiftcap/Package.swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "swiftcap",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swiftcap", targets: ["Swiftcap"])
    ],
    targets: [
        .executableTarget(
            name: "Swiftcap",
            path: "Sources/Swiftcap",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Swiftcap/Info.plist"
                ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(name: "SwiftcapTests", dependencies: ["Swiftcap"], path: "Tests/SwiftcapTests")
    ]
)
```

- [ ] **Step 2: ビルドとコミット**

```bash
cd swift/swiftcap && swift build -c release
otool -P .build/release/swiftcap | head -20
```

期待: Info.plist の中身が出力される。

```bash
git add swift/swiftcap/Package.swift
git commit -m "$(cat <<'EOF'
build(swiftcap): embed Info.plist into Mach-O for TCC prompts

Uses -sectcreate __TEXT __info_plist linker flag so the TCC dialog
shows the usage strings on first launch even though there is no
.app bundle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B10: 手動 e2e（30 秒スモーク）

- [ ] **Step 1: ビルドと起動**

```bash
cd swift/swiftcap
swift build -c release
SWIFTCAP_SPOOL=/tmp/swiftcap-smoke ./.build/release/swiftcap &
SWIFTCAP_PID=$!
```

権限ダイアログ（マイク、画面収録、音声認識）を順次承認。

- [ ] **Step 2: 30 秒待ってから rotate**

```bash
sleep 30
kill -HUP $SWIFTCAP_PID
sleep 2
ls /tmp/swiftcap-smoke/
```

期待: `mic-*.caf`, `screen-*.caf`（rotateで closed）, `quick.jsonl`, `final.jsonl`, `sound.jsonl`, `state.jsonl` 各種出現。

- [ ] **Step 3: 終了**

```bash
kill -TERM $SWIFTCAP_PID
```

Phase B 完了。次の Phase C で fluentd 側がこれらファイルを消費する側を作る。

---

## Phase C: fluentd plugin suite

ゴール: `bundle exec fluentd -c config/fluent.conf` で spool/ ファイルを取り込み、SQLite に書き、ack.jsonl を更新、web に webhook POST する。

### Task C1: config/fluent.conf

**Files:**
- Create: `config/fluent.conf`
- Create: `config/stopwords.yml`

- [ ] **Step 1: fluent.conf**

```
# config/fluent.conf

<source>
  @type tail
  path "#{ENV['SPOOL_DIR'] || '/Users/bash/Library/Application Support/audio-transcription/spool'}/quick.jsonl"
  pos_file "#{ENV['SPOOL_DIR'] || '/tmp'}/.pos.quick"
  tag audio.quick
  read_from_head true
  <parse>
    @type json
  </parse>
</source>

<source>
  @type tail
  path "#{ENV['SPOOL_DIR'] || '/Users/bash/Library/Application Support/audio-transcription/spool'}/final.jsonl"
  pos_file "#{ENV['SPOOL_DIR'] || '/tmp'}/.pos.final"
  tag audio.final
  read_from_head true
  <parse>
    @type json
  </parse>
</source>

<source>
  @type tail
  path "#{ENV['SPOOL_DIR'] || '/Users/bash/Library/Application Support/audio-transcription/spool'}/sound.jsonl"
  pos_file "#{ENV['SPOOL_DIR'] || '/tmp'}/.pos.sound"
  tag audio.sound
  read_from_head true
  <parse>
    @type json
  </parse>
</source>

<source>
  @type tail
  path "#{ENV['SPOOL_DIR'] || '/Users/bash/Library/Application Support/audio-transcription/spool'}/state.jsonl"
  pos_file "#{ENV['SPOOL_DIR'] || '/tmp'}/.pos.state"
  tag audio.state
  read_from_head true
  <parse>
    @type json
  </parse>
</source>

<filter audio.state>
  @type audio_state
</filter>

<filter audio.final>
  @type natural_language_mac
  stopwords_path "#{File.expand_path('stopwords.yml', __dir__)}"
</filter>

<filter audio.final>
  @type foundation_model_mac
</filter>

<match audio.{quick,final,sound,segment}>
  @type sqlite_meeting_log
  db_path "#{ENV['DB_PATH'] || 'db/meeting_log.sqlite'}"
  ack_path "#{ENV['SPOOL_DIR'] || '/Users/bash/Library/Application Support/audio-transcription/spool'}/ack.jsonl"
  webhook_url "#{ENV['WEBHOOK_URL'] || 'http://localhost:9292/_internal/notify'}"
  session_gap_seconds 600
</match>
```

- [ ] **Step 2: stopwords.yml（最小セット）**

```yaml
# config/stopwords.yml
ja:
  - そう
  - あの
  - えー
  - その
  - これ
  - それ
  - あれ
  - こう
  - はい
  - いえ
  - うん
  - ね
  - よ
  - わ
en:
  - the
  - a
  - an
  - is
  - are
  - was
  - were
  - and
  - or
  - but
  - so
  - of
  - in
  - on
  - at
  - to
  - for
  - with
  - that
  - this
  - it
  - its
  - i
  - you
  - he
  - she
  - we
  - they
```

- [ ] **Step 3: コミット**

```bash
git add config/fluent.conf config/stopwords.yml
git commit -m "$(cat <<'EOF'
feat(config): add fluent.conf and minimal stopwords

Wires four in_tail sources (quick/final/sound/state) and a single
match block to out_sqlite_meeting_log. session_gap_seconds=600
matches spec §4.4. SPOOL_DIR / DB_PATH / WEBHOOK_URL are env-overridable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task C2: filter_audio_state plugin（TDD）

**Files:**
- Create: `test/fluent/test_filter_audio_state.rb`
- Create: `lib/fluent/plugin/filter_audio_state.rb`

- [ ] **Step 1: 失敗テスト**

```ruby
# test/fluent/test_filter_audio_state.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_audio_state'
require 'fileutils'
require 'tmpdir'

class TestFilterAudioState < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('audio-state-')
    @caf = File.join(@tmp, 'mic-20260505-120000.caf')
    File.binwrite(@caf, "FAKE_CAF_BYTES_ ")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver(conf = '')
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::AudioStateFilter).configure(conf)
  end

  def test_rotated_event_loads_blob_and_emits_segment
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Time.now.to_f, {
        'ts' => Time.now.to_f,
        'kind' => 'rotated',
        'channel' => 'mic',
        'path' => @caf,
        'bytes' => File.size(@caf)
      })
    end
    events = d.filtered_records
    assert_equal 1, events.size
    rec = events.first
    assert_equal 'mic', rec['channel']
    assert_equal @caf, rec['path']
    assert_equal File.binread(@caf).bytesize, rec['blob'].bytesize
    assert_equal 'aac', rec['codec']
    assert_equal 16000, rec['sample_rate']
  end

  def test_non_rotated_events_are_dropped
    d = create_driver
    d.run(default_tag: 'audio.state') do
      d.feed(Time.now.to_f, { 'kind' => 'heartbeat' })
    end
    assert_equal 0, d.filtered_records.size
  end
end
```

- [ ] **Step 2: RED 確認とコミット**

```bash
bundle exec ruby -Ilib -Itest test/fluent/test_filter_audio_state.rb
git add test/fluent/test_filter_audio_state.rb
git commit -m "$(cat <<'EOF'
test(fluent): add failing spec for filter_audio_state

Asserts rotated events load CAF bytes into blob, drop non-rotated
events, and emit one segment record per rotated entry.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: 最小実装**

```ruby
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
```

- [ ] **Step 4: GREEN 確認とコミット**

```bash
bundle exec ruby -Ilib -Itest test/fluent/test_filter_audio_state.rb
git add lib/fluent/plugin/filter_audio_state.rb
git commit -m "$(cat <<'EOF'
feat(fluent): implement filter_audio_state

Reads CAF bytes synchronously into the record's blob field on
rotated events; drops heartbeat/deleted/consumed/etc. Tag rewrite
to audio.segment is handled by the match section in fluent.conf
via emit time, not in this filter.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

> 注: filter は tag を変えないため、`out_sqlite_meeting_log` 側で `audio.state` タグの場合に `blob` フィールドの有無で audio_segments テーブルへ振り分ける。シンプルさを優先。

### Task C3: filter_natural_language_mac plugin（TDD）

**Files:**
- Create: `test/fluent/test_filter_natural_language_mac.rb`
- Create: `lib/fluent/plugin/filter_natural_language_mac.rb`

- [ ] **Step 1: テスト**

```ruby
# test/fluent/test_filter_natural_language_mac.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_natural_language_mac'
require 'tmpdir'

class TestFilterNaturalLanguageMac < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('nl-mac-')
    @stopwords = File.join(@tmp, 'stopwords.yml')
    File.write(@stopwords, "en:\n  - the\n  - a\nja:\n  - その\n")
  end

  def teardown
    require 'fileutils'
    FileUtils.remove_entry(@tmp)
  end

  def create_driver
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::NaturalLanguageMacFilter)
      .configure("stopwords_path #{@stopwords}")
  end

  def test_extracts_noun_entities_and_drops_stopwords
    d = create_driver
    d.run(default_tag: 'audio.final') do
      d.feed(Time.now.to_f, {
        'kind' => 'final',
        'text' => 'The quick brown fox jumps.',
        'language' => 'en'
      })
    end
    rec = d.filtered_records.first
    assert_kind_of Array, rec['entities']
    texts = rec['entities'].map { |e| e['text'] }
    refute_includes texts, 'the'
    refute_includes texts, 'a'
  end
end
```

- [ ] **Step 2: RED と RED コミット**

```bash
bundle exec ruby -Ilib -Itest test/fluent/test_filter_natural_language_mac.rb
git add test/fluent/test_filter_natural_language_mac.rb
git commit -m "$(cat <<'EOF'
test(fluent): add failing spec for filter_natural_language_mac

Pins that NLTagger output is normalized into entities[] and that
stopwords are dropped per language.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: 実装**

```ruby
# lib/fluent/plugin/filter_natural_language_mac.rb
require 'fluent/plugin/filter'
require 'natural_language_mac'
require 'yaml'

module Fluent
  module Plugin
    class NaturalLanguageMacFilter < Fluent::Plugin::Filter
      Fluent::Plugin.register_filter('natural_language_mac', self)

      config_param :stopwords_path, :string

      NOUN_TAGS = %w[Noun PersonalName PlaceName OrganizationName].freeze

      def configure(conf)
        super
        data = YAML.load_file(@stopwords_path) || {}
        @stopwords = {}
        data.each { |lang, words| @stopwords[lang.to_s] = (words || []).map(&:downcase).to_set }
      end

      def filter(_tag, _time, record)
        return record unless record['kind'] == 'final'
        text = record['text'].to_s
        return record if text.empty?
        lang = record['language'] || 'ja'
        tagged = NaturalLanguageMac.tag(text)
        words = []
        tagged.each_line do |line|
          token, kind = line.strip.split("\t", 2)
          next unless kind && NOUN_TAGS.include?(kind)
          next if @stopwords[lang]&.include?(token.downcase)
          words << { 'text' => token, 'kind' => kind == 'Noun' ? 'term' : kind.downcase }
        end
        record.merge('entities' => words)
      end
    end
  end
end
```

- [ ] **Step 4: 必要な require と GREEN コミット**

```ruby
# lib/fluent/plugin/filter_natural_language_mac.rb の冒頭に追加
require 'set'
```

```bash
bundle exec ruby -Ilib -Itest test/fluent/test_filter_natural_language_mac.rb
git add lib/fluent/plugin/filter_natural_language_mac.rb
git commit -m "$(cat <<'EOF'
feat(fluent): implement filter_natural_language_mac

Calls NaturalLanguageMac.tag and keeps only noun-class tokens, then
strips stopwords loaded from YAML. Output schema: record.entities is
an array of {text, kind} hashes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task C4: filter_foundation_model_mac plugin（TDD）

**Files:**
- Create: `test/fluent/test_filter_foundation_model_mac.rb`
- Create: `lib/fluent/plugin/filter_foundation_model_mac.rb`

- [ ] **Step 1: テスト（adapter モックで）**

```ruby
# test/fluent/test_filter_foundation_model_mac.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_foundation_model_mac'

class TestFilterFoundationModelMac < Test::Unit::TestCase
  class FakeFM
    def self.generate(prompt:, instructions:); "[polished] #{prompt.split(/\n/).last}"; end
  end

  def setup
    Fluent::Test.setup
  end

  def create_driver
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::FoundationModelMacFilter)
      .configure('')
  end

  def test_polishes_final_text
    d = create_driver
    d.instance.client = FakeFM
    d.run(default_tag: 'audio.final') do
      d.feed(Time.now.to_f, {
        'kind' => 'final',
        'text' => 'えーっと、その、コードレビューしてもらいたいです'
      })
    end
    rec = d.filtered_records.first
    assert_match(/^\[polished\]/, rec['polished_text'])
  end

  def test_passes_through_non_final
    d = create_driver
    d.instance.client = FakeFM
    d.run(default_tag: 'audio.final') do
      d.feed(Time.now.to_f, { 'kind' => 'volatile', 'text' => 'foo' })
    end
    rec = d.filtered_records.first
    assert_nil rec['polished_text']
  end
end
```

- [ ] **Step 2: RED コミット**

```bash
bundle exec ruby -Ilib -Itest test/fluent/test_filter_foundation_model_mac.rb
git add test/fluent/test_filter_foundation_model_mac.rb
git commit -m "$(cat <<'EOF'
test(fluent): add failing spec for filter_foundation_model_mac

Pins that final-kind records receive polished_text via the
injected client and that volatile records pass through.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: 実装**

```ruby
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
```

- [ ] **Step 4: GREEN コミット**

```bash
bundle exec ruby -Ilib -Itest test/fluent/test_filter_foundation_model_mac.rb
git add lib/fluent/plugin/filter_foundation_model_mac.rb
git commit -m "$(cat <<'EOF'
feat(fluent): implement filter_foundation_model_mac

Calls AppleFoundationModel.generate (Ollama-backed today, on-device
Apple Foundation Models in the future) with a fixed instruction
that asks for filler-stripped one-line polishing. Client is settable
for tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task C5: out_sqlite_meeting_log（TDD、最後・最大）

**Files:**
- Create: `test/fluent/test_out_sqlite_meeting_log.rb`
- Create: `lib/fluent/plugin/out_sqlite_meeting_log.rb`

- [ ] **Step 1: テスト**

```ruby
# test/fluent/test_out_sqlite_meeting_log.rb
require 'test/unit'
require 'fluent/test'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_sqlite_meeting_log'
require 'tmpdir'
require 'fileutils'
require 'sqlite3'
require_relative '../../lib/audio_transcription/migrator'

class TestOutSqliteMeetingLog < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @tmp = Dir.mktmpdir('out-sqlite-')
    @db_path = File.join(@tmp, 'm.sqlite')
    @ack_path = File.join(@tmp, 'ack.jsonl')
    AudioTranscription::Migrator.new(@db_path).run
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def create_driver
    Fluent::Test::Driver::Output.new(Fluent::Plugin::SqliteMeetingLogOutput)
      .configure(<<~CONF)
        db_path #{@db_path}
        ack_path #{@ack_path}
        session_gap_seconds 600
      CONF
  end

  def test_writes_quick_event_idempotently_no_persistence
    d = create_driver
    d.run(default_tag: 'audio.quick') do
      d.feed(Time.now.to_f, { 'ch' => 'mic', 'text' => 'volatile preview', 'transcript_id' => 'u1' })
    end
    db = SQLite3::Database.new(@db_path, readonly: true)
    count = db.execute("SELECT COUNT(*) FROM transcripts").flatten.first
    assert_equal 0, count, 'volatile must not persist'
    db.close
  end

  def test_writes_final_creates_session_and_transcript
    d = create_driver
    now = Time.now.to_f
    d.run(default_tag: 'audio.final') do
      d.feed(now, {
        'ch' => 'mic', 'kind' => 'final', 'text' => 'こんにちは',
        'started_at' => now, 'ended_at' => now + 1.0, 'language' => 'ja',
        'transcript_id' => 'u-final-1', 'polished_text' => 'こんにちは。',
        'entities' => [{'text' => 'こんにちは', 'kind' => 'term'}]
      })
    end
    db = SQLite3::Database.new(@db_path, readonly: true)
    db.results_as_hash = true
    transcripts = db.execute("SELECT * FROM transcripts")
    sessions = db.execute("SELECT * FROM sessions")
    entities = db.execute("SELECT * FROM entities")
    assert_equal 1, transcripts.size
    assert_equal 1, sessions.size
    assert_equal 'こんにちは。', transcripts.first['polished_text']
    assert_equal 1, entities.size
    db.close
  end

  def test_segment_record_writes_blob_and_appends_ack
    d = create_driver
    blob = "FAKE CAF"
    path = '/tmp/mic-1.caf'
    d.run(default_tag: 'audio.state') do
      d.feed(Time.now.to_f, {
        'channel' => 'mic', 'path' => path,
        'started_at' => 1.0, 'ended_at' => 6.0, 'duration_sec' => 5.0,
        'codec' => 'aac', 'sample_rate' => 16000, 'bytes' => blob.bytesize,
        'blob' => blob
      })
    end
    db = SQLite3::Database.new(@db_path, readonly: true)
    rows = db.execute("SELECT bytes FROM audio_segments")
    assert_equal blob.bytesize, rows.flatten.first
    db.close
    ack_lines = File.read(@ack_path).lines
    assert_equal 1, ack_lines.size
    assert_match(/"consumed"/, ack_lines.first)
    assert_match(Regexp.new(Regexp.escape(path)), ack_lines.first)
  end

  def test_session_gap_creates_new_session
    d = create_driver
    t0 = 1000.0
    d.run(default_tag: 'audio.final') do
      d.feed(t0, { 'ch' => 'mic', 'kind' => 'final', 'text' => 'a',
                   'started_at' => t0, 'ended_at' => t0 + 1, 'transcript_id' => 'a' })
      d.feed(t0 + 1000, { 'ch' => 'mic', 'kind' => 'final', 'text' => 'b',
                          'started_at' => t0 + 1000, 'ended_at' => t0 + 1001, 'transcript_id' => 'b' })
    end
    db = SQLite3::Database.new(@db_path, readonly: true)
    sessions = db.execute("SELECT COUNT(*) FROM sessions").flatten.first
    assert_equal 2, sessions
    db.close
  end
end
```

- [ ] **Step 2: RED と RED コミット**

```bash
bundle exec ruby -Ilib -Itest test/fluent/test_out_sqlite_meeting_log.rb
git add test/fluent/test_out_sqlite_meeting_log.rb
git commit -m "$(cat <<'EOF'
test(fluent): add failing spec for out_sqlite_meeting_log

Covers: volatile is dropped; final creates session+transcript+entities;
state record writes audio_segments blob and appends ack.jsonl
consumed line; session_gap_seconds spawns a new session.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: 実装**

```ruby
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
        @db.execute(<<~SQL, [
          nil, session_id, record['ch'], speaker_for(record['ch']),
          record['started_at'].to_f, record['ended_at'].to_f, record['language'],
          record['text'], record['polished_text'], record['transcript_id']
        ])
          INSERT INTO transcripts(audio_segment_id, session_id, channel, speaker,
                                  started_at, ended_at, language, raw_text,
                                  polished_text, swiftcap_transcript_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        transcript_id = @db.last_insert_row_id
        (record['entities'] || []).each do |e|
          @db.execute(<<~SQL, [transcript_id, e['text'], e['kind'], record['ended_at'].to_f])
            INSERT INTO entities(transcript_id, text, kind, observed_at)
            VALUES (?, ?, ?, ?)
          SQL
        end
        update_edges(record['entities'] || [], record['ended_at'].to_f)
        notify('final', record.merge('id' => transcript_id))
      end

      def handle_segment(record)
        return unless record['blob']
        @db.execute(<<~SQL, [
          record['channel'], record['started_at'].to_f, record['ended_at'].to_f,
          record['duration_sec'].to_f, record['codec'], record['sample_rate'].to_i,
          record['bytes'].to_i, SQLite3::Blob.new(record['blob'])
        ])
          INSERT INTO audio_segments(channel, started_at, ended_at, duration_sec,
                                     codec, sample_rate, bytes, blob)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
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
        @db.execute(<<~SQL, [
          nil, record['ch'], record['started_at'].to_f, record['ended_at'].to_f,
          record['label'], record['confidence'].to_f
        ])
          INSERT INTO sound_labels(audio_segment_id, channel, started_at,
                                   ended_at, label, confidence)
          VALUES (?, ?, ?, ?, ?, ?)
        SQL
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
```

- [ ] **Step 4: GREEN とコミット**

```bash
bundle exec ruby -Ilib -Itest test/fluent/test_out_sqlite_meeting_log.rb
git add lib/fluent/plugin/out_sqlite_meeting_log.rb
git commit -m "$(cat <<'EOF'
feat(fluent): implement out_sqlite_meeting_log

Per-tag handlers: quick is notify-only (no persist); final inserts
transcript+entities and bumps entity_edges co-occurrence; state
inserts audio_segments blob then appends ack.jsonl; sound inserts
sound_labels. Session segmentation uses session_gap_seconds.
Webhook POST is async via Thread; failures only log.warn.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task C6: 統合スモーク（fluentd を立ち上げて手で event を投げる）

- [ ] **Step 1: 起動**

```bash
mkdir -p /tmp/spool db
DB_PATH=db/smoke.sqlite bundle exec rake db:migrate
SPOOL_DIR=/tmp/spool DB_PATH=db/smoke.sqlite \
  bundle exec fluentd -c config/fluent.conf -p lib/fluent/plugin &
FLUENT_PID=$!
sleep 2
```

- [ ] **Step 2: テストイベント投入**

```bash
echo '{"ts":1.0,"ch":"mic","kind":"final","text":"テスト","started_at":1.0,"ended_at":2.0,"language":"ja","transcript_id":"smoke-1"}' >> /tmp/spool/final.jsonl
sleep 3
sqlite3 db/smoke.sqlite "SELECT raw_text FROM transcripts;"
```

期待: `テスト` が表示。

- [ ] **Step 3: 終了**

```bash
kill $FLUENT_PID
```

Phase C 完了。

---

## Phase D: Web frontend

ゴール: `bundle exec puma -C web/puma.rb` で起動、Chrome で `http://localhost:9292/` を開くと 3 カラムが描画される。fluentd からの webhook を受けて WebSocket で push、PicoRuby が描画を更新する。

### Task D1: sinatra app + puma 設定

**Files:**
- Create: `web/app.rb`
- Create: `web/config.ru`
- Create: `web/puma.rb`

- [ ] **Step 1: web/app.rb**

```ruby
# web/app.rb
require 'sinatra/base'
require 'sqlite3'
require 'json'
require 'faye/websocket'
require 'eventmachine'

class TranscriptionWeb < Sinatra::Base
  set :public_folder, File.expand_path('assets', __dir__)
  set :views, File.expand_path('views', __dir__)

  WEBSOCKETS = []

  configure do
    Faye::WebSocket.load_adapter('puma')
  end

  helpers do
    def db
      @db ||= SQLite3::Database.new(ENV.fetch('DB_PATH', 'db/meeting_log.sqlite'), readonly: true).tap do |d|
        d.results_as_hash = true
      end
    end
  end

  get '/' do
    erb :index
  end

  get '/api/recent' do
    content_type :json
    since = params[:since].to_f
    {
      transcripts: db.execute("SELECT * FROM transcripts WHERE ended_at > ? ORDER BY started_at DESC LIMIT 200", [since]),
      edges: db.execute("SELECT src, dst, weight, last_observed_at FROM entity_edges ORDER BY last_observed_at DESC LIMIT 500")
    }.to_json
  end

  get '/api/sessions/:id' do
    content_type :json
    session = db.get_first_row("SELECT * FROM sessions WHERE id=?", [params[:id].to_i])
    halt 404 unless session
    transcripts = db.execute("SELECT * FROM transcripts WHERE session_id=? ORDER BY started_at", [params[:id].to_i])
    { session: session, transcripts: transcripts }.to_json
  end

  get '/api/audio/:id' do
    row = db.get_first_row("SELECT blob, codec FROM audio_segments WHERE id=?", [params[:id].to_i])
    halt 404 unless row
    content_type 'audio/x-caf'
    row['blob']
  end

  post '/_internal/notify' do
    body = JSON.parse(request.body.read)
    msg = body.to_json
    WEBSOCKETS.each { |ws| ws.send(msg) }
    'ok'
  end

  get '/stream' do
    if Faye::WebSocket.websocket?(env)
      ws = Faye::WebSocket.new(env)
      ws.on(:open) { WEBSOCKETS << ws }
      ws.on(:close) { WEBSOCKETS.delete(ws); ws = nil }
      ws.rack_response
    else
      halt 426
    end
  end
end
```

- [ ] **Step 2: web/views/index.erb**

```erb
<!-- web/views/index.erb -->
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Audio Transcription</title>
  <link rel="stylesheet" href="/style.css">
  <script src="https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/3d-force-graph"></script>
  <script src="https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@latest/dist/init.iife.js"></script>
</head>
<body>
  <div id="app">
    <div id="quick">  <h2>Quick</h2>   <div id="quick-stream"></div>   </div>
    <div id="perfect"><h2>Perfect</h2> <div id="perfect-stream"></div> </div>
    <div id="graph">  <h2>Graph</h2>   <div id="graph-canvas"></div>   </div>
  </div>
  <script type="text/ruby" src="/app.rb"></script>
</body>
</html>
```

- [ ] **Step 3: web/assets/style.css**

```css
/* web/assets/style.css */
* { box-sizing: border-box; }
body { margin: 0; font-family: -apple-system, sans-serif; background: #0e0f12; color: #d8dce0; }
#app { display: grid; grid-template-columns: 1fr 1fr 1.5fr; height: 100vh; gap: 1px; background: #2a2d33; }
#app > div { background: #15171c; padding: 12px; overflow: auto; }
h2 { margin: 0 0 8px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.1em; color: #8a8f99; }
#quick-stream .line  { color: #aab2c0; padding: 2px 0; opacity: 0.7; }
#quick-stream .line.live { color: #fff; opacity: 1; }
#perfect-stream .line { padding: 4px 8px; border-left: 2px solid transparent; margin: 4px 0; }
#perfect-stream .line.mic    { border-color: #4aa3ff; background: #1a2230; }
#perfect-stream .line.screen { border-color: #ff8e6b; background: #2a1f1a; }
#graph-canvas { width: 100%; height: calc(100vh - 60px); }
```

- [ ] **Step 4: web/config.ru**

```ruby
# web/config.ru
require_relative 'app'
run TranscriptionWeb
```

- [ ] **Step 5: web/puma.rb**

```ruby
# web/puma.rb
port ENV.fetch('PORT', 9292)
threads 4, 8
environment ENV.fetch('RACK_ENV', 'development')
plugin :tmp_restart
```

- [ ] **Step 6: コミット**

```bash
git add web/
git commit -m "$(cat <<'EOF'
feat(web): add sinatra app, ERB index, and 3-column CSS

Routes: /, /api/recent, /api/sessions/:id, /api/audio/:id (BLOB
streaming), POST /_internal/notify (fluentd webhook receiver),
GET /stream (WebSocket). Static asset folder serves CSS, PicoRuby
app.rb (Phase D2), and 3d-force-graph from CDN.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task D2: PicoRuby:wasm app.rb（quick / perfect / graph 全部）

**Files:**
- Create: `web/assets/app.rb`

> 注: PicoRuby:wasm 制約のため `Hash#fetch` / inline `rescue` 等を使わない。WebSocket は `JS.global[:WebSocket]` 経由。3d-force-graph は `JS::Bridge.to_js` で graphData を渡す。

- [ ] **Step 1: app.rb**

```ruby
# web/assets/app.rb
require 'js'

# State maintained in Ruby; mirrored to 3d-force-graph via JS::Bridge.
NODES = {}
EDGES = {}
GRAPH = JS.global[:ForceGraph3D].new.call(JS.document.getElementById('graph-canvas'))
GRAPH.nodeAutoColorBy('group')
GRAPH.linkOpacity(0.4)

QUICK_DIV   = JS.document.getElementById('quick-stream')
PERFECT_DIV = JS.document.getElementById('perfect-stream')

def push_quick(text)
  QUICK_DIV.querySelectorAll('.line.live').to_a.each { |n| n[:className] = 'line' }
  div = JS.document.createElement('div')
  div[:className] = 'line live'
  div[:textContent] = text
  QUICK_DIV.appendChild(div)
  while QUICK_DIV[:childElementCount].to_i > 80
    QUICK_DIV.removeChild(QUICK_DIV[:firstElementChild])
  end
end

def push_perfect(channel, raw, polished)
  div = JS.document.createElement('div')
  div[:className] = "line #{channel}"
  div[:textContent] = polished.to_s.empty? ? raw : polished
  PERFECT_DIV.appendChild(div)
  while PERFECT_DIV[:childElementCount].to_i > 200
    PERFECT_DIV.removeChild(PERFECT_DIV[:firstElementChild])
  end
end

def upsert_edge(src, dst, weight)
  return if src.nil? || dst.nil? || src == ''
  NODES[src] = { id: src, group: 'term' } unless NODES.key?(src)
  NODES[dst] = { id: dst, group: 'term' } unless NODES.key?(dst)
  key = "#{src}\t#{dst}"
  EDGES[key] = { source: src, target: dst, value: weight, ts: Time.now.to_f }
  redraw_graph
end

TAU = 1800.0

def redraw_graph
  now = Time.now.to_f
  edges_for_js = []
  EDGES.each_pair do |_, e|
    decay = Math.exp(-(now - e[:ts]) / TAU)
    next if decay < 0.05
    edges_for_js << { source: e[:source], target: e[:target], value: e[:value] * decay }
  end
  data = JS::Bridge.to_js({ nodes: NODES.values, links: edges_for_js })
  GRAPH.graphData(data)
end

ws = JS.global[:WebSocket].new("ws://#{JS.global[:location][:host]}/stream")
ws.addEventListener('message') do |event|
  msg = JS.global[:JSON].parse(event[:data]).to_a
  type = msg.find { |kv| kv[0].to_s == 'type' }
  next unless type
  data = msg.find { |kv| kv[0].to_s == 'data' }
  next unless data
  payload = data[1]
  case type[1].to_s
  when 'quick'
    push_quick(payload[:text].to_s)
  when 'final'
    push_perfect(payload[:ch].to_s, payload[:text].to_s, '')
    (payload[:entities].to_a || []).each do |left|
      (payload[:entities].to_a || []).each do |right|
        next if left == right
        upsert_edge(left[:text].to_s, right[:text].to_s, 1.0)
      end
    end
  when 'polished'
    last = PERFECT_DIV[:lastElementChild]
    last[:textContent] = payload[:text].to_s if last
  when 'edge'
    upsert_edge(payload[:src].to_s, payload[:dst].to_s, payload[:weight].to_f)
  end
end

# Initial bootstrap from /api/recent
JS.global.fetch('/api/recent?since=0').then do |resp|
  resp.json.then do |data|
    transcripts = data[:transcripts].to_a
    transcripts.reverse_each do |t|
      push_perfect(t[:channel].to_s, t[:raw_text].to_s, t[:polished_text].to_s)
    end
    edges = data[:edges].to_a
    edges.each do |e|
      upsert_edge(e[:src].to_s, e[:dst].to_s, e[:weight].to_f)
    end
  end
end
```

- [ ] **Step 2: コミット**

```bash
git add web/assets/app.rb
git commit -m "$(cat <<'EOF'
feat(web): implement PicoRuby:wasm 3-column live UI

WebSocket subscribes to /stream and dispatches per type:
- quick: replaces the latest live line in Quick pane
- final: appends to Perfect pane and feeds entity pairs into the
  in-memory graph
- polished: rewrites the last Perfect line with the polished text
- edge: bumps an existing edge weight

Initial state hydrates from /api/recent. Graph weight uses an
exp(-Δt/τ) decay with τ=1800s and a visibility cutoff at 0.05.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task D3: 手動 e2e

- [ ] **Step 1: 起動**

```bash
DB_PATH=db/smoke.sqlite bundle exec puma -C web/puma.rb web/config.ru &
WEB_PID=$!
open http://localhost:9292/
```

- [ ] **Step 2: 投入**

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"type":"quick","data":{"ch":"mic","text":"テスト中"}}' \
  http://localhost:9292/_internal/notify
```

期待: Quick ペインに「テスト中」が出る。

- [ ] **Step 3: 終了**

```bash
kill $WEB_PID
```

Phase D 完了。

---

## Phase E: launchd + e2e + cleanup

ゴール: `bundle exec rake setup` で 3 plist が生成・bootstrap され、3 プロセスが常駐する。旧 fluent-plugin-* と rb-record-transcribe-mac が GitHub archive 状態。README 更新済み。実会議 30 分で動作確認。

### Task E1: plist テンプレ

**Files:**
- Create: `plists/dev.bash0c7.audio-transcription.swiftcap.plist.erb`
- Create: `plists/dev.bash0c7.audio-transcription.fluentd.plist.erb`
- Create: `plists/dev.bash0c7.audio-transcription.web.plist.erb`

- [ ] **Step 1: swiftcap.plist.erb**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>dev.bash0c7.audio-transcription.swiftcap</string>
  <key>ProgramArguments</key> <array><string><%= swiftcap_bin %></string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SWIFTCAP_SPOOL</key>  <string><%= spool_dir %></string>
    <key>SWIFTCAP_LOCALE</key> <string>ja-JP</string>
  </dict>
  <key>RunAtLoad</key>     <true/>
  <key>KeepAlive</key>     <true/>
  <key>StandardOutPath</key> <string><%= log_dir %>/swiftcap.log</string>
  <key>StandardErrorPath</key><string><%= log_dir %>/swiftcap.err</string>
</dict>
</plist>
```

- [ ] **Step 2: fluentd.plist.erb**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key> <string>dev.bash0c7.audio-transcription.fluentd</string>
  <key>ProgramArguments</key>
  <array>
    <string><%= bundle_bin %></string>
    <string>exec</string>
    <string>fluentd</string>
    <string>-c</string><string><%= repo_root %>/config/fluent.conf</string>
    <string>-p</string><string><%= repo_root %>/lib/fluent/plugin</string>
  </array>
  <key>WorkingDirectory</key>      <string><%= repo_root %></string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SPOOL_DIR</key>  <string><%= spool_dir %></string>
    <key>DB_PATH</key>    <string><%= db_path %></string>
    <key>WEBHOOK_URL</key><string>http://localhost:9292/_internal/notify</string>
  </dict>
  <key>RunAtLoad</key>     <true/>
  <key>KeepAlive</key>     <true/>
  <key>StandardOutPath</key> <string><%= log_dir %>/fluentd.log</string>
  <key>StandardErrorPath</key><string><%= log_dir %>/fluentd.err</string>
</dict>
</plist>
```

- [ ] **Step 3: web.plist.erb**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key> <string>dev.bash0c7.audio-transcription.web</string>
  <key>ProgramArguments</key>
  <array>
    <string><%= bundle_bin %></string>
    <string>exec</string><string>puma</string>
    <string>-C</string><string><%= repo_root %>/web/puma.rb</string>
    <string><%= repo_root %>/web/config.ru</string>
  </array>
  <key>WorkingDirectory</key>      <string><%= repo_root %></string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DB_PATH</key> <string><%= db_path %></string>
  </dict>
  <key>RunAtLoad</key>     <true/>
  <key>KeepAlive</key>     <true/>
  <key>StandardOutPath</key> <string><%= log_dir %>/web.log</string>
  <key>StandardErrorPath</key><string><%= log_dir %>/web.err</string>
</dict>
</plist>
```

- [ ] **Step 4: コミット**

```bash
git add plists/
git commit -m "$(cat <<'EOF'
feat(launchd): add ERB templates for the 3 LaunchAgents

swiftcap, fluentd, and web plists each use KeepAlive=true and
RunAtLoad=true, with logs into ~/Library/Logs/audio-transcription/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task E2: scripts/setup.rb

**Files:**
- Create: `scripts/setup.rb`

- [ ] **Step 1: setup.rb**

```ruby
#!/usr/bin/env ruby
# scripts/setup.rb
require 'erb'
require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
HOME      = ENV['HOME']
SUPPORT   = File.join(HOME, 'Library/Application Support/audio-transcription')
SPOOL_DIR = File.join(SUPPORT, 'spool')
DB_PATH   = File.join(SUPPORT, 'db/meeting_log.sqlite')
LOG_DIR   = File.join(HOME, 'Library/Logs/audio-transcription')
LAUNCH_AGENTS = File.join(HOME, 'Library/LaunchAgents')

bundle_bin   = `which bundle`.strip
swiftcap_bin = File.join(REPO_ROOT, 'swift/swiftcap/.build/release/swiftcap')
repo_root    = REPO_ROOT
spool_dir    = SPOOL_DIR
db_path      = DB_PATH
log_dir      = LOG_DIR

[SUPPORT, SPOOL_DIR, File.dirname(DB_PATH), LOG_DIR, LAUNCH_AGENTS].each do |d|
  FileUtils.mkdir_p(d)
end

system('cd swift/swiftcap && swift build -c release', exception: true)

%w[swiftcap fluentd web].each do |name|
  template = File.read(File.join(REPO_ROOT, "plists/dev.bash0c7.audio-transcription.#{name}.plist.erb"))
  rendered = ERB.new(template).result(binding)
  dest = File.join(LAUNCH_AGENTS, "dev.bash0c7.audio-transcription.#{name}.plist")
  File.write(dest, rendered)
  uid = `id -u`.strip
  system("launchctl bootout gui/#{uid} #{dest} 2>/dev/null")
  system("launchctl bootstrap gui/#{uid} #{dest}", exception: true)
  puts "loaded: #{dest}"
end

puts 'all 3 LaunchAgents loaded. open http://localhost:9292/'
```

- [ ] **Step 2: chmod とコミット**

```bash
chmod +x scripts/setup.rb
git add scripts/setup.rb
git commit -m "$(cat <<'EOF'
feat(setup): add scripts/setup.rb to render plists and bootstrap

Creates ~/Library/Application Support/audio-transcription/{spool,db}
and ~/Library/Logs/audio-transcription, builds swiftcap in release,
renders the 3 plists, and re-bootstraps each via launchctl.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task E3: 旧 repo の archive 指示書

**Files:**
- Create: `docs/migration/archived-repos.md`

- [ ] **Step 1: 指示書（手動オペレーション）**

```markdown
# Archived predecessors

The v2 design supersedes these. Each is archived (read-only) on
GitHub via Settings → Archive this repository. README at HEAD is
updated with a one-line pointer to the v2 repo.

- bash0C7/fluent-plugin-audio-recorder
- bash0C7/fluent-plugin-audio-transcoder
- bash0C7/fluent-plugin-audio-transcriber
- bash0C7/rb-record-transcribe-mac

For each:
1. Add a README banner: `> **Archived 2026-05-05.** Replaced by [bash0C7/fluentd-audio-transcription-system](https://github.com/bash0C7/fluentd-audio-transcription-system).`
2. Commit and push.
3. GitHub UI → Settings → scroll to Archive → "Archive this repository".

Do NOT delete the repos (existing clones must keep resolving).
```

- [ ] **Step 2: コミット**

```bash
git add docs/migration/archived-repos.md
git commit -m "$(cat <<'EOF'
docs: capture archive instructions for v1 predecessor repos

Step-by-step manual procedure to mark fluent-plugin-audio-* and
rb-record-transcribe-mac as archived without deleting them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task E4: README rewrite

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 全置換**

````markdown
# fluentd-audio-transcription-system

macOS 26+ 上で動く、会議音声の常時キャプチャ・文字起こし・可視化システム。

## アーキテクチャ概要

```
swiftcap (Swift CLI)
  └─ ScreenCaptureKit + AVAudioEngine
     ├─ CAF/AAC rotating recorder
     ├─ SpeechAnalyzer/SpeechTranscriber (volatile + final)
     └─ SNAudioStreamAnalyzer
  ↓ spool/{quick,final,sound,state}.jsonl + *.caf
fluentd
  └─ in_tail × 4 → filter_audio_state / natural_language_mac /
     foundation_model_mac → out_sqlite_meeting_log
  ↓ SQLite WAL + ack.jsonl + HTTP webhook
web (sinatra + faye-websocket + puma)
  ↓ WebSocket
Chrome (PicoRuby:wasm + Three.js + 3d-force-graph)
  ┌──────────┬──────────┬─────────────┐
  │ Quick    │ Perfect  │ Network     │
  │ pane     │ pane     │ Graph pane  │
  └──────────┴──────────┴─────────────┘
```

詳細は `docs/superpowers/specs/2026-05-05-fluentd-audio-transcription-v2-design.md` 参照。

## 前提

- macOS 26 (Tahoe) / Apple Silicon
- Swift 6.3+ ([swiftly](https://www.swift.org/install/macos/) 経由推奨)
- Ruby 3.4 (rbenv)
- ローカル ghq layout で `../rb-natural-language-mac` `../rb-foundation-model-mac` `../swift_gem` が clone 済み
- Ollama（`gemma4:e2b` 等）が `localhost:11434` で起動（`rb-foundation-model-mac` 仮実装が利用）

## セットアップ

```bash
git clone https://github.com/bash0C7/fluentd-audio-transcription-system
cd fluentd-audio-transcription-system
bundle install
bundle exec rake db:migrate
bundle exec ruby scripts/setup.rb
```

初回起動時に macOS から「画面収録」「マイク」「音声認識」の許諾ダイアログが出る。すべて承認。

## 確認

```
open http://localhost:9292/
```

Quick / Perfect / Graph の 3 カラムが現れる。実会議や `say -v Kyoko こんにちは` で動作確認。

## 設計上の選択

- 翻訳しない（日本語/英語そのまま）
- 完璧経路は Apple SpeechAnalyzer + Foundation Models のみ（Strategy P, Whisper 不採用）
- 話者識別はチャンネルベース（mic = self, screen = remote）
- DB は SQLite WAL、`_sqlite_mcp_meta` で chiebukuro-mcp 互換

## ライセンス

Apache 2.0
````

- [ ] **Step 2: コミット**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: rewrite README for v2 architecture

Replaces the legacy PyCall+MLX Whisper instructions with the v2
quickstart: bundle install, db:migrate, scripts/setup.rb, then
open the web UI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task E5: 実会議 30 分 e2e（手動）

- [ ] **Step 1: 起動状態確認**

```bash
launchctl list | grep audio-transcription
```

期待: 3 entries (swiftcap, fluentd, web) が PID 付きで表示。

- [ ] **Step 2: 30 分の Zoom / Meet 会議をキャプチャ**

ブラウザで `http://localhost:9292/` を開きながら会議。Quick が随時更新、Perfect が utterance 単位で増え、Graph がノード/エッジで成長する。

- [ ] **Step 3: 30 分後に確認**

```bash
DB=~/Library/Application\ Support/audio-transcription/db/meeting_log.sqlite
sqlite3 "$DB" "SELECT COUNT(*) FROM transcripts;"
sqlite3 "$DB" "SELECT COUNT(*) FROM audio_segments;"
sqlite3 "$DB" "SELECT COUNT(*) FROM entity_edges;"
sqlite3 "$DB" "SELECT title, started_at, ended_at FROM sessions ORDER BY id DESC LIMIT 1;"
ls -lh ~/Library/Application\ Support/audio-transcription/spool/
```

期待: transcripts は数十〜数百行、audio_segments は約 12（5 分 × 2 ch × 30 / 5）、spool は最新 5 分以内のファイルしか残ってない（古いのは consumed→deleted されてる）。

- [ ] **Step 4: 不要時の停止**

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.bash0c7.audio-transcription.web.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.bash0c7.audio-transcription.fluentd.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.bash0c7.audio-transcription.swiftcap.plist
```

Phase E 完了。MVP 構築完了。

---

## Self-review notes（実装者向け）

- 各 Phase は単独で動作する単位として設計した。Phase A 完了後は空 DB が手元にあり、Phase B 完了後は spool/ にファイルが出る、という具合。Phase が壊れてる時は前の Phase を疑うんではなく、その Phase 内の Task の前後を疑う。
- TDD コミット境界を厳格に。RED で「失敗するテスト」しか入っていない、GREEN で「最小実装」しか入っていない、を `git show` で確認できる粒度で進める。混ぜない。
- swiftcap の framework 直叩き部分（SpeechAnalyzer / SNAudioStreamAnalyzer / ScreenCaptureKit）は実機・TCC が要るため自動テストせず、protocol で薄く分離して周辺を unit test にしている。実機 e2e は Phase B10 と E5。
- WWDC25 の SpeechAnalyzer API 名は実機で `analyzeSequence(from:)` ではなかった場合、TranscriberWrapper の最小修正で合わせる。spec §3.1 / §12 の参照ドキュメント名を維持する。
- PicoRuby:wasm の制約（`Hash#fetch` / inline `rescue` 等禁止、regex_light は ASCII のみ）に違反していないか、`web/assets/app.rb` を一読する。
- spec §8 の repo 構成と本 plan のファイル作成位置の差分が無いか、Phase A1 完了直後にツリーを比較。
- 旧 fluent-plugin-* repo の archive（Task E3）はリポ外のオペレーション。本リポの作業完了後、別途実施。


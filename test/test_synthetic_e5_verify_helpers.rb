# test/test_synthetic_e5_verify_helpers.rb
#
# Pin verify_l2_fluentd and verify_l3_sqlite behavior against two
# realities observed in the 2026-05-06 E5 reverify and the subsequent
# 5x mini-E5 long-run (evidence: docs/superpowers/observations/...):
#
# 1. fluentd's foundation_model_mac filter emits a [warn] line every
#    time Apple's on-device LanguageModelSession refuses to polish a
#    transcript on guardrailViolation grounds. User has accepted this
#    as expected upstream behavior — raw text still lands in SQLite,
#    only the polished_text column is missing for those rows.
#
# 2. mic-channel transcript emission inside a 30-second window is
#    probabilistic. In real 15-min meetings we measure ~1 mic
#    transcript / minute (E5 reverify: 36 → 51), so a 30s synthetic
#    window legitimately produces 0 transcripts ~half the time.
#    Recording health is asserted at L1 via mic-*.caf RMS > threshold.
require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'sqlite3'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'lib', 'audio_transcription', 'migrator')
require File.join(REPO_ROOT, 'lib', 'audio_transcription', 'synthetic_e5')

class TestSyntheticE5VerifyHelpers < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir('e5-verify-test-')
    %w[tmp/log tmp/run db spool].each { |d| FileUtils.mkdir_p(File.join(@tmp, d)) }
    @e5 = AudioTranscription::SyntheticE5.new(repo_root: @tmp)
    @e5.instance_variable_set(:@baseline, {
      cafs: [],
      audio_segments: 0,
      mic_transcripts: 0,
      screen_transcripts: 0
    })
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_verify_l2_treats_foundation_model_guardrail_warn_as_benign
    log = File.join(@tmp, 'tmp', 'log', 'fluentd.log')
    File.write(log, <<~LOG)
      2026-05-06 23:02:43 +0900 [info]: starting fluentd-1.19.2 pid=1234
      2026-05-06 23:02:45 +0900 [warn]: #0 dump an error event: error_class=AppleFoundationModel::GenerationError error="guardrailViolation(FoundationModels.LanguageModelSession.GenerationError.Context(debugDescription: \\"Response may contain sensitive or unsafe content\\", ...))" tag="audio.final"
    LOG
    @e5.send(:verify_l2_fluentd)
    assert_empty @e5.failures,
                 'foundation_model guardrailViolation warn must be whitelisted (acceptable upstream behavior, 2026-05-06 E5 reverify observation)'
  end

  def test_verify_l2_still_flags_genuinely_unexpected_warn_lines
    log = File.join(@tmp, 'tmp', 'log', 'fluentd.log')
    File.write(log, <<~LOG)
      2026-05-06 23:02:45 +0900 [warn]: out_sqlite_meeting_log: failed to open db, retrying...
    LOG
    @e5.send(:verify_l2_fluentd)
    assert_equal 1, @e5.failures.size
    assert_match(/\[L2\]/, @e5.failures.first)
  end

  def test_verify_l3_does_not_fail_when_mic_delta_zero_but_screen_delta_positive
    setup_db_with(mic_count: 0, screen_count: 2)
    @e5.send(:verify_l3_sqlite)
    mic_failures = @e5.failures.select { |m| m.include?('[L3]') && m.include?('mic') }
    assert_empty mic_failures,
                 'mic delta=0 over a 30-second window is probabilistic and must not block L3 (recording health is asserted at L1 via CAF RMS)'
  end

  def test_verify_l3_still_fails_when_screen_delta_zero
    setup_db_with(mic_count: 0, screen_count: 0)
    @e5.send(:verify_l3_sqlite)
    assert(@e5.failures.any? { |m| m.include?('[L3]') && m.include?('screen') },
           'screen delta=0 must still hard-fail L3 (ScreenCaptureKit gives clean system audio; zero transcripts means the pipeline is broken)')
  end

  private

  def setup_db_with(mic_count:, screen_count:)
    db_path = File.join(@tmp, 'db', 'meeting_log.sqlite')
    AudioTranscription::Migrator.new(db_path).run
    db = SQLite3::Database.new(db_path)
    db.execute('INSERT INTO sessions (started_at, ended_at) VALUES (?, ?)', [0, 0])
    sid = db.last_insert_row_id
    mic_count.times do |i|
      db.execute(
        "INSERT INTO transcripts (session_id, channel, raw_text, polished_text, started_at, ended_at, language, swiftcap_transcript_id) VALUES (?, 'mic', ?, '', ?, ?, 'ja-JP', ?)",
        [sid, "m#{i}", i.to_f, i.to_f + 1.0, "u-mic-#{i}"]
      )
    end
    screen_count.times do |i|
      db.execute(
        "INSERT INTO transcripts (session_id, channel, raw_text, polished_text, started_at, ended_at, language, swiftcap_transcript_id) VALUES (?, 'screen', ?, '', ?, ?, 'ja-JP', ?)",
        [sid, "s#{i}", i.to_f, i.to_f + 1.0, "u-screen-#{i}"]
      )
    end
    db.execute(
      "INSERT INTO audio_segments (channel, started_at, ended_at, duration_sec, codec, bytes, blob) " \
      "VALUES ('mic', 0.0, 5.0, 5.0, 'caf', 0, ?)",
      ['']
    )
    db.close
  end
end

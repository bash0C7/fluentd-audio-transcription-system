# lib/audio_transcription/synthetic_e5.rb
require 'sqlite3'
require 'json'
require 'shellwords'

module AudioTranscription
  class SyntheticE5
    LAYERS = %i[L1_swiftcap L2_fluentd L3_sqlite L4_ack L5_processes].freeze

    # Int16 PCM RMS threshold. The synthetic test plays a sine sweep through
    # speakers; mic captures faint bleed at ~80-100 RMS. 50 cleanly separates
    # "mic actually capturing audio" (any bleed > 50) from "mic dead silent"
    # (RMS = 0 or very near it, the silent-failure mode this test guards against).
    SILENCE_RMS_THRESHOLD = 50
    REPO_ROOT = File.expand_path('../..', __dir__)

    attr_reader :failures

    def initialize(repo_root: REPO_ROOT)
      @repo_root = repo_root
      @spool_dir = File.join(@repo_root, 'spool')
      @db_path   = File.join(@repo_root, 'db', 'meeting_log.sqlite')
      @log_dir   = File.join(@repo_root, 'tmp', 'log')
      @run_dir   = File.join(@repo_root, 'tmp', 'run')
      @fixture   = File.join(@repo_root, 'test', 'fixtures', 'synthetic_e5_audio.aiff')
      @failures  = []
      @baseline  = {}
    end

    def run
      prepare_clean_state
      capture_baseline
      sh('bundle exec rake start:all') or fail!(:start, 'start:all failed')
      # Wait for fluentd in_tail to actually open the spool files; the
      # previous fixed `sleep 5` was sometimes too short and the first
      # rotate event escaped the tail position.
      fail!(:start, 'fluentd worker did not become ready within 30s') unless wait_until_fluentd_ready
      afplay_pid = Process.spawn('afplay', @fixture, [:out, :err] => '/dev/null')
      sleep 30
      Process.kill('TERM', afplay_pid) rescue nil
      Process.wait(afplay_pid) rescue nil
      # SpeechAnalyzer / RotatingRecorder finalize lag — without this the
      # last final transcript can land *after* stop:all, missing the L3
      # delta assertion.
      sleep 2
      sh('bundle exec rake stop:all') or fail!(:stop, 'stop:all failed')
      verify_layers
      @failures
    end

    private

    # Reset state that would poison assertions:
    # - fluentd.log: prior run's [error]/[warn] lines would fail L2
    # - stale pid files (dead PIDs from killed test processes) would fail L5
    def prepare_clean_state
      log_path = File.join(@log_dir, 'fluentd.log')
      File.truncate(log_path, 0) if File.exist?(log_path)
      Dir.glob(File.join(@run_dir, '*.pid')).each do |f|
        pid = File.read(f).to_i rescue nil
        File.delete(f) rescue nil if pid.nil? || pid <= 0 || !pid_alive?(pid)
      end
    end

    def pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def capture_baseline
      @baseline[:cafs] = Dir.glob(File.join(@spool_dir, '*.caf'))
      @baseline[:audio_segments] = count_audio_segments
      @baseline[:mic_transcripts]    = count_transcripts_with_time(channel: 'mic')
      @baseline[:screen_transcripts] = count_transcripts_with_time(channel: 'screen')
    end

    def verify_layers
      verify_l1_swiftcap
      verify_l2_fluentd
      verify_l3_sqlite
      verify_l4_ack
      verify_l5_processes
    end

    def verify_l1_swiftcap
      new_cafs = Dir.glob(File.join(@spool_dir, '*.caf')) - @baseline[:cafs]
      mics = new_cafs.select { |p| File.basename(p).start_with?('mic-') }
      screens = new_cafs.select { |p| File.basename(p).start_with?('screen-') }
      fail!(:L1, 'no new mic-*.caf produced during synthetic run') if mics.empty?
      fail!(:L1, 'no new screen-*.caf produced during synthetic run') if screens.empty?
      mics.each do |p|
        rms = caf_rms(p)
        fail!(:L1, "mic CAF rms=#{rms} <= silence threshold #{SILENCE_RMS_THRESHOLD} (#{File.basename(p)})") if rms <= SILENCE_RMS_THRESHOLD
      end
      screens.each do |p|
        rms = caf_rms(p)
        fail!(:L1, "screen CAF rms=#{rms} <= silence threshold #{SILENCE_RMS_THRESHOLD} (#{File.basename(p)})") if rms <= SILENCE_RMS_THRESHOLD
      end
    end

    # Whitelist of fluentd [warn]/[error] patterns that are non-blocking
    # observations rather than regression signals:
    # - "Oj is not installed": informational, never affects pipeline
    # - "guardrailViolation" / "AppleFoundationModel::GenerationError":
    #   on-device polish-step refuses to process some screen transcripts
    #   that Apple's Foundation Model judges as sensitive. Raw text still
    #   lands in SQLite (the L3 screen delta covers it); only the
    #   polished_text column is missing for those rows. User has
    #   accepted this as expected upstream behavior — see
    #   docs/superpowers/observations/2026-05-06-e5-reverify.md §1.
    L2_BENIGN_WARN_PATTERNS = [
      /Oj is not installed/,
      /guardrailViolation/,
      /AppleFoundationModel::GenerationError/
    ].freeze

    def verify_l2_fluentd
      log_path = File.join(@log_dir, 'fluentd.log')
      return fail!(:L2, "fluentd.log missing at #{log_path}") unless File.exist?(log_path)
      bad = File.foreach(log_path).select do |line|
        line =~ /\[(error|warn)\]/ && L2_BENIGN_WARN_PATTERNS.none? { |re| line =~ re }
      end
      fail!(:L2, "fluentd.log contains #{bad.size} unexpected error/warn lines:\n#{bad.first(5).join}") unless bad.empty?
    end

    def verify_l3_sqlite
      with_db do |db|
        # mic ch over a 30s synthetic window: SpeechAnalyzer needs to
        # decide that speaker-bleed audio captured by the mic crosses
        # its language-confidence threshold to emit a transcript. In
        # real 15-minute meetings we measure ~1 mic transcript / minute
        # (E5 reverify: 36 → 51 over 15 min), so the 30-second mini
        # window is well below the rate where a non-zero count is
        # guaranteed. Mic-channel recording health is asserted at L1
        # via mic-*.caf RMS > SILENCE_RMS_THRESHOLD; L3 mic delta is
        # a soft signal (logged-only) so the synthetic acceptance gate
        # does not flake on a probabilistic SpeechAnalyzer outcome.
        mic_delta = db.get_first_value(
          "SELECT COUNT(*) FROM transcripts WHERE channel='mic' AND ended_at > 0.0"
        ) - @baseline[:mic_transcripts]
        $stderr.puts "  L3 info: mic transcripts delta=#{mic_delta} (recording verified at L1 via CAF RMS; transcript emission probabilistic over 30s)" if mic_delta <= 0

        screen_delta = db.get_first_value(
          "SELECT COUNT(*) FROM transcripts WHERE channel='screen' AND ended_at > 0.0"
        ) - @baseline[:screen_transcripts]
        fail!(:L3, "no new screen transcripts (delta=#{screen_delta})") if screen_delta <= 0

        s = db.get_first_value("SELECT COUNT(*) FROM audio_segments WHERE duration_sec > 0.0")
        fail!(:L3, "no audio_segments with non-zero duration_sec (count=#{s})") if s <= 0
      end
    end

    def verify_l4_ack
      # In the new model, swiftcap deletes a CAF the moment it receives an ack
      # over swiftcap.sock. So a successful ack manifests as: an audio_segments
      # row exists for a CAF whose file is no longer present on disk.
      reached_parity = wait_until(timeout: 15.0, poll: 0.3) do
        rotated = count_audio_segments - @baseline[:audio_segments]
        acked = count_acked_via_deletion(rotated)
        rotated > 0 && acked >= rotated
      end
      unless reached_parity
        rotated = count_audio_segments - @baseline[:audio_segments]
        acked = count_acked_via_deletion(rotated)
        fail!(:L4, "ack-driven CAF deletion never caught up: rotated=#{rotated} acked=#{acked} (polled 15s)")
      end
    end

    def verify_l5_processes
      remaining = Dir.glob(File.join(@run_dir, '*.pid')).reject { |p| File.basename(p) == '.keep' }
      fail!(:L5, "leftover pid files: #{remaining.map { |p| File.basename(p) }.join(', ')}") unless remaining.empty?
      stragglers = `pgrep -f 'fluentd -c config|puma -C web|caffeinate -dimsu'`.lines.map(&:strip).reject(&:empty?)
      fail!(:L5, "leftover processes: pids=#{stragglers.join(',')}") unless stragglers.empty?
    end

    def count_audio_segments
      with_db do |db|
        db.get_first_value('SELECT COUNT(*) FROM audio_segments')
      end
    rescue SQLite3::SQLException
      0
    end

    # An ack causes swiftcap to delete the CAF. So acked-count for a session is
    # rotated_count minus the number of new CAFs still on disk that haven't been
    # acked yet.
    def count_acked_via_deletion(rotated_count)
      present_now = Dir.glob(File.join(@spool_dir, '*.caf')).reject { |p| @baseline[:cafs].include?(p) }.size
      rotated_count - present_now
    end

    def count_transcripts_with_time(channel:)
      with_db do |db|
        db.get_first_value(
          'SELECT COUNT(*) FROM transcripts WHERE channel=? AND ended_at > 0.0',
          [channel]
        )
      end
    rescue SQLite3::SQLException
      0
    end

    def with_db
      db = SQLite3::Database.new(@db_path, readonly: true)
      yield db
    ensure
      db&.close
    end

    # Returns the RMS energy of a CAF file's PCM data, or 0 if decode fails.
    # Uses afconvert (macOS standard) to dump to s16-LE WAV then computes RMS.
    def caf_rms(path)
      tmp = "/tmp/caf-rms-#{Process.pid}-#{rand(1_000_000)}.wav"
      ok = system("afconvert -f WAVE -d LEI16 -c 1 -r 16000 #{path.shellescape} #{tmp} > /dev/null 2>&1")
      return 0 unless ok
      data = File.binread(tmp)
      pcm = data[44..]  # strip RIFF header
      samples = pcm.unpack('s<*')
      return 0 if samples.empty?
      sumsq = samples.reduce(0) { |acc, s| acc + s * s }
      Math.sqrt(sumsq.to_f / samples.size).to_i
    ensure
      File.delete(tmp) rescue nil
    end

    def sh(cmd)
      system(cmd)
    end

    # Polls the block until it returns truthy or `timeout` seconds
    # elapse. Returns the truthy condition value (or true) on success,
    # false on timeout. `poll` is the gap between checks.
    def wait_until(timeout:, poll: 0.2)
      deadline = Time.now + timeout
      loop do
        return true if yield
        return false if Time.now >= deadline
        sleep poll
      end
    end

    def wait_until_fluentd_ready
      log_path = File.join(@log_dir, 'fluentd.log')
      wait_until(timeout: 30.0, poll: 0.2) do
        File.exist?(log_path) &&
          File.foreach(log_path).any? { |l| l.include?('fluentd worker is now running') }
      end
    end

    def fail!(layer, msg)
      @failures << "[#{layer}] #{msg}"
      $stderr.puts "FAIL #{layer}: #{msg}"
    end
  end
end

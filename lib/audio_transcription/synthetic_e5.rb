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
      sleep 5
      afplay_pid = Process.spawn('afplay', @fixture, [:out, :err] => '/dev/null')
      sleep 30
      Process.kill('TERM', afplay_pid) rescue nil
      Process.wait(afplay_pid) rescue nil
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
      @baseline[:rotated_count] = count_rotated
      @baseline[:ack_count] = count_ack
      @baseline[:transcripts_with_time] = count_transcripts_with_time
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

    def verify_l2_fluentd
      log_path = File.join(@log_dir, 'fluentd.log')
      return fail!(:L2, "fluentd.log missing at #{log_path}") unless File.exist?(log_path)
      bad = File.foreach(log_path).select do |line|
        line =~ /\[(error|warn)\]/ && line !~ /Oj is not installed/
      end
      fail!(:L2, "fluentd.log contains #{bad.size} unexpected error/warn lines:\n#{bad.first(5).join}") unless bad.empty?
    end

    def verify_l3_sqlite
      with_db do |db|
        t = db.get_first_value("SELECT COUNT(*) FROM transcripts WHERE ended_at > 0.0") - @baseline[:transcripts_with_time]
        fail!(:L3, "no new transcripts with non-zero ended_at (delta=#{t})") if t <= 0
        s = db.get_first_value("SELECT COUNT(*) FROM audio_segments WHERE duration_sec > 0.0")
        fail!(:L3, "no audio_segments with non-zero duration_sec (count=#{s})") if s <= 0
      end
    end

    def verify_l4_ack
      rotated = count_rotated - @baseline[:rotated_count]
      ack = count_ack - @baseline[:ack_count]
      fail!(:L4, "ack count #{ack} != rotated count #{rotated} (1:1 expected)") if ack != rotated
    end

    def verify_l5_processes
      remaining = Dir.glob(File.join(@run_dir, '*.pid')).reject { |p| File.basename(p) == '.keep' }
      fail!(:L5, "leftover pid files: #{remaining.map { |p| File.basename(p) }.join(', ')}") unless remaining.empty?
      stragglers = `pgrep -f 'swiftcap|fluentd -c config|puma -C web|caffeinate -dimsu'`.lines.map(&:strip).reject(&:empty?)
      fail!(:L5, "leftover processes: pids=#{stragglers.join(',')}") unless stragglers.empty?
    end

    def count_rotated
      path = File.join(@spool_dir, 'state.jsonl')
      return 0 unless File.exist?(path)
      File.foreach(path).count { |l| l.include?('"kind":"rotated"') }
    end

    def count_ack
      path = File.join(@spool_dir, 'ack.jsonl')
      return 0 unless File.exist?(path)
      File.foreach(path).count
    end

    def count_transcripts_with_time
      with_db { |db| db.get_first_value('SELECT COUNT(*) FROM transcripts WHERE ended_at > 0.0') }
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

    def fail!(layer, msg)
      @failures << "[#{layer}] #{msg}"
      $stderr.puts "FAIL #{layer}: #{msg}"
    end
  end
end

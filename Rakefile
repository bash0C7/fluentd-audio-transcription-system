# Rakefile
require 'rake/testtask'
require 'fileutils'

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

REPO_ROOT  = File.expand_path(__dir__)
SPOOL_DIR  = ENV['SPOOL_DIR'] || File.join(REPO_ROOT, 'spool')
DB_PATH    = ENV['DB_PATH']   || File.join(REPO_ROOT, 'db', 'meeting_log.sqlite')
LOG_DIR    = File.join(REPO_ROOT, 'tmp', 'log')
SWIFTCAP_BIN = File.join(REPO_ROOT, 'swift', 'swiftcap', '.build', 'release', 'swiftcap')

RUN_DIR = File.join(REPO_ROOT, 'tmp', 'run')

# wait_sec table per CLAUDE.md graceful-shutdown discipline
# (CAF rotation, fluentd buffer flush, puma drain, etc).
WAIT_SEC = { 'swiftcap' => 30, 'fluentd' => 60, 'web' => 10, 'caffeinate' => 5 }.freeze

def process_alive?(pid)
  return false if pid.nil? || pid <= 0
  Process.kill(0, pid)
  true
rescue Errno::ESRCH, Errno::EPERM
  false
end

# Graceful, single-SIGTERM stop. Reads pidfile, sends TERM, waits up to wait_sec.
# Aborts (no SIGKILL escalation) if the process refuses to exit — silent SIGKILL
# during graceful drain costs transcripts.
def stop_via_pidfile(name, wait_sec, has_screen: true)
  pidfile = File.join(RUN_DIR, "#{name}.pid")
  if File.exist?(pidfile)
    pid = File.read(pidfile).to_i
    if process_alive?(pid)
      puts "stopping #{name} (pid=#{pid}), waiting up to #{wait_sec}s for graceful shutdown..."
      begin
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        # raced — process already gone
      end
      deadline = Time.now + wait_sec
      sleep(0.2) while process_alive?(pid) && Time.now < deadline
      if process_alive?(pid)
        abort "#{name} did not exit within #{wait_sec}s (pid=#{pid}). Investigate — do NOT SIGKILL: graceful drain failure indicates a bug in the service."
      end
      puts "stopped: #{name}"
    else
      puts "stale pidfile for #{name} (pid=#{pid} not alive)"
    end
    File.delete(pidfile) rescue nil
  else
    puts "no pidfile: #{name}"
  end
  system("screen -X -S audio-#{name} quit > /dev/null 2>&1") if has_screen
end

namespace :start do
  desc 'Start swiftcap (mic + screen capture daemon) in screen session "audio-swiftcap"'
  task :swiftcap do
    unless File.executable?(SWIFTCAP_BIN)
      sh 'cd swift/swiftcap && swift build -c release'
    end
    FileUtils.mkdir_p([SPOOL_DIR, LOG_DIR])
    locale = ENV['SWIFTCAP_LOCALE'] || 'ja-JP'
    sh "screen -dmS audio-swiftcap bash -c 'SWIFTCAP_SPOOL=#{SPOOL_DIR} SWIFTCAP_LOCALE=#{locale} #{SWIFTCAP_BIN} > #{LOG_DIR}/swiftcap.log 2>&1; echo DONE: exit=$? >> #{LOG_DIR}/swiftcap.log'"
    puts "started: audio-swiftcap (log: #{LOG_DIR}/swiftcap.log)"
  end

  desc 'Start fluentd in screen session "audio-fluentd"'
  task fluentd: 'db:migrate' do
    FileUtils.mkdir_p([SPOOL_DIR, LOG_DIR, File.dirname(DB_PATH)])
    %w[quick.jsonl final.jsonl sound.jsonl state.jsonl].each do |f|
      FileUtils.touch(File.join(SPOOL_DIR, f))
    end
    sh "screen -dmS audio-fluentd bash -c 'cd #{REPO_ROOT} && SPOOL_DIR=#{SPOOL_DIR} DB_PATH=#{DB_PATH} bundle exec fluentd -c config/fluent.conf -p lib/fluent/plugin > #{LOG_DIR}/fluentd.log 2>&1; echo DONE: exit=$? >> #{LOG_DIR}/fluentd.log'"
    puts "started: audio-fluentd (log: #{LOG_DIR}/fluentd.log)"
  end

  desc 'Start puma web server in screen session "audio-web"'
  task web: 'db:migrate' do
    FileUtils.mkdir_p([LOG_DIR, File.dirname(DB_PATH)])
    sh "screen -dmS audio-web bash -c 'cd #{REPO_ROOT} && DB_PATH=#{DB_PATH} bundle exec puma -C web/puma.rb web/config.ru > #{LOG_DIR}/web.log 2>&1; echo DONE: exit=$? >> #{LOG_DIR}/web.log'"
    puts "started: audio-web (log: #{LOG_DIR}/web.log → http://localhost:9292/)"
  end

  desc 'Start all 3 services (swiftcap, fluentd, web)'
  task all: %w[start:swiftcap start:fluentd start:web]
end

namespace :stop do
  # Process names hosted in each screen session — so we can SIGTERM them
  # directly and let the child run its cleanup (e.g. AVAssetWriter
  # finishWriting) before the screen session is torn down.
  GRACEFUL_PROCS = { 'swiftcap' => 'swiftcap', 'fluentd' => 'fluentd', 'web' => 'puma' }

  %w[swiftcap fluentd web].each do |name|
    desc "Stop audio-#{name} screen session (graceful SIGTERM, then session quit)"
    task name.to_sym do
      proc_name = GRACEFUL_PROCS.fetch(name)
      system("pkill -TERM -x #{proc_name}")
      sleep 3
      ok = system("screen -X -S audio-#{name} quit")
      puts ok ? "stopped: audio-#{name}" : "audio-#{name} was not running"
    end
  end

  desc 'Stop all 3 services'
  task all: %w[stop:swiftcap stop:fluentd stop:web]
end

desc 'Show running audio-* screen sessions'
task :status do
  out = `screen -ls 2>&1`
  matches = out.lines.grep(/audio-/)
  if matches.empty?
    puts 'no audio-* sessions running'
  else
    puts matches
  end
end

desc 'Tail a service log (rake "logs[swiftcap]" / [fluentd] / [web])'
task :logs, [:name] do |_, args|
  name = args[:name] || 'fluentd'
  path = File.join(LOG_DIR, "#{name}.log")
  abort "no log at #{path}" unless File.exist?(path)
  exec "tail -f #{path}"
end

task default: :test

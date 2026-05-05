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

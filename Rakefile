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

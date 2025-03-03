#!/usr/bin/env ruby
# fluentd-audio-transcription-systemセットアップスクリプト
# 音声録音→変換→文字起こし→ファイル出力の一連の流れを設定します

require 'erb'
require 'fileutils'

# 基本ディレクトリ設定
BASE_DIR = File.expand_path("~/fluentd-audio-transcription-system")
BUFFER_DIR = File.join(BASE_DIR, "buffer")
LOG_DIR = "/Users/#{ENV['USER']}/Library/Logs"
TEMPLATES_DIR = File.join(File.dirname(__FILE__), "templates")

# 前提条件のチェック
abort "Error: Homebrewがインストールされていません" unless system("which brew > /dev/null")
abort "Error: ffmpegがインストールされていません" unless system("which ffmpeg > /dev/null")
abort "Error: pyenvがインストールされていません" unless system("which pyenv > /dev/null")
abort "Error: rbenvがインストールされていません" unless system("which rbenv > /dev/null")
abort "Error: Python 3.11が利用できません" unless system("pyenv versions | grep 3.11 > /dev/null")
abort "Error: Ruby 3.4.1が利用できません" unless system("rbenv versions | grep 3.4.1 > /dev/null")

# セットアップディレクトリの作成（既存のディレクトリは維持）
puts "ディレクトリを作成しています..."
FileUtils.mkdir_p(BASE_DIR)
FileUtils.mkdir_p(File.join(BUFFER_DIR, "audio_recorder"))
FileUtils.mkdir_p(File.join(BUFFER_DIR, "audio_transcoder"))
FileUtils.mkdir_p(File.join(BUFFER_DIR, "audio_transcriber"))
FileUtils.mkdir_p(File.join(BUFFER_DIR, "out_file"))
FileUtils.mkdir_p(File.join(BASE_DIR, "logs"))
FileUtils.mkdir_p(LOG_DIR) unless Dir.exist?(LOG_DIR)

# Ruby環境のセットアップ
puts "Ruby環境をセットアップしています..."
Dir.chdir(BASE_DIR) do
  system("rbenv local 3.4.1")
  
  # Gemfileの生成
  gemfile_template = File.read(File.join(TEMPLATES_DIR, "Gemfile.erb"))
  File.write("Gemfile", ERB.new(gemfile_template).result(binding))
  
  # Bundlerの設定とインストール
  system("bundle config set --local path vendor/bundle")
  system("bundle install")
end

# Python環境のセットアップ
puts "Python環境をセットアップしています..."
Dir.chdir(BASE_DIR) do
  system("pyenv local 3.11")
  system("pyenv exec python -m venv myenv") unless Dir.exist?(File.join(BASE_DIR, "myenv"))
  system("source myenv/bin/activate && pip install mlx-whisper")
end

# Fluentd設定ファイルの生成
puts "Fluentd設定ファイルを生成しています..."
fluent_conf_template = File.read(File.join(TEMPLATES_DIR, "fluent.conf.erb"))
File.write(File.join(BASE_DIR, "fluentd.conf"), ERB.new(fluent_conf_template).result(binding))

# 実行スクリプトの生成
puts "実行スクリプトを生成しています..."
run_sh_template = File.read(File.join(TEMPLATES_DIR, "run.sh.erb"))
File.write(File.join(BASE_DIR, "run.sh"), ERB.new(run_sh_template).result(binding))
system("chmod +x #{File.join(BASE_DIR, "run.sh")}")

# cronジョブ設定ファイルの生成
puts "バッファクリーンアップスクリプトを作成しています..."
cleanup_sh_template = File.read(File.join(TEMPLATES_DIR, "cleanup.sh.erb"))
cleanup_path = File.join(BASE_DIR, "cleanup.sh")
File.write(cleanup_path, ERB.new(cleanup_sh_template).result(binding))
system("chmod +x #{cleanup_path}")

puts "cronジョブ設定ファイルを作成しています..."
crontab_template = File.read(File.join(TEMPLATES_DIR, "crontab.erb"))
crontab_path = File.join(BASE_DIR, "crontab")
File.write(crontab_path, ERB.new(crontab_template).result(binding))

# newsyslogの設定
puts "ログローテーション設定を作成しています..."
newsyslog_template = File.read(File.join(TEMPLATES_DIR, "newsyslog.conf.erb"))
newsyslog_conf = ERB.new(newsyslog_template).result(binding)
File.write(File.join(BASE_DIR, "fluentd_newsyslog.conf"), newsyslog_conf)
puts "以下のコマンドを実行してnewsyslogの設定を有効化してください："
puts "sudo cp #{File.join(BASE_DIR, "fluentd_newsyslog.conf")} /etc/newsyslog.d/"

puts "以下のコマンドを実行してcronジョブを設定してください："
puts "crontab #{crontab_path}"

puts "セットアップが完了しました！"
puts "Fluentdを実行するには以下のコマンドを使用してください："
puts "#{File.join(BASE_DIR, "run.sh")}"

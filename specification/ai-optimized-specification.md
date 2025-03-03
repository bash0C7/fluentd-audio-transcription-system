# SYSTEM_SPECIFICATION: fluentd-audio-transcription-system

## SYSTEM_DEFINITION
```
{
  "name": "fluentd-audio-transcription-system",
  "version": "1.0.0",
  "purpose": "macOS環境での音声録音・文字起こし自動化パイプライン",
  "workflow": ["audio_recording", "audio_transcoding", "audio_transcription", "file_output"],
  "platform": "macOS",
  "processor_recommendation": "Apple_Silicon"
}
```

## COMPONENT_PIPELINE
```
[
  {
    "id": "component_1",
    "name": "fluent-plugin-audio-recorder",
    "type": "source_plugin",
    "function": "音声録音",
    "input": "macOSデバイス音声",
    "output": "バイナリ音声データ",
    "output_tag": "audio.raw"
  },
  {
    "id": "component_2",
    "name": "fluent-plugin-audio-transcoder",
    "type": "filter_plugin",
    "function": "音声ノーマライズ",
    "input": "バイナリ音声データ",
    "output": "最適化済み音声データ",
    "input_tag": "audio.raw",
    "output_tag": "audio.raw"
  },
  {
    "id": "component_3",
    "name": "fluent-plugin-audio-transcriber",
    "type": "filter_plugin",
    "function": "音声文字起こし",
    "input": "最適化済み音声データ",
    "output": "文字起こしデータ",
    "input_tag": "audio.raw",
    "output_tag": "audio.raw",
    "uses_external": "MLX_Whisper"
  },
  {
    "id": "component_4",
    "name": "fluentd標準out_file",
    "type": "output_plugin",
    "function": "ファイル出力",
    "input": "文字起こしデータ",
    "output": "JSONファイル",
    "input_tag": "audio.raw",
    "output_location": "/Users/${USER}/Library/Logs/"
  }
]
```

## PREREQUISITES
```
{
  "hardware": {
    "platform": "macOS",
    "processor_recommended": "Apple_Silicon"
  },
  "software": {
    "required": [
      {"name": "FFmpeg", "binary_check": "which ffmpeg"},
      {"name": "Homebrew", "binary_check": "which brew"},
      {"name": "pyenv", "binary_check": "which pyenv", "version": {"command": "pyenv --version"}},
      {"name": "rbenv", "binary_check": "which rbenv", "version": {"command": "rbenv --version"}},
      {"name": "Python", "version": {"required": "3.11", "check_command": "pyenv versions | grep 3.11"}},
      {"name": "Ruby", "version": {"required": "3.4.1", "check_command": "rbenv versions | grep 3.4.1"}}
    ]
  }
}
```

## DIRECTORY_STRUCTURE
```
{
  "base_dir": "~/fluentd-audio-transcription-system",
  "subdirs": [
    {"path": "myenv", "purpose": "Python仮想環境", "preserve_on_update": true},
    {"path": "vendor/bundle", "purpose": "Ruby依存関係", "preserve_on_update": true},
    {"path": "buffer/audio_recorder", "purpose": "録音バッファ", "preserve_on_update": true},
    {"path": "buffer/audio_transcoder", "purpose": "変換バッファ", "preserve_on_update": true},
    {"path": "buffer/audio_transcriber", "purpose": "文字起こしバッファ", "preserve_on_update": true},
    {"path": "logs", "purpose": "Fluentdログ", "preserve_on_update": true}
  ],
  "files": [
    {"path": "Gemfile", "purpose": "Ruby依存関係定義", "preserve_on_update": false},
    {"path": ".ruby-version", "purpose": "Ruby環境設定", "preserve_on_update": false},
    {"path": ".python-version", "purpose": "Python環境設定", "preserve_on_update": false},
    {"path": "fluentd.conf", "purpose": "Fluentd設定", "preserve_on_update": false}
  ],
  "external_dirs": [
    {"path": "/Users/${USER}/Library/Logs/", "purpose": "文字起こし結果出力先", "preserve_on_update": true}
  ]
}
```

## PLUGIN_CONFIGURATIONS

### AUDIO_RECORDER_CONFIG
```
{
  "plugin_type": "source",
  "plugin_name": "audio_recorder",
  "tag": "audio.raw",
  "parameters": {
    "device": {"type": "integer", "value": 0, "description": "録音デバイス番号"},
    "silence_settings": {
      "silence_duration": {"type": "float", "value": 1.0, "description": "無音と判断する秒数"},
      "noise_level": {"type": "integer", "value": -30, "description": "無音判定のノイズレベル閾値(dB)"}
    },
    "duration_limits": {
      "min_duration": {"type": "integer", "value": 2, "description": "最小録音時間(秒)"},
      "max_duration": {"type": "integer", "value": 900, "description": "最大録音時間(秒)"}
    },
    "audio_settings": {
      "audio_codec": {"type": "string", "value": "aac", "description": "音声コーデック"},
      "audio_bitrate": {"type": "string", "value": "192k", "description": "ビットレート"},
      "audio_sample_rate": {"type": "integer", "value": 44100, "description": "サンプルレート"},
      "audio_channels": {"type": "integer", "value": 1, "description": "チャンネル数"}
    },
    "buffer_path": {"type": "string", "value": "${BASE_DIR}/buffer/audio_recorder", "description": "バッファパス"}
  }
}
```

### AUDIO_TRANSCODER_CONFIG
```
{
  "plugin_type": "filter",
  "plugin_name": "audio_transcoder",
  "match_tag": "audio.raw",
  "parameters": {
    "transcode_options": {"type": "string", "value": "-c:v copy -af loudnorm=I=-16:TP=-1.5:print_format=summary", "description": "FFmpeg変換オプション"},
    "output_extension": {"type": "string", "value": "mp3", "description": "出力ファイル拡張子"},
    "buffer_path": {"type": "string", "value": "${BASE_DIR}/buffer/audio_transcoder", "description": "バッファパス"}
  }
}
```

### AUDIO_TRANSCRIBER_CONFIG
```
{
  "plugin_type": "filter",
  "plugin_name": "audio_transcriber",
  "match_tag": "audio.raw",
  "parameters": {
    "model": {"type": "string", "value": "mlx-community/whisper-large-v3-turbo", "description": "Whisperモデル名"},
    "language": {"type": "string", "value": "ja", "description": "言語コード"},
    "initial_prompt": {"type": "string", "value": "これは日本語のビジネス会議や技術的な議論の文字起こしです。敬語表現、専門用語、固有名詞を正確に認識してください。", "description": "文字起こし初期プロンプト"}
  }
}
```

### OUT_FILE_CONFIG
```
{
  "plugin_type": "output",
  "plugin_name": "file",
  "match_tag": "audio.raw",
  "parameters": {
    "path": {"type": "string", "value": "/Users/${USER}/Library/Logs/audio_transcription", "description": "出力パス"},
    "append": {"type": "boolean", "value": true, "description": "追記モード"},
    "buffer": {
      "type": {"type": "string", "value": "file", "description": "バッファタイプ"},
      "path": {"type": "string", "value": "${BASE_DIR}/buffer/out_file", "description": "バッファパス"},
      "flush_interval": {"type": "string", "value": "5s", "description": "フラッシュ間隔"}
    },
    "format": {
      "type": {"type": "string", "value": "json", "description": "出力フォーマット"}
    }
  }
}
```

## INSTALLATION_PROCEDURE
```
[
  {
    "step": 1,
    "action": "directory_create",
    "target": "${BASE_DIR}",
    "condition": "!directory_exists(${BASE_DIR})"
  },
  {
    "step": 2,
    "action": "directory_create_recursive",
    "targets": "${SUBDIRS}",
    "skip_existing": true
  },
  {
    "step": 3,
    "action": "set_ruby_version",
    "command": "rbenv local 3.4.1",
    "working_dir": "${BASE_DIR}"
  },
  {
    "step": 4,
    "action": "set_python_version",
    "command": "pyenv local 3.11",
    "working_dir": "${BASE_DIR}"
  },
  {
    "step": 5,
    "action": "create_python_venv",
    "command": "pyenv exec python -m venv myenv",
    "working_dir": "${BASE_DIR}",
    "condition": "!directory_exists(${BASE_DIR}/myenv)"
  },
  {
    "step": 6,
    "action": "install_python_dependencies",
    "commands": [
      "source ${BASE_DIR}/myenv/bin/activate",
      "pip install mlx-whisper"
    ]
  },
  {
    "step": 7,
    "action": "create_gemfile",
    "target": "${BASE_DIR}/Gemfile"
  },
  {
    "step": 8,
    "action": "configure_bundler",
    "command": "bundle config set --local path vendor/bundle",
    "working_dir": "${BASE_DIR}"
  },
  {
    "step": 9,
    "action": "install_ruby_dependencies",
    "command": "bundle install",
    "working_dir": "${BASE_DIR}"
  },
  {
    "step": 10,
    "action": "create_fluentd_config",
    "target": "${BASE_DIR}/fluentd.conf"
  }
]
```

## GEMFILE_CONTENT
```ruby
source "https://rubygems.org"

gem "fluentd", "~> 1.16.2"
gem "fluent-plugin-audio-recorder", "~> 0.1.0"
gem "fluent-plugin-audio-transcoder", "~> 0.1.0"
gem "fluent-plugin-audio-transcriber", "~> 0.1.0"
```

## FLUENTD_CONFIG_TEMPLATE
```
<source>
  @type audio_recorder
  
  device 0
  silence_duration 1.0
  noise_level -30
  min_duration 2
  max_duration 900
  
  audio_codec aac
  audio_bitrate 192k
  audio_sample_rate 44100
  audio_channels 1
  
  tag audio.raw
  buffer_path ${BASE_DIR}/buffer/audio_recorder
</source>

<filter audio.raw>
  @type audio_transcoder
  
  transcode_options -c:v copy -af loudnorm=I=-16:TP=-1.5:print_format=summary
  output_extension mp3
  buffer_path ${BASE_DIR}/buffer/audio_transcoder
</filter>

<filter audio.raw>
  @type audio_transcriber
  
  model mlx-community/whisper-large-v3-turbo
  language ja
  initial_prompt これは日本語のビジネス会議や技術的な議論の文字起こしです。敬語表現、専門用語、固有名詞を正確に認識してください。
</filter>

<match audio.raw>
  @type file
  
  path /Users/${USER}/Library/Logs/audio_transcription
  append true
  
  <buffer>
    @type file
    path ${BASE_DIR}/buffer/out_file
    flush_interval 5s
  </buffer>
  
  <format>
    @type json
  </format>
</match>
```

## NEWSYSLOG_CONFIG
```
# logfilename                                      [owner:group]  mode  count  size   when  flags [/pid_file] [sig_num]
/Users/${USER}/Library/Logs/audio_transcription.*.log  :          644   5      10000  *     J
```

## EXECUTION_PROCEDURE
```
[
  {
    "step": 1,
    "action": "change_directory",
    "target": "${BASE_DIR}"
  },
  {
    "step": 2,
    "action": "activate_python_env",
    "command": "source myenv/bin/activate"
  },
  {
    "step": 3,
    "action": "start_fluentd",
    "command": "bundle exec fluentd -c fluentd.conf"
  }
]
```

## TROUBLESHOOTING
```
{
  "common_issues": [
    {
      "issue": "録音デバイスが見つからない",
      "check_command": "ffmpeg -f avfoundation -list_devices true -i \"\"",
      "resolution": "device設定を正しいデバイス番号に変更する"
    },
    {
      "issue": "MLX Whisper導入エラー",
      "check_command": "source ${BASE_DIR}/myenv/bin/activate && python -c \"import mlx_whisper; print(mlx_whisper.__version__)\"",
      "resolution": "pip install mlx-whisperを再実行"
    },
    {
      "issue": "Fluentdエラー",
      "check_command": "bundle exec fluentd -c fluentd.conf -v",
      "resolution": "詳細なログを確認して問題を特定"
    }
  ]
}
```

## MAINTENANCE
```
{
  "log_rotation": {
    "method": "newsyslog",
    "config_file": "/etc/newsyslog.d/fluentd-audio-transcription.conf"
  },
  "buffer_cleanup": {
    "method": "cron",
    "command": "find ${BASE_DIR}/buffer -type f -mtime +7 -delete",
    "schedule": "0 0 * * *"
  }
}
```

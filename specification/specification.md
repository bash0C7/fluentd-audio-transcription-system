# Fluentd音声文字起こしシステム仕様書

## 1. システム概要

このシステムは、macOS環境で音声を録音し、自動的に文字起こしを行うパイプラインを構築します。以下のFluentdプラグインを連携させて実現します：

1. **fluent-plugin-audio-recorder**: macOSのデバイスから音声を録音します。無音検出機能により、会話が終了すると自動的に録音を停止します。
2. **fluent-plugin-audio-transcoder**: 録音された音声データを文字起こしに最適化するためにノーマライズ処理を行います。
3. **fluent-plugin-audio-transcriber**: MLX Whisperを使用して音声を文字に変換します（日本語に最適化）。
4. **fluentd標準のout_fileプラグイン**: 文字起こし結果をファイルに出力します。

これらのプラグインをfluentd.confで接続し、一貫したパイプラインとして動作させます。

## 2. システム要件

### ハードウェア
- macOS搭載コンピュータ（Apple Siliconプロセッサ推奨）
- 音声入力デバイス（内蔵マイクまたは外部マイク）

### ソフトウェア前提条件
- **macOS**: Monterey (12.0) 以上
- **FFmpeg**: インストール済み
- **Homebrew**: インストール済み
- **pyenv**: インストール済み、Python 3.11が利用可能
- **rbenv**: インストール済み、Ruby 3.4.1が利用可能

## 3. システムアーキテクチャ

```
音声入力 → [audio-recorder] → [audio-transcoder] → [audio-transcriber] → [out_file] → 文字起こしファイル
```

- **audio-recorder**: 音声を録音し、無音を検出すると録音を停止
- **audio-transcoder**: 録音された音声を日本語文字起こしに最適化（ボリューム正規化など）
- **audio-transcriber**: MLX Whisperによる日本語音声の文字起こし
- **out_file**: 結果をファイルに出力（/Users/ユーザー名/Library/Logs/に保存）

## 4. ディレクトリ構造

```
~/fluentd-audio-transcription-system/
├── Gemfile                  # Rubyの依存関係
├── fluentd.conf             # Fluentd設定ファイル
├── myenv/                   # Python仮想環境
├── vendor/                  # Bundlerでインストールされたgem
├── buffer/                  # 各プラグインのバッファディレクトリ
│   ├── audio_recorder/      # 録音バッファ
│   ├── audio_transcoder/    # 変換バッファ
│   └── audio_transcriber/   # 文字起こしバッファ
└── logs/                    # Fluentdのログ
```

出力された文字起こし結果は `/Users/ユーザー名/Library/Logs/` に保存されます。

## 5. インストールと設定

### セットアップ手順

セットアップはスクリプト `setup.rb` を使用して行います。このスクリプトは以下の処理を実行します：

1. 必要なディレクトリの作成
2. Ruby環境の設定（rbenv local 3.4.1）
3. Python環境の設定（pyenv local 3.11、仮想環境の作成）
4. 必要なPythonパッケージのインストール（mlx-whisper）
5. Gemfileの作成とBundlerでの依存関係インストール
6. Fluentd設定ファイルの作成

### 実行方法

```bash
# セットアップ
ruby setup.rb

# Fluentdの起動
cd ~/fluentd-audio-transcription-system
source myenv/bin/activate
bundle exec fluentd -c fluentd.conf
```

## 6. プラグイン設定詳細

### fluent-plugin-audio-recorder

```
<source>
  @type audio_recorder
  
  # デバイス設定
  device 0                # 録音デバイス番号
  
  # 無音検出設定
  silence_duration 1.0    # 無音と判断する秒数
  noise_level -30         # 無音判定のノイズレベル閾値（dB）
  
  # 録音時間制限
  min_duration 2          # 最小録音時間（秒）
  max_duration 900        # 最大録音時間（秒）
  
  # 音声設定
  audio_codec aac         # 音声コーデック
  audio_bitrate 192k      # ビットレート
  audio_sample_rate 44100 # サンプルレート
  audio_channels 1        # チャンネル数
  
  # 出力設定
  tag audio.raw           # イベントタグ
  buffer_path /path/to/buffer/audio_recorder # バッファパス
</source>
```

### fluent-plugin-audio-transcoder

```
<filter audio.raw>
  @type audio_transcoder
  
  # 変換設定
  transcode_options -c:v copy -af loudnorm=I=-16:TP=-1.5:print_format=summary
  output_extension mp3
  buffer_path /path/to/buffer/audio_transcoder
</filter>
```

### fluent-plugin-audio-transcriber

```
<filter audio.raw>
  @type audio_transcriber
  
  # 文字起こし設定
  model mlx-community/whisper-large-v3-turbo
  language ja
  initial_prompt これは日本語のビジネス会議や技術的な議論の文字起こしです。敬語表現、専門用語、固有名詞を正確に認識してください。
</filter>
```

### out_file

```
<match audio.raw>
  @type file
  
  path /Users/ユーザー名/Library/Logs/audio_transcription
  append true
  
  <buffer>
    @type file
    path /path/to/buffer/out_file
    flush_interval 5s
  </buffer>
  
  <format>
    @type json
  </format>
</match>
```

## 7. ログとメンテナンス

### ログローテーション

ログのローテーションはmacOSのnewsyslogを使用して管理します。以下の設定を `/etc/newsyslog.d/fluentd-audio-transcription.conf` に配置します：

```
# logfilename                     [owner:group]  mode  count  size   when  flags [/pid_file] [sig_num]
/Users/ユーザー名/Library/Logs/audio_transcription.*.log  :  644   5      10000  *     J
```

### バッファクリーンアップ

一時バッファファイルは定期的にクリーンアップする必要があります。自動クリーンアップは以下の方法で設定できます：

```bash
# バッファファイルクリーンアップのcronジョブ例（7日以上前のファイルを削除）
0 0 * * * find ~/fluentd-audio-transcription-system/buffer -type f -mtime +7 -delete
```

## 8. トラブルシューティング

### 録音デバイスの確認

録音デバイスが正しく設定されていない場合、以下のコマンドでデバイス一覧を確認できます：

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

### Python環境の問題

MLX Whisperが正しく動作しない場合、仮想環境が正しく設定されているか確認してください：

```bash
cd ~/fluentd-audio-transcription-system
source myenv/bin/activate
python -c "import mlx_whisper; print(mlx_whisper.__version__)"
```

### Fluentdのデバッグ

Fluentdの詳細なログを確認するには、デバッグモードで起動します：

```bash
bundle exec fluentd -c fluentd.conf -v
```

## 9. 参考情報

- [Fluentd公式ドキュメント](https://docs.fluentd.org/)
- [MLX Whisper GitHub](https://github.com/ml-explore/mlx-examples/tree/main/whisper)
- [FFmpeg ドキュメント](https://ffmpeg.org/documentation.html)

---

本仕様書は人間とAIの両方が理解できるように設計されています。仕様の変更や更新が必要な場合は、このドキュメントを更新し、セットアップスクリプトを再実行してください。

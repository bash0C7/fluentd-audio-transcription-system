# Fluentd音声文字起こしシステム

macOSで動作する会議音声の自動録音・文字起こしシステムです。マイクからの音声を自動的に録音し、音声処理を行った後に文字起こしを行い、結果をファイルに保存します。

## システム概要

このシステムは以下のFluentdプラグインを連携させて動作します：

1. **fluent-plugin-audio-recorder**: マイク入力から音声を録音
2. **fluent-plugin-audio-transcoder**: 録音した音声を文字起こしに適した形式に変換
3. **fluent-plugin-audio-transcriber**: MLX Whisperを使用して音声を文字起こし
4. **Fluentd標準のout_fileプラグイン**: 文字起こし結果をファイルに保存

## 前提条件

このシステムを使用するには以下のソフトウェアが必要です：

- macOS (Apple Siliconプロセッサ推奨)
- Homebrew
- FFmpeg
- pyenv (Python 3.11)
- rbenv (Ruby 3.4.1)

## セットアップ方法

1. リポジトリをクローンする：
```bash
git clone https://github.com/yourusername/fluentd-audio-transcription-system.git
cd fluentd-audio-transcription-system
```

2. セットアップスクリプトを実行する：
```bash
ruby setup.rb
```

3. newsyslogの設定を有効化する（管理者権限が必要）：
```bash
sudo cp ~/fluentd-audio-transcription-system/fluentd_newsyslog.conf /etc/newsyslog.d/
```

4. cronジョブを設定する：
```bash
crontab ~/fluentd-audio-transcription-system/crontab
```

## 使用方法

以下のコマンドで音声文字起こしシステムを起動します：

```bash
~/fluentd-audio-transcription-system/run.sh
```

システムが起動すると、マイクからの音声を自動的に録音・文字起こしします。無音が検出されると録音が停止し、文字起こし処理が開始されます。

文字起こし結果は以下の場所に保存されます：
```
/Users/[ユーザー名]/Library/Logs/audio_transcription...
```

## ディレクトリ構造

```
~/fluentd-audio-transcription-system/
├── Gemfile                  # Rubyの依存関係
├── fluentd.conf             # Fluentd設定ファイル
├── myenv/                   # Python仮想環境
├── vendor/                  # Bundlerでインストールされたgem
├── buffer/                  # 各プラグインのバッファディレクトリ
│   ├── audio_recorder/      # 録音バッファ
│   ├── audio_transcoder/    # 変換バッファ
│   ├── audio_transcriber/   # 文字起こしバッファ
│   └── out_file/            # 出力バッファ
└── logs/                    # Fluentdのログ
```

## ログと一時ファイルの管理

ログファイルと一時ファイルは自動的に管理されます：

- **ログローテーション**: newsyslogによって5世代保存
- **バッファクリーンアップ**: cronジョブによって7日以上経過したファイルを削除

## カスタマイズ

各種設定は以下のファイルで調整できます：
```
~/fluentd-audio-transcription-system/fluentd.conf
```

主な設定項目：
- マイクデバイス番号
- 無音検出の閾値と時間
- 音声フォーマットとビットレート
- 文字起こしモデル
- 言語設定

## トラブルシューティング

### マイクデバイスの確認

使用可能なマイクデバイスを確認するには：
```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

### 文字起こしが機能しない場合

Python環境のセットアップが正しく行われているか確認：
```bash
cd ~/fluentd-audio-transcription-system
source myenv/bin/activate
python -c "import mlx_whisper; print(mlx_whisper.__version__)"
```

### Fluentdのデバッグ

Fluentdの詳細なログを確認するには：
```bash
cd ~/fluentd-audio-transcription-system
bundle exec fluentd -c fluentd.conf -v
```

## ライセンス

このプロジェクトはApache License 2.0の下で公開されています。

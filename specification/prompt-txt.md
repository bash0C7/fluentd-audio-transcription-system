あなたはRubyistでありfluentdとそのプラグイン開発に堪能で、macで開発と実行を行います。 - READMEは日本語で書いてください。 - ソースコード、テストコードのコメントやメッセージも日本語でかいてください - あなたの回答は日本語で解説してください。 1. fluent-plugin-audio-recorder -> 2. fluent-plugin-audio-transcoder -> 3. fluent-plugin-audio-transcriber -> 4. fluentd標準のout_fileプラグイン をfluentd.confで繋げて、1.の録音データを、2.で日本語の会議文字起こしに適したノーマライズ処理を行い、3.で文字起こしして、4.でファイルに吐き出すようにします。 fluentdはbundler経由でインストールし、pythonでの処理が内部にあるためfluentdの起動時には「source myenv/bin/activate」によってvirtualenv環境で立ち上がるように処置してください。

以下の生成AIのプロンプト文章を、人間と生成AIとが同じ理解ができるように、fluentd-audio-transcription-systemのmarkdown形式の日本語仕様書を生成してください。
今後この仕様書を生成AIに渡したら各種リソースが生成されることを意図しています。またこれをみて人間のプログラマーが細部を整えたり、仕様をアップデートして再生成させたりに使います。

それとは別に、このプロンプト全体をそのままprompt.txtとして保存してください。このままだと忘れ去りそうだからです。
------------------------------

1. fluent-plugin-audio-recorder -> 2. fluent-plugin-audio-transcoder -> 3. fluent-plugin-audio-transcriber -> 4. fluentd標準のout_fileプラグイン をfluentd.confで繋げて、1.の録音データを、2.で日本語の会議文字起こしに適したノーマライズ処理を行い、3.で文字起こしして、4.でファイルに吐き出すようにします。 fluentdはbundler経由でインストールし、pythonでの処理が内部にあるためfluentdの起動時には「source myenv/bin/activate」によってvirtualenv環境で立ち上がるように処置してください。

この統合的な実行を行うためのセットアップスクリプトを格納するrepoをつくりたいです。セットアップスクリプトテンプレートエンジンが使えるといいなと思うので、Rubygemsに依存せず、mac標準のruby 2.6.10p210の範囲でRubyスクリプト化してください。erbをテンプレートエンジンとして使って、セットアップのRubyスクリプト本体はロジックに集中してください


ここではセットアップスクリプトだけバージョン管理下におきます。

スクリプトですることをのべます。諸々を格納する場所として、~/**fluentd-audio-transcription-system ディレクトリをつくって**、作成が必要なbuffer_pathのディレクトリ類も~/**fluentd-audio-transcription-system 配下につくってください。**ただし、out_fileでの出力は/Users/bash/Library/Logs/に書き出してコンソール.appから開きやすい様にします。そして、以下の実現するfluentdの設定ファイルをつくってください。設定ファイル中のパスは先につくったディレクトリのフルパスをスクリプトで生成するようにしてください。スクリプトはzshとmacに入っているコマントで完結させてください。

1. fluent-plugin-audio-recorder -> 2. fluent-plugin-audio-transcoder -> 3. fluent-plugin-audio-transcriber -> 4. fluentd標準のout_fileプラグイン をfluentd.confで繋げて、1.の録音データを、2.で日本語の会議文字起こしに適したノーマライズ処理を行い、3.で文字起こしして、4.でファイルに吐き出すようにします。 fluentdはbundler経由でインストールし、pythonでの処理が内部にあるためfluentdの起動時には「source myenv/bin/activate」によってvirtualenv環境で立ち上がるように処置してください。


このsetup.shを最新化したら再度実行すればいいようにしたいです。fluentd設定ファイルなどのstaticなリソースは上書きしてください。ログやバッファーのディレクトリは維持してください。



バッファのクリーンアップとログのローテーションは、macなので newsyslog に任せてみたいのですがどうでしょうか。


pythonはpyenvにて 3.11がすでにシステムに入っている前提で、セットアップではpyenv local 3.11して、pyenv exec python -m venv myenv
して、source myenv/bin/activateして、pip install mlx-whisperするようにしてください。
rubyもrbenvで3.4.1がすでにシステムに入っている前提で、セットアップではrbenv local 3.4.1してbundlerではbundle config set --local path vendor/bundleしてから、bundle installするようにしてください。

ffmpegやhomebrewもすでにシステムに入っている前提です。

セットアップでは前提のものは存在確認してなければエラーで異常終了してください。実行時にはチェックは煩雑なので不要です。動かしてエラーがでたらユーザーで対象します。


setup.rbに直接ヒヤドキュメントで生成テンプレートを埋め込んでいますが、外部ファイルかしてsetup.rbはシンプルにしてください。そしてメソッドわけせずに一本道で書き下してください。abortさせるガード節はワンライナーでかいてください。動くドキュメントとしてのRubyスクリプトの原始的な可読性を重視します。
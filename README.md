# insta360-mic-pro-capture

Insta360 Mic ProをMacへ接続すると、WAVをローカルへ安全にコピーし、FluidAudioで日本語の文字起こしを行い、[chronixd-capture](https://github.com/azu/chronixd-capture)互換のNDJSONとして保存するSwift CLIです。32-bit floatや24-bitのWAV原本は変更せず、`ffmpeg`や変換済みの一時WAVも作りません。

自動取り込みの設計と安全条件は、[automatic-import.md](doc/engineer/design/automatic-import.md)にまとめています。

## Usage

```text
usage:
  insta360-mic-pro-capture process <audio.wav> --data-dir <path> [options]
  insta360-mic-pro-capture import <directory> --data-dir <path> [options]
  insta360-mic-pro-capture watch --data-dir <path> [options]
  insta360-mic-pro-capture status
  insta360-mic-pro-capture retry <job-id>
  insta360-mic-pro-capture agent install --data-dir <path> [options]
  insta360-mic-pro-capture agent status
  insta360-mic-pro-capture agent uninstall

options:
  --accepted-volume-name <name>       repeatable; default: MIC PRO
  --copy-policy <all|selected>        default: all
  --transcription-preference <list>   default: processed,orig
  --local-wav-policy <delete|move>    default: delete
  --device-wav-policy <keep|delete-after-publish>
  --no-notify-copy-complete
  --no-notify-processing-complete
```

## ビルド

macOS 14以降とSwift 6.2以降を使います。

```sh
swift build -c release
```

初回の文字起こし時だけ、[FluidAudio](https://github.com/FluidInference/FluidAudio)がParakeet TDT Japaneseモデルを取得します。モデルとジョブ情報は`~/Library/Application Support/Insta360MicProCapture/`へ保存します。

## ローカルWAVを処理する

```sh
.build/release/insta360-mic-pro-capture process \
  audio_260101_120000_32bit_processed.wav \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture"
```

結果は次のような日別ファイルへ保存します。

```text
<data-dir>/captures/2026-01-01_insta360-mic-pro.ndjson
```

ローカルWAVだけでは元のMic Proを判別できないため、`process`は従来の端末名を使います。

1行が1発話区間です。録音開始時刻は`audio_YYMMDD_HHmmss_*`というファイル名から日本時間として推定し、各区間の相対時刻を加えて`unixTimeMs`と`endUnixTimeMs`を作ります。ファイル名を解析できない場合は、ファイルの更新時刻を推定値として使います。

## Mic Proから1回だけ取り込む

```sh
.build/release/insta360-mic-pro-capture import "/Volumes/MIC PRO" \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture"
```

同じ録音に`processed`と`orig`がある場合、既定では両方をコピーし、文字起こしには`processed`を優先します。すべての未取り込みWAVをコピーしてから文字起こしを始めるため、コピー完了通知の後はMic Proを取り外せます。

WAVはSHA-256で重複判定します。NDJSONの保存と読み直し検証が終わるまで、作業用WAVは削除しません。正常完了後の既定動作は、Mac側の作業用WAVを削除し、Mic Pro側のWAVを残す設定です。

Mic Proから取り込んだ場合は、ボリュームUUIDの先頭8文字を端末IDとして使います。たとえば端末IDが`12345678`なら、NDJSONは`captures/2026-01-01_insta360-mic-pro-12345678.ndjson`、各レコードの`device`は`Insta360 Mic Pro 12345678`になります。複数のMic Proは別ファイルとして扱われます。ストレージをフォーマットしてUUIDが変わった場合は、新しい端末IDとして記録します。

`chronixd-capture`では、次のように特定のMic Proだけを選べます。

```sh
chronixd-capture context \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture" \
  --last 1h \
  --device insta360-mic-pro-12345678
```

## マウントを監視する

ターミナルで監視する場合は、次を実行します。

```sh
.build/release/insta360-mic-pro-capture watch \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture"
```

ログイン中に自動で監視するLaunchAgentを設定する場合は、ビルド済みCLIから次を実行します。外部の設定ファイルは使わず、指定した引数を生成済みplistの`ProgramArguments`へ保存します。

```sh
.build/release/insta360-mic-pro-capture agent install \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture" \
  --local-wav-policy delete \
  --device-wav-policy keep

.build/release/insta360-mic-pro-capture agent status
```

解除する場合は次を実行します。

```sh
.build/release/insta360-mic-pro-capture agent uninstall
```

LaunchAgentの標準出力とエラーは`~/Library/Logs/Insta360MicProCapture/agent.log`へ保存します。

## 状態確認と再開

ジョブはコピー済み、文字起こし中、公開中、完了、失敗の各状態をJSONへ原子的に保存します。失敗したジョブは、最後に成功した処理を再実行せずに再開できます。

```sh
.build/release/insta360-mic-pro-capture status
.build/release/insta360-mic-pro-capture retry <job-id>
```

## 主なオプション

```text
--accepted-volume-name <name>       対象名。複数回指定可能。既定はMIC PRO
--copy-policy <all|selected>        既定はall
--transcription-preference <list>   既定はprocessed,orig
--local-wav-policy <delete|move>    既定はdelete
--device-wav-policy <keep|delete-after-publish>
```

`--local-wav-policy move`では、処理後のWAVを`<data-dir>/audio/insta360-mic-pro-<device-id>/YYYY/MM/DD/<recording-id>/`へ移します。ローカルWAVを直接`process`した場合は、端末IDを付けず`audio/insta360-mic-pro/`を使います。

`--device-wav-policy delete-after-publish`は、NDJSONの検証後も接続されており、サイズと更新時刻が取り込み時から変わっていない個別WAVだけをMic Proから削除します。既定の`keep`ではMic Proの内容を変更しません。ストレージ全体のフォーマットや自動イジェクトは行いません。

## 既存CLIとの互換性

タイムスタンプ付き文字起こしJSONを作る旧コマンドは残しています。

```sh
swift run insta360-ja-transcribe audio.wav audio.transcript
```

## テスト

```sh
swift test
```

## GitHub Release

`vMAJOR.MINOR.PATCH`形式のタグをpushすると、GitHub Actionsがarm64向けのテストとリリースビルドを実行し、GitHub Releaseを作成します。

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

Releaseには、次の2ファイルを添付します。

```text
insta360-mic-pro-capture-v0.1.0-macos-arm64.tar.gz
insta360-mic-pro-capture-v0.1.0-macos-arm64.tar.gz.sha256
```

2ファイルを同じディレクトリへダウンロードした後、次のコマンドでアーカイブを検証できます。

```sh
shasum -a 256 -c insta360-mic-pro-capture-v0.1.0-macos-arm64.tar.gz.sha256
```

アーカイブには`insta360-mic-pro-capture`実行ファイルとREADMEを含めます。Release本文はGitHubの自動生成を使います。現時点ではDeveloper IDによる署名とAppleのnotarizationは行いません。

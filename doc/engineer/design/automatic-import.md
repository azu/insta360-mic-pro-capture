# Insta360 Mic Proの自動取り込みと文字起こし

- Status: Implemented (initial CLI)
- Updated: 2026-08-08

## 結論

`insta360-mic-pro-capture`をユーザー単位のLaunchAgentとして常駐させ、Insta360 Mic Proのマウントを検知したら、未取り込みのWAVをすべてローカルへ安全にコピーする。コピーが完了してから、ローカルのWAVをFluidAudioへ渡して文字起こしを行う。結果は`chronixd-capture`の`transcription`レコードと同じ形式へ変換し、指定したdata-dirの`captures/*.ndjson`へ保存する。

複数のMic Proは、マウントされたFAT32ボリュームのUUIDで区別する。公開用の端末IDにはUUIDの先頭8文字を小文字で使い、NDJSON、`device`フィールド、保存するWAVのディレクトリへ同じ値を反映する。ストレージのフォーマットでUUIDが変わった場合は、別の端末IDとして扱う。

文字起こし処理中にMic Proを外せるように、`/Volumes/MIC PRO`上のWAVは直接処理しない。ローカルへコピーした作業用WAVは、NDJSONの保存と検証が完了した後に既定で削除する。`--local-wav-policy move`を指定した場合だけ、作業用WAVをdata-dir内の音声保存先へ移動する。

Mic Pro上のWAVは既定で削除せず、ループ録音による古いファイルの上書きに任せる。Mic Proを短期的なバックアップとして利用しながら、SHA-256による重複判定で同じWAVを再処理しない。Mic Pro側も整理したい場合に限り、正常完了を確認したファイルを個別に削除する`--device-wav-policy delete-after-publish`を明示的に選択できる。ストレージ全体の自動フォーマットと自動イジェクトは行わない。

## 背景

当初のCLIは、WAVを手動でコピーしてから文字起こしコマンドを実行する構成だった。また、モデルの保存先がカレントディレクトリの`.models`に依存していたため、作業ディレクトリが一定ではないLaunchAgentからの実行には適していなかった。

Activityでは、`chronixd-capture`が指定されたdata-dirの`captures/`へ、日付とデバイス名を含むNDJSONを保存している。文字起こしは`type: "transcription"`のレコードとして扱われ、Activityの既存スクリプトもこの形式を読み取る。Mic Proの文字起こしも独自のJSONやMarkdownを正本にせず、このデータ経路へ直接追加する。

Insta360の公式マニュアルでは、送信機をUSBでコンピューターへ接続し、内部録音のWAVをコピーできる。ファイル名には、無加工のファイルを示す`orig`、加工済みのファイルを示す`processed`が含まれる。USB接続は録音済みファイルの書き出し用であり、リアルタイムの音声転送には対応していない。

公式マニュアルでは、ループ録音を有効にすると、ストレージが満杯になった時点で最も古いファイルから上書きされる。また、コンピューターから内部録音ファイルを個別に削除できる。通常運用ではループ録音を容量管理に使い、CLIによるMic Pro側の削除は既定で無効にする。

## 目的

- Mic Proを接続するだけで、未取り込みのWAVをローカルへコピーできる。
- コピー完了後は、Mic Proを外しても文字起こしが継続する。
- WAV原本を変更せず、16-bit WAVなどの変換済みファイルを作らない。
- 同じMic Proを繰り返し接続しても、同一のWAVを重複して保存、処理しない。
- コピー中の切断や文字起こしの失敗から、安全に再開できる。
- ファイル名から推定した録音開始時刻と、音声内の相対タイムスタンプを保存する。
- バックグラウンド処理の状態と失敗理由をCLIから確認できる。
- Mic Proの文字起こしを`chronixd-capture`互換のNDJSONとしてActivityのdata-dirへ保存できる。

## 非目的

- Mic Pro上のWAVは既定では削除しない。`--device-wav-policy delete-after-publish`を指定した場合だけ、取り込みとNDJSONの検証が完了した個別ファイルを削除できる。
- Mic Proのストレージ全体を自動フォーマットしない。
- Mic Proを自動的にイジェクトしない。
- Bluetooth経由で録音を開始、停止、転送しない。
- 初期実装ではメニューバーアプリや設定画面を作らない。
- 音声内容の要約や外部サービスへのアップロードは行わない。

## システムフロー

```text
LaunchAgentがwatchを起動
        ↓
起動済みボリュームを走査し、以後のマウント通知を監視
        ↓
Mic Proらしいボリュームを検証
        ↓
未取り込みWAVを列挙して録音単位に整理
        ↓
必要な空き容量とファイルの安定状態を確認
        ↓
全WAVをローカルの.partialへコピーしながらSHA-256を計算
        ↓
サイズとハッシュを記録し、正式なファイル名へ変更
        ↓
「コピー完了・取り外し可能」を通知
        ↓
ローカルWAVを処理キューへ追加
        ↓
文字起こし
        ↓
chronixd-capture互換のtranscriptionレコードへ変換
        ↓
data-dir/capturesの日別NDJSONへ保存
        ↓
NDJSONを読み直して、必要なレコードが揃っていることを検証
        ↓
localWavPolicyに従って作業用WAVを削除、またはdata-dir内へ移動
        ↓
deviceWavPolicyがdeleteAfterPublishなら、対象の個別WAVだけを削除
```

Mic Proに未取り込みのWAVが複数ある場合は、文字起こしよりコピーを優先する。これにより、ユーザーがMic Proを接続しておく時間を短くする。

## CLIインターフェース

1つの実行ファイルが、手動処理、自動取り込み、常駐監視を提供する。

```sh
# ローカルWAVを1件処理する
insta360-mic-pro-capture process audio.wav \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture"

# 指定したボリュームまたはディレクトリから1回だけ取り込む
insta360-mic-pro-capture import "/Volumes/MIC PRO" \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture"

# マウントを監視する
insta360-mic-pro-capture watch \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture"

# ジョブの状態を一覧する
insta360-mic-pro-capture status

# 失敗したジョブを再開する
insta360-mic-pro-capture retry <job-id>

# ユーザー単位のLaunchAgentを設定・解除する
insta360-mic-pro-capture agent install \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture" \
  --local-wav-policy delete \
  --device-wav-policy keep
insta360-mic-pro-capture agent status
insta360-mic-pro-capture agent uninstall
```

既存の`insta360-ja-transcribe`は、共通ライブラリを呼ぶ互換用コマンドとして残せる。自動取り込み処理から別のCLIを子プロセスとして起動せず、同じSwiftプロセス内のサービスを直接呼び出す。

外部の設定ファイルは持たない。`process`、`import`、`watch`はコマンド引数から実行条件を受け取り、`agent install`は同じ引数をLaunchAgentのplistへ保存する。

## コンポーネント

共通処理を`Insta360Core`ライブラリへ移し、CLIから利用する。

```text
Sources/
├── Insta360Core/
│   ├── RuntimeOptions.swift
│   ├── MountWatcher.swift
│   ├── VolumeRecognizer.swift
│   ├── RecordingDiscovery.swift
│   ├── RecordingImporter.swift
│   ├── JobStore.swift
│   ├── JobRunner.swift
│   ├── TranscriptionService.swift
│   ├── ChronixdTranscriptionRecord.swift
│   ├── CaptureRecordPublisher.swift
│   └── NotificationService.swift
├── Insta360MicProCapture/
│   └── AutomaticCLI.swift
└── Insta360JaTranscribe/
    └── main.swift
```

`JobRunner`はactorとして実装し、文字起こしジョブを直列に実行する。複数のCore ML処理が同時に走ってメモリ使用量や処理時間が不安定になることを避ける。モデルは最初のジョブで遅延読み込みし、`watch`プロセスが動作している間は再利用する。

## マウント検知

`watch`は、`NSWorkspace.shared.notificationCenter`の`didMountNotification`を監視する。通知を受け取る前からMic Proが接続されている場合に備えて、起動時には`FileManager.mountedVolumeURLs`でもマウント済みボリュームを列挙する。

マウントパスが`/Volumes/MIC PRO`であることだけではMic Proと断定しない。次の条件を組み合わせる。

- ローカルのリムーバブルボリュームである。
- ボリューム名が、設定された候補名と一致する。初期値は`MIC PRO`とする。
- `audio_YYMMDD_HHmmss_*_orig.wav`または`audio_YYMMDD_HHmmss_*_processed.wav`に一致するファイルが存在する。

ボリュームUUIDを取得できる場合はジョブ情報へ保存し、UUIDの先頭8文字を公開用の端末IDとして使う。ただし、特定のUUIDだけを受け入れる設定にはせず、複数の送信機やストレージ初期化後の新しいUUIDも取り込む。UUIDを取得できない場合と、ローカルWAVを直接`process`する場合は、互換性のため端末IDのない`insta360-mic-pro`へフォールバックする。

初期実装ではDisk Arbitrationを利用しない。`NSWorkspace`と`FileManager`で必要な検知ができない事例が確認された場合に、デバイス情報の取得手段として追加する。

## WAVの発見と処理対象

ファイル名から、録音ID、録音開始時刻、ビット深度、種類を抽出する。

```text
audio_260101_120000_32bit_processed.wav
      └──────┬─────┘ └─┬─┘ └───┬───┘
        録音開始時刻  深度     種類
```

録音IDは、まず`audio_YYMMDD_HHmmss`を使用する。同じ録音IDで内容の異なるファイルが見つかった場合は、SHA-256の先頭8文字を付けて衝突を避ける。

見つかったWAVは種類にかかわらず保存する。文字起こしに使用するWAVは、設定された優先順で選択する。

```text
--copy-policy all
--transcription-preference processed,orig
```

`processed`には、Mic Proで有効にした低音カット、ノイズ除去、指向性、音色、オートゲインなどが反映されるため、文字起こしでは初期値として`processed`を優先する。`processed`が存在しない場合は`orig`を直接処理する。

ステレオ内部録音は`Original`に限定される。ステレオWAVを処理する場合も変換済みWAVは作らず、読み込み中にメモリ上でモノラルへ変換する。FluidAudioへステレオWAVを直接渡す経路は、実装時に実ファイルで検証する。

ファイル名から時刻を取得できないWAVもコピーは行う。その場合はファイル更新時刻を録音開始時刻の代替値として使い、`recordingStartSource`を`filesystem-mtime-fallback`と記録する。更新時刻は録音時刻と一致しない可能性があるため、推定値として扱う。

## コピーと整合性

コピー元のWAVは読み取り専用として扱う。コピー先では最初に`.partial`を付け、コピーが完了するまで正式なファイル名を作らない。

```text
audio.wav.partial
        ↓ コピー完了、バイト数確認、FileHandleを同期
audio.wav
```

コピー中にCryptoKitでSHA-256を計算する。同じファイルをハッシュ計算のためだけに再度読み込まず、Mic Proを接続しておく時間を増やさない。

マウント直後にファイルサイズと更新時刻を取得し、短い間隔を置いて再取得する。値が変化しているファイルはコピーを開始しない。Mic ProはUSB接続時に録音済みファイルを書き出す仕様だが、破損や不完全なファイルを取り込まないための防御として実施する。

コピー中にMic Proが外れた場合は、そのジョブを`failed`へ移し、再開地点を`copying`として保存する。次回のマウント時に古い`.partial`を削除してコピーをやり直す。コピー完了前のファイルを文字起こしへ渡さない。

Mic Pro上のファイルはコピー中には変更しない。`deviceWavPolicy`が`deleteAfterPublish`の場合も、コピーの完了を削除条件にはしない。更新後のNDJSONを一時ファイルへ書き出し、正式なファイル名へ変更してから読み直し、ジョブに対応する録音IDと必要なレコードが揃っていることを確認した後に削除候補とする。

## 重複判定

ジョブの最終的な識別子にはWAVのSHA-256を使用する。ファイル名だけでは、送信機の時計変更、ストレージ初期化、同名ファイルの再生成を区別できないためである。

マウント時の高速な事前判定には、次の値を使用できる。

- ボリュームUUID
- ボリューム内の相対パス
- ファイルサイズ
- ファイル更新時刻

事前判定の値が既存ジョブと完全に一致する場合はコピーを省略できる。一致しない場合はコピーしながらハッシュを計算し、既存のSHA-256と一致した時点で重複として扱う。

## ジョブの状態

ジョブは次の状態を持つ。

```text
discovered
    ↓
copying
    ↓
copied
    ↓
transcribing
    ↓
publishing
    ↓
completed

各状態 ──→ failed
```

`completed`は、文字起こしレコードをNDJSONへ書き出しただけではなく、そのNDJSONを読み直して録音IDに対応する全レコードを確認できた状態とする。`failed`には、失敗した処理、再開地点、エラーの種類、試行回数を保存する。`retry`は、完了済みの処理を再実行せず、最後に成功した状態の次から再開する。

WAVの整理結果はジョブ本体の状態と分け、`cleanup.localWav`と`cleanup.deviceWav`へ記録する。`localWav`は`pending`、`deleted`、`moved`、`failed`、`deviceWav`は`pending`、`kept`、`deleted`、`failed`のいずれかとする。NDJSONの保存後にWAVの削除が失敗しても、文字起こしを再実行せず、整理だけを再試行できるようにする。

ジョブ情報の例を示す。

```json
{
  "id": "sha256:...",
  "state": "completed",
  "resumeFrom": null,
  "source": {
    "volumeName": "MIC PRO",
    "volumeUUID": "12345678-9ABC-4DEF-8123-456789ABCDEF",
    "relativePath": "audio_260101_120000_32bit_processed.wav",
    "size": 345702400,
    "sha256": "..."
  },
  "recording": {
    "startedAt": "2026-01-01T12:00:00+09:00",
    "startSource": "filename-inferred",
    "variant": "processed"
  },
  "cleanup": {
    "localWav": "deleted",
    "deviceWav": "kept"
  },
  "options": {
    "dataDir": "/Users/example/Library/CloudStorage/Dropbox/activity-capture",
    "localWavPolicy": "delete",
    "deviceWavPolicy": "keep"
  },
  "publication": {
    "files": ["captures/2026-01-01_insta360-mic-pro-12345678.ndjson"],
    "recordCount": 12
  },
  "attempts": 1,
  "lastError": null
}
```

ジョブの更新は、一時ファイルへJSONを書き出してから名前を変更する。プロセスの強制終了でJSONが途中まで書かれることを防ぐ。

## 保存先

作業用WAVはApplication Support配下のspoolへコピーする。文字起こし結果は、`--data-dir`で指定された`chronixd-capture`と同じdata-dirへ保存する。data-dirは利用者ごとに異なり、自動検出すると誤った場所へ書き込む可能性があるため、`watch`と`agent install`では指定を必須とする。

```text
~/Library/Application Support/Insta360MicProCapture/spool/
└── <job-id>/
    └── audio_260101_120000_32bit_processed.wav

<data-dir>/
├── captures/
│   ├── 2026-01-01_<hostname>.ndjson          # chronixd-capture
│   └── 2026-01-01_insta360-mic-pro-12345678.ndjson # このCLI
└── audio/                                     # moveを指定した場合だけ作成
    └── insta360-mic-pro-12345678/2026/08/08/
        └── audio_260101_120000/
            └── audio_260101_120000_32bit_processed.wav
```

`localWavPolicy`の初期値は`delete`とする。ジョブが`completed`になった後、spoolのWAVを削除する。`move`の場合は、spoolのWAVを`<data-dir>/audio/insta360-mic-pro-<device-id>/<録音日>/<録音ID>/`へ移動する。文字起こしが失敗している間は、どちらの指定でも`retry`に使用するWAVをspoolへ残す。

## chronixd互換の文字起こし形式

1つの発話区間を、`chronixd-capture`の`TranscriptionRecord`と同じ1行1レコードのNDJSONとして保存する。

```json
{"device":"Insta360 Mic Pro 12345678","endUnixTimeMs":1767236406820,"sessionId":"aaaaaaaa","text":"テスト録音です。","type":"transcription","unixTimeMs":1767236401480}
```

各フィールドの意味を示す。

| フィールド | 内容 |
| --- | --- |
| `type` | 常に`transcription` |
| `unixTimeMs` | 録音開始時刻に発話区間の相対開始時刻を加えたUnixミリ秒 |
| `endUnixTimeMs` | 録音開始時刻に発話区間の相対終了時刻を加えたUnixミリ秒 |
| `sessionId` | 録音単位を表す8文字の16進数。録音のSHA-256から決定的に生成する |
| `text` | 発話区間の文字起こし |
| `device` | `Insta360 Mic Pro <device-id>`。端末IDはボリュームUUIDの先頭8文字 |
| `rms` | 発話区間の平均音量を計算した場合だけ保存する |

`chronixd-capture`の文字起こしレコードには`id`がないため、このCLIも独自の`id`を追加しない。再処理の防止にはジョブのSHA-256を使い、各レコードは安定した`sessionId`、時刻、JSONのキー順で決定的に生成する。Activity側の取り込み処理は`id`のないレコードを行全体で比較するため、同一レコードは重複して取り込まれない。

日付は各レコードの`unixTimeMs`をローカルタイムへ変換して決める。録音が日付をまたぐ場合は、発話区間ごとに対応する日付のファイルへ分ける。ファイル名は`YYYY-MM-DD_insta360-mic-pro-<device-id>.ndjson`とし、`chronixd-capture`が書く`YYYY-MM-DD_<hostname>.ndjson`とは分離する。たとえば`chronixd-capture context --device insta360-mic-pro-12345678`から、特定のMic Pro由来の記録だけを選択できる。

このCLIだけが`*_insta360-mic-pro-<device-id>.ndjson`を書き込む。既存ファイルをすべてNDJSONとして検証し、新しいレコードを加えた内容を一時ファイルへ書き出して同期した後、同一ディレクトリ内で正式なファイル名へ置き換える。置き換え後にファイルを読み直し、今回の全レコードを確認できた時点でジョブを`completed`とする。

モデル、グローバルなジョブ情報、ログはdata-dirと分離する。外部の設定ファイルは作成しない。

```text
~/Library/Application Support/Insta360MicProCapture/models/
~/Library/Application Support/Insta360MicProCapture/jobs/
~/Library/Logs/Insta360MicProCapture/agent.log
```

実行時のカレントディレクトリへ依存しない。すべてのパスは、コマンド引数またはFoundationの標準ディレクトリAPIから絶対パスとして解決する。

## 実行オプション

実行条件は設定ファイルではなくコマンド引数で指定する。`watch`を直接実行する例を示す。

```sh
insta360-mic-pro-capture watch \
  --data-dir "$HOME/Library/CloudStorage/Dropbox/activity-capture" \
  --accepted-volume-name "MIC PRO" \
  --copy-policy all \
  --transcription-preference processed,orig \
  --local-wav-policy delete \
  --device-wav-policy keep
```

`--data-dir`はNDJSONを公開する`process`、`import`、`watch`、`agent install`で必須とする。それ以外の指定を省略した場合は、安全な初期値を使用する。初期値は、対象ボリューム名が`MIC PRO`、すべてのWAVをコピー、`processed`を文字起こしへ優先、ローカルWAVは正常完了後に削除、Mic Pro上のWAVは保持とする。

主なオプションを示す。

| オプション | 値 | 初期値 |
| --- | --- | --- |
| `--data-dir` | `chronixd-capture`と共有するdata-dir | 必須 |
| `--accepted-volume-name` | 対象にするボリューム名。複数回指定可能 | `MIC PRO` |
| `--copy-policy` | `all`または`selected` | `all` |
| `--transcription-preference` | 優先順をカンマ区切りで指定 | `processed,orig` |
| `--local-wav-policy` | `delete`または`move` | `delete` |
| `--device-wav-policy` | `keep`または`delete-after-publish` | `keep` |

不明なオプションや値は、処理を開始する前にエラーとする。特に端末上の原本を暗黙に削除しないように、不明な`--device-wav-policy`を`keep`へ読み替えない。

## WAVの整理

既定値は、Mac側の作業用WAVを正常完了後に削除し、Mic Pro側のWAVを残す構成とする。

```text
localWavPolicy:  delete
deviceWavPolicy: keep
Mic Proの設定:   Loop Recordingを利用者が有効化
```

この構成では、Macへ音声を長期保存しない一方、Mic Proの空き容量が必要になるまで端末上の原本を復旧用として利用できる。再接続時に端末上の同じWAVを発見しても、保存済みの事前判定情報とSHA-256で処理済みと判断し、コピーと文字起こしを繰り返さない。

`--device-wav-policy`が`delete-after-publish`の場合は、次の条件をすべて満たす個別ファイルだけを削除する。Swift内部の列挙値は`deleteAfterPublish`とする。

- ローカルコピーのバイト数とSHA-256を記録できている。
- ジョブが`completed`で、保存したNDJSONを読み直して検証できている。
- 削除対象がジョブに記録したボリュームと相対パスに一致する。
- 削除直前のファイルサイズと更新時刻が、発見時の値から変化していない。
- Mic Proが引き続き同じマウント先として接続されている。

ファイル名のパターンやワイルドカードを使った一括削除は行わない。条件を満たさない場合や削除に失敗した場合は、文字起こしジョブを`failed`へ戻さず、`cleanup.deviceWav`を`pending`または`failed`として記録する。`status`から未整理であることを確認でき、次回の接続時に整理だけを再試行できる。

## LaunchAgent

`agent install`は、ビルド済みの実行ファイルを固定パスへ配置し、ユーザーの`~/Library/LaunchAgents`へplistを作成する。LaunchAgentから`swift run`は使用しない。

`agent install`は`watch`と同じ実行オプションを受け取る。パスに含まれる`~`を展開して標準化し、plistの`ProgramArguments`へ実行ファイル、`watch`、各オプションをそれぞれ独立した文字列として保存する。LaunchAgentからシェルを経由しないため、plistへ`$HOME`などの環境変数や引用符を残さない。

同じ引数での`agent install`は何度実行しても同じplistになるようにする。引数が変わった場合はplistを原子的に置き換えてLaunchAgentを再読み込みする。`agent status`は、起動状態とplistに保存された実効引数を表示する。plistはユーザーが編集する設定ファイルではなく、`agent install`が生成、更新するLaunchAgent定義として扱う。

plistでは、少なくとも次を設定する。

```text
Label: com.github.azu.insta360-mic-pro-capture
ProgramArguments:
  <absolute-binary-path>
  watch
  --data-dir
  <absolute-data-dir-path>
  --local-wav-policy
  delete
  --device-wav-policy
  keep
RunAtLoad: true
KeepAlive: true
ProcessType: Background
StandardOutPath: ~/Library/Logs/Insta360MicProCapture/agent.log
StandardErrorPath: ~/Library/Logs/Insta360MicProCapture/agent.log
```

通常は必要時に起動するLaunchAgentが望ましいが、今回は`NSWorkspace`のマウント通知を受け取る必要があるため、ユーザーのログイン中は`watch`を常駐させる。待機中はポーリングを行わず、CPUを消費しない。

`SIGTERM`を受け取った場合は、新しいジョブの受け付けを停止し、進行中の状態を保存して終了する。LaunchAgent自身でforkやdaemonizeは行わない。

## 権限

macOSではリムーバブルボリュームがファイルアクセスのプライバシー管理対象になる。初回セットアップ時は、固定パスへインストールしたCLIを手動で起動し、Mic Proを接続してアクセスできることを確認する。

権限がない場合は、空のボリュームとして扱わず、`permissionDenied`として記録する。エラーには対象パスと、macOSの「プライバシーとセキュリティ」にあるファイルとフォルダ、またはリムーバブルボリュームの設定を確認する必要があることを含める。

初期実装ではApp Sandboxを有効にしない。将来、アプリとして配布する場合は、ユーザーが選択した保存先とMic Proへのアクセスをsecurity-scoped bookmarkとして保存する設計へ変更する。

## 通知と状態確認

次のタイミングで通知する。

- Mic Pro上の未取り込みWAVをすべてコピーし終えたとき。「コピー完了。Mic Proを取り外せます」と表示する。
- 文字起こしがすべて完了したとき。保存したNDJSONのパスとレコード数を表示する。
- コピーまたは処理に失敗し、利用者の操作が必要なとき。短い理由と`status`コマンドを表示する。

`--device-wav-policy delete-after-publish`であっても、コピー完了後の取り外しを妨げない。文字起こし完了前にMic Proが取り外された場合は、端末側の削除を`pending`として残し、次回のマウント時に条件を再検証して実行する。

CLIだけで開始するため、通知は`NotificationService`として分離する。最初の実装ではmacOS標準の`/usr/bin/osascript`を固定メッセージで呼び出せる。通知の失敗はジョブの失敗にせず、必ずログと`status`でも確認できるようにする。

`status`は、少なくとも次を表示する。

```text
WATCHING  mount watcher is running
COPYING   audio_260101_120000_32bit_processed.wav 63%
COPIED    3 files; safe to eject MIC PRO
RUNNING   audio_260101_120000 transcription 42%
DONE      audio_260101_120000 -> captures/2026-01-01_insta360-mic-pro-12345678.ndjson (12 records)
CLEANUP   device WAV deletion pending; reconnect MIC PRO
FAILED    permissionDenied: /Volumes/MIC PRO
```

## エラー処理

| 状況 | 処理 |
| --- | --- |
| Mic Proではないボリュームがマウントされた | 無視し、デバッグログだけを残す |
| WAVが存在しない | 正常終了として扱う |
| 保存先の空き容量が不足している | コピー開始前に失敗させる |
| コピー中にMic Proが外れた | `.partial`を未完了として扱い、次回マウント時に再コピーする |
| コピー済みWAVと同じSHA-256だった | 重複として処理を省略する |
| ファイル名が解析できない | コピーし、時刻を推定値として記録する |
| WAVを開けない | 原本を残し、ジョブを`failed`にする |
| 文字起こしに失敗した | ローカルコピーから`retry`できるようにする |
| NDJSONの保存または検証に失敗した | ローカルの処理結果を残し、`publishing`から再開する |
| 既存のMic Pro用NDJSONに壊れた行がある | ファイルを上書きせず、対象ファイルと行番号を表示する |
| ローカルWAVの削除または移動に失敗した | ジョブは完了済みのまま、整理処理だけを再試行する |
| Mic Pro上の個別WAV削除に失敗した | 原本を残し、`cleanup.deviceWav`へ失敗理由を記録する |
| 不明なオプションや不正な値が指定された | 常駐監視を開始せず、対象の引数と許可される値を表示する |
| モデル取得にネットワークが必要 | コピーは完了させ、モデル取得後に処理を再開する |

## セキュリティとプライバシー

- 音声、文字起こし、モデル処理は利用者が指定したローカルパスに保持する。
- 利用者が指定しない限り、ネットワークへ音声や文字起こしを送信しない。
- data-dirにDropboxなどの同期ディレクトリを指定した場合、その同期は保存先サービスの設定に従う。CLI自身はアップロード処理を持たない。
- ネットワークアクセスはFluidAudioモデルの初回取得だけに限定する。
- Mic Pro上のファイルは、`--device-wav-policy delete-after-publish`による検証済みの個別削除を除いて読み取り専用として扱う。
- ログへ文字起こし本文を出さない。
- ログへSHA-256全体を出す必要はなく、ジョブの識別には先頭8文字を表示する。

## テスト方針

実際のMic Proを必要としないテストでは、一時ディレクトリをマウント先として扱い、通知より後の処理を検証する。

- 対象ファイル名の解析と、無関係なWAVの除外。
- `processed`優先と`orig`へのフォールバック。
- 複数WAVのコピーが完了するまで文字起こしを開始しないこと。
- 同じSHA-256のWAVを再取り込みしないこと。
- 同じファイル名で内容が異なるWAVを別ジョブとして扱うこと。
- `.partial`からの再コピー。
- 各状態からの`retry`。
- ジョブJSONの原子的な更新。
- 権限エラーと容量不足を別のエラーとして表示すること。
- `chronixd-capture`の`TranscriptionRecord`と同じフィールド名と型でエンコードすること。
- ファイル名を`YYYY-MM-DD_insta360-mic-pro-<device-id>.ndjson`とし、録音が日付をまたぐ場合はレコードを分割すること。
- ボリュームUUIDの先頭8文字から、同じ端末ID、`device`フィールド、WAV保存ディレクトリを決定的に生成すること。
- 同じ録音から同じ`sessionId`と同じNDJSON行を決定的に生成すること。
- 同一レコードを再公開してもNDJSONへ重複追加しないこと。
- `chronixd-capture context --data-dir <fixture> --device insta360-mic-pro-<device-id>`で公開済みレコードを読み取れること。
- Activityの`merge-capture-ndjson.mjs`で同一レコードが重複して取り込まれないこと。
- `localWavPolicy: delete`では、NDJSONの検証前にspoolのWAVを削除しないこと。
- `localWavPolicy: move`では、完了後にspoolのWAVをdata-dir内の`audio/`へ移動すること。
- `deviceWavPolicy: keep`では、Mic Pro上のWAVを変更しないこと。
- `deviceWavPolicy: deleteAfterPublish`では、未完了、NDJSONの検証失敗、サイズまたは更新時刻が変化したWAVを削除しないこと。
- WAVの整理に失敗しても、完了済みの文字起こしを再実行しないこと。
- `watch`と`agent install`が同じ実行オプションを解釈すること。
- `agent install`がパスを絶対パスへ変換し、引数をplistの`ProgramArguments`へ順序どおり保存すること。
- 同じ引数で`agent install`を再実行してもplistの内容が変わらないこと。

実機テストでは、次を確認する。

- 未接続状態で`watch`を起動し、その後Mic Proを接続すると取り込みが始まる。
- Mic Proを接続した状態で`watch`を起動しても取り込みが始まる。
- コピー完了通知の後にMic Proを外しても文字起こしが完了する。
- コピー途中でMic Proを外し、再接続すると最初から安全にコピーし直す。
- 同じMic Proを再接続しても新しいファイルだけを取り込む。
- ループ録音を有効にしてMic Pro上の取り込み済みWAVを残しても、再接続時に重複処理しない。
- `delete-after-publish`を有効にした場合、NDJSONの検証後に対象の個別WAVだけを削除する。
- ログアウト後にプロセスが終了し、再ログイン後にLaunchAgentが監視を再開する。

## 採用しない構成

### `/Volumes`の定期ポーリング

短い間隔のポーリングは不要なディスクアクセスを発生させる。マウント通知と起動時の列挙を組み合わせる。

### Mic Pro上のWAVを直接文字起こしする

文字起こし中はMic Proを外せず、切断時に長時間処理が失敗する。ローカルコピー完了後に処理する。

### LaunchAgentから`swift run`を実行する

ビルド、カレントディレクトリ、SwiftPMキャッシュ、PATHへ依存する。固定パスのビルド済み実行ファイルを使う。

### 初期実装からメニューバーアプリを作る

自動コピーと文字起こしの成立確認にUIは必須ではない。CLIの`status`、ログ、完了通知で運用を確認する。

## 実装完了の条件

- `process`、`import`、`watch`、`status`、`retry`が同じ実行ファイルから利用できる。
- 外部の設定ファイルを作成せず、通常実行ではコマンド引数、常駐実行ではplistの`ProgramArguments`から同じ実行条件を取得する。
- Mic Proのマウント後、利用者の操作なしで未取り込みWAVがローカルへコピーされる。
- コピー完了後にMic Proを外しても、文字起こしが完了する。
- 同じWAVを再処理しない。
- 中断したコピーと文字起こしを再開できる。
- `chronixd-capture`互換の`transcription`レコードがdata-dirの`captures/*.ndjson`へ保存される。
- `chronixd-capture context`とActivityの既存取り込み処理がMic Proのレコードを読み取れる。
- 録音開始時刻の根拠と、原本WAVから公開したNDJSONレコードの対応を`job.json`で確認できる。
- `localWavPolicy`に従って、正常完了後の作業用WAVを削除またはdata-dir内へ移動できる。
- Mic Pro上のWAVを既定では保持し、`delete-after-publish`の場合だけ検証済みの個別ファイルを削除できる。
- Mic Proのストレージ全体を自動フォーマットしない。
- 主要な正常系、重複、中断、権限エラーが自動テストで確認される。

## 参考資料

- [Insta360 Mic Pro: Internal Recording with Transmitter](https://onlinemanual.insta360.com/micpro/en-us/operation-tutorial/function/internal-recording)
- [Insta360 Mic Pro: Swipe down - Control Center](https://onlinemanual.insta360.com/micpro/en-us/camera/receiver-usage/control-center)
- [Apple Developer Documentation: NSWorkspace.didMountNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didmountnotification)
- [Apple Developer Documentation: FileManager](https://developer.apple.com/documentation/foundation/filemanager)
- [Apple Developer Documentation: URLResourceValues.volumeUUIDString](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeuuidstring)
- [Apple: Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [Apple Platform Security: Controlling app access to files in macOS](https://support.apple.com/en-euro/guide/security/secddd1d86a6/web)
- [FluidAudio: Models](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)

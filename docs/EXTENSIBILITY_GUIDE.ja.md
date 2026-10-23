English: [EXTENSIBILITY_GUIDE.md](EXTENSIBILITY_GUIDE.md) / 日本語版: このファイル

# WinEase 拡張ガイド

WinEase 本体のコードを書き換えずに、自分用の設定・スクリプト・バックアップ対象を足すためのガイドです。

- **第1部 初心者向けクイックスタート** … ファイルに数行足すだけでできること
- **第2部 リファレンス** … フォルダ構成、カスタムスクリプトの仕組み、エラー時の扱い、安全な動作確認

ユーザーが編集するファイルは `config/user/` に、カスタムスクリプトは `tools/custom-scripts/<Stage>/` にまとまっています。
どれも省略可能です。無ければ WinEase は拡張なしで普通に動きます。

---

# 第1部 初心者向けクイックスタート

## ① 自分用のレジストリ設定とチェックボックスを GUI に増やす

例として「Shift キーを5回押したときのスティッキーキーの確認画面を出さない」設定を足します。

### 手順

1. `config/user/user-tweaks.psd1` をメモ帳などで開きます。
2. `UserTweaks = @( ... )` の中に、次の4行ぶんのかたまりを書き足します(先頭の `#` を消すだけでも構いません)。

   ```powershell
   UserTweaks = @(
       @{
           Key         = 'User_DisableStickyKeysPrompt'
           Category    = 'UI'
           Default     = $false
           Description = '[User] Disable Sticky Keys (Shift x5) popup shortcut'
           Impact      = 'Safe'
           Actions     = @(
               @{ Type = 'Registry'; Hive = 'zNTUSER'; Path = 'Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Kind = 'String'; Value = '506' }
           )
       }
   )
   ```

3. 保存して、`WinEase-GUI.bat` で GUI を起動します。
4. `Category = 'UI'` なので **5. UI & Shell** タブの一番下にチェックボックスが増えています。
   `Security` / `Privacy` / `Performance` 以外のカテゴリ(`System`、`Gaming`、`UserCustom` など)にした場合は **9. User Tweaks** タブに出ます。
5. チェックを入れてビルドすると、フェーズ10(レジストリ)でその設定がイメージに書き込まれます。
   コマンドラインから使うときは `-TweakSettings @{ User_DisableStickyKeysPrompt = $true }` のようにハッシュテーブルで指定できます。

### 各項目の意味

| 項目 | 意味 |
| :--- | :--- |
| `Key` | 設定の名前。他と重複しないよう `User_` で始めるのを推奨。`config/schema.psd1` にあるキーと同じ名前は読み込み時に警告されて無視されます |
| `Category` | GUI のどのタブに出すか。上記の通り |
| `Default` | 初期状態でチェックを入れるか(`$true` / `$false`) |
| `Description` | チェックボックスの説明文 |
| `DescriptionJa` | 省略可。日本語表示(`-UiLanguage ja`)のときに GUI が代わりに表示する日本語の説明文。日本語を書くときは BOM 付き UTF-8 で保存してください |
| `Impact` | 依存関係チェックでの扱い。`'Safe'` は影響なし。省略すると「不明(Unknown)」として警告対象になります |
| `Actions` | 有効にしたときに実行する処理の一覧(下の表) |

### レジストリ設定の書き方

`Hive` にはオフラインイメージのレジストリを読み込んだ先の名前を書きます。`Path` はその下のキーで、`HKLM\` などは付けません。

| `Hive` | 対応する場所 |
| :--- | :--- |
| `zNTUSER` | 既定ユーザーの設定(新しく作られるユーザーに引き継がれる。`HKCU` 相当) |
| `zSOFTWARE` | `HKLM\SOFTWARE` 相当 |
| `zSYSTEM` | `HKLM\SYSTEM` 相当 |

`Kind` は `String` / `ExpandString` / `Binary` / `DWord` / `MultiString` / `QWord` のどれか(省略すると `String`)です。
サービスの起動方法を変えたいときは `@{ Type = 'Service'; Name = 'サービス名'; Value = 'Disabled' }`(`Disabled` / `Manual` / `Automatic`)も使えます。

### うまくいかないとき

- ビルド開始時の警告(`[UserExtensions] ...`)に、キー重複や必須項目(`Key` / `Category` / `Description`)の不足が出ます。
- 先に `-DryRun` で確認できます(第2部 ④ を参照)。実際のイメージには何も書き込まれません。

## ② 標準で対応していないゲームのセーブフォルダを移行対象に足す

PC 移行ツール(`tools/migrator/WinEase-Migrator.ps1`)は、標準で約30種類のゲームとアプリの設定に対応しています(`tools/migrator/migration-rules.psd1`)。
載っていないゲームは自分で足せます。

### 手順

1. `config/user/user-migration-rules.psd1` を開きます。
2. `GameRules = @( ... )` の中に、先頭の `#` を外して書き換えます。

   ```powershell
   GameRules = @(
       @{
           Id              = 'MyCustomGame'
           Name            = 'My Custom Game Saves'
           Category        = 'GameSave'
           StorageType     = 'Local'
           SourcePaths     = @('%USERPROFILE%\Saved Games\MyGame')
           ExcludePatterns = @('*.log')
           ProcessNames    = @('MyGame')
           CloudSaveNotice = ''
           RestoreHint     = ''
       }
   )
   ```

3. 保存したら、ルールが認識されているか確認します。

   ```powershell
   .\tools\migrator\WinEase-Migrator.ps1 -Mode ListRules
   ```

4. まず容量の見積もりと、書き込みなしの試し実行をします(`D:\backup` は例です)。

   ```powershell
   .\tools\migrator\WinEase-Migrator.ps1 -Mode Estimate -PackagePath D:\backup -RuleIds MyCustomGame
   .\tools\migrator\WinEase-Migrator.ps1 -Mode Backup -PackagePath D:\backup -RuleIds MyCustomGame -DryRun
   ```

   問題なければ `-DryRun` を外して実行します。GUI で行うときは、ビルド用 GUI の **8. Migration & Backup** タブか、引数なしで起動した WinEase-Migrator のウィンドウから選べます。

### 各項目の意味

| 項目 | 意味 |
| :--- | :--- |
| `Id` | ルールの名前(`-RuleIds` で指定する)。重複させない |
| `Name` | 画面とレポートに出る名前 |
| `SourcePaths` | バックアップするフォルダ/ファイル。`%USERPROFILE%` や `%APPDATA%` などの環境変数が使える |
| `ExcludePatterns` | 除外するファイル名のパターン |
| `ProcessNames` | そのゲームのプロセス名。起動中はバックアップをスキップして知らせる |
| `CloudSaveNotice` / `RestoreHint` | レポートに載せる注意書き(クラウドセーブの有無、復元先の補足など) |

ゲーム以外のアプリ設定は `AppConfigRules`、任意のフォルダは `CustomPathRules` に同じ形式で書きます(テンプレートに例があります)。
パスワードやトークンらしいファイルは、既定では自動的に除外されます。

---

# 第2部 リファレンス

## ① フォルダ構成と各ファイルの担当

```text
WinEase-main/
├── WinEasebuilder.ps1      メイン。引数の定義、設定の組み立て、フェーズの呼び出し
├── WinEasehelpers.ps1      共通の小さな関数(パス検証、設定ファイルの場所の解決など)
├── lib/                   ビルダーが読み込む関数群
├── phases/                ビルドの各工程(01〜18)
├── gui/WinEaseGui.ps1      WinForms の GUI
├── config/                設定ファイル
├── scripts/               イメージに埋め込むセットアップ用スクリプト
├── tools/                 補助ツールとカスタムスクリプト
├── profiles/              保存したプロファイル(JSON)
├── templates/report.html  レポートの雛形
└── tests/                 Pester テスト(領域別に分割。_TestCommon.ps1 が共通設定)
```

`WinEasebuilder.ps1` は `phases/*.ps1` と `lib/*.ps1` を**ドットソース**で読み込み、変数をスクリプトスコープで共有します。
ファイルを足すときも同じ方法で読み込んでください(モジュール化すると変数が見えなくなります)。

### lib/

| ファイル | 担当 |
| :--- | :--- |
| `WinEaseMount.ps1` | DISM のマウント確認とクリーンアップ、マウント用フォルダ、オフラインレジストリ |
| `WinEaseFileSystem.ps1` | フォルダの安全確認、所有権と ACL、強制削除、空き容量 |
| `WinEaseWim.ps1` | WIM の書き出し、フィンガープリント、修復 |
| `WinEaseReport.ps1` | HTML レポート(`WinEase_report.html`) |
| `WinEaseResume.ps1` | `-ResumeIsoOnly` と工程ごとのチェックポイント |
| `WinEaseSelfTest.ps1` | `-TestSelf` の自己診断(`-TestSelf` のときだけ読み込む) |
| `WinEaseExtensions.ps1` | 拡張エンジン(ユーザー設定の読み込みと実行、カスタムスクリプト、設定比較、復旧準備チェック) |

### phases/

| フェーズ | 内容 |
| :--- | :--- |
| `01-environment.ps1` | 実行環境の確認 |
| `02-source-media.ps1` | 元メディア(ISO / ドライブ)の準備 |
| `03-staging.ps1` | 作業フォルダの準備 |
| `04-mount-baseline.ps1` | イメージのマウントと削減前の記録 |
| `05-appx.ps1` | AppX の削除 |
| `06-fod.ps1` | 機能(FOD)の削除 |
| `07-nativeimages.ps1` | .NET ネイティブイメージの整理 |
| `08-filesystem.ps1` | ファイルとフォルダの削除 |
| `09-physical-debloat.ps1` | 高度な削減(物理削除)。同意ゲートとマウント先の検証があり、`-AllowPhysicalDebloat` が必要 |
| `09-winsxs.ps1` | WinSxS の整理 |
| `10-registry.ps1` | オフラインレジストリの読み込みと各種設定(ユーザー設定の `Registry` もここ) |
| `11-unattend.ps1` | 応答ファイルとセットアップ用スクリプトの埋め込み、カスタムスクリプトの配置、レジストリの書き戻し |
| `12-unmount-commit.ps1` | アンマウントと保存 |
| `13-export.ps1` | install.wim / .esd の書き出し |
| `14-bootwim.ps1` | boot.wim の調整 |
| `15-verify.ps1` | 検証 |
| `16-iso-cleanup.ps1` | ISO 側の整理 |
| `17-oscdimg.ps1` | `oscdimg.exe` の準備 |
| `18-iso.ps1` | ISO の作成 |

### config/

| ファイル | 担当 |
| :--- | :--- |
| `schema.psd1` | すべての設定スイッチとコンポーネントの**唯一の定義元**。GUI、プロファイル、CLI はここから作られる |
| `dependencies.psd1` | 設定の依存関係・影響のカタログ(競合、影響、不明の判定に使う) |
| `WinEase.config.schema.json` | プロファイルの JSON スキーマ |
| `user/user-tweaks.psd1` | ユーザー独自の設定、プリセット、カスタムスクリプト |
| `user/user-migration-rules.psd1` | ユーザー独自の移行ルール |

`config/` 直下にあった古い `user-*.psd1` も、新しい場所に無ければ警告つきで読み込まれます。`config/user/` へ移してください。

### gui/ と tools/

| ファイル | 担当 |
| :--- | :--- |
| `gui/WinEaseGui.ps1` | GUI 本体。タブごとの関数に分かれ、ボタンやテキストボックスなどの共通部品も持つ |
| `tools/migrator/WinEase-Migrator.ps1` | PC 移行・バックアップツール(CLI と GUI ウィザード) |
| `tools/migrator/WinEaseMigration.ps1` | 移行エンジン(バックアップ、復元、アプリ一覧、レポート) |
| `tools/migrator/migration-rules.psd1` | 標準の移行ルール |
| `tools/custom-scripts/<Stage>/` | カスタムスクリプトの置き場(次項) |
| `tools/winease-physical-debloat/` | 物理削除用の Rust ツール |
| `tools/Measure-WinEaseGuestBaseline.ps1` / `tools/Compare-WinEaseBenchmarks.ps1` | インストール後の計測と比較 |

GUI の **8. Migration & Backup** タブは、最初に開いたときに `tools/migrator/WinEaseMigration.ps1` を読み込みます(ビルダー本体は移行エンジンを読み込みません)。
`-IncludeMigrationAssistant` を付けると、移行ツールとルールが ISO の `Windows\Setup\Scripts\Migration` に同梱されます。`-IncludeMigrationBackup` (移行アシスタントと同時に既定でオン) を指定すると、`%USERPROFILE%\WinEase_migration_backup` の既定バックアップも `C:\WinEaseBackup` にコピーされます。このバックアップには**個人データが含まれ**、復元は明示的な操作でのみ実行されます。

## ② カスタムスクリプトの4ステージ

`tools/custom-scripts/<Stage>/` に `.ps1` を置くと、ステージごとに自動で見つかります。`config/user/user-tweaks.psd1` の `CustomScripts` に書いて登録することもできます。

| ステージ | いつ・どこで動くか | 権限 |
| :--- | :--- | :--- |
| `PreBuild` | ビルド開始直後(依存関係チェックの後、元メディアの確認の前)。ビルドするPC上 | ビルド実行ユーザー |
| `OfflineImage` | フェーズ11の終わり。ビルドするPC上で、マウント中のイメージに対して | ビルド実行ユーザー |
| `FirstLogon` | インストール後の初回ログオン時 | 管理者 |
| `UserOnce` | ユーザープロファイルが初期化された後 | 標準ユーザー |

`PreBuild` と `OfflineImage` は、ビルダーがスクリプトを `-WinEaseContext` 付きで直接呼び出します。
`FirstLogon` と `UserOnce` はビルド時には実行されず、イメージの `Windows\Setup\Scripts\Custom\...` にコピーされてインストール後に動きます(ログは `C:\ProgramData\WinEase\Logs\custom-scripts.log`、`UserOnce` は `%TEMP%\UserOnce-custom.log`)。
`FirstLogon` / `UserOnce` には `.bat` / `.cmd` / `.reg` も置けます(詳しくは `tools/custom-scripts/README.md`)。

### スクリプトのひな形

```powershell
# @WinEase-Id: MyScript
# @WinEase-Stage: PreBuild
# @WinEase-Order: 100
# @WinEase-OnError: Warn
# @WinEase-Description: 説明
param($WinEaseContext)
Write-Host "ScratchDir: $($WinEaseContext.ScratchDir)"
```

先頭30行のコメントに `# @WinEase-Id` / `Stage` / `Order` / `Condition` / `OnError` / `Description` を書けます。
`Order` の小さい順、同じ値ならファイル名順に実行します。`Condition` に設定キー名を書くと、その設定が有効なときだけ実行します。

### 渡される `$WinEaseContext`

`PreBuild` / `OfflineImage` のスクリプトに、ハッシュテーブルで渡されます。

| ステージ | 中身 |
| :--- | :--- |
| `PreBuild` | `Config`(現在の設定)、`ScriptRoot`(リポジトリのフォルダ) |
| `OfflineImage` | `ScratchDir`(マウントしたイメージのルート)、`WinEaseDir`、`Config` |

`FirstLogon` / `UserOnce` のスクリプトには渡されません(インストール後の PC 上で普通に実行されます)。

### オフラインのレジストリ(`HKLM:\zSOFTWARE` / `zNTUSER` / `zSYSTEM`)

ビルダーはフェーズ10でイメージのレジストリを `HKLM\zSYSTEM`、`HKLM\zSOFTWARE`、`HKLM\zDEFAULT`、`HKLM\zCOMPONENTS`、`HKLM\zNTUSER`(既定ユーザーの `ntuser.dat`)として読み込み、フェーズ11の途中で**すべてアンロード**します。
そのため:

- ユーザー設定の `Registry` アクション(第1部 ①)は、読み込み中に実行されるので `Hive = 'zNTUSER'` などをそのまま使えます。
- **`OfflineImage` ステージのスクリプトが動く時点では、これらはもう読み込まれていません。** レジストリを触りたいときは、スクリプト自身で読み込んで、終わったら必ず外してください。

  ```powershell
  param($WinEaseContext)
  $hive = Join-Path $WinEaseContext.ScratchDir 'Users\Default\ntuser.dat'
  & reg.exe load HKLM\zMyNtuser $hive
  try {
      & reg.exe add 'HKLM\zMyNtuser\Software\MyApp' /v Enabled /t REG_DWORD /d 1 /f
  } finally {
      [GC]::Collect()
      & reg.exe unload HKLM\zMyNtuser
  }
  ```

  ビルダーが使う `zSOFTWARE` などの名前とは別の名前(上の `zMyNtuser`)を使うと、衝突しません。

## ③ エラー時の扱いとセキュリティ上の注意

### `OnError`

`CustomScripts` の項目か `# @WinEase-OnError:` で指定します。省略時は `Warn` です。

| 値 | 動作 |
| :--- | :--- |
| `Stop` | そのスクリプトの例外を呼び出し元へ再スローし、以降のスクリプトを実行しない。ただし呼び出し元(`PreBuild` はビルダー本体、`OfflineImage` はフェーズ11)で捕捉されるため、**ビルド全体は止まらない**(`PreBuild` は警告を表示、`OfflineImage` は `-Verbose` にだけ記録) |
| `Warn` | 警告を出して次のスクリプトへ進む |
| `Ignore` | 何も言わずに次へ進む(`-Verbose` で理由を確認できる) |

`PreBuild` / `OfflineImage` のスクリプトで例外が出たときにだけ働きます。`FirstLogon` / `UserOnce` はインストール後に動くため、ビルドは止まりません。
`Warn` / `Ignore` では失敗しても残りのスクリプトを続けて実行します。`FirstLogon` では失敗した終了コードと理由がログに残ります。

### セキュリティ上の注意

- **カスタムスクリプトは、ビルド時はビルド実行ユーザー(管理者)の権限、`FirstLogon` では管理者権限で動きます。** 自分で中身を確認したものだけを置いてください。
- ビルド時に `custom-scripts-manifest.json` へ各スクリプトの SHA-256 を記録し、初回ログオン時に照合します。記録にないスクリプトや、書き換えられたスクリプトは `[SECURITY REFUSAL]` として実行されません。
- ログに出るパスワード、トークン、API キー、プロダクトキーは `[REDACTED]` に置き換えられます。ただし、スクリプトにそれらを直接書くのは避けてください。
- バックアップには個人データが含まれます。認証情報らしいファイルは既定で除外されます(`-IncludeSecrets` を付けたときだけ含める)。バックアップ先は安全な場所にしてください。
- `Impact` を省略したユーザー設定は「不明」として扱われ、`-StrictDependencyCheck` ではビルドが止まります。

### 現在できないこと

ユーザー設定の `AppxRemove` / `FeatureDisable` / `CapabilityRemove` は書式としては受け付けますが、現在のコードは実行内容を `-Verbose` のログに出すだけで、実際の削除は行いません。
実際に動くのは `Registry` と `Service` です。AppX や機能を削除したいときは、`OfflineImage` ステージのカスタムスクリプトで DISM を呼び出してください。

## ④ 安全な動作確認の手順

実際のビルド(数十分かかり、管理者権限とディスク容量が必要)の前に、次の順で確認します。

1. **構文と自己診断**: ディスクに何も書き込まず、ISO も不要です。

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WinEasebuilder.ps1 -TestSelf
   ```

2. **DryRun**: 設定、パス、カスタムスクリプトの検出を解決して表示だけします。ディスクやイメージには変更を加えません。`PreBuild` / `OfflineImage` のスクリプトは実行されません。

   ```powershell
   .\WinEasebuilder.ps1 -NonInteractive -Profile balanced -DryRun
   ```

3. **依存関係の厳格チェック**: 競合や不明があればビルドを止めます。

   ```powershell
   .\WinEasebuilder.ps1 -NonInteractive -Profile balanced -DryRun -StrictDependencyCheck
   ```

4. **プリセットとの差分確認**: 現在の設定が別のプリセット(名前か JSON のパス)とどう違うかを表示して、そのまま終了します。ビルドはしません。

   ```powershell
   .\WinEasebuilder.ps1 -Profile balanced -ComparePreset extreme
   ```

5. **Pester テスト**: リポジトリのルールを守っているか(構文、PSScriptAnalyzer の警告 0 件、GUI の配線など)を確認します。

   ```powershell
   Invoke-Pester -Path .\tests
   ```

6. **移行ツール**: `-Mode Estimate`(容量の見積もり)と `-DryRun`(書き込みなしの試し実行)を先に実行します。

スクリプトを自作したときは、`.ps1` / `.psd1` を BOM なしの UTF-8 で保存する場合は ASCII 文字だけにしてください(日本語を入れると Windows PowerShell 5.1 で文字化けします。テストでも検出されます)。
この `.md` のような文書は対象外です。

# nano11 修正・実装セッション指示書

`implementation_plan.md` との差分調査(2026-10-19)と GUI・構造レビューの結果を、**1セッション = 1テーマ** に分けた指示書です。
各セッションは Claude Sonnet 5.5 で実行する前提で書いています。

## 使い方

1. 新しいセッションには **「共通ルール」+「そのセッションの指示」** の2つをまとめて貼り付けてください。
2. 実行順は下の表に従ってください。同じファイルを触るセッションを並行させると、取り込み時に衝突します。
3. 各セッションは自分専用のブランチで作業し、`main` には取り込みません。差分の確認とテストをしてから、`main` へ fast-forward で取り込んでください。

## 実行順と並行可否

| 順 | セッション | 主に触るファイル | 前提 | 並行できる相手 |
|---|---|---|---|---|
| 1 | S1 ユーザー拡張が消えるバグ | `lib/Nano11Extensions.ps1`, `nano11builder.ps1` | なし | S2, S3 |
| 1 | S2 依存関係チェックの不足分 | `config/dependencies.psd1`, `nano11helpers.ps1` | なし | S1, S3 |
| 1 | S3 移行エンジンの不足分 | `lib/Nano11Migration.ps1` | なし | S1, S2 |
| 2 | S4 ビルド本体の未接続フック | `nano11builder.ps1`, `phases/05-appx.ps1`, `phases/11-unattend.ps1` | S1 | S6 |
| 3 | S5 移行ツールの ISO 同梱 | `phases/11-unattend.ps1`, `nano11builder.ps1` | S4 | S6, S7 |
| 2 | S6 移行ツール本体を仕様どおりに | `tools/Nano11-Migrator.ps1` | S3 | S4, S5, S7 |
| 2 | S7 GUI Tab 8 の修正 | `gui/Nano11Gui.ps1` | S3 | S4, S5, S6 |
| 4 | S8 GUI のユーザー拡張表示とプリセット差分 | `gui/Nano11Gui.ps1` | S1, S7 | S5, S6 |
| 5 | S9 フォルダ構造の整理 | 多数(移動) | S1〜S8 すべて | なし |
| 6 | S10 GUI・移行ツールのコード整理 | `gui/Nano11Gui.ps1`, `tools/Nano11-Migrator.ps1` | S9 | S11 |
| 6 | S11 ビルド本体・工程のコード整理 | `nano11builder.ps1`, `phases/*`, `lib/*` | S9 | S10 |
| 7 | S12 ドキュメント | `docs/`, `README.md`, `CHANGELOG.md` | すべて | なし |

テストファイル `tests/nano11.Tests.ps1` は全セッションが触ります。衝突を減らすため、新しいテストは **ファイル末尾に、セッションごとの新しい `Describe` ブロックとして追加** してください。

---

## 共通ルール(全セッションに貼る)

```text
# プロジェクト
nano11: Windows 11 のインストールメディアから軽量化した ISO を作る PowerShell ツール。
- nano11builder.ps1 … メインスクリプト。phases/*.ps1 と lib/*.ps1 を「ドットソース」で読み込み、
  スクリプトスコープの変数を共有している。新しいファイルも必ず同じスコープにドットソースすること
  (モジュール化してスコープを変えない)。
- config/tweaks.psd1 … すべてのスイッチ/コンポーネント設定の唯一の定義元。設定一覧を別の場所に手書きしない。
- gui/Nano11Gui.ps1 … WinForms の GUI。lib/ … 下処理・レポート・再開・拡張・移行。

# 守ること(テストで強制されている)
1. nano11builder.ps1 の AST 上で $script:AllTweakDefs / $script:TweakKeyAliases /
   $script:TweakVariableMap / $script:Nano11ProfileKeys への単純代入は各1回だけ。追加は要素代入で行う。
2. gui/Nano11Gui.ps1 の New-Nano11ToggleCheckBox -Key には、config/tweaks.psd1 にあるキーのリテラルか、
   変数 $tk / $sd.Key だけを渡す。
3. メインウィンドウ上の「Select All / Clear All / Deselect All」ボタンの総数は 14 個のまま。
4. PSScriptAnalyzer(PSScriptAnalyzerSettings.psd1)の Error/Warning は 0 件のまま:
   $null は比較の左側 / 空の catch {} 禁止(catch { Write-Verbose "Ignored: $($_.Exception.Message)" })/
   [ordered]@{} には .ContainsKey() ではなく .Contains() / 行末の空白禁止 / エイリアス(% ?)を使わない。
5. WinForms のイベント処理から、すでに終了したスコープの変数を参照しない。
   対象はコントロールの Tag に持たせて $this.Tag で読む($this.FindForm().Tag で $gui を取る既存パターンも可)。
6. 公開している引数名・別名・プロファイルのキー名を変えない(変える場合は別名を残す)。
7. phases/09-physical-debloat.ps1 の安全確認(同意ゲート・マウント先の検証)のロジックには触れない。
8. 動作を変えるのは、このセッションの指示に書かれた範囲だけ。ついでの書き換えをしない。

# 進め方
- 自分専用のブランチ(git worktree)で作業する。main には取り込まない。
- 1つの変更内容ごとに1コミット。コミットメッセージは英語で、何を・なぜ変えたかを書く。
- テストは tests/nano11.Tests.ps1 の末尾に、このセッション用の新しい Describe ブロックとして追加する。
  このマシンの Pester は 3.4 なので、`Should Be` 形式(ハイフンなし)で書く。

# 完了条件(すべて満たしてから終了報告)
1. Invoke-Pester -Script tests\nano11.Tests.ps1 -PassThru -Quiet がすべて成功(失敗 0)。
2. すべての .ps1 / .psd1 が構文エラーなしでパースできる。
3. Invoke-ScriptAnalyzer を PSScriptAnalyzerSettings.psd1 付きで全 .ps1 に実行し、Error/Warning が 0 件。
4. powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\nano11builder.ps1 -TestSelf が成功。
5. 終了報告に、変えたこと / テスト結果(件数) / 確認していないこと を書く。
```

---

## S1 ユーザー拡張が消えるバグ

```text
# 目的
config/user-tweaks.psd1 で定義したユーザー独自スイッチとカスタムスクリプトが、ビルド開始前に消えてしまうバグを直す。

# 原因
nano11builder.ps1 は Import-Nano11UserExtensions を2回呼ぶ。
- 1回目(505行目付近): 通常の読み込み。$script:UserTweakDefs と $script:UserCustomScripts が入る。
- 2回目(1003行目付近): -PresetsOnly 付き。$script:BuiltInPresets が定義された後にプリセットだけ読み直す目的。
ところが lib/Nano11Extensions.ps1 の Import-Nano11UserExtensions は、毎回最初に
$script:UserTweakDefs = [ordered]@{} と $script:UserCustomScripts = @() で空にしてから、
-PresetsOnly のときはスイッチとスクリプトを読み込まない。そのため2回目の呼び出し後、この2つが空になる。
結果: GUI にユーザー独自スイッチは表示される($script:AllTweakDefs には残る)が、
Invoke-Nano11UserExtensionActions は何も実行せず、psd1 に書いたカスタムスクリプトも実行されない。

# 作業
1. Import-Nano11UserExtensions を直す: -PresetsOnly のときは $script:UserTweakDefs / $script:UserCustomScripts を
   初期化しない。初期化はスイッチ・スクリプトを読み込むときだけ行う。$script:UserPresets も同様に、
   プリセットを読むときだけ初期化する。戻り値の件数は、その時点で保持している件数を正しく返す。
2. nano11builder.ps1 が lib/Nano11Extensions.ps1 と lib/Nano11Migration.ps1 を2回ドットソースしている
   (280〜288行目付近の $extModuleEarly / $migModuleEarly と、1208〜1220行目付近の $extModule / $migModule)。
   早い方の1回だけに統一する。他の lib/*.ps1 と同じように、存在しないときは throw する扱いに合わせるかどうかは、
   既存の 'Nano11Mount.ps1' などを読み込む配列(465行目付近)の扱いに揃える。
3. テストを追加する:
   - 一時フォルダに UserTweaks 1件・CustomScripts 1件・UserPresets 1件を持つ psd1 を作り、
     通常呼び出し → -PresetsOnly 呼び出しの順に実行しても、$script:UserTweakDefs と
     $script:UserCustomScripts の件数が減らないこと。
   - nano11builder.ps1 の AST で、Nano11Extensions.ps1 と Nano11Migration.ps1 のドットソースがそれぞれ1回だけであること。

# 触らないもの
GUI、phases、移行処理の中身。
```

---

## S2 依存関係チェックの不足分

```text
# 目的
implementation_plan.md §2(M1: 依存関係チェック)の未実装部分を入れる。

# 現状
- config/dependencies.psd1 は Components / Tweaks / AdvancedDebloat の3区分。
  Components の 'RemoveDrivers' は Status = 'Known' になっている。'AllowPhysicalDebloat' の項目はない。
- nano11helpers.ps1 の Test-Nano11Dependencies(1624行目付近)は、未登録の Advanced Debloat 項目は
  Unknown にするが、ユーザー独自スイッチ($script:UserTweakDefs)の扱いがない。

# 作業
1. config/dependencies.psd1:
   - 'RemoveDrivers' を Status = 'Unknown' にする。理由(Reason/Summary): 対象 PC のプリンター・スマートカード・
     シリアル/モデムなどの周辺機器構成に依存し、安全と言い切れない。
   - 'AllowPhysicalDebloat'(TriggerValue = $true)を Status = 'Unknown' で追加する。影響: 今後の累積更新(LCU)、
     SFC/DISM による修復。理由: WinSxS/System32 のファイルを物理削除するため、将来の更新への影響が不明。
   - 'DisableCPUMitigations' と 'NoHypervisor' がすでにあることを確認し、NoHypervisor の影響に
     WSL2 / Hyper-V / Windows Sandbox / Docker Desktop / VBS が含まれていなければ追加する。
   - 既存の区分構成(Components / Tweaks / AdvancedDebloat)は変えない。設計書の ComponentRules という
     新区分は作らず、既存の Components に寄せる(二重定義を避けるため)。ファイル冒頭のコメントにその方針を1行書く。
2. Test-Nano11Dependencies:
   - $Config で有効になっているユーザー独自スイッチ($script:UserTweakDefs にあるキーで値が $true)について、
     Impact が未定義または 'Unknown' なら Unknowns に追加する。
     Summary: 'User-defined custom tweak does not declare explicit dependency impact metadata (Dependency: Unknown).'
   - Impact が 'Safe' なら何も出さない。Impact がハッシュテーブル(AffectedFeatures / Severity / Reason)なら
     Impacts に追加する。
   - $script:UserTweakDefs が未定義でもエラーにならないこと。
3. テストを追加する:
   - RemoveDrivers = $true と AllowPhysicalDebloat = $true がそれぞれ Unknowns に出ること。
   - Impact なしのユーザー独自スイッチを有効にすると Unknowns に出ること。Impact = 'Safe' なら出ないこと。
   - 既存の競合検出(RemoveStore + KeepXboxServices、NoHypervisor + WSLSupport)が引き続き Conflicts に出ること。

# 触らないもの
GUI(結果の表示は既存の Format-Nano11DependencyReport をそのまま使う)。
```

---

## S3 移行エンジンの不足分

```text
# 目的
lib/Nano11Migration.ps1 を implementation_plan.md §4.2 の仕様まで仕上げる。

# 作業
1. Start-Nano11MigrationRestore を、タスク単位の復元にする:
   - タスク ID は App_<アプリ名>、UserData_<フォルダ名>、Rule_<ルールID>、Custom_<パス>(カスタムパスがある場合)。
   - migration-manifest.json から、バックアップされた個人データのフォルダ・ルール・アプリ一覧を読んでタスクを作る。
   - 各タスクの状態を Pending / Completed / Failed / Skipped で restore-state.json に保存する。
   - -RetryFailedOnly のときは Completed のタスクを飛ばし、Failed と Pending だけ実行する。
   - 1つのタスクが失敗しても次へ進む。
   - アプリは Restore-Nano11Apps、ルールは Invoke-Nano11MigrationRulesRestore、
     個人データは Restore-Nano11UserData を呼ぶ。
2. Start-Nano11MigrationBackup:
   - バックアップしたフォルダの一覧とルールの一覧を manifest に記録する(復元側が読めるように)。
   - 最後に Export-Nano11MigrationReport を呼び、migration-report.html と migration-report.json を出力する。
3. Export-Nano11MigrationReport を仕様どおりにする:
   - HTML(ダークテーマ。既存の lib/Nano11Report.ps1 の配色に合わせる)と JSON の両方を出力。
   - 成功(ファイル数・合計サイズ・SHA-256 検証結果)/ スキップ(秘密情報の除外・既存ファイルの保護など)/
     失敗(理由付き)/ 手動対応が必要な項目(自動で入れ直せないアプリ、クラウドセーブの注意、再ログインの案内)。
   - HTML に埋め込む文字列は必ず HTML エスケープする。
4. Invoke-Nano11MigrationRulesBackup: ルールに CloudSaveNotice があれば、結果オブジェクトに含める(レポートで使う)。
5. Backup-Nano11UserData と Backup-Nano11CustomPaths:
   バックアップ先がコピー元フォルダの中にある場合(コピーが無限に繰り返される)を、処理開始前に検出して拒否する。
   パスの比較は既存の Test-Nano11PathWithin(nano11helpers.ps1)を使う。
6. ファイル冒頭のコメントにある「Dot-sourced by nano11builder.ps1」の説明を実態に合わせる。

# テスト
すべて $TestDrive 上で行う(実際のユーザーフォルダに触れない)。
- -RetryFailedOnly で Completed のタスクが実行されず、Failed のタスクだけ再実行されること。
- バックアップ後に migration-report.html と migration-report.json ができること。HTML に <script> を含む名前を
  渡してもエスケープされること。
- バックアップ先をコピー元の中に指定すると拒否されること。
- コピー元のファイルが一切削除・変更されないこと(既存テストがあれば維持)。

# 触らないもの
GUI、tools/Nano11-Migrator.ps1(S6・S7 で対応)。関数名と既存の引数は変えない(引数の追加は可)。
```

---

## S4 ビルド本体の未接続フック

```text
# 目的
implementation_plan.md §6.2-1・6.2-4・6.2-5・6.3 のうち、関数はあるのに呼ばれていない部分をつなぐ。

# 作業
1. nano11builder.ps1 に引数 [string]$ComparePreset を追加する(既存の $IncludeMigrationAssistant の近く)。
   README のパラメータ表に載せるのは S12 で行うので、ここでは不要。
2. -ComparePreset の処理: -SaveProfile の処理の直後で、
   今の設定(Get-Nano11CurrentConfig)と指定プリセット(名前または JSON パス)を Compare-Nano11Config で比べ、
   Format-Nano11ConfigDiff の結果を表示して終了する。トランスクリプトを開始していれば止めてから exit 0。
   ビルドやディスク操作は一切行わない。
3. ビルド開始前(既存の依存関係チェック Test-Nano11Dependencies を呼んでいる箇所の直後):
   - Test-Nano11RecoveryReadiness -Config <解決済みの設定> を呼び、結果を表示する(警告だけで止めない)。
   - Invoke-Nano11CustomScriptsStage -Stage 'PreBuild' -Context @{ Config = <解決済みの設定>; ScriptRoot = $scriptDir }
     -DryRun:$isDryRunMode を呼ぶ。
4. OfflineImage ステージの位置を直す:
   今は phases/05-appx.ps1 の末尾で Invoke-Nano11CustomScriptsStage -Stage 'OfflineImage' を呼んでいる。
   設計書どおり phases/11-unattend.ps1 の末尾(FirstLogon / UserOnce の呼び出しの前)に移す。
   こうすると、カスタムスクリプトはレジストリ設定などの工程が終わったイメージに対して動く。
   Context には ScratchDir / Nano11Dir / Config を渡す。
5. テスト:
   - -ComparePreset が param ブロックにあること。
   - phases/05-appx.ps1 に OfflineImage の呼び出しがなく、phases/11-unattend.ps1 に1回だけあること。
   - nano11builder.ps1 に PreBuild ステージと Test-Nano11RecoveryReadiness の呼び出しがあること。
   - 可能なら -ComparePreset balanced -DryRun 相当で差分が表示されて正常終了すること。

# 触らないもの
IncludeMigrationAssistant の同梱処理(S5)、GUI。
```

---

## S5 移行ツールの ISO 同梱

```text
# 目的
GUI とコマンドラインの IncludeMigrationAssistant が、オンにしても何も起きない状態を直す。

# 現状
config/tweaks.psd1 に IncludeMigrationAssistant(Variable = 'includeMigrationAssistant')があり、
nano11builder.ps1 に引数もあるが、$includeMigrationAssistant を読むコードがどこにもない。

# 作業
1. phases/11-unattend.ps1 の末尾で、$includeMigrationAssistant が $true のとき:
   - tools/Nano11-Migrator.ps1、lib/Nano11Migration.ps1、config/migration-rules.psd1、
     config/user-migration-rules.psd1 を $scratchDir\Windows\Setup\Scripts\Migration\ にコピーする。
     Nano11-Migrator.ps1 がこの配置(すべて同じフォルダ)で lib と config を見つけられるようにする対応は
     S6 で行う。このセッションでは Nano11-Migrator.ps1 を編集しない(S6 と衝突するため)。
   - パブリックデスクトップ($scratchDir\Users\Public\Desktop)に Launch-MigrationAssistant.cmd を置く。
     中身は powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\Migration\Nano11-Migrator.ps1" -GUI。
   - 個人データは一切イメージに含めないこと。
   - DryRun のときはコピーせず、何をコピーするかだけ表示する。
2. 値が CLI・プロファイル・GUI のどれから来ても $includeMigrationAssistant に入ることを確認する
   (config/tweaks.psd1 の Components 定義から自動で作られる仕組みに乗っているはず。乗っていなければ直す)。
3. テスト:
   - $includeMigrationAssistant = $true のとき、11-unattend.ps1 の同梱処理が4ファイルと .cmd を対象にすること
     (一時フォルダを $scratchDir に見立てて実行できるなら実行、難しければ AST/文字列で確認)。
   - config/tweaks.psd1 のこのキーが、少なくとも1か所で読まれていること(既存の「すべての設定が使われている」テストが
     コンポーネントも対象にしているか確認し、していなければ対象に加える)。

# 触らないもの
移行処理の中身、tools/Nano11-Migrator.ps1(S6)、GUI の配置(Tab 8 への移動は S7)。
```

---

## S6 移行ツール本体を仕様どおりに

```text
# 目的
tools/Nano11-Migrator.ps1 を implementation_plan.md §5 の仕様にする。

# 作業
1. 引数を仕様どおりにする([CmdletBinding(DefaultParameterSetName = 'GUI')]、CLI と GUI でパラメータセットを分ける):
   - Mode: ExportApps / Backup / Restore / Verify / Estimate。
     既存の ListRules と RecoveryCheck は使っている人がいる可能性があるので残す。
   - PackagePath(バックアップの保存先・読み込み元)。既存の BackupRoot は PackagePath の別名として残す。
   - UserFolders(既定: Documents, Desktop, Pictures)、CustomPaths、RuleIds、ConflictPolicy、IncludeSecrets、
     RetryFailedOnly、DryRun。GUI 用の -GUI スイッチ。
   - Verify: migration-manifest.json の SHA-256 とバックアップ内のファイルを照合し、結果を表示する。
   - Estimate: Get-Nano11MigrationSizeEstimate の結果(件数・必要容量・空き容量・足りるか・起動中のプロセス)を表示する。
   - UserFolders は既知フォルダ名を実際のパスに変換してから Backup に渡す(Environment.GetFolderPath を使う)。
2. GUI(Show-Nano11MigratorDialog)を 900×680、サブタブ2つにする:
   - タブ1「Export / Backup」: 保存先フォルダ(参照ボタンと空き容量表示)、個人データフォルダのチェックリスト
     (Documents / Desktop / Pictures / Videos / Downloads と「Add Custom Folder...」)、ゲームのルール一覧
     (CloudSaveNotice があるものは名前の後ろに目印)、アプリ設定のルール一覧、
     「Exclude credentials/tokens (Recommended)」チェックボックス(既定オン)、
     「Estimate Size & Pre-flight Check」ボタン、「Start Backup & Verify (SHA-256)」ボタン(完了後に HTML レポートを開く)。
   - タブ2「Restore & Reinstall」: バックアップの選択(migration-manifest.json があるフォルダ)、上書き方法の選択
     (BackupExisting (.nano11.bak) / Skip / OverwriteIfNewer / Overwrite)、「Verify Backup Integrity」、
     「Restore Selected Items」、「Retry Failed Tasks Only」ボタン。
   - 配色は gui/Nano11Gui.ps1 と揃える。長い処理は Start-Job で裏に回し、画面を固めない
     (gui/Nano11Gui.ps1 の Run Backup と同じ方式)。
   - -GUI で起動したときに保存先が空文字にならないこと(既定値: Documents\nano11_migration_backup)。
3. lib/Nano11Migration.ps1 と config の場所は、リポジトリ配置($PSScriptRoot の親)と、
   S5 の ISO 同梱配置(同じフォルダ内)の両方で見つかるようにする。
4. テスト: 各 Mode が param の ValidateSet にあること、BackupRoot が PackagePath の別名であること、
   -DryRun 付きの Estimate / Verify が $TestDrive 上で例外なく終わること。

# 触らないもの
lib/Nano11Migration.ps1 の関数の中身(足りないものがあれば終了報告に書くだけにする)、gui/Nano11Gui.ps1。
```

---

## S7 GUI Tab 8 の修正

```text
# 目的
gui/Nano11Gui.ps1 の「8. Migration & Backup」タブ(1031行目付近〜)で、動くが結果が意図と違う部分と、足りない部分を直す。

# 作業
1. 「Run Backup」で個人データがバックアップされない問題:
   Start-Nano11MigrationBackup に -FolderMap を渡していない。Tab 8 に個人データフォルダのチェックリスト
   (Documents / Desktop / Pictures / Videos / Downloads)を追加し、チェックされたものを
   Environment.GetFolderPath で実際のパスにして -FolderMap に渡す。
   ※チェックリストに「Select All / Clear All / Deselect All」という文字のボタンを付けないこと(ボタン数 14 の制約)。
     付けるなら「Check All Items」「Uncheck All Items」などの表記にする。
2. 「Recovery Readiness Check」が起動時の設定($InitialSettings)を見ている:
   「Check Dependencies」ボタンと同じく Get-Nano11GuiDraftConfig -Gui $g で今の画面の設定を渡す。
3. ルールが無いとき「No migration rules found」の行にチェックを入れられ、その文字列がルール ID として渡る:
   ルールが無いときはリストを無効化し、表示用の行を選択できないようにする。ルール ID を取り出すときも
   実在するルールだけを使う(表示文字列を ' - ' で分割する今の方式をやめ、Id を Tag や別の配列で持つ)。
4. 足りない入力を追加する:
   - バックアップ先の「Browse...」ボタン(FolderBrowserDialog)。
   - 「Exclude credentials/tokens (Recommended)」チェックボックス(既定オン。オフなら -IncludeSecrets)。
   - 上書き方法の選択(BackupExisting / Skip / OverwriteIfNewer / Overwrite)。Restore 系に渡す。
   - 「Estimate Size」ボタン(Get-Nano11MigrationSizeEstimate)、「Verify Backup Integrity」ボタン、
     「Retry Failed Tasks Only」ボタン(Start-Nano11MigrationRestore -RetryFailedOnly)。
5. IncludeMigrationAssistant のチェックボックスを Tab 6 から Tab 8 の先頭カード
   「Post-Install Migration Assistant」に移す。config/tweaks.psd1 の Gui 定義で Tab 6 に出ている場合は、
   Tab 6 の自動生成から外す仕組み(例: Gui = @{ Tab = 'Migration' })を最小限で入れる。
   New-Nano11ToggleCheckBox -Key 'IncludeMigrationAssistant' はリテラルで呼んでよい(tweaks.psd1 にあるキーのため)。
   値が結果(Complete-Nano11GuiResult)に今まで通り入ることを確認する。
6. 「Export App Inventory」: SaveFileDialog で保存先を選べるようにし、Backup と同じく Start-Job で裏に回す。
7. 「Open Migration Wizard」: 起動時に -BackupRoot(または S6 後なら -PackagePath)へ今のバックアップ先を渡す。
   S6 が未取り込みでも動くよう、Nano11-Migrator.ps1 の param に存在する名前を使う。
8. Backup / Restore のジョブで、ジョブが Completed でもエラーストリームに出たエラーを拾って表示する。
9. 見出しコメント「Synchronization & Presets Handling」が2回続いている(1263行目と1266行目付近)ので1つにする。
10. テスト: 既存の GUI スモークテストの方式(フォームを ShowDialog せずに作る)で、
    - Tab 8 に個人データのチェックリストがあり、Run Backup の処理が -FolderMap を渡すこと(処理をモックして確認)。
    - メインウィンドウの Select All / Clear All / Deselect All ボタンが 14 個のままであること(既存テスト)。
    - Recovery Readiness Check が Get-Nano11GuiDraftConfig の結果を使うこと。

# 触らないもの
lib/Nano11Migration.ps1 の中身、Tab 1〜7 の他の部分。
```

---

## S8 GUI のユーザー拡張表示とプリセット差分

```text
# 目的
implementation_plan.md §6.4-1・6.4-2・6.4-3(カード3)のうち未実装の部分を入れる。

# 作業
1. ユーザー独自スイッチのカテゴリ:
   config/user-tweaks.psd1 では Category に System / Privacy / Gaming / UI / Security / UserCustom を使えるが、
   GUI のスイッチタブは Security / Privacy / Performance / UI しか作らないので、System / Gaming / UserCustom の
   スイッチがどこにも表示されない。
   既存の4タブに無いカテゴリのユーザー独自スイッチは、新しいタブ「User Tweaks」にまとめて表示する
   (既存タブにあるカテゴリはそのタブに表示されたままでよい)。チェックボックスは変数 $tk で
   New-Nano11ToggleCheckBox を呼ぶ既存のループ方式で作る。
   このタブに Select All / Clear All ボタンを付ける場合は、ボタン数 14 のテストの期待値も合わせて更新し、
   なぜ増えたかをテスト内にコメントで書く。
2. 「Preset Diff」:
   今は Tab 8 の「Compare Presets (balanced vs extreme)」が固定の組み合わせしか比べられない。
   画面下のボタン列(「Check Dependencies」の並び)に「Preset Diff」ボタンを追加し、小さなダイアログで
   比較元(プリセット一覧 + 「今の画面の設定」)と比較先を選べるようにする。今の画面の設定は Get-Nano11GuiDraftConfig で取る。
   結果は Format-Nano11ConfigDiff の文字列を、スクロールできるテキストボックスのダイアログで表示する
   (MessageBox だと長い結果が切れるため)。
   Tab 8 の固定比較ボタンは削除する。
   ボタンを追加したら「Start nano11 Build」「Cancel」と重ならないよう位置を調整する。
3. Tab 8 にカード「User Extensions & Custom Scripts」を追加する:
   読み込んだユーザー独自スイッチ・プリセット・カスタムスクリプトの件数($script:UserExtensionsResult)、
   読み込みエラーがあればその内容、「Open Extensibility Guide」ボタン(docs/EXTENSIBILITY_GUIDE.md を既定のアプリで開く)。
4. テスト: カテゴリが Gaming のユーザー独自スイッチを1つ読み込んだ状態でフォームを作ると、どこかのタブに
   そのキーのチェックボックスがあること。Preset Diff ボタンが存在すること。

# 前提
S1(ユーザー拡張が消えるバグの修正)と S7(Tab 8 の修正)が main に入っていること。
```

---

## S9 フォルダ構造の整理

```text
# 目的
機能追加で散らばった配置を整理する。動作は変えない(ファイルの移動・読み込みパスの修正・重複の統合だけ)。

# 作業
1. PC 移行ツールを ISO ビルドから切り離す:
   - lib/Nano11Migration.ps1 → tools/migrator/Nano11Migration.ps1
   - tools/Nano11-Migrator.ps1 → tools/migrator/Nano11-Migrator.ps1
   - config/migration-rules.psd1 → tools/migrator/migration-rules.psd1
   - nano11builder.ps1 は移行処理を使わないなら読み込みをやめる。GUI の Tab 8 は、
     必要なときだけ tools/migrator/Nano11Migration.ps1 を読み込む(GUI を開くたびに毎回ではなく、最初に使うとき1回)。
   - S5 の ISO 同梱処理のコピー元パスを新しい場所に直す。
2. ユーザーが編集するファイルを分ける:
   - config/user-tweaks.psd1 → config/user/user-tweaks.psd1
   - config/user-migration-rules.psd1 → config/user/user-migration-rules.psd1
   - 古い場所にファイルがある場合も読み込めるようにする(新しい場所を優先し、古い場所を見つけたら警告を1回出す)。
3. カスタムスクリプトの置き場所が2つある問題:
   既存の tools/custom-scripts/(初回ログオン時に実行、user/ はユーザー権限)と、
   新しい scripts/custom/<Stage>/(PreBuild / OfflineImage / FirstLogon / UserOnce)が並存している。
   scripts/custom/ はフォルダ自体が無い。どちらか1つに統一する。推奨: tools/custom-scripts/<Stage>/ に統一し、
   既存の tools/custom-scripts/ 直下は FirstLogon、user/ は UserOnce として扱い、
   読み込み側(lib/Nano11Extensions.ps1 と、既存の custom-scripts を埋め込む処理)を1か所の関数にまとめる。
   各ステージのフォルダに .gitkeep を置く。
4. nano11_report.html はビルドのたびに再生成されるが git の管理対象になっている。管理対象から外し
   (git rm --cached)、.gitignore に追加する。templates/report.html は残す。
5. 移動したファイルを参照しているテスト、自己診断(lib/Nano11SelfTest.ps1 のカタログ一覧など)、
   README の「Repository Structure」を直す。
6. git mv を使い、履歴をたどれるようにする。移動だけのコミットと、パス修正のコミットを分ける。

# 前提
S1〜S8 がすべて main に入っていること(移動すると他のセッションの差分が当たらなくなるため)。
```

---

## S10 GUI・移行ツールのコード整理

```text
# 目的
gui/Nano11Gui.ps1 と tools/migrator/Nano11-Migrator.ps1(S9 後の場所)の重複と書き方の揺れを整える。動作は変えない。

# 作業
1. 既存の部品(New-Nano11Button / New-Nano11Label / New-Nano11TextBox / New-Nano11CheckedList /
   New-Nano11GroupBox など)を使わず、New-Object で直接作っているコントロールを部品に置き換える
   (Tab 8 の CheckedListBox や複数行 TextBox、移行ツールの全コントロール)。足りない部品があれば
   gui/Nano11Gui.ps1 の部品群に追加し、移行ツールからも読み込んで使う。
2. 「ボタンを無効化 → 待機カーソル → Start-Job → DoEvents で待つ → 結果かエラーを表示 → 元に戻す」が
   何度も繰り返されているので、1つの関数(例: Invoke-Nano11GuiBackgroundJob)にまとめる。
3. 成功・エラーの MessageBox 表示を1つの関数(例: Show-Nano11GuiMessage -Kind Info|Warning|Error)にまとめる。
4. 既定のバックアップ先 "Documents\nano11_migration_backup" などの重複した文字列を1か所の定数にする。
5. 色の指定(FromArgb の同じ値の繰り返し)を、すでにある配色の定義があればそれに、無ければ1か所の配色表にまとめる。
6. Show-Nano11GUI が長すぎる場合は、タブごとの作成処理を関数に分ける(New-Nano11MigrationTab など)。

# 完了条件(共通ルールに加えて)
GUI スモークテストがすべて通ること。見た目(位置・大きさ・文字)が変わらないこと。
変わってしまう場合は終了報告に箇条書きで書く。
```

---

## S11 ビルド本体・工程のコード整理

```text
# 目的
nano11builder.ps1、phases/*、lib/* の気になる点を直す。動作を変える変更は、下に書いた範囲だけにする。

# 作業
1. phases/05-appx.ps1 の並列フォルダ削除($folderCleanupScript、119行目付近):
   順番に削除するときの Remove-Nano11TreeRobust と違い、「作業フォルダの外を消そうとしていないか」の確認がない。
   ワーカーに渡す前に、各パスが $scratchDir の中にあることを Test-Nano11PathWithin で確認し、外なら並列削除の対象から外して警告する。
   ワーカーの戻り値(成功/失敗)を集め、失敗したフォルダ名をログに出す。
2. nano11builder.ps1 の起動時メニュー(4403行目付近だったが、分割後の位置を探すこと)の絵文字:
   ファイルが BOM なし UTF-8 のため、Windows PowerShell 5.1 で文字化けする。
   絵文字を外して ASCII の記号に置き換える(BOM 付きにする方法は、他のツールとの相性があるため採らない)。
   他の .ps1 にも BOM なしで ASCII 以外の文字があれば同様に対処し、テストで「BOM なしの .ps1 は ASCII のみ」を確認する。
3. lib/Nano11SelfTest.ps1 の Invoke-Nano11SelfTest(約750行の1関数)を、確認内容ごとの小さな関数に分ける。
   出力内容と終了コードは変えない。
4. コマンドライン引数の処理で、まだ `if (& $isAnyBound @(...))` が繰り返されている箇所のうち、
   config/tweaks.psd1 の CliBindings に載せられるものを載せる。載せられないもの(数値・文字列引数など)は無理に変えない。
5. PSScriptAnalyzer の Information レベルの指摘(現在13件程度)を確認し、直せるものは直す。

# 完了条件(共通ルールに加えて)
-TestSelf と -DryRun の出力が、作業前と比べて(並び順を除き)変わらないこと。作業前に両方の出力を保存して比較する。
```

---

## S12 ドキュメント

```text
# 目的
implementation_plan.md §7 のガイドを仕上げ、README と CHANGELOG を今の実装に合わせる。

# 作業
1. docs/EXTENSIBILITY_GUIDE.md を日本語で書き直す(今は英語)。構成:
   - 第1部 初心者向けクイックスタート:
     ① config/user/user-tweaks.psd1 に数行足して、自分用のレジストリ設定とチェックボックスを GUI に増やす手順
     ② config/user/user-migration-rules.psd1 に、標準で対応していないゲームのセーブフォルダを足す手順
   - 第2部 リファレンス:
     ① フォルダ構成と各ファイル(nano11builder.ps1 / nano11helpers.ps1 / lib/*.ps1 / phases/01〜18 / gui / tools)の担当
     ② カスタムスクリプトの4ステージ(PreBuild / OfflineImage / FirstLogon / UserOnce)がいつ動くか、
        渡される $Nano11Context の中身、オフラインのレジストリハイブ(HKLM:\zSOFTWARE / zNTUSER / zSYSTEM)の扱い方
     ③ エラー時の扱い(OnError: Stop / Warn / Ignore)とセキュリティ上の注意
     ④ -DryRun / -TestSelf / Pester を使った安全な動作確認の手順
   - パスや関数名は、実際のコードを読んで確認したものだけを書く(S9 で移動した後の場所)。
2. README.md: 新しい引数(-ComparePreset / -IncludeMigrationAssistant / -StrictDependencyCheck など)をパラメータ表に追加。
   GUI の Tab 8 と移行ツールの説明、Repository Structure を今の配置に合わせる。
3. CHANGELOG.md: S1〜S11 の変更を Added / Changed / Fixed に分けて追記する。
   各セッションのコミットメッセージ(git log)を元にし、推測で書かない。

# 完了条件
共通ルールのテストに加え、ドキュメントに出てくるファイルパスがすべて実在することを確認する
(簡単なスクリプトで、バッククォートで囲まれたパスを抜き出して Test-Path する)。
```

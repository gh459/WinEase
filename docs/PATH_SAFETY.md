# Path safety

The destructive entry points of the builder (directory reset, protected-directory removal,
robust tree removal, mount-directory cleanup) share the safety checks in
`lib\WinEasePathSafety.ps1` and `lib\WinEaseFileSystem.ps1`. This document states what those
checks guarantee and what they do not. The rules were tightened in the G1 fixes; the earlier
behaviour is recorded in `tests\FileSystemSafety.Tests.ps1` (the former `-Pending` findings
F1-1, F1-2, F1-4 and F1-5).

## The entry points and their guards

| Entry point | Guards |
| --- | --- |
| `Assert-WinEaseDirectorySafety` (called by `Reset-DirectoryWithRobocopy` and `Remove-ProtectedDirectory`) | absolute local path only (drive-relative `C:` / `C:foo` and root-relative `\x` refused, F1-5); drive roots, UNC share roots and host system directories refused; workspace containment (lexical); **no reparse point on any existing element between the containing workspace root and the target, target included** (F1-4); active-DISM-mount overlap with **real long paths** on both sides (F1-2) |
| `Reset-DirectoryWithRobocopy` | everything above plus its own check that the reset root is not a reparse point, plus a queue walk that prunes reparse points inside the tree without following them |
| `Remove-ProtectedDirectory` | `Assert-WinEaseDirectorySafety` (`RemoveOfflineContent`), so the full guard list above |
| `Remove-WinEaseTreeRobust` | drive root refused; strict lexical child of `-SafetyRoot` only; **no reparse point on any existing ancestor between the safety root and the target's parent** (F1-4; the target itself may be a link and is removed as a link only); inside the tree, reparse points are pruned without being followed and `robocopy /MIR` runs only after the walk proved the tree link-free |
| `Test-CanSafelyDeleteDirectory` / `Test-CanSafelyDeleteVhdx` | `Test-IsSafePathToDelete` (real-path judgement, below), lexical workspace containment, preserved-directory list, DISM mount and offline-hive checks; the deletion itself still goes through `Remove-WinEaseTreeRobust` and its guards |
| `Test-IsSafePathToDelete` (predicate) | lexical judgement (drive roots, UNC roots, user profile, OS directories, repository directory) **plus the same judgement on the real path with reparse targets resolved** (F1-1); a real path that cannot be determined refuses |

## What is guaranteed

* A path is refused when **either** its lexical form **or** its real file-system form names a
  protected location (drive root, UNC root, user profile, Windows / Program Files /
  ProgramData, the repository directory) or is a drive root in any spelling.
* A junction or symlink anywhere between the workspace (or safety) root and the target makes
  reset / removal refuse before anything is destroyed. A link directly above the workspace
  root is out of scope by design: the workspace root is chosen by the operator.
* Mount overlap and workspace membership compare **real long paths**: 8.3 short names of
  existing elements are expanded and reparse targets substituted while walking down
  (`ConvertTo-WinEaseRealPath`). A mount record written in a different spelling of the same
  directory still matches.
* Robocopy exit code 8 or higher alone does not fail a reset; the verdict is the strict
  emptiness check afterwards. This is deliberate and recorded (former finding F1-3).
* When a safety decision cannot be made (a reparse target that cannot be read, a mount record
  that cannot be resolved), the operation refuses: fail closed.

## What is not guaranteed

* The real-path resolution is a best-effort walk over `Get-Item` results, not a
  `GetFinalPathNameByHandle` system call. A path whose existing ancestor is a reparse point is
  refused rather than resolved further, so the guarantee above is implemented as "refuse on
  any link between root and target", not as "operate on the resolved path".
* 8.3 short-name matching is verified by mocking `ConvertTo-WinEaseRealPath`
  (`tests\FileSystemSafety.Tests.ps1`, the F1-2 tests). Behaviour with **real** 8.3 names was
  not verified because 8.3 name creation is disabled on the development machine and on the CI
  runner.
* `Remove-WinEaseTreeRobust` without a `-SafetyRoot` cannot run the ancestry walk (there is no
  root to walk to). Every caller in this repository passes one.
* Elements **above** the workspace root are never inspected. If the operator points the
  workspace at a directory below a junction, the junction is the operator's choice.
* Symbolic links and junctions created between a guard and the destructive step (a
  time-of-check / time-of-use race) are out of scope; the steps re-run
  `Assert-WinEaseDirectorySafety` at every retry boundary but nothing holds the tree locked.

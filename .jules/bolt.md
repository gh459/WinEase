# Bolt's Journal

## 2025-05-20 - Pre-allocating trailing slashes in path loop boundary checks
**Learning:** `Test-IsPathPreserved` iterates over `HashSet[string]` preserved directories to perform boundary prefix matching (`StartsWith`). Doing string concatenation inside the loop (`$normPath + '\'`) allocates temporary string objects on every iteration. Pre-allocating `$normPathWithSlash` before the loop avoids redundant allocations.
**Action:** Always pre-compute loop-invariant string concatenations (like trailing path separators) before `foreach` loops in path validation utilities.

## 2025-05-21 - Using HashSet[string] instead of List[object] | Select-Object -Unique for key deduplication
**Learning:** Collecting key strings into a `List[object]` and piping to `Select-Object -Unique` creates substantial pipeline overhead in PowerShell. Instantiating a `HashSet[string]` with `[System.StringComparer]::OrdinalIgnoreCase` directly avoids pipeline object creation and yields ~30% faster execution time for configuration comparison.
**Action:** Prefer `HashSet[string]` with case-insensitive comparer over piping through `Select-Object -Unique` when collecting unique string keys across dictionaries or objects in PowerShell helpers.

## 2025-05-22 - Using intrinsic .Where() instead of piping arrays to Where-Object in configuration matrix checks
**Learning:** Piping collection items to `Where-Object` creates pipeline enumerator objects and pipeline context switching for each item. Replacing `$items | Where-Object { $_ -match ... }` with PowerShell's intrinsic `@($items.Where({ $_ -match ... }))` method reduces evaluation time in `Test-WinEaseConfigConflicts` by ~61% (9.5s -> 3.7s for 1000 runs).
**Action:** Use intrinsic `.Where(...)` method on PowerShell arrays and generic lists (`List[T]`) for filter conditions in frequently evaluated validation routines instead of piping to `Where-Object`.

## 2025-05-23 - Streaming File.ReadLines with early exit instead of File.ReadAllLines | Select-Object -First
**Learning:** Calling `[System.IO.File]::ReadAllLines($path) | Select-Object -First N` reads the entire file into an array in memory before pipeline enumeration. Replacing this with `[System.IO.File]::ReadLines($path)` streaming and exiting the `foreach` loop once N lines are processed reduces header parsing duration by ~86% (1070ms -> 148ms for 500 executions on 10k-line files).
**Action:** Use `[System.IO.File]::ReadLines($path)` with a manual line counter and early `break` for header parsing or top-N line inspection in PowerShell instead of `ReadAllLines` piped to `Select-Object -First`.

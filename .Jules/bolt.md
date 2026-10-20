# Bolt's Journal

## 2025-05-20 - Pre-allocating trailing slashes in path loop boundary checks
**Learning:** `Test-IsPathPreserved` iterates over `HashSet[string]` preserved directories to perform boundary prefix matching (`StartsWith`). Doing string concatenation inside the loop (`$normPath + '\'`) allocates temporary string objects on every iteration. Pre-allocating `$normPathWithSlash` before the loop avoids redundant allocations.
**Action:** Always pre-compute loop-invariant string concatenations (like trailing path separators) before `foreach` loops in path validation utilities.

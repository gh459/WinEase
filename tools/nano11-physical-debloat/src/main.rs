use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{
    BOOL, CloseHandle, ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, GetLastError, HANDLE, LUID,
};
use windows::Win32::Security::{
    AddAccessAllowedAce, AdjustTokenPrivileges, CreateWellKnownSid, InitializeAcl,
    InitializeSecurityDescriptor, LookupPrivilegeValueW, SetSecurityDescriptorDacl,
    SetSecurityDescriptorOwner, WinBuiltinAdministratorsSid, ACL, ACL_REVISION,
    DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
    SECURITY_DESCRIPTOR, SECURITY_MAX_SID_SIZE, SE_PRIVILEGE_ENABLED, TOKEN_ADJUST_PRIVILEGES,
    TOKEN_PRIVILEGES, TOKEN_QUERY,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, DeleteFileW, RemoveDirectoryW, SetFileAttributesW,
    FILE_ATTRIBUTE_NORMAL, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    OPEN_EXISTING,
};
use windows::Win32::System::Registry::{
    RegCloseKey, RegDeleteTreeW, RegEnumKeyExW, RegLoadKeyW, RegOpenKeyExW, RegQueryValueExW,
    RegSetKeySecurity, RegUnLoadKeyW, KEY_ALL_ACCESS, KEY_READ, REG_DWORD, REG_SAM_FLAGS,
    REG_VALUE_TYPE, HKEY, HKEY_LOCAL_MACHINE,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

#[derive(Debug, Deserialize, Default, Clone)]
struct DebloatConfig {
    #[serde(default)]
    dry_run: bool,
    #[serde(default)]
    mount_path: String,
    #[serde(default)]
    log_path: String,
    #[serde(default)]
    experimental: HashMap<String, bool>,
}

#[derive(Debug, Serialize, Default)]
struct DebloatResult {
    success: bool,
    deleted_files: u64,
    deleted_dirs: u64,
    deleted_registry_keys: u64,
    errors: Vec<String>,
    dry_run: bool,
    timestamp: String,
    targets_processed: Vec<String>,
}

// --- Privilege escalation ---

fn enable_privilege(priv_name: &str) -> bool {
    unsafe {
        let mut token: HANDLE = HANDLE::default();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &mut token).is_err() {
            return false;
        }
        let mut luid = LUID::default();
        let wide: Vec<u16> = priv_name.encode_utf16().chain(std::iter::once(0)).collect();
        if LookupPrivilegeValueW(None, PCWSTR(wide.as_ptr()), &mut luid).is_err() {
            let _ = CloseHandle(token);
            return false;
        }
        let mut tp = TOKEN_PRIVILEGES {
            PrivilegeCount: 1,
            Privileges: [windows::Win32::Security::LUID_AND_ATTRIBUTES {
                Luid: luid,
                Attributes: SE_PRIVILEGE_ENABLED,
            }],
        };
        let result = AdjustTokenPrivileges(token, false, Some(&mut tp), 0, None, None);
        let _ = CloseHandle(token);
        result.is_ok()
    }
}

fn escalate_privileges() {
    let privs = [
        "SeRestorePrivilege",
        "SeBackupPrivilege",
        "SeTakeOwnershipPrivilege",
    ];
    for p in &privs {
        if enable_privilege(p) {
            println!("[PRIV] Enabled: {}", p);
        } else {
            println!("[PRIV] Failed to enable: {}", p);
        }
    }
}

// --- String helpers ---

fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// True when `p` itself (not its target) is a reparse point: junction, mount point or
/// symlink. Traversal must never descend into these, and they are never deleted through.
fn is_reparse_point(p: &Path) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    match fs::symlink_metadata(p) {
        Ok(md) => (md.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT) != 0,
        Err(_) => false,
    }
}

/// Strip the `\\?\` verbatim prefix on local drive paths (registry APIs prefer the plain
/// `C:\...` form). UNC verbatim paths are left untouched.
fn strip_verbatim_prefix(p: PathBuf) -> PathBuf {
    let s = p.to_string_lossy();
    if let Some(rest) = s.strip_prefix("\\\\?\\") {
        if rest.as_bytes().get(1) == Some(&b':') {
            return PathBuf::from(rest);
        }
    }
    p
}

/// Validate the configured mount directory before any destructive operation.
/// Rejects empty paths, reparse-point roots, non-directories, drive/volume roots, and
/// trees without the `Windows\System32\config\SYSTEM` marker (offline-image proof).
fn validate_mount_path(mount: &str) -> Result<PathBuf, String> {
    if mount.trim().is_empty() {
        return Err("mount_path is empty".to_string());
    }
    let p = Path::new(mount);
    if is_reparse_point(p) {
        return Err(format!("mount_path is a reparse point (junction/symlink): {}", mount));
    }
    let md = fs::symlink_metadata(p)
        .map_err(|e| format!("mount_path is not accessible ({}): {}", mount, e))?;
    if !md.is_dir() {
        return Err(format!("mount_path is not a directory: {}", mount));
    }
    let canon = fs::canonicalize(p)
        .map_err(|e| format!("mount_path canonicalization failed ({}): {}", mount, e))?;
    if canon.parent().is_none() {
        return Err(format!("mount_path resolves to a drive/volume root: {}", canon.display()));
    }
    let canon = strip_verbatim_prefix(canon);
    let marker = canon.join("Windows").join("System32").join("config").join("SYSTEM");
    if !marker.is_file() {
        return Err(format!(
            "Windows\\System32\\config\\SYSTEM marker not found (not a mounted Windows image): {}",
            canon.display()
        ));
    }
    println!("[GUARD] Mount validated: {}", canon.display());
    Ok(canon)
}

// --- File/directory deletion ---

/// Delete a file. Returns `Ok(true)` when the file was deleted, `Ok(false)`
/// when it did not exist (reported as `[SKIP]`, not an error), and `Err` only
/// for genuine failures (locked, access denied, ...).
fn delete_file(path: &str, dry_run: bool) -> Result<bool, String> {
    if dry_run {
        // Report only targets that actually exist: counters must not overstate the run.
        if fs::symlink_metadata(path).is_ok() {
            println!("[DRY] Would delete file: {}", path);
            return Ok(true);
        }
        println!("  [SKIP] File not found: {}", path);
        return Ok(false);
    }
    let wide = to_wide(path);
    unsafe {
        // Remove read-only attribute first
        let attrs = windows::Win32::Storage::FileSystem::GetFileAttributesW(PCWSTR(wide.as_ptr()));
        if attrs == u32::MAX {
            let err = GetLastError();
            if err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND {
                println!("  [SKIP] File not found: {}", path);
                return Ok(false);
            }
        } else {
            let _ = SetFileAttributesW(PCWSTR(wide.as_ptr()), FILE_ATTRIBUTE_NORMAL);
        }
        // Try direct delete first
        match DeleteFileW(PCWSTR(wide.as_ptr())) {
            Ok(()) => return Ok(true),
            Err(e) => {
                let code = e.code();
                if code == windows::core::HRESULT::from_win32(ERROR_FILE_NOT_FOUND.0)
                    || code == windows::core::HRESULT::from_win32(ERROR_PATH_NOT_FOUND.0)
                {
                    println!("  [SKIP] File not found: {}", path);
                    return Ok(false);
                }
            }
        }
        // Fallback: open with backup semantics and set disposition
        let handle = CreateFileW(
            PCWSTR(wide.as_ptr()),
            0x00010000, // DELETE
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            None,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            None,
        );
        match handle {
            Ok(h) => {
                use windows::Win32::Storage::FileSystem::{FILE_DISPOSITION_INFO, SetFileInformationByHandle, FileDispositionInfo};
                let info = FILE_DISPOSITION_INFO { DeleteFile: true.into() };
                let result = SetFileInformationByHandle(h, FileDispositionInfo, &info as *const _ as *const _, std::mem::size_of::<FILE_DISPOSITION_INFO>() as u32);
                let _ = CloseHandle(h);
                if result.is_ok() { Ok(true) } else { Err(format!("SetFileInformationByHandle failed")) }
            }
            Err(e) => {
                // The file may have vanished between the checks: treat as skip
                let code = e.code();
                if code == windows::core::HRESULT::from_win32(ERROR_FILE_NOT_FOUND.0)
                    || code == windows::core::HRESULT::from_win32(ERROR_PATH_NOT_FOUND.0)
                {
                    println!("  [SKIP] File not found: {}", path);
                    Ok(false)
                } else {
                    Err(format!("CreateFileW failed: {}", e))
                }
            }
        }
    }
}

/// Delete a directory tree. Returns `Ok(true)` only when the tree is gone,
/// `Ok(false)` when the directory did not exist (reported as `[SKIP]`), and `Err`
/// when the directory (or parts of it) could not be removed.
/// Reparse points (junctions/symlinks) are never traversed and never deleted through.
fn delete_directory(path: &str, dry_run: bool) -> Result<bool, String> {
    let p = Path::new(path);
    // B5: a reparse-point root would make `read_dir` enumerate the *target* tree.
    if is_reparse_point(p) {
        println!("  [SKIP] Reparse point (junction/symlink) is never deleted: {}", path);
        return Ok(false);
    }
    if !p.exists() {
        println!("  [SKIP] Directory not found: {}", path);
        return Ok(false);
    }
    // Target registered as a directory but is actually a file (config drift):
    // delete it as a file so success/failure reporting stays accurate.
    if p.is_file() {
        println!("  [INFO] Target is a file, not a directory; deleting as file: {}", path);
        return delete_file(path, dry_run);
    }
    if dry_run {
        println!("[DRY] Would delete directory: {}", path);
        return Ok(true);
    }
    // Collect all entries bottom-up (reparse points are skipped, not followed)
    let mut entries: Vec<PathBuf> = Vec::new();
    fn collect(path: &Path, entries: &mut Vec<PathBuf>) {
        if let Ok(rd) = fs::read_dir(path) {
            for entry in rd.flatten() {
                let ep = entry.path();
                // B5: never descend into junctions/symlinks; deleting through them would
                // destroy data outside the intended tree.
                if is_reparse_point(&ep) {
                    println!("  [SKIP] Reparse point (junction/symlink) not traversed: {}", ep.to_string_lossy());
                    continue;
                }
                if ep.is_dir() {
                    collect(&ep, entries);
                }
                entries.push(ep);
            }
        }
    }
    collect(p, &mut entries);
    // Delete in order (children first)
    for entry in &entries {
        if entry.is_dir() {
            let s = entry.to_string_lossy();
            let wide = to_wide(&s);
            unsafe { let _ = RemoveDirectoryW(PCWSTR(wide.as_ptr())); }
        } else {
            let _ = delete_file(&entry.to_string_lossy(), false);
        }
    }
    // Delete root and verify the outcome so success is not reported for failed removals
    let s = p.to_string_lossy();
    let wide = to_wide(&s);
    unsafe { let _ = RemoveDirectoryW(PCWSTR(wide.as_ptr())); }
    if p.exists() {
        Err(format!(
            "not fully removed (locked, access denied, or contains preserved reparse points): {}",
            path
        ))
    } else {
        Ok(true)
    }
}

// --- Wildcard expansion for directory patterns ---

fn has_wildcard(s: &str) -> bool {
    s.contains('*') || s.contains('?')
}

/// Case-insensitive wildcard matcher supporting `*` and `?`.
fn wildcard_match(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let n: Vec<char> = name.to_lowercase().chars().collect();
    let (mut pi, mut ni) = (0usize, 0usize);
    let mut star_pi: Option<usize> = None;
    let mut star_ni = 0usize;
    while ni < n.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == n[ni]) {
            pi += 1;
            ni += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star_pi = Some(pi);
            star_ni = ni;
            pi += 1;
        } else if let Some(sp) = star_pi {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

/// Expand a relative pattern such as `Windows\SystemApps\Microsoft.Cortana*`
/// against the mount root into concrete existing paths. Expansion is
/// component-wise and case-insensitive. Returns matched paths (sorted),
/// or an empty list when nothing matches.
fn expand_dir_pattern(mount: &str, rel_pattern: &str) -> Vec<PathBuf> {
    let mut bases: Vec<PathBuf> = vec![PathBuf::from(mount)];
    for comp in rel_pattern.split('\\') {
        if comp.is_empty() {
            continue;
        }
        let mut next: Vec<PathBuf> = Vec::new();
        if has_wildcard(comp) {
            for base in &bases {
                if let Ok(rd) = fs::read_dir(base) {
                    for entry in rd.flatten() {
                        let name = entry.file_name().to_string_lossy().into_owned();
                        if wildcard_match(comp, &name) {
                            next.push(entry.path());
                        }
                    }
                }
            }
        } else {
            for base in &bases {
                next.push(base.join(comp));
            }
        }
        bases = next;
        if bases.is_empty() {
            break;
        }
    }
    bases.sort();
    bases
}

// --- Registry deletion ---

/// Resolve the offline hive's active control set (`Select\Current`) into a
/// concrete name such as `ControlSet001`. Falls back to `ControlSet001` when
/// the value cannot be read. The mounted hive root equals the SYSTEM hive
/// itself, so keys must never carry a `SYSTEM\` prefix, and `CurrentControlSet`
/// is resolved explicitly instead of relying on the hive link.
fn resolve_current_control_set(mount_name: &str) -> String {
    let select_path = format!("{}\\Select", mount_name);
    let select_wide = to_wide(&select_path);
    let value_wide = to_wide("Current");
    unsafe {
        let mut hkey = HKEY::default();
        let open = RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(select_wide.as_ptr()),
            0,
            KEY_READ,
            &mut hkey,
        );
        if open.is_ok() {
            let mut ty = REG_VALUE_TYPE(0);
            let mut data: u32 = 0;
            let mut size: u32 = std::mem::size_of::<u32>() as u32;
            let query = RegQueryValueExW(
                hkey,
                PCWSTR(value_wide.as_ptr()),
                None,
                Some(&mut ty),
                Some(&mut data as *mut u32 as *mut u8),
                Some(&mut size),
            );
            let _ = RegCloseKey(hkey);
            if query.is_ok() && ty.0 == REG_DWORD.0 && data >= 1 {
                return format!("ControlSet{:03}", data);
            }
        }
    }
    println!("[WARN] Could not read Select\\Current; falling back to ControlSet001");
    "ControlSet001".to_string()
}

/// Normalize a target key path so it is valid under the mounted hive root:
/// strips any legacy `SYSTEM\` prefix and resolves `CurrentControlSet`.
fn normalize_registry_key(key_path: &str, mount_name: &str) -> String {
    let key = key_path.strip_prefix("SYSTEM\\").unwrap_or(key_path);
    if key == "CurrentControlSet" {
        return resolve_current_control_set(mount_name);
    }
    if let Some(rest) = key.strip_prefix("CurrentControlSet\\") {
        return format!("{}\\{}", resolve_current_control_set(mount_name), rest);
    }
    key.to_string()
}

// Generic access rights that the windows crate does not expose as constants
const WRITE_DAC_ACCESS: REG_SAM_FLAGS = REG_SAM_FLAGS(0x0004_0000);
const WRITE_OWNER_ACCESS: REG_SAM_FLAGS = REG_SAM_FLAGS(0x0008_0000);

/// Create the BUILTIN\Administrators SID inside `buf` (>= SECURITY_MAX_SID_SIZE
/// bytes) and return a pointer to it.
fn administrators_sid(buf: &mut [u8]) -> PSID {
    let mut size = buf.len() as u32;
    unsafe {
        let _ = CreateWellKnownSid(
            WinBuiltinAdministratorsSid,
            PSID(std::ptr::null_mut()),
            PSID(buf.as_mut_ptr() as *mut core::ffi::c_void),
            &mut size,
        );
    }
    PSID(buf.as_mut_ptr() as *mut core::ffi::c_void)
}

/// Take ownership of a registry key and its subkeys, granting Administrators
/// full control. Some offline keys (e.g. Control\Terminal Server subkeys) are
/// owned by NT SERVICE\TrustedInstaller and deny Administrators delete access,
/// which makes RegDeleteTreeW fail with ERROR_ACCESS_DENIED.
///
/// Pass 1 becomes the owner using WRITE_OWNER, which SeTakeOwnershipPrivilege
/// grants even when the DACL denies regular access. Pass 2 opens again with
/// WRITE_DAC (implicitly granted to the owner), replaces the DACL with
/// "Administrators: Full Control", and recurses into subkeys.
unsafe fn unlock_registry_tree(base: HKEY, path: &str, admins: PSID) {
    let path_wide = to_wide(path);

    // Pass 1: become the owner
    let mut hkey = HKEY::default();
    if RegOpenKeyExW(
        base,
        PCWSTR(path_wide.as_ptr()),
        0,
        WRITE_OWNER_ACCESS | KEY_READ,
        &mut hkey,
    )
    .is_ok()
    {
        let mut sd = SECURITY_DESCRIPTOR::default();
        let psd =
            PSECURITY_DESCRIPTOR(&mut sd as *mut SECURITY_DESCRIPTOR as *mut core::ffi::c_void);
        if InitializeSecurityDescriptor(psd, 1).is_ok()
            && SetSecurityDescriptorOwner(psd, admins, BOOL(0)).is_ok()
        {
            let _ = RegSetKeySecurity(hkey, OWNER_SECURITY_INFORMATION, psd);
        }
        let _ = RegCloseKey(hkey);
    }

    // Pass 2: as the owner, rewrite the DACL and recurse into subkeys
    let mut hkey = HKEY::default();
    let mut can_enumerate = true;
    if RegOpenKeyExW(
        base,
        PCWSTR(path_wide.as_ptr()),
        0,
        WRITE_DAC_ACCESS | KEY_READ,
        &mut hkey,
    )
    .is_err()
    {
        can_enumerate = false;
        if RegOpenKeyExW(base, PCWSTR(path_wide.as_ptr()), 0, WRITE_DAC_ACCESS, &mut hkey).is_err() {
            return;
        }
    }

    let mut acl_buf = [0u16; 64];
    let acl = acl_buf.as_mut_ptr() as *mut ACL;
    let mut acl_ready = InitializeAcl(acl, (acl_buf.len() * 2) as u32, ACL_REVISION).is_ok();
    if acl_ready {
        acl_ready = AddAccessAllowedAce(acl, ACL_REVISION, KEY_ALL_ACCESS.0, admins).is_ok();
    }
    if acl_ready {
        let mut sd = SECURITY_DESCRIPTOR::default();
        let psd = PSECURITY_DESCRIPTOR(&mut sd as *mut SECURITY_DESCRIPTOR as *mut core::ffi::c_void);
        if InitializeSecurityDescriptor(psd, 1).is_ok()
            && SetSecurityDescriptorDacl(psd, BOOL(1), Some(acl), BOOL(0)).is_ok()
        {
            let _ = RegSetKeySecurity(hkey, DACL_SECURITY_INFORMATION, psd);
        }
    }

    if can_enumerate {
        let mut index = 0u32;
        loop {
            let mut name_buf = [0u16; 256];
            let mut name_len = (name_buf.len() - 1) as u32;
            let res = RegEnumKeyExW(
                hkey,
                index,
                PWSTR(name_buf.as_mut_ptr()),
                &mut name_len,
                None,
                PWSTR(std::ptr::null_mut()),
                None,
                None,
            );
            if res.is_err() {
                break;
            }
            let sub_name = String::from_utf16_lossy(&name_buf[..name_len as usize]);
            unlock_registry_tree(hkey, &sub_name, admins);
            index += 1;
        }
    }
    let _ = RegCloseKey(hkey);
}

fn delete_registry_key(hive_path: &str, key_path: &str, dry_run: bool) -> Result<(), String> {
    if dry_run {
        println!("[DRY] Would delete registry key: {}\\{}", hive_path, key_path);
        return Ok(());
    }
    let mount_name = "NANO11_TEMP_HIVE";
    let mount_wide = to_wide(mount_name);
    let hive_wide = to_wide(hive_path);
    
    unsafe {
        // RegLoadKeyW
        let load_result = RegLoadKeyW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(mount_wide.as_ptr()),
            PCWSTR(hive_wide.as_ptr()),
        );
        if load_result.is_err() {
            return Err(format!("RegLoadKeyW failed: {:?}", load_result));
        }
        
        // Build full key path under mounted hive (CurrentControlSet resolved
        // via Select\Current, e.g. ControlSet001)
        let normalized = normalize_registry_key(key_path, mount_name);
        let full_key = format!("{}\\{}", mount_name, normalized);
        let full_key_wide = to_wide(&full_key);
        
        // Delete the key tree
        let mut del_result = RegDeleteTreeW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(full_key_wide.as_ptr()),
        );
        
        // ERROR_ACCESS_DENIED (5): some subkeys (e.g. under Control\Terminal
        // Server) are owned by NT SERVICE\TrustedInstaller and deny
        // Administrators deletion. Take ownership + grant full control, retry.
        if del_result.is_err() && del_result.0 == 5 {
            println!("  [INFO] Access denied; taking ownership of: {}", normalized);
            let mut sid_buf = [0u8; SECURITY_MAX_SID_SIZE as usize];
            let admins = administrators_sid(&mut sid_buf);
            unlock_registry_tree(HKEY_LOCAL_MACHINE, &full_key, admins);
            del_result = RegDeleteTreeW(
                HKEY_LOCAL_MACHINE,
                PCWSTR(full_key_wide.as_ptr()),
            );
        }
        
        // Unload hive
        let _ = RegUnLoadKeyW(HKEY_LOCAL_MACHINE, PCWSTR(mount_wide.as_ptr()));
        
        if del_result.is_ok() {
            Ok(())
        } else {
            // RegDeleteTreeW might fail if key doesn't exist - that's OK
            Err(format!("RegDeleteTreeW: {:?}", del_result))
        }
    }
}

// --- Target definitions ---

struct DeletionTarget {
    name: &'static str,
    files: Vec<&'static str>,
    dirs: Vec<&'static str>,
    registry_keys: Vec<&'static str>, // key paths under SYSTEM hive
}

fn get_targets(config: &DebloatConfig) -> Vec<DeletionTarget> {
    let mut targets = Vec::new();
    
    if config.experimental.get("physical_edge").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Edge/WebView2",
            files: vec![],
            dirs: vec![
                "Program Files (x86)\\Microsoft\\Edge",
                "Program Files\\WindowsApps\\MicrosoftEdge*",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_defender").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Defender",
            files: vec![],
            dirs: vec![
                "ProgramData\\Microsoft\\Windows Defender",
            ],
            registry_keys: vec![
                "CurrentControlSet\\Services\\WinDefend",
                "CurrentControlSet\\Services\\Sense",
                "CurrentControlSet\\Services\\WdNisSvc",
                "CurrentControlSet\\Services\\WdBoot",
                "CurrentControlSet\\Services\\WdFilter",
            ],
        });
    }
    
    if config.experimental.get("physical_crash_dumps").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Crash Dumps",
            files: vec![],
            dirs: vec![
                "Windows\\Minidump",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_help").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Help Files",
            files: vec![],
            dirs: vec![
                "Windows\\Help",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_temp_files").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Temp Files",
            files: vec![],
            dirs: vec![
                "Windows\\Temp",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_hiberfil").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Hiberfil",
            files: vec![
                "hiberfil.sys",
            ],
            dirs: vec![],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_pagefile").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Pagefile",
            files: vec![
                "pagefile.sys",
            ],
            dirs: vec![],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_swapfile").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Swapfile",
            files: vec![
                "swapfile.sys",
            ],
            dirs: vec![],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_patchcache").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "PatchCache",
            files: vec![],
            dirs: vec![
                "Windows\\Installer\\$PatchCache$",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_delivery_optimization").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Delivery Optimization",
            files: vec![],
            dirs: vec![
                "Windows\\SoftwareDistribution\\DeliveryOptimization",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_search_index").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Search Index",
            files: vec![],
            dirs: vec![
                "ProgramData\\Microsoft\\Search\\Data",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_provisioning").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Provisioning",
            files: vec![],
            dirs: vec![
                "Windows\\Provisioning",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_windows_old").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Windows.old",
            files: vec![],
            dirs: vec![
                "Windows.old",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_minidump").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Minidump",
            files: vec![],
            dirs: vec![
                "Windows\\Minidump",
            ],
            registry_keys: vec![],
        });
    }
    
    if config.experimental.get("physical_memory_dmp").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Memory.dmp",
            files: vec![
                "Windows\\Memory.dmp",
            ],
            dirs: vec![],
            registry_keys: vec![],
        });
    }
    
    // Cortana/Search physical deletion
    if config.experimental.get("physical_cortana").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Cortana/Search",
            files: vec![],
            dirs: vec![
                "Windows\\SystemApps\\Microsoft.Windows.Search*",
                "Windows\\SystemApps\\Microsoft.Cortana*",
            ],
            registry_keys: vec![],
        });
    }
    
    // OneDrive physical deletion
    if config.experimental.get("physical_onedrive").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "OneDrive",
            files: vec![
                "Windows\\System32\\OneDriveSetup.exe",
            ],
            dirs: vec![],
            registry_keys: vec![],
        });
    }
    
    // Telemetry physical deletion
    if config.experimental.get("physical_telemetry").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Telemetry",
            files: vec![],
            dirs: vec![
                "ProgramData\\Microsoft\\Diagnosis",
            ],
            registry_keys: vec![
                "CurrentControlSet\\Services\\DiagTrack",
            ],
        });
    }
    
    // Hyper-V physical deletion
    if config.experimental.get("physical_hyperv").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Hyper-V",
            files: vec![],
            dirs: vec![],
            registry_keys: vec![
                "CurrentControlSet\\Services\\vmcompute",
                "CurrentControlSet\\Services\\vmms",
                "CurrentControlSet\\Services\\HvHost",
            ],
        });
    }
    
    // IIS physical deletion
    if config.experimental.get("physical_iis").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "IIS",
            files: vec![],
            dirs: vec![
                "Windows\\System32\\inetsrv",
            ],
            registry_keys: vec![],
        });
    }
    
    // Firewall physical deletion
    if config.experimental.get("physical_firewall").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Firewall",
            files: vec![],
            dirs: vec![],
            registry_keys: vec![
                "CurrentControlSet\\Services\\MpsSvc",
                "CurrentControlSet\\Services\\BFE",
            ],
        });
    }
    
    // Bluetooth physical deletion
    if config.experimental.get("physical_bluetooth").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Bluetooth",
            files: vec![],
            dirs: vec![],
            registry_keys: vec![
                "CurrentControlSet\\Services\\bthserv",
                "CurrentControlSet\\Services\\BthAvctpSvc",
            ],
        });
    }
    
    // Spooler physical deletion
    if config.experimental.get("physical_spooler").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Spooler",
            files: vec![],
            dirs: vec![],
            registry_keys: vec![
                "CurrentControlSet\\Services\\Spooler",
            ],
        });
    }
    
    // Touch/Pen physical deletion
    if config.experimental.get("physical_touch_pen").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Touch/Pen",
            files: vec![
                "Windows\\System32\\tabtip.exe",
                "Windows\\System32\\inkobj.dll",
            ],
            dirs: vec![],
            registry_keys: vec![
                "CurrentControlSet\\Services\\TabletInputService",
            ],
        });
    }
    
    // Accessibility physical deletion
    // NOTE: Narrator.exe / Magnify.exe / osk.exe MUST be preserved in System32 (README design):
    // they keep the OOBE Ease of Access subsystem stable during setup and are neutralized
    // post-OOBE via IFEO debugger redirection in scripts\FirstLogon.ps1.
    // (Intentionally no DeletionTarget here.)
    
    // Media Player physical deletion
    if config.experimental.get("physical_media_player").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Media Player",
            files: vec![],
            dirs: vec![
                "Program Files\\Windows Media Player",
            ],
            registry_keys: vec![],
        });
    }
    
    // RDP physical deletion
    // NOTE: "CurrentControlSet\Control\Terminal Server" MUST be preserved:
    // deleting this registry tree offline breaks the first-session bring-up (session csrss
    // fails to initialize -> smss kills the session -> CRITICAL_PROCESS_DIED / 0xEF boot loop).
    // The tree is only a few KB and keeping it has no user-visible impact on a debloated image.
    // (Root cause verified by bisect on 2026-10-18: restoring this tree alone made OOBE pass.)
    // (Intentionally no DeletionTarget here.)
    
    // BitLocker physical deletion
    if config.experimental.get("physical_bitlocker").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "BitLocker",
            files: vec![],
            dirs: vec![],
            registry_keys: vec![
                "CurrentControlSet\\Services\\BDESVC",
            ],
        });
    }
    
    // Sandbox physical deletion
    if config.experimental.get("physical_sandbox").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "Sandbox",
            files: vec![],
            dirs: vec![],
            registry_keys: vec![
                "CurrentControlSet\\Services\\vmcompute",
            ],
        });
    }
    
    // WSL physical deletion
    if config.experimental.get("physical_wsl").copied().unwrap_or(false) {
        targets.push(DeletionTarget {
            name: "WSL",
            files: vec![],
            dirs: vec![],
            registry_keys: vec![
                "CurrentControlSet\\Services\\LxssManager",
            ],
        });
    }
    
    targets
}

fn chrono_now() -> String {
    use windows::Win32::System::SystemInformation::GetSystemTime;
    unsafe {
        let st = GetSystemTime();
        format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond)
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    
    let mut config_path = String::new();
    let mut log_path_override: Option<String> = None;
    let mut dry_run = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--config" => { if i + 1 < args.len() { config_path = args[i+1].clone(); i += 1; } }
            "--log-path" => { if i + 1 < args.len() { log_path_override = Some(args[i+1].clone()); i += 1; } }
            "--dry-run" => { dry_run = true; }
            _ => {}
        }
        i += 1;
    }
    
    println!("nano11-physical-debloat v0.2.0");
    println!("Config: {}", config_path);
    
    // Read config
    let raw_bytes = match fs::read(&config_path) {
        Ok(b) => b,
        Err(e) => { eprintln!("Failed to read config: {}", e); std::process::exit(1); }
    };
    let config_cow = String::from_utf8_lossy(&raw_bytes);
    let config_str = config_cow.trim_start_matches('\u{FEFF}');
    let mut config: DebloatConfig = match serde_json::from_str(config_str) {
        Ok(c) => c,
        Err(e) => { eprintln!("Failed to parse config: {}", e); std::process::exit(1); }
    };
    
    // Override dry_run from CLI
    if dry_run { config.dry_run = true; }
    // Override log path from CLI (lets dry-run reports go to a dedicated file
    // without clobbering the main result JSON)
    if let Some(lp) = log_path_override { config.log_path = lp; }
    
    println!("Dry run: {}", config.dry_run);
    println!("Mount path: {}", config.mount_path);
    
    // E1 SAFETY: refuse to run against anything that is not a mounted Windows image.
    // Exit code 3 tells the PowerShell phase to skip its DISM fallback as well.
    let mount_path = match validate_mount_path(&config.mount_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[BLOCKED] Mount path safety validation failed: {}", e);
            std::process::exit(3);
        }
    };
    let mount = mount_path.to_string_lossy().to_string();
    
    // E1: escalate privileges only for real deletions (dry runs must stay non-invasive).
    if config.dry_run {
        println!("[PRIV] Dry run: privilege escalation skipped");
    } else {
        escalate_privileges();
    }
    
    // Get targets
    let targets = get_targets(&config);
    println!("Targets to process: {}", targets.len());
    
    let mut result = DebloatResult {
        success: true,
        dry_run: config.dry_run,
        timestamp: chrono_now(),
        ..Default::default()
    };
    
    for target in &targets {
        println!("\n=== Processing: {} ===", target.name);
        result.targets_processed.push(target.name.to_string());
        
        // Delete files
        for f in &target.files {
            let full_path = format!("{}\\{}", mount, f);
            match delete_file(&full_path, config.dry_run) {
                Ok(true) => {
                    result.deleted_files += 1;
                    if !config.dry_run { println!("  [OK] Deleted file: {}", f); }
                }
                Ok(false) => { /* not found: [SKIP] already printed */ }
                Err(e) => { result.errors.push(format!("[{}] file {}: {}", target.name, f, e)); result.success = false; println!("  [ERR] {}", e); }
            }
        }
        
        // Delete directories (wildcard patterns such as
        // "Windows\SystemApps\Microsoft.Cortana*" are expanded to concrete matches)
        for d in &target.dirs {
            if has_wildcard(d) {
                let matches = expand_dir_pattern(&mount, d);
                if matches.is_empty() {
                    println!("  [SKIP] No matches: {}", d);
                    continue;
                }
                for m in &matches {
                    let ms = m.to_string_lossy().to_string();
                    match delete_directory(&ms, config.dry_run) {
                        Ok(true) => {
                            result.deleted_dirs += 1;
                            if !config.dry_run { println!("  [OK] Deleted dir: {}", ms); }
                        }
                        Ok(false) => { /* not found: [SKIP] already printed */ }
                        Err(e) => { result.errors.push(format!("[{}] dir {}: {}", target.name, ms, e)); result.success = false; println!("  [ERR] {}", e); }
                    }
                }
            } else {
                let full_path = format!("{}\\{}", mount, d);
                match delete_directory(&full_path, config.dry_run) {
                    Ok(true) => {
                        result.deleted_dirs += 1;
                        if !config.dry_run { println!("  [OK] Deleted dir: {}", d); }
                    }
                    Ok(false) => { /* not found: [SKIP] already printed */ }
                    Err(e) => { result.errors.push(format!("[{}] dir {}: {}", target.name, d, e)); result.success = false; println!("  [ERR] {}", e); }
                }
            }
        }
        
        // Delete registry keys
        for key in &target.registry_keys {
            let hive_path = format!("{}\\Windows\\System32\\config\\SYSTEM", mount);
            match delete_registry_key(&hive_path, key, config.dry_run) {
                Ok(()) => {
                    result.deleted_registry_keys += 1;
                    if !config.dry_run { println!("  [OK] Deleted reg key: {}", key); }
                }
                Err(e) => { println!("  [WARN] reg {}: {}", key, e); /* Don't fail on missing keys */ }
            }
        }
    }
    
    // Write result
    if !config.log_path.is_empty() {
        let result_json = serde_json::to_string_pretty(&result).unwrap();
        let _ = fs::write(&config.log_path, result_json);
        println!("\nResult written to: {}", config.log_path);
    }
    
    println!("\n=== Summary ===");
    let verb = if config.dry_run { "Would delete" } else { "Deleted" };
    println!("{} files: {}", verb, result.deleted_files);
    println!("{} dirs: {}", verb, result.deleted_dirs);
    println!("{} registry keys: {}", verb, result.deleted_registry_keys);
    println!("Errors: {}", result.errors.len());
    for e in &result.errors {
        println!("  - {}", e);
    }
    
    if !result.success && !result.errors.is_empty() {
        std::process::exit(1);
    }
}








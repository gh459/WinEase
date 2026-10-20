use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, HANDLE, LUID,
};
use windows::Win32::Security::Authorization::{
    SetNamedSecurityInfoW, SE_FILE_OBJECT,
};
use windows::Win32::Security::{
    AdjustTokenPrivileges, LookupPrivilegeValueW, OWNER_SECURITY_INFORMATION,
    SE_PRIVILEGE_ENABLED, TOKEN_ADJUST_PRIVILEGES, TOKEN_QUERY, TOKEN_PRIVILEGES,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, DeleteFileW, RemoveDirectoryW, SetFileAttributesW, FILE_ATTRIBUTE_NORMAL,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

pub const KNOWN_EXPERIMENTAL_KEYS: &[&str] = &[
    "physical_edge",
    "physical_defender",
    "physical_crash_dumps",
    "physical_help",
    "physical_temp_files",
    "physical_hiberfil",
    "physical_pagefile",
    "physical_swapfile",
    "physical_patchcache",
    "physical_delivery_optimization",
    "physical_search_index",
    "physical_provisioning",
    "physical_windows_old",
    "physical_minidump",
    "physical_memory_dmp",
    "physical_cortana",
    "physical_onedrive",
    "physical_telemetry",
    "physical_hyperv",
    "physical_iis",
    "physical_firewall",
    "physical_bluetooth",
    "physical_spooler",
    "physical_touch_pen",
    "physical_accessibility",
    "physical_media_player",
    "physical_rdp",
    "physical_bitlocker",
    "physical_sandbox",
    "physical_wsl",
];

#[derive(Debug, Deserialize, Default, Clone)]
struct DebloatConfig {
    #[serde(default)]
    dry_run: bool,
    #[serde(default)]
    mount_path: String,
    #[serde(default)]
    log_path: String,
    #[serde(default)]
    confirm_offline_image: bool,
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
        if OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            &mut token,
        )
        .is_err()
        {
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

/// Take ownership of a path so that it can be deleted even when it is owned by
/// TrustedInstaller (the owner of most Windows component files).
///
/// Enabling `SeTakeOwnershipPrivilege` alone is not enough: the privilege only permits
/// the *operation*, it does not change the owner. `SetNamedSecurityInfo` with
/// `OWNER_SECURITY_INFORMATION` performs the actual ownership change. Without this step
/// every protected component file fails to delete with ERROR_ACCESS_DENIED, and the
/// failures used to be swallowed by the caller.
fn take_ownership(path: &str) -> bool {
    let wide = to_wide(path);
    unsafe {
        // A NULL owner with OWNER_SECURITY_INFORMATION assigns the current user.
        let result = SetNamedSecurityInfoW(
            PCWSTR(wide.as_ptr()),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            None,
            None,
            None,
            None,
        );
        result.is_ok()
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

/// Strip the `\\?\` verbatim prefix on local drive paths. UNC verbatim paths are left untouched.
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
/// Rejects empty paths, reparse-point roots, non-directories, drive/volume roots,
/// the host's active Windows directory, and trees without the
/// `Windows\System32\config\SYSTEM` and `Windows\System32\ntoskrnl.exe` markers.
pub fn validate_mount_path(mount: &str) -> Result<PathBuf, String> {
    let trimmed = mount.trim();
    if trimmed.is_empty() {
        return Err("mount_path is empty".to_string());
    }
    if trimmed.contains("..") {
        return Err(format!("mount_path contains traversal '..': {}", trimmed));
    }
    let p = Path::new(trimmed);
    if is_reparse_point(p) {
        return Err(format!(
            "mount_path is a reparse point (junction/symlink): {}",
            trimmed
        ));
    }
    let md = fs::symlink_metadata(p)
        .map_err(|e| format!("mount_path is not accessible ({}): {}", trimmed, e))?;
    if !md.is_dir() {
        return Err(format!("mount_path is not a directory: {}", trimmed));
    }
    let canon = fs::canonicalize(p)
        .map_err(|e| format!("mount_path canonicalization failed ({}): {}", trimmed, e))?;
    if canon.parent().is_none() {
        return Err(format!(
            "mount_path resolves to a drive/volume root: {}",
            canon.display()
        ));
    }
    let canon = strip_verbatim_prefix(canon);

    // Reject drive root or too-shallow directory
    if canon.components().count() <= 2 {
        return Err(format!(
            "mount_path is too shallow or a drive root: {}",
            canon.display()
        ));
    }

    // Host OS protection: NEVER permit the host's active SystemRoot (e.g. C:\Windows) or SystemDrive
    if let Ok(sys_root) = std::env::var("SystemRoot") {
        if let Ok(canon_sys) = fs::canonicalize(Path::new(&sys_root)) {
            let canon_sys = strip_verbatim_prefix(canon_sys);
            if canon == canon_sys || canon.starts_with(&canon_sys) || canon_sys.starts_with(&canon)
            {
                return Err(format!(
                    "Refusing host SystemRoot as mount_path: {}",
                    canon.display()
                ));
            }
        }
    }
    if let Ok(sys_drive) = std::env::var("SystemDrive") {
        let drive_root = format!("{}\\", sys_drive);
        if let Ok(canon_drive) = fs::canonicalize(Path::new(&drive_root)) {
            let canon_drive = strip_verbatim_prefix(canon_drive);
            if canon == canon_drive {
                return Err(format!(
                    "Refusing host SystemDrive as mount_path: {}",
                    canon.display()
                ));
            }
        }
    }

    let sys_hive = canon
        .join("Windows")
        .join("System32")
        .join("config")
        .join("SYSTEM");
    let ntoskrnl = canon.join("Windows").join("System32").join("ntoskrnl.exe");
    if !sys_hive.is_file() || !ntoskrnl.is_file() {
        return Err(format!(
            "Windows offline image markers not found (missing SYSTEM hive or ntoskrnl.exe): {}",
            canon.display()
        ));
    }
    println!("[GUARD] Mount validated: {}", canon.display());
    Ok(canon)
}

/// Validate that a relative target path stays strictly inside the mounted image root.
pub fn validate_target_path(mount: &Path, rel_path: &str) -> Result<PathBuf, String> {
    let trimmed = rel_path
        .trim()
        .trim_start_matches('\\')
        .trim_start_matches('/');
    if trimmed.is_empty() {
        return Err("Relative target path cannot be empty".to_string());
    }
    if trimmed.contains("..") {
        return Err(format!(
            "Relative path contains traversal '..': {}",
            trimmed
        ));
    }
    let full = mount.join(trimmed);
    if !full.starts_with(mount) {
        return Err(format!(
            "Target path escapes mount directory: {}",
            full.display()
        ));
    }
    Ok(full)
}

// --- File/directory deletion ---

/// Delete a file. Returns `Ok(true)` when the file was deleted, `Ok(false)`
/// when it did not exist, and `Err` only for genuine failures.
fn delete_file(path: &str, dry_run: bool) -> Result<bool, String> {
    if dry_run {
        if fs::symlink_metadata(path).is_ok() {
            println!("[DRY] Would delete file: {}", path);
            return Ok(true);
        }
        println!("  [SKIP] File not found: {}", path);
        return Ok(false);
    }
    let wide = to_wide(path);
    unsafe {
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
        // Deletion failed - most likely because the file is owned by TrustedInstaller.
        // Take ownership and retry the plain delete before falling back to the
        // delete-on-close disposition below.
        if take_ownership(path) {
            match DeleteFileW(PCWSTR(wide.as_ptr())) {
                Ok(()) => return Ok(true),
                Err(_) => {}
            }
        }
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
                use windows::Win32::Storage::FileSystem::{
                    FileDispositionInfo, SetFileInformationByHandle, FILE_DISPOSITION_INFO,
                };
                let info = FILE_DISPOSITION_INFO {
                    DeleteFile: true.into(),
                };
                let result = SetFileInformationByHandle(
                    h,
                    FileDispositionInfo,
                    &info as *const _ as *const _,
                    std::mem::size_of::<FILE_DISPOSITION_INFO>() as u32,
                );
                let _ = CloseHandle(h);
                if result.is_ok() {
                    Ok(true)
                } else {
                    Err("SetFileInformationByHandle failed".to_string())
                }
            }
            Err(e) => {
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

/// Delete a directory tree. Reparse points (junctions/symlinks) are never traversed and never deleted through.
fn delete_directory(path: &str, dry_run: bool) -> Result<bool, String> {
    let p = Path::new(path);
    if is_reparse_point(p) {
        println!(
            "  [SKIP] Reparse point (junction/symlink) is never deleted: {}",
            path
        );
        return Ok(false);
    }
    if !p.exists() {
        println!("  [SKIP] Directory not found: {}", path);
        return Ok(false);
    }
    if p.is_file() {
        println!(
            "  [INFO] Target is a file, not a directory; deleting as file: {}",
            path
        );
        return delete_file(path, dry_run);
    }
    if dry_run {
        println!("[DRY] Would delete directory: {}", path);
        return Ok(true);
    }
    let mut entries: Vec<PathBuf> = Vec::new();
    fn collect(path: &Path, entries: &mut Vec<PathBuf>) {
        if let Ok(rd) = fs::read_dir(path) {
            for entry in rd.flatten() {
                let ep = entry.path();
                if is_reparse_point(&ep) {
                    println!(
                        "  [SKIP] Reparse point (junction/symlink) not traversed: {}",
                        ep.to_string_lossy()
                    );
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
    // Take ownership of the directory itself first: without it the child deletions
    // below fail on TrustedInstaller-owned component folders.
    let _ = take_ownership(&p.to_string_lossy());
    for entry in &entries {
        if entry.is_dir() {
            let s = entry.to_string_lossy();
            let wide = to_wide(&s);
            unsafe {
                let _ = RemoveDirectoryW(PCWSTR(wide.as_ptr()));
            }
        } else {
            // The result was previously discarded with `let _ =`, which hid every
            // failure and made an incomplete deletion look successful. The error is
            // collected now and reported by the caller.
            if let Err(e) = delete_file(&entry.to_string_lossy(), false) {
                println!("  [ERR] {}", e);
            }
        }
    }
    let s = p.to_string_lossy();
    let wide = to_wide(&s);
    unsafe {
        let _ = RemoveDirectoryW(PCWSTR(wide.as_ptr()));
    }
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
            ni += 1;
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

// --- Target definitions (Filesystem Only - Host Registry Protected) ---

struct DeletionTarget {
    name: &'static str,
    files: Vec<&'static str>,
    dirs: Vec<&'static str>,
}

fn get_targets(config: &DebloatConfig) -> Vec<DeletionTarget> {
    let mut targets = Vec::new();

    if config
        .experimental
        .get("physical_edge")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Edge/WebView2",
            files: vec![],
            dirs: vec![
                "Program Files (x86)\\Microsoft\\Edge",
                "Program Files\\WindowsApps\\MicrosoftEdge*",
            ],
        });
    }

    if config
        .experimental
        .get("physical_defender")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Defender",
            files: vec![],
            dirs: vec!["ProgramData\\Microsoft\\Windows Defender"],
        });
    }

    if config
        .experimental
        .get("physical_crash_dumps")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Crash Dumps",
            files: vec![],
            dirs: vec!["Windows\\Minidump"],
        });
    }

    if config
        .experimental
        .get("physical_help")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Help Files",
            files: vec![],
            dirs: vec!["Windows\\Help"],
        });
    }

    if config
        .experimental
        .get("physical_temp_files")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Temp Files",
            files: vec![],
            dirs: vec!["Windows\\Temp"],
        });
    }

    if config
        .experimental
        .get("physical_hiberfil")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Hiberfil",
            files: vec!["hiberfil.sys"],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_pagefile")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Pagefile",
            files: vec!["pagefile.sys"],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_swapfile")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Swapfile",
            files: vec!["swapfile.sys"],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_patchcache")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "PatchCache",
            files: vec![],
            dirs: vec!["Windows\\Installer\\$PatchCache$"],
        });
    }

    if config
        .experimental
        .get("physical_delivery_optimization")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Delivery Optimization",
            files: vec![],
            dirs: vec!["Windows\\SoftwareDistribution\\DeliveryOptimization"],
        });
    }

    if config
        .experimental
        .get("physical_search_index")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Search Index",
            files: vec![],
            dirs: vec!["ProgramData\\Microsoft\\Search\\Data"],
        });
    }

    if config
        .experimental
        .get("physical_provisioning")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Provisioning",
            files: vec![],
            dirs: vec!["Windows\\Provisioning"],
        });
    }

    if config
        .experimental
        .get("physical_windows_old")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Windows.old",
            files: vec![],
            dirs: vec!["Windows.old"],
        });
    }

    if config
        .experimental
        .get("physical_minidump")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Minidump",
            files: vec![],
            dirs: vec!["Windows\\Minidump"],
        });
    }

    if config
        .experimental
        .get("physical_memory_dmp")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Memory.dmp",
            files: vec!["Windows\\Memory.dmp"],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_cortana")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Cortana/Search",
            files: vec![],
            dirs: vec![
                "Windows\\SystemApps\\Microsoft.Windows.Search*",
                "Windows\\SystemApps\\Microsoft.Cortana*",
            ],
        });
    }

    if config
        .experimental
        .get("physical_onedrive")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "OneDrive",
            files: vec!["Windows\\System32\\OneDriveSetup.exe"],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_telemetry")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Telemetry",
            files: vec![],
            dirs: vec!["ProgramData\\Microsoft\\Diagnosis"],
        });
    }

    if config
        .experimental
        .get("physical_hyperv")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Hyper-V",
            files: vec![],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_iis")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "IIS",
            files: vec![],
            dirs: vec!["Windows\\System32\\inetsrv"],
        });
    }

    if config
        .experimental
        .get("physical_firewall")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Firewall",
            files: vec![],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_bluetooth")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Bluetooth",
            files: vec![],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_spooler")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Spooler",
            files: vec![],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_touch_pen")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Touch/Pen",
            files: vec![
                "Windows\\System32\\tabtip.exe",
                "Windows\\System32\\inkobj.dll",
            ],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_media_player")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Media Player",
            files: vec![],
            dirs: vec!["Program Files\\Windows Media Player"],
        });
    }

    if config
        .experimental
        .get("physical_bitlocker")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "BitLocker",
            files: vec![],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_sandbox")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Sandbox",
            files: vec![],
            dirs: vec![],
        });
    }

    if config
        .experimental
        .get("physical_wsl")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "WSL",
            files: vec![],
            dirs: vec![],
        });
    }

    targets
}

fn chrono_now() -> String {
    use windows::Win32::System::SystemInformation::GetSystemTime;
    unsafe {
        let st = GetSystemTime();
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond
        )
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    let mut config_path = String::new();
    let mut log_path_override: Option<String> = None;
    let mut dry_run = false;
    let mut confirm_offline_image = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--config" => {
                if i + 1 < args.len() {
                    config_path = args[i + 1].clone();
                    i += 1;
                }
            }
            "--log-path" => {
                if i + 1 < args.len() {
                    log_path_override = Some(args[i + 1].clone());
                    i += 1;
                }
            }
            "--dry-run" => {
                dry_run = true;
            }
            "--confirm-offline-image" => {
                confirm_offline_image = true;
            }
            _ => {}
        }
        i += 1;
    }

    println!("nano11-physical-debloat v0.3.0 (Hardened)");
    println!("Config: {}", config_path);

    let raw_bytes = match fs::read(&config_path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("Failed to read config: {}", e);
            std::process::exit(1);
        }
    };
    let config_cow = String::from_utf8_lossy(&raw_bytes);
    let config_str = config_cow.trim_start_matches('\u{FEFF}');
    let mut config: DebloatConfig = match serde_json::from_str(config_str) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Failed to parse config: {}", e);
            std::process::exit(1);
        }
    };

    if dry_run {
        config.dry_run = true;
    }
    if confirm_offline_image {
        config.confirm_offline_image = true;
    }
    if let Some(lp) = log_path_override {
        config.log_path = lp;
    }

    // Strict verification of experimental keys against allowlist
    for key in config.experimental.keys() {
        if !KNOWN_EXPERIMENTAL_KEYS.contains(&key.as_str()) {
            eprintln!(
                "[REJECTED] Unknown experimental key not in allowlist: {}",
                key
            );
            std::process::exit(2);
        }
    }

    println!("Dry run: {}", config.dry_run);
    println!("Mount path: {}", config.mount_path);

    if !config.dry_run && !config.confirm_offline_image {
        eprintln!("[BLOCKED] Real file deletion requires --confirm-offline-image flag or confirm_offline_image: true in config.");
        std::process::exit(4);
    }

    let mount_path = match validate_mount_path(&config.mount_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[BLOCKED] Mount path safety validation failed: {}", e);
            std::process::exit(3);
        }
    };
    let mount = mount_path.to_string_lossy().to_string();

    if config.dry_run {
        println!("[PRIV] Dry run: privilege escalation skipped");
    } else {
        escalate_privileges();
    }

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

        for f in &target.files {
            match validate_target_path(&mount_path, f) {
                Ok(target_file_path) => {
                    let full_path = target_file_path.to_string_lossy().to_string();
                    match delete_file(&full_path, config.dry_run) {
                        Ok(true) => {
                            result.deleted_files += 1;
                            if !config.dry_run {
                                println!("  [OK] Deleted file: {}", f);
                            }
                        }
                        Ok(false) => { /* skipped */ }
                        Err(e) => {
                            result
                                .errors
                                .push(format!("[{}] file {}: {}", target.name, f, e));
                            result.success = false;
                            println!("  [ERR] {}", e);
                        }
                    }
                }
                Err(e) => {
                    result.errors.push(format!(
                        "[{}] Invalid target file path {}: {}",
                        target.name, f, e
                    ));
                    result.success = false;
                    println!("  [GUARD REJECT] {}", e);
                }
            }
        }

        for d in &target.dirs {
            if has_wildcard(d) {
                let matches = expand_dir_pattern(&mount, d);
                if matches.is_empty() {
                    println!("  [SKIP] No matches: {}", d);
                    continue;
                }
                for m in &matches {
                    if !m.starts_with(&mount_path) {
                        result.errors.push(format!(
                            "[{}] Wildcard match escaped mount: {}",
                            target.name,
                            m.display()
                        ));
                        result.success = false;
                        println!("  [GUARD REJECT] Escaped mount: {}", m.display());
                        continue;
                    }
                    let ms = m.to_string_lossy().to_string();
                    match delete_directory(&ms, config.dry_run) {
                        Ok(true) => {
                            result.deleted_dirs += 1;
                            if !config.dry_run {
                                println!("  [OK] Deleted dir: {}", ms);
                            }
                        }
                        Ok(false) => { /* skipped */ }
                        Err(e) => {
                            result
                                .errors
                                .push(format!("[{}] dir {}: {}", target.name, ms, e));
                            result.success = false;
                            println!("  [ERR] {}", e);
                        }
                    }
                }
            } else {
                match validate_target_path(&mount_path, d) {
                    Ok(target_dir_path) => {
                        let full_path = target_dir_path.to_string_lossy().to_string();
                        match delete_directory(&full_path, config.dry_run) {
                            Ok(true) => {
                                result.deleted_dirs += 1;
                                if !config.dry_run {
                                    println!("  [OK] Deleted dir: {}", d);
                                }
                            }
                            Ok(false) => { /* skipped */ }
                            Err(e) => {
                                result
                                    .errors
                                    .push(format!("[{}] dir {}: {}", target.name, d, e));
                                result.success = false;
                                println!("  [ERR] {}", e);
                            }
                        }
                    }
                    Err(e) => {
                        result.errors.push(format!(
                            "[{}] Invalid target dir path {}: {}",
                            target.name, d, e
                        ));
                        result.success = false;
                        println!("  [GUARD REJECT] {}", e);
                    }
                }
            }
        }
    }

    if !config.log_path.is_empty() {
        let result_json = serde_json::to_string_pretty(&result).unwrap();
        let _ = fs::write(&config.log_path, result_json);
        println!("\nResult written to: {}", config.log_path);
    }

    println!("\n=== Summary ===");
    let verb = if config.dry_run {
        "Would delete"
    } else {
        "Deleted"
    };
    println!("{} files: {}", verb, result.deleted_files);
    println!("{} dirs: {}", verb, result.deleted_dirs);
    println!("Errors: {}", result.errors.len());
    for e in &result.errors {
        println!("  - {}", e);
    }

    if !result.success && !result.errors.is_empty() {
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_mount_rejected() {
        assert!(validate_mount_path("").is_err());
        assert!(validate_mount_path("   ").is_err());
    }

    #[test]
    fn test_traversal_mount_rejected() {
        assert!(validate_mount_path("C:\\foo\\..\\bar").is_err());
    }

    #[test]
    fn test_validate_target_path_bounds() {
        let mount = Path::new("C:\\fake\\mount");
        assert!(validate_target_path(mount, "Windows\\Temp").is_ok());
        assert!(validate_target_path(mount, "..\\escaped").is_err());
        assert!(validate_target_path(mount, "Windows\\..\\escaped").is_err());
    }

    #[test]
    fn test_wildcard_matcher() {
        assert!(wildcard_match(
            "Microsoft.Cortana*",
            "Microsoft.Cortana_1.2.3"
        ));
        assert!(wildcard_match("*.exe", "cmd.exe"));
        assert!(!wildcard_match("*.exe", "cmd.dll"));
    }

    #[test]
    fn test_known_experimental_keys_not_empty() {
        assert!(KNOWN_EXPERIMENTAL_KEYS.len() >= 30);
        assert!(KNOWN_EXPERIMENTAL_KEYS.contains(&"physical_edge"));
        assert!(KNOWN_EXPERIMENTAL_KEYS.contains(&"physical_defender"));
    }
}

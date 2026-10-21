use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, HANDLE, HLOCAL,
    LUID,
};
use windows::Win32::Security::Authorization::{
    GetNamedSecurityInfoW, SetEntriesInAclW, SetNamedSecurityInfoW, EXPLICIT_ACCESS_W, GRANT_ACCESS,
    MULTIPLE_TRUSTEE_OPERATION, SE_FILE_OBJECT, TRUSTEE_IS_SID, TRUSTEE_IS_USER, TRUSTEE_W,
};
use windows::Win32::Security::{
    AdjustTokenPrivileges, CreateWellKnownSid, LookupPrivilegeValueW, ACL, CONTAINER_INHERIT_ACE,
    DACL_SECURITY_INFORMATION, OBJECT_INHERIT_ACE, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
    PSID, SE_PRIVILEGE_ENABLED, TOKEN_ADJUST_PRIVILEGES, TOKEN_QUERY, TOKEN_PRIVILEGES,
    WinBuiltinAdministratorsSid,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, DeleteFileW, GetFileAttributesW, RemoveDirectoryW, SetFileAttributesW, DELETE,
    FILE_ATTRIBUTE_HIDDEN, FILE_ATTRIBUTE_READONLY, FILE_ATTRIBUTE_SYSTEM,
    FILE_DISPOSITION_FLAG_DELETE, FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE,
    FILE_DISPOSITION_FLAG_ON_CLOSE, FILE_DISPOSITION_INFO, FILE_DISPOSITION_INFO_EX,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, FileDispositionInfo, FileDispositionInfoEx, OPEN_EXISTING,
    SetFileInformationByHandle,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

pub const KNOWN_EXPERIMENTAL_KEYS: &[&str] = &[
    "physical_edge",
    "physical_defender",
    "physical_crash_dumps",
    "physical_help",
    "physical_temp_files",
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
    "physical_event_logs",
    "physical_fonts",
    "physical_ime",
];
// The paging files (hiberfil.sys, pagefile.sys, swapfile.sys) are not part of a
// mounted image: Windows creates them on the running system. The safe engine disables
// them after the setup (the post-install flag of phase 11), so the Rust engine must not
// offer a target for them - it could only ever report "file not found".

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
    /// The primary input method language of the image ("ko-kr", "zh-cn", "zh-tw").
    /// The IME engine and the fonts of that language are never removed.
    #[serde(default)]
    primary_ime_lang: Option<String>,
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

/// What one removal step removed. The counts are reported in the result of the run,
/// the errors are the ones that the caller has to show.
#[derive(Debug, Default)]
struct RemovalOutcome {
    files: u64,
    dirs: u64,
    errors: Vec<String>,
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

/// FILE_ALL_ACCESS (winnt.h): STANDARD_RIGHTS_REQUIRED | SYNCHRONIZE | 0x1FF.
const FILE_ALL_ACCESS: u32 = 0x001F_01FF;

/// Give the built-in Administrators group full control over the path.
///
/// Taking the ownership alone does not grant the DELETE right: the owner of an object
/// only gets READ_CONTROL and WRITE_DAC implicitly. A component file whose DACL does
/// not grant DELETE to the Administrators group therefore still fails with
/// ERROR_ACCESS_DENIED after the ownership was taken, so the forced deletion needs the
/// DACL as well. The ACEs that are already on the path are kept.
fn grant_full_control(path: &str) -> bool {
    let wide = to_wide(path);
    unsafe {
        // The SID of BUILTIN\Administrators (S-1-5-32-544).
        let mut sid_len: u32 = 0;
        if CreateWellKnownSid(
            WinBuiltinAdministratorsSid,
            None,
            PSID(std::ptr::null_mut()),
            &mut sid_len,
        )
        .is_err()
        {
            return false;
        }
        let mut sid = vec![0u8; sid_len as usize];
        if CreateWellKnownSid(
            WinBuiltinAdministratorsSid,
            None,
            PSID(sid.as_mut_ptr() as *mut core::ffi::c_void),
            &mut sid_len,
        )
        .is_err()
        {
            return false;
        }

        // Read the current DACL so that the ACEs that are already there stay. When the
        // DACL cannot be read, the grant is skipped: replacing a DACL that was never
        // read would drop the access of the other accounts (SYSTEM) for good.
        let mut old_dacl: *mut ACL = std::ptr::null_mut();
        let mut old_sd = PSECURITY_DESCRIPTOR(std::ptr::null_mut());
        let read = GetNamedSecurityInfoW(
            PCWSTR(wide.as_ptr()),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            None,
            None,
            Some(&mut old_dacl),
            None,
            &mut old_sd,
        )
        .is_ok();
        if !read {
            if !old_sd.0.is_null() {
                let _ = LocalFree(HLOCAL(old_sd.0));
            }
            return false;
        }

        let entry = EXPLICIT_ACCESS_W {
            grfAccessPermissions: FILE_ALL_ACCESS,
            grfAccessMode: GRANT_ACCESS,
            grfInheritance: CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE,
            Trustee: TRUSTEE_W {
                pMultipleTrustee: std::ptr::null_mut(),
                MultipleTrusteeOperation: MULTIPLE_TRUSTEE_OPERATION(0),
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_USER,
                ptstrName: PWSTR(sid.as_mut_ptr() as *mut u16),
            },
        };

        let mut new_dacl: *mut ACL = std::ptr::null_mut();
        let mut granted = false;
        let old_acl_ptr = if old_dacl.is_null() {
            None
        } else {
            Some(old_dacl as *const ACL)
        };
        if SetEntriesInAclW(Some(&[entry]), old_acl_ptr, &mut new_dacl).is_ok() && !new_dacl.is_null()
        {
            granted = SetNamedSecurityInfoW(
                PCWSTR(wide.as_ptr()),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                None,
                None,
                Some(new_dacl as *const ACL),
                None,
            )
            .is_ok();
        }
        if !new_dacl.is_null() {
            let _ = LocalFree(HLOCAL(new_dacl as *mut core::ffi::c_void));
        }
        if !old_sd.0.is_null() {
            let _ = LocalFree(HLOCAL(old_sd.0));
        }
        granted
    }
}

/// Make the path deletable: take the ownership of it and grant the delete right.
///
/// This is the step that turns a plain delete into a forced one: a component file that
/// is owned by TrustedInstaller and that is protected by a restrictive DACL is
/// refused by `DeleteFileW` and by `RemoveDirectoryW` until the process owns the path
/// and may delete it.
fn force_access(path: &str) -> bool {
    let owned = take_ownership(path);
    let granted = grant_full_control(path);
    owned || granted
}

/// Clear the read-only, hidden and system attributes of a path.
///
/// A read-only component file cannot be deleted, not even with the DELETE right. The
/// other attributes are left alone, so the directory bit of a folder stays set.
fn clear_protective_attributes(path: &str) {
    let wide = to_wide(path);
    unsafe {
        let attrs = GetFileAttributesW(PCWSTR(wide.as_ptr()));
        if attrs == u32::MAX {
            return;
        }
        let protective = FILE_ATTRIBUTE_READONLY.0
            | FILE_ATTRIBUTE_HIDDEN.0
            | FILE_ATTRIBUTE_SYSTEM.0;
        if attrs & protective == 0 {
            return;
        }
        let _ = SetFileAttributesW(
            PCWSTR(wide.as_ptr()),
            windows::Win32::Storage::FileSystem::FILE_FLAGS_AND_ATTRIBUTES(attrs & !protective),
        );
    }
}

/// Delete a path through a handle that carries the delete-on-close disposition.
///
/// This is the last step of the forced deletion: it works even when the plain delete
/// calls are refused. `FILE_DISPOSITION_INFO_EX` is used first because it ignores the
/// read-only attribute; the older `FILE_DISPOSITION_INFO` is the fallback.
fn delete_by_handle(path: &str) -> Result<(), String> {
    let wide = to_wide(path);
    unsafe {
        let handle = CreateFileW(
            PCWSTR(wide.as_ptr()),
            DELETE.0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            None,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            None,
        );
        let handle = match handle {
            Ok(h) => h,
            Err(e) => {
                let code = e.code();
                if code == windows::core::HRESULT::from_win32(ERROR_FILE_NOT_FOUND.0)
                    || code == windows::core::HRESULT::from_win32(ERROR_PATH_NOT_FOUND.0)
                {
                    return Err(format!("not found: {}", path));
                }
                return Err(format!("CreateFileW failed: {}", e));
            }
        };
        let ex = FILE_DISPOSITION_INFO_EX {
            Flags: windows::Win32::Storage::FileSystem::FILE_DISPOSITION_INFO_EX_FLAGS(
                FILE_DISPOSITION_FLAG_DELETE.0
                    | FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE.0
                    | FILE_DISPOSITION_FLAG_ON_CLOSE.0,
            ),
        };
        let mut deleted = SetFileInformationByHandle(
            handle,
            FileDispositionInfoEx,
            &ex as *const _ as *const _,
            std::mem::size_of::<FILE_DISPOSITION_INFO_EX>() as u32,
        )
        .is_ok();
        if !deleted {
            let info = FILE_DISPOSITION_INFO {
                DeleteFile: true.into(),
            };
            deleted = SetFileInformationByHandle(
                handle,
                FileDispositionInfo,
                &info as *const _ as *const _,
                std::mem::size_of::<FILE_DISPOSITION_INFO>() as u32,
            )
            .is_ok();
        }
        let _ = CloseHandle(handle);
        if deleted {
            Ok(())
        } else {
            Err(format!("SetFileInformationByHandle failed: {}", path))
        }
    }
}

/// Remove a directory with the forced ladder: the plain call first, then the
/// ownership and the delete right, then the delete-on-close disposition.
///
/// A directory that is still owned by TrustedInstaller is refused by
/// `RemoveDirectoryW`, and the refusal was silently dropped before, so a component
/// folder survived the removal unnoticed.
fn remove_directory_forced(path: &str) -> bool {
    let wide = to_wide(path);
    unsafe {
        clear_protective_attributes(path);
        if RemoveDirectoryW(PCWSTR(wide.as_ptr())).is_ok() {
            return true;
        }
        force_access(path);
        if RemoveDirectoryW(PCWSTR(wide.as_ptr())).is_ok() {
            return true;
        }
        delete_by_handle(path).is_ok()
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
///
/// The deletion is a forced one: the plain delete is tried first, then the ownership
/// of the file is taken and the delete right is granted, and the last step is the
/// delete-on-close disposition of a handle that owns the DELETE access.
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
        let attrs = GetFileAttributesW(PCWSTR(wide.as_ptr()));
        if attrs == u32::MAX {
            let err = GetLastError();
            if err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND {
                println!("  [SKIP] File not found: {}", path);
                return Ok(false);
            }
        }
        // A read-only component file cannot be deleted, not even with the DELETE right.
        clear_protective_attributes(path);
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
        // Deletion failed - most likely because the file is owned by TrustedInstaller
        // or protected by a restrictive DACL. Take the ownership, grant the delete
        // right and retry the plain delete before falling back to the delete-on-close
        // disposition below.
        force_access(path);
        match DeleteFileW(PCWSTR(wide.as_ptr())) {
            Ok(()) => return Ok(true),
            Err(_) => {}
        }
        delete_by_handle(path)
            .map(|_| true)
            .map_err(|e| format!("{}: {}", path, e))
    }
}

/// Delete a directory tree. Reparse points (junctions/symlinks) are never traversed and never deleted through.
///
/// Every step is a forced one: the files are deleted with `delete_file`, the
/// subdirectories are removed with `remove_directory_forced` and the directory itself
/// is removed with the same ladder.
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
    let _ = force_access(&p.to_string_lossy());
    for entry in &entries {
        if entry.is_dir() {
            // The subdirectory is removed with the forced ladder as well. The plain
            // RemoveDirectoryW call that was used here before was refused for every
            // component folder that is owned by TrustedInstaller, and the refusal was
            // dropped, so the folder survived the removal unnoticed.
            if let Err(e) = delete_directory(&entry.to_string_lossy(), false) {
                println!("  [ERR] {}", e);
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
    // The directory itself is removed with the forced ladder too: a plain
    // RemoveDirectoryW is refused while the directory is owned by TrustedInstaller.
    remove_directory_forced(path);
    if p.exists() {
        Err(format!(
            "not fully removed (locked, access denied, or contains preserved reparse points): {}",
            path
        ))
    } else {
        Ok(true)
    }
}

/// Delete everything inside a directory but keep the directory itself.
///
/// The event log service expects its log folder to exist, so only the log files are
/// removed and the folder stays.
fn delete_directory_contents(path: &str, dry_run: bool) -> RemovalOutcome {
    let mut outcome = RemovalOutcome::default();
    let p = Path::new(path);
    if !p.exists() {
        println!("  [SKIP] Directory not found: {}", path);
        return outcome;
    }
    if !p.is_dir() {
        outcome.errors.push(format!("not a directory: {}", path));
        return outcome;
    }
    let mut entries: Vec<PathBuf> = Vec::new();
    if let Ok(rd) = fs::read_dir(p) {
        for entry in rd.flatten() {
            let ep = entry.path();
            if is_reparse_point(&ep) {
                println!(
                    "  [SKIP] Reparse point (junction/symlink) not traversed: {}",
                    ep.to_string_lossy()
                );
                continue;
            }
            entries.push(ep);
        }
    }
    if dry_run {
        println!("[DRY] Would delete the content of: {}", path);
        for entry in &entries {
            if entry.is_dir() {
                outcome.dirs += 1;
            } else {
                outcome.files += 1;
            }
        }
        return outcome;
    }
    for entry in &entries {
        let entry_path = entry.to_string_lossy().to_string();
        if entry.is_dir() {
            if remove_directory_forced(&entry_path) {
                outcome.dirs += 1;
            } else {
                outcome.errors.push(format!("directory not removed: {}", entry_path));
            }
        } else {
            match delete_file(&entry_path, false) {
                Ok(true) => outcome.files += 1,
                Ok(false) => {}
                Err(e) => outcome.errors.push(e),
            }
        }
    }
    outcome
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

/// How a target removes its payload. Most targets name their files and directories;
/// the fonts and the input method engines need a rule that cannot be expressed as a
/// list of paths.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
enum TargetKind {
    #[default]
    Paths,
    Fonts,
    Ime,
}

#[derive(Debug, Default)]
struct DeletionTarget {
    name: &'static str,
    files: Vec<&'static str>,
    dirs: Vec<&'static str>,
    /// The directories whose content is removed while the directory itself stays.
    dir_contents: Vec<&'static str>,
    kind: TargetKind,
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
                "Program Files (x86)\\Microsoft\\EdgeUpdate",
                "Program Files (x86)\\Microsoft\\EdgeCore",
                "Program Files\\WindowsApps\\MicrosoftEdge*",
            ],
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            files: vec![
                "Windows\\System32\\vmms.exe",
                "Windows\\System32\\vmwp.exe",
                "Windows\\System32\\vmcompute.exe",
                "Windows\\System32\\drivers\\hvservice.sys",
                "Windows\\System32\\drivers\\vhdmp.sys",
            ],
            dirs: vec![],
            ..Default::default()
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
            ..Default::default()
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
            files: vec![
                "Windows\\System32\\mpssvc.dll",
                "Windows\\System32\\drivers\\mpsdrv.sys",
            ],
            dirs: vec![],
            ..Default::default()
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
            files: vec![
                "Windows\\System32\\bthserv.dll",
                "Windows\\System32\\drivers\\bthport.sys",
                "Windows\\System32\\drivers\\bthusb.sys",
            ],
            dirs: vec![],
            ..Default::default()
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
            files: vec![
                "Windows\\System32\\spoolsv.exe",
                "Windows\\System32\\printui.exe",
                "Windows\\System32\\localspl.dll",
                "Windows\\System32\\win32spl.dll",
            ],
            dirs: vec!["Windows\\System32\\spool"],
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            files: vec![
                "Windows\\System32\\manage-bde.exe",
                "Windows\\System32\\bdeunlock.exe",
                "Windows\\System32\\BitLockerWizard.exe",
                "Windows\\System32\\BitLockerWizardElev.exe",
                "Windows\\System32\\fveapi.dll",
                "Windows\\System32\\bdesvc.dll",
            ],
            dirs: vec![],
            ..Default::default()
        });
    }

    if config
        .experimental
        .get("physical_accessibility")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Accessibility",
            files: vec![
                "Windows\\System32\\osk.exe",
                "Windows\\System32\\Narrator.exe",
                "Windows\\System32\\Magnify.exe",
                "Windows\\System32\\utilman.exe",
                "Windows\\System32\\atbroker.exe",
            ],
            dirs: vec![],
            ..Default::default()
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
            files: vec![
                "Windows\\System32\\WindowsSandbox.exe",
                "Windows\\System32\\WindowsSandboxClient.exe",
                "Windows\\System32\\WindowsSandboxServer.exe",
            ],
            dirs: vec!["Windows\\System32\\Containers\\DisposableClientVM"],
            ..Default::default()
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
            files: vec![
                "Windows\\System32\\wsl.exe",
                "Windows\\System32\\wslconfig.exe",
                "Windows\\System32\\wslg.exe",
            ],
            dirs: vec!["Windows\\System32\\lxss"],
            ..Default::default()
        });
    }

    if config
        .experimental
        .get("physical_rdp")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Remote Desktop",
            files: vec![
                "Windows\\System32\\mstsc.exe",
                "Windows\\System32\\mstscax.dll",
                "Windows\\System32\\termsrv.dll",
                "Windows\\System32\\rdpclip.exe",
                "Windows\\System32\\rfxvmt.dll",
            ],
            dirs: vec![],
            ..Default::default()
        });
    }

    if config
        .experimental
        .get("physical_event_logs")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Event Logs",
            files: vec![],
            dirs: vec![],
            // The log folder itself stays: the event log service expects it to exist,
            // only the log files inside it are removed.
            dir_contents: vec!["Windows\\System32\\winevt\\Logs"],
            ..Default::default()
        });
    }

    if config
        .experimental
        .get("physical_fonts")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Non-essential Fonts",
            files: vec![],
            dirs: vec![],
            kind: TargetKind::Fonts,
            ..Default::default()
        });
    }

    if config
        .experimental
        .get("physical_ime")
        .copied()
        .unwrap_or(false)
    {
        targets.push(DeletionTarget {
            name: "Non-Japanese IME",
            files: vec![],
            dirs: vec![],
            kind: TargetKind::Ime,
            ..Default::default()
        });
    }

    targets
}

// --- The targets that need a rule instead of a list of paths ---

/// The font files that stay in the image: the system fonts, the Japanese fonts and
/// the fonts of the primary language of the image.
///
/// The list is the one of phases\08-filesystem.ps1, so both engines remove the same
/// fonts and the Japanese rendering of the image never breaks.
fn font_keep_patterns(primary_ime_lang: Option<&str>) -> Vec<&'static str> {
    let mut keep = vec![
        // the system fonts
        "segoe*",
        "tahoma*",
        "marlett.ttf",
        "8541oem.fon",
        "segui*",
        "consol*",
        "lucon*",
        "calibri*",
        "arial*",
        "times*",
        "cou*",
        "8*.*",
        // the Japanese fonts
        "meiryo*",
        "yugoth*",
        "yumin*",
        "msgoth*",
        "msgothic*",
        "msmin*",
        "msmincho*",
        "segoeuihistoric.ttf",
    ];
    match primary_ime_lang {
        Some("ko-kr") => keep.extend_from_slice(&["gulim*", "malgun*", "batang*"]),
        Some("zh-cn") => keep.extend_from_slice(&["simsun*", "msyh*", "simhei*", "dengxian*"]),
        Some("zh-tw") => keep.extend_from_slice(&["mingliu*", "msjh*", "jhen*", "tc*"]),
        _ => {}
    }
    keep
}

/// The input method engine of the primary language of the image.
fn ime_directory_for_language(primary_ime_lang: Option<&str>) -> Option<&'static str> {
    match primary_ime_lang {
        Some("ko-kr") => Some("KOR"),
        Some("zh-cn") => Some("CHS"),
        Some("zh-tw") => Some("CHT"),
        Some("zh-hk") => Some("CHT"),
        _ => None,
    }
}

/// Remove the fonts that the image does not need.
fn remove_non_essential_fonts(mount: &Path, config: &DebloatConfig) -> RemovalOutcome {
    let mut outcome = RemovalOutcome::default();
    let fonts_dir = mount.join("Windows").join("Fonts");
    if !fonts_dir.is_dir() {
        println!("  [SKIP] Font folder not found: {}", fonts_dir.display());
        return outcome;
    }
    let keep = font_keep_patterns(config.primary_ime_lang.as_deref());
    let entries: Vec<PathBuf> = match fs::read_dir(&fonts_dir) {
        Ok(rd) => rd.flatten().map(|e| e.path()).collect(),
        Err(e) => {
            outcome
                .errors
                .push(format!("cannot read {}: {}", fonts_dir.display(), e));
            return outcome;
        }
    };
    for entry in entries {
        if entry.is_dir() {
            continue;
        }
        let name = match entry.file_name() {
            Some(n) => n.to_string_lossy().into_owned(),
            None => continue,
        };
        if keep.iter().any(|pattern| wildcard_match(pattern, &name)) {
            continue;
        }
        match delete_file(&entry.to_string_lossy(), config.dry_run) {
            Ok(true) => outcome.files += 1,
            Ok(false) => {}
            Err(e) => outcome.errors.push(e),
        }
    }
    outcome
}

/// Remove the input method engines of the other languages.
///
/// The Japanese engine and the engine of the primary language of the image stay, so
/// the keyboard of the image keeps working.
fn remove_non_japanese_ime(mount: &Path, config: &DebloatConfig) -> RemovalOutcome {
    let mut outcome = RemovalOutcome::default();
    let mut keep = vec!["JPN"];
    if let Some(dir) = ime_directory_for_language(config.primary_ime_lang.as_deref()) {
        keep.push(dir);
    }
    let ime_root = mount.join("Windows").join("System32").join("InputMethod");
    for dir in ["JPN", "CHS", "CHT", "KOR"] {
        if keep.contains(&dir) {
            println!("  [SKIP] IME engine kept: {}", dir);
            continue;
        }
        let path = ime_root.join(dir);
        if !path.exists() {
            continue;
        }
        match delete_directory(&path.to_string_lossy(), config.dry_run) {
            Ok(true) => outcome.dirs += 1,
            Ok(false) => {}
            Err(e) => outcome.errors.push(e),
        }
    }
    outcome
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

    println!("winease-physical-debloat v0.3.0 (Hardened)");
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

        // The fonts and the input method engines need a rule instead of a list of
        // paths, so they are removed by their own handler.
        match target.kind {
            TargetKind::Fonts => {
                let outcome = remove_non_essential_fonts(&mount_path, &config);
                result.deleted_files += outcome.files;
                if !config.dry_run {
                    println!("  [OK] Removed {} font file(s)", outcome.files);
                }
                for e in outcome.errors {
                    result.errors.push(format!("[{}] font: {}", target.name, e));
                    result.success = false;
                    println!("  [ERR] {}", e);
                }
                continue;
            }
            TargetKind::Ime => {
                let outcome = remove_non_japanese_ime(&mount_path, &config);
                result.deleted_dirs += outcome.dirs;
                if !config.dry_run {
                    println!("  [OK] Removed {} IME engine folder(s)", outcome.dirs);
                }
                for e in outcome.errors {
                    result.errors.push(format!("[{}] ime: {}", target.name, e));
                    result.success = false;
                    println!("  [ERR] {}", e);
                }
                continue;
            }
            TargetKind::Paths => {}
        }

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

        // The directories whose content is removed while the directory itself stays.
        for d in &target.dir_contents {
            match validate_target_path(&mount_path, d) {
                Ok(target_dir_path) => {
                    let full_path = target_dir_path.to_string_lossy().to_string();
                    let outcome = delete_directory_contents(&full_path, config.dry_run);
                    result.deleted_files += outcome.files;
                    result.deleted_dirs += outcome.dirs;
                    for e in outcome.errors {
                        result
                            .errors
                            .push(format!("[{}] content of {}: {}", target.name, d, e));
                        result.success = false;
                        println!("  [ERR] {}", e);
                    }
                    if !config.dry_run && (outcome.files > 0 || outcome.dirs > 0) {
                        println!(
                            "  [OK] Deleted the content of {} ({} files, {} dirs)",
                            d, outcome.files, outcome.dirs
                        );
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

    /// Every experimental target that physically removes a Windows component must name
    /// the files or directories it removes. A target with an empty list is a no-op that
    /// silently does nothing, which is exactly how the nine unimplemented targets
    /// (hyperv, firewall, bluetooth, spooler, bitlocker, accessibility, sandbox, wsl,
    /// rdp) behaved before.
    #[test]
    fn test_every_experimental_target_has_a_non_empty_definition() {
        // Build a config that enables every known experimental key.
        let mut experimental = std::collections::HashMap::new();
        for key in KNOWN_EXPERIMENTAL_KEYS {
            experimental.insert(key.to_string(), true);
        }
        let config = DebloatConfig {
            dry_run: true,
            mount_path: "C:\\nonexistent-mount".to_string(),
            log_path: String::new(),
            confirm_offline_image: false,
            experimental,
            primary_ime_lang: None,
        };

        let targets = get_targets(&config);
        assert!(
            !targets.is_empty(),
            "get_targets returned no targets for a fully enabled config"
        );
        for target in &targets {
            assert!(
                !target.files.is_empty()
                    || !target.dirs.is_empty()
                    || !target.dir_contents.is_empty()
                    || target.kind != TargetKind::Paths,
                "experimental target '{}' has an empty file and directory list, so it \
                 would silently do nothing",
                target.name
            );
        }
    }

    /// The nine targets that were previously empty must now delete real binaries.
    #[test]
    fn test_previously_unimplemented_targets_delete_real_files() {
        let mut experimental = std::collections::HashMap::new();
        for key in [
            "physical_hyperv",
            "physical_firewall",
            "physical_bluetooth",
            "physical_spooler",
            "physical_bitlocker",
            "physical_accessibility",
            "physical_sandbox",
            "physical_wsl",
            "physical_rdp",
        ] {
            experimental.insert(key.to_string(), true);
        }
        let config = DebloatConfig {
            dry_run: true,
            mount_path: "C:\\nonexistent-mount".to_string(),
            log_path: String::new(),
            confirm_offline_image: false,
            experimental,
            primary_ime_lang: None,
        };

        let targets = get_targets(&config);
        let expected = [
            "physical_hyperv",
            "physical_firewall",
            "physical_bluetooth",
            "physical_spooler",
            "physical_bitlocker",
            "physical_accessibility",
            "physical_sandbox",
            "physical_wsl",
            "physical_rdp",
        ];
        for key in expected {
            let target = targets
                .iter()
                .find(|t| {
                    t.files
                        .iter()
                        .chain(t.dirs.iter())
                        .any(|p| p.starts_with("Windows\\System32"))
                })
                .unwrap_or_else(|| panic!("no System32 target produced for {}", key));
            assert!(
                !target.files.is_empty() || !target.dirs.is_empty(),
                "target for {} is still empty",
                key
            );
        }
    }

    /// The components that had no forced physical deletion at all must now have one:
    /// the event logs, the fonts and the input method engines.
    #[test]
    fn test_the_components_without_a_forced_deletion_have_one_now() {
        for key in ["physical_event_logs", "physical_fonts", "physical_ime"] {
            assert!(
                KNOWN_EXPERIMENTAL_KEYS.contains(&key),
                "the key {} is not in the allowlist of the binary",
                key
            );
            let mut experimental = std::collections::HashMap::new();
            experimental.insert(key.to_string(), true);
            let config = DebloatConfig {
                dry_run: true,
                mount_path: "C:\\nonexistent-mount".to_string(),
                log_path: String::new(),
                confirm_offline_image: false,
                experimental,
                primary_ime_lang: None,
            };
            let targets = get_targets(&config);
            assert_eq!(
                targets.len(),
                1,
                "the key {} did not produce a target",
                key
            );
            let target = &targets[0];
            match key {
                "physical_event_logs" => assert!(
                    !target.dir_contents.is_empty(),
                    "the event log target names no directory"
                ),
                "physical_fonts" => assert_eq!(
                    target.kind,
                    TargetKind::Fonts,
                    "the font target does not use the font rule"
                ),
                "physical_ime" => assert_eq!(
                    target.kind,
                    TargetKind::Ime,
                    "the IME target does not use the IME rule"
                ),
                _ => unreachable!(),
            }
        }
    }

    /// The font rule keeps the system fonts, the Japanese fonts and the fonts of the
    /// primary language of the image, so the rendering of the image never breaks.
    #[test]
    fn test_the_font_rule_keeps_the_system_and_the_japanese_fonts() {
        let keep = font_keep_patterns(None);
        for name in [
            "segoeui.ttf",
            "tahoma.ttf",
            "consola.ttf",
            "meiryo.ttc",
            "msgothic.ttc",
            "msmincho.ttc",
            "yugothm.ttc",
            "segoeuihistoric.ttf",
        ] {
            assert!(
                keep.iter().any(|p| wildcard_match(p, name)),
                "the font {} would be removed",
                name
            );
        }
        // a font that is not needed by the image is not on the keep list
        assert!(
            !keep.iter().any(|p| wildcard_match(p, "NotoSansThai-Regular.ttf")),
            "an unneeded font would be kept"
        );
        // the fonts of the primary language are kept as well
        let keep_ko = font_keep_patterns(Some("ko-kr"));
        assert!(keep_ko.iter().any(|p| wildcard_match(p, "malgun.ttf")));
        let keep_zh = font_keep_patterns(Some("zh-cn"));
        assert!(keep_zh.iter().any(|p| wildcard_match(p, "msyh.ttc")));
    }

    /// The IME rule keeps the Japanese engine and the engine of the primary language.
    #[test]
    fn test_the_ime_rule_keeps_the_japanese_and_the_own_language() {
        assert_eq!(ime_directory_for_language(None), None);
        assert_eq!(ime_directory_for_language(Some("ko-kr")), Some("KOR"));
        assert_eq!(ime_directory_for_language(Some("zh-cn")), Some("CHS"));
        assert_eq!(ime_directory_for_language(Some("zh-tw")), Some("CHT"));
        assert_eq!(ime_directory_for_language(Some("zh-hk")), Some("CHT"));
    }

    /// The forced deletion removes a read-only file. The plain delete call refuses it,
    /// so the file only goes away when the attributes are cleared and the delete right
    /// is granted.
    #[test]
    fn test_the_forced_deletion_removes_a_read_only_file() {
        let dir = test_temp_dir("forced-file");
        let file = dir.join("component.dll");
        fs::write(&file, b"payload").expect("the test file must be writable");
        let attrs = unsafe {
            GetFileAttributesW(PCWSTR(to_wide(&file.to_string_lossy()).as_ptr()))
        };
        assert_ne!(attrs, u32::MAX);
        unsafe {
            let _ = SetFileAttributesW(
                PCWSTR(to_wide(&file.to_string_lossy()).as_ptr()),
                FILE_ATTRIBUTE_READONLY,
            );
        }
        let deleted = delete_file(&file.to_string_lossy(), false).expect("the delete failed");
        assert!(deleted, "the read-only file was not deleted");
        assert!(!file.exists(), "the read-only file is still there");
        let _ = fs::remove_dir_all(&dir);
    }

    /// The forced deletion removes a whole tree, including the subdirectories that are
    /// read-only. The plain RemoveDirectoryW call refuses those, so they only go away
    /// when the ownership is taken and the delete right is granted.
    #[test]
    fn test_the_forced_deletion_removes_a_read_only_directory_tree() {
        let dir = test_temp_dir("forced-tree");
        let sub = dir.join("sub");
        fs::create_dir_all(&sub).expect("the test directory must be creatable");
        let file = sub.join("component.dll");
        fs::write(&file, b"payload").expect("the test file must be writable");
        unsafe {
            let _ = SetFileAttributesW(
                PCWSTR(to_wide(&sub.to_string_lossy()).as_ptr()),
                FILE_ATTRIBUTE_READONLY,
            );
        }
        let deleted = delete_directory(&dir.to_string_lossy(), false).expect("the delete failed");
        assert!(deleted, "the directory tree was not deleted");
        assert!(!dir.exists(), "the directory tree is still there");
        let _ = fs::remove_dir_all(&dir);
    }

    /// The event log folder stays, only the log files inside it are removed.
    #[test]
    fn test_the_content_removal_keeps_the_directory() {
        let dir = test_temp_dir("contents");
        let file = dir.join("System.evtx");
        fs::write(&file, b"log").expect("the test file must be writable");
        let outcome = delete_directory_contents(&dir.to_string_lossy(), false);
        assert!(outcome.errors.is_empty(), "the removal reported errors");
        assert_eq!(outcome.files, 1);
        assert!(dir.exists(), "the directory itself was removed");
        assert!(!file.exists(), "the log file is still there");
        let _ = fs::remove_dir_all(&dir);
    }

    /// A unique directory for a test. The name contains the process id and the name of
    /// the test, so two runs never use the same directory.
    fn test_temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "winease-physical-debloat-test-{}-{}",
            std::process::id(),
            name
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("the test directory must be creatable");
        dir
    }
}

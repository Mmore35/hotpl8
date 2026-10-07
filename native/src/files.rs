//! src/common.ps1 and src/diagnostics.ps1, the file half: state written whole or not at
//! all, a lock held while a decision depends on what it guards, and the event log.

use crate::json;
use crate::ps::*;
use crate::sha256;
use crate::time::Dto;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

/// [guid]::NewGuid().ToString('N'): a name nothing else has, not a secret.
pub fn guid() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut bytes = [0u8; 16];
    for half in bytes.chunks_mut(8) {
        // Every RandomState is keyed apart from the last, from the system's randomness.
        let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
        hasher.write_u32(std::process::id());
        half.copy_from_slice(&hasher.finish().to_le_bytes());
    }
    bytes[6] = bytes[6] & 0x0f | 0x40;
    bytes[8] = bytes[8] & 0x3f | 0x80;
    sha256::hex(&bytes, false)
}

fn beside(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

/// Move-Hotpl8AtomicFile. Windows replaces a file in place, which keeps the file's own
/// attributes and permissions and names both files as surviving when it fails.
#[cfg(windows)]
fn replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    extern "system" {
        fn ReplaceFileW(replaced: *const u16, replacement: *const u16, backup: *const u16, flags: u32, exclude: *mut core::ffi::c_void, reserved: *mut core::ffi::c_void) -> i32;
    }
    if !destination.is_file() {
        return std::fs::rename(source, destination);
    }
    let wide = |path: &Path| path.as_os_str().encode_wide().chain([0]).collect::<Vec<u16>>();
    let (replaced, replacement) = (wide(destination), wide(source));
    // SAFETY: both names are live, NUL-terminated UTF-16; the optional pointers are null.
    let done = unsafe { ReplaceFileW(replaced.as_ptr(), replacement.as_ptr(), core::ptr::null(), 0, core::ptr::null_mut(), core::ptr::null_mut()) };
    if done == 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}
#[cfg(not(windows))]
fn replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    std::fs::rename(source, destination)
}

/// Write-Hotpl8Text: readers see the old text or the new, never part of either.
#[track_caller]
pub fn write_text(path: &Path, text: &str, mark: bool) -> R<()> {
    let temp = beside(path, &format!(".{}.tmp", guid()));
    let mut bytes = Vec::with_capacity(text.len() + 3);
    if mark {
        bytes.extend_from_slice(&[0xef, 0xbb, 0xbf]);
    }
    bytes.extend_from_slice(text.as_bytes());
    if let Err(error) = std::fs::write(&temp, &bytes) {
        let _ = std::fs::remove_file(&temp);
        return Stop::io(&error, path);
    }
    let mut attempt = 0;
    loop {
        let Err(error) = replace(&temp, path) else { return Ok(()) };
        let code = error.raw_os_error().unwrap_or(0) & 0xffff;
        // A viewer may hold the file without letting it be replaced. The replacement
        // reports 1175 when only its delete phase was blocked; in each of these cases both
        // files survive, so the write is tried again for at most a second. 1176 and 1177
        // can leave the replacement half done: its staging file is then the only copy.
        if cfg!(windows) && [32, 33, 1175].contains(&code) && attempt < 40 {
            attempt += 1;
            std::thread::sleep(std::time::Duration::from_millis(25));
            continue;
        }
        if ![1176, 1177].contains(&code) {
            let _ = std::fs::remove_file(&temp);
        }
        return Stop::io(&error, path);
    }
}

/// Write-Hotpl8Text $path ($value | ConvertTo-Json -Depth $depth): a state file.
#[track_caller]
pub fn write_json(path: &Path, value: &V, depth: usize) -> R<()> {
    write_text(path, &json::write(value, depth)?, true)
}

/// A file opened so that no one else can open it while this is held.
pub struct Lock {
    _file: File,
}

/// Why a lock was not taken: someone holds it, or the system refused for another reason.
pub enum Unlocked {
    Busy,
    Refused,
}

/// [IO.File]::Open($path,'OpenOrCreate','ReadWrite','None')
pub fn lock(path: &Path) -> Result<Lock, Unlocked> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(0);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if cfg!(windows) && matches!(error.raw_os_error(), Some(32 | 33)) => return Err(Unlocked::Busy),
        Err(_) => return Err(Unlocked::Refused),
    };
    // Off Windows .NET holds an advisory lock on the open file; so does this.
    #[cfg(not(windows))]
    match file.try_lock() {
        Ok(()) => {}
        Err(std::fs::TryLockError::WouldBlock) => return Err(Unlocked::Busy),
        Err(std::fs::TryLockError::Error(_)) => return Err(Unlocked::Refused),
    }
    Ok(Lock { _file: file })
}

/// The state files an event may name. Nothing else about a failure is written down: not
/// its text, not a path, not what a native program printed.
const NAMED: [&str; 11] = [
    "status.json",
    "status.js",
    "status.txt",
    "collector.json",
    "warm-outcomes.json",
    "warm-state.json",
    "usage-history.json",
    "activity.json",
    "codex-state.json",
    "critical-claude.json",
    "policy.json",
];

/// Write-Hotpl8Event: one line in events.jsonl, which never grows past two files.
pub fn event(directory: &Path, code: &str, failure: Option<&Stop>) {
    let path = directory.join("events.jsonl");
    let written = || -> R<()> {
        if std::fs::metadata(&path).is_ok_and(|file| file.len() > 262_144) {
            let _ = std::fs::copy(&path, beside(&path, ".1"));
            let _ = std::fs::write(&path, "");
        }
        let mut record = vec![("at", V::from(Dto::now()?.o())), ("code", V::from(code))];
        if let Some(stop) = failure {
            record.push(("failureCode", V::from(stop.failure_code())));
            if let Some((file, system)) = stop.state_file() {
                if NAMED.contains(&file) {
                    record.push(("stateFile", V::from(file)));
                    record.push(("ioCode", V::I32(system)));
                }
            }
            if let Some((source, line)) = stop.place() {
                record.push(("source", V::from(source)));
                record.push(("line", V::I32(line as i32)));
            }
        }
        let mut row = json::line(&record)?;
        row.push('\n');
        let Ok(mut file) = OpenOptions::new().append(true).create(true).open(&path) else { return Ok(()) };
        let _ = file.write_all(row.as_bytes());
        Ok(())
    };
    let _ = written();
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// A new directory of this test's own under the system's temporary one.
    pub fn scratch(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("hotpl8-native-{name}-{}", guid()));
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    /// One part of tests/parity/shared-rules.json. It holds what PowerShell's side of a
    /// rule answers for each case, tests/test-shared-rules.ps1 holds PowerShell to it, and
    /// the test beside the rule here holds this side to it.
    pub fn shared_rules(part: &str) -> V {
        let rules = crate::json::parse(include_str!("../../tests/parity/shared-rules.json"), "shared-rules.json").ok().unwrap();
        rules.g(part).ok().unwrap()
    }

    #[test]
    fn names_are_new_each_time() {
        let (first, second) = (guid(), guid());
        assert_eq!(first.len(), 32);
        assert!(first.bytes().all(|b| b.is_ascii_hexdigit()) && first.as_bytes()[12] == b'4');
        assert_ne!(first, second);
    }

    #[test]
    fn text_is_replaced_whole() {
        let directory = scratch("write");
        let path = directory.join("status.json");
        write_text(&path, "one", true).ok().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"\xef\xbb\xbfone");
        write_text(&path, "two", false).ok().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"two");
        write_json(&path, &crate::obj! {"a" => V::I32(1)}, 4).ok().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"\xef\xbb\xbf{\n  \"a\": 1\n}");
        assert_eq!(std::fs::read_dir(&directory).unwrap().count(), 1);
        let missing = directory.join("none").join("status.json");
        let stop = write_text(&missing, "x", true).err().unwrap();
        assert!(stop.thrown());
        assert_eq!(stop.failure_code(), "state_io_failed");
        assert_eq!(stop.state_file().map(|(name, _)| name), Some("status.json"));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn a_held_lock_is_busy() {
        let directory = scratch("lock");
        let path = directory.join("tick.lock");
        let held = lock(&path).ok().unwrap();
        assert!(matches!(lock(&path), Err(Unlocked::Busy)));
        drop(held);
        assert!(lock(&path).is_ok());
        assert!(matches!(lock(&directory.join("none").join("x.lock")), Err(Unlocked::Refused)));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn events_are_lines_and_rotate() {
        let directory = scratch("events");
        event(&directory, "collector_failed", None);
        let stop = write_text(&directory.join("none").join("status.json"), "x", true).err().unwrap();
        event(&directory, "claude_collection_failed", Some(&stop));
        let stop = fail::<()>("claude_missing").err().unwrap();
        event(&directory, "claude_claude_missing", Some(&stop));
        let text = std::fs::read_to_string(directory.join("events.jsonl")).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].starts_with("{\"at\":\"2") && lines[0].ends_with("\",\"code\":\"collector_failed\"}"));
        assert!(lines[1].contains("\"failureCode\":\"state_io_failed\",\"stateFile\":\"status.json\",\"ioCode\":"));
        assert!(lines[1].contains("\"source\":\"files.rs\",\"line\":"));
        assert!(lines[2].contains("\"failureCode\":\"unexpected_collection_error\",\"source\":\"files.rs\""));
        std::fs::write(directory.join("events.jsonl"), "x".repeat(262_145)).unwrap();
        event(&directory, "collector_failed", None);
        assert!(std::fs::metadata(directory.join("events.jsonl")).unwrap().len() < 1000);
        assert_eq!(std::fs::metadata(directory.join("events.jsonl.1")).unwrap().len(), 262_145);
        std::fs::remove_dir_all(&directory).unwrap();
    }
}

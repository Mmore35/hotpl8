//! The part of HotPl8 that touches cswap, the program that holds the
//! Claude accounts: where it is, how long it may take, and the one request HotPl8 ever
//! sends through it. HotPl8 never presents a credential itself. It asks cswap to run, and
//! cswap renews under its own per-account lock, taking up a newer credential where one
//! exists: replaying a superseded one is how a whole family of them is revoked.

use crate::json;
use crate::process;
use crate::ps::*;
use crate::sha256;
use crate::time::Dto;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Get-CswapReadTimeoutMs. Reading the accounts renews a sign-in that has expired, and a
/// renewed sign-in replaces a single-use token: cswap stopped halfway has spent the old
/// token without storing the new one, and the account needs a person to sign in again.
/// Its longest road through one renewal is 85 seconds, so it is given 90.
pub const READ_TIMEOUT_MS: u64 = 90_000;

/// Get-Hotpl8UserHome: where cswap keeps its accounts.
pub fn user_home() -> R<PathBuf> {
    for name in ["USERPROFILE", "HOME"] {
        if let Some(home) = std::env::var_os(name).filter(|home| !home.is_empty()) {
            return Ok(PathBuf::from(home));
        }
    }
    fail("Neither USERPROFILE nor HOME is set.")
}

/// Where a cswap may be: what this machine's environment says, or what a test names.
pub struct Places {
    /// HOTPL8_NATIVE_BIN, the directory of the programs HotPl8 installed.
    pub owned: Option<PathBuf>,
    pub home: Option<PathBuf>,
    /// The one place every user of the machine shares.
    pub shared: PathBuf,
    pub path: Option<OsString>,
    pub extensions: Option<String>,
    /// LOCALAPPDATA and APPDATA, under which Windows keeps a person's Pythons.
    pub local: Option<PathBuf>,
    pub roaming: Option<PathBuf>,
}

impl Places {
    pub fn here() -> Places {
        let directory = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty()).map(PathBuf::from);
        Places {
            owned: directory("HOTPL8_NATIVE_BIN"),
            home: user_home().ok(),
            shared: PathBuf::from("/usr/local/bin/cswap"),
            path: std::env::var_os("PATH"),
            extensions: std::env::var("PATHEXT").ok(),
            local: directory("LOCALAPPDATA"),
            roaming: directory("APPDATA"),
        }
    }
}

/// `(Get-Command cswap).Source`: the first cswap a directory of PATH holds.
fn on_path(places: &Places) -> Option<PathBuf> {
    let path = places.path.as_ref()?;
    let extensions: Vec<String> = if cfg!(windows) {
        let known = places.extensions.clone().unwrap_or_else(|| ".COM;.EXE;.BAT;.CMD".into());
        // The collector starts programs, and a batch shim only with the words it knows.
        known.split(';').map(str::to_ascii_lowercase).filter(|e| [".com", ".exe", ".bat", ".cmd"].contains(&e.as_str())).collect()
    } else {
        vec![String::new()]
    };
    for directory in std::env::split_paths(path).filter(|directory| directory.is_absolute()) {
        for extension in &extensions {
            let candidate = directory.join(format!("cswap{extension}"));
            if runnable(&candidate) {
                return Some(candidate);
            }
        }
    }
    None
}

#[cfg(unix)]
pub(crate) fn runnable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|file| file.is_file() && file.permissions().mode() & 0o111 != 0)
}
#[cfg(not(unix))]
pub(crate) fn runnable(path: &Path) -> bool {
    path.is_file()
}

/// The cswap of the newest-named Python under `base`: `Python*\Scripts\cswap.exe`.
fn beside_python(base: PathBuf) -> Option<PathBuf> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(base)
        .ok()?
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().to_ascii_lowercase().starts_with("python"))
        .map(|entry| entry.path().join("Scripts").join("cswap.exe"))
        .filter(|candidate| candidate.is_file())
        .collect();
    found.sort_by_key(|candidate| candidate.to_string_lossy().to_ascii_lowercase());
    found.pop()
}

/// Resolve-CswapExecutable: the one named, then the one HotPl8 installed, then the ones a
/// person installs. On Windows `pip install --user` puts cswap in a Scripts directory that
/// is not on PATH, so the usual places are looked in as well.
pub fn resolve_executable(named: Option<&str>) -> Option<String> {
    if let Some(named) = named.filter(|named| !named.is_empty()) {
        return Some(named.to_string());
    }
    found_in(&Places::here()).map(|path| path.to_string_lossy().into_owned())
}

/// The cswap that is used when none is named.
fn found_in(places: &Places) -> Option<PathBuf> {
    if let Some(owned) = &places.owned {
        let owned = owned.join(if cfg!(windows) { "cswap.exe" } else { "cswap" });
        if owned.is_file() {
            return Some(owned);
        }
    }
    let usual = [places.home.as_ref().map(|home| home.join(".local").join("bin").join("cswap")), Some(places.shared.clone())];
    if let Some(found) = usual.into_iter().flatten().find(|candidate| candidate.exists()) {
        return Some(found);
    }
    if let Some(found) = on_path(places) {
        return Some(found);
    }
    let local = places.local.as_ref().and_then(|base| beside_python(base.join("Programs").join("Python")));
    local.or_else(|| places.roaming.as_ref().and_then(|base| beside_python(base.join("Python"))))
}

/// The name cswap gives an account's own session directory.
pub fn slug_email(email: &str) -> String {
    email.chars().map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '_' }).collect()
}

/// Where cswap stores the sign-in it will use for this account next.
pub fn stored_credential(home: &Path, slot: i32, email: &str) -> PathBuf {
    home.join(".claude-swap-backup").join("credentials").join(format!(".creds-{slot}-{email}.enc"))
}

/// The copy of the sign-in a request through cswap leaves in the account's own session.
pub fn session_credential(home: &Path, slot: i32, email: &str) -> PathBuf {
    home.join(".claude-swap-backup").join("sessions").join(format!("{slot}-{}", slug_email(email))).join(".credentials.json")
}

/// [Convert]::FromBase64String
fn base64(text: &str) -> Option<Vec<u8>> {
    let symbols: Vec<u8> = text.bytes().filter(|b| !matches!(b, b' ' | b'\t' | b'\r' | b'\n')).collect();
    if symbols.len() % 4 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(symbols.len() / 4 * 3);
    for (index, group) in symbols.chunks(4).enumerate() {
        let last = index + 1 == symbols.len() / 4;
        let padding = group.iter().rev().take_while(|b| **b == b'=').count();
        if padding > 2 || (padding > 0 && !last) {
            return None;
        }
        let mut bits = 0u32;
        for symbol in &group[..4 - padding] {
            let value = match symbol {
                b'A'..=b'Z' => symbol - b'A',
                b'a'..=b'z' => symbol - b'a' + 26,
                b'0'..=b'9' => symbol - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                _ => return None,
            };
            bits = bits << 6 | u32::from(value);
        }
        bits <<= 6 * padding;
        out.extend_from_slice(&bits.to_be_bytes()[1..4 - padding]);
    }
    Some(out)
}

/// Which sign-in a file holds and when it expires, as text that is no
/// secret: the start of a digest of the token, never the token. `-` says there is no such
/// file and `?` that it cannot be read; the difference matters, because a file that is
/// absent after a request has been cleaned up and one that cannot be read has not. A
/// refresh token is used once, so two holders replaying one can get it revoked; the mark
/// lets the log show one sign-in giving way to the next. It does not show which program
/// renewed a token, or why the provider refused one.
pub fn credential_mark(path: &Path, encoded: bool) -> String {
    if !path.exists() {
        return "-".into();
    }
    let read = || -> Option<String> {
        let bytes = std::fs::read(path).ok().filter(|bytes| bytes.len() <= 1_048_576)?;
        let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes).to_vec();
        let bytes = if encoded { base64(String::from_utf8_lossy(&bytes).trim())? } else { bytes };
        let sign_in = json::parse(&String::from_utf8_lossy(&bytes), "").ok()?.g("claudeAiOauth").ok()?;
        if !sign_in.t().ok()? {
            return None;
        }
        let token = sign_in.g("refreshToken").ok()?.s().ok()?;
        if blank(&token).ok()? {
            return None;
        }
        let print = sha256::hex(&sha256::digest(token.as_bytes())[..6], false);
        let expires = sign_in.g("expiresAt").ok()?;
        let until = || -> R<String> {
            if !expires.t()? {
                return throw();
            }
            Ok(Dto::from_unix_milliseconds(expires.to_long()?)?.month_day_hour_minute())
        };
        Some(format!("{print}@{}", until().unwrap_or_else(|_| "?".into())))
    };
    read().unwrap_or_else(|| "?".into())
}

/// A request that worked through a session of the account's own, yet
/// left the stored sign-in exactly as it was. The session renewed its own copy, that copy
/// is deleted afterwards, and the stored one was not replaced: the account will need a
/// person to sign in when it expires. A mark that could not be read proves nothing.
pub fn ping_unrenewed(ok: bool, before: &str, after: &str, cleared: &str) -> bool {
    ok && cleared != "absent" && before.contains('@') && before == after
}

/// What a request through cswap came to.
pub struct Ping {
    pub ok: bool,
    pub unrenewed: bool,
}

fn delete(path: &Path) -> std::io::Result<()> {
    let Err(error) = std::fs::remove_file(path) else { return Ok(()) };
    // Remove-Item -Force also removes a file marked read-only.
    let Ok(file) = std::fs::metadata(path) else { return Err(error) };
    let mut permissions = file.permissions();
    #[allow(clippy::permissions_set_readonly_false)]
    permissions.set_readonly(false);
    std::fs::set_permissions(path, permissions)?;
    std::fs::remove_file(path)
}

/// One smallest request as this account, to open its window or to test a
/// sign-in cswap has stopped testing.
///
/// `cswap run` belongs to the one process it starts and never moves the account every
/// other session uses, so it is safe while a hold is in force. `--strict-mcp-config`
/// keeps the request from starting the user's tool servers. `--require-session` is left
/// out on purpose: for the account already in use cswap takes a road that makes no second
/// copy of the sign-in, and that flag turns the road into a refusal.
///
/// A request that fails must never read as one that worked: only exit status 0 is a
/// request sent. Afterwards the session's copy of the sign-in is deleted whatever the
/// result, because a sign-in is renewed by a single-use token and two stored copies of
/// one token are how an account is locked out. One line of the audit says what the
/// stored sign-in was before and after, in marks that are no secret.
pub fn slot_ping(cswap: &str, home: &Path, slot: i32, email: &str, root: &Path, kind: &str) -> Ping {
    let stored = stored_credential(home, slot, email);
    let session = session_credential(home, slot, email);
    let stored_before = credential_mark(&stored, true);
    let session_before = credential_mark(&session, false);
    let words = ["run", &slot.to_string(), "--", "claude", "--model", "haiku", "--strict-mcp-config", "-p", "."];
    let ok = process::run(cswap, &words, 90_000).is_ok_and(|finished| finished.exit_code == 0);
    let session_after = credential_mark(&session, false);
    let cleared = if !session.exists() {
        "absent"
    } else if delete(&session).is_ok() {
        "cleared"
    } else {
        "CLEAR-FAILED"
    };
    let stored_after = credential_mark(&stored, true);
    let unrenewed = ping_unrenewed(ok, &stored_before, &stored_after, cleared);
    let at = Dto::now().map_or_else(|_| String::new(), Dto::o);
    let said = if ok { "True" } else { "False" };
    let line = format!("{at} slot {slot} kind={kind} ok={said} enc {stored_before} -> {stored_after} prof-before={session_before} prof={cleared} prof-after={session_after}");
    audit(&root.join("cred-audit.log"), &line);
    Ping { ok, unrenewed }
}

/// One more line in cred-audit.log, which never grows past two files. Best effort: the
/// request has been made whether or not it can be written down.
fn audit(path: &Path, line: &str) {
    use std::io::Write;
    if std::fs::metadata(path).is_ok_and(|file| file.len() > 262_144) {
        let mut kept = path.as_os_str().to_owned();
        kept.push(".1");
        let _ = std::fs::copy(path, kept);
        let _ = std::fs::write(path, "");
    }
    let Ok(mut file) = std::fs::OpenOptions::new().append(true).create(true).open(path) else { return };
    let _ = file.write_all(format!("{line}{}", if cfg!(windows) { "\r\n" } else { "\n" }).as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::{scratch, shared_rules};

    /// A sign-in no account has: `{"claudeAiOauth":{"refreshToken":"fictional-refresh-token","expiresAt":1791288000000}}`.
    const SESSION: &str = r#"{"claudeAiOauth":{"refreshToken":"fictional-refresh-token","expiresAt":1791288000000}}"#;
    const STORED: &str = "eyJjbGF1ZGVBaU9hdXRoIjp7InJlZnJlc2hUb2tlbiI6ImZpY3Rpb25hbC1yZWZyZXNoLXRva2VuIiwiZXhwaXJlc0F0IjoxNzkxMjg4MDAwMDAwfX0=";

    #[test]
    fn base64_reads_what_dotnet_reads() {
        assert_eq!(base64("").unwrap(), b"");
        assert_eq!(base64("Zg==").unwrap(), b"f");
        assert_eq!(base64("Zm8=").unwrap(), b"fo");
        assert_eq!(base64("Zm9v").unwrap(), b"foo");
        assert_eq!(base64("Zm9v\r\nYmFy").unwrap(), b"foobar");
        assert_eq!(base64("+/+/").unwrap(), [0xfb, 0xff, 0xbf]);
        for refused in ["Zg", "Zg=", "Z===", "Zg==Zm9v", "Zm9*", "=Zm9"] {
            assert!(base64(refused).is_none(), "{refused}");
        }
        assert_eq!(String::from_utf8(base64(STORED).unwrap()).unwrap(), SESSION);
    }

    #[test]
    fn a_mark_names_a_sign_in_without_holding_it() {
        let directory = scratch("mark");
        let path = directory.join("credential");
        assert_eq!(credential_mark(&path, false), "-");
        std::fs::write(&path, SESSION).unwrap();
        let mark = credential_mark(&path, false);
        assert_eq!(mark, format!("{}@10-06 12:00", &sha256::hash("fictional-refresh-token")[..12]));
        std::fs::write(&path, format!("\u{feff}{STORED}\r\n")).unwrap();
        assert_eq!(credential_mark(&path, true), mark);
        assert_eq!(credential_mark(&path, false), "?");
        for (text, said) in [
            ("{oh no", "?"),
            ("{}", "?"),
            (r#"{"claudeAiOauth":{"refreshToken":" "}}"#, "?"),
            (r#"{"claudeAiOauth":{"refreshToken":"fictional-refresh-token"}}"#, "@?"),
            (r#"{"claudeAiOauth":{"refreshToken":"fictional-refresh-token","expiresAt":"soon"}}"#, "@?"),
        ] {
            std::fs::write(&path, text).unwrap();
            assert!(credential_mark(&path, false).ends_with(said), "{text}");
        }
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn only_a_request_that_left_the_stored_sign_in_alone_is_unrenewed() {
        let before = "aaaaaaaaaaaa@10-05 06:00";
        assert!(ping_unrenewed(true, before, before, "cleared"));
        assert!(ping_unrenewed(true, before, before, "CLEAR-FAILED"));
        assert!(!ping_unrenewed(true, before, "bbbbbbbbbbbb@10-05 07:00", "cleared"));
        assert!(!ping_unrenewed(true, before, before, "absent"));
        assert!(!ping_unrenewed(false, before, before, "cleared"));
        for unread in ["-", "?"] {
            assert!(!ping_unrenewed(true, unread, unread, "cleared"));
        }
    }

    #[test]
    fn a_session_directory_is_named_as_cswap_names_it() {
        assert_eq!(slug_email("first.last+tag@example.test"), "first.last_tag_example.test");
        assert_eq!(slug_email("ü_n-1@example.test"), "__n-1_example.test");
    }

    fn stub(directory: &Path, status: i32) -> String {
        if cfg!(windows) {
            let path = directory.join("cswap-stub.cmd");
            std::fs::write(&path, format!("@echo off\r\necho %*>>\"%~dp0runs\"\r\nexit /b {status}\r\n")).unwrap();
            path.to_string_lossy().into_owned()
        } else {
            let path = directory.join("cswap-stub");
            std::fs::write(&path, format!("#!/bin/sh\necho \"$*\" >> \"$(dirname \"$0\")/runs\"\nexit {status}\n")).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            path.to_string_lossy().into_owned()
        }
    }

    #[test]
    fn a_request_is_one_run_and_leaves_one_stored_sign_in() {
        let directory = scratch("ping");
        let home = directory.join("home");
        let email = "pilot@example.test";
        let stored = stored_credential(&home, 2, email);
        let session = session_credential(&home, 2, email);
        std::fs::create_dir_all(stored.parent().unwrap()).unwrap();
        std::fs::create_dir_all(session.parent().unwrap()).unwrap();
        std::fs::write(&stored, STORED).unwrap();
        std::fs::write(&session, SESSION).unwrap();
        let ping = slot_ping(&stub(&directory, 0), &home, 2, email, &directory, "warm");
        assert!(ping.ok && ping.unrenewed);
        assert!(!session.exists() && stored.exists());
        let runs = std::fs::read_to_string(directory.join("runs")).unwrap();
        assert_eq!(runs.trim(), "run 2 -- claude --model haiku --strict-mcp-config -p .");
        let mark = format!("{}@10-06 12:00", &sha256::hash("fictional-refresh-token")[..12]);
        let audit = std::fs::read_to_string(directory.join("cred-audit.log")).unwrap();
        assert!(audit.trim_end().ends_with(&format!(" slot 2 kind=warm ok=True enc {mark} -> {mark} prof-before={mark} prof=cleared prof-after={mark}")), "{audit}");

        // A request that fails is not one that worked, and nothing is left to clear.
        let ping = slot_ping(&stub(&directory, 3), &home, 2, email, &directory, "probe");
        assert!(!ping.ok && !ping.unrenewed);
        let audit = std::fs::read_to_string(directory.join("cred-audit.log")).unwrap();
        assert_eq!(audit.lines().count(), 2);
        assert!(audit.trim_end().ends_with(&format!(" slot 2 kind=probe ok=False enc {mark} -> {mark} prof-before=- prof=absent prof-after=-")), "{audit}");
        let ping = slot_ping(&directory.join("no-such-program").to_string_lossy(), &home, 2, email, &directory, "probe");
        assert!(!ping.ok);

        // The audit keeps one earlier file and starts again.
        std::fs::write(directory.join("cred-audit.log"), "x".repeat(262_145)).unwrap();
        slot_ping(&stub(&directory, 0), &home, 2, email, &directory, "warm");
        assert_eq!(std::fs::metadata(directory.join("cred-audit.log.1")).unwrap().len(), 262_145);
        assert_eq!(std::fs::read_to_string(directory.join("cred-audit.log")).unwrap().lines().count(), 1);
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn cswap_is_found_where_the_shared_cases_say() {
        let cases = shared_rules("cswap").arr();
        assert!(cases.len() > 8);
        let mut wrong = Vec::new();
        for case in &cases {
            let field = |name: &str| case.g(name).ok().unwrap();
            let root = scratch("shared-cswap");
            for place in ["owned", "home", "path", "local", "roaming"] {
                std::fs::create_dir_all(root.join(place)).unwrap();
            }
            // Each staged cswap holds the name of its place, which is how the one found is told.
            for place in field("present").each() {
                let place = place.s().ok().unwrap();
                let file = match place.as_str() {
                    "owned" | "path" => root.join(&place).join(if cfg!(windows) { "cswap.exe" } else { "cswap" }),
                    _ => root.join(&place),
                };
                std::fs::create_dir_all(file.parent().unwrap()).unwrap();
                std::fs::write(&file, &place).unwrap();
                #[cfg(unix)]
                std::fs::set_permissions(&file, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
            }
            let places = Places {
                owned: Some(root.join("owned")),
                home: Some(root.join("home")),
                shared: root.join("shared").join("cswap"),
                path: Some(root.join("path").into_os_string()),
                extensions: None,
                local: Some(root.join("local")),
                roaming: Some(root.join("roaming")),
            };
            let named = field("named").s().ok().unwrap();
            let answer = match named.is_empty() {
                true => found_in(&places).map(|found| std::fs::read_to_string(found).unwrap()),
                false => resolve_executable(Some(&named)),
            };
            let expected = field("expected");
            let expected = if expected.is_null() { None } else { Some(expected.s().ok().unwrap()) };
            if answer != expected {
                wrong.push(format!("{}: expected {expected:?}, answered {answer:?}", field("name").s().ok().unwrap()));
            }
            std::fs::remove_dir_all(&root).unwrap();
        }
        assert!(wrong.is_empty(), "{} of {} cases differ:\n{}", wrong.len(), cases.len(), wrong.join("\n"));
        assert!(shared_rules("readTimeoutMs").eq_i(READ_TIMEOUT_MS as i32).ok().unwrap());
    }

    #[test]
    fn the_named_cswap_is_the_one_used() {
        assert_eq!(resolve_executable(Some("C:/fictional/cswap.exe")).as_deref(), Some("C:/fictional/cswap.exe"));
        let directory = scratch("python");
        for name in ["Python39", "Python312", "Other"] {
            std::fs::create_dir_all(directory.join(name).join("Scripts")).unwrap();
            std::fs::write(directory.join(name).join("Scripts").join("cswap.exe"), "").unwrap();
        }
        // The newest by name, as the PowerShell sort had it: 39 sorts after 312.
        assert_eq!(beside_python(directory.clone()), Some(directory.join("Python39").join("Scripts").join("cswap.exe")));
        assert_eq!(beside_python(directory.join("none")), None);
        std::fs::remove_dir_all(&directory).unwrap();
    }
}

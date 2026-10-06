//! Compiled reader for HotPl8 display commands.
//!
//! The PowerShell implementation stays the authority. This program answers only the inputs it
//! models exactly; for anything else it exits with `DECLINED` and writes nothing to standard
//! output, so `hotpl8.ps1` continues into its own code and prints what it always printed.
//! The behaviour contract is docs/plans/rust-read-side.md.

#![allow(dead_code)]

mod capacity;
mod claude;
mod codex;
mod contract;
mod critical;
mod decision;
mod insights;
mod json;
mod num;
mod observation;
mod overview;
mod pause;
mod policy;
mod ps;
mod registry;
mod selection;
mod time;

use std::ffi::OsString;
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use serde_json::{Map, Value};

use crate::ps::{decline, throw, Stop, R, V};
use crate::time::Dto;

/// Raised whenever the command line or the output contract with `hotpl8.ps1` changes.
/// Every request names the number its caller speaks; another number is declined.
const PROTOCOL: u32 = 2;
/// Exit status for "not modelled here; use the PowerShell implementation".
const DECLINED_STATUS: u8 = 64;
const FAILED_STATUS: u8 = 1;

/// The input is outside what this program reproduces exactly.
#[derive(Debug, PartialEq)]
struct Declined;

fn main() -> ExitCode {
    let arguments: Vec<OsString> = std::env::args_os().skip(1).collect();
    let Ok(output) = run(&arguments) else {
        return ExitCode::from(DECLINED_STATUS);
    };
    let mut stdout = std::io::stdout().lock();
    // A caller that received part of an answer must not use it.
    if stdout.write_all(output.as_bytes()).is_err() || stdout.flush().is_err() {
        return ExitCode::from(FAILED_STATUS);
    }
    ExitCode::SUCCESS
}

fn run(arguments: &[OsString]) -> Result<String, Declined> {
    run_as(arguments, option_env!("HOTPL8_BUILD_SHA"))
}

fn run_as(arguments: &[OsString], build_sha: Option<&str>) -> Result<String, Declined> {
    let (command, rest) = arguments.split_first().ok_or(Declined)?;
    match command.to_str() {
        Some("self-check") if rest.is_empty() => Ok(self_check(build_sha)),
        Some("version") => {
            let request = request(rest, build_sha)?;
            if request.state.is_some() || request.policy.is_some() || request.now.is_some() || request.dump {
                return Err(Declined);
            }
            let root = Path::new(request.root);
            let version = std::fs::read(root.join("VERSION")).map_err(|_| Declined)?;
            let build = match std::fs::read(root.join("build-info.json")) {
                Ok(bytes) => Some(bytes),
                // PowerShell reads a missing file as "no build identity".
                Err(error) if error.kind() == ErrorKind::NotFound => None,
                Err(_) => return Err(Declined),
            };
            version_output(&version, build.as_deref(), request.as_json)
        }
        Some(name @ ("status" | "explain")) => {
            let request = request(rest, build_sha)?;
            display(name == "explain", &request).map_err(|stop| {
                // Where the input left the model: a debugging aid hotpl8.ps1 never shows.
                let (kind, at) = match stop {
                    Stop::Decline(at) => ("declined", at),
                    Stop::Throw(at) => ("error", at),
                };
                eprintln!("hotpl8-native: {kind} at {}:{}", at.file(), at.line());
                Declined
            })
        }
        _ => Err(Declined),
    }
}

/// What every command is told: which caller this is, and what to read.
struct Request<'a> {
    root: &'a OsString,
    state: Option<&'a OsString>,
    policy: Option<&'a OsString>,
    /// Test-only: the instant to answer for instead of the clock.
    now: Option<Dto>,
    /// PowerShell 7 rather than Windows PowerShell 5.1.
    core: bool,
    as_json: bool,
    /// Test-only: with `-AsJson`, the typed dump of the value instead of its JSON text.
    dump: bool,
}

/// The arguments after the command. A caller speaking another protocol, or one whose
/// release was not built from this binary's commit, is declined before anything is read.
fn request<'a>(arguments: &'a [OsString], build_sha: Option<&str>) -> Result<Request<'a>, Declined> {
    const NAMES: [&str; 7] = ["--protocol", "--shell", "--release", "--root", "--state", "--policy", "--now"];
    let mut values: [Option<&OsString>; 7] = [None; 7];
    let (mut as_json, mut dump) = (false, false);
    let mut index = 0;
    while index < arguments.len() {
        let name = arguments[index].to_str().ok_or(Declined)?;
        if let Some(slot) = NAMES.iter().position(|known| *known == name) {
            index += 1;
            if values[slot].is_some() || index == arguments.len() {
                return Err(Declined);
            }
            values[slot] = Some(&arguments[index]);
        } else if name == "-AsJson" && !as_json {
            as_json = true;
        } else if name == "--dump" && !dump {
            dump = true;
        } else {
            return Err(Declined);
        }
        index += 1;
    }
    let text = |slot: usize| values[slot].map(|value| value.to_str().ok_or(Declined)).transpose();
    if text(0)? != Some(PROTOCOL.to_string().as_str()) {
        return Err(Declined);
    }
    let core = match text(1)? {
        Some("desktop") => false,
        Some("core") => true,
        _ => return Err(Declined),
    };
    // A source checkout has no build identity; there the protocol alone decides.
    if let Some(release) = text(2)? {
        if !is_commit_sha(release) || build_sha != Some(release) {
            return Err(Declined);
        }
    }
    let now = match text(6)? {
        Some(instant) => Some(Dto::parse(instant).ok().filter(|at| at.offset_minutes == 0).ok_or(Declined)?),
        None => None,
    };
    if dump && !as_json {
        return Err(Declined);
    }
    Ok(Request { root: values[3].ok_or(Declined)?, state: values[4], policy: values[5], now, core, as_json, dump })
}

const CLAUDE_DEFINITION: &str = include_str!("../../data/providers/claude.json");
const CODEX_DEFINITION: &str = include_str!("../../data/providers/codex.json");
const CAPACITY_PROFILES: &str = include_str!("../../data/capacity-profiles.json");

/// A path PowerShell and this program open as the same file whatever their directories.
#[track_caller]
fn absolute(path: &OsString) -> R<PathBuf> {
    let Some(text) = path.to_str() else { return decline() };
    let bytes = text.as_bytes();
    let rooted = if cfg!(windows) {
        let drive = bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && matches!(bytes[2], b'\\' | b'/');
        // Device paths skip the normalisation .NET applies.
        drive || (text.starts_with(r"\\") && !text.starts_with(r"\\?") && !text.starts_with(r"\\."))
    } else {
        text.starts_with('/')
    };
    if !rooted || ps::has_control(text) {
        return decline();
    }
    Ok(PathBuf::from(text))
}

/// The data files every rule reads, as built into this binary. The release's own copies
/// must say the same, so an edited file is PowerShell's to answer.
fn packaged_data(root: &Path) -> R<()> {
    let data = root.join("data");
    let providers = data.join("providers");
    let Ok(entries) = std::fs::read_dir(&providers) else { return decline() };
    let mut names = Vec::new();
    for entry in entries {
        let Ok(entry) = entry else { return decline() };
        names.push(entry.file_name());
    }
    names.sort();
    if names != ["claude.json", "codex.json"] {
        return decline();
    }
    let embedded = |text: &str, path: PathBuf| -> R<V> {
        let value = json::parse_bytes(text.as_bytes())?;
        match json::read_file(&path)? {
            Some(found) if json::same(&found, &value) => Ok(value),
            _ => decline(),
        }
    };
    // Display order: Claude, then Codex.
    let definitions = vec![embedded(CLAUDE_DEFINITION, providers.join("claude.json"))?, embedded(CODEX_DEFINITION, providers.join("codex.json"))?];
    registry::set_catalog(definitions);
    capacity::set_catalog(embedded(CAPACITY_PROFILES, data.join("capacity-profiles.json"))?);
    Ok(())
}

/// Resolve-Hotpl8StateDirectory
fn state_directory(request: &Request, root: &Path) -> R<PathBuf> {
    if let Some(explicit) = request.state {
        return absolute(explicit);
    }
    if let Some(named) = std::env::var_os("HOTPL8_STATE_DIRECTORY").filter(|value| !value.is_empty()) {
        return absolute(&named);
    }
    let installed = json::read_file(&root.join("install-state.json"))?.unwrap_or(V::Null);
    let directory = installed.g("stateDirectory")?;
    if directory.t()? {
        return absolute(&OsString::from(directory.s()?));
    }
    // A source checkout is portable, including existing installations.
    Ok(root.to_path_buf())
}

/// The lines PowerShell writes, each ended by a line feed. `src/native.ps1` splits on
/// line feeds, so a line holding one cannot be handed over.
fn text_output(lines: Vec<String>) -> R<String> {
    let mut out = String::new();
    for line in lines {
        if line.contains('\n') {
            return decline();
        }
        out.push_str(&line);
        out.push('\n');
    }
    Ok(out)
}

/// `$value | ConvertTo-Json -Depth $limit`, or its typed dump for the parity suite.
fn value_output(value: &V, limit: usize, dump: bool) -> R<String> {
    let text = json::write(value, limit)?;
    if dump {
        return json::dump(value);
    }
    Ok(text + "\n")
}

/// `hotpl8 status` and `hotpl8 explain`, in the steps hotpl8.ps1 takes.
fn display(explain: bool, request: &Request) -> R<String> {
    ps::set_core(request.core);
    let root = absolute(request.root)?;
    packaged_data(&root)?;
    let state = state_directory(request, &root)?;
    // One clock reading per request: every line of an answer describes the same instant.
    let now = match request.now {
        Some(now) => now,
        None => Dto::now()?,
    };
    let policy_file = match request.policy {
        Some(preview) => absolute(preview)?,
        None => state.join("policy.json"),
    };
    let Some(policy) = json::read_file(&policy_file)? else { return throw() };
    policy::assert_policy(&policy)?;
    let status = insights::read_snapshot(&state, &policy, request.policy.is_some(), now)?;
    if explain {
        if status.t()? {
            status.add_member("automationPause", pause::pause(&state, now)?, true)?;
        }
        if request.as_json {
            let answer = obj! {
                "generatedAt" => status.g("generatedAt")?,
                "claude" => status.g("decision")?,
                "codex" => status.path(&["providers", "codex", "decisions"])?,
                "pause" => status.g("automationPause")?,
                "providerOverview" => status.g("providerOverview")?,
            };
            return value_output(&answer, 16, request.dump);
        }
        return text_output(insights::format_explanation(&status, now)?.iter().map(|line| ps::safe_text(line)).collect());
    }
    if !status.t()? || !status.g("generatedAt")?.t()? {
        return text_output(vec!["No cached status. Run hotpl8 refresh.".to_string()]);
    }
    if request.as_json {
        return value_output(&status, 24, request.dump);
    }
    text_output(insights::format_status(&status, &policy, &state, now)?)
}

/// Identity line read by `src/native.ps1` before it trusts this binary.
fn self_check(build_sha: Option<&str>) -> String {
    let sha = match build_sha {
        Some(value) if is_commit_sha(value) => value,
        _ => "unknown",
    };
    format!("hotpl8-native protocol={PROTOCOL} sha={sha}\n")
}

fn is_commit_sha(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// `hotpl8 version`: `<VERSION> main <sha12>` when the release has a build identity, the bare
/// version otherwise; with `-AsJson` the version and the whole build record.
fn version_output(version_file: &[u8], build_file: Option<&[u8]>, as_json: bool) -> Result<String, Declined> {
    let version = version_text(version_file)?;
    let build = match build_file {
        Some(bytes) => Some(build_record(bytes)?),
        None => None,
    };
    if as_json {
        let mut document = Map::new();
        document.insert("version".to_owned(), Value::String(version.to_owned()));
        document.insert("build".to_owned(), build.map_or(Value::Null, Value::Object));
        let text = serde_json::to_string_pretty(&Value::Object(document)).map_err(|_| Declined)?;
        return Ok(text + "\n");
    }
    Ok(match build.as_ref().map(short_sha).transpose()?.flatten() {
        Some(sha) => format!("{version} main {sha}\n"),
        None => format!("{version}\n"),
    })
}

/// `(Get-Content VERSION -Raw).Trim()` for an ASCII file. Windows PowerShell decodes a file
/// without a byte-order mark in the system code page, so anything else is left to it.
fn version_text(bytes: &[u8]) -> Result<&str, Declined> {
    let text = utf8_text(bytes)?;
    // -Raw gives $null for an empty file and the script then fails on .Trim().
    if text.is_empty() || !text.is_ascii() {
        return Err(Declined);
    }
    // .NET Trim() whitespace within ASCII: tab through carriage return, and space.
    Ok(text.trim_matches(|character| matches!(character, '\t'..='\r' | ' ')))
}

/// The flat object `delivery/package.py` writes. PowerShell's JSON reader is looser than a
/// strict parser and converts some values (dates, nested data past a depth); every such shape
/// is declined rather than imitated.
fn build_record(bytes: &[u8]) -> Result<Map<String, Value>, Declined> {
    let Value::Object(record) = serde_json::from_str(utf8_text(bytes)?).map_err(|_| Declined)? else {
        return Err(Declined);
    };
    let mut seen: Vec<String> = Vec::with_capacity(record.len());
    for (key, value) in &record {
        // PowerShell property names ignore case; names that collide make its reader fail.
        let folded = key.to_ascii_lowercase();
        if key.is_empty() || !key.is_ascii() || seen.contains(&folded) {
            return Err(Declined);
        }
        seen.push(folded);
        match value {
            Value::Null | Value::Bool(_) => {}
            Value::Number(number) if number.is_i64() || number.is_u64() => {}
            Value::String(text) if !looks_like_date(text) => {}
            _ => return Err(Declined),
        }
    }
    Ok(record)
}

/// Strings some PowerShell versions turn into date values while reading JSON.
fn looks_like_date(text: &str) -> bool {
    let bytes = text.as_bytes();
    let iso = bytes.len() >= 11
        && bytes[..10].iter().enumerate().all(|(index, byte)| match index {
            4 | 7 => *byte == b'-',
            _ => byte.is_ascii_digit(),
        })
        && bytes[10] == b'T';
    iso || text.contains("/Date(")
}

/// `if($build.sha){...$build.sha.Substring(0,12)}`: the first twelve UTF-16 units of a
/// non-empty string, nothing for a missing or false value, and declined where the script
/// would raise an error.
fn short_sha(build: &Map<String, Value>) -> Result<Option<String>, Declined> {
    let value = build.iter().find(|(key, _)| key.eq_ignore_ascii_case("sha")).map(|(_, value)| value);
    match value {
        None | Some(Value::Null) | Some(Value::Bool(false)) => Ok(None),
        Some(Value::Number(number)) if number.as_i64() == Some(0) => Ok(None),
        Some(Value::String(text)) if text.is_empty() => Ok(None),
        Some(Value::String(text)) => {
            let prefix: String = text.chars().take(12).collect();
            // .Length counts UTF-16 units; a pair split by Substring is not reproduced here.
            if prefix.chars().count() < 12 || prefix.chars().any(|character| character.len_utf16() != 1) {
                return Err(Declined);
            }
            Ok(Some(prefix))
        }
        Some(_) => Err(Declined),
    }
}

/// UTF-8 with an optional byte-order mark. PowerShell also detects UTF-16 marks.
fn utf8_text(bytes: &[u8]) -> Result<&str, Declined> {
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    std::str::from_utf8(bytes).map_err(|_| Declined)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

    fn build(sha: &str) -> Vec<u8> {
        format!(r#"{{"protocol":1,"product":"hotpl8","repository":"example/hotpl8","sha":"{sha}","channel":"main"}}"#).into_bytes()
    }

    fn text(version: &[u8], build: Option<&[u8]>) -> Result<String, Declined> {
        version_output(version, build, false)
    }

    #[test]
    fn release_with_identity_prints_version_and_short_sha() {
        assert_eq!(text(b"1.4.0\n", Some(&build(SHA))), Ok("1.4.0 main 0123456789ab\n".to_owned()));
    }

    #[test]
    fn source_checkout_prints_the_bare_version() {
        assert_eq!(text(b"1.4.0\r\n", None), Ok("1.4.0\n".to_owned()));
    }

    #[test]
    fn version_is_trimmed_like_dotnet() {
        assert_eq!(text(b"\xEF\xBB\xBF \t1.4.0-rc.1 \x0B\x0C\r\n", None), Ok("1.4.0-rc.1\n".to_owned()));
        // U+001C is not whitespace to .NET Trim().
        assert_eq!(text(b"\x1C 1.4.0\n", None), Ok("\x1C 1.4.0\n".to_owned()));
        assert_eq!(text(b" \n", None), Ok("\n".to_owned()));
    }

    #[test]
    fn version_file_outside_the_model_is_declined() {
        assert_eq!(text(b"", None), Err(Declined));
        assert_eq!(text("1.4.0\u{a0}".as_bytes(), None), Err(Declined));
        assert_eq!(text(b"\xFF\xFE1\x00", None), Err(Declined));
    }

    #[test]
    fn absent_or_false_sha_prints_the_bare_version() {
        for record in [r#"{}"#, r#"{"sha":null}"#, r#"{"sha":""}"#, r#"{"sha":false}"#, r#"{"sha":0}"#] {
            assert_eq!(text(b"1.4.0", Some(record.as_bytes())), Ok("1.4.0\n".to_owned()), "{record}");
        }
    }

    #[test]
    fn sha_property_name_ignores_case() {
        let record = format!(r#"{{"SHA":"{SHA}"}}"#);
        assert_eq!(text(b"1.4.0", Some(record.as_bytes())), Ok("1.4.0 main 0123456789ab\n".to_owned()));
    }

    #[test]
    fn sha_the_script_would_fail_on_is_declined() {
        for record in [r#"{"sha":"short"}"#, r#"{"sha":5}"#, r#"{"sha":true}"#, "{\"sha\":\"0123456789a\u{1F431}\"}"] {
            assert_eq!(text(b"1.4.0", Some(record.as_bytes())), Err(Declined), "{record}");
        }
    }

    #[test]
    fn build_records_powershell_reads_differently_are_declined() {
        for record in [
            "",
            "null",
            "[]",
            "{'sha':'single quotes'}",
            r#"{"sha":"a",}"#,
            r#"{"sha":"a","SHA":"b"}"#,
            r#"{"":1}"#,
            r#"{"nested":{"a":1}}"#,
            r#"{"list":[1]}"#,
            r#"{"ratio":1.5}"#,
            r#"{"big":123456789012345678901234567890}"#,
            r#"{"built":"2026-09-10T12:00:00Z"}"#,
            r#"{"built":"\/Date(1000)\/"}"#,
            "{\"\u{17F}ha\":\"x\"}",
        ] {
            assert_eq!(text(b"1.4.0", Some(record.as_bytes())), Err(Declined), "{record}");
        }
    }

    #[test]
    fn json_keeps_the_build_record_in_file_order() {
        let output = version_output(b"1.4.0\n", Some(&build(SHA)), true).unwrap();
        let parsed: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(parsed["version"], "1.4.0");
        let keys: Vec<&String> = parsed["build"].as_object().unwrap().keys().collect();
        assert_eq!(keys, ["protocol", "product", "repository", "sha", "channel"]);
        assert_eq!(parsed["build"]["protocol"], 1);
        assert_eq!(parsed["build"]["sha"], SHA);
        assert!(output.ends_with("}\n"));
    }

    #[test]
    fn json_without_a_build_record_reports_null() {
        let output = version_output(b"1.4.0\n", None, true).unwrap();
        let parsed: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(parsed, serde_json::json!({"version": "1.4.0", "build": null}));
    }

    #[test]
    fn json_does_not_need_a_usable_sha() {
        let output = version_output(b"1.4.0\n", Some(br#"{"sha":"short"}"#), true).unwrap();
        let parsed: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(parsed["build"]["sha"], "short");
    }

    #[test]
    fn self_check_reports_protocol_and_build_identity() {
        assert_eq!(self_check(Some(SHA)), format!("hotpl8-native protocol=2 sha={SHA}\n"));
        assert_eq!(self_check(None), "hotpl8-native protocol=2 sha=unknown\n");
        assert_eq!(self_check(Some("not-a-commit")), "hotpl8-native protocol=2 sha=unknown\n");
        assert_eq!(self_check(Some(&SHA.to_uppercase())), "hotpl8-native protocol=2 sha=unknown\n");
    }

    fn arguments(items: &[&str]) -> Vec<OsString> {
        items.iter().map(OsString::from).collect()
    }

    #[test]
    fn command_lines_outside_the_contract_are_declined() {
        for items in [
            &[][..],
            &["status"],
            &["self-check", "extra"],
            &["version"],
            &["version", "--root", "a"],
            &["version", "--protocol", "2", "--shell", "desktop"],
            &["version", "--protocol", "2", "--shell", "desktop", "--root"],
            &["version", "--protocol", "2", "--shell", "desktop", "--root", "a", "--root", "b"],
            &["version", "--protocol", "2", "--shell", "desktop", "--root", "a", "-asjson"],
            &["version", "--protocol", "2", "--shell", "desktop", "--root", "a", "-AsJson", "-AsJson"],
            &["version", "--protocol", "2", "--shell", "desktop", "--root", "a", "--state", "b"],
            &["version", "--protocol", "2", "--shell", "desktop", "--root", "a", "--now", "2026-09-12T12:00:00Z"],
            &["status", "--protocol", "2", "--shell", "desktop", "--root", "a", "--dump"],
            &["status", "--protocol", "2", "--shell", "desktop", "--root", "a", "--now", "2026-09-12T07:00:00-05:00"],
            &["status", "--protocol", "2", "--shell", "desktop", "--root", "relative"],
            &["refresh", "--protocol", "2", "--shell", "desktop", "--root", "a"],
        ] {
            assert_eq!(run_as(&arguments(items), Some(SHA)), Err(Declined), "{items:?}");
        }
    }

    #[test]
    fn a_caller_this_binary_was_not_built_for_is_declined() {
        let root = std::env::temp_dir().join(format!("hotpl8-native-identity-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("VERSION"), "1.4.0\n").unwrap();
        let root_text = root.to_str().unwrap();
        let with = |identity: &[&str]| {
            let mut items = vec!["version"];
            items.extend_from_slice(identity);
            items.extend_from_slice(&["--root", root_text]);
            arguments(&items)
        };
        let other = "89abcdef0123456789abcdef0123456789abcdef";
        assert_eq!(run_as(&with(&["--protocol", "2", "--shell", "desktop"]), Some(SHA)), Ok("1.4.0\n".to_owned()));
        assert_eq!(run_as(&with(&["--protocol", "2", "--shell", "core", "--release", SHA]), Some(SHA)), Ok("1.4.0\n".to_owned()));
        // A source checkout names no release, so any build answers it.
        assert_eq!(run_as(&with(&["--protocol", "2", "--shell", "desktop"]), None), Ok("1.4.0\n".to_owned()));
        for identity in [
            &["--protocol", "1", "--shell", "desktop"][..],
            &["--protocol", "3", "--shell", "desktop"],
            &["--protocol", "02", "--shell", "desktop"],
            &["--shell", "desktop"],
            &["--protocol", "2"],
            &["--protocol", "2", "--shell", "Desktop"],
            &["--protocol", "2", "--shell", "desktop", "--release", other],
            &["--protocol", "2", "--shell", "desktop", "--release", "unknown"],
        ] {
            assert_eq!(run_as(&with(identity), Some(SHA)), Err(Declined), "{identity:?}");
        }
        // A binary without a build identity cannot vouch for a release.
        assert_eq!(run_as(&with(&["--protocol", "2", "--shell", "desktop", "--release", SHA]), None), Err(Declined));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn version_reads_the_release_directory() {
        let root = std::env::temp_dir().join(format!("hotpl8-native-test-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("VERSION"), "1.4.0\n").unwrap();
        let mut arguments = arguments(&["version", "--protocol", "2", "--shell", "desktop", "--root"]);
        arguments.push(root.clone().into_os_string());
        assert_eq!(run(&arguments), Ok("1.4.0\n".to_owned()));
        std::fs::write(root.join("build-info.json"), build(SHA)).unwrap();
        assert_eq!(run(&arguments), Ok("1.4.0 main 0123456789ab\n".to_owned()));
        std::fs::remove_file(root.join("VERSION")).unwrap();
        assert_eq!(run(&arguments), Err(Declined));
        std::fs::remove_dir_all(&root).unwrap();
    }
}

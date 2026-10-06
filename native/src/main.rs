//! Compiled reader for HotPl8 display commands.
//!
//! The PowerShell implementation stays the authority. This program answers only the inputs it
//! models exactly; for anything else it exits with `DECLINED` and writes nothing to standard
//! output, so `hotpl8.ps1` continues into its own code and prints what it always printed.
//! The behaviour contract is docs/plans/rust-read-side.md.

#![allow(dead_code)]

mod capacity;
mod contract;
mod critical;
mod decision;
mod json;
mod num;
mod observation;
mod ps;
mod selection;
mod time;

use std::ffi::OsString;
use std::io::{ErrorKind, Write};
use std::path::Path;
use std::process::ExitCode;

use serde_json::{Map, Value};

/// Raised whenever the command line or the output contract with `hotpl8.ps1` changes.
/// `src/native.ps1` refuses a binary that reports a different number.
const PROTOCOL: u32 = 1;
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
    let (command, rest) = arguments.split_first().ok_or(Declined)?;
    match command.to_str() {
        Some("self-check") if rest.is_empty() => Ok(self_check(option_env!("HOTPL8_BUILD_SHA"))),
        Some("version") => {
            let (root, as_json) = version_arguments(rest)?;
            let root = Path::new(root);
            let version = std::fs::read(root.join("VERSION")).map_err(|_| Declined)?;
            let build = match std::fs::read(root.join("build-info.json")) {
                Ok(bytes) => Some(bytes),
                // PowerShell reads a missing file as "no build identity".
                Err(error) if error.kind() == ErrorKind::NotFound => None,
                Err(_) => return Err(Declined),
            };
            version_output(&version, build.as_deref(), as_json)
        }
        _ => Err(Declined),
    }
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

fn version_arguments(arguments: &[OsString]) -> Result<(&OsString, bool), Declined> {
    let mut root = None;
    let mut as_json = false;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].to_str() {
            Some("--root") if root.is_none() && index + 1 < arguments.len() => {
                index += 1;
                root = Some(&arguments[index]);
            }
            Some("-AsJson") if !as_json => as_json = true,
            _ => return Err(Declined),
        }
        index += 1;
    }
    Ok((root.ok_or(Declined)?, as_json))
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
        assert_eq!(self_check(Some(SHA)), format!("hotpl8-native protocol=1 sha={SHA}\n"));
        assert_eq!(self_check(None), "hotpl8-native protocol=1 sha=unknown\n");
        assert_eq!(self_check(Some("not-a-commit")), "hotpl8-native protocol=1 sha=unknown\n");
        assert_eq!(self_check(Some(&SHA.to_uppercase())), "hotpl8-native protocol=1 sha=unknown\n");
    }

    #[test]
    fn command_lines_outside_the_contract_are_declined() {
        let arguments = |items: &[&str]| items.iter().map(OsString::from).collect::<Vec<_>>();
        for items in [
            &[][..],
            &["status"],
            &["self-check", "extra"],
            &["version"],
            &["version", "--root"],
            &["version", "--root", "a", "--root", "b"],
            &["version", "--root", "a", "-asjson"],
            &["version", "--root", "a", "-AsJson", "-AsJson"],
        ] {
            assert_eq!(run(&arguments(items)), Err(Declined), "{items:?}");
        }
    }

    #[test]
    fn version_reads_the_release_directory() {
        let root = std::env::temp_dir().join(format!("hotpl8-native-test-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("VERSION"), "1.4.0\n").unwrap();
        let arguments = [OsString::from("version"), OsString::from("--root"), root.clone().into_os_string()];
        assert_eq!(run(&arguments), Ok("1.4.0\n".to_owned()));
        std::fs::write(root.join("build-info.json"), build(SHA)).unwrap();
        assert_eq!(run(&arguments), Ok("1.4.0 main 0123456789ab\n".to_owned()));
        std::fs::remove_file(root.join("VERSION")).unwrap();
        assert_eq!(run(&arguments), Err(Declined));
        std::fs::remove_dir_all(&root).unwrap();
    }
}

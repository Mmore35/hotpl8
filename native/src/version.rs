//! `hotpl8 version`: what this copy of HotPl8 is.

use std::path::Path;

use crate::json;
use crate::obj;
use crate::ps::{unreadable_as, R, V};
use crate::request::Request;

/// `<VERSION> main <first twelve of the commit>` for a built release and the bare version for
/// a checkout; with `-AsJson` the version and the whole build record.
pub fn answer(request: &Request) -> R<String> {
    let version = version(&request.root)?;
    let build = json::read_file(&request.root.join("build-info.json"))?;
    if request.as_json {
        let document = obj! { "version" => version.as_str(), "build" => build.unwrap_or(V::Null) };
        return Ok(json::write(&document, 4)? + "\n");
    }
    let commit = match build {
        Some(build) => build.g("sha")?,
        None => V::Null,
    };
    Ok(match commit.as_str().filter(|sha| !sha.is_empty()) {
        Some(sha) => format!("{version} main {}\n", sha.chars().take(12).collect::<String>()),
        None => format!("{version}\n"),
    })
}

pub(crate) fn version(root: &Path) -> R<String> {
    let Ok(bytes) = std::fs::read(root.join("VERSION")) else {
        return unreadable_as("This copy of HotPl8 has no VERSION file.");
    };
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes);
    match std::str::from_utf8(bytes).map(str::trim) {
        Ok(version) if !version.is_empty() => Ok(version.to_owned()),
        _ => unreadable_as("This copy of HotPl8 has a VERSION file that names no version."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::Command;

    const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

    /// A release directory holding the two files, answered as text and as JSON.
    fn answers(name: &str, version: Option<&[u8]>, build: Option<&str>) -> (Result<String, String>, Result<String, String>) {
        let root = std::env::temp_dir().join(format!("hotpl8-native-version-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        if let Some(version) = version {
            std::fs::write(root.join("VERSION"), version).unwrap();
        }
        if let Some(build) = build {
            std::fs::write(root.join("build-info.json"), build).unwrap();
        }
        let mut request = Request::new(Command::Version, root.clone());
        let text = answer(&request).map_err(|stop| stop.message());
        request.as_json = true;
        let json = answer(&request).map_err(|stop| stop.message());
        std::fs::remove_dir_all(&root).unwrap();
        (text, json)
    }

    #[test]
    fn a_release_prints_its_version_and_commit() {
        let build = format!(r#"{{"protocol":1,"product":"hotpl8","sha":"{SHA}","channel":"main"}}"#);
        let (text, json) = answers("release", Some(b"1.4.0\n"), Some(&build));
        assert_eq!(text.unwrap(), "1.4.0 main 0123456789ab\n");
        assert_eq!(
            json.unwrap(),
            format!("{{\n  \"version\": \"1.4.0\",\n  \"build\": {{\n    \"protocol\": 1,\n    \"product\": \"hotpl8\",\n    \"sha\": \"{SHA}\",\n    \"channel\": \"main\"\n  }}\n}}\n")
        );
    }

    #[test]
    fn a_checkout_prints_the_bare_version() {
        let (text, json) = answers("checkout", Some(b"\xEF\xBB\xBF 1.4.0-rc.1 \r\n"), None);
        assert_eq!(text.unwrap(), "1.4.0-rc.1\n");
        assert_eq!(json.unwrap(), "{\n  \"version\": \"1.4.0-rc.1\",\n  \"build\": null\n}\n");
    }

    #[test]
    fn a_build_record_without_a_commit_prints_the_bare_version() {
        for (index, build) in ["{}", r#"{"sha":null}"#, r#"{"sha":""}"#, r#"{"sha":5}"#].into_iter().enumerate() {
            assert_eq!(answers(&format!("bare{index}"), Some(b"1.4.0"), Some(build)).0.unwrap(), "1.4.0\n", "{build}");
        }
        assert_eq!(answers("short", Some(b"1.4.0"), Some(r#"{"sha":"abc"}"#)).0.unwrap(), "1.4.0 main abc\n");
    }

    #[test]
    fn a_copy_that_cannot_say_what_it_is_says_why() {
        assert_eq!(answers("none", None, None).0.unwrap_err(), "This copy of HotPl8 has no VERSION file.");
        for (index, version) in [&b""[..], b" \r\n", b"\xFF\xFE1\x00"].into_iter().enumerate() {
            assert_eq!(answers(&format!("empty{index}"), Some(version), None).0.unwrap_err(), "This copy of HotPl8 has a VERSION file that names no version.");
        }
        let (text, json) = answers("record", Some(b"1.4.0"), Some("{\"sha\": -}"));
        assert_eq!(text.unwrap_err(), "build-info.json is not JSON as HotPl8 writes it (line 1, column 10).");
        assert_eq!(json.unwrap_err(), "build-info.json is not JSON as HotPl8 writes it (line 1, column 10).");
    }
}

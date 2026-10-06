//! The front door: the words a user typed after `hotpl8`, answered without starting
//! PowerShell when they spell a request the reader owns. Everything else is not this
//! program's to refuse: the launcher starts the PowerShell entry with the same words.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::request::{full_path, Command, Request};
use crate::Refusal;

pub fn answer(said: &[OsString]) -> Result<String, Refusal> {
    let request = release().and_then(|root| request(said, &root)).ok_or(Refusal::NotMine)?;
    let text = crate::answer(&request)?;
    // A terminal on Windows, and whatever reads a command's output there, expects its line ends.
    Ok(if cfg!(windows) { text.replace('\n', "\r\n") } else { text })
}

/// The release this program is part of: `<release>/bin/<platform>/hotpl8-native`.
fn release() -> Option<PathBuf> {
    let program = std::env::current_exe().ok()?;
    let root = program.parent()?.parent()?.parent()?;
    root.join("hotpl8.ps1").is_file().then(|| root.to_path_buf())
}

/// The request the words spell, in the plain spellings only: the command first, then
/// parameters by their whole names. PowerShell accepts many more spellings of the same
/// request, and its entry hands those to the reader itself.
fn request(said: &[OsString], root: &Path) -> Option<Request> {
    let (command, rest) = said.split_first()?;
    let mut request = Request::new(Command::named(command.to_str()?)?, root.to_path_buf());
    // The Mac launcher names its Codex binding on every request; none of these commands reads it.
    let (mut state, mut policy, mut codex) = (None, None, None);
    let mut rest = rest.iter();
    while let Some(word) = rest.next() {
        let slot = match word.to_str()?.to_ascii_lowercase().as_str() {
            "-asjson" if !request.as_json => {
                request.as_json = true;
                continue;
            }
            "-statedirectory" => &mut state,
            "-previewpolicy" => &mut policy,
            "-codexexecutable" => &mut codex,
            _ => return None,
        };
        if slot.is_some() {
            return None;
        }
        *slot = Some(value(rest.next()?)?);
    }
    if request.command == Command::Version && (state.is_some() || policy.is_some()) {
        return None;
    }
    request.state = match state {
        Some(directory) => Some(full_path(directory)?),
        None => None,
    };
    request.policy = match policy {
        Some(file) => Some(full_path(file)?),
        None => None,
    };
    Some(request)
}

/// A word PowerShell binds to the parameter before it as it stands.
fn value(word: &OsString) -> Option<&std::ffi::OsStr> {
    // PowerShell reads any of its four dashes as the start of another parameter.
    let parameter = |first: char| matches!(first, '-' | '\u{2013}' | '\u{2014}' | '\u{2015}');
    let text = word.to_str()?;
    (!text.is_empty() && !text.starts_with(parameter)).then_some(word.as_os_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROOT: &str = if cfg!(windows) { r"C:\hotpl8" } else { "/hotpl8" };
    const STATE: &str = if cfg!(windows) { r"D:\my state" } else { "/my state" };

    fn spelled(items: &[&str]) -> Option<Request> {
        let words: Vec<OsString> = items.iter().map(OsString::from).collect();
        request(&words, Path::new(ROOT))
    }

    #[test]
    fn the_plain_spellings_are_answered() {
        assert_eq!(spelled(&["status"]), Some(Request::new(Command::Status, PathBuf::from(ROOT))));
        assert_eq!(spelled(&["VERSION", "-asjson"]).map(|request| (request.command, request.as_json)), Some((Command::Version, true)));
        let full = spelled(&["Explain", "-statedirectory", STATE, "-AsJson", "-PreviewPolicy", "policy.json", "-CodexExecutable", "codex"]).unwrap();
        assert_eq!((full.command, full.as_json, full.state), (Command::Explain, true, Some(PathBuf::from(STATE))));
        assert_eq!(full.policy, Some(std::env::current_dir().unwrap().join("policy.json")));
        assert_eq!(spelled(&["version", "-CodexExecutable", "codex"]), Some(Request::new(Command::Version, PathBuf::from(ROOT))));
        // Test-only words are never a user's.
        assert_eq!((full.now, full.dump, full.core), (None, false, !cfg!(windows)));
    }

    #[test]
    fn every_other_spelling_is_left_to_powershell() {
        for items in [
            &[][..],
            &["watch"],
            &["refresh"],
            &["stat"],
            &["-AsJson", "status"],
            &["-Command", "status"],
            &["status", "-As"],
            &["status", "-AsJson:$true"],
            &["status", "-AsJson", "-AsJson"],
            &["status", "extra"],
            &["status", "--dump"],
            &["status", "--now", "2026-09-12T12:00:00Z"],
            &["status", "-StateDirectory"],
            &["status", "-StateDirectory", ""],
            &["status", "-StateDirectory", "-AsJson"],
            &["status", "-StateDirectory", "\u{2014}state"],
            &["status", "-StateDirectory", STATE, "-statedirectory", STATE],
            &["status", "-StateDirectory:state"],
            &["status", "-Live"],
            &["status", "-Provider", "codex"],
            &["version", "-StateDirectory", STATE],
            &["version", "-PreviewPolicy", "policy.json"],
        ] {
            assert_eq!(spelled(items), None, "{items:?}");
        }
    }
}

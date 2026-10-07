//! What a start of the reader is asked, once its words are understood.

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

use crate::time::Dto;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Command {
    Version,
    Status,
    Explain,
    /// What the tray's window shows. The window asks; a user who types `tray` opens it.
    Tray,
}

impl Command {
    /// The command a word names. PowerShell, which users have always typed these to, ignores case.
    pub fn named(word: &str) -> Option<Command> {
        [("version", Command::Version), ("status", Command::Status), ("explain", Command::Explain), ("tray", Command::Tray)]
            .into_iter()
            .find_map(|(name, command)| name.eq_ignore_ascii_case(word).then_some(command))
    }
}

#[derive(Debug, PartialEq)]
pub struct Request {
    pub command: Command,
    /// The release: a checkout, or the application directory of an installation.
    pub root: PathBuf,
    /// Where the state is, when the caller says; otherwise the release knows.
    pub state: Option<PathBuf>,
    /// A policy to show the state under instead of the one in force.
    pub policy: Option<PathBuf>,
    pub as_json: bool,
    /// Numbers and durations as PowerShell 7 computes them rather than Windows PowerShell 5.1.
    /// The collector writes the state with the numbers PowerShell gave it before it was
    /// compiled, and the reader shows them the same way: 5.1 on Windows, 7 elsewhere.
    pub core: bool,
    /// Test-only: the instant to answer for instead of the clock.
    pub now: Option<Dto>,
    /// Test-only: the machine's UTC offset in minutes instead of the system's.
    pub zone: Option<i32>,
    /// Test-only: with `as_json`, the typed dump of the value instead of its JSON text.
    pub dump: bool,
}

impl Request {
    pub fn new(command: Command, root: PathBuf) -> Request {
        Request { command, root, state: None, policy: None, as_json: false, core: !cfg!(windows), now: None, zone: None, dump: false }
    }

    /// `<command> --root <dir> [--state <dir>] [--policy <file>] [-AsJson]`, as the PowerShell
    /// entry spells a request, and for tests `[--shell desktop|core] [--now <instant>] [--zone <minutes>] [--dump]`.
    pub fn explicit(arguments: &[OsString]) -> Result<Request, String> {
        Request::spelled(arguments).ok_or_else(|| {
            let words: Vec<String> = arguments.iter().map(|word| word.to_string_lossy().into_owned()).collect();
            match words.is_empty() {
                true => "The reader was started without a request.".to_owned(),
                false => format!("The reader was started with words it does not take: {}", words.join(" ")),
            }
        })
    }

    fn spelled(arguments: &[OsString]) -> Option<Request> {
        const NAMES: [&str; 6] = ["--root", "--state", "--policy", "--shell", "--now", "--zone"];
        let (command, rest) = arguments.split_first()?;
        let command = Command::named(command.to_str()?)?;
        let mut values: [Option<&OsString>; 6] = [None; 6];
        let (mut as_json, mut dump) = (false, false);
        let mut rest = rest.iter();
        while let Some(word) = rest.next() {
            let name = word.to_str()?;
            if let Some(slot) = NAMES.iter().position(|known| *known == name) {
                if values[slot].is_some() {
                    return None;
                }
                values[slot] = Some(rest.next()?);
            } else if name == "-AsJson" && !as_json {
                as_json = true;
            } else if name == "--dump" && !dump {
                dump = true;
            } else {
                return None;
            }
        }
        let mut request = Request::new(command, full_path(values[0]?)?);
        request.state = match values[1] {
            Some(directory) => Some(full_path(directory)?),
            None => None,
        };
        request.policy = match values[2] {
            Some(file) => Some(full_path(file)?),
            None => None,
        };
        request.as_json = as_json;
        request.dump = dump;
        if let Some(shell) = values[3] {
            request.core = match shell.to_str()? {
                "desktop" => false,
                "core" => true,
                _ => return None,
            };
        }
        if let Some(instant) = values[4] {
            request.now = Some(Dto::parse(instant.to_str()?).ok().filter(|at| at.offset_minutes == 0)?);
        }
        if let Some(minutes) = values[5] {
            request.zone = Some(minutes.to_str()?.parse().ok().filter(|minutes| (-840..=840).contains(minutes))?);
        }
        let reads_state = command != Command::Version;
        let for_state = request.state.is_some() || request.policy.is_some() || request.now.is_some() || request.zone.is_some() || dump;
        if (dump && !as_json) || (!reads_state && for_state) {
            return None;
        }
        Some(request)
    }
}

/// A path as the system reads it from where the reader was started, without looking at the disk.
pub fn full_path(value: &OsStr) -> Option<PathBuf> {
    std::path::absolute(Path::new(value)).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(items: &[&str]) -> Vec<OsString> {
        items.iter().map(OsString::from).collect()
    }

    const ROOT: &str = if cfg!(windows) { r"C:\hotpl8" } else { "/hotpl8" };

    #[test]
    fn a_request_names_its_command_and_release() {
        let request = Request::explicit(&words(&["status", "--root", ROOT])).unwrap();
        assert_eq!(request, Request::new(Command::Status, PathBuf::from(ROOT)));
        assert_eq!(request.core, !cfg!(windows));
        let state = if cfg!(windows) { r"D:\state" } else { "/state" };
        let full = Request::explicit(&words(&["Explain", "-AsJson", "--dump", "--now", "2026-09-12T12:00:00Z", "--zone", "-300", "--shell", "core", "--policy", state, "--state", state, "--root", ROOT])).unwrap();
        assert_eq!((full.command, full.as_json, full.dump, full.core), (Command::Explain, true, true, true));
        assert_eq!((full.state, full.policy), (Some(PathBuf::from(state)), Some(PathBuf::from(state))));
        assert!(full.now.is_some());
        assert_eq!(full.zone, Some(-300));
        assert!(!Request::explicit(&words(&["version", "--root", ROOT, "--shell", "desktop"])).unwrap().core);
    }

    #[test]
    fn paths_are_read_from_where_the_reader_was_started() {
        let here = std::env::current_dir().unwrap();
        let request = Request::explicit(&words(&["status", "--root", "release", "--state", "."])).unwrap();
        assert_eq!(request.root, here.join("release"));
        assert_eq!(request.state.unwrap().components().collect::<Vec<_>>(), here.components().collect::<Vec<_>>());
    }

    #[test]
    fn words_the_reader_does_not_take_are_named() {
        assert_eq!(Request::explicit(&[]).unwrap_err(), "The reader was started without a request.");
        for items in [
            &["status"][..],
            &["refresh", "--root", ROOT],
            &["status", "--root"],
            &["status", "--root", ""],
            &["status", "--root", ROOT, "--root", ROOT],
            &["status", "--root", ROOT, "-asjson"],
            &["status", "--root", ROOT, "-AsJson", "-AsJson"],
            &["status", "--root", ROOT, "--dump"],
            &["status", "--root", ROOT, "--shell", "Desktop"],
            &["status", "--root", ROOT, "--now", "2026-09-12T07:00:00-05:00"],
            &["status", "--root", ROOT, "--now", "noon"],
            &["version", "--root", ROOT, "--state", ROOT],
            &["version", "--root", ROOT, "--now", "2026-09-12T12:00:00Z"],
            &["version", "--root", ROOT, "--zone", "0"],
            &["status", "--root", ROOT, "--zone", "noon"],
            &["status", "--root", ROOT, "--zone", "900"],
        ] {
            let refused = Request::explicit(&words(items)).unwrap_err();
            assert_eq!(refused, format!("The reader was started with words it does not take: {}", items.join(" ")), "{items:?}");
        }
    }
}

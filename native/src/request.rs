//! What a start of the reader is asked, once its words are understood.

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

use crate::paint::Colours;
use crate::time::Dto;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Command {
    Version,
    Status,
    Explain,
    /// What the tray's window shows. The window asks; a user who types `tray` opens it.
    Tray,
    /// The dashboard, which stays open on a terminal.
    Watch,
    /// The dashboard with the cat flying across it.
    Nyan,
}

impl Command {
    /// The command a word names. PowerShell, which users have always typed these to, ignores case.
    pub fn named(word: &str) -> Option<Command> {
        [("version", Command::Version), ("status", Command::Status), ("explain", Command::Explain), ("tray", Command::Tray), ("watch", Command::Watch), ("nyan", Command::Nyan)]
            .into_iter()
            .find_map(|(name, command)| name.eq_ignore_ascii_case(word).then_some(command))
    }

    /// Whether the command opens the dashboard.
    pub fn draws(self) -> bool {
        matches!(self, Command::Watch | Command::Nyan)
    }
}

/// Test-only: one frame of the dashboard, as a terminal of that size would be given it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Shot {
    pub width: usize,
    pub height: usize,
    pub offset: usize,
    /// How long the dashboard has been open.
    pub seconds: f64,
    pub frozen: bool,
    /// As for output that is not a terminal.
    pub plain: bool,
    /// The lines with their colours, as a terminal is written them.
    pub ansi: bool,
    pub colours: Colours,
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
    /// The dashboard without movement.
    pub reduced_motion: bool,
    /// The dashboard without colours.
    pub no_color: bool,
    pub shot: Option<Shot>,
}

impl Request {
    pub fn new(command: Command, root: PathBuf) -> Request {
        Request { command, root, state: None, policy: None, as_json: false, core: !cfg!(windows), now: None, zone: None, dump: false, reduced_motion: false, no_color: false, shot: None }
    }

    /// `<command> --root <dir> [--state <dir>] [--policy <file>] [-AsJson]`, as the PowerShell
    /// entry spells a request, and for tests `[--shell desktop|core] [--now <instant>] [--zone <minutes>] [--dump]`.
    /// The dashboard takes `[--reduced-motion] [--no-color]` instead of `-AsJson`, and for
    /// tests `--size <columns>x<rows> [--offset <rows>] [--at <seconds>] [--frozen] [--plain] [--ansi] [--colours true|indexed]`.
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
        const NAMES: [&str; 10] = ["--root", "--state", "--policy", "--shell", "--now", "--zone", "--size", "--offset", "--at", "--colours"];
        const FLAGS: [&str; 7] = ["-AsJson", "--dump", "--reduced-motion", "--no-color", "--frozen", "--plain", "--ansi"];
        let (command, rest) = arguments.split_first()?;
        let command = Command::named(command.to_str()?)?;
        let mut values: [Option<&OsString>; 10] = [None; 10];
        let mut flags = [false; 7];
        let mut rest = rest.iter();
        while let Some(word) = rest.next() {
            let name = word.to_str()?;
            if let Some(slot) = NAMES.iter().position(|known| *known == name) {
                if values[slot].is_some() {
                    return None;
                }
                values[slot] = Some(rest.next()?);
            } else {
                let flag = FLAGS.iter().position(|known| *known == name).filter(|flag| !flags[*flag])?;
                flags[flag] = true;
            }
        }
        let [as_json, dump, reduced_motion, no_color, frozen, plain, ansi] = flags;
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
        (request.reduced_motion, request.no_color) = (reduced_motion, no_color);
        let number = |value: Option<&OsString>| value.map_or(Some(0), |text| text.to_str()?.parse::<usize>().ok());
        let mut shot = None;
        if let Some(size) = values[6] {
            let (width, height) = size.to_str()?.split_once('x')?;
            let seconds = match values[8] {
                Some(seconds) => seconds.to_str()?.parse::<f64>().ok().filter(|seconds| seconds.is_finite() && *seconds >= 0.0)?,
                None => 0.0,
            };
            let colours = match values[9].map(|name| name.to_str()) {
                None | Some(Some("true")) => Colours::True,
                Some(Some("indexed")) => Colours::Indexed,
                _ => return None,
            };
            shot = Some(Shot { width: width.parse().ok()?, height: height.parse().ok()?, offset: number(values[7])?, seconds, frozen, plain, ansi, colours });
        }
        let for_shot = values[7].is_some() || values[8].is_some() || values[9].is_some() || frozen || plain || ansi;
        let for_dashboard = reduced_motion || no_color || shot.is_some();
        if (for_shot && shot.is_none()) || (plain && ansi) || (for_dashboard && !command.draws()) || (command.draws() && as_json) {
            return None;
        }
        request.shot = shot;
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
    fn the_dashboard_is_asked_for_as_a_terminal_or_as_one_frame() {
        let open = Request::explicit(&words(&["nyan", "--root", ROOT, "--no-color", "--reduced-motion"])).unwrap();
        assert_eq!((open.command, open.reduced_motion, open.no_color, open.shot), (Command::Nyan, true, true, None));
        assert!(Command::Watch.draws() && Command::Nyan.draws() && !Command::Tray.draws());
        let frame = Request::explicit(&words(&["Watch", "--root", ROOT, "--size", "100x40"])).unwrap();
        assert_eq!(frame.shot, Some(Shot { width: 100, height: 40, offset: 0, seconds: 0.0, frozen: false, plain: false, ansi: false, colours: Colours::True }));
        let full = Request::explicit(&words(&["watch", "--root", ROOT, "--size", "66x20", "--offset", "3", "--at", "1.25", "--frozen", "--ansi", "--colours", "indexed"])).unwrap();
        assert_eq!(full.shot, Some(Shot { width: 66, height: 20, offset: 3, seconds: 1.25, frozen: true, plain: false, ansi: true, colours: Colours::Indexed }));
        assert!(Request::explicit(&words(&["watch", "--root", ROOT, "--size", "66x20", "--plain"])).unwrap().shot.unwrap().plain);
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
            &["status", "--root", ROOT, "--no-color"],
            &["status", "--root", ROOT, "--size", "100x40"],
            &["watch", "--root", ROOT, "-AsJson"],
            &["watch", "--root", ROOT, "--frozen"],
            &["watch", "--root", ROOT, "--offset", "3"],
            &["watch", "--root", ROOT, "--size", "100"],
            &["watch", "--root", ROOT, "--size", "100x-4"],
            &["watch", "--root", ROOT, "--size", "100x40", "--at", "soon"],
            &["watch", "--root", ROOT, "--size", "100x40", "--at", "-1"],
            &["watch", "--root", ROOT, "--size", "100x40", "--colours", "many"],
            &["watch", "--root", ROOT, "--size", "100x40", "--plain", "--ansi"],
            &["watch", "--root", ROOT, "--no-color", "--no-color"],
        ] {
            let refused = Request::explicit(&words(items)).unwrap_err();
            assert_eq!(refused, format!("The reader was started with words it does not take: {}", items.join(" ")), "{items:?}");
        }
    }
}

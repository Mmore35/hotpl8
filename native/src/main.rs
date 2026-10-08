//! HotPl8's compiled program: the reader (`version`, `status`, `explain` and the dashboard,
//! `watch` and `nyan`) and the collector (`collect`, one wake).
//!
//! These are implemented here and nowhere else. A launcher hands the reader the words the
//! user typed (`user`, in door.rs); the PowerShell entry, which has the rest of HotPl8, hands
//! it a request it has already understood (request.rs). Either way the answer printed is this
//! program's. The scheduler starts the collector (`wake`, in door.rs, and wake.rs). The
//! contract is docs/plans/rust-read-side.md.

mod activity;
mod automation;
mod capacity;
mod claude;
mod claude_tick;
mod codex;
mod codex_collect;
mod codex_read;
mod collection;
mod contract;
mod control;
mod critical;
mod cswap;
mod dashboard;
mod decision;
mod display;
mod door;
mod files;
mod forecast;
mod insights;
mod json;
mod lane;
mod launch;
mod num;
mod nyan;
mod observation;
mod overview;
mod paint;
mod pause;
mod phase;
mod plans;
mod policy;
mod process;
mod ps;
mod registry;
mod replay;
mod request;
mod route;
mod runtime;
mod selection;
mod sha256;
mod terminal;
mod time;
mod tray;
mod version;
mod wake;
mod warming;
mod watch;

use std::ffi::OsString;
use std::io::Write;
use std::path::Path;
use std::process::ExitCode;

use crate::ps::{Stop, R};
use crate::request::{Command, Request};

/// Exit status for words that are not a request the reader owns: the launcher starts the
/// PowerShell entry with them. Only the front door answers so.
const NOT_MINE: u8 = 64;
const FAILED: u8 = 1;
/// Exit status of a dashboard that ended for another release's to be opened in its place.
const HANDED_OFF: u8 = 75;

/// Why a start of the reader printed no answer.
#[derive(Debug)]
pub enum Refusal {
    /// The front door was given words for another part of HotPl8.
    NotMine,
    /// The reader was started with words it does not take.
    Misspelled(String),
    /// The request was understood and could not be answered.
    Stopped(Stop),
}

impl From<Stop> for Refusal {
    fn from(stop: Stop) -> Refusal {
        Refusal::Stopped(stop)
    }
}

impl Refusal {
    /// What the user is told, after HotPl8's name.
    fn said(&self) -> String {
        match self {
            Refusal::NotMine => String::new(),
            Refusal::Misspelled(words) => words.clone(),
            Refusal::Stopped(stop) => stop.message(),
        }
    }
    /// What a batch calls it. `ruled` is a refusal in words HotPl8 has always used, which
    /// the parity suite holds to PowerShell's; `stopped` is any other.
    fn kind(&self) -> &'static str {
        match self {
            Refusal::NotMine => "not-mine",
            Refusal::Misspelled(_) => "misspelled",
            Refusal::Stopped(stop) if stop.ruled() => "ruled",
            Refusal::Stopped(_) => "stopped",
        }
    }
}

fn main() -> ExitCode {
    let arguments: Vec<OsString> = std::env::args_os().skip(1).collect();
    if let [command, file] = arguments.as_slice() {
        if command == "batch" {
            return batch(Path::new(file));
        }
    }
    // The scheduler's start: the release in force is woken, whichever this program is part of.
    if let Some((_, words)) = arguments.split_first().filter(|(command, _)| *command == "wake") {
        return ExitCode::from(door::woken(words));
    }
    // A launcher's start for an installation it names: the release in force is asked.
    if let Some((_, words)) = arguments.split_first().filter(|(command, _)| *command == "ask") {
        return ExitCode::from(door::asked(words));
    }
    // A wake prints what it did, and never an answer a reader would.
    if let Some((_, words)) = arguments.split_first().filter(|(command, _)| *command == "collect") {
        return match wake::started(words) {
            Ok(true) => ExitCode::SUCCESS,
            Ok(false) => ExitCode::from(FAILED),
            Err(why) => {
                let _ = writeln!(std::io::stderr().lock(), "HotPl8: {}", ps::safe_text(&why));
                ExitCode::from(FAILED)
            }
        };
    }
    // A route answers its caller's pipe with one line, and that line is all it prints.
    if let Some((_, words)) = arguments.split_first().filter(|(command, _)| *command == "route") {
        return match route::started(words) {
            Ok(true) => ExitCode::SUCCESS,
            Ok(false) => ExitCode::from(FAILED),
            Err(why) => {
                let _ = writeln!(std::io::stderr().lock(), "HotPl8: {}", ps::safe_text(&why));
                ExitCode::from(FAILED)
            }
        };
    }
    // A launch is the user's own terminal handed to Codex, and ends as Codex ends: a status
    // of any size, which `ExitCode` cannot carry.
    if let Some((_, words)) = arguments.split_first().filter(|(command, _)| *command == "codex") {
        match launch::started(words) {
            Ok(status) => std::process::exit(status),
            Err(why) => {
                let line = format!("HotPl8: {}{}", ps::safe_text(&why), if cfg!(windows) { "\r\n" } else { "\n" });
                let mut stderr = std::io::stderr().lock();
                let _ = stderr.write_all(&door::bytes_for(&line, &stderr));
                return ExitCode::from(FAILED);
            }
        }
    }
    // The PowerShell entry reads UTF-8 from the reader. A launcher's start is the user's own,
    // and its streams are written to as door.rs says.
    let user = arguments.first().is_some_and(|word| word == "user");
    if user {
        if let Some(status) = door::relayed(&arguments[1..]) {
            return ExitCode::from(status);
        }
    }
    // Written, not `eprintln!`: a closed stream must not turn a refusal into a crash.
    let complain = |why: String| {
        // A user on Windows is given its line end, as for an answer.
        let end = if user && cfg!(windows) { "\r\n" } else { "\n" };
        let line = format!("HotPl8: {}{end}", ps::safe_text(&why));
        let mut stderr = std::io::stderr().lock();
        let bytes = if user { door::bytes_for(&line, &stderr) } else { line.as_bytes().into() };
        let _ = stderr.write_all(&bytes);
        ExitCode::from(FAILED)
    };
    // With someone at a terminal the dashboard stays open on it. Anything else is given one
    // frame of it below, as an answer.
    if terminal::attended() {
        let asked = match user {
            true => door::dashboard(&arguments[1..]),
            false => Request::explicit(&arguments).ok().filter(|request| request.command.draws() && request.shot.is_none()),
        };
        match asked.as_ref().map(watch::open) {
            Some(Ok(Some(status))) => return ExitCode::from(status),
            Some(Err(stop)) => return complain(stop.message()),
            Some(Ok(None)) | None => {}
        }
    }
    match respond(&arguments) {
        Ok(output) => {
            let mut stdout = std::io::stdout().lock();
            let bytes = if user { door::bytes_for(&output, &stdout) } else { output.as_bytes().into() };
            // A caller that received part of an answer must not use it.
            if stdout.write_all(&bytes).is_err() || stdout.flush().is_err() {
                return ExitCode::from(FAILED);
            }
            ExitCode::SUCCESS
        }
        Err(Refusal::NotMine) => ExitCode::from(NOT_MINE),
        Err(refusal) => complain(refusal.said()),
    }
}

fn respond(arguments: &[OsString]) -> Result<String, Refusal> {
    match arguments.split_first() {
        Some((word, said)) if word == "user" => door::answer(said),
        Some((word, [])) if word == "self-check" => Ok(self_check(option_env!("HOTPL8_BUILD_SHA"))),
        _ => Ok(answer(&Request::explicit(arguments).map_err(Refusal::Misspelled)?)?),
    }
}

pub fn answer(request: &Request) -> R<String> {
    match request.command {
        Command::Version => version::answer(request),
        Command::Status | Command::Explain | Command::Tray | Command::Watch | Command::Nyan => display::answer(request),
    }
}

/// The commit this program was built from, for whoever must know which reader it holds.
fn self_check(build_sha: Option<&str>) -> String {
    format!("hotpl8-native sha={}\n", build_sha.filter(|sha| is_commit(sha)).unwrap_or("unknown"))
}

/// A commit as HotPl8 names one: forty lowercase hexadecimal digits.
fn is_commit(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// Test-only: every request in a file, answered by one start of this program. Comparing a
/// thousand answers with PowerShell's must not cost a thousand program starts.
fn batch(file: &Path) -> ExitCode {
    let Some(requests) = std::fs::read(file).ok().and_then(|bytes| batch_requests(&bytes)) else {
        let _ = writeln!(std::io::stderr().lock(), "HotPl8: The batch is not a file of requests.");
        return ExitCode::from(FAILED);
    };
    match answer_each(&requests, &mut std::io::stdout().lock(), respond) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::from(FAILED),
    }
}

/// One request per line: a JSON array holding the words of an ordinary start.
fn batch_requests(bytes: &[u8]) -> Option<Vec<Vec<OsString>>> {
    let text = std::str::from_utf8(bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes)).ok()?;
    text.lines().filter(|line| !line.is_empty()).map(|line| Some(json::strings(line)?.into_iter().map(OsString::from).collect())).collect()
}

/// Each answer as `<kind> <bytes>` on a line of its own, then that many bytes: the output for
/// `answer`, and for a refusal what the user would be told. Every answer is flushed, so a
/// request that ends the program is the one after the last answer received.
fn answer_each(requests: &[Vec<OsString>], out: &mut impl Write, respond: impl Fn(&[OsString]) -> Result<String, Refusal>) -> std::io::Result<()> {
    for arguments in requests {
        let (kind, text) = match respond(arguments) {
            Ok(output) => ("answer", output),
            Err(refusal) => (refusal.kind(), refusal.said()),
        };
        writeln!(out, "{kind} {}", text.len())?;
        out.write_all(text.as_bytes())?;
        out.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

    fn words(items: &[&str]) -> Vec<OsString> {
        items.iter().map(OsString::from).collect()
    }

    #[test]
    fn self_check_names_the_commit_the_reader_was_built_from() {
        assert_eq!(self_check(Some(SHA)), format!("hotpl8-native sha={SHA}\n"));
        for unknown in [None, Some("not-a-commit"), Some(&*SHA.to_uppercase())] {
            assert_eq!(self_check(unknown), "hotpl8-native sha=unknown\n");
        }
        assert!(respond(&words(&["self-check"])).is_ok_and(|line| line.starts_with("hotpl8-native sha=")));
        assert!(matches!(respond(&words(&["self-check", "extra"])), Err(Refusal::Misspelled(_))));
    }

    #[test]
    fn a_refusal_says_whose_it_is() {
        let root = std::env::temp_dir().join(format!("hotpl8-native-refusal-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let place = root.to_str().unwrap();
        let told = |items: &[&str]| respond(&words(items)).map_err(|refusal| (refusal.kind(), refusal.said()));
        assert_eq!(told(&["refresh"]), Err(("misspelled", "The reader was started with words it does not take: refresh".to_owned())));
        assert_eq!(told(&[]), Err(("misspelled", "The reader was started without a request.".to_owned())));
        // The test program is no release, so the front door has nothing to answer from.
        assert_eq!(told(&["user", "status"]), Err(("not-mine", String::new())));
        assert_eq!(told(&["user"]), Err(("not-mine", String::new())));
        assert_eq!(told(&["user", "nyan", "-StateDirectory", place]), Err(("not-mine", String::new())));
        assert_eq!(told(&["version", "--root", place]), Err(("stopped", "This copy of HotPl8 has no VERSION file.".to_owned())));
        assert_eq!(told(&["status", "--root", place, "--state", place]), Err(("ruled", "No valid policy.json. Run hotpl8 setup or see docs/install.md.".to_owned())));
        std::fs::write(root.join("policy.json"), "{\"mode\":\"sideways\"}").unwrap();
        assert_eq!(told(&["explain", "--root", place, "--state", place]), Err(("ruled", "Invalid policy: mode must be monitor or automate.".to_owned())));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_batch_answers_each_request_as_a_start_of_its_own_would() {
        let root = std::env::temp_dir().join(format!("hotpl8-native-batch-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("VERSION"), "1.4.0\n").unwrap();
        let version = format!("[\"version\", \"--root\", {:?}]", root.to_str().unwrap());
        // A batch inside a batch is words the reader does not take, like any other.
        let file = format!("\u{feff}{version}\n[\"batch\",\"requests\"]\r\n\n[\"user\",\"refresh\"]\n{version}");
        let requests = batch_requests(file.as_bytes()).unwrap();
        assert_eq!(requests.len(), 4);
        let mut out = Vec::new();
        answer_each(&requests, &mut out, respond).unwrap();
        let misspelled = "The reader was started with words it does not take: batch requests";
        assert_eq!(String::from_utf8(out).unwrap(), format!("answer 6\n1.4.0\nmisspelled {}\n{misspelled}not-mine 0\nanswer 6\n1.4.0\n", misspelled.len()));
        std::fs::remove_dir_all(&root).unwrap();
        for file in ["{}", "[1]", "[\"version\"", "\"version\"", "[\"a\"]\nnot json", "[\"a\"] [\"b\"]"] {
            assert!(batch_requests(file.as_bytes()).is_none(), "{file}");
        }
        assert!(batch_requests(b"").is_some_and(|requests| requests.is_empty()));
        assert!(batch_requests(b"\xff").is_none());
    }
}

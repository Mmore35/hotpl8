//! The front door: the words a user typed after `hotpl8`, answered without starting
//! PowerShell when they spell a request the reader owns. Everything else is not this
//! program's to refuse: the launcher starts the PowerShell entry with the same words.

use std::borrow::Cow;
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

/// The exit status of the release in force, asked the same words, when this program is the
/// copy an installation that updates itself keeps beside its launcher (delivery/launch.cmd).
/// That copy answers nothing itself, so it is never stale: it is `None` everywhere else.
#[cfg(windows)]
pub fn relayed(said: &[OsString]) -> Option<u8> {
    let program = std::env::current_exe().ok()?;
    let installation = program.parent()?;
    if !installation.join("current.json").is_file() {
        return None;
    }
    let status = held(installation, said).and_then(|(lease, reader, state)| {
        let child = std::process::Command::new(reader).arg("user").args(said).env("HOTPL8_STATE_DIRECTORY", state).env("HOTPL8_INSTALL_DIRECTORY", installation).status();
        // The release stays in place until its reader has ended.
        drop(lease);
        child.ok()?.code()
    });
    // Whatever is out of the ordinary is launch.ps1's to report, in the words it has for it.
    Some(match status {
        Some(0) => 0,
        Some(1) => crate::FAILED,
        _ => crate::NOT_MINE,
    })
}
#[cfg(not(windows))]
pub fn relayed(_said: &[OsString]) -> Option<u8> {
    None
}

/// The exit status of one scheduled wake of the release in force of an installation that
/// updates itself: what its scheduler starts every minute. With no words this program is the
/// copy beside the installation's launcher, as Windows keeps one. A Mac keeps none, and its
/// job starts the release's own program with the installation named first and, after it,
/// what the collector is told besides. An update in progress is no failure, and the wake
/// after it collects.
pub fn woken(said: &[OsString]) -> u8 {
    let program = std::env::current_exe().ok();
    let (installation, told) = match said.split_first() {
        Some((named, told)) => (Some(Path::new(named)), Some(told)),
        None => (program.as_deref().and_then(Path::parent), None),
    };
    let Some(installation) = installation else { return crate::FAILED };
    match in_force(installation) {
        None => crate::FAILED,
        Some(InForce::Updating) => 0,
        Some(InForce::Release { lease, root, state }) => {
            let Some(mut collector) = collector_of(&root, &state, told) else { return 0 };
            let child = collector.env("HOTPL8_STATE_DIRECTORY", &state).env("HOTPL8_INSTALL_DIRECTORY", installation).status();
            // The release stays in place until its collector has ended.
            drop(lease);
            child.ok().and_then(|status| status.code()).map_or(crate::FAILED, |code| u8::try_from(code).unwrap_or(crate::FAILED))
        }
    }
}

/// One scheduled wake of a release, told what the job that named the installation said.
/// Every release whose collector is compiled has src/lane.ps1. A release from before that
/// can come back into force by a rollback, and its collector is its tick.ps1: the copy
/// beside a launcher starts it as delivery/launch.ps1 does. A job that named the
/// installation is the release's own, so it meets such a release only when an update came
/// between its choice and the lease. That release's own job wakes it a minute later: `None`.
fn collector_of(release: &Path, state: &str, told: Option<&[OsString]>) -> Option<std::process::Command> {
    if release.join("src").join("lane.ps1").is_file() {
        let mut compiled = std::process::Command::new(reader_of(release));
        compiled.arg("collect").arg("--root").arg(release).arg("--state").arg(state).arg("--scheduled").args(told.unwrap_or_default());
        return Some(compiled);
    }
    if told.is_some() {
        return None;
    }
    let mut script = std::process::Command::new(crate::lane::powershell(None));
    script.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]).arg(release.join("tick.ps1")).args(["-Scheduled", "-StateDirectory", state]);
    Some(script)
}

/// What an installation that updates itself has in force.
enum InForce {
    /// An update holds the installation alone.
    Updating,
    /// The lease an update waits for, the release, and the state directory it is told to use.
    Release { lease: std::fs::File, root: PathBuf, state: String },
}

fn reader_of(release: &Path) -> PathBuf {
    let platform = release.join("bin").join(if cfg!(windows) { "windows" } else { "macos" });
    platform.join(if cfg!(windows) { "hotpl8-native.exe" } else { "hotpl8-native" })
}

/// The lease every command in progress holds on an installation together. An update holds
/// the file alone, and then there is none.
fn leased(path: &Path) -> Option<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(3);
    }
    let file = options.open(path).ok()?;
    // Off Windows .NET holds an advisory lock on the open file, shared or alone; so does this.
    #[cfg(not(windows))]
    file.try_lock_shared().ok()?;
    Some(file)
}

/// What delivery/launch.ps1 does before it starts a release. `None` is an installation that
/// cannot say which release is in force.
fn in_force(installation: &Path) -> Option<InForce> {
    let text = |file: &str, name: &str| Some(crate::json::read_file(&installation.join(file)).ok()??.g(name).ok()?.as_str()?.to_owned());
    let state = text("delivery.json", "stateDirectory")?;
    let Some(lease) = leased(&installation.join("runtime.lock")) else { return Some(InForce::Updating) };
    let sha = text("current.json", "sha")?;
    if !crate::is_commit(&sha) || text("current.json", "release")? != format!("releases/{sha}") {
        return None;
    }
    Some(InForce::Release { lease, root: installation.join("releases").join(sha), state })
}

/// For the requests the reader owns: the lease, the reader of the release in force, and the
/// state directory that release is told to use.
#[cfg(windows)]
fn held(installation: &Path, said: &[OsString]) -> Option<(std::fs::File, PathBuf, String)> {
    // Only words the reader owns go past PowerShell. The release's own reader reads them
    // again, so this copy may be older or newer than the release.
    request(said, installation)?;
    match in_force(installation)? {
        InForce::Release { lease, root, state } => Some((lease, reader_of(&root), state)),
        InForce::Updating => None,
    }
}

/// The bytes a stream of this start is given for `text`. Windows PowerShell writes to a file
/// or a pipe in the console's code page, and whatever read HotPl8's output from one before
/// reads it the same way now. A console is given the text as it is.
#[cfg(windows)]
pub fn bytes_for<'a>(text: &'a str, stream: &impl std::os::windows::io::AsRawHandle) -> Cow<'a, [u8]> {
    #[link(name = "kernel32")]
    extern "system" {
        fn GetConsoleMode(console: *mut core::ffi::c_void, mode: *mut u32) -> i32;
        fn GetConsoleOutputCP() -> u32;
        fn WideCharToMultiByte(page: u32, flags: u32, wide: *const u16, units: i32, bytes: *mut u8, capacity: i32, default: *const u8, used_default: *mut i32) -> i32;
    }
    const UTF8: u32 = 65001;
    let plain = Cow::Borrowed(text.as_bytes());
    if text.is_ascii() {
        return plain;
    }
    let mut mode = 0;
    // SAFETY: the handle is one of this process's own streams and `mode` is a live u32; the
    // call fails, and writes nothing, for a handle that is no console.
    if unsafe { GetConsoleMode(stream.as_raw_handle(), &mut mode) } != 0 {
        return plain;
    }
    // SAFETY: takes no arguments. Without a console it gives 0, which the conversion below
    // reads as the system's own page, as PowerShell does.
    let page = unsafe { GetConsoleOutputCP() };
    if page == UTF8 {
        return plain;
    }
    let wide: Vec<u16> = text.encode_utf16().collect();
    let Ok(units) = i32::try_from(wide.len()) else { return plain };
    // SAFETY: `wide` holds `units` units, and no buffer with no capacity asks for the size.
    let size = unsafe { WideCharToMultiByte(page, 0, wide.as_ptr(), units, core::ptr::null_mut(), 0, core::ptr::null(), core::ptr::null_mut()) };
    let Ok(length) = usize::try_from(size) else { return plain };
    let mut bytes = vec![0u8; length];
    // SAFETY: `bytes` holds `size` bytes, the size the same call asked for a moment ago.
    let written = unsafe { WideCharToMultiByte(page, 0, wide.as_ptr(), units, bytes.as_mut_ptr(), size, core::ptr::null(), core::ptr::null_mut()) };
    if written != size || size == 0 {
        return plain;
    }
    Cow::Owned(bytes)
}
#[cfg(not(windows))]
pub fn bytes_for<'a, S>(text: &'a str, _stream: &S) -> Cow<'a, [u8]> {
    Cow::Borrowed(text.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROOT: &str = if cfg!(windows) { r"C:\hotpl8" } else { "/hotpl8" };
    const STATE: &str = if cfg!(windows) { r"D:\my state" } else { "/my state" };

    fn words(items: &[&str]) -> Vec<OsString> {
        items.iter().map(OsString::from).collect()
    }

    fn spelled(items: &[&str]) -> Option<Request> {
        request(&words(items), Path::new(ROOT))
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

    #[cfg(windows)]
    #[test]
    fn an_installation_that_updates_itself_names_the_release_in_force() {
        use std::os::windows::fs::OpenOptionsExt;
        const SHA: &str = "0123456789abcdef0123456789abcdef01234567";
        let root = std::env::temp_dir().join(format!("hotpl8-native-relay-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let pointer = |sha: &str, release: &str| std::fs::write(root.join("current.json"), format!("{{\"protocol\":1,\"sha\":\"{sha}\",\"release\":\"{release}\"}}")).unwrap();
        let found = |items: &[&str]| held(&root, &words(items)).map(|(_, reader, state)| (reader, state));
        std::fs::write(root.join("delivery.json"), "{\"stateDirectory\":\"D:\\\\my state\"}").unwrap();
        pointer(SHA, &format!("releases/{SHA}"));
        // Words for the rest of HotPl8 go to launch.ps1 before anything is opened.
        for items in [&["refresh"][..], &["status", "-Live"], &["-Command", "status"], &[]] {
            assert_eq!(found(items), None, "{items:?}");
        }
        assert!(!root.join("runtime.lock").exists());
        let reader = root.join("releases").join(SHA).join("bin").join("windows").join("hotpl8-native.exe");
        assert_eq!(found(&["status", "-AsJson"]), Some((reader, STATE.to_owned())));
        // Two commands hold the lease together; an update holds it alone.
        let first = held(&root, &words(&["explain"])).unwrap();
        assert!(found(&["version"]).is_some());
        drop(first);
        let update = std::fs::OpenOptions::new().read(true).write(true).share_mode(0).open(root.join("runtime.lock")).unwrap();
        assert_eq!(found(&["status"]), None);
        drop(update);
        for (sha, release) in [("main", "releases/main".to_owned()), (SHA, "releases/other".to_owned()), (&*SHA.to_uppercase(), format!("releases/{}", SHA.to_uppercase()))] {
            pointer(sha, &release);
            assert_eq!(found(&["status"]), None, "{sha} {release}");
        }
        std::fs::write(root.join("current.json"), "not a pointer").unwrap();
        assert_eq!(found(&["status"]), None);
        std::fs::remove_file(root.join("delivery.json")).unwrap();
        pointer(SHA, &format!("releases/{SHA}"));
        assert_eq!(found(&["status"]), None);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_wake_holds_an_installation_with_other_commands_and_never_with_an_update() {
        const SHA: &str = "0123456789abcdef0123456789abcdef01234567";
        let root = crate::files::tests::scratch("wake-lease");
        let pointer = |sha: &str, release: &str| std::fs::write(root.join("current.json"), format!("{{\"protocol\":1,\"sha\":\"{sha}\",\"release\":\"{release}\"}}")).unwrap();
        let release = |found: Option<InForce>| match found {
            Some(InForce::Release { lease, root, state }) => Some((lease, root, state)),
            _ => None,
        };
        // An installation that does not say where its state is has nothing in force.
        pointer(SHA, &format!("releases/{SHA}"));
        assert!(in_force(&root).is_none());
        assert!(!root.join("runtime.lock").exists());
        std::fs::write(root.join("delivery.json"), crate::json::compact(&crate::obj! { "stateDirectory" => STATE }, 4).unwrap()).unwrap();
        let first = release(in_force(&root)).unwrap();
        assert_eq!((first.1.clone(), first.2.as_str()), (root.join("releases").join(SHA), STATE));
        // As [IO.File]::Open(...,'None') and the updater's lock hold it: alone, or not at all.
        assert!(matches!(crate::files::lock(&root.join("runtime.lock")), Err(crate::files::Unlocked::Busy)));
        let second = release(in_force(&root)).unwrap();
        drop((first, second));
        let update = crate::files::lock(&root.join("runtime.lock")).ok().unwrap();
        assert!(matches!(in_force(&root), Some(InForce::Updating)));
        drop(update);
        for (sha, named) in [("main", "releases/main".to_owned()), (SHA, "releases/other".to_owned()), (&*SHA.to_uppercase(), format!("releases/{}", SHA.to_uppercase()))] {
            pointer(sha, &named);
            assert!(in_force(&root).is_none(), "{sha} {named}");
        }
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_wake_starts_the_collector_the_release_has() {
        let release = crate::files::tests::scratch("wake-collector");
        std::fs::create_dir_all(release.join("src")).unwrap();
        let started = |told: Option<&[&str]>| {
            let told = told.map(words);
            let command = collector_of(&release, STATE, told.as_deref())?;
            Some((PathBuf::from(command.get_program()), command.get_args().map(|word| word.to_string_lossy().into_owned()).collect::<Vec<_>>()))
        };
        let path = |file: PathBuf| file.to_string_lossy().into_owned();
        // A release from before the collector was compiled: the copy beside a launcher starts
        // its tick.ps1, and a job that named the installation leaves it to that release's own.
        let (program, said) = started(None).unwrap();
        assert!(program.ends_with(if cfg!(windows) { r"System32\WindowsPowerShell\v1.0\powershell.exe" } else { "pwsh" }), "{program:?}");
        assert_eq!(said, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", &path(release.join("tick.ps1")), "-Scheduled", "-StateDirectory", STATE]);
        assert!(started(Some(&[])).is_none());
        assert!(started(Some(&["--observe-only"])).is_none());
        std::fs::write(release.join("src").join("lane.ps1"), "").unwrap();
        let compiled = release.join("bin").join(if cfg!(windows) { "windows" } else { "macos" }).join(if cfg!(windows) { "hotpl8-native.exe" } else { "hotpl8-native" });
        let collect = ["collect", "--root", &path(release.clone()), "--state", STATE, "--scheduled"];
        assert_eq!(started(None), Some((compiled.clone(), collect.map(str::to_owned).to_vec())));
        assert_eq!(started(Some(&[])), Some((compiled.clone(), collect.map(str::to_owned).to_vec())));
        let told = ["--powershell", "/opt/pw sh", "--codex", "/opt/codex", "--observe-only"];
        assert_eq!(started(Some(&told)), Some((compiled, collect.iter().chain(&told).map(|word| (*word).to_owned()).collect())));
        std::fs::remove_dir_all(&release).unwrap();
    }

    #[test]
    fn text_in_ascii_is_written_as_it_is() {
        assert!(matches!(bytes_for("5h 62% remaining\r\n", &std::io::stdout()), Cow::Borrowed(bytes) if bytes == b"5h 62% remaining\r\n"));
    }
}

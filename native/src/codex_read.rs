//! One Codex account, read through the program Codex ships: it is started in the account's
//! own home and asked over its standard streams who is signed in, what the limits say and
//! how it is set up. Signing in stays Codex's business. Nothing here refreshes a sign-in,
//! and no token is kept, printed or passed on.

use crate::cswap::runnable;
use crate::files;
use crate::json;
use crate::policy::home_path;
use crate::process::Running;
use crate::ps::*;
use crate::request::full_path;
use crate::sha256;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Get-CodexReadBudgetMs. A healthy read takes 2-4 s; on a machine with every core busy
/// the program alone can take 5 s to start, and a tighter bound called every account
/// unavailable.
pub const READ_BUDGET_MS: u64 = 12_000;

/// The longest line of an answer, in UTF-16 units, which is how PowerShell counted it.
const LINE_LIMIT: usize = 1_048_576;

/// What the program must not be handed: a key or token in these would replace the
/// account's own sign-in, and the last would move its state out of the home.
const WITHHELD: [&str; 4] = ["CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_SQLITE_HOME"];

/// What one account answered.
pub struct Account {
    /// The limits, as Codex words them.
    pub quota: V,
    /// A name for the subscription that says nothing about it. It changes when another
    /// subscription signs in to this home, and is never shown.
    pub identity_key: String,
    pub plan_type: String,
    pub model: String,
    pub model_provider: String,
    /// Requests go to the subscription's own service, not to an address the user set.
    pub standard_transport: bool,
}

/// One read of one home: how long it took, and the account or the name of what failed.
pub struct HomeRead {
    pub elapsed_ms: i64,
    pub outcome: Result<Account, &'static str>,
}

/// Where a Codex program is looked for when none is named.
pub struct Search {
    /// The program HotPl8's own setup installed.
    pub managed: Option<PathBuf>,
    /// The directories of PATH, in order.
    pub path: Vec<PathBuf>,
    /// What may follow `codex` in a command's name: nothing, and on Windows the endings
    /// the shell runs.
    pub endings: Vec<String>,
    /// Where a package manager keeps what no directory of PATH holds.
    pub libraries: Vec<PathBuf>,
    /// This machine's programs are ARM programs.
    pub arm: bool,
}

/// The files named `name` under `directory`. A link to a directory is not followed.
fn named_files(directory: &Path, name: &str, depth: usize, found: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(directory) else { return };
    for entry in entries.flatten() {
        let (path, Ok(kind)) = (entry.path(), entry.file_type()) else { continue };
        if kind.is_dir() {
            if depth < 16 {
                named_files(&path, name, depth + 1, found);
            }
        } else if path.is_file() && entry.file_name().to_str().is_some_and(|known| if cfg!(windows) { known.eq_ignore_ascii_case(name) } else { known == name }) {
            found.push(path);
        }
    }
}

impl Search {
    /// What this machine and this start of the program offer.
    pub fn here() -> Search {
        let set = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
        let binary = if cfg!(windows) { "codex.exe" } else { "codex" };
        let mut endings = vec![String::new()];
        if cfg!(windows) {
            let known = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
            endings.extend(known.split(';').filter(|ending| !ending.is_empty()).map(str::to_ascii_lowercase));
            endings.push(".ps1".into());
        }
        Search {
            managed: set("HOTPL8_NATIVE_BIN").map(|directory| PathBuf::from(directory).join(binary)),
            path: set("PATH").map(|path| std::env::split_paths(&path).filter(|directory| directory.is_absolute()).collect()).unwrap_or_default(),
            endings,
            libraries: if cfg!(windows) { Vec::new() } else { vec!["/usr/local/lib".into(), "/opt/homebrew/lib".into()] },
            arm: cfg!(target_arch = "aarch64") || std::env::var("PROCESSOR_ARCHITECTURE").is_ok_and(|kind| kind.eq_ignore_ascii_case("ARM64")),
        }
    }

    /// Resolve-CodexExecutable: the program named; else the one HotPl8 installed; else the
    /// first `codex.exe` PATH holds; else the one program for this machine inside the
    /// package a `codex` command of PATH belongs to. A script is never started in its
    /// place: the shell that would run it reads the words it is given.
    pub fn program(&self, named: Option<&str>) -> Result<PathBuf, &'static str> {
        if let Some(named) = named.filter(|named| !named.is_empty()) {
            let path = Path::new(named);
            if !path.is_file() {
                return Err("codex_missing");
            }
            let ending = path.extension().and_then(|ending| ending.to_str()).unwrap_or("").to_ascii_lowercase();
            if ["cmd", "bat", "ps1"].contains(&ending.as_str()) {
                return Err("native_codex_required");
            }
            return full_path(path.as_os_str()).ok_or("codex_missing");
        }
        if let Some(managed) = self.managed.as_ref().filter(|managed| managed.is_file()) {
            return Ok(managed.clone());
        }
        if let Some(found) = self.path.iter().map(|directory| directory.join("codex.exe")).find(|candidate| runnable(candidate)) {
            return Ok(found);
        }
        // The program beside the package manager's shim, found without a versioned path
        // and without a shell. Only the installed package is searched.
        let mut bases: Vec<&PathBuf> = Vec::new();
        let commands = self.path.iter().filter(|directory| self.endings.iter().any(|ending| runnable(&directory.join(format!("codex{ending}")))));
        for base in commands.chain(&self.libraries) {
            if !bases.contains(&base) {
                bases.push(base);
            }
        }
        let (own, other) = if self.arm { ("aarch64", "x86_64") } else { ("x86_64", "aarch64") };
        for base in bases {
            let mut found = Vec::new();
            named_files(&base.join("node_modules").join("@openai").join("codex"), if cfg!(windows) { "codex.exe" } else { "codex" }, 0, &mut found);
            let built_for = |kind: &str| found.iter().filter(|path| path.to_string_lossy().to_ascii_lowercase().contains(kind)).collect::<Vec<_>>();
            // A machine that runs both kinds may hold only the other one.
            let fitting = Some(built_for(own)).filter(|fitting| !fitting.is_empty()).unwrap_or_else(|| built_for(other));
            if let [only] = fitting[..] {
                return Ok(only.clone());
            }
        }
        if !cfg!(windows) {
            if let Some(found) = self.path.iter().map(|directory| directory.join("codex")).find(|candidate| runnable(candidate)) {
                return Ok(found);
            }
        }
        Err("codex_missing")
    }
}

/// `$value.name`, for a value another program wrote: only an object has members.
fn member(value: &V, name: &str) -> V {
    if value.is_obj() {
        value.g(name).unwrap_or(V::Null)
    } else {
        V::Null
    }
}

/// ConvertTo-Hotpl8CodexPlanType. Plan names change faster than releases, so a well-formed
/// one is passed on rather than hidden; anything else is `unknown`.
fn plan_name(value: &V) -> String {
    let named = value.as_str().filter(|name| {
        let b = name.as_bytes();
        (1..=24).contains(&b.len()) && b[0].is_ascii_lowercase() && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_')
    });
    named.unwrap_or("unknown").to_string()
}

/// `$text -match '^https://chatgpt\.com/backend-api/?$'`
fn subscription_address(text: &str) -> bool {
    let text = text.strip_suffix('\n').unwrap_or(text);
    text.strip_suffix('/').unwrap_or(text).eq_ignore_ascii_case("https://chatgpt.com/backend-api")
}

/// What one line of the program's output is to the request numbered `id`.
enum Said {
    /// A notice, an answer to another request, or nothing: the next line is read.
    Nothing,
    Result(V),
    Failed(&'static str),
}

/// Invoke-CodexRpc, for one line. A refusal is told by its number alone: the words a
/// server sends with it may hold a credential, and are never read.
fn said(line: &str, id: u32) -> Said {
    let line = line.trim_start_matches('\u{feff}');
    if line.trim_matches([' ', '\t', '\r', '\n']).is_empty() {
        return Said::Nothing;
    }
    let Ok(message) = json::parse_foreign(line) else { return Said::Failed("invalid_json") };
    let answered = match member(&message, "id") {
        V::Null | V::Arr(_) | V::Obj(_) | V::Hash(_) => false,
        number => number.s().is_ok_and(|text| text == id.to_string()),
    };
    if !answered {
        return Said::Nothing;
    }
    let error = member(&message, "error");
    if error.t().unwrap_or(true) {
        return Said::Failed(match member(&error, "code").s().unwrap_or_default().as_str() {
            "-32600" | "401" => "authentication_required",
            "403" => "access_denied",
            "429" => "rate_limited",
            _ => "rpc_failed",
        });
    }
    if !message.has("result").unwrap_or(false) {
        return Said::Failed("invalid_response");
    }
    Said::Result(member(&message, "result"))
}

/// One thing the program printed.
enum Heard {
    Line(String),
    /// A line longer than any answer.
    TooLong,
}

/// The program's output a line at a time, handed to `pass` until it says to stop. A line
/// ends where .NET ends one: at a line feed, a carriage return, or the two together.
fn lines(mut stream: impl Read, mut pass: impl FnMut(Heard) -> bool) {
    let whole = |bytes: &[u8]| {
        let text = String::from_utf8_lossy(bytes).into_owned();
        if text.encode_utf16().count() > LINE_LIMIT {
            Heard::TooLong
        } else {
            Heard::Line(text)
        }
    };
    let mut buffer = [0u8; 8192];
    let mut line: Vec<u8> = Vec::new();
    let mut after_return = false;
    loop {
        let count = match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        for &byte in &buffer[..count] {
            let second = byte == b'\n' && after_return;
            after_return = byte == b'\r';
            if second {
                continue;
            }
            if byte == b'\n' || byte == b'\r' {
                let heard = whole(&line);
                line.clear();
                if matches!(heard, Heard::TooLong) || !pass(heard) {
                    pass(Heard::TooLong);
                    return;
                }
            } else {
                line.push(byte);
                // No character takes more than three bytes for each of its UTF-16 units.
                if line.len() > LINE_LIMIT * 3 {
                    pass(Heard::TooLong);
                    return;
                }
            }
        }
    }
    if !line.is_empty() {
        pass(whole(&line));
    }
}

/// The conversation with a started program. One clock runs from before the program was
/// started, and every request shares the time it leaves.
struct Wire {
    input: ChildStdin,
    heard: mpsc::Receiver<Heard>,
    started: Instant,
    timeout: Duration,
}

impl Wire {
    /// One message. A program that has closed its input has gone.
    fn say(&mut self, message: &str) -> Result<(), &'static str> {
        let sent = self.input.write_all(format!("{message}\n").as_bytes()).and_then(|()| self.input.flush());
        sent.map_err(|_| "process_exited")
    }

    /// One request, and the result of the answer that carries its number.
    fn ask(&mut self, id: u32, request: &str) -> Result<V, &'static str> {
        self.say(request)?;
        loop {
            let spent = self.started.elapsed();
            if spent >= self.timeout {
                return Err("timeout");
            }
            match self.heard.recv_timeout((self.timeout - spent).max(Duration::from_millis(1))) {
                Ok(Heard::Line(line)) => match said(&line, id) {
                    Said::Nothing => {}
                    Said::Result(result) => return Ok(result),
                    Said::Failed(name) => return Err(name),
                },
                Ok(Heard::TooLong) => return Err("response_too_large"),
                Err(mpsc::RecvTimeoutError::Timeout) => return Err("timeout"),
                Err(mpsc::RecvTimeoutError::Disconnected) => return Err("process_exited"),
            }
        }
    }
}

/// The account id Codex keeps beside the sign-in, which `account/read` leaves out. The
/// rest of the file is let go unread.
fn signed_account(home: &str) -> V {
    let Ok(bytes) = std::fs::read(Path::new(home).join("auth.json")) else { return V::Null };
    if bytes.len() > 16_000_000 {
        return V::Null;
    }
    let text = String::from_utf8_lossy(bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes));
    let file = json::parse_foreign(&text).unwrap_or(V::Null);
    member(&member(&file, "tokens"), "account_id")
}

/// What the answers say of the account. The address signed in with goes no further than
/// the name made from it here.
fn described(home: &str, account: &V, quota: V, config: &V) -> R<Account> {
    let mut workspace = member(config, "forced_chatgpt_workspace_id").s()?;
    let signed = signed_account(home);
    if signed.t()? {
        workspace = format!("{workspace}|{}", signed.s()?);
    }
    let identity_key = sha256::hash(&format!("{}|{workspace}", member(account, "email").s()?));
    let mut standard_transport = !member(&member(&member(config, "model_providers"), "openai"), "base_url").t()?;
    let address = member(config, "chatgpt_base_url");
    if address.t()? && !subscription_address(&address.s()?) {
        standard_transport = false;
    }
    Ok(Account {
        quota,
        identity_key,
        plan_type: plan_name(&member(account, "planType")),
        model: member(config, "model").s()?,
        model_provider: member(config, "model_provider").s()?,
        standard_transport,
    })
}

/// The four requests of one read, in order.
fn conversation(wire: &mut Wire, home: &str) -> Result<Account, &'static str> {
    wire.ask(1, r#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"hotpl8","version":"0.1"},"capabilities":{"experimentalApi":true}}}"#)?;
    wire.say(r#"{"method":"initialized"}"#)?;
    let account = member(&wire.ask(2, r#"{"id":2,"method":"account/read","params":{"refreshToken":false}}"#)?, "account");
    // A key is not a subscription: its limits are not the ones HotPl8 measures.
    if !member(&account, "type").as_str().is_some_and(|kind| kind.eq_ignore_ascii_case("chatgpt")) {
        return Err("subscription_login_required");
    }
    let quota = wire.ask(3, r#"{"id":3,"method":"account/rateLimits/read"}"#)?;
    let asked = format!(r#"{{"id":4,"method":"config/read","params":{{"includeLayers":false,"cwd":{}}}}}"#, json::text(home));
    let config = member(&wire.ask(4, &asked)?, "config");
    described(home, &account, quota, &config).map_err(|_| "transport_failed")
}

/// The program as it is started for one home: in that home, told that the home is its
/// own, with no window and nothing of the caller's that would sign it in as someone else.
fn command(program: &Path, home: &str) -> Command {
    let mut command = Command::new(program);
    command.args(["app-server", "--stdio"]).current_dir(home).env("CODEX_HOME", home);
    for name in WITHHELD {
        command.env_remove(name);
    }
    command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(crate::process::CREATE_NO_WINDOW);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    command
}

/// Where the lock of a home is kept. Everything of HotPl8's that starts Codex in a home
/// holds this file while it does, in whichever language it is written.
fn lock_path(full_home: &str) -> PathBuf {
    std::env::temp_dir().join(format!("hotpl8-codex-{}.lock", sha256::hash(&full_home.to_ascii_lowercase())))
}

/// Read-CodexQuota, as a collection uses it. `program` is what the search for a Codex
/// program came to; a home that is missing or busy is said before a program that is.
pub fn read_home(home: &str, program: &Result<PathBuf, &'static str>, timeout_ms: u64) -> HomeRead {
    let started = Instant::now();
    let done = |outcome| HomeRead { elapsed_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX), outcome };
    let (true, Ok(full_home)) = (Path::new(home).is_dir(), home_path(home)) else { return done(Err("home_missing")) };
    // Held until the program has gone: declared first, so let go last.
    let Ok(_lock) = files::lock(&lock_path(&full_home)) else { return done(Err("home_busy")) };
    let program = match program {
        Ok(program) => program,
        Err(name) => return done(Err(name)),
    };
    let Ok(child) = command(program, home).spawn() else { return done(Err("transport_failed")) };
    let mut running = Running(child);
    let (Some(input), Some(output)) = (running.0.stdin.take(), running.0.stdout.take()) else { return done(Err("transport_failed")) };
    let (sender, heard) = mpsc::sync_channel(8);
    std::thread::spawn(move || lines(output, |line| sender.send(line).is_ok()));
    // Its input closes before the program is waited for, which is how it is told to leave.
    let mut wire = Wire { input, heard, started, timeout: Duration::from_millis(timeout_ms) };
    done(conversation(&mut wire, home))
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::files::tests::scratch;

    /// The stand-in for Codex that `cargo test` builds from native/examples. It does what
    /// the file `stand-in.txt` in its home says, and writes down what it was started with
    /// and what it heard. No test starts a real Codex or looks for one.
    pub fn stand_in() -> PathBuf {
        let test = std::env::current_exe().unwrap();
        let path = test.parent().unwrap().parent().unwrap().join("examples").join(format!("codex_stand_in{}", std::env::consts::EXE_SUFFIX));
        assert!(path.is_file(), "the stand-in for Codex is not built: {} (`cargo test` builds it from native/examples; with a test named, run `cargo build --examples` first)", path.display());
        path
    }

    /// A home of this test's own, with what the stand-in is to do there.
    pub fn home(name: &str, script: &str) -> String {
        let home = scratch(name);
        std::fs::write(home.join("stand-in.txt"), script).unwrap();
        home.to_string_lossy().into_owned()
    }

    pub const ACCOUNT: &str = r#"{"account":{"type":"chatgpt","email":"fixture-a@example.invalid","planType":"plus"}}"#;
    pub const LIMITS: &str = r#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1800000000},"secondary":null,"spendControlReached":false}}}"#;
    pub const CONFIG: &str = r#"{"config":{"model":"gpt-fixture","model_provider":"openai"}}"#;

    /// A script in which every request is answered, `changed` replacing the usual answers.
    pub fn answers(changed: &[(&str, &str)]) -> String {
        let usual = [("initialize", "reply {}".to_string()), ("account/read", format!("reply {ACCOUNT}")), ("account/rateLimits/read", format!("reply {LIMITS}")), ("config/read", format!("reply {CONFIG}"))];
        let mut script = String::new();
        for (method, usual) in usual {
            let own: Vec<&str> = changed.iter().filter(|(known, _)| *known == method).map(|(_, line)| *line).collect();
            for line in if own.is_empty() { vec![usual.as_str()] } else { own } {
                script.push_str(&format!("{method} {line}\n"));
            }
        }
        for (_, line) in changed.iter().filter(|(known, _)| *known == "start") {
            script.push_str(&format!("start {line}\n"));
        }
        script
    }

    fn read(home: &str, timeout_ms: u64) -> HomeRead {
        read_home(home, &Ok(stand_in()), timeout_ms)
    }

    fn failure(read: &HomeRead) -> &'static str {
        read.outcome.as_ref().err().copied().unwrap_or("ok")
    }

    /// Nothing started from a home still runs once its read is over.
    fn remove(home: &str) {
        for _ in 0..50 {
            if std::fs::remove_dir_all(home).is_ok() {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("{home} is still in use");
    }

    #[test]
    fn an_account_is_read_in_four_requests() {
        set_core(false);
        let home = home("read", &answers(&[]));
        let read = read(&home, 20_000);
        let account = read.outcome.ok().unwrap();
        assert_eq!(json::compact(&account.quota, 12).ok().unwrap(), LIMITS);
        assert_eq!(account.identity_key, sha256::hash("fixture-a@example.invalid|"));
        assert_eq!((account.plan_type.as_str(), account.model.as_str(), account.model_provider.as_str(), account.standard_transport), ("plus", "gpt-fixture", "openai", true));
        assert!((0..20_000).contains(&read.elapsed_ms));
        let heard = std::fs::read_to_string(Path::new(&home).join("heard.txt")).unwrap();
        let asked = format!(r#"{{"id":4,"method":"config/read","params":{{"includeLayers":false,"cwd":{}}}}}"#, json::text(&home));
        let expected = [
            r#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"hotpl8","version":"0.1"},"capabilities":{"experimentalApi":true}}}"#,
            r#"{"method":"initialized"}"#,
            r#"{"id":2,"method":"account/read","params":{"refreshToken":false}}"#,
            r#"{"id":3,"method":"account/rateLimits/read"}"#,
            asked.as_str(),
        ];
        assert_eq!(heard.lines().collect::<Vec<_>>(), expected);
        let started = std::fs::read_to_string(Path::new(&home).join("started.txt")).unwrap();
        let same_place = |line: &str, name: &str| line.strip_prefix(name).is_some_and(|path| Path::new(path).canonicalize().unwrap() == Path::new(&home).canonicalize().unwrap());
        let started: Vec<&str> = started.lines().collect();
        assert_eq!(started[0], "words app-server --stdio");
        assert!(same_place(started[1], "directory "), "{}", started[1]);
        assert_eq!(started[2], format!("home {home}"));
        remove(&home);
    }

    #[test]
    fn the_program_is_given_the_home_and_none_of_the_callers_keys() {
        let command = command(Path::new("codex"), "/fixture/home");
        let set: Vec<(String, Option<String>)> = command.get_envs().map(|(name, value)| (name.to_string_lossy().into_owned(), value.map(|value| value.to_string_lossy().into_owned()))).collect();
        assert!(set.contains(&("CODEX_HOME".into(), Some("/fixture/home".into()))));
        for name in WITHHELD {
            assert!(set.contains(&(name.into(), None)), "{name}");
        }
        assert_eq!(set.len(), 5);
        assert_eq!(command.get_args().collect::<Vec<_>>(), ["app-server", "--stdio"]);
        assert_eq!(command.get_current_dir(), Some(Path::new("/fixture/home")));
    }

    /// Who is signed in is told from the address, the workspace the configuration pins
    /// and the account id beside the sign-in; the file's tokens are not part of it.
    #[test]
    fn the_subscription_is_named_without_being_told() {
        set_core(false);
        let config = r#"reply {"config":{"model":7,"model_provider":null,"forced_chatgpt_workspace_id":"ws-fixture"}}"#;
        let home = home("identity", &answers(&[("config/read", config)]));
        std::fs::write(Path::new(&home).join("auth.json"), b"\xef\xbb\xbf{\"tokens\":{\"access_token\":\"fixture-not-a-token\",\"account_id\":\"acct-fixture\"},\"\":1}").unwrap();
        let account = read(&home, 20_000).outcome.ok().unwrap();
        assert_eq!(account.identity_key, sha256::hash("fixture-a@example.invalid|ws-fixture|acct-fixture"));
        assert_eq!((account.model.as_str(), account.model_provider.as_str()), ("7", ""));
        remove(&home);
        for (file, expected) in [("not json", "fixture-a@example.invalid|"), (r#"{"tokens":{"account_id":""}}"#, "fixture-a@example.invalid|"), (r#"{"tokens":{"account_id":42}}"#, "fixture-a@example.invalid||42"), ("[]", "fixture-a@example.invalid|")] {
            let directory = scratch("auth");
            std::fs::write(directory.join("auth.json"), file).unwrap();
            let account = described(&directory.to_string_lossy(), &json::parse_foreign(ACCOUNT).ok().unwrap().g("account").ok().unwrap(), V::Null, &V::Null).ok().unwrap();
            assert_eq!(account.identity_key, sha256::hash(expected), "{file}");
            std::fs::remove_dir_all(&directory).unwrap();
        }
        // A value that is not one thing has no text, and the read is not used.
        let odd = json::parse_foreign(r#"{"email":["a","b"]}"#).ok().unwrap();
        assert!(described("/fixture/none", &odd, V::Null, &V::Null).is_err());
    }

    #[test]
    fn a_set_address_is_not_the_subscriptions_own() {
        let standard = |config: &str| described("/fixture/none", &V::Null, V::Null, &json::parse_foreign(config).ok().unwrap()).ok().unwrap().standard_transport;
        assert!(standard("{}"));
        assert!(standard(r#"{"model_providers":{"openai":{"base_url":""}},"chatgpt_base_url":null}"#));
        assert!(!standard(r#"{"model_providers":{"openai":{"base_url":"https://example.invalid/v1"}}}"#));
        assert!(standard(r#"{"model_providers":{"other":{"base_url":"https://example.invalid/v1"}}}"#));
        for (address, own) in [
            ("https://chatgpt.com/backend-api", true),
            ("https://chatgpt.com/backend-api/", true),
            ("HTTPS://ChatGPT.com/Backend-API/", true),
            ("https://chatgpt.com/backend-api/\\n", true),
            ("https://chatgpt.com/backend-api//", false),
            ("https://chatgpt.com/backend-api/\\n\\n", false),
            ("https://example.invalid/backend-api", false),
            ("https://chatgpt.com/backend-api/v2", false),
        ] {
            assert_eq!(standard(&format!(r#"{{"chatgpt_base_url":"{address}"}}"#)), own, "{address}");
        }
        assert!(!standard(r#"{"chatgpt_base_url":5}"#));
        assert!(standard(r#"{"chatgpt_base_url":0}"#));
    }

    #[test]
    fn a_plan_is_named_only_by_a_well_formed_name() {
        let name = |json: &str| plan_name(&json::parse_foreign(json).ok().unwrap());
        for (value, expected) in [
            (r#""plus""#, "plus"),
            (r#""a""#, "a"),
            (r#""a_b9""#, "a_b9"),
            (r#""aaaaaaaaaaaaaaaaaaaaaaaa""#, "aaaaaaaaaaaaaaaaaaaaaaaa"),
            (r#""aaaaaaaaaaaaaaaaaaaaaaaaa""#, "unknown"),
            (r#""Plus""#, "unknown"),
            (r#""1a""#, "unknown"),
            (r#""plus\n""#, "unknown"),
            (r#""""#, "unknown"),
            ("5", "unknown"),
            ("null", "unknown"),
            ("true", "unknown"),
        ] {
            assert_eq!(name(value), expected, "{value}");
        }
    }

    /// What Windows PowerShell made of each of these lines as the answer to request 1,
    /// measured there; the few this program reads otherwise are in the contract.
    #[test]
    fn a_line_is_an_answer_only_when_it_carries_the_requests_number() {
        set_core(false);
        let told = |line: &str| match said(line, 1) {
            Said::Nothing => "nothing".to_string(),
            Said::Failed(name) => name.to_string(),
            Said::Result(result) => format!("result {}", json::compact(&result, 12).ok().unwrap()),
        };
        for (line, expected) in [
            ("", "nothing"),
            (" ", "nothing"),
            ("null", "nothing"),
            ("5", "nothing"),
            ("\"x\"", "nothing"),
            ("true", "nothing"),
            ("[1]", "nothing"),
            (r#"{"method":"note","params":{"id":1}}"#, "nothing"),
            (r#"{"id":2,"result":3}"#, "nothing"),
            (r#"{"id":1,"result":1} {"id":2}"#, "invalid_json"),
            (r#"{"id":1,"result":1}x"#, "invalid_json"),
            (r#"{"a":1,"A":2,"id":1,"result":3}"#, "invalid_json"),
            (r#"{"id":1,"result":1e400}"#, "invalid_json"),
            ("{", "invalid_json"),
            (r#"{"id":1.0,"result":3}"#, "nothing"),
            (r#"{"id":"1","result":3}"#, "result 3"),
            (r#"{"id":"01","result":3}"#, "nothing"),
            (r#"{"id":true,"result":3}"#, "nothing"),
            (r#"{"id":{"a":1},"result":3}"#, "nothing"),
            (r#"{"id":1}"#, "invalid_response"),
            (r#"{"id":1,"result":null}"#, "result null"),
            (r#"{"id":1,"error":null,"result":4}"#, "result 4"),
            (r#"{"id":1,"error":0,"result":4}"#, "result 4"),
            (r#"{"id":1,"error":"","result":4}"#, "result 4"),
            (r#"{"id":1,"error":[],"result":4}"#, "result 4"),
            (r#"{"id":1,"error":[0],"result":4}"#, "result 4"),
            (r#"{"id":1,"error":"x"}"#, "rpc_failed"),
            (r#"{"id":1,"error":{}}"#, "rpc_failed"),
            (r#"{"id":1,"error":{"code":"401","message":"fixture words"}}"#, "authentication_required"),
            (r#"{"id":1,"error":{"code":401}}"#, "authentication_required"),
            (r#"{"id":1,"error":{"code":-32600}}"#, "authentication_required"),
            (r#"{"id":1,"error":{"code":403}}"#, "access_denied"),
            (r#"{"id":1,"error":{"code":429}}"#, "rate_limited"),
            (r#"{"id":1,"error":{"code":4.29e2}}"#, "rate_limited"),
            (r#"{"id":1,"error":{"code":401.0}}"#, "rpc_failed"),
            (r#"{"id":1,"error":{"code":500}}"#, "rpc_failed"),
            (r#"{"ID":1,"Result":5}"#, "result 5"),
            ("\u{feff}{\"id\":1,\"result\":6}", "result 6"),
            (r#"{"id":1,"result":{"a":{"a":{"a":{"a":1}}}}}"#, r#"result {"a":{"a":{"a":{"a":1}}}}"#),
            // Read otherwise than PowerShell read them, and said so in the contract.
            (r#"[{"id":1,"result":2}]"#, "nothing"),
            (r#"{"id":[1],"result":3}"#, "nothing"),
            (r#"{"id":1,"error":{"code":[429]}}"#, "rpc_failed"),
            (r#"{"":1,"id":1,"result":3}"#, "result 3"),
            (r#"{"id":1,"result":{"psobject":1}}"#, "result {}"),
            (r#"{"id":1,"result":01}"#, "invalid_json"),
            ("{\"id\":1,\"result\":\"a\tb\"}", "invalid_json"),
        ] {
            assert_eq!(told(line), expected, "{line}");
        }
    }

    #[test]
    fn output_is_read_a_line_at_a_time() {
        let heard = |bytes: &[u8]| {
            let mut all = Vec::new();
            lines(bytes, |heard| {
                all.push(match heard {
                    Heard::Line(line) => line,
                    Heard::TooLong => "<too long>".into(),
                });
                true
            });
            all
        };
        assert_eq!(heard(b"a\nb\r\nc\rd\n\ne"), ["a", "b", "c", "d", "", "e"]);
        assert_eq!(heard(b"a\r\n"), ["a"]);
        assert_eq!(heard(b"a\r\r\nb"), ["a", "", "b"]);
        assert_eq!(heard(b""), Vec::<String>::new());
        assert_eq!(heard(b"caf\xc3\xa9\n\xff\n"), ["caf\u{e9}", "\u{fffd}"]);
        let exact = "a".repeat(LINE_LIMIT) + "\n";
        assert_eq!(heard(exact.as_bytes()).len(), 1);
        assert_ne!(heard(exact.as_bytes())[0], "<too long>");
        let over = "a".repeat(LINE_LIMIT + 1) + "\nnext\n";
        assert_eq!(heard(over.as_bytes())[0], "<too long>");
        // Three bytes to the unit: this many of them are one line of exactly the limit.
        let wide = "\u{20ac}".repeat(LINE_LIMIT) + "\n";
        assert_ne!(heard(wide.as_bytes())[0], "<too long>");
        // A line that never ends is given up on as soon as it cannot be an answer.
        assert_eq!(heard("a".repeat(LINE_LIMIT * 3 + 1).as_bytes()), ["<too long>"]);
    }

    /// What each way of going wrong is called. None of them is told in the server's words.
    #[test]
    fn a_read_that_fails_is_named() {
        set_core(false);
        let refusal = r#"error {"code":CODE,"message":"FIXTURE_WORDS_NEVER_READ"}"#;
        let cases: Vec<(&str, Vec<(&str, String)>, u64)> = vec![
            ("subscription_login_required", vec![("account/read", r#"reply {"account":{"type":"apiKey"}}"#.into())], 20_000),
            ("subscription_login_required", vec![("account/read", r#"reply {"account":{"type":true}}"#.into())], 20_000),
            ("subscription_login_required", vec![("account/read", "reply null".into())], 20_000),
            ("authentication_required", vec![("account/rateLimits/read", refusal.replace("CODE", "401"))], 20_000),
            ("authentication_required", vec![("initialize", refusal.replace("CODE", "-32600"))], 20_000),
            ("access_denied", vec![("account/rateLimits/read", refusal.replace("CODE", "403"))], 20_000),
            ("rate_limited", vec![("account/rateLimits/read", refusal.replace("CODE", "429"))], 20_000),
            ("rpc_failed", vec![("config/read", refusal.replace("CODE", "500"))], 20_000),
            ("invalid_json", vec![("account/read", "raw not json".into())], 20_000),
            ("invalid_response", vec![("account/read", r#"raw {"id":$ID}"#.into())], 20_000),
            ("response_too_large", vec![("account/rateLimits/read", format!("long {}", LINE_LIMIT + 1))], 20_000),
            ("process_exited", vec![("account/read", "exit 8".into())], 20_000),
            ("process_exited", vec![("start", "exit 3".into())], 20_000),
            ("timeout", vec![("account/rateLimits/read", "hang".into())], 700),
            ("timeout", vec![("account/read", r#"part {"id":$ID,"result":{"account""#.into()), ("account/read", "hang".into())], 700),
            ("timeout", vec![("start", "hang".into())], 400),
            ("transport_failed", vec![("config/read", r#"reply {"config":{"model":["a","b"]}}"#.into())], 20_000),
        ];
        std::thread::scope(|scope| {
            for (index, (expected, changed, timeout)) in cases.iter().enumerate() {
                scope.spawn(move || {
                    let changed: Vec<(&str, &str)> = changed.iter().map(|(method, line)| (*method, line.as_str())).collect();
                    let home = home("named", &answers(&changed));
                    let started = Instant::now();
                    let read = read(&home, *timeout);
                    assert_eq!(failure(&read), *expected, "case {index}");
                    assert!(started.elapsed() < Duration::from_secs(15), "case {index}");
                    remove(&home);
                });
            }
        });
    }

    /// Notices, answers to other requests, blank lines, a byte-order mark, every way of
    /// ending a line and a program that talks on its other stream are all read past.
    #[test]
    fn what_is_not_an_answer_is_read_past() {
        set_core(false);
        let changed = [
            ("start", "errors 300000"),
            ("initialize", r#"raw {"method":"note","params":{"id":$ID}}"#),
            ("initialize", "raw "),
            ("initialize", r#"raw {"id":99,"result":"another request's"}"#),
            ("initialize", "part <BOM>{\"id\":$ID,\"result\":{}}<CR><LF>"),
            ("account/read", "part <LF><CR>"),
            ("account/read", &format!("part {{\"id\":\"$ID\",\"result\":{ACCOUNT}}}<CR>")),
            ("account/rateLimits/read", "wait 150"),
            ("account/rateLimits/read", &format!("reply {LIMITS}")),
        ];
        let home = home("noise", &answers(&changed));
        let read = read(&home, 20_000);
        assert_eq!(failure(&read), "ok");
        assert!(read.elapsed_ms >= 150);
        remove(&home);
    }

    #[test]
    fn a_home_that_cannot_be_read_is_said_before_anything_is_started() {
        let home = home("held", &answers(&[]));
        let gone = format!("{home}-gone");
        assert_eq!(failure(&read(&gone, 20_000)), "home_missing");
        assert_eq!(failure(&read("fixture/relative", 20_000)), "home_missing");
        let held = files::lock(&lock_path(&home_path(&home).ok().unwrap())).ok().unwrap();
        assert_eq!(failure(&read(&home, 20_000)), "home_busy");
        // A busy home is said before a missing program, and a missing program once it is free.
        assert_eq!(failure(&read_home(&home, &Err("codex_missing"), 20_000)), "home_busy");
        drop(held);
        assert_eq!(failure(&read_home(&home, &Err("codex_missing"), 20_000)), "codex_missing");
        assert_eq!(failure(&read_home(&home, &Ok(Path::new(&home).join("no-such-program")), 20_000)), "transport_failed");
        assert!(!Path::new(&home).join("started.txt").exists());
        // The lock is let go with the read.
        assert_eq!(failure(&read(&home, 20_000)), "ok");
        assert!(files::lock(&lock_path(&home_path(&home).ok().unwrap())).is_ok());
        remove(&home);
    }

    fn touch(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    /// The search is given the places to look, so no test looks at this machine's own.
    #[test]
    fn a_codex_program_is_found_where_one_is_installed() {
        let root = scratch("search");
        let binary = if cfg!(windows) { "codex.exe" } else { "codex" };
        let shim = if cfg!(windows) { "codex.cmd" } else { "codex" };
        let search = |path: &[&str], libraries: &[&str], arm: bool| Search {
            managed: Some(root.join("managed").join(binary)),
            path: path.iter().map(|name| root.join(name)).collect(),
            endings: if cfg!(windows) { vec![String::new(), ".exe".into(), ".cmd".into(), ".ps1".into()] } else { vec![String::new()] },
            libraries: libraries.iter().map(|name| root.join(name)).collect(),
            arm,
        };
        let found = |search: &Search| search.program(None).map(|path| path.strip_prefix(&root).unwrap().to_string_lossy().replace('\\', "/"));
        assert_eq!(found(&search(&["empty", "none"], &["lib"], false)), Err("codex_missing"));

        // A package: the shim PATH holds, and one program for each kind of machine.
        let package = |base: &str, kinds: &[&str]| {
            for kind in kinds {
                touch(&root.join(base).join("node_modules/@openai/codex/node_modules/@openai").join(format!("codex-{kind}")).join("vendor").join(kind).join("codex").join(binary));
            }
            touch(&root.join(base).join("node_modules/@openai/codex/bin/codex.js"));
        };
        let inside = |base: &str, kind: &str| Ok(format!("{base}/node_modules/@openai/codex/node_modules/@openai/codex-{kind}/vendor/{kind}/codex/{binary}"));
        touch(&root.join("npm").join(shim));
        package("npm", &["x86_64-fixture", "aarch64-fixture"]);
        assert_eq!(found(&search(&["empty", "npm"], &[], false)), inside("npm", "x86_64-fixture"));
        assert_eq!(found(&search(&["empty", "npm"], &[], true)), inside("npm", "aarch64-fixture"));
        // Only the other kind is installed: a machine that runs both is given it.
        touch(&root.join("one").join(shim));
        package("one", &["aarch64-fixture"]);
        assert_eq!(found(&search(&["one"], &[], false)), inside("one", "aarch64-fixture"));
        // Two programs of one kind are not a choice the search makes.
        touch(&root.join("two").join(shim));
        package("two", &["x86_64-fixture", "x86_64-other"]);
        let unix_shim = |base: &str| if cfg!(windows) { Err("codex_missing") } else { Ok(format!("{base}/codex")) };
        assert_eq!(found(&search(&["two"], &[], false)), unix_shim("two"));
        assert_eq!(found(&search(&["two", "npm"], &[], false)), inside("npm", "x86_64-fixture"));
        // A package no command of PATH belongs to is found where the package manager keeps them.
        package("lib", &["x86_64-fixture"]);
        assert_eq!(found(&search(&["empty"], &["lib"], false)), inside("lib", "x86_64-fixture"));
        assert_eq!(found(&search(&["empty"], &[], false)), Err("codex_missing"));
        // A program of PATH comes before any package, and HotPl8's own before that.
        touch(&root.join("bin").join("codex.exe"));
        assert_eq!(found(&search(&["npm", "bin"], &["lib"], false)), Ok("bin/codex.exe".into()));
        touch(&root.join("managed").join(binary));
        assert_eq!(found(&search(&["npm", "bin"], &["lib"], false)), Ok(format!("managed/{binary}")));

        // A program that is named is the one used, and a script is never used for one.
        let all = search(&["npm", "bin"], &["lib"], false);
        let named = root.join("bin").join("codex.exe");
        assert_eq!(all.program(Some(&named.to_string_lossy())), Ok(named));
        assert_eq!(all.program(Some(&root.join("bin").join("absent.exe").to_string_lossy())), Err("codex_missing"));
        assert_eq!(all.program(Some(&root.join("bin").to_string_lossy())), Err("codex_missing"));
        for script in ["codex.cmd", "codex.BAT", "codex.ps1"] {
            touch(&root.join("scripts").join(script));
            assert_eq!(all.program(Some(&root.join("scripts").join(script).to_string_lossy())), Err("native_codex_required"));
        }
        assert_eq!(all.program(Some("")), Ok(root.join("managed").join(binary)));
        std::fs::remove_dir_all(&root).unwrap();
    }
}

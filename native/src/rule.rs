//! The rules PowerShell asks for. The commands that stay in PowerShell change what a person
//! owns and decide nothing about accounts themselves: each rule they need is one question,
//!
//! ```text
//! hotpl8-native rule <question> --root <release> [--core]
//! ```
//!
//! with the question's arguments one JSON object on standard input and the answer one line:
//! `{"value": …}`, or `{"error": "…"}` in the words PowerShell throws. src/rules.ps1 is the
//! one place that asks.

use std::cell::RefCell;
use std::ffi::OsString;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use crate::agent;
use crate::capacity;
use crate::codex_read::{read_home_as, Asked, Search, READ_BUDGET_MS};
use crate::cswap;
use crate::dashboard::park_reason;
use crate::display::packaged_data;
use crate::doctor::{self, Found};
use crate::files;
use crate::insights;
use crate::json;
use crate::obj;
use crate::overview::park_candidates;
use crate::pause;
use crate::policy::{actions, assert_codex_policy, assert_policy};
use crate::ps::*;
use crate::registry::{catalog, configured_provider, configured_providers, provider_account_rows, provider_definition, provider_driver, provider_state_directory, provider_view};
use crate::replay;
use crate::request::full_path;
use crate::time::Dto;

/// As deep as an answer goes: a snapshot inside the object that holds it.
const DEPTH: usize = 32;

/// What a rule reads of the machine it runs on, which a test stands in for.
pub struct Machine<'a> {
    /// Resolve-CswapExecutable
    pub cswap: &'a dyn Fn(Option<&str>) -> Option<String>,
    /// Resolve-CodexExecutable
    pub codex: &'a dyn Fn(Option<&str>) -> Result<PathBuf, &'static str>,
    pub clock: &'a dyn Fn() -> R<Dto>,
}

struct Started {
    question: String,
    root: PathBuf,
    core: bool,
}

fn spelled(arguments: &[OsString]) -> Option<Started> {
    let (question, rest) = arguments.split_first()?;
    let (mut root, mut core) = (None, false);
    let mut rest = rest.iter();
    while let Some(word) = rest.next() {
        match word.to_str()? {
            "--root" if root.is_none() => root = Some(full_path(rest.next()?)?),
            "--core" if !core => core = true,
            _ => return None,
        }
    }
    Some(Started { question: question.to_str()?.to_string(), root: root?, core })
}

/// `[string]` of one of the question's arguments.
fn words(asked: &V, name: &str) -> R<String> {
    asked.g(name)?.s()
}
fn named(text: &str) -> Option<&str> {
    Some(text).filter(|text| !text.is_empty())
}
fn place(asked: &V, name: &str) -> R<PathBuf> {
    match named(&words(asked, name)?) {
        Some(path) => Ok(PathBuf::from(path)),
        None => fail(format!("The question names no {name}.")),
    }
}
fn path_text(path: &Path) -> R<String> {
    match path.to_str() {
        Some(text) => Ok(text.to_string()),
        None => unreadable(),
    }
}

/// A hashtable is an object once it is written, as ConvertTo-Json writes it.
fn plain(value: &V) -> V {
    match value {
        V::Hash(members) | V::Obj(members) => {
            let items = members.borrow().items.iter().map(|(name, value)| (name.clone(), plain(value))).collect();
            V::Obj(Rc::new(RefCell::new(Props { items })))
        }
        V::Arr(items) => V::Arr(Rc::new(items.iter().map(plain).collect())),
        other => other.clone(),
    }
}

/// Get-Hotpl8HistoryStores: the usage history each configured provider writes, the store
/// the canonical providers share first and each alias's own after it.
fn history_stores(policy: &V, directory: &Path) -> R<Vec<V>> {
    // Enumerate configured registrations only, never arbitrary residual folders.
    let own = path_text(directory)?;
    let mut shared: Vec<V> = Vec::new();
    let mut aliases: Vec<(String, String)> = Vec::new();
    let mut seen = Keys::new();
    for registration in configured_providers(policy, false)? {
        let id = registration.g("id")?.s()?;
        let state = path_text(&provider_state_directory(directory, &id)?)?;
        if state == own {
            shared.push(id.into());
        } else if seen.contains(&state)? {
            return unreadable();
        } else {
            seen.insert(&state)?;
            aliases.push((id, state));
        }
    }
    let store = |state: &str, providers: Vec<V>| -> R<V> {
        let history = json::read_or_null(&Path::new(state).join("usage-history.json"));
        let samples = filter(&history.g("samples")?.each(), |sample| sample.t())?.len();
        Ok(obj! {"directory" => state, "providers" => providers, "samples" => i32::try_from(samples).unwrap_or(i32::MAX)})
    };
    let mut stores = Vec::new();
    if !shared.is_empty() {
        stores.push(store(&own, shared)?);
    }
    // A directory sorts before the ones inside it, and those sort as their names do.
    for (id, state) in sort(&aliases, |left, right| order_text(&left.0, &right.0), |left, right| left.0 == right.0)? {
        stores.push(store(&state, vec![id.into()])?);
    }
    Ok(stores)
}

/// Read-CodexQuota for a person's command: the account's limits and identity, and never
/// the sign-in itself.
fn codex_read(asked: &V, machine: &Machine) -> R<V> {
    let (home, executable, directory) = (words(asked, "home")?, words(asked, "executable")?, words(asked, "workingDirectory")?);
    let timeout = asked.g("timeoutMs")?;
    let timeout = if timeout.is_null() { READ_BUDGET_MS } else { u64::try_from(timeout.to_int()?).unwrap_or(0) };
    let identity_only = asked.g("identityOnly")?.t()?;
    let program = (machine.codex)(named(&executable));
    let read = read_home_as(&home, &program, timeout, &Asked { directory: named(&directory), refresh: false, identity_only, token: false });
    let account = match read.outcome {
        Ok(account) => account,
        Err(failure) => return Ok(obj! {"status" => failure, "elapsedMs" => read.elapsed_ms}),
    };
    let answer = obj! {
        "status" => "ok",
        "quota" => account.quota,
        "identityKey" => account.identity_key,
        "planType" => account.plan_type,
        "model" => account.model,
        "modelProvider" => account.model_provider,
        "standardTransport" => account.standard_transport,
        "elapsedMs" => read.elapsed_ms,
    };
    if identity_only {
        answer.add_member("identityVerified", account.identity_verified.into(), true)?;
    }
    Ok(answer)
}

/// The answer to one question.
pub fn answer(question: &str, root: &Path, asked: &V, machine: &Machine) -> R<V> {
    // One clock reading a question: the caller's when it gives one.
    let now = || -> R<Dto> {
        let given = asked.g("now")?;
        if given.is_null() {
            (machine.clock)()
        } else {
            Dto::parse(&given.s()?)
        }
    };
    let flag = |name: &str| -> R<bool> { asked.g(name)?.t() };
    // What is installed here, looked for as a command with none named looks for it.
    let found = || Found { cswap: (machine.cswap)(None).is_some_and(|program| !program.is_empty()), codex: (machine.codex)(None).is_ok() };
    Ok(match question {
        "policy.check" => {
            assert_policy(&asked.g("policy")?)?;
            V::Null
        }
        "codex.check" => {
            assert_codex_policy(&asked.g("policy")?)?;
            V::Null
        }
        "policy.actions" => {
            let allowed = actions(&asked.g("policy")?, flag("observeOnly")?)?;
            obj! {"switching" => allowed.switching, "warming" => allowed.warming, "probing" => allowed.probing, "continuing" => allowed.continuing}
        }
        // A driver by its own name, or the one a registered provider is read through.
        "provider.driver" => match named(&words(asked, "provider")?) {
            Some(provider) => provider_driver(&provider_definition(provider)?.g("driver")?)?,
            None => provider_driver(&asked.g("id")?)?,
        },
        "provider.catalog" => catalog()?.into(),
        "provider.definition" => provider_definition(&words(asked, "id")?)?,
        "provider.configured" => configured_providers(&asked.g("policy")?, flag("includeUnconfigured")?)?.into(),
        "provider.one" => configured_provider(&asked.g("policy")?, &words(asked, "provider")?, flag("includeUnconfigured")?)?,
        "provider.state" => path_text(&provider_state_directory(&place(asked, "directory")?, &words(asked, "provider")?)?)?.into(),
        "provider.view" => provider_view(&asked.g("snapshot")?, &asked.g("policy")?, &words(asked, "provider")?, &[])?,
        "provider.accounts" => provider_account_rows(&asked.g("policy")?)?.into(),
        "pause" => pause::pause(&place(asked, "directory")?, now()?)?,
        "lease.pause" => pause::lease_pause(&place(asked, "directory")?, now()?)?,
        "capacity.catalog" => capacity::catalog()?,
        "fresh" => capacity::fresh_timestamp(&asked.g("timestamp")?, now()?)?.into(),
        "snapshot" => {
            let directory = place(asked, "directory")?;
            let given = asked.g("policy")?;
            let explicit = given.t()?;
            let policy = if explicit { given } else { json::read_or_null(&directory.join("policy.json")) };
            insights::read_snapshot(&directory, &policy, explicit, now()?)?
        }
        "health" => insights::health(&asked.g("collector")?, now()?, &words(asked, "provider")?)?.into(),
        "history" => history_stores(&asked.g("policy")?, &place(asked, "directory")?)?.into(),
        "park.candidates" => park_candidates(&asked.g("snapshot")?, &asked.g("policy")?, now()?)?.into(),
        "park.reason" => park_reason(&asked.g("candidate")?)?.into(),
        "cswap.find" => (machine.cswap)(named(&words(asked, "explicit")?)).map_or(V::Null, V::from),
        "cswap.timeout" => V::I64(cswap::READ_TIMEOUT_MS as i64),
        "codex.find" => match (machine.codex)(named(&words(asked, "explicit")?)) {
            Ok(program) => path_text(&program)?.into(),
            Err(failure) => return fail(failure),
        },
        "codex.budget" => V::I64(READ_BUDGET_MS as i64),
        "codex.read" => codex_read(asked, machine)?,
        "doctor" => doctor::facts(root, &place(asked, "directory")?, found(), now()?)?,
        "capabilities" => doctor::capabilities(root, &place(asked, "directory")?, found(), now()?)?,
        "event" => {
            files::event(&place(asked, "directory")?, &words(asked, "code")?, None);
            V::Null
        }
        "replay" => replay::replay(&asked.g("frames")?.each(), &asked.g("policy")?)?,
        "agent" => agent::answer(&words(asked, "operation")?, &place(asked, "directory")?, &words(asked, "provider")?, &words(asked, "model")?, now()?)?,
        _ => return fail(format!("The program holds no rule named {question}.")),
    })
}

/// The line a question is answered with, and whether it is an answer.
fn line(question: &str, root: &Path, written: &[u8], machine: &Machine) -> (String, bool) {
    let answered = json::parse_asked(written).and_then(|asked| answer(question, root, &asked, machine)).and_then(|value| json::compact(&obj! {"value" => plain(&value)}, DEPTH));
    match answered {
        Ok(line) => (line, true),
        Err(stop) => (json::compact(&obj! {"error" => stop.message()}, 2).unwrap_or_else(|_| r#"{"error":"The program could not say why it has no answer."}"#.into()), false),
    }
}

/// `rule <question> --root <release> [--core]`: one line, and whether it is an answer.
pub fn started(arguments: &[OsString]) -> Result<bool, String> {
    let Some(started) = spelled(arguments) else {
        let words: Vec<String> = arguments.iter().map(|word| word.to_string_lossy().into_owned()).collect();
        return Err(format!("The rule was started with words it does not take: {}", words.join(" ")));
    };
    // The numbers of an answer are written as the PowerShell that asks would write them.
    set_core(started.core);
    packaged_data(&started.root);
    let mut written = Vec::new();
    // A question cut short is not JSON, and is refused as that.
    let _ = std::io::stdin().lock().take(json::MAX_ASKED_BYTES as u64 + 1).read_to_end(&mut written);
    let machine = Machine { cswap: &cswap::resolve_executable, codex: &|named| Search::here().program(named), clock: &Dto::now };
    let (line, answered) = line(&started.question, &started.root, &written, &machine);
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{line}");
    let _ = stdout.flush();
    Ok(answered)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::tests::{changed, noon, set, state};
    use crate::codex_read::tests::{answers, home, stand_in, LIMITS};
    use crate::files::tests::scratch;
    use crate::hash;
    use crate::sha256;
    use std::fs;

    fn root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("..")
    }
    fn file(directory: &Path, name: &str) -> V {
        json::parse(&fs::read_to_string(directory.join(name)).unwrap(), name).ok().unwrap()
    }
    fn names(value: &V) -> Vec<String> {
        value.props().ok().unwrap().iter().map(|(name, _)| name.to_string()).collect()
    }
    fn listed(values: &V, name: &str) -> Vec<String> {
        values.each().iter().map(|value| value.g(name).ok().unwrap().s().ok().unwrap()).collect()
    }
    fn written(value: &V) -> String {
        json::compact(value, 24).ok().unwrap()
    }

    /// The machine a test asks on: what its finders find, what its clock reads, and what
    /// they were asked. No test looks at the real PATH, a real home or the real clock.
    struct Stand {
        cswap: Option<String>,
        codex: Result<PathBuf, &'static str>,
        clock: R<Dto>,
        asked: RefCell<Vec<String>>,
    }

    impl Stand {
        /// A machine that has neither program, at noon.
        fn bare() -> Stand {
            Stand { cswap: None, codex: Err("codex_missing"), clock: Ok(noon()), asked: RefCell::new(Vec::new()) }
        }
        fn with(cswap: Option<&str>, codex: Result<PathBuf, &'static str>) -> Stand {
            Stand { cswap: cswap.map(String::from), codex, ..Stand::bare() }
        }
        fn at(clock: R<Dto>) -> Stand {
            Stand { clock, ..Stand::bare() }
        }
        fn sent(&self, question: &str, written: &[u8]) -> (String, bool) {
            let cswap = |named: Option<&str>| {
                self.asked.borrow_mut().push(format!("cswap {named:?}"));
                self.cswap.clone()
            };
            let codex = |named: Option<&str>| {
                self.asked.borrow_mut().push(format!("codex {named:?}"));
                self.codex.clone()
            };
            let clock = || {
                self.asked.borrow_mut().push("clock".to_string());
                match &self.clock {
                    Ok(now) => Ok(*now),
                    Err(_) => fail("this machine has no clock"),
                }
            };
            line(question, &root(), written, &Machine { cswap: &cswap, codex: &codex, clock: &clock })
        }
        fn line(&self, question: &str, asked: &V) -> (String, bool) {
            self.sent(question, written(asked).as_bytes())
        }
        /// The answer, as it is written.
        fn text(&self, question: &str, asked: V) -> String {
            let (line, answered) = self.line(question, &asked);
            assert!(answered, "{question}: {line}");
            line.strip_prefix(r#"{"value":"#).and_then(|rest| rest.strip_suffix('}')).unwrap().to_string()
        }
        /// The answer, as PowerShell reads it.
        fn value(&self, question: &str, asked: V) -> V {
            let (line, answered) = self.line(question, &asked);
            assert!(answered, "{question}: {line}");
            // Read as another program's text is: an answer holds numbers as PowerShell
            // writes them, which are more than a file of HotPl8's holds.
            json::parse_foreign(&line).ok().unwrap().g("value").ok().unwrap()
        }
        /// The words the question is refused in.
        fn refusal(&self, question: &str, asked: V) -> String {
            let (line, answered) = self.line(question, &asked);
            assert!(!answered, "{question}: {line}");
            let refusal = json::parse(&line, "refusal").ok().unwrap();
            assert_eq!(names(&refusal), ["error"]);
            refusal.g("error").ok().unwrap().s().ok().unwrap()
        }
        /// What the finders and the clock were asked since the last look.
        fn heard(&self) -> Vec<String> {
            self.asked.borrow_mut().drain(..).collect()
        }
    }

    /// The definitions this tree ships and Claude under each of these other names.
    fn registered(directory: &Path, aliases: &[&str]) {
        let shipped = root().join("data/providers");
        let catalog = directory.join("catalog");
        fs::create_dir_all(&catalog).unwrap();
        for name in ["claude.json", "codex.json"] {
            fs::copy(shipped.join(name), catalog.join(name)).unwrap();
        }
        let claude = fs::read_to_string(shipped.join("claude.json")).unwrap();
        for alias in aliases {
            assert_eq!((claude.matches(r#""id": "claude""#).count(), claude.matches(r#""name": "Claude""#).count()), (1, 1));
            let text = claude.replace(r#""id": "claude""#, &format!(r#""id": "{alias}""#)).replace(r#""name": "Claude""#, &format!(r#""name": "Other {alias}""#));
            fs::write(catalog.join(format!("{alias}.json")), text).unwrap();
        }
        crate::registry::set_source(catalog);
    }

    #[test]
    fn a_rule_is_started_with_a_question_and_a_release() {
        let words = |words: &[&str]| -> Vec<OsString> { words.iter().map(OsString::from).collect() };
        let usual = spelled(&words(&["fresh", "--root", "."])).unwrap();
        assert_eq!((usual.question.as_str(), usual.core), ("fresh", false));
        assert!(usual.root.is_absolute());
        // The edition that asks is named on either side of the release.
        assert!(spelled(&words(&["fresh", "--core", "--root", "."])).unwrap().core);
        assert!(spelled(&words(&["fresh", "--root", ".", "--core"])).unwrap().core);
        let refused: [&[&str]; 9] = [
            &[],
            &["fresh"],
            &["fresh", "--core"],
            &["fresh", "--root"],
            &["fresh", "--root", ""],
            &["fresh", "--root", ".", "--root", "."],
            &["fresh", "--core", "--root", ".", "--core"],
            &["fresh", "--root", ".", "--state", "."],
            &["fresh", "--root", ".", "more"],
        ];
        for refused in refused {
            assert!(spelled(&words(refused)).is_none(), "{refused:?}");
        }
        // Words it does not take are said back before anything is read.
        assert_eq!(started(&words(&["fresh", "--state", "x"])).err().unwrap(), "The rule was started with words it does not take: fresh --state x");
    }

    #[test]
    fn an_answer_is_one_line_and_so_is_a_refusal() {
        let stand = Stand::bare();
        assert_eq!(stand.line("codex.budget", &obj! {}), (r#"{"value":12000}"#.to_string(), true));
        assert_eq!(stand.line("nothing", &obj! {}), (r#"{"error":"The program holds no rule named nothing."}"#.to_string(), false));
        // Windows PowerShell opens the pipe it writes into with the mark.
        assert_eq!(stand.sent("cswap.timeout", b"\xef\xbb\xbf{}"), (r#"{"value":90000}"#.to_string(), true));
        // A question is one object, whole.
        for written in ["", "{", "[1]", "7", "\"fresh\"", "{} {}"] {
            assert_eq!(stand.sent("codex.budget", written.as_bytes()), (r#"{"error":"The question is not JSON as HotPl8 writes it."}"#.to_string(), false), "{written:?}");
        }
        assert_eq!(stand.sent("codex.budget", b"{\"a\":\"\xff\"}"), (r#"{"error":"The question is not UTF-8 text."}"#.to_string(), false));
        // Neither of those needed the machine.
        assert_eq!(stand.heard(), Vec::<String>::new());
    }

    #[test]
    fn a_hashtable_is_written_as_the_object_powershell_would_write() {
        let nested = hash! {"a" => vec![V::from(hash! {"b" => 1})], "c" => obj! {"d" => hash! {"e" => "f"}}};
        assert!(json::compact(&nested, 8).is_err());
        assert_eq!(written(&plain(&nested)), r#"{"a":[{"b":1}],"c":{"d":{"e":"f"}}}"#);
        assert_eq!(written(&plain(&V::Null)), "null");
    }

    #[test]
    fn a_question_brings_its_clock_or_reads_the_machines() {
        let directory = state("rule-clock");
        let collector = file(&directory, "status.json").g("collector").ok().unwrap();
        let reading = "2026-09-12T11:59:18.0000000+00:00";
        let day_later = "2026-09-13T12:00:00.0000000+00:00";
        let noon_stand = Stand::bare();
        let late = Stand::at(Dto::parse(day_later));
        // The machine's clock, read once.
        assert_eq!(noon_stand.text("fresh", obj! {"timestamp" => reading}), "true");
        assert_eq!(noon_stand.heard(), ["clock"]);
        assert_eq!(late.text("fresh", obj! {"timestamp" => reading}), "false");
        assert_eq!(noon_stand.text("health", obj! {"collector" => &collector, "provider" => "claude"}), r#""recent collection completed""#);
        assert_eq!(late.text("health", obj! {"collector" => &collector, "provider" => "claude"}), r#""collector overdue""#);
        assert_eq!(late.heard(), ["clock", "clock"]);
        assert_eq!(noon_stand.heard(), ["clock"]);
        // The question's own, and then the machine's is not read at all.
        assert_eq!(late.text("fresh", obj! {"timestamp" => reading, "now" => "2026-09-12T14:00:00.0000000+02:00"}), "true");
        assert_eq!(noon_stand.text("fresh", obj! {"timestamp" => reading, "now" => day_later}), "false");
        assert_eq!(noon_stand.text("health", obj! {"collector" => &collector, "provider" => "claude", "now" => day_later}), r#""collector overdue""#);
        assert_eq!((late.heard(), noon_stand.heard()), (Vec::<String>::new(), Vec::<String>::new()));
        let broken = Stand::at(fail("no clock"));
        assert_eq!(broken.text("fresh", obj! {"timestamp" => reading, "now" => NOON_TEXT}), "true");
        assert_eq!(broken.refusal("fresh", obj! {"timestamp" => reading}), "this machine has no clock");
        // A clock that is not a time HotPl8 writes is refused, never guessed at.
        for odd in [V::from("tomorrow"), V::from(""), V::from(1789214400), V::from(true)] {
            let (line, answered) = noon_stand.line("fresh", &obj! {"timestamp" => reading, "now" => &odd});
            assert!(!answered && line.starts_with(r#"{"error":"This state cannot be shown"#), "{line}");
        }
        // A rule that needs no clock reads none.
        assert_eq!(broken.text("codex.budget", obj! {}), "12000");
        assert_eq!(broken.text("provider.accounts", obj! {"policy" => file(&directory, "policy.json")}).len() > 2, true);
    }
    const NOON_TEXT: &str = "2026-09-12T12:00:00.0000000+00:00";

    #[test]
    fn a_program_is_found_by_the_machine_the_rule_runs_on() {
        let stand = Stand::with(Some("C:/fixture/cswap.exe"), Ok(PathBuf::from("C:/fixture/codex.exe")));
        assert_eq!(stand.text("cswap.find", obj! {}), r#""C:/fixture/cswap.exe""#);
        assert_eq!(stand.text("cswap.find", obj! {"explicit" => ""}), r#""C:/fixture/cswap.exe""#);
        assert_eq!(stand.text("cswap.find", obj! {"explicit" => V::Null}), r#""C:/fixture/cswap.exe""#);
        assert_eq!(stand.heard(), ["cswap None", "cswap None", "cswap None"]);
        stand.text("cswap.find", obj! {"explicit" => "named.exe"});
        assert_eq!(stand.heard(), [r#"cswap Some("named.exe")"#]);
        assert_eq!(stand.text("codex.find", obj! {}), r#""C:/fixture/codex.exe""#);
        stand.text("codex.find", obj! {"explicit" => ""});
        stand.text("codex.find", obj! {"explicit" => "named.exe"});
        assert_eq!(stand.heard(), ["codex None", "codex None", r#"codex Some("named.exe")"#]);
        // No cswap is nothing; no Codex is the name PowerShell throws.
        assert_eq!(Stand::bare().text("cswap.find", obj! {}), "null");
        assert_eq!(Stand::bare().refusal("codex.find", obj! {}), "codex_missing");
        assert_eq!(Stand::with(None, Err("native_codex_required")).refusal("codex.find", obj! {"explicit" => "codex.cmd"}), "native_codex_required");
        assert_eq!(stand.text("cswap.timeout", obj! {}), "90000");
        assert_eq!(stand.text("codex.budget", obj! {}), "12000");
        assert_eq!(stand.heard(), Vec::<String>::new());
    }

    #[test]
    fn a_codex_account_is_read_without_its_sign_in() {
        set_core(false);
        let stand = Stand::with(None, Ok(stand_in()));
        let home = home("rule-read", &answers(&[]));
        fs::write(Path::new(&home).join("auth.json"), r#"{"tokens":{"access_token":"fixture-not-a-token","account_id":"acct-fixture"}}"#).unwrap();
        let (line, answered) = stand.line("codex.read", &obj! {"home" => home.as_str(), "timeoutMs" => 20_000});
        assert!(answered, "{line}");
        assert_eq!(stand.heard(), ["codex None"]);
        let read = json::parse(&line, "answer").ok().unwrap().g("value").ok().unwrap();
        assert_eq!(names(&read), ["status", "quota", "identityKey", "planType", "model", "modelProvider", "standardTransport", "elapsedMs"]);
        assert_eq!(written(&read.g("quota").ok().unwrap()), LIMITS);
        let rest = obj! {"status" => read.g("status").ok().unwrap(), "planType" => read.g("planType").ok().unwrap(), "model" => read.g("model").ok().unwrap(), "modelProvider" => read.g("modelProvider").ok().unwrap(), "standardTransport" => read.g("standardTransport").ok().unwrap()};
        assert_eq!(written(&rest), r#"{"status":"ok","planType":"plus","model":"gpt-fixture","modelProvider":"openai","standardTransport":true}"#);
        assert_eq!(read.g("identityKey").ok().unwrap().s().ok().unwrap().len(), 64);
        assert!(read.g("elapsedMs").ok().unwrap().is_number() && read.g("elapsedMs").ok().unwrap().lt_i(20_000).ok().unwrap());
        // Neither the sign-in nor the address leaves the program.
        assert!(!line.contains("fixture-not-a-token") && !line.contains("example.invalid") && !line.contains("acct-fixture"), "{line}");

        // Who is signed in: the same members, no limits, and whether the sign-in vouches.
        let (line, answered) = stand.line("codex.read", &obj! {"home" => home.as_str(), "executable" => "named.exe", "workingDirectory" => "", "timeoutMs" => 20_000, "identityOnly" => true});
        assert!(answered, "{line}");
        assert_eq!(stand.heard(), [r#"codex Some("named.exe")"#]);
        let who = json::parse(&line, "answer").ok().unwrap().g("value").ok().unwrap();
        assert_eq!(names(&who), ["status", "quota", "identityKey", "planType", "model", "modelProvider", "standardTransport", "elapsedMs", "identityVerified"]);
        assert!(who.g("quota").ok().unwrap().is_null() && who.g("identityVerified").ok().unwrap().is_true().ok().unwrap());
        assert_eq!(who.g("identityKey").ok().unwrap().s().ok().unwrap(), sha256::hash("fixture-a@example.invalid|acct-fixture"));
        assert!(!line.contains("fixture-not-a-token") && !line.contains("example.invalid") && !line.contains("acct-fixture"), "{line}");
        fs::remove_file(Path::new(&home).join("auth.json")).unwrap();
        let unsigned = stand.value("codex.read", obj! {"home" => home.as_str(), "timeoutMs" => 20_000, "identityOnly" => true});
        assert!(unsigned.g("identityVerified").ok().unwrap().is_false().ok().unwrap());

        // A read that fails is its name and how long it took, and nothing else.
        let absent = Path::new(&home).join("absent");
        for missing in [absent.to_str().unwrap(), "relative-home", ""] {
            let failed = stand.value("codex.read", obj! {"home" => missing, "timeoutMs" => 20_000});
            assert_eq!(names(&failed), ["status", "elapsedMs"], "{missing}");
            assert_eq!(failed.g("status").ok().unwrap().s().ok().unwrap(), "home_missing", "{missing}");
        }
        assert_eq!(Stand::bare().text("codex.read", obj! {"home" => home.as_str()}), r#"{"status":"codex_missing","elapsedMs":0}"#);
        assert_eq!(Stand::with(None, Err("native_codex_required")).text("codex.read", obj! {"home" => home.as_str()}), r#"{"status":"native_codex_required","elapsedMs":0}"#);
        // The time it is given is the time it has.
        let hurried = stand.value("codex.read", obj! {"home" => home.as_str(), "timeoutMs" => -5});
        assert_eq!(hurried.g("status").ok().unwrap().s().ok().unwrap(), "timeout");
    }

    #[test]
    fn history_is_counted_store_by_store() {
        let directory = state("rule-history");
        let place = directory.to_str().unwrap();
        let stand = Stand::bare();
        let policy = file(&directory, "policy.json");
        let stores = |policy: &V| stand.value("history", obj! {"policy" => policy, "directory" => place});
        // The canonical providers share the directory itself.
        assert_eq!(written(&stores(&policy)), format!(r#"[{{"directory":{},"providers":["claude","codex"],"samples":0}}]"#, json::text(place)));
        fs::write(directory.join("usage-history.json"), r#"{"schemaVersion":1,"samples":[{"at":"2026-09-12T11:00:00.0000000+00:00"},null,{"at":"2026-09-12T11:30:00.0000000+00:00"}]}"#).unwrap();
        assert_eq!(written(&stores(&policy).each()[0].g("samples").ok().unwrap()), "2");
        // A provider registered under another name keeps a store of its own, and the
        // stores are listed in the order of their directories.
        registered(&directory, &["zeta-claude", "alpha-claude"]);
        let aliased = json::parse(r#"{"schemaVersion":3,"mode":"monitor","providers":{"zeta-claude":{"prefer":[1],"reserve":[]},"claude":{"prefer":[1],"reserve":[]},"alpha-claude":{"prefer":[1],"reserve":[]}}}"#, "policy").ok().unwrap();
        let own = |alias: &str| directory.join("providers").join(alias);
        fs::create_dir_all(own("zeta-claude")).unwrap();
        fs::write(own("zeta-claude").join("usage-history.json"), r#"{"schemaVersion":1,"samples":[{"at":"2026-09-12T11:00:00.0000000+00:00"}]}"#).unwrap();
        let listed_stores = stores(&aliased);
        assert_eq!(listed(&listed_stores, "directory"), [place, own("alpha-claude").to_str().unwrap(), own("zeta-claude").to_str().unwrap()]);
        let rest: Vec<String> = listed_stores.each().iter().map(|store| format!("{} {}", written(&store.g("providers").ok().unwrap()), written(&store.g("samples").ok().unwrap()))).collect();
        assert_eq!(rest, [r#"["claude"] 2"#, r#"["alpha-claude"] 0"#, r#"["zeta-claude"] 1"#]);
        // Only aliases: no shared store is listed, and no directory is made by looking.
        let only = json::parse(r#"{"schemaVersion":3,"mode":"monitor","providers":{"alpha-claude":{"prefer":[1],"reserve":[]}}}"#, "policy").ok().unwrap();
        assert_eq!(listed(&stores(&only), "directory"), [own("alpha-claude").to_str().unwrap()]);
        assert!(!own("alpha-claude").exists());
        assert_eq!(stand.refusal("history", obj! {"policy" => &only}), "The question names no directory.");
    }

    #[test]
    fn a_providers_state_is_its_own_directory_or_one_inside() {
        let directory = state("rule-state");
        let place = directory.to_str().unwrap();
        let stand = Stand::bare();
        registered(&directory, &["fictional-claude"]);
        let at = |provider: &str| stand.value("provider.state", obj! {"directory" => place, "provider" => provider}).s().ok().unwrap();
        assert_eq!((at("claude"), at("codex")), (place.to_string(), place.to_string()));
        assert_eq!(at("fictional-claude"), directory.join("providers").join("fictional-claude").to_str().unwrap());
        assert!(!directory.join("providers").exists());
        assert_eq!(stand.refusal("provider.state", obj! {"directory" => place, "provider" => "nothing"}), "Provider is not registered.");
        assert_eq!(stand.refusal("provider.state", obj! {"provider" => "codex"}), "The question names no directory.");
        assert_eq!(stand.refusal("provider.state", obj! {"directory" => "", "provider" => "codex"}), "The question names no directory.");
    }

    #[test]
    fn a_policy_is_checked_in_the_words_powershell_throws() {
        let directory = state("rule-policy");
        let stand = Stand::bare();
        let policy = file(&directory, "policy.json");
        assert_eq!(stand.text("policy.check", obj! {"policy" => &policy}), "null");
        assert_eq!(stand.refusal("policy.check", obj! {"policy" => obj! {"schemaVersion" => 7}}), "Invalid policy: unsupported schemaVersion.");
        assert_eq!(stand.refusal("policy.check", obj! {}), "Invalid policy: expected an object.");
        assert_eq!(stand.text("codex.check", obj! {"policy" => policy.g("codex").ok().unwrap()}), "null");
        assert_eq!(stand.refusal("codex.check", obj! {"policy" => obj! {"slots" => vec![V::from(obj! {"id" => "work"})]}}), "invalid_home");
        // The two checks are two rules: the whole policy is not a Codex policy's shape.
        assert_eq!(stand.refusal("policy.check", obj! {"policy" => obj! {"schemaVersion" => 2, "mode" => "monitor", "prefer" => vec![V::from(1)], "reserve" => Vec::<V>::new(), "weights" => obj! {"a" => 0}}}), "Invalid policy field: weights");
    }

    #[test]
    fn what_a_policy_lets_hotpl8_do() {
        let directory = state("rule-actions");
        let stand = Stand::bare();
        let policy = file(&directory, "policy.json");
        let allowed = |policy: &V, observe: bool| stand.text("policy.actions", obj! {"policy" => policy, "observeOnly" => observe});
        assert_eq!(allowed(&policy, false), r#"{"switching":false,"warming":false,"probing":false,"continuing":false}"#);
        set(&policy, "mode", "automate".into());
        assert_eq!(allowed(&policy, false), r#"{"switching":false,"warming":false,"probing":false,"continuing":true}"#);
        set(&policy, "switchEnabled", true.into());
        assert_eq!(allowed(&policy, false), r#"{"switching":true,"warming":false,"probing":false,"continuing":true}"#);
        set(&policy, "warm", true.into());
        set(&policy, "probeEnabled", true.into());
        set(&policy, "automation", obj! {"continue" => false});
        assert_eq!(allowed(&policy, false), r#"{"switching":true,"warming":true,"probing":true,"continuing":false}"#);
        assert_eq!(allowed(&policy, true), r#"{"switching":false,"warming":false,"probing":false,"continuing":false}"#);
        // Asked without the word, it is not observing only.
        assert_eq!(stand.text("policy.actions", obj! {"policy" => &policy}), allowed(&policy, false));
    }

    #[test]
    fn a_snapshot_is_read_with_what_a_reader_adds() {
        let directory = state("rule-snapshot");
        let place = directory.to_str().unwrap();
        let stand = Stand::bare();
        let mut expected = names(&file(&directory, "status.json"));
        let read = stand.value("snapshot", obj! {"directory" => place});
        expected.extend(["automationPause", "providerOverview", "parkCandidates"].map(String::from));
        assert_eq!(names(&read), expected);
        assert!(read.g("automationPause").ok().unwrap().is_null() && read.g("providerOverview").ok().unwrap().t().ok().unwrap());
        assert_eq!(written(&read.g("parkCandidates").ok().unwrap()), "[]");
        // The policy of the directory is the one it is read by, unless one is given.
        changed(&directory, "status.json", |status| {
            for slot in status.path(&["providers", "codex", "slots"]).ok().unwrap().arr() {
                set(&slot, "planType", "free".into());
            }
        });
        let candidates = |asked: V| listed(&stand.value("snapshot", asked).g("parkCandidates").ok().unwrap(), "slot");
        assert_eq!(candidates(obj! {"directory" => place}), ["work", "personal"]);
        let given = file(&directory, "policy.json");
        set(&given.g("codex").ok().unwrap(), "disabled", vec![V::from("work")].into());
        assert_eq!(candidates(obj! {"directory" => place, "policy" => &given}), ["personal"]);
        let explicit = stand.value("snapshot", obj! {"directory" => place, "policy" => &given});
        expected.insert(expected.len() - 2, "displayPolicy".to_string());
        assert_eq!(names(&explicit), expected);
        assert_eq!(written(&explicit.g("displayPolicy").ok().unwrap()), r#""explicit reader policy""#);
        // The question's clock is the reader's: a day on, the snapshot shows nothing to park.
        assert_eq!(candidates(obj! {"directory" => place, "now" => "2026-09-13T12:00:00.0000000+00:00"}), Vec::<String>::new());
        // No snapshot is nothing; a pause with none is still shown.
        let empty = scratch("rule-snapshot-empty");
        assert_eq!(stand.text("snapshot", obj! {"directory" => empty.to_str().unwrap()}), "null");
        fs::write(empty.join("automation-pause.json"), r#"{"until":"2026-09-12T13:00:00.0000000+00:00","reason":"fixture"}"#).unwrap();
        let paused = stand.value("snapshot", obj! {"directory" => empty.to_str().unwrap()});
        assert_eq!(names(&paused), ["schemaVersion", "generatedAt", "slots", "automationPause", "providerOverview", "parkCandidates"]);
        assert_eq!(written(&paused.g("automationPause").ok().unwrap()), r#"{"until":"2026-09-12T13:00:00.0000000+00:00","reason":"fixture"}"#);
        assert_eq!(stand.refusal("snapshot", obj! {}), "The question names no directory.");
    }

    #[test]
    fn accounts_that_could_be_parked_and_why() {
        let directory = state("rule-park");
        let stand = Stand::bare();
        let policy = file(&directory, "policy.json");
        let found = |snapshot: &V| stand.text("park.candidates", obj! {"snapshot" => snapshot, "policy" => &policy});
        let snapshot = file(&directory, "status.json");
        assert_eq!(found(&snapshot), "[]");
        // A plan that ended, read just now.
        let work = snapshot.path(&["providers", "codex", "slots"]).ok().unwrap().arr()[0].clone();
        set(&work, "planType", "free".into());
        set(&work, "observedAt", "2026-09-12T11:59:18.0000000+00:00".into());
        assert_eq!(
            found(&snapshot),
            r#"[{"provider":"codex","providerName":"Codex","family":"codex","slot":"work","label":"Work","reason":"canceled","days":0,"lastReadingAt":"2026-09-12T11:59:18.0000000+00:00","planType":"free"}]"#
        );
        // A login that has not answered for a week or more, and is not the one in use.
        let reserve = snapshot.g("slots").ok().unwrap().arr()[1].clone();
        set(&reserve, "status", "relogin_required".into());
        set(&reserve, "lastGoodAt", "2026-09-03T11:00:00.0000000+00:00".into());
        let both = stand.value("park.candidates", obj! {"snapshot" => &snapshot, "policy" => &policy});
        assert_eq!(
            written(&both.each()[0]),
            r#"{"provider":"claude","providerName":"Claude","family":"claude","slot":"2","label":"Reserve","reason":"dormant","days":9,"lastReadingAt":"2026-09-03T11:00:00.0000000+00:00","planType":null}"#
        );
        assert_eq!(listed(&both, "reason"), ["dormant", "canceled"]);
        let said: Vec<String> = both.each().iter().map(|candidate| stand.text("park.reason", obj! {"candidate" => candidate})).collect();
        assert_eq!(said, [r#""no reading for 9 days""#, r#""plan ended (now free)""#]);
        // Six days is not a long absence, and a day on the snapshot is evidence of nothing.
        set(&reserve, "lastGoodAt", "2026-09-06T11:00:00.0000000+00:00".into());
        assert_eq!(listed(&stand.value("park.candidates", obj! {"snapshot" => &snapshot, "policy" => &policy}), "reason"), ["canceled"]);
        assert_eq!(stand.text("park.candidates", obj! {"snapshot" => &snapshot, "policy" => &policy, "now" => "2026-09-13T12:00:00.0000000+00:00"}), "[]");
        assert_eq!(stand.heard().iter().filter(|heard| *heard != "clock").count(), 0);
    }

    #[test]
    fn the_doctor_is_told_what_the_machine_has() {
        let directory = state("rule-doctor");
        let place = directory.to_str().unwrap();
        let has = |stand: &Stand| {
            let report = stand.value("doctor", obj! {"directory" => place});
            (report.g("cswapFound").ok().unwrap().is_true().ok().unwrap(), report.g("codexFound").ok().unwrap().is_true().ok().unwrap())
        };
        let both = Stand::with(Some("C:/fixture/cswap.exe"), Ok(PathBuf::from("C:/fixture/codex.exe")));
        assert_eq!(has(&both), (true, true));
        // Each program is looked for as a command with none named looks for it.
        assert_eq!(both.heard(), ["cswap None", "codex None", "clock"]);
        assert_eq!(has(&Stand::with(Some("C:/fixture/cswap.exe"), Err("native_codex_required"))), (true, false));
        assert_eq!(has(&Stand::with(None, Ok(PathBuf::from("C:/fixture/codex.exe")))), (false, true));
        assert_eq!(has(&Stand::with(Some(""), Err("codex_missing"))), (false, false));
        let version = fs::read_to_string(root().join("VERSION")).unwrap();
        assert_eq!(
            Stand::bare().text("doctor", obj! {"directory" => place}),
            format!(
                r#"{{"providers":{{"claude":{{"driver":"claude-cswap","configured":true,"installed":false}},"codex":{{"driver":"codex-app-server","configured":true,"installed":false}}}},"version":"{}","policyPresent":true,"policyValid":true,"mode":"monitor","claudeConfigured":true,"codexConfigured":true,"cswapFound":false,"codexFound":false,"snapshotAgeSeconds":42,"snapshotFresh":true,"collectorBusy":false,"parkCandidates":0,"continue":{{"enabled":false,"lastAt":null}}}}"#,
                version.trim()
            )
        );
        let later = Stand::bare().value("doctor", obj! {"directory" => place, "now" => "2026-09-12T12:20:00.0000000+00:00"});
        assert_eq!(written(&obj! {"age" => later.g("snapshotAgeSeconds").ok().unwrap(), "fresh" => later.g("snapshotFresh").ok().unwrap()}), r#"{"age":1242,"fresh":false}"#);
        assert_eq!(Stand::bare().refusal("doctor", obj! {}), "The question names no directory.");
        // What this copy can do is reported of the same machine.
        let able = |stand: &Stand| {
            let report = stand.value("capabilities", obj! {"directory" => place});
            written(&obj! {"claude" => report.path(&["providers", "claude", "installed"]).ok().unwrap(), "codex" => report.path(&["providers", "codex", "installed"]).ok().unwrap(), "fresh" => report.path(&["providers", "codex", "freshAccounts"]).ok().unwrap()})
        };
        let only = Stand::with(Some("C:/fixture/cswap.exe"), Err("codex_missing"));
        assert_eq!(able(&only), r#"{"claude":true,"codex":false,"fresh":2}"#);
        assert_eq!(only.heard(), ["cswap None", "codex None", "clock"]);
        assert_eq!(able(&Stand::with(None, Ok(PathBuf::from("C:/fixture/codex.exe")))), r#"{"claude":false,"codex":true,"fresh":2}"#);
        assert_eq!(Stand::bare().refusal("capabilities", obj! {}), "The question names no directory.");
    }

    #[test]
    fn the_agent_interface_is_answered_through_the_door() {
        let directory = state("rule-agent");
        let place = directory.to_str().unwrap();
        let stand = Stand::bare();
        let accounts = stand.value("agent", obj! {"operation" => "accounts", "directory" => place});
        assert_eq!(names(&accounts), ["data"]);
        assert_eq!(accounts.path(&["data", "accounts"]).ok().unwrap().each().len(), 4);
        // A code is an answer: the envelope it is reported in is PowerShell's.
        assert_eq!(stand.text("agent", obj! {"operation" => "readiness", "directory" => place, "provider" => "claude", "model" => "gpt-fixture"}), r#"{"code":"model_unknown"}"#);
        fs::remove_file(directory.join("status.json")).unwrap();
        assert_eq!(stand.text("agent", obj! {"operation" => "status", "directory" => place}), r#"{"code":"snapshot_missing"}"#);
        assert_eq!(stand.refusal("agent", obj! {"operation" => "doctor", "directory" => place}), "The agent interface has no operation named doctor that is answered from the files.");
        assert_eq!(stand.refusal("agent", obj! {"operation" => "status"}), "The question names no directory.");
    }

    #[test]
    fn the_agent_interface_reads_the_questions_clock() {
        let directory = state("rule-agent-clock");
        let place = directory.to_str().unwrap();
        let age = |stand: &Stand, asked: V| written(&stand.value("agent", asked).path(&["data", "ageSeconds"]).ok().unwrap());
        assert_eq!(age(&Stand::bare(), obj! {"operation" => "status", "directory" => place}), "42");
        assert_eq!(age(&Stand::at(fail("no clock")), obj! {"operation" => "status", "directory" => place, "now" => "2026-09-12T12:00:01.2350000+00:00"}), "43.235");
    }

    #[test]
    fn an_event_is_one_line_in_the_log() {
        let directory = scratch("rule-event");
        let place = directory.to_str().unwrap();
        let stand = Stand::bare();
        assert_eq!(stand.text("event", obj! {"directory" => place, "code" => "continue_sent"}), "null");
        assert_eq!(stand.text("event", obj! {"directory" => place, "code" => "continue_skipped"}), "null");
        let log = fs::read_to_string(directory.join("events.jsonl")).unwrap();
        let lines: Vec<&str> = log.lines().collect();
        assert_eq!(lines.len(), 2);
        for (line, code) in lines.iter().zip(["continue_sent", "continue_skipped"]) {
            let event = json::parse(line, "event").ok().unwrap();
            assert_eq!(names(&event), ["at", "code"]);
            assert_eq!(event.g("code").ok().unwrap().s().ok().unwrap(), code);
            assert!(Dto::parse(&event.g("at").ok().unwrap().s().ok().unwrap()).is_ok());
        }
        assert_eq!(stand.refusal("event", obj! {"code" => "continue_sent"}), "The question names no directory.");
    }

    /// Each remaining question, once: asked of the rule its name says.
    #[test]
    fn every_question_reaches_its_rule() {
        let directory = state("rule-every");
        let place = directory.to_str().unwrap();
        let stand = Stand::bare();
        let policy = file(&directory, "policy.json");
        let snapshot = file(&directory, "status.json");

        let driver = stand.value("provider.driver", obj! {"id" => "codex-app-server"});
        assert_eq!(written(&obj! {"id" => driver.g("id").ok().unwrap(), "provider" => driver.g("provider").ok().unwrap(), "slotKind" => driver.g("slotKind").ok().unwrap()}), r#"{"id":"codex-app-server","provider":"codex","slotKind":"native-home"}"#);
        assert_eq!(stand.refusal("provider.driver", obj! {"id" => "nothing"}), "Unknown provider driver. Only shipped native contracts may be registered.");
        // The driver a registered provider is read through, in the one start.
        assert_eq!(written(&stand.value("provider.driver", obj! {"provider" => "claude"}).g("slotKind").ok().unwrap()), r#""numeric""#);
        assert_eq!(written(&stand.value("provider.driver", obj! {"provider" => "codex", "id" => "claude-cswap"}).g("id").ok().unwrap()), r#""codex-app-server""#);
        assert_eq!(stand.refusal("provider.driver", obj! {"provider" => "nothing"}), "Provider is not registered.");
        assert_eq!(listed(&stand.value("provider.catalog", obj! {}), "id"), ["claude", "codex"]);
        assert_eq!(listed(&stand.value("provider.catalog", obj! {}), "driver"), ["claude-cswap", "codex-app-server"]);
        let definition = stand.value("provider.definition", obj! {"id" => "codex"});
        assert_eq!(written(&obj! {"id" => definition.g("id").ok().unwrap(), "name" => definition.g("name").ok().unwrap(), "meters" => definition.g("meters").ok().unwrap()}), r#"{"id":"codex","name":"Codex","meters":["codex","codex_bengalfox"]}"#);
        assert_eq!(stand.refusal("provider.definition", obj! {"id" => "nothing"}), "Provider is not registered.");

        // Only what the policy configures, unless everything registered is asked for.
        let claude_only = obj! {"schemaVersion" => 2, "mode" => "monitor", "prefer" => vec![V::from(1)], "reserve" => Vec::<V>::new()};
        let configured = stand.value("provider.configured", obj! {"policy" => &policy});
        assert_eq!(listed(&configured, "id"), ["claude", "codex"]);
        assert_eq!(names(&configured.each()[0])[..5], ["id", "name", "driver", "definition", "policy"]);
        assert_eq!(listed(&stand.value("provider.configured", obj! {"policy" => &claude_only}), "id"), ["claude"]);
        assert_eq!(listed(&stand.value("provider.configured", obj! {"policy" => &claude_only, "includeUnconfigured" => true}), "id"), ["claude", "codex"]);
        assert_eq!(stand.value("provider.one", obj! {"policy" => &policy, "provider" => "codex"}).g("name").ok().unwrap().s().ok().unwrap(), "Codex");
        assert_eq!(stand.refusal("provider.one", obj! {"policy" => &claude_only, "provider" => "codex"}), "Provider is not configured.");
        assert_eq!(stand.value("provider.one", obj! {"policy" => &claude_only, "provider" => "codex", "includeUnconfigured" => true}).g("id").ok().unwrap().s().ok().unwrap(), "codex");
        assert_eq!(stand.refusal("provider.one", obj! {"policy" => &policy, "provider" => "nothing"}), "Provider is not registered.");

        let view = stand.value("provider.view", obj! {"snapshot" => &snapshot, "policy" => &policy, "provider" => "codex"});
        assert_eq!(names(&view)[..6], ["providerId", "provider", "driver", "registration", "policy", "snapshot"]);
        // The driver is handed the shapes it has always read: its part under its own name.
        assert_eq!(names(&view.g("policy").ok().unwrap()), ["schemaVersion", "mode", "codex"]);
        assert_eq!(written(&view.path(&["policy", "codex"]).ok().unwrap()), written(&policy.g("codex").ok().unwrap()));
        assert_eq!(written(&view.path(&["snapshot", "providers"]).ok().unwrap()), written(&obj! {"codex" => snapshot.path(&["providers", "codex"]).ok().unwrap()}));
        assert_eq!(written(&view.path(&["snapshot", "slots"]).ok().unwrap()), "[]");
        assert_eq!(
            stand.text("provider.accounts", obj! {"policy" => &policy}),
            r#"[{"provider":"claude","slot":"1","label":"Everyday","capacity":{"fiveHour":0.3,"weekly":1},"disabled":false,"reserve":false},{"provider":"claude","slot":"2","label":"Reserve","capacity":{"fiveHour":1.5,"weekly":5},"disabled":false,"reserve":true},{"provider":"codex","slot":"work","label":"Work","capacity":{"fiveHour":1.5,"weekly":5},"disabled":false,"reserve":false},{"provider":"codex","slot":"personal","label":"Personal","capacity":{"fiveHour":0.3,"weekly":1},"disabled":false,"reserve":false}]"#
        );

        // A pause by a person, and one by an agent's lease.
        assert_eq!((stand.text("pause", obj! {"directory" => place}), stand.text("lease.pause", obj! {"directory" => place})), ("null".to_string(), "null".to_string()));
        fs::write(directory.join("automation-pause.json"), r#"{"until":"2026-09-12T13:00:00.0000000+00:00","reason":"fixture"}"#).unwrap();
        assert_eq!(stand.text("pause", obj! {"directory" => place}), r#"{"until":"2026-09-12T13:00:00.0000000+00:00","reason":"fixture"}"#);
        assert_eq!(stand.text("lease.pause", obj! {"directory" => place}), "null");
        assert_eq!(stand.text("pause", obj! {"directory" => place, "now" => "2026-09-12T13:00:00.0000000+00:00"}), "null");
        assert_eq!(stand.refusal("pause", obj! {}), "The question names no directory.");
        assert_eq!(stand.refusal("lease.pause", obj! {}), "The question names no directory.");

        let capacity = stand.value("capacity.catalog", obj! {});
        assert_eq!(names(&capacity)[..2], ["schemaVersion", "verifiedAt"]);
        assert!(capacity.path(&["profiles", "claude-pro"]).ok().unwrap().t().ok().unwrap());

        let replayed = stand.value("replay", obj! {"frames" => vec![snapshot.clone()], "policy" => &policy});
        assert_eq!(names(&replayed), ["schemaVersion", "frames", "decisions", "summary", "limitation"]);
        assert_eq!(written(&replayed.g("frames").ok().unwrap()), "1");
        assert_eq!(written(&replayed.g("decisions").ok().unwrap().each()[0]), r#"{"stream":"claude/prefer","at":"2026-09-12T11:59:18.0000000+00:00","selected":1,"reserve":false}"#);
        assert_eq!(written(&stand.value("replay", obj! {"policy" => &policy}).g("frames").ok().unwrap()), "0");
    }
}

//! `hotpl8-native codex`: Codex started in the home of the account this launch is given,
//! on the caller's own terminal, and ended with as Codex ends. The account is chosen by the
//! rules every other choice is made with, and its home is read once more before Codex is
//! started in it: a launch never trusts what a collection found some minutes ago.

use crate::capacity::capacity_accounts;
use crate::codex::codex_eligibility;
use crate::codex_collect::codex_buckets;
use crate::codex_read::{read_home_as, Asked, HomeRead, Search, READ_BUDGET_MS};
use crate::contract::age_seconds;
use crate::control::{action_authorization, control_snapshot, provider_action_context};
use crate::decision::provider_decision;
use crate::display::{packaged_data, state_directory};
use crate::json;
use crate::observation::{add_observation_capacity, codex_observation};
use crate::policy::{assert_codex_policy, assert_policy};
use crate::ps::*;
use crate::registry::{configured_provider, copy, provider_state_directory, provider_view};
use crate::request::full_path;
use crate::route::{bound, named, CONFLICTS};
use crate::time::Dto;
use crate::{hash, obj};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// The options of Codex that would choose the model, the account or the place for it.
const OPTIONS: [&str; 9] = ["--config", "--profile", "--oss", "--local-provider", "--model", "--cd", "--remote", "--remote-auth-token-env", "--ignore-user-config"];

/// The commands of Codex that are no session in an account's home.
const COMMANDS: [&str; 23] = [
    "login",
    "logout",
    "app-server",
    "mcp",
    "mcp-server",
    "app",
    "agents",
    "cloud",
    "remote-control",
    "exec-server",
    "plugin",
    "debug",
    "sandbox",
    "completion",
    "doctor",
    "features",
    "update",
    "apply",
    "queue",
    "archive",
    "delete",
    "unarchive",
    "migrate-rollouts",
];

/// One launch, and what it is prepared with. A test says what the environment holds, what
/// a read answers and what time it is; the command asks the machine.
pub struct Launch<'a> {
    /// The state directory.
    pub directory: &'a Path,
    pub provider: &'a str,
    /// The account asked for, or nothing for the one HotPl8 would choose.
    pub slot: &'a str,
    pub model: &'a str,
    /// The words for Codex.
    pub words: &'a [String],
    /// Where the caller works, and Codex will.
    pub working: &'a str,
    /// The caller's environment holds this key.
    pub conflict: &'a dyn Fn(&str) -> bool,
    pub program: &'a dyn Fn() -> Result<PathBuf, &'static str>,
    /// One read of the home named, inside the milliseconds given.
    pub read: &'a dyn Fn(&str, &Asked, u64) -> HomeRead,
    pub clock: &'a dyn Fn() -> R<Dto>,
}

/// Get-CodexLaunchPlan's answer: the account, and what it was chosen with.
pub struct Plan {
    part: V,
    slot: V,
    meter: String,
    automatic: bool,
    emergency: bool,
    observations: Vec<V>,
    context: V,
    status: V,
}

/// What Codex is started with.
#[derive(Debug)]
pub struct Prepared {
    pub program: PathBuf,
    pub home: String,
    pub slot: String,
    pub meter: String,
    /// Where this provider keeps its state.
    pub state: PathBuf,
    pub words: Vec<String>,
}

/// A word as any runtime that ignores case reads it: PowerShell compared these words by
/// the culture it ran under, and four characters outside ASCII are an ASCII letter to one
/// culture or another.
fn folded(word: &str) -> String {
    word.chars()
        .map(|letter| match letter {
            '\u{130}' | '\u{131}' => 'i',
            '\u{17f}' => 's',
            '\u{212a}' => 'k',
            other => other.to_ascii_lowercase(),
        })
        .collect()
}

/// The word would choose the model, the account, the endpoint or the place for Codex, or
/// asks it for something that is no session.
fn overrides(word: &str) -> bool {
    let word = folded(word);
    let option = OPTIONS.iter().any(|name| word.strip_prefix(name).is_some_and(|rest| rest.is_empty() || rest == "\n" || rest.starts_with('=')));
    let short = word.strip_prefix('-').is_some_and(|rest| rest.starts_with(['c', 'p', 'm']));
    option || short || COMMANDS.contains(&word.as_str())
}

/// hotpl8.ps1's own part of a launch, and Get-CodexLaunchPlan: the account this launch is
/// given, by what the last collection found.
pub fn planned(launch: &Launch) -> R<Plan> {
    let directory = launch.directory;
    let policy = json::read_or_null(&directory.join("policy.json"));
    if !policy.t()? {
        return fail("No valid policy.json. Run hotpl8 setup or see docs/install.md.");
    }
    let snapshot = json::read_or_null(&directory.join("status.json"));
    let (policy, _) = control_snapshot(directory)?;
    assert_policy(&policy)?;
    let view = provider_view(&snapshot, &policy, launch.provider, &[])?;
    if !view.path(&["registration", "definition", "capabilities", "nativeLaunch"])?.t()? || view.g("provider")?.ne_s("codex")? {
        return fail("Native launch is not supported by this registered driver.");
    }
    let part = view.g("policy")?.g("codex")?;
    if !part.g("slots")?.t()? {
        return fail("No native account homes configured.");
    }
    let context = provider_action_context(&policy, directory, &obj! {"intent" => "admit", "bindingKnown" => false}, (launch.clock)()?)?;
    let status = view.path(&["snapshot", "providers", "codex"])?;
    let now = (launch.clock)()?;

    assert_codex_policy(&part)?;
    if let Some(key) = CONFLICTS.iter().find(|key| (launch.conflict)(key)) {
        // The key, and never what it is set to.
        return fail(format!("Conflicting environment setting: {key}. Use native Codex directly for an explicitly different authentication mode."));
    }
    if launch.words.iter().any(|word| overrides(word)) {
        return fail("Use HotPl8 -Model for model selection. Config/profile/auth/workdir overrides require native Codex directly; they cannot be verified against a subscription recommendation.");
    }
    let explicit = !blank(launch.slot)?;
    if !explicit && launch.words.iter().any(|word| ["resume", "fork"].contains(&folded(word).as_str())) {
        return fail("Resume/fork requires -Slot naming the home that owns the conversation.");
    }
    let meter = if part.g("defaultMeter")?.t()? { part.g("defaultMeter")?.s()? } else { "codex".to_string() };
    if !explicit {
        let Ok(Some(age)) = age_seconds(&status.g("observedAt")?, now) else { return fail("No current Codex status. Run hotpl8 refresh first or choose -Slot.") };
        if !(-5.0..=900.0).contains(&age) {
            return fail("Codex status is stale. Refresh it or choose -Slot.");
        }
    }
    let listed = status.g("slots")?.arr();
    let mut observations = Vec::new();
    for configured in part.g("slots")?.arr() {
        let id = configured.g("id")?;
        let rows = filter(&listed, |row| row.g("id")?.ceq(&id))?;
        observations.push(match rows.as_slice() {
            [row] => codex_observation(row, &meter)?,
            rows => obj! {"id" => id.s()?, "status" => "unknown", "windows" => Vec::<V>::new(), "observedAt" => V::Null, "bindingValid" => rows.is_empty()},
        });
    }
    let capacity = capacity_accounts(&obj! {"providers" => hash! {"codex" => status.clone()}}, &part, "codex", now, &meter, false)?;
    let observations = add_observation_capacity(&observations, &capacity)?;
    let context = copy(&context)?;
    context.add_member("scopes", vec![V::s_of(&meter)].into(), true)?;
    if explicit {
        context.add_member("pin", V::s_of(launch.slot), true)?;
    }
    let decision = provider_decision(&observations.clone().into(), &part, &context, now)?;
    if !decision.g("actionPermitted")?.t()? {
        return fail(format!("No eligible subscription for this launch: {}", decision.g("suppressionReason")?.s()?));
    }
    let chosen = named(&part.g("slots")?.arr(), &decision.g("targetSlot")?.s()?, true)?;
    let [slot] = chosen.as_slice() else { return fail("Unknown or duplicate Codex slot.") };
    if slot.g("id")?.is_in(&part.g("disabled")?)? {
        return fail("This Codex slot is disabled. Enable it before launch.");
    }
    let emergency = decision.path(&["critical", "active"])?.t()?;
    Ok(Plan { slot: slot.clone(), part, meter, automatic: !explicit, emergency, observations, context, status })
}

/// Invoke-Hotpl8Codex, as far as the start of Codex: the home of the account is read as it
/// is now, and the launch stands only if the account is still the one this launch is given.
pub fn validated(launch: &Launch, plan: &Plan) -> R<Prepared> {
    let directory = launch.directory;
    let state = provider_state_directory(directory, launch.provider)?;
    let (admission, generation) = control_snapshot(directory)?;
    assert_policy(&admission)?;
    let current = configured_provider(&admission, launch.provider, false)?.g("policy")?;
    if json::compact(&current, 24)? != json::compact(&plan.part, 24)? {
        return fail("Policy changed before native launch; prepare a new launch.");
    }
    let program = match (launch.program)() {
        Ok(program) => program,
        Err(name) => return fail(name),
    };
    let home = plan.slot.g("home")?.s()?;
    let id = plan.slot.g("id")?;
    let name = id.s()?;
    let named = V::s_of(&name);
    let read = (launch.read)(&home, &Asked { directory: Some(launch.working), ..Asked::default() }, READ_BUDGET_MS);
    let account = match read.outcome {
        Ok(account) => account,
        Err(name) => return fail(format!("Native subscription validation failed: {name}")),
    };
    if !account.standard_transport {
        return fail("This home overrides the OpenAI endpoint. Subscription routing is unavailable for that configuration.");
    }
    if !account.model_provider.is_empty() && !account.model_provider.eq_ignore_ascii_case("openai") {
        return fail("This home uses a custom model provider. Its billing cannot be represented as this subscription.");
    }
    if plan.automatic {
        let prior = json::read_or_null(&state.join("codex-state.json")).g("slots")?.gd(&name)?;
        if !prior.t()? || prior.g("identityKey")?.ne(&V::s_of(&account.identity_key))? || prior.g("binding")?.ne(&V::from(bound(&plan.slot)?))? {
            return fail("Account binding changed since collection. Refresh HotPl8 before automatic launch.");
        }
        let now = (launch.clock)()?;
        let current = obj! {"id" => id.clone(), "status" => "ok", "observedAt" => now.o(), "buckets" => codex_buckets(&account.quota, &V::Null, now)?};
        if codex_eligibility(&current, &plan.part, &plan.meter, now, plan.emergency)?.ne_s("eligible")? {
            return fail("Quota changed before launch; the selected subscription is no longer eligible.");
        }
    }
    // No program is run inside this short boundary: the account is decided once more with
    // what its home just said, under the settings this launch began with.
    let authorized = action_authorization(directory, &generation, || {
        let context = provider_action_context(&admission, directory, &plan.context, (launch.clock)()?)?;
        let mut observations = filter(&plan.observations, |row| row.g("id")?.cne(&named))?;
        let read_now = (launch.clock)()?;
        let listed = plan.status.g("slots")?.arr();
        let previous = filter(&listed, |row| row.g("id")?.ceq(&named))?;
        let buckets = match previous.as_slice() {
            [row] => row.g("buckets")?,
            _ => V::Null,
        };
        let native = obj! {"id" => id.clone(), "status" => "ok", "observedAt" => read_now.o(), "buckets" => codex_buckets(&account.quota, &buckets, read_now)?};
        observations.push(codex_observation(&native, &plan.meter)?);
        let mut rows = filter(&listed, |row| row.g("id")?.cne(&named))?;
        rows.push(native);
        let capacity = capacity_accounts(&obj! {"providers" => hash! {"codex" => hash! {"slots" => rows}}}, &plan.part, "codex", read_now, &plan.meter, false)?;
        let observations = add_observation_capacity(&observations, &capacity)?;
        provider_decision(&observations.into(), &plan.part, &context, read_now)
    })?;
    if !authorized.g("actionPermitted")?.t()? || authorized.g("targetSlot")?.cne(&named)? {
        return fail("Launch decision changed during native validation; prepare a new launch.");
    }
    let mut words = Vec::new();
    if !launch.model.is_empty() {
        words.extend(["--model".to_string(), launch.model.to_string()]);
    }
    words.extend(launch.words.iter().cloned());
    Ok(Prepared { program, home, slot: name, meter: plan.meter.clone(), state, words })
}

/// What Codex is started with for this launch, or why it is not started.
pub fn prepared(launch: &Launch) -> R<Prepared> {
    validated(launch, &planned(launch)?)
}

/// While Codex runs, an interrupt is Codex's to answer: the terminal sends it to every
/// program on it, and this one must neither end before Codex has nor tell Codex to ignore
/// it. A program started from here is not handed what is set here.
#[cfg(windows)]
fn leave_interrupts() {
    #[link(name = "kernel32")]
    extern "system" {
        fn SetConsoleCtrlHandler(handler: Option<unsafe extern "system" fn(u32) -> i32>, add: i32) -> i32;
    }
    /// Ctrl+C and Ctrl+Break are answered by doing nothing; a closed window, a logoff and
    /// a shutdown end this program as they always would.
    unsafe extern "system" fn left(kind: u32) -> i32 {
        i32::from(kind <= 1)
    }
    // SAFETY: `left` is a function of this program that lives as long as it does, and does
    // nothing but answer.
    unsafe { SetConsoleCtrlHandler(Some(left), 1) };
}
#[cfg(unix)]
fn leave_interrupts() {
    extern "C" {
        fn signal(signal: core::ffi::c_int, handler: extern "C" fn(core::ffi::c_int)) -> usize;
    }
    extern "C" fn left(_signal: core::ffi::c_int) {}
    const INTERRUPT: core::ffi::c_int = 2;
    // SAFETY: `left` does nothing, which any signal handler may. A handler, unlike an
    // ignored signal, is not passed on to the program started next.
    unsafe { signal(INTERRUPT, left) };
}

/// Codex, on this terminal, in the caller's directory and the account's home. Answers the
/// status Codex ended with.
pub fn run(prepared: &Prepared, working: &str) -> Result<i32, String> {
    let mut codex = std::process::Command::new(&prepared.program);
    codex.args(&prepared.words).current_dir(working);
    codex.env("CODEX_HOME", &prepared.home).env("HOTPL8_SLOT", &prepared.slot).env("HOTPL8_STATE_DIRECTORY", &prepared.state).env("HOTPL8_METER", &prepared.meter);
    let mut running = codex.spawn().map_err(|error| format!("Codex could not be started: {error}"))?;
    leave_interrupts();
    let status = running.wait().map_err(|error| format!("Codex was started and could not be waited for: {error}"))?;
    #[cfg(unix)]
    let code = {
        use std::os::unix::process::ExitStatusExt;
        status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
    };
    #[cfg(not(unix))]
    let code = status.code().unwrap_or(1);
    Ok(code)
}

struct Started {
    root: PathBuf,
    state: Option<PathBuf>,
    codex: Option<String>,
    provider: String,
    slot: String,
    model: String,
    directory: Option<PathBuf>,
    words: Vec<String>,
}

/// `codex --root <dir> [--state <dir>] [--codex <program>] [--provider <id>] [--slot <id>]
/// [--model <name>] [--directory <dir>] [-- <the words for Codex>]`
fn spelled(arguments: &[OsString]) -> Option<Started> {
    const NAMES: [&str; 7] = ["--root", "--state", "--codex", "--provider", "--slot", "--model", "--directory"];
    let mut values: [Option<&OsString>; 7] = [None; 7];
    let mut words = Vec::new();
    let mut rest = arguments.iter();
    while let Some(word) = rest.next() {
        let name = word.to_str()?;
        if name == "--" {
            // Every word after it is Codex's, whatever it looks like.
            words = rest.by_ref().map(|word| word.to_str().map(str::to_string)).collect::<Option<_>>()?;
            break;
        }
        let place = NAMES.iter().position(|known| *known == name).filter(|place| values[*place].is_none())?;
        values[place] = Some(rest.next()?);
    }
    let path = |place: usize| -> Option<Option<PathBuf>> {
        match values[place] {
            Some(named) => Some(Some(full_path(named)?)),
            None => Some(None),
        }
    };
    let text = |place: usize, usual: &str| -> Option<String> {
        match values[place] {
            Some(named) => Some(named.to_str()?.to_string()),
            None => Some(usual.to_string()),
        }
    };
    Some(Started {
        root: path(0)??,
        state: path(1)?,
        codex: match values[2] {
            Some(named) => Some(named.to_str()?.to_string()),
            None => None,
        },
        provider: text(3, "codex")?,
        slot: text(4, "")?,
        model: text(5, "")?,
        directory: path(6)?,
        words,
    })
}

/// The `codex` command: Codex run for this launch, and the status it ended with.
pub fn started(arguments: &[OsString]) -> Result<i32, String> {
    // What the words for Codex were is no part of a refusal.
    let Some(started) = spelled(arguments) else { return Err("The launch was started with words it does not take.".to_string()) };
    // The numbers of a choice are those of the PowerShell that has always made it.
    set_core(!cfg!(windows));
    packaged_data(&started.root);
    let said = |stop: Stop| stop.message();
    let directory = state_directory(&started.root, started.state.as_deref()).map_err(said)?;
    crate::wake::onboarding_tools(&directory);
    let working = match started.directory {
        Some(directory) => directory,
        None => std::env::current_dir().map_err(|error| format!("The directory this launch was started in cannot be read: {error}"))?,
    };
    let working = working.to_string_lossy().into_owned();
    // Looked for once, and not at all by a launch that is refused before its home is read.
    let program = std::cell::OnceCell::new();
    let found = || program.get_or_init(|| Search::here().program(started.codex.as_deref()));
    let prepared = prepared(&Launch {
        directory: &directory,
        provider: &started.provider,
        slot: &started.slot,
        model: &started.model,
        words: &started.words,
        working: &working,
        conflict: &|key| std::env::var_os(key).is_some_and(|value| !value.is_empty()),
        program: &|| found().clone(),
        read: &|home, asked, budget| read_home_as(home, found(), budget, asked),
        clock: &Dto::now,
    })
    .map_err(said)?;
    run(&prepared, &working)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codex_read::tests::{home as scratch_home, stand_in};
    use crate::route::tests::{failed, limits, noon, Lab};
    use std::cell::{Cell, RefCell};

    const NO_STATUS: &str = "No current Codex status. Run hotpl8 refresh first or choose -Slot.";
    const STALE: &str = "Codex status is stale. Refresh it or choose -Slot.";
    const OVERRIDE: &str = "Use HotPl8 -Model for model selection. Config/profile/auth/workdir overrides require native Codex directly; they cannot be verified against a subscription recommendation.";
    const OWNER: &str = "Resume/fork requires -Slot naming the home that owns the conversation.";
    const BINDING: &str = "Account binding changed since collection. Refresh HotPl8 before automatic launch.";
    const QUOTA: &str = "Quota changed before launch; the selected subscription is no longer eligible.";
    const DECISION: &str = "Launch decision changed during native validation; prepare a new launch.";
    const WORKING: &str = "fixture-work";

    /// One read a launch asked for.
    struct Seen {
        id: String,
        directory: String,
        budget: u64,
        /// Nothing was refreshed and no sign-in was asked for.
        plain: bool,
    }

    /// Someone at the lab's two accounts, `a` preferred to `b`. No Codex is started: each
    /// test says what a read answers, and it is noon throughout.
    struct Caller {
        lab: Lab,
        /// The key this caller's environment holds.
        set: Cell<Option<&'static str>>,
        /// The Codex this caller has, or why it has none.
        program: Cell<Result<&'static str, &'static str>>,
        provider: Cell<&'static str>,
        reads: RefCell<Vec<Seen>>,
    }

    impl Caller {
        fn new() -> Caller {
            Caller { lab: Lab::new(), set: Cell::new(None), program: Cell::new(Ok("codex-fixture")), provider: Cell::new("codex"), reads: RefCell::new(Vec::new()) }
        }

        /// A launch for the account, the model and the words named, with reads a test describes.
        fn launch<T>(&self, slot: &str, model: &str, words: &[&str], read: &dyn Fn(&str) -> HomeRead, asked: impl FnOnce(&Launch) -> T) -> T {
            self.reads.borrow_mut().clear();
            let words: Vec<String> = words.iter().map(|word| word.to_string()).collect();
            asked(&Launch {
                directory: &self.lab.directory,
                provider: self.provider.get(),
                slot,
                model,
                words: &words,
                working: WORKING,
                conflict: &|key| self.set.get().is_some_and(|held| held == key),
                program: &|| self.program.get().map(PathBuf::from),
                read: &|home, asked, budget| {
                    let id = home.rsplit('-').next().unwrap_or_default();
                    assert_eq!(home, self.lab.home(id));
                    self.reads.borrow_mut().push(Seen { id: id.into(), directory: asked.directory.unwrap_or_default().into(), budget, plain: !asked.refresh && !asked.token && !asked.identity_only });
                    read(id)
                },
                clock: &|| Ok(noon()),
            })
        }

        fn tried(&self, slot: &str, model: &str, words: &[&str], read: &dyn Fn(&str) -> HomeRead) -> R<Prepared> {
            self.launch(slot, model, words, read, prepared)
        }

        /// The launch with every account read as it is.
        fn given(&self, slot: &str, model: &str, words: &[&str]) -> R<Prepared> {
            self.tried(slot, model, words, &|id| self.lab.fresh(id))
        }

        /// The account a launch with no model and no words is given, or why it is refused.
        fn says(&self, slot: &str) -> String {
            said(self.given(slot, "", &[]))
        }

        /// A read of one account with something of it changed.
        fn read_as(&self, id: &str, change: impl FnOnce(&mut crate::codex_read::Account)) -> HomeRead {
            let mut read = self.lab.fresh(id);
            change(read.outcome.as_mut().ok().unwrap());
            read
        }
    }

    /// The account a launch was given, or the sentence it was refused with.
    fn said(launch: R<Prepared>) -> String {
        match launch {
            Ok(prepared) => prepared.slot,
            Err(stop) => stop.message(),
        }
    }

    fn list(ids: &[&str]) -> V {
        ids.iter().map(|id| V::s_of(id)).collect::<Vec<V>>().into()
    }

    /// What a collection made now lists of an account that had used this much of its week.
    fn row(id: &str, used: i32) -> V {
        obj! {"id" => id, "status" => "ok", "observedAt" => noon().o(), "defaultModel" => "fixture-model", "buckets" => codex_buckets(&limits(used), &V::Null, noon()).ok().unwrap()}
    }

    /// The snapshot of a collection made now that listed these rows.
    fn snapshot(lab: &Lab, rows: Vec<V>) {
        lab.save("status.json", &obj! {"providers" => obj! {"codex" => obj! {"observedAt" => noon().o(), "recommendations" => obj! {"codex" => "a"}, "slots" => rows}}});
    }

    #[test]
    fn a_launch_is_given_the_preferred_account_and_reads_its_home_once() {
        let caller = Caller::new();
        let prepared = caller.given("", "", &[]).ok().unwrap();
        assert_eq!((prepared.slot.as_str(), prepared.meter.as_str(), prepared.home.as_str()), ("a", "codex", caller.lab.home("a").as_str()));
        assert_eq!((prepared.program, prepared.state, prepared.words.len()), (PathBuf::from("codex-fixture"), caller.lab.directory.clone(), 0));
        let reads = caller.reads.borrow();
        assert_eq!(reads.len(), 1);
        assert_eq!((reads[0].id.as_str(), reads[0].directory.as_str(), reads[0].budget, reads[0].plain), ("a", WORKING, READ_BUDGET_MS, true));
        drop(reads);
        // The choice is made now, by the settings as they are, and not by what the last
        // collection recommended.
        caller.lab.accounts("prefer", list(&["b", "a"]));
        assert_eq!((caller.says(""), caller.says(" ")), ("b".to_string(), "b".to_string()));
        // Every setting but one that stops a launch leaves it to the user who asked.
        caller.lab.automate();
        assert_eq!(caller.says(""), "b");
    }

    #[test]
    fn the_model_named_is_passed_before_the_words_as_they_were_written() {
        let caller = Caller::new();
        let awkward = ["a b", "a\"b", "C:\\ends with slash\\", "", "$literal", "x&y", "semi;colon", "Unicode: \u{3a9}\u{4e2d}"];
        assert_eq!(caller.given("b", "", &awkward).ok().unwrap().words, awkward);
        let prepared = caller.given("", "fixture-model", &["exec", "--json", "fixture prompt"]).ok().unwrap();
        assert_eq!(prepared.words, ["--model", "fixture-model", "exec", "--json", "fixture prompt"]);
        // A model HotPl8 has never heard of, and no model, are counted against the same quota.
        assert_eq!(said(caller.given("", "model-nobody-knows", &[])), "a");
        let retired: Vec<String> = (0..300).map(|number| format!("retired-{number}")).collect();
        caller.lab.accounts("modelMeters", new_obj(retired.iter().map(|name| (name.as_str(), V::s_of("codex"))).collect()));
        assert_eq!(said(caller.given("", "model-nobody-knows", &[])), "a");
        caller.lab.policy.g("codex").ok().unwrap().remove_member("modelMeters").ok().unwrap();
        caller.lab.save("policy.json", &caller.lab.policy);
        assert_eq!((said(caller.given("", "fixture-model", &[])), caller.says("")), ("a".to_string(), "a".to_string()));
    }

    #[test]
    fn an_account_that_is_named_needs_no_collection_and_any_other_needs_a_current_one() {
        let caller = Caller::new();
        for (age, automatic) in [(0, "a"), (900, "a"), (901, STALE), (3600, STALE), (-5, "a"), (-6, STALE)] {
            caller.lab.collected("ok", 0, age);
            assert_eq!((caller.says(""), caller.says("b")), (automatic.to_string(), "b".to_string()), "{age}");
        }
        // A time that is not written as HotPl8 writes one is no reading.
        for written in [V::Null, V::s_of(""), V::s_of("yesterday"), V::I32(7)] {
            let codex = obj! {"observedAt" => written, "slots" => Vec::<V>::new()};
            caller.lab.save("status.json", &obj! {"providers" => obj! {"codex" => codex}});
            assert_eq!((caller.says(""), caller.says("b")), (NO_STATUS.to_string(), "b".to_string()));
        }
        caller.lab.remove("status.json");
        assert_eq!((caller.says(""), caller.says("b")), (NO_STATUS.to_string(), "b".to_string()));
        // Nor does it need what the collector keeps of who the home belongs to.
        caller.lab.remove("codex-state.json");
        assert_eq!(caller.says("b"), "b");
        assert_eq!(caller.reads.borrow().len(), 1);
    }

    #[test]
    fn what_holds_a_selection_defers_the_choice_and_not_an_account_that_is_named() {
        let caller = Caller::new();
        caller.lab.until("hold.json");
        assert_eq!((caller.says(""), caller.says("b")), ("No eligible subscription for this launch: binding_unknown".to_string(), "b".to_string()));
        caller.lab.remove("hold.json");
        assert_eq!(caller.says(""), "a");
        // A pause stops what HotPl8 does by itself. A launch is the user's own.
        caller.lab.until("automation-pause.json");
        assert_eq!((caller.says(""), caller.says("b")), ("a".to_string(), "b".to_string()));
    }

    #[test]
    fn an_account_counted_on_another_basis_does_not_borrow_the_ordinary_quota() {
        let caller = Caller::new();
        caller.lab.accounts("defaultMeter", "codex_bengalfox".into());
        assert_eq!(said(caller.given("", "fixture-model", &[])), "No eligible subscription for this launch: unavailable");
        let prepared = caller.given("b", "fixture-model", &[]).ok().unwrap();
        assert_eq!((prepared.slot.as_str(), prepared.meter.as_str(), prepared.words), ("b", "codex_bengalfox", vec!["--model".to_string(), "fixture-model".to_string()]));
    }

    #[test]
    fn a_conversation_is_resumed_only_in_the_home_that_is_named() {
        let caller = Caller::new();
        for word in ["resume", "fork", "RESUME", "Fork"] {
            assert_eq!(said(caller.given("", "", &["exec", word])), OWNER, "{word}");
            let prepared = caller.given("b", "", &[word, "--last"]).ok().unwrap();
            assert_eq!((prepared.slot.as_str(), prepared.words), ("b", vec![word.to_string(), "--last".to_string()]));
        }
        // A prompt that only holds the word is no request to resume.
        assert_eq!(said(caller.given("", "", &["exec", "resume the work"])), "a");
        // An account written as blanks names no home.
        assert_eq!((said(caller.given(" ", "", &["resume", "abc"])), said(caller.given("\t", "", &["fork"]))), (OWNER.to_string(), OWNER.to_string()));
    }

    #[test]
    fn a_caller_signed_in_some_other_way_is_told_which_setting_and_never_its_value() {
        let caller = Caller::new();
        for key in CONFLICTS {
            caller.set.set(Some(key));
            let expected = format!("Conflicting environment setting: {key}. Use native Codex directly for an explicitly different authentication mode.");
            assert_eq!((caller.says(""), caller.says("b")), (expected.clone(), expected));
            assert!(caller.reads.borrow().is_empty());
        }
        caller.set.set(Some("OPENAI_ORGANIZATION"));
        assert_eq!(caller.says(""), "a");
    }

    #[test]
    fn words_that_would_choose_the_model_the_account_or_the_place_are_refused() {
        let caller = Caller::new();
        let refused = [
            "--config",
            "--config=model_provider=\"other\"",
            "--profile",
            "--oss",
            "--local-provider=x",
            "--model",
            "--model=other",
            "--cd",
            "--remote=ws://other",
            "--remote-auth-token-env",
            "--ignore-user-config",
            "--CONFIG=x",
            "--Remote",
            "--oss\n",
            "-c",
            "-C",
            "-cmodel=other",
            "-p",
            "-Pwork",
            "-m",
            "-M",
            "-model",
            "login",
            "LOGOUT",
            "app-server",
            "mcp",
            "mcp-server",
            "app",
            "agents",
            "cloud",
            "remote-control",
            "exec-server",
            "plugin",
            "debug",
            "sandbox",
            "completion",
            "doctor",
            "features",
            "update",
            "apply",
            "queue",
            "archive",
            "delete",
            "unarchive",
            "migrate-rollouts",
            // Letters outside ASCII that one culture or another reads as an ASCII letter.
            "--conf\u{131}g",
            "--CONF\u{130}G=x",
            "plug\u{131}n",
            "\u{17f}andbox",
            "LOG\u{130}N",
            "--o\u{17f}\u{17f}",
            "feature\u{17f}",
            "--remote-auth-to\u{212a}en-env",
            "--REMOTE-AUTH-TO\u{212a}EN-ENV=X",
        ];
        for word in refused {
            for words in [vec![word], vec!["exec", word], vec![word, "after"]] {
                assert_eq!((said(caller.given("", "", &words)), said(caller.given("b", "", &words))), (OVERRIDE.to_string(), OVERRIDE.to_string()), "{words:?}");
            }
        }
        assert!(caller.reads.borrow().is_empty());
        let passed = [
            "exec", "--json", "fixture prompt", "--configure", "--models", "--cdx", "--remote-auth", "--config x", "config", "--", "-", "-a", "-s", "--search", "logins", "log in", " login", "login ", "--oss\r\n", "--oss\n\n", "mcp=1", "\u{3a9}\u{4e2d}", "-\u{441}", "\u{441}loud",
            "\u{440}lugin",
        ];
        for word in passed {
            assert_eq!(said(caller.given("", "", &["exec", word])), "a", "{word:?}");
        }
    }

    #[test]
    fn an_account_that_is_switched_off_or_unknown_is_not_launched() {
        let caller = Caller::new();
        // The choice has no account for a name it does not know, and names are told apart
        // by the case of their letters.
        let unknown = "No eligible subscription for this launch: binding_changed";
        assert_eq!((caller.says("c"), caller.says("B")), (unknown.to_string(), unknown.to_string()));
        caller.lab.accounts("disabled", list(&["b"]));
        assert_eq!((caller.says(""), caller.says("b"), caller.says("c")), ("a".to_string(), unknown.to_string(), unknown.to_string()));
        caller.lab.accounts("disabled", list(&["a", "b"]));
        assert_eq!(caller.says(""), "No eligible subscription for this launch: unavailable");
        assert!(caller.reads.borrow().is_empty());
    }

    #[test]
    fn an_account_is_chosen_by_the_one_row_the_collection_listed_under_its_name() {
        let caller = Caller::new();
        let unknown = "No eligible subscription for this launch: binding_changed";
        // Listed twice, it is no account to choose or to name.
        snapshot(&caller.lab, vec![row("a", 10), row("a", 10), row("b", 10)]);
        assert_eq!((caller.says(""), caller.says("a"), caller.says("b")), ("b".to_string(), unknown.to_string(), "b".to_string()));
        // Under a name of other letters, not at all, or with no reading of what this launch
        // is counted on, it was not measured: the choice passes it over, and it may be named.
        let unmeasured = row("a", 10);
        unmeasured.set("buckets", obj! {}).ok().unwrap();
        for rows in [vec![row("A", 10), row("b", 10)], vec![row("b", 10)], vec![unmeasured.clone(), row("b", 10)]] {
            snapshot(&caller.lab, rows);
            assert_eq!((caller.says(""), caller.says("a")), ("b".to_string(), "a".to_string()));
        }
        snapshot(&caller.lab, vec![unmeasured]);
        assert_eq!(caller.says(""), "No eligible subscription for this launch: unavailable");
    }

    #[test]
    fn accounts_that_are_nearly_used_up_are_given_by_the_settings_for_that() {
        let caller = Caller::new();
        let nearly = |used: i32| {
            snapshot(&caller.lab, vec![row("a", used), row("b", used)]);
            caller.lab.uses("a", used);
            caller.lab.uses("b", used);
        };
        nearly(97);
        assert_eq!((caller.says(""), caller.says("b")), ("No eligible subscription for this launch: unavailable".to_string(), "b".to_string()));
        // With those settings, the read before the start is judged as the choice was.
        caller.lab.accounts("critical", obj! {"enabled" => true});
        for (used, automatic) in [(90, "a"), (97, "a"), (99, "a"), (100, "No eligible subscription for this launch: unavailable")] {
            nearly(used);
            assert_eq!((caller.says(""), caller.says("b")), (automatic.to_string(), "b".to_string()), "{used}");
        }
        nearly(97);
        for (used, automatic) in [(10, "a"), (99, DECISION), (100, QUOTA)] {
            caller.lab.uses("a", used);
            assert_eq!(caller.says(""), automatic, "{used}");
        }
    }

    #[test]
    fn a_reset_the_collection_confirmed_still_counts_when_the_home_is_read() {
        let caller = Caller::new();
        caller.lab.accounts("order", "soonest-reset".into());
        // Both resets were seen to hold, and the week of `b` ends an hour after that of `a`.
        let confirmed = |id: &str, later: i64| {
            let row = row(id, 10);
            let week = row.path(&["buckets", "codex", "windows", "10080"]).ok().unwrap();
            week.set("anchorState", "observed-active".into()).ok().unwrap();
            week.set("resetsAt", V::I64(noon().unix_seconds() + 3600 + later)).ok().unwrap();
            row
        };
        snapshot(&caller.lab, vec![confirmed("a", 0), confirmed("b", 3600)]);
        assert_eq!((caller.says(""), caller.says("b")), ("a".to_string(), "b".to_string()));
    }

    #[test]
    fn a_home_that_cannot_be_validated_is_not_launched() {
        let caller = Caller::new();
        for name in ["timeout", "auth_required", "home_busy", "transport_failed"] {
            let refused = format!("Native subscription validation failed: {name}");
            assert_eq!((said(caller.tried("", "", &[], &|_| failed(name))), said(caller.tried("b", "", &[], &|_| failed(name)))), (refused.clone(), refused));
        }
        let endpoint = "This home overrides the OpenAI endpoint. Subscription routing is unavailable for that configuration.";
        assert_eq!(said(caller.tried("b", "", &[], &|id| caller.read_as(id, |account| account.standard_transport = false))), endpoint);
        let custom = "This home uses a custom model provider. Its billing cannot be represented as this subscription.";
        for (provider, answer) in [("other", custom), ("openai-compatible", custom), ("\u{3a9}", custom), ("", "b"), ("OpenAI", "b")] {
            assert_eq!(said(caller.tried("b", "", &[], &|id| caller.read_as(id, |account| account.model_provider = provider.into()))), answer, "{provider}");
        }
        // The endpoint is named first.
        assert_eq!(said(caller.tried("", "", &[], &|id| caller.read_as(id, |account| (account.standard_transport, account.model_provider) = (false, "other".into())))), endpoint);
        caller.program.set(Err("codex_missing"));
        assert_eq!((caller.says(""), caller.reads.borrow().len()), ("codex_missing".to_string(), 0));
        caller.program.set(Err("native_codex_required"));
        assert_eq!(caller.says("b"), "native_codex_required");
    }

    #[test]
    fn a_home_that_changed_hands_since_the_collection_is_not_chosen() {
        let caller = Caller::new();
        for changed in [("a", "identityKey", "identity-other"), ("a", "binding", "another-home")] {
            caller.lab.recorded(&[changed]);
            assert_eq!((caller.says(""), caller.says("a")), (BINDING.to_string(), "a".to_string()), "{changed:?}");
        }
        caller.lab.recorded(&[]);
        assert_eq!(said(caller.tried("", "", &[], &|id| caller.read_as(id, |account| account.identity_key = "identity-other".into()))), BINDING);
        caller.lab.save("codex-state.json", &obj! {"slots" => obj! {"b" => obj! {"binding" => "x", "identityKey" => "identity-b"}}});
        assert_eq!(caller.says(""), BINDING);
        caller.lab.remove("codex-state.json");
        assert_eq!((caller.says(""), caller.says("a")), (BINDING.to_string(), "a".to_string()));
    }

    #[test]
    fn an_account_used_up_since_the_collection_is_not_launched() {
        let caller = Caller::new();
        // With none of its week left it is not eligible; inside the margin the settings keep
        // of a week, it is no longer the account the choice would make.
        for (used, automatic) in [(100, QUOTA), (85, DECISION), (81, DECISION), (80, "a"), (79, "a")] {
            caller.lab.uses("a", used);
            assert_eq!((caller.says(""), caller.says("a")), (automatic.to_string(), "a".to_string()), "{used}");
        }
        // An account that was named is the user's choice, at any use.
        caller.lab.uses("b", 100);
        assert_eq!(caller.says("b"), "b");
    }

    #[test]
    fn settings_changed_while_a_launch_was_prepared_stop_it() {
        let caller = Caller::new();
        let fresh = |id: &str| caller.lab.fresh(id);
        let plan = caller.launch("", "", &[], &fresh, |launch| planned(launch)).ok().unwrap();
        assert_eq!(said(caller.launch("", "", &[], &fresh, |launch| validated(launch, &plan))), "a");
        // The accounts' settings, between the choice and the start.
        caller.lab.accounts("margin5h", V::I32(30));
        assert_eq!(said(caller.launch("", "", &[], &fresh, |launch| validated(launch, &plan))), "Policy changed before native launch; prepare a new launch.");
        assert!(caller.reads.borrow().is_empty());
        // Any setting that governs an action, while the home was read.
        let paused = |id: &str| {
            caller.lab.until("automation-pause.json");
            caller.lab.fresh(id)
        };
        assert_eq!(said(caller.tried("", "", &[], &paused)), "action_state_changed");
        caller.lab.remove("automation-pause.json");
        let held = |id: &str| {
            caller.lab.until("hold.json");
            caller.lab.fresh(id)
        };
        assert_eq!(said(caller.tried("b", "", &[], &held)), "action_state_changed");
        caller.lab.remove("hold.json");
        let changed = |id: &str| {
            caller.lab.accounts("margin7d", V::I32(30));
            caller.lab.fresh(id)
        };
        assert_eq!(said(caller.tried("", "", &[], &changed)), "action_state_changed");
    }

    #[test]
    fn a_pause_that_cannot_be_read_stops_a_launch_whenever_it_is_found() {
        let caller = Caller::new();
        let fresh = |id: &str| caller.lab.fresh(id);
        let unsafe_state = "No eligible subscription for this launch: safety_state_invalid";
        for slot in ["", "b"] {
            let plan = caller.launch(slot, "", &[], &fresh, |launch| planned(launch)).ok().unwrap();
            // Between the choice and the start.
            std::fs::write(caller.lab.directory.join("automation-pause.json"), "{not json").unwrap();
            assert_eq!(said(caller.launch(slot, "", &[], &fresh, |launch| validated(launch, &plan))), DECISION, "{slot}");
            assert_eq!(caller.says(slot), unsafe_state, "{slot}");
            caller.lab.remove("automation-pause.json");
        }
        // Settings that are no settings are refused in the words for what is wrong with them,
        // at the choice and at the start.
        let plan = caller.launch("b", "", &[], &fresh, |launch| planned(launch)).ok().unwrap();
        caller.lab.policy.set("mode", "sometimes".into()).ok().unwrap();
        caller.lab.save("policy.json", &caller.lab.policy);
        let invalid = "Invalid policy: mode must be monitor or automate.";
        assert_eq!(said(caller.launch("b", "", &[], &fresh, |launch| validated(launch, &plan))), invalid);
        assert_eq!(caller.launch("b", "", &[], &fresh, |launch| planned(launch)).err().map(|stop| stop.message()), Some(invalid.to_string()));
    }

    #[test]
    fn a_launch_needs_settings_and_a_provider_that_launches() {
        let caller = Caller::new();
        caller.provider.set("claude");
        assert_eq!(caller.says(""), "Native launch is not supported by this registered driver.");
        caller.provider.set("nobody");
        assert_eq!(caller.says(""), "Provider is not registered.");
        caller.provider.set("codex");
        caller.lab.accounts("slots", Vec::<V>::new().into());
        assert_eq!(caller.says("a"), "No native account homes configured.");
        let none = "No valid policy.json. Run hotpl8 setup or see docs/install.md.";
        std::fs::write(caller.lab.directory.join("policy.json"), "{not json").unwrap();
        assert_eq!(caller.says("a"), none);
        std::fs::write(caller.lab.directory.join("policy.json"), "[]").unwrap();
        assert_eq!(caller.says("a"), none);
        caller.lab.remove("policy.json");
        assert_eq!(caller.says("a"), none);
        assert!(caller.reads.borrow().is_empty());
    }

    #[test]
    fn codex_is_started_in_the_home_with_the_words_and_ends_the_launch_as_it_ends() {
        let place = crate::files::tests::scratch("launch-place");
        let working = place.to_string_lossy().into_owned();
        let state = place.join("providers").join("fixture");
        let words: Vec<String> = ["--model", "fixture-model", "exec", "a b", "a\"b", "C:\\ends with slash\\", "", "$literal", "x&y", "semi;colon", "Unicode: \u{3a9}\u{4e2d}"].map(str::to_string).into();
        let launched = |script: &str| {
            let home = scratch_home("launch", script);
            let prepared = Prepared { program: stand_in(), home: home.clone(), slot: "b".into(), meter: "codex_fixture".into(), state: state.clone(), words: words.clone() };
            (run(&prepared, &working), home)
        };
        let (status, home) = launched("launch exit 3\n");
        // More than a byte of it is kept where a status is that wide.
        let wide = if cfg!(windows) { 259 } else { 259 & 0xff };
        assert_eq!(status, Ok(3));
        let told = std::fs::read_to_string(Path::new(&home).join("launched.txt")).unwrap();
        let mut expected = vec!["slot b".to_string(), format!("state {}", state.display()), "meter codex_fixture".to_string()];
        expected.extend(words.iter().map(|word| format!("word {word}")));
        assert_eq!(told.lines().collect::<Vec<_>>(), expected);
        let started = std::fs::read_to_string(Path::new(&home).join("started.txt")).unwrap();
        let started: Vec<&str> = started.lines().collect();
        assert_eq!(Path::new(started[1].strip_prefix("directory ").unwrap()).canonicalize().unwrap(), place.canonicalize().unwrap());
        assert_eq!(started[2], format!("home {home}"));
        std::fs::remove_dir_all(&home).unwrap();
        // A status of any size is the launch's own.
        for (script, status) in [("", 7), ("launch exit 0\n", 0), ("launch wait 50\nlaunch exit 259\n", wide)] {
            let (ended, home) = launched(script);
            assert_eq!(ended, Ok(status), "{script}");
            std::fs::remove_dir_all(&home).unwrap();
        }
        let home = scratch_home("launch-none", "");
        let nothing = Prepared { program: place.join("no-such-codex"), home: home.clone(), slot: "b".into(), meter: "codex".into(), state, words };
        assert!(run(&nothing, &working).unwrap_err().starts_with("Codex could not be started: "));
        std::fs::remove_dir_all(&home).unwrap();
        std::fs::remove_dir_all(&place).unwrap();
    }

    #[test]
    fn the_command_takes_each_of_its_words_once() {
        let words = |list: &[&str]| -> Vec<OsString> { list.iter().map(OsString::from).collect() };
        let place = std::env::temp_dir();
        let path = |name: &str| place.join(name).to_string_lossy().into_owned();
        let (root, state, directory) = (path("release"), path("state"), path("work"));
        let started = spelled(&words(&["--root", &root])).unwrap();
        assert_eq!((started.root, started.state, started.codex, started.directory), (place.join("release"), None, None, None));
        assert_eq!((started.provider.as_str(), started.slot.as_str(), started.model.as_str(), started.words.len()), ("codex", "", "", 0));
        let all = ["--model", "fixture-model", "--slot", "b", "--provider", "work", "--codex", "codex-stand-in", "--directory", &directory, "--state", &state, "--root", &root, "--", "exec", "a b", "", "\u{3a9}\u{4e2d}", "--root", "--"];
        let started = spelled(&words(&all)).unwrap();
        assert_eq!((started.root, started.state, started.directory), (place.join("release"), Some(place.join("state")), Some(place.join("work"))));
        assert_eq!((started.provider.as_str(), started.slot.as_str(), started.model.as_str(), started.codex.as_deref()), ("work", "b", "fixture-model", Some("codex-stand-in")));
        assert_eq!(started.words, ["exec", "a b", "", "\u{3a9}\u{4e2d}", "--root", "--"]);
        assert!(spelled(&words(&["--root", &root, "--"])).unwrap().words.is_empty());
        let wrong: [&[&str]; 7] = [&[], &["--state", &state], &["--", "--root", &root], &["--root", &root, "--root", &root], &["--root", &root, "--slot"], &["--root", &root, "exec"], &["--root", &root, "--words", "exec"]];
        for wrong in wrong {
            assert!(spelled(&words(wrong)).is_none(), "{wrong:?}");
        }
        // A word that is no text cannot be told from the words that are refused.
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStringExt;
            let mut half = words(&["--root", &root, "--", "exec"]);
            half.push(OsString::from_wide(&[0x61, 0xd800]));
            assert!(spelled(&half).is_none());
        }
        assert_eq!(super::started(&words(&["--root", &root, "exec", "fixture prompt"])), Err("The launch was started with words it does not take.".to_string()));
    }
}

//! tick.ps1: one wake of the collector. Every registered provider that is due is read, the
//! readings are checked against each other, and the snapshot everything else reads is
//! replaced whole. A scheduled wake is quiet; a caller who asks is told when it fell short.

use crate::codex::format_codex_status;
use crate::collection::{collection_due, collection_state, set_collection_result};
use crate::control::control_snapshot;
use crate::cswap::user_home;
use crate::display::{packaged_data, state_directory};
use crate::files;
use crate::insights::{add_insights, name_text, rename_codex};
use crate::json;
use crate::lane::{self, Lanes};
use crate::obj;
use crate::policy::{actions, assert_policy};
use crate::ps::*;
use crate::registry::{configured_providers, provider_account_count, provider_driver};
use crate::request::full_path;
use crate::runtime::{collected_ownership, registered_collection, registered_failure, Reading};
use crate::time::Dto;
use std::ffi::OsString;
use std::io::Write;
use std::path::{Path, PathBuf};

/// The line end of the files a wake writes as text.
const NEWLINE: &str = if cfg!(windows) { "\r\n" } else { "\n" };

/// The refusals a provider's routine makes in words of its own. Each is the reason shown
/// for the provider; any other failure is shown as one that is not explained.
const REASONS: [&str; 7] = ["claude_missing", "claude_no_accounts", "claude_schema_unsupported", "claude_read_failed", "claude_switch_failed", "process_timeout", "process_output_limit"];

/// What a wake leaves to PowerShell once the snapshot is stored.
pub enum Upkeep {
    /// An account addition the snapshot now shows is closed.
    Onboarding,
    /// Claude's continue hook is there, or with `remove` is not.
    ContinueHook { remove: bool },
}

pub struct Wake<'a> {
    /// The release this program belongs to.
    pub root: &'a Path,
    pub directory: &'a Path,
    pub home: &'a Path,
    pub cswap: Option<&'a str>,
    /// Started by the scheduler: a healthy provider that asks for it is left until it is due.
    pub scheduled: bool,
    /// Read, and act on nothing.
    pub observe_only: bool,
    pub clock: &'a dyn Fn() -> R<Dto>,
    pub codex: &'a dyn Fn(&str) -> R<V>,
    pub upkeep: &'a dyn Fn(Upkeep) -> R<()>,
}

pub struct Outcome {
    /// Something was not read, or not stored. Old data is not a fresh result.
    pub failed: bool,
    /// What the collection did to an account, for whoever started it.
    pub printed: Vec<String>,
}

/// One wake. Two never run at once: the second finds the lock held and leaves.
pub fn collect(wake: &Wake) -> Outcome {
    let quiet = |failed| Outcome { failed, printed: Vec::new() };
    if !wake.directory.join("policy.json").exists() {
        return quiet(true);
    }
    let Ok(_lock) = files::lock(&wake.directory.join("tick.lock")) else { return quiet(true) };
    gathered(wake).unwrap_or_else(|stop| {
        files::event(wake.directory, "collector_failed", Some(&stop));
        quiet(true)
    })
}

fn gathered(wake: &Wake) -> R<Outcome> {
    let (directory, now) = (wake.directory, wake.clock);
    let (policy, generation) = control_snapshot(directory)?;
    assert_policy(&policy)?;
    let registrations = configured_providers(&policy, false)?;
    let mut counts = Vec::new();
    for registration in &registrations {
        counts.push(provider_account_count(registration)?);
    }
    if counts.iter().sum::<usize>() == 0 {
        return Ok(Outcome { failed: false, printed: Vec::new() });
    }
    let previous = json::read_or_null(&directory.join("status.json"));
    let collector = collection_state(directory)?;
    collector.add_member("startedAt", now()?.o().into(), true)?;
    collector.add_member("scheduled", wake.scheduled.into(), true)?;
    files::write_json(&directory.join("collector.json"), &collector, 8)?;
    let reading = Reading {
        policy: &policy,
        directory,
        generation: &generation,
        cswap: wake.cswap,
        observe_only: wake.observe_only,
        root: wake.root,
        home: wake.home,
        clock: wake.clock,
        codex: wake.codex,
    };
    let mut payload = obj! {"active" => 0, "verdict" => "Claude not configured", "hold" => V::Null, "slots" => Vec::<V>::new()};
    let mut payloads: Vec<(String, V)> = Vec::new();
    let mut own_lines: Vec<(String, Vec<String>)> = Vec::new();
    let (mut failed, mut printed) = (false, Vec::new());
    for (registration, count) in registrations.iter().zip(&counts) {
        let id = registration.g("id")?.s()?;
        let driver = provider_driver(&registration.g("driver")?)?;
        if *count == 0 {
            continue;
        }
        let old = if id == "claude" { previous.clone() } else { previous.g("providers").and_then(|providers| providers.gd(&id)).unwrap_or(V::Null) };
        let mut read = || -> R<V> {
            if collection_due(&collector, &id, wake.scheduled, now()?) {
                let result = registered_collection(registration, &reading)?;
                set_collection_result(&collector, &id, result.success, now()?, result.healthy_seconds, None)?;
                if result.incomplete {
                    failed = true;
                    files::event(directory, &format!("{id}_observation_unavailable"), None);
                }
                own_lines.push((id.clone(), result.lines));
                printed.extend(result.action.filter(|action| !action.is_empty()));
                return Ok(result.payload);
            }
            let mut observed = old.clone();
            if collector.g("providers")?.gd(&id)?.g("failures")?.t()? {
                observed = registered_failure(registration, &old, "backoff", None)?;
                failed = true;
            }
            own_lines.push((id.clone(), vec![format!("{}: cached until next scheduled collection", registration.g("name")?.s()?)]));
            Ok(observed)
        };
        let observed = match read() {
            Ok(observed) => observed,
            Err(stop) => {
                failed = true;
                let failure_code = stop.failure_code();
                let mut reason = "collection_failed";
                if failure_code == "state_io_failed" && driver.g("provider")?.eq_s("claude")? {
                    reason = "local_state_unavailable";
                }
                if let Some(known) = stop.said().and_then(|said| REASONS.iter().find(|known| known.eq_ignore_ascii_case(said))) {
                    reason = known;
                }
                let observed = registered_failure(registration, &old, reason, Some(failure_code))?;
                files::event(directory, &format!("{id}_{reason}"), Some(&stop));
                set_collection_result(&collector, &id, false, now()?, 300, Some(failure_code))?;
                observed
            }
        };
        if id == "claude" {
            payload = observed;
        } else {
            payloads.push((id, observed));
        }
    }
    for conflict in collected_ownership(&registrations, &payloads, directory, now()?)? {
        failed = true;
        set_collection_result(&collector, &conflict, false, now()?, 300, None)?;
    }
    // Mirror text reflects final ownership checks, not a superseded proposal.
    let mut lines = Vec::new();
    for registration in &registrations {
        let id = registration.g("id")?.s()?;
        let observed = payloads.iter().find(|(known, _)| *known == id);
        if let (true, Some((_, observed))) = (registration.g("driver")?.ceq_s("codex-app-server")?, observed) {
            let name = name_text(&registration.g("name")?)?;
            for line in format_codex_status(observed, &registration.g("policy")?, now()?)? {
                lines.push(rename_codex(&line, &name)?);
            }
        } else if let Some((_, own)) = own_lines.iter().rev().find(|(known, _)| *known == id) {
            lines.extend(own.iter().cloned());
        }
    }
    payload.add_member("schemaVersion", 2.into(), true)?;
    payload.add_member("generatedAt", now()?.o().into(), true)?;
    payload.add_member("generationId", files::guid().into(), true)?;
    let monitor = wake.observe_only || policy.g("mode")?.eq_s("monitor")?;
    payload.add_member("mode", if monitor { "monitor" } else { "automate" }.into(), true)?;
    if payloads.is_empty() {
        payload.remove_member("providers")?;
    } else {
        payload.add_member("providers", new_obj(payloads.iter().map(|(id, observed)| (id.as_str(), observed.clone())).collect()), true)?;
    }
    let build = json::read_or_null(&wake.root.join("build-info.json")).g("sha")?;
    if build.t()? {
        collector.add_member("runningSha", build, true)?;
    }
    collector.add_member("completedAt", now()?.o().into(), true)?;
    collector.add_member("status", if failed { "incomplete" } else { "ok" }.into(), true)?;
    let runs = match failed {
        true => collector.g("incompleteRuns")?.to_int()?.checked_add(1).map_or_else(throw, Ok)?,
        false => 0,
    };
    collector.add_member("incompleteRuns", runs.into(), true)?;
    payload.add_member("collector", collector.clone(), true)?;
    add_insights(&payload, &policy, directory, &previous, now()?)?;
    let json = json::write(&payload, 24)?;
    files::write_text(&directory.join("status.json"), &format!("{json}{NEWLINE}"), true)?;
    // status.json is the authoritative snapshot. Legacy text/browser mirrors must not turn
    // successful observation into a failed collection.
    let text: String = lines.iter().flat_map(|line| [safe_text(line), NEWLINE.to_string()]).collect();
    let text = if lines.is_empty() { NEWLINE.to_string() } else { text };
    for (name, mirror) in [("status.js", format!("window.CSWAP = {json};{NEWLINE}")), ("status.txt", text)] {
        if let Err(stop) = files::write_text(&directory.join(name), &mirror, true) {
            files::event(directory, "compatibility_output_failed", Some(&stop));
        }
    }
    files::write_json(&directory.join("collector.json"), &collector, 8)?;
    // Busy workers and malformed progress never interrupt collection.
    let _ = (wake.upkeep)(Upkeep::Onboarding);
    // Claude's automatic continue hook follows policy; a settings file that cannot be
    // changed safely is reported and never fails collection.
    let claude = registrations.iter().zip(&counts).any(|(registration, count)| *count > 0 && registration.g("id").is_ok_and(|id| id.as_str() == Some("claude")));
    if !wake.observe_only && claude {
        let kept = || (wake.upkeep)(Upkeep::ContinueHook { remove: !actions(&policy, false)?.continuing });
        if let Err(stop) = kept() {
            files::event(directory, "continue_hook_failed", Some(&stop));
        }
    }
    Ok(Outcome { failed, printed: printed.iter().map(|action| safe_text(action)).collect() })
}

/// Initialize-Hotpl8OnboardingTools: the tools setup installed for this user are found
/// before any the machine has, by this program and by whatever it starts.
fn onboarding_tools(directory: &Path) {
    let bin = directory.join("runtime").join("bin");
    if !bin.is_dir() {
        return;
    }
    let separator = if cfg!(windows) { ';' } else { ':' };
    let path = std::env::var_os("PATH").unwrap_or_default();
    let listed = path.to_string_lossy().split(separator).any(|part| part.eq_ignore_ascii_case(&bin.to_string_lossy()));
    if !listed {
        let mut joined = OsString::from(bin.as_os_str());
        joined.push(separator.to_string());
        joined.push(&path);
        std::env::set_var("PATH", joined);
    }
    std::env::set_var("HOTPL8_NATIVE_BIN", &bin);
}

/// What `collect` was started with.
struct Started {
    root: PathBuf,
    state: Option<PathBuf>,
    programs: [Option<String>; 3],
    scheduled: bool,
    observe_only: bool,
    strict: bool,
}

/// `collect --root <dir> [--state <dir>] [--cswap <program>] [--codex <program>]
/// [--powershell <program>] [--scheduled] [--observe-only] [--strict]`
fn spelled(arguments: &[OsString]) -> Option<Started> {
    const NAMES: [&str; 5] = ["--root", "--state", "--cswap", "--codex", "--powershell"];
    const SWITCHES: [&str; 3] = ["--scheduled", "--observe-only", "--strict"];
    let mut values: [Option<&OsString>; 5] = [None; 5];
    let mut switches = [false; 3];
    let mut rest = arguments.iter();
    while let Some(word) = rest.next() {
        let name = word.to_str()?;
        if let Some(slot) = NAMES.iter().position(|known| *known == name) {
            if values[slot].is_some() {
                return None;
            }
            values[slot] = Some(rest.next()?);
        } else {
            let slot = SWITCHES.iter().position(|known| *known == name).filter(|slot| !switches[*slot])?;
            switches[slot] = true;
        }
    }
    let state = match values[1] {
        Some(directory) => Some(full_path(directory)?),
        None => None,
    };
    let program = |slot: usize| -> Option<Option<String>> {
        match values[slot] {
            Some(named) => Some(Some(named.to_str()?.to_string())),
            None => Some(None),
        }
    };
    Some(Started { root: full_path(values[0]?)?, state, programs: [program(2)?, program(3)?, program(4)?], scheduled: switches[0], observe_only: switches[1], strict: switches[2] })
}

/// The `collect` command: one wake, started by the scheduler or by someone who asked.
/// Answers whether the caller may take it as done; only a caller who asked with `--strict`
/// is ever told that it fell short.
pub fn started(arguments: &[OsString]) -> Result<bool, String> {
    let Some(started) = spelled(arguments) else {
        let words: Vec<String> = arguments.iter().map(|word| word.to_string_lossy().into_owned()).collect();
        return Err(format!("The collector was started with words it does not take: {}", words.join(" ")));
    };
    // The numbers of a snapshot are those of the PowerShell that has always written it.
    set_core(!cfg!(windows));
    packaged_data(&started.root);
    let (Ok(directory), Ok(home)) = (state_directory(&started.root, started.state.as_deref()), user_home()) else { return Ok(!started.strict) };
    onboarding_tools(&directory);
    let [cswap, codex, powershell] = &started.programs;
    let powershell = lane::powershell(powershell.as_deref());
    let lanes = Lanes { root: &started.root, directory: &directory, powershell: &powershell };
    let outcome = collect(&Wake {
        root: &started.root,
        directory: &directory,
        home: &home,
        cswap: cswap.as_deref().filter(|named| !named.is_empty()),
        scheduled: started.scheduled,
        observe_only: started.observe_only,
        clock: &Dto::now,
        codex: &|provider| lanes.codex(provider, codex.as_deref()),
        upkeep: &|upkeep| match upkeep {
            Upkeep::Onboarding => lanes.onboarding(),
            Upkeep::ContinueHook { remove } => lanes.continue_hook(remove, &home),
        },
    });
    let mut stdout = std::io::stdout().lock();
    for line in &outcome.printed {
        let _ = writeln!(stdout, "{line}");
    }
    let _ = stdout.flush();
    Ok(!(started.strict && outcome.failed))
}

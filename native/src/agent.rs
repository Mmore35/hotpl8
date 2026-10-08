//! What the agent interface reports: `status`, `explain`, `accounts` and `readiness`, from
//! the files of one state directory. Reading them runs no provider and writes nothing.
//! The requests, the envelope, the pause leases and onboarding are src/agent-api.ps1's.

use std::cmp::Ordering;
use std::path::Path;

use crate::automation;
use crate::capacity::capacity_accounts;
use crate::claude::{claude_selection, margin_7d_for, model_block, test_ok, Accounts};
use crate::codex::{codex_eligibility, select_codex_slot};
use crate::contract::resolve_window;
use crate::critical::critical_decision;
use crate::json;
use crate::num::round3;
use crate::observation::claude_observation;
use crate::overview::{future_reset, overview_percent};
use crate::pause;
use crate::policy::{actions, assert_codex_policy, assert_policy};
use crate::ps::*;
use crate::registry::{configured_providers, provider_account_rows, provider_accounts, provider_state_directory, provider_view};
use crate::time::Dto;
use crate::{hash, obj};

/// More accounts or observations than any installation has; a file that holds more is not
/// one HotPl8 wrote.
const MOST: usize = 256;

/// Why an operation has no answer: one of the interface's codes, or a stop.
enum Refusal {
    Code(&'static str),
    Stop(Stop),
}
impl From<Stop> for Refusal {
    fn from(stop: Stop) -> Refusal {
        Refusal::Stop(stop)
    }
}
type A<T> = Result<T, Refusal>;

/// ConvertTo-Hotpl8AgentTime, as the instant the text names.
pub(crate) fn instant(value: &V) -> R<Option<Dto>> {
    match value.as_str() {
        Some(text) if !text.is_empty() => catch(|| Dto::parse_external(text)),
        _ => Ok(None),
    }
}
/// ConvertTo-Hotpl8AgentTime
fn time(value: &V) -> R<V> {
    Ok(match instant(value)? {
        Some(at) => at.utc().o().into(),
        None => V::Null,
    })
}
/// Get-Hotpl8AgentAge
fn age(value: &V, now: Dto) -> R<Option<f64>> {
    match instant(value)? {
        Some(at) => Ok(Some(round3(now.utc().since(at.utc()).total_seconds())?)),
        None => Ok(None),
    }
}
fn seconds(age: Option<f64>) -> V {
    age.map_or(V::Null, V::Dbl)
}

/// ConvertTo-Hotpl8AgentReason
fn known(reason: &str) -> &str {
    // Never return arbitrary provider error strings from a local snapshot.
    const KNOWN: [&str; 28] = [
        "eligible",
        "eligible_critical",
        "disabled",
        "stale",
        "unknown",
        "no_observation",
        "duplicate_observation",
        "duplicate_subscription",
        "unsupported",
        "authentication_required",
        "relogin_required",
        "no_credentials",
        "rate_limited",
        "meter_unknown",
        "constraint_unknown",
        "constraint_blocked",
        "below_margin",
        "reset_unconfirmed",
        "model_quota_unknown",
        "model_reset_unconfirmed",
        "model_below_margin",
        "window_unmeasured",
        "malformed",
        "blocked",
        "unavailable",
        "error",
        "model_unknown",
        "binding_changed",
    ];
    if KNOWN.contains(&reason) {
        reason
    } else {
        "unknown"
    }
}

/// Get-Hotpl8AgentPause
fn agent_pause(directory: &Path, now: Dto) -> R<V> {
    let pause = pause::pause(directory, now)?;
    Ok(obj! {"active" => pause.t()?, "until" => time(&pause.g("until")?)?, "invalid" => pause.g("invalid")?.is_true()?})
}

/// Get-Hotpl8AgentPolicy
fn read_policy(directory: &Path) -> A<V> {
    let policy = json::read_or_null(&directory.join("policy.json"));
    let valid = catch(|| {
        assert_policy(&policy)?;
        if policy.g("codex")?.t()? {
            assert_codex_policy(&policy.g("codex")?)?;
        }
        let accounts = provider_accounts(&policy)?;
        for registration in configured_providers(&policy, false)? {
            let id = registration.g("id")?.s()?;
            if accounts.iter().filter(|account| account.provider == id).count() > MOST {
                return Ok(false);
            }
        }
        Ok(true)
    })?;
    if valid == Some(true) {
        Ok(policy)
    } else {
        Err(Refusal::Code("policy_invalid"))
    }
}

/// Get-Hotpl8AgentSnapshot
fn read_snapshot(directory: &Path) -> A<V> {
    let path = directory.join("status.json");
    if !path.exists() {
        return Err(Refusal::Code("snapshot_missing"));
    }
    let snapshot = json::read_or_null(&path);
    let invalid = Err(Refusal::Code("snapshot_invalid"));
    if !snapshot.is_obj() || instant(&snapshot.g("generatedAt")?)?.is_none() {
        return invalid;
    }
    let version = snapshot.g("schemaVersion")?;
    if !version.is_null() && !version.is_in_list(&[V::I32(1), V::I32(2)])? {
        return invalid;
    }
    if snapshot.g("slots")?.arr().len() > MOST || snapshot.path(&["providers", "codex", "slots"])?.arr().len() > MOST {
        return invalid;
    }
    let providers = snapshot.g("providers")?;
    if providers.is_obj() {
        for (_, payload) in providers.props()? {
            if payload.g("slots")?.arr().len() > MOST {
                return invalid;
            }
        }
    }
    Ok(snapshot)
}

/// A window's name is its length in minutes: '^[1-9][0-9]{0,5}$', whose end also stands
/// before one last line feed.
fn window_name(name: &str) -> bool {
    let digits = name.strip_suffix('\n').unwrap_or(name).as_bytes();
    (1..=6).contains(&digits.len()) && digits[0] != b'0' && digits.iter().all(u8::is_ascii_digit)
}

/// Test-Hotpl8AgentCodexObservation
fn codex_observed(slot: &V, meter: &str) -> R<bool> {
    let bucket = slot.g("buckets")?.gd(meter)?;
    // Eligibility owns the codes of a bucket that was not observed.
    if !bucket.t()? || bucket.g("status")?.ne_s("observed")? {
        return Ok(true);
    }
    let windows = bucket.g("windows")?;
    if !windows.is_obj() {
        return Ok(false);
    }
    let windows = windows.props()?;
    if windows.is_empty() || windows.len() > 8 {
        return Ok(false);
    }
    for (name, window) in &windows {
        if !window_name(name) || !window.is_obj() {
            return Ok(false);
        }
        let remaining = window.g("remainingPercent")?;
        if !remaining.is_number() || remaining.lt_i(0)? || remaining.gt_i(100)? {
            return Ok(false);
        }
        let resets = window.g("resetsAt")?;
        if !resets.is_null() && (!resets.is_number() || resets.lt_i(0)? || resets.gt(&V::I64(253_402_300_799))? || resets.floor()?.ne(&resets)?) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// `$id -in @($list|ForEach-Object {[string]$_})`
fn listed(id: &str, list: &V) -> R<bool> {
    for item in list.arr() {
        if text_eq(&item.s()?, id)? {
            return Ok(true);
        }
    }
    Ok(false)
}

/// One account of a readiness answer.
struct Row {
    slot: String,
    eligible: bool,
    reason: String,
    observed_at: V,
    age: Option<f64>,
    reserve: bool,
    windows: Vec<V>,
}

/// Whether the selector's choice is an account the checks above passed.
fn confirmed(choice: &V, rows: &[Row]) -> R<bool> {
    let slot = choice.s()?;
    for row in rows {
        if row.eligible && V::s_of(&row.slot).ceq_s(&slot)? {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Get-Hotpl8NativeAgentReadiness: one family's accounts as the view of its provider holds
/// them, `directory` the provider's own and `control` the installation's.
fn native_readiness(policy: &V, snapshot: &V, directory: &Path, family: &str, model: &str, now: Dto, control: &Path) -> A<V> {
    let claude = family == "claude";
    let pause = agent_pause(control, now)?;
    let part = if claude { policy.clone() } else { policy.g("codex")? };
    let meter = if claude {
        "claude".to_string()
    } else if part.g("defaultMeter")?.t()? {
        part.g("defaultMeter")?.s()?
    } else {
        "codex".to_string()
    };
    if !model.is_empty() && family != "codex" {
        return Err(Refusal::Code("model_unknown"));
    }
    // A list that is not there is one account with no name, as PowerShell reads it.
    let configured: Vec<String> = if claude {
        policy.g("prefer")?.arr().iter().map(|id| id.s()).collect::<R<_>>()?
    } else {
        filter(&part.g("slots")?.each(), |slot| slot.t())?.iter().map(|slot| slot.g("id")?.s()).collect::<R<_>>()?
    };
    let observations = held(if claude { snapshot.g("slots")?.arr() } else { snapshot.path(&["providers", "codex", "slots"])?.arr() })?;
    let names: Vec<V> = configured.iter().map(|id| V::s_of(id)).collect();
    let active = if claude && V::from(snapshot.g("active")?.s()?).is_in_list(&names)? { V::from(snapshot.g("active")?.s()?) } else { V::Null };
    let mut rows: Vec<Row> = Vec::new();
    let mut usable: Vec<V> = Vec::new();
    let mut held_accounts = Accounts::default();
    let mut identities = Keys::new();
    for id in &configured {
        let matches = filter(&observations, |observation| observation.g(if claude { "slot" } else { "id" })?.sv()?.ceq_s(id))?;
        let slot = if matches.len() == 1 { matches[0].clone() } else { V::Null };
        let observed = slot.g("observedAt")?;
        let seen = age(&observed, now)?;
        let mut reason = "no_observation".to_string();
        let mut eligible = false;
        let mut windows: Vec<V> = Vec::new();
        let longest = if claude && !policy.g("maxUsageAgeS")?.is_null() { policy.g("maxUsageAgeS")?.dbl()? } else { 900.0 };
        if listed(id, &part.g("disabled")?)? {
            reason = "disabled".into();
        } else if matches.len() > 1 {
            reason = "duplicate_observation".into();
        } else if slot.t()? {
            if slot.g("status")?.ne_s("ok")? {
                reason = slot.g("status")?.s()?;
            } else if seen.is_none_or(|seen| seen < -5.0 || seen > longest) {
                reason = "stale".into();
            } else if slot.g("streamKey")?.t()? && identities.contains(&slot.g("streamKey")?.s()?)? {
                reason = "duplicate_subscription".into();
            } else {
                if slot.g("streamKey")?.t()? {
                    identities.insert(&slot.g("streamKey")?.s()?)?;
                }
                if claude {
                    // Same rollover rule as the dashboard and the overview, so the
                    // API never reports an unmeasured window the UI calls refilled.
                    let w7 = resolve_window(&slot.g("used7d")?, &slot.g("reset7d")?, &observed, now, false)?;
                    let w5 = resolve_window(&slot.g("used5h")?, &slot.g("reset5h")?, &observed, now, false)?;
                    let week = overview_percent(&w7.g("used")?)? && (w7.g("rolledOver")?.t()? || future_reset(&w7.g("resetAt")?, now, false)?);
                    let short = overview_percent(&w5.g("used")?)?
                        && (w5.g("rolledOver")?.t()?
                            || future_reset(&w5.g("resetAt")?, now, false)?
                            || (slot.g("cold")?.is_true()? && slot.g("used5h")?.eq_i(0)? && !slot.g("reset5h")?.t()?));
                    let number = V::s_of(id).to_int()?;
                    let blocked = model_block(&slot.g("scoped")?, policy, number, now, &observed)?;
                    let h5 = if short { Some(100.0 - w5.g("used")?.dbl()?) } else { None };
                    let h7 = if week { Some(100.0 - w7.g("used")?.dbl()?) } else { None };
                    let entry = hash! {
                        "h5" => seconds(h5),
                        "h7" => seconds(h7),
                        // A zero floor is not permission to use an exhausted account, including in critical mode.
                        "fresh" => slot.g("fresh")?.is_true()? && short && week && h5 != Some(0.0) && h7 != Some(0.0),
                        "modelBlocked" => blocked.t()?,
                        "obj" => hash! {"usage" => hash! {
                            "fiveHour" => hash! {"resetsAt" => w5.g("resetAt")?},
                            "sevenDay" => hash! {"resetsAt" => w7.g("resetAt")?},
                            "scoped" => slot.g("scoped")?,
                        }},
                    };
                    entry.set("observation", claude_observation(&slot, policy)?)?;
                    held_accounts.put(number, entry.clone());
                    eligible = test_ok(&entry, V::Dbl(policy.g("margin5h")?.dbl()?), margin_7d_for(policy, &V::I32(number))?, now)?.t()?;
                    reason = if blocked.t()? {
                        blocked.s()?
                    } else if !slot.g("fresh")?.t()? {
                        "stale".into()
                    } else if !short || !week {
                        "window_unmeasured".into()
                    } else if eligible {
                        "eligible".into()
                    } else {
                        "below_margin".into()
                    };
                    for (minutes, window) in [(300, &w5), (10080, &w7)] {
                        let used = window.g("used")?;
                        windows.push(obj! {
                            "durationMinutes" => minutes,
                            "remainingPercent" => if overview_percent(&used)? { V::Dbl(100.0 - used.dbl()?) } else { V::Null },
                            "resetsAt" => time(&window.g("resetAt")?)?,
                        });
                    }
                } else if !codex_observed(&slot, &meter)? {
                    reason = "malformed".into();
                } else {
                    usable.push(slot.clone());
                    reason = codex_eligibility(&slot, &part, &meter, now, false)?.s()?;
                    eligible = text_eq(&reason, "eligible")?;
                    let measured = slot.g("buckets")?.gd(&meter)?.g("windows")?;
                    for (name, window) in if measured.is_obj() { measured.props()? } else { Vec::new() }.iter().take(8) {
                        if !window_name(name) {
                            continue;
                        }
                        // The rollover rule the eligibility just applied, so one
                        // response never calls a window refilled and empty at once.
                        let rolled = window.t()? && resolve_window(&window.g("usedPercent")?, &window.g("resetsAt")?, &window.g("observedAt")?, now, true)?.g("rolledOver")?.t()?;
                        let resets = window.g("resetsAt")?;
                        let reset = if rolled || resets.is_null() { None } else { catch(|| Ok(Dto::from_unix_seconds(resets.to_long()?)?.o()))? };
                        let remaining = window.g("remainingPercent")?;
                        windows.push(obj! {
                            "durationMinutes" => V::s_of(name).to_int()?,
                            "remainingPercent" => if rolled { V::I32(100) } else if overview_percent(&remaining)? { remaining } else { V::Null },
                            "resetsAt" => reset.map_or(V::Null, V::from),
                        });
                    }
                }
            }
        }
        rows.push(Row { slot: id.clone(), eligible, reason: known(&reason).to_string(), observed_at: time(&observed)?, age: seen, reserve: listed(id, &part.g("reserve")?)?, windows });
    }
    let (mut selected, mut proposed);
    let mut switching = false;
    let (selection_held, critical) = if claude {
        let prefer: Vec<i32> = configured.iter().map(|id| V::s_of(id).to_int()).collect::<R<_>>()?;
        let selection = claude_selection(policy, &prefer, &held_accounts, if active.is_null() { 0 } else { active.to_int()? }, now, &snapshot.g("critical")?)?;
        let critical = selection.critical.g("active")?.is_true()?;
        if critical {
            let ranked = selection.critical.g("ranked")?;
            for row in &mut rows {
                let slot = V::s_of(&row.slot);
                if !slot.is_in(&ranked)? {
                    continue;
                }
                let entry = held_accounts.get(slot.to_int()?);
                if entry.g("fresh")?.t()? && !entry.g("modelBlocked")?.t()? {
                    (row.eligible, row.reason) = (true, "eligible_critical".to_string());
                }
            }
        }
        proposed = if !selection.target.is_null() {
            V::from(selection.target.s()?)
        } else if selection.active_ok {
            active.clone()
        } else {
            V::Null
        };
        // Read the current hold file; a published snapshot can predate a hold change.
        // A corrupt legacy hold expires rather than holding forever. Automation pauses
        // and agent leases have a separate, intentionally fail-closed contract.
        let held = automation::hold(directory, now).is_some();
        switching = actions(policy, false)?.switching && !pause.g("active")?.t()? && !held;
        selected = if switching {
            proposed.clone()
        } else if selection.active_ok {
            active.clone()
        } else {
            V::Null
        };
        (held, critical)
    } else {
        let codex = snapshot.path(&["providers", "codex"])?;
        let (hold, held) = if control.join("hold.json").exists() {
            // The hold of the installation's own file, which holds for as long as it says.
            let held = automation::hold(control, now).is_some();
            (V::Bool(held), held)
        } else {
            let hold = codex.g("hold")?;
            let held = hold.t()? && instant(&hold.g("until")?)?.is_none_or(|until| until.ticks > now.ticks);
            (if held { hold } else { V::Null }, held)
        };
        let mut prior = codex.g("recommendations")?.gd(&meter)?.s()?;
        if prior.is_empty() {
            prior = codex.g("recommendedSlot")?.s()?;
        }
        let state = codex.g("critical")?.gd(&meter)?;
        let observed = obj! {"providers" => hash! {"codex" => hash! {"slots" => usable.clone()}}};
        let critical_accounts = capacity_accounts(&observed, &part, "codex", now, &meter, false)?;
        let critical = critical_decision(&critical_accounts, &part, &prior, &state, now)?.g("active")?.is_true()?;
        if critical {
            for row in &mut rows {
                let own = filter(&usable, |slot| slot.g("id")?.ceq_s(&row.slot))?;
                if own.len() == 1 && codex_eligibility(&own[0], &part, &meter, now, true)?.eq_s("eligible")? {
                    (row.eligible, row.reason) = (true, "eligible_critical".to_string());
                }
            }
        }
        selected = select_codex_slot(&usable, &part, &meter, &prior, &hold, now, &state)?;
        proposed = selected.clone();
        (held, critical)
    };
    // Pure selectors are authoritative; never publish a candidate that failed validation above.
    if selected.t()? && !confirmed(&selected, &rows)? {
        selected = V::Null;
    }
    if proposed.t()? && !confirmed(&proposed, &rows)? {
        proposed = V::Null;
    }
    let mut next = V::Null;
    for window in rows.iter().flat_map(|row| &row.windows) {
        let resets = window.g("resetsAt")?;
        if future_reset(&resets, now, false)? && (next.is_null() || order_text(&resets.s()?, &next.s()?)? == Ordering::Less) {
            next = resets;
        }
    }
    let accounts: Vec<V> = rows
        .into_iter()
        .map(|row| {
            obj! {
                "slot" => row.slot,
                "eligible" => row.eligible,
                "reason" => row.reason,
                "observedAt" => row.observed_at,
                "ageSeconds" => seconds(row.age),
                "reserve" => row.reserve,
                "windows" => row.windows,
            }
        })
        .collect();
    Ok(obj! {
        "provider" => family,
        "meter" => meter,
        "eligible" => selected.t()?,
        "selectedSlot" => if selected.t()? { V::from(selected.s()?) } else { V::Null },
        "activeSlot" => &active,
        "proposedSlot" => &proposed,
        "requiresSelection" => claude && proposed.t()? && proposed.ne(&active)?,
        "switchingPermitted" => switching,
        "automationPaused" => pause.g("active")?,
        "pause" => &pause,
        "selectionHeld" => selection_held,
        "mode" => if policy.g("mode")?.t()? { policy.g("mode")? } else { "legacy".into() },
        "critical" => critical,
        "requiresNativeValidation" => true,
        "scope" => if family == "codex" { "next-launch" } else { "active-or-proposed-account" },
        "nextObservedResetAt" => next,
        "accounts" => accounts,
    })
}

/// Get-Hotpl8AgentReadiness
fn readiness(policy: &V, snapshot: &V, directory: &Path, provider: &str, model: &str, now: Dto) -> A<V> {
    let view = provider_view(snapshot, policy, provider, &[])?;
    let state = provider_state_directory(directory, provider)?;
    let result = native_readiness(&view.g("policy")?, &view.g("snapshot")?, &state, &view.g("provider")?.s()?, model, now, directory)?;
    result.set("provider", provider.into())?;
    result.add_member("driver", view.path(&["registration", "driver"])?, true)?;
    Ok(result)
}

/// `$left -gt $right` of two times as the interface writes them, either of which may be none.
fn later(left: &V, right: &V) -> R<bool> {
    Ok(match (left.as_str(), right.as_str()) {
        (Some(left), Some(right)) => order_text(left, right)? == Ordering::Greater,
        (Some(_), None) => true,
        _ => false,
    })
}

fn data(operation: &str, directory: &Path, provider: &str, model: &str, now: Dto) -> A<V> {
    let policy = read_policy(directory)?;
    match operation {
        // A pause lease is written by PowerShell, once the policy is known to be valid.
        "pause.acquire" | "pause.release" => return Ok(V::Null),
        "accounts" => {
            let mut rows: Vec<V> = Vec::new();
            for row in provider_account_rows(&policy)? {
                rows.push(obj! {"provider" => row.g("provider")?, "slot" => row.g("slot")?, "disabled" => row.g("disabled")?, "reserve" => row.g("reserve")?});
            }
            return Ok(obj! {"accounts" => rows});
        }
        "readiness" | "status" | "explain" => {}
        _ => return Ok(fail(format!("The agent interface has no operation named {operation} that is answered from the files."))?),
    }
    let snapshot = read_snapshot(directory)?;
    if operation == "readiness" {
        return readiness(&policy, &snapshot, directory, provider, model, now);
    }
    let mut collector = json::read_or_null(&directory.join("collector.json"));
    let completed = time(&snapshot.path(&["collector", "completedAt"])?)?;
    // A marker older than the snapshot's own completion cannot override it.
    if !collector.t()? || (completed.t()? && later(&completed, &time(&collector.g("startedAt")?)?)?) {
        collector = snapshot.g("collector")?;
    }
    let providers = obj! {};
    for registration in configured_providers(&policy, true)? {
        let id = registration.g("id")?.s()?;
        providers.add_member(&id, readiness(&policy, &snapshot, directory, &id, "", now)?, false)?;
    }
    let status = collector.g("status")?;
    Ok(obj! {
        "generatedAt" => time(&snapshot.g("generatedAt")?)?,
        "ageSeconds" => seconds(age(&snapshot.g("generatedAt")?, now)?),
        "collector" => obj! {
            "status" => if status.in_s(&["ok", "incomplete", "collecting", "started", "failed"])? { status } else { "unknown".into() },
            "startedAt" => time(&collector.g("startedAt")?)?,
            "completedAt" => time(&collector.g("completedAt")?)?,
        },
        "providers" => providers,
    })
}

/// What one operation reports: `{data}`, or `{code}` when the interface has a code for why
/// there is none.
pub fn answer(operation: &str, directory: &Path, provider: &str, model: &str, now: Dto) -> R<V> {
    match data(operation, directory, provider, model, now) {
        Ok(data) => Ok(obj! {"data" => data}),
        Err(Refusal::Code(code)) => Ok(obj! {"code" => code}),
        Err(Refusal::Stop(stop)) => Err(stop),
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::dashboard::tests::{NOON, POLICY, STATUS};
    use crate::display::packaged_data;
    use crate::files::tests::scratch;
    use std::fs;
    use std::path::PathBuf;

    pub fn noon() -> Dto {
        Dto::parse(NOON).ok().unwrap()
    }
    fn read(directory: &Path, name: &str) -> V {
        json::parse(&fs::read_to_string(directory.join(name)).unwrap(), name).ok().unwrap()
    }
    fn save(directory: &Path, name: &str, value: &V) {
        fs::write(directory.join(name), json::compact(value, 24).ok().unwrap()).unwrap();
    }
    /// A state directory holding the dashboard's fixture snapshot and its policy, whose
    /// Codex accounts are given the homes a policy must name.
    pub fn state(name: &str) -> PathBuf {
        packaged_data(&Path::new(env!("CARGO_MANIFEST_DIR")).join(".."));
        set_core(false);
        let directory = scratch(name);
        let policy = json::parse(POLICY, "policy").ok().unwrap();
        for slot in policy.path(&["codex", "slots"]).ok().unwrap().arr() {
            let home = directory.join(format!("home-{}", slot.g("id").ok().unwrap().s().ok().unwrap()));
            set(&slot, "home", home.to_str().unwrap().into());
        }
        save(&directory, "policy.json", &policy);
        fs::write(directory.join("status.json"), STATUS).unwrap();
        directory
    }
    /// One file of the directory, changed and written back.
    pub fn changed(directory: &Path, name: &str, change: impl FnOnce(&V)) {
        let value = read(directory, name);
        change(&value);
        save(directory, name, &value);
    }
    pub fn set(value: &V, name: &str, member: V) {
        value.add_member(name, member, true).ok().unwrap();
    }
    fn put(value: &V, path: &[&str], name: &str, member: V) {
        set(&value.path(path).ok().unwrap(), name, member);
    }
    fn text(json: &str) -> V {
        json::parse(&format!("{{\"is\":{json}}}"), "test").ok().unwrap().g("is").ok().unwrap()
    }
    fn asked_at(directory: &Path, operation: &str, provider: &str, model: &str, now: Dto) -> V {
        match answer(operation, directory, provider, model, now) {
            Ok(answer) => answer,
            Err(stop) => panic!("{}", stop.message()),
        }
    }
    fn asked(directory: &Path, operation: &str, provider: &str) -> String {
        json::compact(&asked_at(directory, operation, provider, "", noon()), 24).ok().unwrap()
    }
    fn ready(directory: &Path, provider: &str) -> V {
        asked_at(directory, "readiness", provider, "", noon()).g("data").ok().unwrap()
    }
    fn is(value: &V, path: &[&str]) -> String {
        json::compact(&obj! {"is" => value.path(path).ok().unwrap()}, 24).ok().unwrap()
    }
    /// `eligible reason` of one account of a readiness answer.
    fn account(readiness: &V, slot: &str) -> String {
        let rows = readiness.g("accounts").ok().unwrap().arr();
        let row = rows.iter().find(|row| row.g("slot").ok().unwrap().s().ok().unwrap() == slot).unwrap();
        format!("{} {}", row.g("eligible").ok().unwrap().s().ok().unwrap(), row.g("reason").ok().unwrap().s().ok().unwrap())
    }
    /// The Claude accounts of the snapshot, changed and put back.
    fn claude_slots(directory: &Path, change: impl FnOnce(&mut Vec<V>)) {
        changed(directory, "status.json", |status| {
            let mut slots = status.g("slots").ok().unwrap().arr();
            change(&mut slots);
            status.set("slots", slots.into()).ok().unwrap();
        });
    }
    /// What the first Codex account's meter was seen to hold, changed.
    fn codex_bucket(directory: &Path, change: impl FnOnce(&V)) {
        changed(directory, "status.json", |status| change(&status.path(&["providers", "codex", "slots"]).ok().unwrap().arr()[0].path(&["buckets", "codex"]).ok().unwrap()));
    }
    /// A policy under which HotPl8 switches accounts itself.
    fn switching(policy: &V) {
        set(policy, "mode", "automate".into());
        set(policy, "switchEnabled", true.into());
    }
    /// Why Claude's account `slot` can or cannot be used once the directory is changed.
    fn claude(slot: &str, change: impl FnOnce(&Path)) -> String {
        let directory = state("agent-reason");
        change(&directory);
        account(&ready(&directory, "claude"), slot)
    }
    /// The same after one member of the first account's observation is changed.
    fn first(name: &str, value: V) -> String {
        claude("1", |directory| claude_slots(directory, |slots| set(&slots[0], name, value)))
    }
    /// The same after one member of the policy is changed.
    fn ruled(name: &str, value: V) -> String {
        claude("1", |directory| changed(directory, "policy.json", |policy| set(policy, name, value)))
    }
    /// Why the first Codex account can or cannot be used once its meter is changed.
    fn codex(change: impl FnOnce(&V)) -> String {
        let directory = state("agent-reason-codex");
        codex_bucket(&directory, change);
        account(&ready(&directory, "codex"), "work")
    }
    /// The same after one member of its week is changed.
    fn week(name: &str, value: V) -> String {
        codex(|bucket| put(bucket, &["windows", "10080"], name, value))
    }
    /// The same after a window is added to it.
    fn window(name: &str, value: V) -> String {
        codex(|bucket| put(bucket, &["windows"], name, value))
    }

    #[test]
    fn without_a_valid_policy_every_operation_has_one_code() {
        let directory = state("agent-no-policy");
        fs::remove_file(directory.join("policy.json")).unwrap();
        for operation in ["status", "explain", "accounts", "readiness", "pause.acquire", "pause.release"] {
            assert_eq!(asked(&directory, operation, "claude"), r#"{"code":"policy_invalid"}"#, "{operation}");
        }
        fs::write(directory.join("policy.json"), r#"{"schemaVersion":7}"#).unwrap();
        assert_eq!(asked(&directory, "status", ""), r#"{"code":"policy_invalid"}"#);
        fs::write(directory.join("policy.json"), "{").unwrap();
        assert_eq!(asked(&directory, "status", ""), r#"{"code":"policy_invalid"}"#);
        // A policy whose Codex part is not valid is not a valid policy.
        fs::write(directory.join("policy.json"), POLICY).unwrap();
        assert_eq!(asked(&directory, "accounts", ""), r#"{"code":"policy_invalid"}"#);
    }

    #[test]
    fn accounts_are_the_policys_and_need_no_snapshot() {
        let directory = state("agent-accounts");
        fs::remove_file(directory.join("status.json")).unwrap();
        assert_eq!(
            asked(&directory, "accounts", ""),
            concat!(
                r#"{"data":{"accounts":[{"provider":"claude","slot":"1","disabled":false,"reserve":false},{"provider":"claude","slot":"2","disabled":false,"reserve":true},"#,
                r#"{"provider":"codex","slot":"work","disabled":false,"reserve":false},{"provider":"codex","slot":"personal","disabled":false,"reserve":false}]}}"#
            )
        );
        // A lease is PowerShell's to write, once the policy is known to be valid.
        assert_eq!(asked(&directory, "pause.acquire", ""), r#"{"data":null}"#);
        assert_eq!(asked(&directory, "pause.release", ""), r#"{"data":null}"#);
        for operation in ["status", "explain", "readiness"] {
            assert_eq!(asked(&directory, operation, "codex"), r#"{"code":"snapshot_missing"}"#, "{operation}");
        }
        changed(&directory, "policy.json", |policy| {
            set(policy, "disabled", text("[2]"));
            put(policy, &["codex"], "disabled", text(r#"["work"]"#));
            put(policy, &["codex"], "reserve", text(r#"["personal"]"#));
        });
        assert_eq!(
            asked(&directory, "accounts", ""),
            concat!(
                r#"{"data":{"accounts":[{"provider":"claude","slot":"1","disabled":false,"reserve":false},{"provider":"claude","slot":"2","disabled":true,"reserve":true},"#,
                r#"{"provider":"codex","slot":"work","disabled":true,"reserve":false},{"provider":"codex","slot":"personal","disabled":false,"reserve":true}]}}"#
            )
        );
    }

    #[test]
    fn a_snapshot_that_is_not_one_hotpl8_wrote_is_invalid() {
        let invalid = |name: &str, change: &dyn Fn(&V)| {
            let directory = state("agent-invalid");
            changed(&directory, "status.json", change);
            assert_eq!(asked(&directory, "status", ""), r#"{"code":"snapshot_invalid"}"#, "{name}");
            assert_eq!(asked(&directory, "readiness", "claude"), r#"{"code":"snapshot_invalid"}"#, "{name}");
        };
        let many = |count: usize| V::from(vec![obj! {"slot" => 9}; count]);
        invalid("no time", &|status| set(status, "generatedAt", V::Null));
        invalid("an empty time", &|status| set(status, "generatedAt", "".into()));
        invalid("a time that is a number", &|status| set(status, "generatedAt", V::I32(1_789_210_800)));
        invalid("a time in other words", &|status| set(status, "generatedAt", "noon on Saturday".into()));
        invalid("a later schema", &|status| set(status, "schemaVersion", V::I32(3)));
        invalid("a schema in words", &|status| set(status, "schemaVersion", "two".into()));
        invalid("too many accounts", &|status| set(status, "slots", many(257)));
        invalid("too many Codex accounts", &|status| put(status, &["providers", "codex"], "slots", many(257)));
        invalid("too many accounts of another provider", &|status| put(status, &["providers"], "other", obj! {"slots" => many(257)}));
        let directory = state("agent-invalid-text");
        fs::write(directory.join("status.json"), "[1]").unwrap();
        assert_eq!(asked(&directory, "status", ""), r#"{"code":"snapshot_invalid"}"#);
        fs::write(directory.join("status.json"), "{").unwrap();
        assert_eq!(asked(&directory, "status", ""), r#"{"code":"snapshot_invalid"}"#);
        // As many as an installation may have, and either schema, is a snapshot.
        let directory = state("agent-valid");
        changed(&directory, "status.json", |status| {
            set(status, "schemaVersion", V::I32(2));
            put(status, &["providers"], "other", obj! {"slots" => many(256)});
        });
        assert!(asked(&directory, "status", "").starts_with(r#"{"data":{"generatedAt":"2026-09-12T11:59:18.0000000+00:00","#));
    }

    #[test]
    fn claude_readiness_is_what_the_snapshot_and_the_policy_say() {
        let directory = state("agent-claude");
        assert_eq!(
            asked(&directory, "readiness", "claude"),
            concat!(
                r#"{"data":{"provider":"claude","meter":"claude","eligible":true,"selectedSlot":"1","activeSlot":"1","proposedSlot":"1","requiresSelection":false,"#,
                r#""switchingPermitted":false,"automationPaused":false,"pause":{"active":false,"until":null,"invalid":false},"selectionHeld":false,"mode":"monitor","#,
                r#""critical":false,"requiresNativeValidation":true,"scope":"active-or-proposed-account","nextObservedResetAt":"2026-09-12T13:23:00.0000000+00:00","#,
                r#""accounts":[{"slot":"1","eligible":true,"reason":"eligible","observedAt":"2026-09-12T11:59:18.0000000+00:00","ageSeconds":42,"reserve":false,"#,
                r#""windows":[{"durationMinutes":300,"remainingPercent":62,"resetsAt":"2026-09-12T13:23:00.0000000+00:00"},"#,
                r#"{"durationMinutes":10080,"remainingPercent":46,"resetsAt":"2026-09-14T16:00:00.0000000+00:00"}]},"#,
                // An account that has not been used has a whole short window and no time it ends.
                r#"{"slot":"2","eligible":true,"reason":"eligible","observedAt":"2026-09-12T11:59:18.0000000+00:00","ageSeconds":42,"reserve":true,"#,
                r#""windows":[{"durationMinutes":300,"remainingPercent":100,"resetsAt":null},"#,
                r#"{"durationMinutes":10080,"remainingPercent":83,"resetsAt":"2026-09-17T12:00:00.0000000+00:00"}]}],"driver":"claude-cswap"}}"#
            )
        );
    }

    #[test]
    fn codex_readiness_is_what_the_snapshot_and_the_policy_say() {
        let directory = state("agent-codex");
        assert_eq!(
            asked(&directory, "readiness", "codex"),
            concat!(
                r#"{"data":{"provider":"codex","meter":"codex","eligible":true,"selectedSlot":"work","activeSlot":null,"proposedSlot":"work","requiresSelection":false,"#,
                r#""switchingPermitted":false,"automationPaused":false,"pause":{"active":false,"until":null,"invalid":false},"selectionHeld":false,"mode":"monitor","#,
                r#""critical":false,"requiresNativeValidation":true,"scope":"next-launch","nextObservedResetAt":"2026-09-12T14:00:00.0000000+00:00","#,
                r#""accounts":[{"slot":"work","eligible":true,"reason":"eligible","observedAt":"2026-09-12T11:59:18.0000000+00:00","ageSeconds":42,"reserve":false,"#,
                r#""windows":[{"durationMinutes":10080,"remainingPercent":59,"resetsAt":"2026-09-15T12:00:00.0000000+00:00"},"#,
                r#"{"durationMinutes":300,"remainingPercent":74,"resetsAt":"2026-09-12T14:00:00.0000000+00:00"}]},"#,
                // An account that is not a reserve keeps back the smaller part of its week.
                r#"{"slot":"personal","eligible":true,"reason":"eligible","observedAt":"2026-09-12T11:59:18.0000000+00:00","ageSeconds":42,"reserve":false,"#,
                r#""windows":[{"durationMinutes":10080,"remainingPercent":11,"resetsAt":"2026-09-13T06:00:00.0000000+00:00"}]}],"driver":"codex-app-server"}}"#
            )
        );
    }

    #[test]
    fn only_codex_takes_a_model() {
        let directory = state("agent-model");
        let with = |provider: &str| json::compact(&asked_at(&directory, "readiness", provider, "fixture-model", noon()), 24).ok().unwrap();
        assert_eq!(with("claude"), r#"{"code":"model_unknown"}"#);
        assert!(with("codex").starts_with(r#"{"data":{"provider":"codex","meter":"codex","eligible":true,"selectedSlot":"work","#));
    }

    #[test]
    fn a_claude_account_that_cannot_be_used_says_why() {
        assert_eq!(claude("1", |_| {}), "True eligible");
        assert_eq!(ruled("disabled", text("[1]")), "False disabled");
        assert_eq!(claude("1", |directory| claude_slots(directory, |slots| slots.push(slots[0].clone()))), "False duplicate_observation");
        assert_eq!(claude("1", |directory| claude_slots(directory, |slots| drop(slots.remove(0)))), "False no_observation");
        assert_eq!(first("status", "rate_limited".into()), "False rate_limited");
        // What a provider said is never passed on.
        assert_eq!(first("status", "Quota exceeded for fixture-a".into()), "False unknown");
        assert_eq!(first("status", "Rate_Limited".into()), "False unknown");
        // Read more than fifteen minutes ago, or by a clock more than five seconds ahead.
        assert_eq!(first("observedAt", "2026-09-12T11:44:59.0000000+00:00".into()), "False stale");
        assert_eq!(first("observedAt", "2026-09-12T11:45:00.0000000+00:00".into()), "True eligible");
        assert_eq!(first("observedAt", "2026-09-12T12:00:06.0000000+00:00".into()), "False stale");
        assert_eq!(first("observedAt", "2026-09-12T12:00:05.0000000+00:00".into()), "True eligible");
        assert_eq!(first("observedAt", V::Null), "False stale");
        assert_eq!(first("observedAt", "a minute ago".into()), "False stale");
        assert_eq!(first("fresh", false.into()), "False stale");
        assert_eq!(first("used7d", V::Null), "False window_unmeasured");
        assert_eq!(first("used5h", V::Null), "False window_unmeasured");
        assert_eq!(first("used5h", V::I32(101)), "False window_unmeasured");
        // A window that ended before it was read, and has no later end, is not measured.
        assert_eq!(first("reset5h", "2026-09-12T11:00:00.0000000+00:00".into()), "False window_unmeasured");
        assert_eq!(first("used5h", V::I32(100)), "False below_margin");
        assert_eq!(first("used7d", V::I32(100)), "False below_margin");
        // The policy's own longest age, and its own margin.
        assert_eq!(ruled("maxUsageAgeS", V::I32(41)), "False stale");
        assert_eq!(ruled("maxUsageAgeS", V::I32(42)), "True eligible");
        assert_eq!(ruled("margin5h", V::I32(63)), "False below_margin");
        assert_eq!(ruled("margin5h", V::I32(62)), "True eligible");
        // One subscription seen under two accounts is counted once, for the first of them.
        let same = |directory: &Path| claude_slots(directory, |slots| slots.iter().for_each(|slot| set(slot, "streamKey", "fixture-stream".into())));
        assert_eq!(claude("1", same), "True eligible");
        assert_eq!(claude("2", same), "False duplicate_subscription");
    }

    #[test]
    fn a_codex_account_that_cannot_be_used_says_why() {
        assert_eq!(codex(|_| {}), "True eligible");
        assert_eq!(codex(|bucket| set(bucket, "windows", obj! {})), "False malformed");
        assert_eq!(codex(|bucket| set(bucket, "windows", text("[1]"))), "False malformed");
        assert_eq!(window("weekly", obj! {"remainingPercent" => 50}), "False malformed");
        assert_eq!(window("0", obj! {"remainingPercent" => 50}), "False malformed");
        assert_eq!(window("1000000", obj! {"remainingPercent" => 50}), "False malformed");
        assert_eq!(window("60", V::I32(50)), "False malformed");
        assert_eq!(week("remainingPercent", V::I32(101)), "False malformed");
        assert_eq!(week("remainingPercent", V::I32(-1)), "False malformed");
        assert_eq!(week("remainingPercent", "59".into()), "False malformed");
        assert_eq!(week("remainingPercent", V::Null), "False malformed");
        assert_eq!(week("resetsAt", V::I32(-1)), "False malformed");
        assert_eq!(week("resetsAt", text("1789473600.5")), "False malformed");
        assert_eq!(week("resetsAt", V::I64(253_402_300_800)), "False malformed");
        assert_eq!(week("resetsAt", "2026-09-15".into()), "False malformed");
        // Eight windows are as many as a meter has.
        let more = |count: i32| codex(|bucket| (1..=count).for_each(|minutes| put(bucket, &["windows"], &minutes.to_string(), obj! {"remainingPercent" => 50, "usedPercent" => 50})));
        assert_eq!(more(7), "False malformed");
        assert_ne!(more(6), "False malformed");
        // A meter that was not observed is the eligibility rule's to name.
        assert_ne!(codex(|bucket| set(bucket, "status", "unsupported".into())), "False malformed");
        // The other limits are met where they stand.
        assert_ne!(week("remainingPercent", V::I32(100)), "False malformed");
        assert_ne!(week("remainingPercent", V::I32(0)), "False malformed");
        assert_ne!(week("resetsAt", V::I64(253_402_300_799)), "False malformed");
        assert_ne!(week("resetsAt", V::I32(0)), "False malformed");
        assert_ne!(week("resetsAt", V::Null), "False malformed");
        // A reserve keeps back the larger part of its week, which this one has not got.
        let directory = state("agent-reason-reserve");
        assert_eq!(account(&ready(&directory, "codex"), "personal"), "True eligible");
        changed(&directory, "policy.json", |policy| put(policy, &["codex"], "reserve", text(r#"["personal"]"#)));
        assert_eq!(account(&ready(&directory, "codex"), "personal"), "False below_margin");
    }

    #[test]
    fn a_window_past_its_end_is_reported_whole() {
        // Read before its end, which has since passed.
        let directory = state("agent-rolled");
        claude_slots(&directory, |slots| set(&slots[0], "reset5h", "2026-09-12T11:59:50.0000000+00:00".into()));
        let everyday = ready(&directory, "claude");
        assert_eq!(account(&everyday, "1"), "True eligible");
        assert_eq!(is(&everyday.g("accounts").ok().unwrap().arr()[0], &["windows"]), concat!(
            r#"{"is":[{"durationMinutes":300,"remainingPercent":100,"resetsAt":null},"#,
            r#"{"durationMinutes":10080,"remainingPercent":46,"resetsAt":"2026-09-14T16:00:00.0000000+00:00"}]}"#
        ));
        assert_eq!(is(&everyday, &["nextObservedResetAt"]), r#"{"is":"2026-09-14T16:00:00.0000000+00:00"}"#);
        codex_bucket(&directory, |bucket| {
            put(bucket, &["windows", "300"], "resetsAt", V::I32(1_789_214_390));
            put(bucket, &["windows", "300"], "observedAt", "2026-09-12T11:59:18.0000000+00:00".into());
        });
        let work = ready(&directory, "codex");
        assert_eq!(is(&work.g("accounts").ok().unwrap().arr()[0], &["windows"]), concat!(
            r#"{"is":[{"durationMinutes":10080,"remainingPercent":59,"resetsAt":"2026-09-15T12:00:00.0000000+00:00"},"#,
            r#"{"durationMinutes":300,"remainingPercent":100,"resetsAt":null}]}"#
        ));
    }

    #[test]
    fn a_hold_keeps_the_selection_and_permits_no_switch() {
        let automated = |name: &str| {
            let directory = state(name);
            changed(&directory, "policy.json", switching);
            directory
        };
        let directory = automated("agent-hold");
        let free = ready(&directory, "claude");
        assert_eq!(is(&free, &["switchingPermitted"]), r#"{"is":true}"#);
        assert_eq!(is(&free, &["selectionHeld"]), r#"{"is":false}"#);
        assert_eq!(is(&free, &["mode"]), r#"{"is":"automate"}"#);
        fs::write(directory.join("hold.json"), r#"{"until":"2026-09-12T12:30:00.0000000+00:00","reason":"fixture"}"#).unwrap();
        for provider in ["claude", "codex"] {
            let held = ready(&directory, provider);
            assert_eq!(is(&held, &["selectionHeld"]), r#"{"is":true}"#, "{provider}");
            assert_eq!(is(&held, &["switchingPermitted"]), r#"{"is":false}"#, "{provider}");
        }
        // A hold that has ended, and one whose end cannot be read, hold nothing.
        for lapsed in [r#"{"until":"2026-09-12T12:00:00.0000000+00:00"}"#, r#"{"until":"later"}"#, r#"{"until":null}"#, "{"] {
            fs::write(directory.join("hold.json"), lapsed).unwrap();
            assert_eq!(is(&ready(&directory, "claude"), &["selectionHeld"]), r#"{"is":false}"#, "{lapsed}");
            assert_eq!(is(&ready(&directory, "claude"), &["switchingPermitted"]), r#"{"is":true}"#, "{lapsed}");
            assert_eq!(is(&ready(&directory, "codex"), &["selectionHeld"]), r#"{"is":false}"#, "{lapsed}");
        }
        // With no hold file, Codex is held by the hold the snapshot recorded.
        let directory = automated("agent-hold-recorded");
        let recorded = |until: &str| changed(&directory, "status.json", |status| put(status, &["providers", "codex"], "hold", text(until)));
        recorded(r#"{"until":"2026-09-12T12:30:00.0000000+00:00"}"#);
        assert_eq!(is(&ready(&directory, "codex"), &["selectionHeld"]), r#"{"is":true}"#);
        assert_eq!(is(&ready(&directory, "claude"), &["selectionHeld"]), r#"{"is":false}"#);
        recorded(r#"{"until":"2026-09-12T11:30:00.0000000+00:00"}"#);
        assert_eq!(is(&ready(&directory, "codex"), &["selectionHeld"]), r#"{"is":false}"#);
        // A recorded hold with no end that can be read holds until it is removed.
        recorded(r#"{"until":"later"}"#);
        assert_eq!(is(&ready(&directory, "codex"), &["selectionHeld"]), r#"{"is":true}"#);
        // Codex is chosen at its next launch, and nothing is switched for it.
        assert_eq!(is(&ready(&directory, "codex"), &["switchingPermitted"]), r#"{"is":false}"#);
    }

    #[test]
    fn a_pause_is_reported_and_permits_no_switch() {
        let directory = state("agent-pause");
        changed(&directory, "policy.json", switching);
        assert_eq!(is(&ready(&directory, "claude"), &["switchingPermitted"]), r#"{"is":true}"#);
        fs::write(directory.join("automation-pause.json"), r#"{"until":"2026-09-12T15:00:00.0000000+02:00","reason":"fixture"}"#).unwrap();
        for provider in ["claude", "codex"] {
            let paused = ready(&directory, provider);
            // A time is reported as the same instant in UTC.
            assert_eq!(is(&paused, &["pause"]), r#"{"is":{"active":true,"until":"2026-09-12T13:00:00.0000000+00:00","invalid":false}}"#, "{provider}");
            assert_eq!(is(&paused, &["automationPaused"]), r#"{"is":true}"#, "{provider}");
            assert_eq!(is(&paused, &["switchingPermitted"]), r#"{"is":false}"#, "{provider}");
        }
        // A pause with no end is one, and is reported as not valid.
        fs::write(directory.join("automation-pause.json"), r#"{"until":null}"#).unwrap();
        assert_eq!(is(&ready(&directory, "claude"), &["pause"]), r#"{"is":{"active":true,"until":null,"invalid":true}}"#);
        assert_eq!(is(&ready(&directory, "claude"), &["switchingPermitted"]), r#"{"is":false}"#);
        // One whose end is not a time HotPl8 writes is not read, and nothing is reported.
        fs::write(directory.join("automation-pause.json"), r#"{"until":"later"}"#).unwrap();
        assert!(answer("readiness", &directory, "claude", "", noon()).is_err());
    }

    #[test]
    fn status_names_the_snapshot_its_age_and_every_registered_provider() {
        let directory = state("agent-status");
        let status = asked_at(&directory, "status", "", "", noon()).g("data").ok().unwrap();
        assert_eq!(is(&status, &["generatedAt"]), r#"{"is":"2026-09-12T11:59:18.0000000+00:00"}"#);
        assert_eq!(is(&status, &["ageSeconds"]), r#"{"is":42}"#);
        assert_eq!(is(&status, &["collector"]), r#"{"is":{"status":"ok","startedAt":"2026-09-12T11:59:15.0000000+00:00","completedAt":"2026-09-12T11:59:18.0000000+00:00"}}"#);
        let names: Vec<String> = status.g("providers").ok().unwrap().props().ok().unwrap().iter().map(|(name, _)| name.to_string()).collect();
        assert_eq!(names, ["claude", "codex"]);
        // Each provider's part is its readiness, and `explain` is the same answer.
        assert_eq!(is(&status, &["providers", "codex"]), is(&ready(&directory, "codex"), &[]));
        assert_eq!(is(&status, &["providers", "claude"]), is(&ready(&directory, "claude"), &[]));
        assert_eq!(asked(&directory, "explain", ""), asked(&directory, "status", ""));
        // An age is to the thousandth of a second.
        let later = asked_at(&directory, "status", "", "", Dto { ticks: noon().ticks + 12_345_678, offset_minutes: 0 });
        assert_eq!(is(&later, &["data", "ageSeconds"]), r#"{"is":43.235}"#);
        // The clock's own zone changes nothing.
        let abroad = asked_at(&directory, "status", "", "", Dto::parse("2026-09-12T14:00:00.0000000+02:00").ok().unwrap());
        assert_eq!(json::compact(&abroad, 24).ok().unwrap(), asked(&directory, "status", ""));
    }

    #[test]
    fn the_collector_reported_is_the_newer_of_the_marker_and_the_snapshots_own() {
        let directory = state("agent-collector");
        let collector = |directory: &Path| is(&asked_at(directory, "status", "", "", noon()).g("data").ok().unwrap(), &["collector"]);
        // A marker started after the snapshot was completed is the collection now running.
        fs::write(directory.join("collector.json"), r#"{"status":"collecting","startedAt":"2026-09-12T11:59:50.0000000+00:00"}"#).unwrap();
        assert_eq!(collector(&directory), r#"{"is":{"status":"collecting","startedAt":"2026-09-12T11:59:50.0000000+00:00","completedAt":null}}"#);
        // One started before it cannot override the completed snapshot.
        fs::write(directory.join("collector.json"), r#"{"status":"started","startedAt":"2026-09-12T11:59:15.0000000+00:00"}"#).unwrap();
        assert_eq!(collector(&directory), r#"{"is":{"status":"ok","startedAt":"2026-09-12T11:59:15.0000000+00:00","completedAt":"2026-09-12T11:59:18.0000000+00:00"}}"#);
        // A status HotPl8 does not write is not passed on, and a time is reported in UTC.
        fs::write(directory.join("collector.json"), r#"{"status":"fixture words","startedAt":"2026-09-12T14:59:50.0000000+03:00","completedAt":"2026-09-12T14:59:55.0000000+03:00"}"#).unwrap();
        assert_eq!(collector(&directory), r#"{"is":{"status":"unknown","startedAt":"2026-09-12T11:59:50.0000000+00:00","completedAt":"2026-09-12T11:59:55.0000000+00:00"}}"#);
    }

    #[test]
    fn an_operation_the_files_do_not_answer_is_refused() {
        let directory = state("agent-unknown");
        let refused = answer("doctor", &directory, "", "", noon()).err().unwrap();
        assert_eq!(refused.message(), "The agent interface has no operation named doctor that is answered from the files.");
    }

    #[test]
    fn window_names_are_minutes() {
        for name in ["1", "300", "10080", "999999", "60\n"] {
            assert!(window_name(name), "{name:?}");
        }
        for name in ["", "0", "0300", "1000000", "5h", " 300", "300 ", "-300", "3.5", "\n", "60\n\n", "\u{0663}\u{0660}\u{0660}"] {
            assert!(!window_name(name), "{name:?}");
        }
    }

    #[test]
    fn only_reasons_hotpl8_names_are_passed_on() {
        assert_eq!(known("below_margin"), "below_margin");
        assert_eq!(known("binding_changed"), "binding_changed");
        for other in ["", "Below_Margin", "below_margin ", "fixture-a@example.invalid is over quota"] {
            assert_eq!(known(other), "unknown", "{other:?}");
        }
    }
}

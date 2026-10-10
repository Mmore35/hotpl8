//! The Claude collection: one reading of every Claude account
//! through cswap, then at most one switch, one request that opens a window and one test of
//! a sign-in cswap has stopped testing, and what the status files say afterwards.
//!
//! The clock is read again after every program this starts, as PowerShell reads it at each
//! use: a request through cswap can take a minute and a half.

use crate::activity::add_action_event;
use crate::automation::{action_block, add_attempt, hold, pause};
use crate::claude::{claude_provider_decision, claude_selection, margin_7d_for, model_block, test_ok, Accounts};
use crate::contract::provider_account;
use crate::control::{action_authorization, control_generation, provider_action_context};
use crate::cswap;
use crate::files;
use crate::forecast::forecast;
use crate::json;
use crate::observation::claude_entry_observation;
use crate::phase;
use crate::plans;
use crate::policy;
use crate::process;
use crate::ps::*;
use crate::sha256;
use crate::time::Dto;
use crate::warming::{new_warm_outcome, save_warm_outcomes, update_warm_outcome, warm_outcomes, warm_pending};
use crate::{hash, obj};
use std::path::Path;

/// What one collection is asked to do, and where.
pub struct Request<'a> {
    pub policy: &'a V,
    pub state: &'a Path,
    /// Where the pause, the hold, the parked accounts and the action lock are kept: the
    /// state directory itself, unless this is a registered provider with a directory of
    /// its own under it.
    pub control: &'a Path,
    /// The control generation the caller read the policy under, when it read one.
    pub generation: Option<&'a str>,
    pub provider: &'a str,
    pub cswap: Option<&'a str>,
    pub observe_only: bool,
    /// The release this program belongs to: the plan helper is one of its files.
    pub root: &'a Path,
    /// The user's home directory, where cswap keeps what it stores.
    pub home: &'a Path,
    pub clock: &'a dyn Fn() -> R<Dto>,
}

/// What one collection came to.
pub struct Collected {
    /// The lines of status.txt.
    pub lines: Vec<String>,
    pub payload: V,
    /// What to print when the collection did something to an account.
    pub action: Option<String>,
}

/// The states only a person signing in again can end.
const NEEDS_HUMAN: [&str; 2] = ["relogin_required", "no_credentials"];
/// How many tests of one stored sign-in may fail before it is called dead.
const SPENT_AFTER: i32 = 2;

/// The weekly headroom below which an account's window is not opened.
/// A reserve account keeps the stricter guard, since opening its window spends what it is
/// kept for; a working account may be given a lower one.
fn warm_min_7d_for(policy: &V, slot: i32) -> R<f64> {
    let base = match policy.g("warmMin7d")? {
        V::Null => 20.0,
        set => set.dbl()?,
    };
    let reserve = policy.g("reserve")?;
    if reserve.t()? {
        let reserve = reserve.each().iter().map(V::to_int).collect::<R<Vec<i32>>>()?;
        if reserve.contains(&slot) {
            return Ok(base);
        }
    }
    match policy.g("warmMin7dWork")? {
        V::Null => Ok(base),
        set => set.dbl(),
    }
}

/// How long cswap must have left an account untested before its sign-in is tested here.
fn stale_quarantine_s(policy: &V) -> R<f64> {
    match policy.g("staleQuarantineS")? {
        V::Null => Ok(21_600.0),
        set => set.dbl(),
    }
}

/// A "needs a person" verdict that cswap itself has stopped testing.
///
/// cswap sets an account aside after one refused renewal and never reads it again; only
/// signing in again lifts that. So cswap can hold a working sign-in for an account and go
/// on reporting it dead. The age of the last good reading is the one field that says so:
/// past the limit the verdict is unchecked, which is not the same as dead.
fn quarantine_stale(account: &V, stale_s: f64) -> R<bool> {
    let last_good = account.g("lastGoodAgeSeconds")?;
    Ok(!last_good.is_null() && last_good.dbl()? > stale_s)
}

/// The weekly usage each day and the days until the limit, at the average rate
/// of this cycle. Both are doubles, or the whole number 0 when there is no rate.
fn projection(account: &V, now: Dto) -> R<Option<(V, V)>> {
    let age = account.g("usageAgeSeconds")?;
    if account.g("usageStatus")?.ne_s("ok")? || age.is_null() {
        return Ok(None);
    }
    let week = account.path(&["usage", "sevenDay"])?;
    let observed = V::from(now.plus(-age.dbl()?)?.o());
    let read = forecast(&week.g("pct")?, &week.g("resetsAt")?, &observed, 10_080, now, &[])?;
    if !read.t()? {
        return Ok(None);
    }
    let seconds = read.g("secondsToLimit")?;
    let rate = if seconds.gt_i(0)? { V::I32(100).sub(&read.g("used")?)?.mul(&V::I32(86_400))?.div(&seconds)? } else { V::I32(0) };
    Ok(Some((rate, seconds.div(&V::I32(86_400))?)))
}

/// One stored sign-in that failed its test, and how often.
struct Dead {
    mark: String,
    fails: i32,
}

/// warm-state.json: when each account was last sent a request, by kind, and which stored
/// sign-ins have failed their test. Keys are slot numbers.
#[derive(Default)]
struct Marks {
    last_warm: Vec<(String, String)>,
    last_probe: Vec<(String, String)>,
    probe_dead: Vec<(String, Dead)>,
}

fn found<'a, T>(items: &'a [(String, T)], slot: i32) -> Option<&'a T> {
    let key = slot.to_string();
    items.iter().find(|(known, _)| *known == key).map(|(_, value)| value)
}

fn put<T>(items: &mut Vec<(String, T)>, slot: i32, value: T) {
    let key = slot.to_string();
    match items.iter_mut().find(|(known, _)| *known == key) {
        Some(known) => known.1 = value,
        None => items.push((key, value)),
    }
}

impl Marks {
    /// A file that cannot be read in full is no memory at all: every account may be asked
    /// again, which the attempt budget and the one-request-a-wake rule still bound.
    fn read(path: &Path) -> Marks {
        let read = || -> R<Marks> {
            let mut marks = Marks::default();
            let Some(saved) = json::read_file(path)? else { return Ok(marks) };
            for (name, into) in [("lastWarm", &mut marks.last_warm), ("lastProbe", &mut marks.last_probe)] {
                let part = saved.g(name)?;
                if part.t()? {
                    for (slot, at) in part.props()? {
                        into.push((slot.to_string(), at.s()?));
                    }
                }
            }
            let dead = saved.g("probeDead")?;
            if dead.t()? {
                for (slot, record) in dead.props()? {
                    marks.probe_dead.push((slot.to_string(), Dead { mark: record.g("mark")?.s()?, fails: record.g("fails")?.to_int()? }));
                }
            }
            Ok(marks)
        };
        read().unwrap_or_default()
    }

    /// Best effort: the request has been made whether or not it can be
    /// written down.
    fn save(&self, path: &Path) {
        let times = |items: &[(String, String)]| new_obj(items.iter().map(|(slot, at)| (slot.as_str(), V::from(at.as_str()))).collect());
        let dead = new_obj(self.probe_dead.iter().map(|(slot, dead)| (slot.as_str(), obj! {"mark" => dead.mark.as_str(), "fails" => dead.fails})).collect());
        let _ = files::write_json(path, &obj! {"lastWarm" => times(&self.last_warm), "lastProbe" => times(&self.last_probe), "probeDead" => dead}, 4);
    }
}

/// The name one account's usage history is kept under. The same account read into another
/// state directory is another history.
fn stream_key(state: &str, identity: &str) -> String {
    sha256::hash(&format!("{state}|usage|{identity}"))
}

/// `$slots -join '+'`
fn joined(slots: &[i32]) -> String {
    slots.iter().map(i32::to_string).collect::<Vec<_>>().join("+")
}

/// One collection. Nothing is collected for a policy that prefers no Claude account.
pub fn claude_tick(request: &Request) -> R<Option<Collected>> {
    let &Request { policy, state, control, provider, home, clock, .. } = request;
    if !policy.g("prefer")?.t()? {
        return Ok(None);
    }
    let generation = match request.generation.filter(|generation| !generation.is_empty()) {
        Some(generation) => generation.to_string(),
        None => control_generation(control)?,
    };
    let mut actions = policy::actions(policy, request.observe_only)?;
    if pause(control, clock()?).t()? {
        actions.switching = false;
        actions.warming = false;
        actions.probing = false;
    }
    let Some(cswap) = cswap::resolve_executable(request.cswap) else { return fail("claude_missing") };
    let read = process::run(&cswap, &["list", "--json"], cswap::READ_TIMEOUT_MS)?;
    if read.exit_code != 0 || blank(&read.output)? {
        return fail("claude_read_failed");
    }
    let data = json::parse(&read.output, "")?;
    let schema = data.g("schemaVersion")?;
    if !schema.is_null() && schema.ne(&V::I32(1))? {
        return fail("claude_schema_unsupported");
    }
    if !data.g("accounts")?.t()? {
        return fail("claude_no_accounts");
    }
    let listed = data.g("accounts")?.each();
    let (preferred, disabled) = (policy.g("prefer")?, policy.g("disabled")?);
    let planned = filter(&listed, |account| {
        let number = account.g("number")?;
        Ok(number.is_in(&preferred)? && !number.is_in(&disabled)?)
    })?;
    let plans = plans::plans(&planned, state, clock()?, plans::helper(&cswap, request.root))?;

    let m5 = V::Dbl(policy.g("margin5h")?.dbl()?);
    let max_age = match policy.g("maxUsageAgeS")? {
        V::Null => 900.0,
        set => set.dbl()?,
    };
    let prefer = preferred.each().iter().map(V::to_int).collect::<R<Vec<i32>>>()?;

    let now = clock()?;
    let mut acc = Accounts::default();
    for a in &listed {
        // Unsupported native data stays visible as its own state rather than an empty healthy row.
        let mut valid = true;
        for window in [a.path(&["usage", "fiveHour"])?, a.path(&["usage", "sevenDay"])?] {
            if window.t()? {
                let pct = window.g("pct")?;
                if !pct.is_number() || pct.lt_i(0)? || pct.gt_i(100)? {
                    valid = false;
                }
            }
        }
        let number = a.g("number")?;
        let off = a.g("disabled")?.is_true()? || a.g("enabled")?.is_false()? || V::I32(number.to_int()?).is_in(&disabled)?;
        let age = a.g("usageAgeSeconds")?;
        if !age.is_null() && (!age.is_number() || age.lt_i(0)? || age.gt_i(604_800)?) {
            valid = false;
        }
        if off {
            a.set("usage", V::Null)?;
            a.set("usageStatus", "disabled".into())?;
        } else if !valid {
            a.set("usage", V::Null)?;
            a.set("usageStatus", "unsupported".into())?;
        }
        let usage = a.g("usage")?;
        let (five, seven) = (usage.g("fiveHour")?, usage.g("sevenDay")?);
        let h5 = if five.t()? { V::Dbl(100.0 - five.g("pct")?.dbl()?) } else { V::Null };
        let h7 = if seven.t()? { V::Dbl(100.0 - seven.g("pct")?.dbl()?) } else { V::Null };
        // Cold: no five-hour window is open, so the account is at full headroom and
        // nothing is counting down. The signal is the absent reset time, not a zero
        // percentage: a window that is open with nothing used yet also reads zero. The
        // window object must itself be there, or an account whose usage could not be read
        // would look cold and be sent a request.
        let cold = five.t()? && blank(&five.g("resetsAt")?.s()?)?;
        // Fresh only when cswap vouches for the reading. A cached "ok" snapshot can be
        // hours old; without an age it cannot be trusted, and anything that is not "ok"
        // is unusable. Fail closed.
        let fresh = a.g("usageStatus")?.eq_s("ok")? && !age.is_null() && age.dbl()? <= max_age;
        let slot = number.to_int()?;
        let entry = hash! {"n" => slot, "h5" => h5, "h7" => h7, "fresh" => fresh, "cold" => cold, "obj" => a};
        acc.put(slot, entry.clone());
        entry.set("identity", sha256::hash(&a.g("email")?.s()?).into())?;
        let last_good = a.g("lastGoodAgeSeconds")?;
        let last_good_at = if last_good.is_number() && last_good.ge_i(0)? && last_good.le_i(315_360_000)? { V::from(now.plus(-last_good.dbl()?)?.o()) } else { V::Null };
        entry.set("lastGoodAt", last_good_at)?;
        let observed_at = if valid && age.is_number() && age.ge_i(0)? { V::from(now.plus(-age.dbl()?)?.o()) } else { V::Null };
        entry.set("observedAt", observed_at.clone())?;
        let reason = model_block(&usage.g("scoped")?, policy, slot, now, &observed_at)?;
        entry.set("modelBlocked", reason.t()?.into())?;
        entry.set("modelReason", reason)?;
        let observation = claude_entry_observation(&number, &entry, policy, now, false)?;
        entry.set("observation", observation.clone())?;
        let for_warm = claude_entry_observation(&number, &entry, policy, now, true)?;
        let warm_fresh = fresh && provider_account(&for_warm, policy, &[], now)?.g("valid")?.t()?;
        entry.set("warmFresh", warm_fresh.into())?;
        let normalized = provider_account(&observation, policy, &[], now)?;
        entry.set("h5", normalized.g("shortRemaining")?)?;
        entry.set("h7", normalized.g("weeklyRemaining")?)?;
        entry.set("fresh", (fresh && normalized.g("valid")?.t()?).into())?;
    }

    let outcomes = warm_outcomes(state);
    for n in &prefer {
        let (e, key) = (acc.get(*n), format!("claude:{n}"));
        let prior = outcomes.g(&key)?;
        if e.t()? && prior.t()? {
            let was = prior.g("outcome")?;
            let reset = e.path(&["obj", "usage", "fiveHour", "resetsAt"])?;
            let updated = update_warm_outcome(&prior, &e.g("identity")?.s()?, &e.g("observedAt")?, &reset, e.g("fresh")?.t()?, now)?;
            outcomes.add_member(&key, updated.clone(), true)?;
            if updated.g("outcome")?.ne(&was)? {
                add_action_event(state, provider, &n.to_string(), "warm_outcome", &updated.g("outcome")?.s()?, now)?;
            }
        }
    }
    if !outcomes.props()?.is_empty() {
        save_warm_outcomes(state, &outcomes)?;
    }

    let order = policy.g("order")?;
    let order_mode = if order.t()? { order.s()? } else { "prefer".to_string() };
    let mut active = data.g("activeAccountNumber")?.to_int()?;
    let critical_prior = json::read_or_null(&state.join("critical-claude.json"));
    let selection = claude_selection(policy, &prefer, &acc, active, now, &critical_prior)?;
    let target = match &selection.target {
        V::Null => None,
        slot => Some(slot.to_int()?),
    };

    // A hold stops the switch and nothing else. It exists so that work in flight is not
    // moved to another account; a request through `cswap run` belongs to its own process
    // and moves no one, so windows go on being opened and sign-ins tested while held.
    let hold = hold(control, now);
    let held_switch = hold.is_some() && target.is_some_and(|target| target != active);

    // The last look before acting, taken under the
    // action lock against the generation the policy was read under. A change of control
    // state since then is a quiet no, not a failure.
    let authorized = |active: i32, intent: &str, slot: i32| -> R<bool> {
        let slot = slot.to_string();
        let decided = action_authorization(control, &generation, || {
            let now = clock()?;
            let context = obj! {
                "intent" => intent,
                "previousId" => active.to_string(),
                "bindingKnown" => active > 0,
                "criticalState" => &critical_prior,
                "actionSlot" => slot.as_str(),
                "actionEligible" => true,
            };
            let context = provider_action_context(policy, control, &context, now)?;
            claude_provider_decision(policy, &prefer, &acc, active, now, &critical_prior, Some(&context))
        });
        match decided {
            Ok(decision) => Ok(decision.g("actionPermitted")?.t()? && decision.g("targetSlot")?.sv()?.ceq_s(&slot)?),
            Err(stop) if stop.said().is_some_and(|said| ["action_state_changed", "action_control_busy", "action_state_unavailable"].contains(&said)) => Ok(false),
            Err(stop) => Err(stop),
        }
    };

    let mut switched = false;
    if let Some(target) = target.filter(|target| actions.switching && *target != active && hold.is_none()) {
        if authorized(active, "rebind", target)? {
            let moved = process::run(&cswap, &["switch", &target.to_string()], 20_000)?;
            if moved.exit_code != 0 {
                return fail("claude_switch_failed");
            }
            switched = true;
            active = target;
            add_action_event(state, provider, &target.to_string(), "switch", "native_switch_succeeded", clock()?)?;
        }
    }

    let now = clock()?;
    let critical = claude_provider_decision(policy, &prefer, &acc, active, now, &critical_prior, None)?.g("critical")?;
    critical.set("selected", active.to_string().into())?;
    let selected_at = critical_prior.g("selectedAt")?;
    critical.set("selectedAt", if switched || !selected_at.t()? { now.o().into() } else { selected_at })?;
    files::write_json(&state.join("critical-claude.json"), &critical, 6)?;
    let critical_active = critical.g("active")?.t()?;

    // An account can be lost in a way no wake can mend. Such an account reads as a hole
    // in the pool, so it is said aloud rather than left to look like "no headroom".
    let mut broken = Vec::new();
    for n in &prefer {
        let e = acc.get(*n);
        if e.t()? && e.path(&["obj", "usageStatus"])?.sv()?.in_s(&NEEDS_HUMAN)? {
            broken.push(*n);
        }
    }
    // ...but a verdict that is merely no longer tested is not yet a broken account.
    let stale_s = stale_quarantine_s(policy)?;
    let mut stuck = Vec::new();
    for n in &broken {
        if quarantine_stale(&acc.get(*n).g("obj")?, stale_s)? {
            stuck.push(*n);
        }
    }
    let mut really_broken: Vec<i32> = broken.iter().copied().filter(|n| !stuck.contains(n)).collect();
    let mut any_fresh = false;
    for n in &prefer {
        let e = acc.get(*n);
        any_fresh |= e.t()? && e.g("fresh")?.t()?;
    }
    let mut any_eligible = critical_active && !critical.g("ranked")?.each().is_empty();
    if !any_eligible {
        for n in &prefer {
            any_eligible |= test_ok(&acc.get(*n), m5.clone(), margin_7d_for(policy, &V::I32(*n))?, now)?.t()?;
        }
    }

    let (mut warmed, mut warm_failed, mut unrenewed) = (Vec::new(), Vec::new(), Vec::new());
    let mut offsets = None;
    // How long after an account's turn its request may still be sent. It must be longer
    // than the time between wakes, or a wake that falls between turns would miss one.
    let w_window = match policy.g("warmPhaseWindowMin")? {
        V::Null => 15,
        set => set.to_int()?,
    };
    let marks_path = state.join("warm-state.json");
    let mut marks = Marks::read(&marks_path);
    let stored_mark = |slot: i32| -> R<String> { Ok(cswap::credential_mark(&cswap::stored_credential(home, slot, &acc.get(slot).path(&["obj", "email"])?.s()?), true)) };

    // A stored sign-in that has failed its test twice, unchanged, is dead and not merely
    // untested: the account moves to the "sign in again" call and is no longer tested.
    // Signing in again, or cswap capturing a new sign-in, changes the mark and reopens it.
    let mut spent = Vec::new();
    for n in &stuck {
        if let Some(dead) = found(&marks.probe_dead, *n) {
            if dead.fails >= SPENT_AFTER && text_eq(&dead.mark, &stored_mark(*n)?)? {
                spent.push(*n);
            }
        }
    }
    if !spent.is_empty() {
        stuck.retain(|n| !spent.contains(n));
        really_broken.extend(&spent);
    }

    if actions.warming {
        // The least time between two requests to one account, so a request that fails
        // cannot be repeated every wake.
        let w_floor = match policy.g("warmFloorMin")? {
            V::Null => 20.0,
            set => set.dbl()?,
        };
        offsets = phase::warm_offsets(policy, &prefer)?;
        for n in &prefer {
            let (n, slot) = (*n, n.to_string());
            let e = acc.get(n);
            // Fresh cold facts, whatever admission thinks of the missing reset time; and
            // a window that is already open needs no opening.
            if !e.t()? || !e.g("warmFresh")?.t()? || !e.g("cold")?.t()? {
                continue;
            }
            // Every request spends a little of the week, so an account near its weekly
            // limit is left alone. The active account is not excluded: a request through
            // `cswap run` uses a sign-in of its own and cannot disturb the live session.
            let h7 = e.g("h7")?;
            if !h7.is_null() && h7.lt(&V::Dbl(warm_min_7d_for(policy, n)?))? {
                continue;
            }
            if let Some(last) = found(&marks.last_warm, n).filter(|last| !last.is_empty()) {
                if Dto::parse_external(last).is_ok_and(|last| now.since(last).total_minutes() < w_floor) {
                    continue;
                }
            }
            // An account waits for its turn only while another can carry the work. With
            // nothing eligible there is nothing to stagger against, so it is opened now.
            if let Some(offset) = offsets.as_ref().and_then(|offsets| offsets.of(n)) {
                if any_eligible && !phase::at_phase(offset, w_window, now) {
                    continue;
                }
            }
            if e.g("modelBlocked")?.t()? || action_block(policy, state, provider, &slot, "warm", now)?.is_some() {
                continue;
            }
            let (key, identity) = (format!("claude:{n}"), e.g("identity")?.s()?);
            if warm_pending(&outcomes.g(&key)?, &identity, now)? || !authorized(active, "warm", n)? {
                continue;
            }
            add_attempt(state, provider, &slot, now)?;
            // The record is on disk before the request leaves, so a wake that dies in
            // between cannot send a second one.
            let outcome = new_warm_outcome(provider, &slot, &identity, "fiveHour", true, now)?;
            outcome.set("outcome", "requested".into())?;
            outcomes.add_member(&key, outcome.clone(), true)?;
            save_warm_outcomes(state, &outcomes)?;
            let ping = cswap::slot_ping(&cswap, home, n, &e.path(&["obj", "email"])?.s()?, state, "warm");
            let now = clock()?;
            if ping.unrenewed {
                unrenewed.push(n);
                add_action_event(state, provider, &slot, "credential_unrenewed", "warm", now)?;
            }
            let said = if ping.ok { "sent" } else { "failed" };
            outcome.set("outcome", said.into())?;
            outcomes.add_member(&key, outcome.clone(), true)?;
            save_warm_outcomes(state, &outcomes)?;
            add_action_event(state, provider, &slot, "warm_attempt", said, now)?;
            if ping.ok {
                warmed.push(n);
            } else {
                warm_failed.push(n);
            }
            // Recorded whether it worked or not, so a failing request waits out the floor.
            put(&mut marks.last_warm, n, now.o());
            marks.save(&marks_path);
            // One account a wake: each request is a whole program that may run a minute
            // and a half, and the wake is not left running for several.
            break;
        }
    }

    // The test of a sign-in cswap has stopped testing. It is not gated on warming: a
    // policy that opens no windows still wants to know whether an account is really lost.
    // An account is tested at most once per staleness period; this must never hammer.
    let (mut probed, mut revived) = (Vec::new(), Vec::new());
    for n in stuck.clone() {
        if !actions.probing {
            break;
        }
        let (e, slot) = (acc.get(n), n.to_string());
        if !e.t()? {
            continue;
        }
        if let Some(last) = found(&marks.last_probe, n).filter(|last| !last.is_empty()) {
            if Dto::parse_external(last).is_ok_and(|last| now.since(last).total_seconds() < stale_s) {
                continue;
            }
        }
        if action_block(policy, state, provider, &slot, "probe", now)?.is_some() || !authorized(active, "probe", n)? {
            continue;
        }
        add_attempt(state, provider, &slot, now)?;
        let ping = cswap::slot_ping(&cswap, home, n, &e.path(&["obj", "email"])?.s()?, state, "probe");
        let now = clock()?;
        add_action_event(state, provider, &slot, "recovery_probe", if ping.ok { "sent" } else { "failed" }, now)?;
        probed.push(n);
        if ping.ok {
            revived.push(n);
            marks.probe_dead.retain(|(known, _)| *known != slot);
        } else {
            // Counted only against a sign-in that can be named: an unreadable one is
            // never called dead.
            let mark = stored_mark(n)?;
            if mark.contains('@') {
                let fails = match found(&marks.probe_dead, n) {
                    Some(dead) if text_eq(&dead.mark, &mark)? => dead.fails.saturating_add(1),
                    _ => 1,
                };
                put(&mut marks.probe_dead, n, Dead { mark, fails });
            }
        }
        put(&mut marks.last_probe, n, now.o());
        marks.save(&marks_path);
        break;
    }

    let now = clock()?;
    // A call for a person comes before everything else in the verdict.
    let mut calls = Vec::new();
    if !really_broken.is_empty() {
        calls.push(format!("slot {} NEEDS RE-LOGIN -> hotpl8 add -Provider claude", joined(&really_broken)));
    }
    if !stuck.is_empty() {
        let hours = V::Dbl(stale_s / 3600.0).to_int()?;
        calls.push(format!("slot {} QUARANTINE STALE (>{hours}h unchecked) -> verify with 'cswap list'; if it answers, the strike is stale, not the account", joined(&stuck)));
    }
    let mut verdict = if !calls.is_empty() {
        format!(" · {}", calls.join(" · "))
    } else if !any_fresh {
        format!(" · usage STALE (>{}m), holding", V::Dbl(max_age / 60.0).to_int()?)
    } else if !any_eligible {
        " · no headroom on any slot".to_string()
    } else {
        String::new()
    };
    if let Some(hold) = &hold {
        verdict += &format!(" · HELD by {} until {}", hold.reason, hold.until.local()?.hour_minute());
        // A switch the hold stopped is said, or the hold would hide its own cost.
        if let Some(target) = target.filter(|_| held_switch) {
            verdict += &format!(" (suppressed -> slot {target})");
        }
    }
    if switched {
        verdict += &format!(" · switched -> slot {active}");
    }
    if critical_active {
        verdict += " · low-balance rotation";
    }
    if !warmed.is_empty() {
        verdict += &format!(" · warm request sent to slot {}; window unconfirmed", joined(&warmed));
    }
    if !warm_failed.is_empty() {
        verdict += &format!(" · WARM FAILED slot {} -> check cswap run", joined(&warm_failed));
    }
    if !unrenewed.is_empty() {
        verdict += &format!(" · slot {} SIGN-IN NOT RENEWED by its ping -> may need re-login when it expires", joined(&unrenewed));
    }
    if !revived.is_empty() {
        verdict += &format!(" · probe REVIVED slot {}", joined(&revived));
    } else if !probed.is_empty() {
        verdict += &format!(" · probed slot {} (still dead)", joined(&probed));
    }

    let labels = policy.g("labels")?;
    let label = |slot: i32| -> R<String> {
        if labels.t()? {
            labels.g(&slot.to_string())?.s()
        } else {
            Ok(String::new())
        }
    };
    let named = |label: &str| if label.is_empty() { String::new() } else { format!(" ({label})") };
    let mut lines = vec![format!("cswap {}{verdict} · active slot {active}{}", now.local()?.hour_minute(), named(&label(active)?))];
    for n in &prefer {
        let n = *n;
        let e = acc.get(n);
        if !e.t()? {
            lines.push(format!("  slot {n}  not registered"));
            continue;
        }
        let a = e.g("obj")?;
        let (h5, h7) = (e.g("h5")?, e.g("h7")?);
        let five = if h5.is_null() { "5h unknown".to_string() } else { format!("5h {}%", V::Dbl(100.0).sub(&h5)?.grouped(0)?) };
        let seven = if h7.is_null() {
            "7d not reported".to_string()
        } else {
            let used = V::Dbl(100.0).sub(&h7)?.grouped(0)?;
            match projection(&a, now)? {
                Some((rate, left)) => format!("7d {used}% -> {}%/day, exhausts in ~{}d", rate.grouped(0)?, left.grouped(1)?),
                None => format!("7d {used}%"),
            }
        };
        // A status that is not "ok" is named, or the row would read as merely stale. An
        // account cswap has stopped testing is marked unchecked, not as needing a person.
        let status = a.g("usageStatus")?.s()?;
        let human = V::s_of(&status).in_s(&NEEDS_HUMAN)?;
        let flag = if human && quarantine_stale(&a, stale_s)? && !spent.contains(&n) {
            format!("  [{status} - UNCHECKED {}h, verdict may be stale]", V::Dbl(a.g("lastGoodAgeSeconds")?.dbl()? / 3600.0).to_int()?)
        } else if human {
            format!("  [{status} - re-login]")
        } else if !status.is_empty() && V::s_of(&status).ne_s("ok")? {
            format!("  [{status}]")
        } else if !e.g("fresh")?.t()? {
            format!("  [stale {}s]", a.g("usageAgeSeconds")?.to_int()?)
        } else if e.g("cold")?.t()? {
            // Why a cold account was not opened, so a stuck one can be told from one that
            // is waiting for its turn.
            let why = if !policy.g("warm")?.t()? {
                "  [cold - warming off]"
            } else if !h7.is_null() && h7.lt(&V::Dbl(warm_min_7d_for(policy, n)?))? {
                "  [cold - 7d guard]"
            } else if offsets.as_ref().and_then(|offsets| offsets.of(n)).is_some_and(|offset| !phase::at_phase(offset, w_window, now)) {
                "  [cold - held for phase]"
            } else {
                "  [cold - warming next tick]"
            };
            why.to_string()
        } else {
            String::new()
        };
        let scoped = a.path(&["usage", "scoped"])?;
        if scoped.t()? && !scoped.arr().is_empty() {
            let mut shown = Vec::new();
            for scope in scoped.each() {
                shown.push(format!("{} {}%", scope.g("name")?.s()?, scope.g("pct")?.grouped(0)?));
            }
            let note = if policy.g("claudeModels")?.t()? { format!("SCOPED CONSTRAINTS: {}", e.g("modelReason")?.s()?) } else { "SCOPED WINDOWS NOT RANKED ON".to_string() };
            lines.push(format!("  slot {n}  [{note}: {}]", shown.join(", ")));
        }
        lines.push(format!("  slot {n}{}  {five}  {seven}{flag}", named(&label(n)?)));
    }

    // The pattern in force and whether the open windows keep to it, so a drift shows.
    if actions.warming {
        let pattern = policy.g("pattern")?;
        let mut pattern = if pattern.t()? { pattern.s()? } else { "maintain".to_string() };
        if text_eq(&pattern, "clustered")? {
            let group = match policy.g("warmGroup")? {
                V::Null => 2,
                set => set.to_int()?,
            };
            pattern += &format!("(g{group})");
        }
        let mut note = String::new();
        if let Some(offsets) = &offsets {
            let mut off_by = Vec::new();
            for n in &prefer {
                let e = acc.get(*n);
                if !e.t()? {
                    continue;
                }
                // A cold account has no phase to judge yet.
                let Some(current) = phase::phase_offset_of(&e.g("obj")?)? else { continue };
                let mut distance = (current - offsets.of(*n).unwrap_or(0)).abs();
                if distance > phase::CYCLE_MINUTES / 2 {
                    distance = phase::CYCLE_MINUTES - distance;
                }
                // Ten minutes is the grid the turns are laid on.
                if distance > 10 {
                    off_by.push(*n);
                }
            }
            note = if off_by.is_empty() { " · in phase".to_string() } else { format!(" · slot {} off-phase", joined(&off_by)) };
        }
        lines.push(format!("  pattern {pattern} · order {order_mode}{note}"));
    }

    // What the dashboard and `hotpl8 status` read. Every string in it is data to them.
    let Some(state_text) = state.to_str() else { return unreadable() };
    let mut slots = Vec::new();
    for n in &prefer {
        let n = *n;
        let e = acc.get(n);
        if !e.t()? {
            slots.push(obj! {"slot" => n, "registered" => false});
            continue;
        }
        let a = e.g("obj")?;
        let usage = a.g("usage")?;
        let (five, seven) = if usage.t()? { (usage.g("fiveHour")?, usage.g("sevenDay")?) } else { (V::Null, V::Null) };
        let used = |window: &V| -> R<V> {
            let pct = window.g("pct")?;
            Ok(if window.t()? && !pct.is_null() { V::Dbl(pct.dbl()?) } else { V::Null })
        };
        let reset = |window: &V| -> R<String> {
            if window.t()? {
                window.g("resetsAt")?.s()
            } else {
                Ok(String::new())
            }
        };
        let outcome = outcomes.g(&format!("claude:{n}"))?;
        let warm_outcome = if outcome.is_null() {
            V::Null
        } else {
            let mut shown = Vec::new();
            for name in ["schemaVersion", "id", "provider", "slot", "meter", "sentAt", "expiresAt", "outcome", "observedAt", "resetAt"] {
                shown.push((name, outcome.g(name)?));
            }
            new_obj(shown)
        };
        slots.push(obj! {
            "slot" => n,
            "label" => label(n)?,
            "registered" => true,
            "plan" => plans.g(&n.to_string())?,
            "active" => n == active,
            "cold" => e.g("cold")?.t()?,
            "fresh" => e.g("fresh")?.t()?,
            "observedAt" => e.g("observedAt")?,
            "lastGoodAt" => e.g("lastGoodAt")?,
            "streamKey" => stream_key(state_text, &e.g("identity")?.s()?),
            "scoped" => usage.g("scoped")?.arr(),
            "warmOutcome" => warm_outcome,
            "actionBlock" => action_block(policy, state, provider, &n.to_string(), "warm", now)?.map(V::from),
            "modelBlock" => e.g("modelReason")?,
            "status" => a.g("usageStatus")?.s()?,
            "used5h" => used(&five)?,
            "reset5h" => reset(&five)?,
            "used7d" => used(&seven)?,
            "reset7d" => reset(&seven)?,
        });
    }
    let said = verdict.trim_matches([' ', '·']);
    let proposed = target.map_or(V::Null, V::I32);

    let mut reasons = Vec::new();
    for n in &prefer {
        let e = acc.get(*n);
        let reason: V = if !e.t()? {
            "not_observed".into()
        } else if !e.g("fresh")?.t()? {
            "stale_or_unavailable".into()
        } else if e.g("modelBlocked")?.t()? {
            e.g("modelReason")?
        } else if critical_active && V::from(n.to_string()).is_in(&critical.g("ranked")?)? {
            "eligible_critical".into()
        } else if !test_ok(&e, m5.clone(), margin_7d_for(policy, &V::I32(*n))?, now)?.t()? {
            "below_margin_or_unknown".into()
        } else if V::I32(*n).is_in(&policy.g("reserve")?)? {
            "eligible_reserve".into()
        } else {
            "eligible_work".into()
        };
        let rank = selection.ranked.iter().position(|ranked| ranked == n).map_or(0, |index| index as i32 + 1);
        reasons.push(obj! {"slot" => *n, "rank" => rank, "reason" => reason});
    }

    // Parked accounts cswap can still read, so the dashboard can offer them back.
    let mut parked = Vec::new();
    for record in json::read_or_null(&control.join("parked.json")).g("accounts")?.each() {
        if !record.t()? || !record.g("provider")?.ceq_s(provider)? {
            continue;
        }
        let slot = record.g("slot")?.s()?;
        if !plans::numbered(&slot) {
            continue;
        }
        let rows = filter(&listed, |account| text_eq(&account.g("number")?.s()?, &slot))?;
        if rows.len() == 1 && rows[0].g("usageStatus")?.eq_s("ok")? && !prefer.contains(&record.g("slot")?.to_int()?) {
            parked.push(obj! {"slot" => slot, "label" => record.g("label")?.s()?});
        }
    }

    let why = if hold.is_some() {
        "switch held"
    } else if !actions.switching {
        "switching disabled"
    } else if switched {
        "switched to higher ranked eligible account"
    } else {
        "retained current account"
    };
    let payload = obj! {
        "generatedAt" => now.local()?.o(),
        "active" => active,
        "verdict" => said,
        "hold" => hold.as_ref().map(|hold| obj! {"until" => hold.until.o(), "reason" => hold.reason.as_str()}),
        "slots" => slots,
        "proposedSlot" => &proposed,
        "actions" => obj! {"switching" => actions.switching, "warming" => actions.warming, "probing" => actions.probing, "continuing" => actions.continuing},
        "critical" => &critical,
        "parkedReadable" => parked,
        "decision" => obj! {"policy" => order_mode.as_str(), "selected" => active, "proposed" => &proposed, "reason" => why, "accounts" => reasons},
    };
    let acted = switched || !warmed.is_empty() || !warm_failed.is_empty() || !unrenewed.is_empty();
    let action = if acted { Some(format!("{}  {said}", now.local()?.hour_minute_second())) } else { None };
    Ok(Some(Collected { lines, payload, action }))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::files::tests::scratch;
    use std::cell::Cell;
    use std::path::PathBuf;

    /// Noon UTC, on a machine that keeps it as seven in the morning.
    pub(crate) const NOON: &str = "2026-10-06T12:00:00.0000000+00:00";

    /// A cswap that answers `list` from a file beside it, writes every other request down
    /// and fails the kind a marker file names; a state directory; and a home no one has.
    pub(crate) struct Lab {
        pub(crate) directory: PathBuf,
        pub(crate) state: PathBuf,
        pub(crate) home: PathBuf,
        pub(crate) stub: String,
        /// Seconds past noon.
        pub(crate) later: Cell<i64>,
        generation: Cell<Option<&'static str>>,
    }

    impl Lab {
        pub(crate) fn new(name: &str) -> Lab {
            let directory = scratch(name);
            let (state, home) = (directory.join("state"), directory.join("home"));
            std::fs::create_dir_all(&state).unwrap();
            std::fs::create_dir_all(&home).unwrap();
            let stub = if cfg!(windows) {
                let path = directory.join("cswap-stub.cmd");
                std::fs::write(&path, "@echo off\r\nif \"%1\"==\"list\" (type \"%~dp0fixture.json\" & exit /b 0)\r\n>>\"%~dp0calls\" echo %*\r\nif exist \"%~dp0fail-%1\" exit /b 1\r\nexit /b 0\r\n").unwrap();
                path
            } else {
                let path = directory.join("cswap-stub");
                std::fs::write(&path, "#!/bin/sh\nhere=\"$(dirname \"$0\")\"\nif [ \"$1\" = list ]; then cat \"$here/fixture.json\"; exit 0; fi\necho \"$*\" >> \"$here/calls\"\nif [ -e \"$here/fail-$1\" ]; then exit 1; fi\nexit 0\n").unwrap();
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
                }
                path
            };
            crate::time::set_zone(Some(-300));
            Lab { directory, state, home, stub: stub.to_string_lossy().into_owned(), later: Cell::new(0), generation: Cell::new(None) }
        }
        /// What cswap lists from now on.
        pub(crate) fn list(&self, text: &str) {
            std::fs::write(self.directory.join("fixture.json"), text).unwrap();
        }
        /// Whether cswap refuses requests of this kind from now on.
        fn fail(&self, kind: &str, fails: bool) {
            let marker = self.directory.join(format!("fail-{kind}"));
            if fails {
                std::fs::write(marker, "").unwrap();
            } else {
                std::fs::remove_file(marker).unwrap();
            }
        }
        /// Every request other than `list`, oldest first.
        fn calls(&self) -> Vec<String> {
            std::fs::read_to_string(self.directory.join("calls")).unwrap_or_default().lines().map(|line| line.trim().to_string()).collect()
        }
        fn tick_in(&self, state: &Path, policy: &V, observe_only: bool) -> R<Option<Collected>> {
            self.tick_as("claude", state, state, policy, observe_only)
        }
        /// A collection for a provider by its registered name, whose state may be a
        /// directory of its own under the one that holds the controls.
        fn tick_as(&self, provider: &str, state: &Path, control: &Path, policy: &V, observe_only: bool) -> R<Option<Collected>> {
            std::fs::create_dir_all(state).unwrap();
            let clock = || Dto::parse(NOON)?.plus_seconds(self.later.get());
            claude_tick(&Request { policy, state, control, generation: self.generation.get(), provider, cswap: Some(&self.stub), observe_only, root: &self.directory, home: &self.home, clock: &clock })
        }
        pub(crate) fn done(self) {
            crate::time::set_zone(None);
            set_core(false);
            std::fs::remove_dir_all(&self.directory).unwrap();
        }
    }

    fn policy(text: &str) -> V {
        json::parse(text, "").ok().unwrap()
    }
    /// The text with its one `old` made `new`.
    fn with(text: &str, old: &str, new: &str) -> String {
        assert_eq!(text.matches(old).count(), 1, "{old}");
        text.replace(old, new)
    }
    /// One member of a value, by a dotted path in which a number is a place in a list.
    fn dig(value: &V, path: &str) -> V {
        path.split('.').fold(value.clone(), |value, name| match name.parse::<usize>() {
            Ok(index) if value.is_arr() => value.each().get(index).cloned().unwrap_or(V::Null),
            _ => value.g(name).ok().unwrap(),
        })
    }
    /// That member as JSON on one line.
    fn text(value: &V, path: &str) -> String {
        json::write(&dig(value, path), 24).ok().unwrap().lines().map(str::trim).collect()
    }
    /// That member as PowerShell joins it into a string.
    fn said(value: &V, path: &str) -> String {
        match dig(value, path) {
            V::Null => String::new(),
            V::Bool(held) => if held { "True" } else { "False" }.to_string(),
            other => other.s().ok().unwrap(),
        }
    }
    fn truthy(value: &V, path: &str) -> bool {
        dig(value, path).t().ok().unwrap()
    }
    fn names(value: &V) -> Vec<String> {
        value.props().ok().unwrap_or_default().iter().map(|(name, _)| name.to_string()).collect()
    }
    fn kept(directory: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(directory).unwrap().map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        names
    }

    /// Five accounts: one with a scoped window, one cold, one cswap has stopped testing,
    /// one whose reading is old, and one the policy does not prefer. Times as cswap
    /// spells them.
    const LISTED: &str = r#"{"schemaVersion":1,"activeAccountNumber":2,"accounts":[
 {"number":1,"email":"one@example.invalid","organizationUuid":"org-1","usageStatus":"ok","usageAgeSeconds":12.5,"lastGoodAgeSeconds":12.5,
  "usage":{"fiveHour":{"pct":41.5,"resetsAt":"2026-10-06T14:00:00+00:00"},"sevenDay":{"pct":62.5,"resetsAt":"2026-10-09T10:00:00+00:00"},"scoped":[{"name":"Opus","pct":97.4,"resetsAt":"2026-10-09T10:00:00+00:00"}]}},
 {"number":2,"email":"two@example.invalid","organizationUuid":"org-2","usageStatus":"ok","usageAgeSeconds":30,"lastGoodAgeSeconds":30,
  "usage":{"fiveHour":{"pct":0,"resetsAt":""},"sevenDay":{"pct":10,"resetsAt":"2026-10-10T16:00:00+00:00"}}},
 {"number":3,"email":"three@example.invalid","organizationUuid":"org-3","usageStatus":"relogin_required","usageAgeSeconds":null,"lastGoodAgeSeconds":90000,"usage":null},
 {"number":5,"email":"five@example.invalid","organizationUuid":"org-5","usageStatus":"ok","usageAgeSeconds":2000,"lastGoodAgeSeconds":2000,
  "usage":{"fiveHour":{"pct":99.5,"resetsAt":"2026-10-06T13:00:00+00:00"},"sevenDay":{"pct":2.5,"resetsAt":"2026-10-07T18:00:00+00:00"}}},
 {"number":7,"email":"seven@example.invalid","organizationUuid":"org-7","usageStatus":"ok","usageAgeSeconds":5,"lastGoodAgeSeconds":5,
  "usage":{"fiveHour":{"pct":12,"resetsAt":"2026-10-06T15:00:00+00:00"},"sevenDay":{"pct":33,"resetsAt":"2026-10-10T06:00:00+00:00"}}}
]}"#;
    const LEGACY: &str = r#"{"prefer":[1,2,3,4,5],"reserve":[5],"disabled":[],"margin5h":25,"margin7d":20,"hysteresis":10,"warm":false,"switchEnabled":false,"probeEnabled":false,"labels":{"1":"One","2":"Two"}}"#;
    const MODELS: &str = r#"{"prefer":[2,1],"reserve":[],"margin5h":25,"margin7d":20,"hysteresis":10,"warm":false,"switchEnabled":false,"probeEnabled":false,"claudeModels":["Opus"],"order":"balanced","pattern":"clustered"}"#;

    /// The lines the PowerShell collector gave for the same accounts, policy, hold and parked
    /// record under Windows PowerShell, the clock and the hold's end apart. PowerShell 7
    /// rounds the two weekly figures that end in a half the other way.
    const LEGACY_LINES: [&str; 7] = [
        "cswap 07:00 · slot 3 QUARANTINE STALE (>6h unchecked) -> verify with 'cswap list'; if it answers, the strike is stale, not the account · HELD by probe until 08:00 (suppressed -> slot 1) · active slot 2 (Two)",
        "  slot 1  [SCOPED WINDOWS NOT RANKED ON: Opus 97%]",
        "  slot 1 (One)  5h 42%  7d 63% -> 15%/day, exhausts in ~2.4d",
        "  slot 2 (Two)  5h 0%  7d 10% -> 4%/day, exhausts in ~25.5d  [cold - warming off]",
        "  slot 3  5h unknown  7d not reported  [relogin_required - UNCHECKED 25h, verdict may be stale]",
        "  slot 4  not registered",
        "  slot 5  5h 100%  7d 3%  [stale 2000s]",
    ];
    const MODELS_LINES: [&str; 4] = [
        "cswap 07:00 · usage STALE (>15m), holding · HELD by probe until 08:00 · active slot 2",
        "  slot 2  5h 0%  7d 10% -> 4%/day, exhausts in ~25.5d  [stale 30s]",
        "  slot 1  [SCOPED CONSTRAINTS: model_below_margin: Opus 97%]",
        "  slot 1  5h 42%  7d 63% -> 15%/day, exhausts in ~2.4d  [stale 12s]",
    ];

    #[test]
    fn the_lines_and_the_payload_are_what_powershell_gave() {
        for core in [false, true] {
            let lab = Lab::new("tick-said");
            set_core(core);
            lab.list(LISTED);
            std::fs::write(lab.state.join("parked.json"), r#"{"schemaVersion":1,"accounts":[{"provider":"claude","slot":"7","label":"Parked seven"},{"provider":"codex","slot":"1"}]}"#).unwrap();
            std::fs::write(lab.state.join("hold.json"), r#"{"until":"2026-10-06T13:00:00+00:00","reason":"probe"}"#).unwrap();
            let week = |line: &str| if core { line.replace("7d 63%", "7d 62%").replace("7d 3%", "7d 2%") } else { line.to_string() };

            let seen = lab.tick_in(&lab.state, &policy(LEGACY), false).ok().unwrap().unwrap();
            assert_eq!(seen.lines, LEGACY_LINES.map(week));
            assert!(seen.action.is_none());
            let p = &seen.payload;
            assert_eq!(names(p), ["generatedAt", "active", "verdict", "hold", "slots", "proposedSlot", "actions", "critical", "parkedReadable", "decision"]);
            assert_eq!(said(p, "generatedAt"), "2026-10-06T07:00:00.0000000-05:00");
            assert_eq!(said(p, "verdict"), "slot 3 QUARANTINE STALE (>6h unchecked) -> verify with 'cswap list'; if it answers, the strike is stale, not the account · HELD by probe until 08:00 (suppressed -> slot 1)");
            assert_eq!(text(p, "hold"), r#"{"until": "2026-10-06T13:00:00.0000000+00:00","reason": "probe"}"#);
            assert_eq!((text(p, "active"), text(p, "proposedSlot")), ("2".into(), "1".into()));
            assert_eq!(text(p, "actions"), r#"{"switching": false,"warming": false,"probing": false,"continuing": true}"#);
            // The floor is a fraction under both; only PowerShell 7 writes it as one.
            assert_eq!(
                text(p, "critical"),
                r#"{"active": false,"selected": "2","selectedAt": "2026-10-06T12:00:00.0000000+00:00","reason": "normal policy","basis": "normal policy","coverage": "2/4","pollSeconds": 300,"ranked": [],"floorPercent": 1}"#.replace("1}", if core { "1.0}" } else { "1}" })
            );
            assert_eq!(text(p, "parkedReadable"), r#"[{"slot": "7","label": "Parked seven"}]"#);
            assert_eq!(
                text(p, "decision"),
                r#"{"policy": "prefer","selected": 2,"proposed": 1,"reason": "switch held","accounts": [{"slot": 1,"rank": 1,"reason": "eligible_work"},{"slot": 2,"rank": 2,"reason": "eligible_work"},{"slot": 3,"rank": 3,"reason": "stale_or_unavailable"},{"slot": 4,"rank": 4,"reason": "not_observed"},{"slot": 5,"rank": 5,"reason": "stale_or_unavailable"}]}"#
            );
            assert_eq!(
                names(&dig(p, "slots.0")),
                ["slot", "label", "registered", "plan", "active", "cold", "fresh", "observedAt", "lastGoodAt", "streamKey", "scoped", "warmOutcome", "actionBlock", "modelBlock", "status", "used5h", "reset5h", "used7d", "reset7d"]
            );
            let slot = |place: usize, members: &[&str]| members.iter().map(|member| text(p, &format!("slots.{place}.{member}"))).collect::<Vec<_>>().join(" ");
            assert_eq!(slot(0, &["slot", "label", "registered", "active", "cold", "fresh"]), r#"1 "One" true false false true"#);
            assert_eq!(slot(0, &["observedAt", "lastGoodAt"]), r#""2026-10-06T11:59:47.5000000+00:00" "2026-10-06T11:59:47.5000000+00:00""#);
            assert_eq!(said(p, "slots.0.streamKey"), stream_key(lab.state.to_str().unwrap(), &sha256::hash("one@example.invalid")));
            assert_eq!(slot(0, &["scoped"]), r#"[{"name": "Opus","pct": 97.4,"resetsAt": "2026-10-09T10:00:00+00:00"}]"#);
            assert_eq!(slot(0, &["warmOutcome", "actionBlock", "modelBlock", "status"]), r#"null null null "ok""#);
            assert_eq!(slot(0, &["used5h", "reset5h", "used7d", "reset7d"]), r#"41.5 "2026-10-06T14:00:00+00:00" 62.5 "2026-10-09T10:00:00+00:00""#);
            assert_eq!(slot(1, &["label", "active", "cold", "fresh", "observedAt", "scoped"]), r#""Two" true true true "2026-10-06T11:59:30.0000000+00:00" [null]"#);
            // What is used is a fraction, and PowerShell 7 writes a whole one as a fraction.
            let used = if core { r#"0.0 "" 10.0 "2026-10-10T16:00:00+00:00""# } else { r#"0 "" 10 "2026-10-10T16:00:00+00:00""# };
            assert_eq!(slot(1, &["used5h", "reset5h", "used7d", "reset7d"]), used);
            assert_eq!(slot(2, &["label", "fresh", "observedAt", "lastGoodAt", "scoped", "status"]), r#""" false null "2026-10-05T11:00:00.0000000+00:00" [null] "relogin_required""#);
            assert_eq!(slot(2, &["used5h", "reset5h", "used7d", "reset7d"]), r#"null "" null """#);
            assert_eq!(names(&dig(p, "slots.2.plan")), ["status", "identityKey", "profile", "label", "sessionMultiplier", "source", "observedAt", "nextAttemptAt"]);
            assert_eq!(slot(2, &["plan.status", "plan.profile", "plan.source"]), r#""unavailable" null "anthropic-oauth-profile""#);
            assert_eq!(text(p, "slots.3"), r#"{"slot": 4,"registered": false}"#);
            assert_eq!(slot(4, &["fresh", "used5h", "used7d"]), "false 99.5 2.5");

            let seen = lab.tick_in(&lab.state, &policy(MODELS), true).ok().unwrap().unwrap();
            assert_eq!(seen.lines, MODELS_LINES.map(week));
            assert!(seen.action.is_none());
            let p = &seen.payload;
            assert_eq!(said(p, "verdict"), "usage STALE (>15m), holding · HELD by probe until 08:00");
            assert_eq!((said(p, "slots.0.modelBlock"), said(p, "slots.1.modelBlock")), ("model_quota_unknown".into(), "model_below_margin".into()));
            assert_eq!((text(p, "slots.0.fresh"), text(p, "slots.1.fresh"), text(p, "proposedSlot")), ("false".into(), "false".into(), "null".into()));
            assert_eq!(text(p, "actions"), r#"{"switching": false,"warming": false,"probing": false,"continuing": false}"#);
            // The account chosen is the one it was, since the time it was first seen.
            assert_eq!((said(p, "critical.coverage"), said(p, "critical.selectedAt")), ("0/2".into(), NOON.into()));
            assert_eq!(
                text(p, "decision"),
                r#"{"policy": "balanced","selected": 2,"proposed": null,"reason": "switch held","accounts": [{"slot": 2,"rank": 1,"reason": "stale_or_unavailable"},{"slot": 1,"rank": 2,"reason": "stale_or_unavailable"}]}"#
            );

            // A policy that prefers no Claude account collects nothing.
            assert!(lab.tick_in(&lab.state, &policy(r#"{"prefer":[],"margin5h":25}"#), false).ok().unwrap().is_none());
            // No request was made, and nothing is kept that a quiet wake has no use for.
            assert!(lab.calls().is_empty());
            assert_eq!(kept(&lab.state), ["claude-plans.json", "critical-claude.json", "hold.json", "parked.json"]);
            lab.done();
        }
    }

    #[test]
    fn a_usage_history_keeps_its_name() {
        // What PowerShell gives for the same two texts.
        assert_eq!(stream_key("C:\\state", &sha256::hash("one@example.invalid")), "02314563c95b025b4cbfd9f0672f3a6126e8e3155e816e7f4371abee124b442b");
    }

    const HOUR: &str = r#""resetsAt":"2026-10-06T13:00:00.0000000+00:00""#;
    const DAY: &str = r#""resetsAt":"2026-10-07T12:00:00.0000000+00:00"}"#;
    const AGE: &str = r#""usageAgeSeconds":0"#;
    /// The active account, nearly spent for these five hours.
    const ONE: &str = r#"{"number":1,"email":"one@example.invalid","usageStatus":"ok","usageAgeSeconds":0,"usage":{"fiveHour":{"pct":90,"resetsAt":"2026-10-06T13:00:00.0000000+00:00"},"sevenDay":{"pct":20,"resetsAt":"2026-10-07T12:00:00.0000000+00:00"}}}"#;
    /// The account the policy prefers, with nearly everything left.
    const TWO: &str = r#"{"number":2,"email":"two@example.invalid","usageStatus":"ok","usageAgeSeconds":0,"usage":{"fiveHour":{"pct":10,"resetsAt":"2026-10-06T13:00:00.0000000+00:00"},"sevenDay":{"pct":20,"resetsAt":"2026-10-07T12:00:00.0000000+00:00"}}}"#;
    /// The preferred account as cswap lists it once it has stopped testing its sign-in.
    const TWO_DEAD: &str = r#"{"number":2,"email":"two@example.invalid","usageStatus":"relogin_required","usageAgeSeconds":0,"lastGoodAgeSeconds":90000,"usage":null}"#;
    const WATCH: &str = r#"{"prefer":[2,1],"reserve":[],"mode":"monitor","warm":true,"probeEnabled":true,"switchEnabled":true,"order":"prefer","margin5h":25,"margin7d":20,"hysteresis":10,"labels":{"1":"Reserve","2":"Work"}}"#;
    const WARM: &str = r#"{"prefer":[2,1],"reserve":[],"mode":"automate","warm":true,"probeEnabled":false,"switchEnabled":false,"order":"prefer","margin5h":25,"margin7d":20,"hysteresis":10,"labels":{"1":"Reserve","2":"Work"}}"#;
    const PROBE: &str = r#"{"prefer":[2,1],"reserve":[],"mode":"automate","warm":false,"probeEnabled":true,"switchEnabled":false,"order":"prefer","margin5h":25,"margin7d":20,"hysteresis":10,"labels":{"1":"Reserve","2":"Work"}}"#;
    /// Two sign-ins no account has, as cswap stores them.
    const STORED: &str = "eyJjbGF1ZGVBaU9hdXRoIjp7InJlZnJlc2hUb2tlbiI6ImZpY3Rpb25hbC1yZWZyZXNoLXRva2VuIiwiZXhwaXJlc0F0IjoxNzkxMjg4MDAwMDAwfX0=";
    const STORED_AGAIN: &str = "eyJjbGF1ZGVBaU9hdXRoIjp7InJlZnJlc2hUb2tlbiI6ImZpY3Rpb25hbC1zZWNvbmQtdG9rZW4iLCJleHBpcmVzQXQiOjE3OTEyODgwMDAwMDB9fQ==";

    fn pool(active: i32, first: &str, second: &str) -> String {
        format!(r#"{{"schemaVersion":1,"activeAccountNumber":{active},"accounts":[{first},{second}]}}"#)
    }
    fn cold(account: &str) -> String {
        with(account, HOUR, r#""resetsAt":"""#)
    }
    /// The preferred account with a window of its own for the model the policy names.
    fn scoped(pct: i32, reset: &str) -> String {
        with(TWO, DAY, &format!(r#"{DAY},"scoped":[{{"name":"seven_day_opus","pct":{pct},"resetsAt":"{reset}"}}]"#))
    }
    /// Three accounts with so much of the five hours left, read a second ago unless stale.
    fn three(active: i32, left: [f64; 3], stale: i32) -> String {
        let accounts: Vec<String> = (1..=3)
            .map(|id| {
                let (age, used) = (if id == stale { 1000 } else { 1 }, 100.0 - left[id as usize - 1]);
                format!(r#"{{"number":{id},"email":"fixture{id}@example.invalid","usageStatus":"ok","usageAgeSeconds":{age},"usage":{{"fiveHour":{{"pct":{used},"resetsAt":"2026-10-06T13:00:00.0000000+00:00"}},"sevenDay":{{"pct":30,"resetsAt":"2026-10-09T12:00:00.0000000+00:00"}}}}}}"#)
            })
            .collect();
        format!(r#"{{"schemaVersion":1,"activeAccountNumber":{active},"accounts":[{}]}}"#, accounts.join(","))
    }

    /// What is said of a run of collections: each one's lines, action, the parts of the
    /// payload the cases turn on, and every request made of cswap so far.
    struct Told<'a> {
        lab: &'a Lab,
        text: String,
    }

    impl Told<'_> {
        fn say(&mut self, line: &str) {
            self.text += line;
            self.text.push('\n');
        }
        fn shown(&mut self, name: &str, policy: &V, state: &Path, observe_only: bool) {
            self.say(&format!("=== {name}"));
            let seen = match self.lab.tick_in(state, policy, observe_only) {
                Ok(Some(seen)) => seen,
                Ok(None) => return self.say("null"),
                Err(stop) => return self.say(&format!("THROWN {}", stop.said().unwrap_or("(unreadable answer)"))),
            };
            for line in &seen.lines {
                self.say(&format!("L {line}"));
            }
            // The text has every clock reading made the minute the run began in.
            match &seen.action {
                Some(action) => {
                    assert!(action.starts_with("07:00:0"), "{action}");
                    self.say(&format!("A 07:00:00{}", &action[8..]));
                }
                None => self.say("A null"),
            }
            let p = &seen.payload;
            let does: Vec<&str> = ["switching", "warming", "probing", "continuing"].into_iter().filter(|kind| truthy(p, &format!("actions.{kind}"))).collect();
            let accounts: Vec<String> = dig(p, "decision.accounts").each().iter().map(|account| format!("{}:{}", said(account, "slot"), said(account, "reason"))).collect();
            self.say(&format!(
                "P active={} proposed={} reason={} does={} status0={} model0={} warm0={} active0={} critical={} selected={} coverage={} hold={} accounts={}",
                said(p, "active"),
                said(p, "proposedSlot"),
                said(p, "decision.reason"),
                does.join(","),
                said(p, "slots.0.status"),
                said(p, "slots.0.modelBlock"),
                said(p, "slots.0.warmOutcome.outcome"),
                said(p, "slots.0.active"),
                said(p, "critical.active"),
                said(p, "critical.selected"),
                said(p, "critical.coverage"),
                said(p, "hold.reason"),
                accounts.join(",")
            ));
            let (pings, others): (Vec<String>, Vec<String>) = self.lab.calls().into_iter().partition(|call| call.starts_with("run "));
            self.say(&format!("K {} pings={}", others.join("|"), pings.len()));
        }
        /// What a collection left in one of its records.
        fn recorded(&mut self, state: &Path, file: &str) {
            let path = state.join(file);
            if !path.exists() {
                return self.say(&format!("R {file} absent"));
            }
            let read = json::read_or_null(&path);
            let members = |name: &str| names(&dig(&read, name)).join(",");
            let told = match file {
                "activity.json" => dig(&read, "events").each().iter().map(|event| ["provider", "slot", "kind", "reason"].map(|member| said(event, member)).join(":")).collect::<Vec<_>>().join(","),
                "warm-state.json" => {
                    let dead: Vec<String> = dig(&read, "probeDead").props().ok().unwrap_or_default().iter().map(|(slot, dead)| format!("{slot}:{}", said(dead, "fails"))).collect();
                    format!("lastWarm={} lastProbe={} probeDead={}", members("lastWarm"), members("lastProbe"), dead.join(","))
                }
                _ => read
                    .props()
                    .ok()
                    .unwrap()
                    .iter()
                    .map(|(key, outcome)| {
                        let held = |member: &str| if truthy(outcome, member) { "True" } else { "False" };
                        format!("{key}={}:{}:{}:{}:{}:{}", said(outcome, "provider"), said(outcome, "slot"), said(outcome, "meter"), said(outcome, "outcome"), held("observedAt"), held("resetAt"))
                    })
                    .collect::<Vec<_>>()
                    .join(","),
            };
            self.say(&format!("R {file} {told}"));
        }
    }

    /// The PowerShell collector was taken through these collections, one after another on the
    /// same records, under Windows PowerShell and PowerShell 7 before it was removed; both
    /// said the same, and that is the text beside this file, with its clock made this one's.
    /// There a request that opens a window or tests a sign-in was a function that counted
    /// its calls and the stored sign-in was a mark it was handed; here the request is the
    /// one cswap is sent and the sign-in is a file in a home no one has. There the clock
    /// ran on from the moment the accounts' times were reckoned from; here it stands five
    /// seconds past it.
    #[test]
    fn a_run_of_collections_says_what_powershell_said() {
        let lab = Lab::new("tick-run");
        let mut told = Told { lab: &lab, text: String::new() };
        lab.later.set(5);
        let at = |name: &str| lab.directory.join(name);
        let state = lab.state.clone();
        let acting = with(WATCH, r#""monitor""#, r#""automate""#);
        let (watch, act, warm, probe) = (policy(WATCH), policy(&acting), policy(WARM), policy(PROBE));
        let (tomorrow, yesterday) = ("2026-10-07T12:00:00.0000000+00:00", "2026-10-05T12:00:00.0000000+00:00");
        let store = |text: Option<&str>| {
            let path = cswap::stored_credential(&lab.home, 2, "two@example.invalid");
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            match text {
                Some(text) => std::fs::write(path, text).unwrap(),
                None => std::fs::remove_file(path).unwrap(),
            }
        };

        told.say("##### switch");
        lab.list(&pool(1, ONE, TWO));
        told.shown("monitor", &watch, &state, false);
        told.shown("observe", &act, &state, true);
        std::fs::write(state.join("hold.json"), r#"{"until":"2026-10-06T12:05:00Z","reason":"fixture"}"#).unwrap();
        told.shown("held", &act, &state, false);
        std::fs::remove_file(state.join("hold.json")).unwrap();
        lab.generation.set(Some("another generation"));
        told.shown("stale generation", &act, &state, false);
        lab.generation.set(None);
        told.recorded(&state, "activity.json");
        told.shown("switch", &act, &state, false);
        told.recorded(&state, "activity.json");
        lab.fail("switch", true);
        told.shown("switch refused", &act, &state, false);
        lab.fail("switch", false);

        told.say("##### refused");
        std::fs::remove_file(at("fixture.json")).unwrap();
        told.shown("no answer", &act, &at("refused"), false);
        lab.list(r#"{"schemaVersion":2,"activeAccountNumber":1,"accounts":[]}"#);
        told.shown("schema", &act, &at("refused"), false);
        lab.list(r#"{"schemaVersion":1,"activeAccountNumber":1,"accounts":[]}"#);
        told.shown("no accounts", &act, &at("refused"), false);
        lab.list("cswap: something went wrong");
        told.shown("not json", &act, &at("refused"), false);

        told.say("##### untrusted");
        let untrusted = at("untrusted");
        for second in [
            with(TWO, r#""number":2,"#, r#""number":2,"disabled":true,"#),
            with(TWO, AGE, r#""usageAgeSeconds":-1"#),
            with(TWO, AGE, r#""usageAgeSeconds":"not-a-number""#),
            with(TWO, AGE, r#""usageAgeSeconds":1e100"#),
            with(TWO, r#""pct":10,"#, r#""pct":-10,"#),
        ] {
            lab.list(&pool(1, ONE, &second));
            told.shown("mutation", &act, &untrusted, true);
        }
        lab.list(&pool(1, ONE, TWO));
        told.shown("policy disabled", &policy(&with(&acting, r#""reserve":[],"#, r#""reserve":[],"disabled":[2],"#)), &untrusted, true);
        let models = policy(&with(&acting, r#"{"prefer""#, r#"{"schemaVersion":2,"claudeModels":["seven_day_opus"],"prefer""#));
        for (name, second) in [("model missing", TWO.to_string()), ("model exhausted", scoped(99, tomorrow)), ("model expired", scoped(10, yesterday)), ("model available", scoped(10, tomorrow))] {
            lab.list(&pool(1, ONE, &second));
            told.shown(name, &models, &untrusted, true);
        }

        told.say("##### warm");
        let warmed = at("warm");
        std::fs::create_dir_all(&warmed).unwrap();
        lab.list(&pool(1, ONE, &cold(TWO)));
        std::fs::write(warmed.join("automation-pause.json"), r#"{"until":"2026-10-06T13:00:00.0000000+00:00","reason":"fixture"}"#).unwrap();
        told.shown("paused", &act, &warmed, false);
        std::fs::remove_file(warmed.join("automation-pause.json")).unwrap();
        told.shown("monitor", &watch, &warmed, false);
        told.shown("warm", &warm, &warmed, false);
        for file in ["activity.json", "warm-state.json", "warm-outcomes.json"] {
            told.recorded(&warmed, file);
        }
        // With the time floor lifted, the record of the request still holds the next back.
        std::fs::write(warmed.join("warm-state.json"), r#"{"lastWarm":{},"lastProbe":{}}"#).unwrap();
        told.shown("warm again", &warm, &warmed, false);
        // A later reading that shows the window open confirms it.
        lab.later.set(7);
        lab.list(&pool(1, ONE, &with(TWO, HOUR, r#""resetsAt":"2026-10-06T17:00:00.0000000+00:00""#)));
        told.shown("confirmed", &warm, &warmed, true);
        told.recorded(&warmed, "warm-outcomes.json");
        told.recorded(&warmed, "activity.json");
        lab.later.set(5);

        told.say("##### cold");
        let models = with(WARM, r#"{"prefer""#, r#"{"claudeModels":["seven_day_opus"],"prefer""#);
        let exhausted = format!(r#"{DAY},"scoped":[{{"name":"seven_day_opus","pct":99,"resetsAt":"{tomorrow}"}}]"#);
        let cases = [
            (WARM, with(&cold(TWO), AGE, r#""usageAgeSeconds":901"#)),
            (WARM, with(&cold(TWO), DAY, r#""resetsAt":""}"#)),
            (WARM, with(&cold(TWO), r#""pct":10,"#, r#""pct":-1,"#)),
            (models.as_str(), with(&cold(TWO), DAY, &exhausted)),
            (models.as_str(), cold(TWO)),
        ];
        // Each starts with no record that could hold a request back by itself.
        for (place, (policy_text, second)) in cases.iter().enumerate() {
            lab.list(&pool(1, ONE, second));
            told.shown(&format!("cold {}", place + 1), &policy(policy_text), &at(&format!("cold-{}", place + 1)), false);
        }
        lab.fail("run", true);
        lab.list(&pool(1, ONE, &cold(TWO)));
        told.shown("warm failed", &warm, &at("cold-failed"), false);
        told.recorded(&at("cold-failed"), "warm-state.json");
        told.recorded(&at("cold-failed"), "warm-outcomes.json");
        told.shown("warm failed, next wake", &warm, &at("cold-failed"), false);
        lab.fail("run", false);

        told.say("##### spent");
        let spent = at("spent");
        store(Some(STORED));
        lab.list(&pool(1, &cold(ONE), TWO_DEAD));
        told.shown("monitor", &watch, &spent, false);
        told.say(if spent.join("cred-audit.log").exists() { "audit=True" } else { "audit=False" });
        lab.list(&pool(1, ONE, TWO_DEAD));
        lab.fail("run", true);
        // Lift the time floor, so only the remembered sign-in can hold the next test back.
        let lift = || {
            let saved = json::read_or_null(&spent.join("warm-state.json"));
            saved.set("lastProbe", new_obj(vec![])).ok().unwrap();
            files::write_json(&spent.join("warm-state.json"), &saved, 4).ok().unwrap();
        };
        told.shown("probe 1", &probe, &spent, false);
        told.recorded(&spent, "warm-state.json");
        told.shown("probe floor", &probe, &spent, false);
        lift();
        // One failed test proves nothing about the sign-in, so it gets a second look.
        told.shown("probe 2", &probe, &spent, false);
        lift();
        told.shown("spent", &probe, &spent, false);
        told.recorded(&spent, "warm-state.json");
        // Signing in again stores a new sign-in, and that one has not been asked about.
        store(Some(STORED_AGAIN));
        told.shown("signed in again", &probe, &spent, false);
        told.recorded(&spent, "warm-state.json");
        // A stored sign-in that is not there is never called spent.
        store(None);
        told.shown("unreadable", &probe, &at("spent-unreadable"), false);
        told.recorded(&at("spent-unreadable"), "warm-state.json");
        lab.fail("run", false);
        told.shown("revived", &probe, &at("spent-revived"), false);
        told.recorded(&at("spent-revived"), "warm-state.json");
        told.recorded(&at("spent-revived"), "activity.json");

        told.say("##### unrenewed");
        lab.list(&pool(1, ONE, &cold(TWO)));
        store(Some(STORED));
        for (name, unrenewed) in [("True", true), ("False", false)] {
            // A request went through a session of the account's own only when that
            // session left a copy of the sign-in behind.
            let session = cswap::session_credential(&lab.home, 2, "two@example.invalid");
            if unrenewed {
                std::fs::create_dir_all(session.parent().unwrap()).unwrap();
                std::fs::write(&session, r#"{"claudeAiOauth":{"refreshToken":"fictional-refresh-token","expiresAt":1791288000000}}"#).unwrap();
            }
            let state = at(&format!("unrenewed-{name}"));
            told.shown(&format!("unrenewed {name}"), &warm, &state, false);
            told.recorded(&state, "activity.json");
            assert!(!session.exists());
        }

        told.say("##### critical");
        crate::capacity::set_source(Path::new(env!("CARGO_MANIFEST_DIR")).join("../data").join("capacity-profiles.json"));
        let rotating = at("critical");
        let p = policy(include_str!("../../policy.example.json"));
        for (name, value) in [("mode", V::from("automate")), ("switchEnabled", true.into()), ("prefer", vec![V::I32(3), V::I32(2), V::I32(1)].into()), ("reserve", vec![V::I32(1)].into())] {
            p.set(name, value).ok().unwrap();
        }
        let critical = p.g("critical").ok().unwrap();
        for (name, value) in [("enabled", V::from(true)), ("enterPercent", 25.into()), ("exitPercent", 30.into()), ("drainToZero", true.into()), ("advantagePercent", 0.into())] {
            critical.set(name, value).ok().unwrap();
        }
        lab.list(&three(1, [0.0, 17.0, 21.0], 0));
        told.shown("enter", &p, &rotating, false);
        // A one-minute dwell prevents an immediate bounce.
        lab.list(&three(3, [0.0, 17.0, 16.0], 0));
        told.shown("dwell", &p, &rotating, false);
        let kept = json::read_or_null(&rotating.join("critical-claude.json"));
        kept.set("selectedAt", "2026-10-06T11:58:00.0000000+00:00".into()).ok().unwrap();
        files::write_json(&rotating.join("critical-claude.json"), &kept, 6).ok().unwrap();
        told.shown("after dwell", &p, &rotating, false);
        // Exhaustion does not wait for the dwell.
        lab.list(&three(2, [0.0, 0.0, 16.0], 0));
        told.shown("exhausted", &p, &rotating, false);
        // A high balance read too long ago cannot authorize a switch.
        lab.list(&three(3, [0.0, 24.0, 16.0], 2));
        told.shown("stale high", &p, &rotating, false);
        // A confirmed refill returns to normal selection.
        lab.list(&three(3, [0.0, 100.0, 16.0], 0));
        told.shown("refill", &p, &rotating, false);
        lab.list(&three(1, [0.0, 17.0, 21.0], 0));
        told.shown("preview", &p, &rotating, true);
        std::fs::write(rotating.join("hold.json"), r#"{"until":"2026-10-06T12:05:00.0000000+00:00","reason":"fixture"}"#).unwrap();
        told.shown("held", &p, &rotating, false);
        std::fs::remove_file(rotating.join("hold.json")).unwrap();
        // With no reserve, the former reserve competes on what it has left.
        p.set("reserve", Vec::<V>::new().into()).ok().unwrap();
        lab.list(&three(3, [14.0, 9.0, 0.0], 0));
        told.shown("no reserve", &p, &rotating, false);
        lab.list(&three(1, [0.0, 0.0, 0.5], 0));
        told.shown("anything left", &p, &rotating, false);
        lab.list(&three(3, [0.0, 0.0, 0.0], 0));
        told.shown("nothing left", &p, &rotating, false);

        let expected = include_str!("claude_tick-expected.txt");
        let mut case = "";
        for (place, (said, expected)) in told.text.lines().zip(expected.lines()).enumerate() {
            if expected.starts_with("=== ") || expected.starts_with("#####") {
                case = expected;
            }
            assert_eq!(said, expected, "line {} of the text, in {case}", place + 1);
        }
        assert_eq!(told.text.lines().count(), expected.lines().count());
        lab.done();
    }

    /// A second registration of the Claude driver is asked for under its own name: its
    /// exclusions, its budget, its events and its warm outcomes are its own, never the
    /// family's. The PowerShell collector was held to these.
    #[test]
    fn a_registered_claude_keeps_its_own_name_in_what_it_records() {
        let lab = Lab::new("tick-alias");
        // The definitions this tree ships, and one more that is Claude under another name.
        let shipped = Path::new(env!("CARGO_MANIFEST_DIR")).join("../data/providers");
        let catalog = lab.directory.join("providers");
        std::fs::create_dir_all(&catalog).unwrap();
        for name in ["claude.json", "codex.json"] {
            std::fs::copy(shipped.join(name), catalog.join(name)).unwrap();
        }
        let claude = std::fs::read_to_string(shipped.join("claude.json")).unwrap();
        let alias = with(&with(&claude, r#""id": "claude""#, r#""id": "fictional-claude""#), r#""name": "Claude""#, r#""name": "Fictional Claude""#);
        std::fs::write(catalog.join("fictional-claude.json"), alias).unwrap();
        crate::registry::set_source(catalog);
        let now = Dto::parse(NOON).ok().unwrap();
        // The ping is refused, as the spy of the PowerShell check refused it.
        lab.fail("run", true);
        for kind in ["warm", "probe"] {
            for excluded in [true, false] {
                let account = if kind == "warm" {
                    r#"{"number":1,"email":"alias@example.invalid","usageStatus":"ok","usageAgeSeconds":0,"usage":{"fiveHour":{"pct":0,"resetsAt":""},"sevenDay":{"pct":10,"resetsAt":"2026-10-09T12:00:00.0000000+00:00"}}}"#
                } else {
                    r#"{"number":1,"email":"alias@example.invalid","usageStatus":"relogin_required","lastGoodAgeSeconds":86400,"usage":null}"#
                };
                lab.list(&format!(r#"{{"schemaVersion":1,"activeAccountNumber":1,"accounts":[{account}]}}"#));
                let root = lab.directory.join(format!("claude-alias-{kind}-{excluded}"));
                let whole = policy(&format!(
                    r#"{{"schemaVersion":3,"mode":"automate","switchEnabled":false,"warm":true,"probeEnabled":true,"automation":{{"warmExcluded":[{}]}},"providers":{{"fictional-claude":{{"prefer":[1],"reserve":[]}}}}}}"#,
                    if excluded { r#""fictional-claude:1""# } else { "" }
                ));
                std::fs::create_dir_all(&root).unwrap();
                std::fs::write(root.join("policy.json"), json::write(&whole, 12).ok().unwrap()).unwrap();
                let view = crate::registry::provider_view(&V::Null, &whole, "fictional-claude", &[]).ok().unwrap().g("policy").ok().unwrap();
                let state = crate::registry::provider_state_directory(&root, "fictional-claude").ok().unwrap();
                assert_eq!(state, root.join("providers").join("fictional-claude"));
                let before = lab.calls().len();
                let collected = lab.tick_as("fictional-claude", &state, &root, &view, false).ok().unwrap().unwrap();
                let pings: Vec<String> = lab.calls()[before..].iter().filter(|call| call.starts_with("run ")).cloned().collect();
                let case = format!("{kind} excluded={excluded}");
                assert_eq!(dig(&collected.payload, "slots").each().len(), 1, "{case}");
                if excluded {
                    assert_eq!(pings.len(), 0, "{case}");
                    assert_eq!(said(&collected.payload, "slots.0.actionBlock"), "account_excluded", "{case}");
                    assert!(!state.join("attempt-budget.json").exists(), "{case}");
                    continue;
                }
                assert_eq!(pings, ["run 1 -- claude --model haiku --strict-mcp-config -p ."], "{case}");
                assert!(!truthy(&collected.payload, "slots.0.actionBlock"), "{case}");
                // Which of the two requests it was is in what the collection wrote down.
                let request = json::read_or_null(&state.join("warm-state.json"));
                assert_eq!((truthy(&request, "lastWarm.1"), truthy(&request, "lastProbe.1")), (kind == "warm", kind == "probe"), "{case}");
                let ledger = json::read_or_null(&state.join("attempt-budget.json"));
                assert_eq!(text(&ledger, "2026-10-06/fictional-claude/1"), "1", "{case}");
                assert_eq!(names(&ledger).len(), 1, "{case}");
                view.g("automation").ok().unwrap().add_member("dailyAttemptLimit", V::I32(1), true).ok().unwrap();
                assert_eq!(action_block(&view, &state, "fictional-claude", "1", kind, now).ok().unwrap(), Some("daily_attempt_limit"), "{case}");
                let events = dig(&json::read_or_null(&state.join("activity.json")), "events").each();
                assert!(!events.is_empty(), "{case}");
                assert!(events.iter().all(|event| said(event, "provider") == "fictional-claude"), "{case}");
                if kind == "warm" {
                    assert_eq!(said(&json::read_or_null(&state.join("warm-outcomes.json")), "claude:1.provider"), "fictional-claude", "{case}");
                }
            }
        }
        lab.done();
    }
}

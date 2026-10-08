//! `hotpl8-native route`: the account one T3 session is given. The
//! bridge asks on a private pipe and is answered there, the answer holding the sign-in of
//! the account it names. That answer is printed to the pipe and to nothing else: it is
//! never logged, never kept, and a refusal names a fixed code and no more.

use crate::capacity::capacity_accounts;
use crate::codex_collect::codex_buckets;
use crate::codex_read::{read_home_as, Account, Asked, HomeRead, Search, READ_BUDGET_MS};
use crate::contract::{age_seconds, setting};
use crate::control::{action_authorization, control_snapshot, provider_action_context};
use crate::decision::provider_decision;
use crate::display::packaged_data;
use crate::files;
use crate::json;
use crate::observation::{add_observation_capacity, codex_observation};
use crate::policy::{assert_codex_policy, assert_policy, home_path};
use crate::ps::*;
use crate::registry::configured_provider;
use crate::request::full_path;
use crate::sha256;
use crate::time::Dto;
use crate::{hash, obj};
use std::ffi::OsString;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::rc::Rc;

/// What a caller sets that would sign Codex in as someone else, or send it somewhere else.
const CONFLICTS: [&str; 5] = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_SQLITE_HOME", "OPENAI_BASE_URL"];

/// The refusals the bridge is told by name. Any other is `routing_failed`.
const REFUSALS: [&str; 17] = [
    "routing_environment_conflict",
    "routing_invalid_request",
    "routing_duplicate_identity",
    "routing_stale",
    "routing_unavailable",
    "routing_binding_changed",
    "routing_refresh_failed",
    "routing_auth_unavailable",
    "routing_account_busy",
    "routing_validation_timeout",
    "routing_monitor_only",
    "routing_automation_paused",
    "routing_switching_disabled",
    "routing_selection_held",
    "routing_binding_unknown",
    "routing_state_changed",
    "routing_control_unavailable",
];

/// The longest request read, in the units PowerShell counts a line by.
const LINE_UNITS: usize = 16384;

/// An admission may wait out one slow reader and then make its own slow read, 12 s each on
/// a saturated machine.
const SELECT_BUDGET_MS: i64 = 30_000;
/// A refresh answers Codex itself, which does not wait that long.
const REFRESH_BUDGET_MS: i64 = 6500;
/// How long a read that found its home busy waits before it asks again.
const BUSY_PAUSE_MS: u64 = 75;

/// One request, and what the choice is made with. A test says what a read answers and
/// what time it is; the command reads Codex and the clock.
pub struct Route<'a> {
    pub directory: &'a Path,
    /// The caller's environment holds one of `CONFLICTS`.
    pub conflicted: bool,
    /// One read of the home named, inside the milliseconds given.
    pub read: &'a dyn Fn(&str, &Asked, u64) -> HomeRead,
    pub clock: &'a dyn Fn() -> R<Dto>,
    /// The milliseconds that have passed.
    pub elapsed: &'a dyn Fn() -> i64,
    pub pause: &'a dyn Fn(u64),
}

/// What one home's read came to: the account, or the name of what failed.
type Reading = Result<Rc<Account>, &'static str>;

/// The key a record is bound to its home by.
fn bound(slot: &V) -> R<String> {
    Ok(sha256::hash(&home_path(&slot.g("home")?.s()?)?))
}

/// `$rows | Where-Object id -EQ $id`, or the rows that are left when `kept` is false.
fn named(rows: &[V], id: &str, kept: bool) -> R<Vec<V>> {
    filter(rows, |row| Ok(row.g("id")?.eq_s(id)? == kept))
}

/// Get-Hotpl8CodexRoutingDecision: the accounts as the rows describe them, and which of
/// them this request may be given at `now`.
fn decision(route: &Route, rows: &[V], part: &V, policy: &V, meter: &str, request: &V, now: Dto) -> R<V> {
    let mut accounts = Vec::new();
    for row in rows {
        let account = codex_observation(row, meter)?;
        let blocked = account.g("blockedReason")?;
        if blocked.t()? {
            account.add_member("blockedReason", blocked, true)?;
        }
        account.add_member("windows", account.g("windows")?.arr().into(), true)?;
        accounts.push(account);
    }
    let snapshot = obj! {"providers" => hash! {"codex" => hash! {"slots" => rows.to_vec()}}};
    let capacity = capacity_accounts(&snapshot, part, "codex", now, meter, false)?;
    let accounts = add_observation_capacity(&accounts, &capacity)?;
    // Critical dwell belongs to the session that asks, never to the collector.
    let intent = if request.g("operation")?.eq_s("refresh")? {
        "refresh".to_string()
    } else if request.g("intent")?.t()? {
        request.g("intent")?.s()?
    } else {
        "admit".to_string()
    };
    let previous = request.g("previousSlot")?;
    let context = obj! {
        "intent" => intent,
        "previousId" => previous.s()?,
        "bindingKnown" => previous.t()?,
        "identityKnown" => request.g("accountId")?.t()?,
        "scopes" => vec![V::s_of(meter)],
        "criticalState" => request.g("criticalState")?,
    };
    let context = provider_action_context(policy, route.directory, &context, now)?;
    provider_decision(&accounts.into(), part, &context, now)
}

/// Get-Hotpl8CodexRoute: the account this request is given, with its sign-in.
pub fn chosen(route: &Route, request: &V) -> R<V> {
    let began = (route.elapsed)();
    let spent = || (route.elapsed)() - began;
    if !request.is_obj() {
        return fail("routing_invalid_request");
    }
    let (operation, intent) = (request.g("operation")?, request.g("intent")?);
    let refresh = operation.eq_s("refresh")?;
    let background = intent.eq_s("rebind")?;
    let budget = if refresh { REFRESH_BUDGET_MS } else { SELECT_BUDGET_MS };
    if !operation.in_s(&["select", "refresh", "exec"])? || (intent.t()? && !intent.in_s(&["admit", "rebind"])?) || (operation.ne_s("select")? && background) {
        return fail("routing_invalid_request");
    }
    if route.conflicted {
        return fail("routing_environment_conflict");
    }
    let (policy, generation) = match control_snapshot(route.directory) {
        Err(stop) if stop.said() == Some("action_state_changed") => return fail("routing_state_changed"),
        snapshot => snapshot?,
    };
    assert_policy(&policy)?;
    let part = configured_provider(&policy, "codex", false)?.g("policy")?;
    assert_codex_policy(&part)?;
    let state = json::read_or_null(&route.directory.join("codex-state.json"));
    let status = json::read_or_null(&route.directory.join("status.json")).g("providers")?.g("codex")?;
    let now = (route.clock)()?;
    let meter = if part.g("defaultMeter")?.t()? { part.g("defaultMeter")?.s()? } else { "codex".to_string() };
    let slots = part.g("slots")?.arr();
    let recorded = |state: &V, id: &str| -> R<V> { state.g("slots")?.gd(id) };
    let mut identities = Keys::new();
    for slot in &slots {
        let key = recorded(&state, &slot.g("id")?.s()?)?.g("identityKey")?;
        if key.t()? {
            let key = key.s()?;
            if identities.contains(&key)? {
                return fail("routing_duplicate_identity");
            }
            identities.insert(&key)?;
        }
    }
    let listed = status.g("slots")?.arr();
    let mut rows = Vec::new();
    for slot in &slots {
        let id = slot.g("id")?;
        let matches = filter(&listed, |row| row.g("id")?.eq(&id))?;
        let prior = recorded(&state, &id.s()?)?;
        if prior.g("identityKey")?.t()? && prior.g("binding")?.eq_s(&bound(slot)?)? && !id.is_in(&request.g("exclude")?)? {
            if matches.len() == 1 {
                let mut row = matches[0].clone();
                // A lock that could not be taken, or one slow read by the collector, says
                // nothing of the account's limits or its sign-in. What was kept of it is
                // considered again here and nowhere else: every gate of freshness and
                // policy still applies, and so does the fresh read below, so an account
                // that is stale or was never read stays out. This is never shown as health.
                if row.g("status")?.in_s(&["home_busy", "timeout"])? {
                    row = row.shallow()?;
                    row.set("status", "ok".into())?;
                }
                rows.push(row);
            } else if refresh && matches.is_empty() {
                rows.push(obj! {"id" => id.clone(), "status" => "unknown", "observedAt" => V::Null, "buckets" => V::Null});
            }
        }
    }
    if !refresh {
        let Ok(Some(age)) = age_seconds(&status.g("observedAt")?, now) else { return fail("routing_stale") };
        if age < -5.0 || dbl(age)?.gt(&setting(&part, "maxUsageAgeS", V::I32(900))?)? {
            return fail("routing_stale");
        }
    }
    // What was read stays with this admission. An account that loses its place once its
    // fresh limits arrive can still serve if a better one fails. Each home is read once,
    // and one more pass may choose among those already read. A home whose lock stayed busy
    // has not been read: it is set aside while the others are tried, and tried again until
    // the time is up.
    let same = |left: &str, right: &str| left.eq_ignore_ascii_case(right);
    let mut validated: Vec<(String, Rc<Account>)> = Vec::new();
    let mut busy: Vec<V> = Vec::new();
    let mut locked: Vec<String> = Vec::new();
    let mut settled = 0;
    let directory = request.g("cwd")?.s()?;
    while settled <= slots.len() {
        if spent() >= budget {
            return fail(if locked.is_empty() { "routing_validation_timeout" } else { "routing_account_busy" });
        }
        let first = decision(route, &rows, &part, &policy, &meter, request, (route.clock)()?)?;
        if !first.g("actionPermitted")?.t()? {
            // Only a lock stands between this admission and the homes set aside. They are
            // decided with again: a setting that stops the action still does, and is the
            // reason given then.
            if !busy.is_empty() {
                rows.append(&mut busy);
                continue;
            }
            let reason = first.g("suppressionReason")?;
            if reason.in_s(&["monitor_only", "automation_paused", "switching_disabled", "selection_held", "binding_unknown"])? {
                return fail(format!("routing_{}", reason.s()?));
            }
            return fail("routing_unavailable");
        }
        let selected = first.g("targetSlot")?.s()?;
        let slot = named(&slots, &selected, true)?;
        if slot.len() != 1 || V::s_of(&selected).is_in(&part.g("disabled")?)? {
            return fail("routing_binding_changed");
        }
        let slot = &slot[0];
        let prior = recorded(&state, &selected)?;
        if !prior.g("identityKey")?.t()? || prior.g("binding")?.ne(&V::from(bound(slot)?))? {
            return fail("routing_binding_changed");
        }
        let cached = validated.iter().find(|(id, _)| same(id, &selected)).map(|(_, account)| account.clone());
        let read: Reading = match &cached {
            Some(account) => Ok(account.clone()),
            None => {
                let waited = (route.elapsed)();
                let home = slot.g("home")?.s()?;
                // Another reader holds this lock for 2 to 4 s, and up to 12 s on a saturated
                // machine. An admission waits 6.5 s for it before another account is tried.
                // A refresh waits less, so that its own read still fits its 6.5 s. Work
                // nobody waits for does not wait at all: it would hold the lock next, in
                // front of an admission, and the next wake repeats it.
                let lock_wait = if refresh {
                    2500
                } else if background {
                    0
                } else {
                    6500
                };
                let mut read: Option<Reading> = None;
                loop {
                    let remaining = budget - spent();
                    if remaining <= 0 {
                        let waiting = !locked.is_empty() || matches!(read, Some(Err("home_busy")));
                        return fail(if waiting { "routing_account_busy" } else { "routing_validation_timeout" });
                    }
                    // The collector's bound: a tighter one fails every account at once when
                    // starting Codex alone takes longer.
                    let asked = Asked { directory: Some(&directory), refresh, identity_only: false, token: true };
                    let outcome = (route.read)(&home, &asked, READ_BUDGET_MS.min(remaining as u64)).outcome.map(Rc::new);
                    let held = matches!(outcome, Err("home_busy"));
                    read = Some(outcome);
                    if !held || (route.elapsed)() - waited >= lock_wait {
                        break;
                    }
                    (route.pause)(BUSY_PAUSE_MS);
                }
                read.unwrap_or(Err("transport_failed"))
            }
        };
        if matches!(read, Err("home_busy")) {
            if refresh || background {
                return fail("routing_account_busy");
            }
            if !locked.iter().any(|id| same(id, &selected)) {
                locked.push(selected.clone());
            }
            busy.extend(named(&rows, &selected, true)?);
            rows = named(&rows, &selected, false)?;
            continue;
        }
        locked.retain(|id| !same(id, &selected));
        settled += 1;
        let account = read.ok();
        let mut valid = match &account {
            Some(account) => V::s_of(&account.identity_key).eq(&prior.g("identityKey")?)? && account.standard_transport && (account.model_provider.is_empty() || text_eq(&account.model_provider, "openai")?),
            None => false,
        };
        let auth = account.as_ref().and_then(|account| account.auth.as_ref());
        if refresh {
            let signed = auth.map_or(V::Null, |auth| V::s_of(&auth.account_id));
            if !valid || signed.cne(&request.g("accountId")?)? {
                return fail("routing_refresh_failed");
            }
        } else if let (true, Some(account)) = (valid, &account) {
            let read_now = (route.clock)()?;
            if cached.is_none() {
                validated.push((selected.clone(), account.clone()));
                let old = filter(&rows, |row| row.g("id")?.ceq_s(&selected))?.into_iter().next().unwrap_or(V::Null);
                let current = obj! {
                    "id" => selected.as_str(),
                    "status" => "ok",
                    "observedAt" => read_now.o(),
                    "buckets" => codex_buckets(&account.quota, &old.g("buckets")?, read_now)?,
                };
                rows = named(&rows, &selected, false)?;
                rows.push(current);
            }
            let second = decision(route, &rows, &part, &policy, &meter, request, read_now)?;
            let stays = second.g("targetSlot")?.ceq_s(&selected)?;
            if second.g("actionPermitted")?.t()? && !stays {
                continue;
            }
            valid = second.g("actionPermitted")?.t()? && stays;
        }
        if valid {
            let Some(auth) = auth.filter(|auth| !auth.access_token.is_empty() && !auth.account_id.is_empty()) else { return fail("routing_auth_unavailable") };
            // No program is run inside this short boundary. A change made after it governs
            // what is done next; a turn is never repeated.
            let authorized = action_authorization(route.directory, &generation, || {
                let latest = recorded(&json::read_or_null(&route.directory.join("codex-state.json")), &selected)?;
                if latest.g("identityKey")?.cne(&prior.g("identityKey")?)? || latest.g("binding")?.cne(&prior.g("binding")?)? {
                    return fail("routing_binding_changed");
                }
                decision(route, &rows, &part, &policy, &meter, request, (route.clock)()?)
            });
            let authorized = match authorized {
                Err(stop) if stop.said() == Some("action_state_changed") => return fail("routing_state_changed"),
                authorized => authorized?,
            };
            if !authorized.g("actionPermitted")?.t()? || !authorized.g("targetSlot")?.ceq_s(&selected)? {
                return fail("routing_state_changed");
            }
            let critical = authorized.g("critical")?;
            critical.set("selected", selected.as_str().into())?;
            let since = request.g("criticalState")?.g("selectedAt")?;
            let moved = V::s_of(&selected).cne(&request.g("previousSlot")?)? || !since.t()?;
            critical.set("selectedAt", if moved { (route.clock)()?.o().into() } else { since })?;
            return Ok(obj! {
                "slot" => selected.as_str(),
                "home" => slot.g("home")?.s()?,
                "meter" => meter.as_str(),
                "criticalState" => critical,
                "authorizationGeneration" => generation.as_str(),
                "auth" => if operation.ne_s("exec")? { obj! {"accessToken" => auth.access_token.as_str(), "chatgptAccountId" => auth.account_id.as_str()} } else { V::Null },
            });
        }
        rows = named(&rows, &selected, false)?;
        if refresh {
            return fail("routing_refresh_failed");
        }
    }
    fail(if locked.is_empty() { "routing_unavailable" } else { "routing_account_busy" })
}

/// src/codex-route.ps1: the one line answered to one line asked, and whether it names an
/// account. A refusal is written to the event log as its code and the time, and nothing of
/// the request, the account, the home or what Codex said. Work nobody waits for that found
/// the lock held was passed over, not refused, and leaves no line.
pub fn answered(route: &Route, line: Option<&str>) -> (String, bool) {
    let mut request = V::Null;
    let answer = || -> R<String> {
        let Some(line) = line.filter(|line| !line.is_empty() && length(line) <= LINE_UNITS) else { return fail("routing_invalid_request") };
        request = json::parse_foreign(line)?;
        json::compact(&chosen(route, &request)?, 12)
    }();
    let stop = match answer {
        Ok(line) => return (line, true),
        Err(stop) => stop,
    };
    let code = match stop.said() {
        Some("action_control_busy" | "action_state_unavailable") => "routing_control_unavailable",
        Some(said) => REFUSALS.iter().find(|known| **known == said).copied().unwrap_or("routing_failed"),
        None => "routing_failed",
    };
    let passed_over = code == "routing_account_busy" && request.is_obj() && request.g("intent").and_then(|intent| intent.eq_s("rebind")).unwrap_or(false);
    if !passed_over {
        files::event(route.directory, code, None);
    }
    (format!(r#"{{"error":"{code}"}}"#), false)
}

struct Started {
    root: PathBuf,
    state: PathBuf,
    codex: Option<String>,
}

/// `route --root <dir> --state <dir> [--codex <program>]`
fn spelled(arguments: &[OsString]) -> Option<Started> {
    const NAMES: [&str; 3] = ["--root", "--state", "--codex"];
    let mut values: [Option<&OsString>; 3] = [None; 3];
    let mut rest = arguments.iter();
    while let Some(word) = rest.next() {
        let name = word.to_str()?;
        let slot = NAMES.iter().position(|known| *known == name).filter(|slot| values[*slot].is_none())?;
        values[slot] = Some(rest.next()?);
    }
    let codex = match values[2] {
        Some(named) => Some(named.to_str()?.to_string()),
        None => None,
    };
    Some(Started { root: full_path(values[0]?)?, state: full_path(values[1]?)?, codex })
}

/// The request: the first line of what the caller writes, or nothing when it is longer
/// than any request is. Windows PowerShell opens a pipe it writes with the mark of its
/// console's encoding, which is no part of the line.
fn asked_line(written: impl BufRead) -> Option<String> {
    const MARK: &[u8] = &[0xef, 0xbb, 0xbf];
    // A line of `LINE_UNITS` is at most three bytes a unit, and its end at most two more.
    let most = MARK.len() + LINE_UNITS * 3 + 2;
    let mut bytes = Vec::new();
    written.take(most as u64).read_until(b'\n', &mut bytes).ok()?;
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
        if bytes.last() == Some(&b'\r') {
            bytes.pop();
        }
    } else if bytes.len() >= most {
        return None;
    }
    Some(String::from_utf8_lossy(bytes.strip_prefix(MARK).unwrap_or(&bytes)).into_owned())
}

/// The `route` command: one request read from the caller, one line answered to it. Answers
/// whether an account was named.
pub fn started(arguments: &[OsString]) -> Result<bool, String> {
    let Some(started) = spelled(arguments) else {
        let words: Vec<String> = arguments.iter().map(|word| word.to_string_lossy().into_owned()).collect();
        return Err(format!("The route was started with words it does not take: {}", words.join(" ")));
    };
    // The numbers of an answer are those of the PowerShell that has always given it.
    set_core(!cfg!(windows));
    packaged_data(&started.root);
    let line = asked_line(std::io::stdin().lock());
    // Looked for once, by the first account that is read, and not at all by a request that reads none.
    let program = std::cell::OnceCell::new();
    let clock = std::time::Instant::now();
    let (answer, named) = answered(
        &Route {
            directory: &started.state,
            conflicted: CONFLICTS.iter().any(|key| std::env::var_os(key).is_some_and(|value| !value.is_empty())),
            read: &|home, asked, budget| read_home_as(home, program.get_or_init(|| Search::here().program(started.codex.as_deref())), budget, asked),
            clock: &Dto::now,
            elapsed: &|| clock.elapsed().as_millis() as i64,
            pause: &|milliseconds| std::thread::sleep(std::time::Duration::from_millis(milliseconds)),
        },
        line.as_deref(),
    );
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{answer}");
    let _ = stdout.flush();
    Ok(named)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codex_read::Auth;
    use crate::files::tests::scratch;
    use std::cell::{Cell, RefCell};

    const NOON: &str = "2026-10-07T12:00:00.0000000+00:00";

    /// One read a route asked for.
    struct Seen {
        id: String,
        refresh: bool,
        budget: u64,
        token: bool,
        directory: String,
    }

    /// Two accounts, `a` preferred to `b`, in a directory of their own. No Codex is started:
    /// each test says what a read answers. It is noon throughout, and time passes only as
    /// the route pauses or a read says it took.
    struct Lab {
        directory: PathBuf,
        spent: Cell<i64>,
        conflicted: Cell<bool>,
        policy: V,
        /// The percent of its week each account has used, as a read finds it.
        used: RefCell<Vec<(&'static str, i32)>>,
        reads: RefCell<Vec<Seen>>,
    }

    fn noon() -> Dto {
        Dto::parse(NOON).ok().unwrap()
    }

    /// What Codex says of an account's limits: one weekly window that resets in an hour.
    fn limits(used: i32) -> V {
        let resets = noon().unix_seconds() + 3600;
        let quota = format!(r#"{{"rateLimits":{{"limitId":"codex","primary":{{"usedPercent":{used},"windowDurationMins":10080,"resetsAt":{resets}}},"secondary":null,"spendControlReached":false}}}}"#);
        json::parse(&quota, "").ok().unwrap()
    }

    fn failed(name: &'static str) -> HomeRead {
        HomeRead { elapsed_ms: 5, outcome: Err(name) }
    }

    /// The account a request was given, or how it was refused.
    fn slot(answer: R<V>) -> String {
        match answer {
            Ok(route) => route.g("slot").ok().unwrap().s().ok().unwrap(),
            Err(stop) => format!("refused: {}", stop.message()),
        }
    }

    /// The code a request was refused with, or the account it was given.
    fn code(answer: R<V>) -> String {
        match answer {
            Ok(route) => format!("given {}", slot(Ok(route))),
            Err(stop) => stop.message(),
        }
    }

    impl Lab {
        fn new() -> Lab {
            set_core(false);
            crate::display::packaged_data(&Path::new(env!("CARGO_MANIFEST_DIR")).join(".."));
            let directory = scratch("route");
            let home = |id: &str| directory.join(format!("home-{id}")).to_string_lossy().into_owned();
            let slots: Vec<V> = ["a", "b"].iter().map(|id| obj! {"id" => *id, "home" => home(id), "label" => *id}).collect();
            let policy = obj! {
                "schemaVersion" => 2,
                "mode" => "monitor",
                "prefer" => Vec::<V>::new(),
                "codex" => obj! {
                    "slots" => slots,
                    "prefer" => vec![V::s_of("a"), V::s_of("b")],
                    "reserve" => Vec::<V>::new(),
                    "order" => "prefer",
                    "defaultMeter" => "codex",
                    "modelMeters" => obj! {"fixture-model" => "codex"},
                    "margin7d" => 20,
                    "margin7dWork" => 5,
                },
            };
            let lab = Lab { directory, spent: Cell::new(0), conflicted: Cell::new(false), policy, used: RefCell::new(vec![("a", 10), ("b", 10)]), reads: RefCell::new(Vec::new()) };
            lab.save("policy.json", &lab.policy);
            lab.collected("ok", 0, 0);
            lab.recorded(&[]);
            lab
        }

        fn home(&self, id: &str) -> String {
            self.directory.join(format!("home-{id}")).to_string_lossy().into_owned()
        }

        fn save(&self, name: &str, value: &V) {
            std::fs::write(self.directory.join(name), json::write(value, 30).ok().unwrap()).unwrap();
        }

        fn remove(&self, name: &str) {
            std::fs::remove_file(self.directory.join(name)).unwrap();
        }

        /// The settings as the user has them: HotPl8 acts, and may move a session.
        fn automate(&self) {
            self.policy.set("mode", "automate".into()).ok().unwrap();
            self.policy.add_member("switchEnabled", true.into(), true).ok().unwrap();
            self.save("policy.json", &self.policy);
        }

        /// One of the settings of the accounts, changed.
        fn accounts(&self, name: &str, value: V) {
            self.policy.g("codex").ok().unwrap().add_member(name, value, true).ok().unwrap();
            self.save("policy.json", &self.policy);
        }

        /// The snapshot a collection left `age` seconds ago: both accounts a tenth used,
        /// each read `read_age` seconds ago and found as `status` says.
        fn collected(&self, status: &str, read_age: i64, age: i64) {
            let at = |age: i64| noon().plus_seconds(-age).ok().unwrap().o();
            let rows: Vec<V> = ["a", "b"]
                .iter()
                .map(|id| obj! {"id" => *id, "status" => status, "observedAt" => at(read_age), "defaultModel" => "fixture-model", "buckets" => codex_buckets(&limits(10), &V::Null, noon()).ok().unwrap()})
                .collect();
            let codex = obj! {"observedAt" => at(age), "recommendations" => obj! {"codex" => "a"}, "slots" => rows};
            self.save("status.json", &obj! {"providers" => obj! {"codex" => codex}});
        }

        /// What the collector keeps of who each home belongs to, `changed` in place of
        /// what it wrote for the members named.
        fn recorded(&self, changed: &[(&str, &str, &str)]) {
            let slots: Vec<(&str, V)> = ["a", "b"]
                .iter()
                .map(|id| {
                    let kept = |name: &str, usual: String| changed.iter().find(|(slot, member, _)| slot == id && *member == name).map_or(usual, |(_, _, value)| value.to_string());
                    let binding = kept("binding", sha256::hash(&home_path(&self.home(id)).ok().unwrap()));
                    (*id, obj! {"binding" => binding, "identityKey" => kept("identityKey", format!("identity-{id}"))})
                })
                .collect();
            self.save("codex-state.json", &obj! {"slots" => new_obj(slots)});
        }

        /// The automation is paused, or a selection is held, for five more minutes.
        fn until(&self, name: &str) {
            let until = noon().plus_seconds(300).ok().unwrap().o();
            self.save(name, &obj! {"until" => until, "reason" => "fixture"});
        }

        fn uses(&self, id: &'static str, percent: i32) {
            self.used.borrow_mut().retain(|(known, _)| *known != id);
            self.used.borrow_mut().push((id, percent));
        }

        /// What a read of the account answers when nothing is in its way.
        fn fresh(&self, id: &str) -> HomeRead {
            let used = self.used.borrow().iter().find(|(known, _)| *known == id).map_or(10, |(_, used)| *used);
            HomeRead {
                elapsed_ms: 40,
                outcome: Ok(Account {
                    quota: limits(used),
                    identity_key: format!("identity-{id}"),
                    plan_type: "plus".into(),
                    model: "fixture-model".into(),
                    model_provider: "openai".into(),
                    standard_transport: true,
                    identity_verified: false,
                    auth: Some(Auth { access_token: format!("fixture-token-{id}"), account_id: id.into() }),
                }),
            }
        }

        /// A request as the bridge writes one, from this lab's working directory.
        fn asks(&self, members: &str) -> V {
            json::parse_foreign(&self.line(members)).ok().unwrap()
        }

        fn line(&self, members: &str) -> String {
            format!(r#"{{{members},"model":"fixture-model","cwd":{}}}"#, json::text(&self.directory.to_string_lossy()))
        }

        fn route<T>(&self, read: &dyn Fn(&str, &Asked, u64) -> HomeRead, asked: impl FnOnce(&Route) -> T) -> T {
            self.spent.set(0);
            self.reads.borrow_mut().clear();
            asked(&Route {
                directory: &self.directory,
                conflicted: self.conflicted.get(),
                read: &|home, asked, budget| {
                    let id = home.rsplit('-').next().unwrap_or_default();
                    assert_eq!(home, self.home(id));
                    self.reads.borrow_mut().push(Seen { id: id.into(), refresh: asked.refresh, budget, token: asked.token && !asked.identity_only, directory: asked.directory.unwrap_or_default().into() });
                    read(id, asked, budget)
                },
                clock: &|| Ok(noon()),
                elapsed: &|| self.spent.get(),
                pause: &|milliseconds| self.spent.set(self.spent.get() + milliseconds as i64),
            })
        }

        /// The request answered with reads a test describes.
        fn tried(&self, request: &V, read: &dyn Fn(&str, &Asked, u64) -> HomeRead) -> R<V> {
            self.route(read, |route| chosen(route, request))
        }

        /// The request answered with every account read as it is.
        fn given(&self, request: &V) -> R<V> {
            self.tried(request, &|id, _, _| self.fresh(id))
        }

        /// How many reads the last request made of one account.
        fn reads(&self, id: &str) -> usize {
            self.reads.borrow().iter().filter(|seen| seen.id == id).count()
        }

        fn events(&self) -> Vec<String> {
            std::fs::read_to_string(self.directory.join("events.jsonl")).unwrap_or_default().lines().map(str::to_string).collect()
        }
    }

    #[test]
    fn an_admission_is_given_the_preferred_account_and_its_sign_in() {
        let lab = Lab::new();
        let route = lab.given(&lab.asks(r#""operation":"select""#)).ok().unwrap();
        let named: Vec<String> = route.props().ok().unwrap().iter().map(|(name, _)| name.to_string()).collect();
        assert_eq!(named, ["slot", "home", "meter", "criticalState", "authorizationGeneration", "auth"]);
        assert_eq!(json::compact(&route.g("auth").ok().unwrap(), 4).ok().unwrap(), r#"{"accessToken":"fixture-token-a","chatgptAccountId":"a"}"#);
        let said = |name: &str| route.g(name).ok().unwrap().s().ok().unwrap();
        assert_eq!((said("slot"), said("home"), said("meter")), ("a".to_string(), lab.home("a"), "codex".to_string()));
        assert_eq!(said("authorizationGeneration").len(), 64);
        assert_eq!(route.path(&["criticalState", "selected"]).ok().unwrap().s().ok().unwrap(), "a");
        assert_eq!(route.path(&["criticalState", "selectedAt"]).ok().unwrap().s().ok().unwrap(), noon().o());
        // One read, with the sign-in, where the session works, in the time a collection allows.
        let reads = lab.reads.borrow();
        assert_eq!(reads.len(), 1);
        assert!(reads[0].id == "a" && reads[0].token && !reads[0].refresh && reads[0].budget == READ_BUDGET_MS);
        assert_eq!(reads[0].directory, lab.directory.to_string_lossy());
        // Nothing is written of an account that was given.
        assert!(lab.events().is_empty());
    }

    #[test]
    fn an_account_the_caller_rules_out_is_not_considered() {
        let lab = Lab::new();
        let without = |ruled_out: &str| lab.given(&lab.asks(&format!(r#""operation":"select","exclude":{ruled_out}"#)));
        let route = without(r#"["a"]"#).ok().unwrap();
        assert_eq!(route.g("slot").ok().unwrap().s().ok().unwrap(), "b");
        assert_eq!((lab.reads("a"), lab.reads("b")), (0, 1));
        // An account is named as PowerShell compared names: in either case.
        assert_eq!(without(r#"["A"]"#).ok().unwrap().g("slot").ok().unwrap().s().ok().unwrap(), "b");
        assert_eq!(without("[]").ok().unwrap().g("slot").ok().unwrap().s().ok().unwrap(), "a");
        assert_eq!(code(without(r#"["a","b"]"#)), "routing_unavailable");
        assert_eq!(lab.reads.borrow().len(), 0);
    }

    /// A saturated machine makes every read slow, the collector's included. An admission
    /// that allowed its own read less time than the collector's lost the preferred
    /// account, and with every account slow had none left.
    #[test]
    fn a_slow_read_is_allowed_the_time_a_collection_allows() {
        let lab = Lab::new();
        let slow = |id: &str, _: &Asked, _: u64| {
            lab.spent.set(lab.spent.get() + 7000);
            lab.fresh(id)
        };
        assert_eq!(slot(lab.tried(&lab.asks(r#""operation":"select""#), &slow)), "a");
        let reads = lab.reads.borrow();
        assert!(reads.len() == 1 && reads[0].budget == READ_BUDGET_MS);
    }

    /// A collector that met a session at an account's lock keeps what it knew of the
    /// account, and so does one whose read was slow. An admission may read that account
    /// afresh; what the collector kept does not admit it alone.
    #[test]
    fn an_account_the_collector_could_not_read_is_read_afresh() {
        let lab = Lab::new();
        let request = lab.asks(r#""operation":"select""#);
        let refused = |_: &str, _: &Asked, _: u64| failed("authentication_required");
        for status in ["home_busy", "timeout"] {
            lab.collected(status, 0, 0);
            assert_eq!(slot(lab.given(&request)), "a", "{status}");
            assert_eq!(code(lab.tried(&request, &refused)), "routing_unavailable", "{status}");
            assert_eq!((lab.reads("a"), lab.reads("b")), (1, 1), "{status}");
            // What was kept an hour ago is as stale as it would be had the read worked.
            lab.collected(status, 3600, 0);
            assert_eq!(code(lab.tried(&request, &refused)), "routing_unavailable", "{status}");
            assert!(lab.reads.borrow().is_empty(), "{status}");
        }
        // Only a busy home or a slow read is considered again.
        lab.collected("authentication_required", 0, 0);
        assert_eq!(code(lab.tried(&request, &refused)), "routing_unavailable");
        assert!(lab.reads.borrow().is_empty());
    }

    #[test]
    fn what_the_user_set_stops_a_move_before_anything_is_read() {
        let lab = Lab::new();
        let admission = lab.asks(r#""operation":"select""#);
        let background = lab.asks(r#""operation":"select","intent":"rebind","previousSlot":"a""#);
        let unexpected = |_: &str, _: &Asked, _: u64| -> HomeRead { panic!("nothing is read") };
        assert_eq!(code(lab.tried(&background, &unexpected)), "routing_monitor_only");
        lab.policy.set("mode", "automate".into()).ok().unwrap();
        lab.policy.add_member("switchEnabled", false.into(), true).ok().unwrap();
        lab.save("policy.json", &lab.policy);
        assert_eq!(code(lab.tried(&background, &unexpected)), "routing_switching_disabled");
        lab.automate();
        lab.until("automation-pause.json");
        assert_eq!(code(lab.tried(&background, &unexpected)), "routing_automation_paused");
        // A pause stops what HotPl8 would do unasked. A session that is starting still
        // gets an account, and one that is running still has its sign-in renewed.
        assert_eq!(slot(lab.given(&admission)), "a");
        let pinned = lab.asks(r#""operation":"refresh","previousSlot":"a","accountId":"a""#);
        assert_eq!(slot(lab.given(&pinned)), "a");
        assert!(lab.reads.borrow()[0].refresh);
    }

    #[test]
    fn a_setting_changed_while_the_account_was_read_is_not_acted_past() {
        let lab = Lab::new();
        lab.automate();
        let request = lab.asks(r#""operation":"select""#);
        let changed = |id: &str, _: &Asked, _: u64| {
            lab.until("automation-pause.json");
            lab.fresh(id)
        };
        assert_eq!(code(lab.tried(&request, &changed)), "routing_state_changed");
        lab.remove("automation-pause.json");
        assert_eq!(slot(lab.given(&request)), "a");
    }

    /// The margins a launch is chosen by, measured on both sides before an account runs
    /// out. Routing has no threshold of its own.
    #[test]
    fn work_moves_before_an_account_runs_out_and_starts_on_what_is_left() {
        let lab = Lab::new();
        lab.automate();
        let admission = lab.asks(r#""operation":"select""#);
        let ongoing = lab.asks(r#""operation":"select","intent":"rebind","models":["fixture-model"],"previousSlot":"a""#);
        let without_b = |id: &str, _: &Asked, _: u64| if id == "b" { failed("authentication_required") } else { lab.fresh(id) };
        lab.uses("a", 94);
        assert_eq!(slot(lab.given(&ongoing)), "b");
        // An account that is running low still serves when the better one cannot be read,
        // and neither is read twice for it.
        let fallback = lab.tried(&admission, &without_b).ok().unwrap();
        assert_eq!(fallback.path(&["auth", "accessToken"]).ok().unwrap().s().ok().unwrap(), "fixture-token-a");
        assert_eq!((slot(Ok(fallback)), lab.reads("a"), lab.reads("b")), ("a".to_string(), 1, 1));
        // Under the floor it does not.
        lab.uses("a", 96);
        assert_eq!(code(lab.tried(&admission, &without_b)), "routing_unavailable");
        assert_eq!(slot(lab.given(&ongoing)), "b");
    }

    #[test]
    fn a_change_made_before_the_account_fallen_back_on_is_noticed() {
        let lab = Lab::new();
        lab.automate();
        lab.uses("a", 94);
        let request = lab.asks(r#""operation":"select""#);
        let paused = |id: &str, _: &Asked, _: u64| {
            if id == "b" {
                lab.until("automation-pause.json");
                return failed("authentication_required");
            }
            lab.fresh(id)
        };
        assert_eq!(code(lab.tried(&request, &paused)), "routing_state_changed");
        lab.remove("automation-pause.json");
        let signed_out = |id: &str, _: &Asked, _: u64| {
            if id == "b" {
                lab.recorded(&[("a", "identityKey", "changed")]);
                return failed("authentication_required");
            }
            lab.fresh(id)
        };
        assert_eq!(code(lab.tried(&request, &signed_out)), "routing_binding_changed");
    }

    #[test]
    fn a_held_selection_keeps_a_session_on_the_account_it_has() {
        let lab = Lab::new();
        lab.automate();
        lab.uses("a", 96);
        lab.until("hold.json");
        let asks = |intent: &str, previous: &str| lab.asks(&format!(r#""operation":"select","intent":"{intent}","previousSlot":"{previous}""#));
        assert_eq!(code(lab.given(&asks("rebind", "a"))), "routing_selection_held");
        assert_eq!(code(lab.given(&asks("admit", "a"))), "routing_unavailable");
        assert_eq!(code(lab.given(&asks("rebind", "b"))), "routing_selection_held");
        // The collector recommends `a`; the session is on `b`, and stays there.
        assert_eq!(slot(lab.given(&asks("admit", "b"))), "b");
        assert_eq!(code(lab.given(&lab.asks(r#""operation":"select""#))), "routing_binding_unknown");
    }

    #[test]
    fn the_models_a_session_names_do_not_change_what_an_account_is_measured_by() {
        let lab = Lab::new();
        lab.automate();
        lab.accounts("modelMeters", obj! {"fixture-model" => "codex", "other-model" => "codex_bengalfox"});
        for models in [r#"["fixture-model","other-model"]"#, r#"["unmapped"]"#] {
            let ongoing = lab.asks(&format!(r#""operation":"select","intent":"rebind","models":{models},"previousSlot":"b""#));
            assert_eq!(lab.given(&ongoing).ok().unwrap().g("meter").ok().unwrap().s().ok().unwrap(), "codex", "{models}");
        }
        // Nor does the model the session runs.
        lab.uses("a", 100);
        let unmapped = json::parse_foreign(&lab.line(r#""operation":"select""#).replace("fixture-model", "unmapped")).ok().unwrap();
        assert_eq!(slot(lab.given(&unmapped)), "b");
    }

    #[test]
    fn a_busy_home_is_waited_for_and_no_other_failure_is() {
        let lab = Lab::new();
        lab.automate();
        lab.uses("a", 100);
        let admission = lab.asks(r#""operation":"select""#);
        // What a fresh read finds spent gives way before anything is sent.
        assert_eq!(slot(lab.given(&admission)), "b");
        let busy_twice = |id: &str, _: &Asked, _: u64| if id == "b" && lab.reads("b") <= 2 { failed("home_busy") } else { lab.fresh(id) };
        assert_eq!(slot(lab.tried(&admission, &busy_twice)), "b");
        assert_eq!(lab.reads("b"), 3);
        // A run that is not a chat is found its account the same way, and is not handed the sign-in.
        let run = lab.tried(&lab.asks(r#""operation":"exec""#), &busy_twice).ok().unwrap();
        assert!(run.g("auth").ok().unwrap().is_null());
        assert_eq!((slot(Ok(run)), lab.reads("b")), ("b".to_string(), 3));
        let refused = |_: &str, _: &Asked, _: u64| failed("authentication_required");
        assert_eq!(code(lab.tried(&admission, &refused)), "routing_unavailable");
        assert_eq!(lab.reads.borrow().len(), 2);
        // An account whose home stays busy is passed over for one that can be read.
        let busy_a = |id: &str, _: &Asked, _: u64| if id == "a" { failed("home_busy") } else { lab.fresh(id) };
        assert_eq!(slot(lab.tried(&admission, &busy_a)), "b");
        assert!(lab.spent.get() >= 6500 && lab.reads("b") == 1);
    }

    /// The only account that can serve, its lock held by slow readers for longer than one
    /// wait. Nothing is wrong with the account: the admission keeps waiting for it inside
    /// its time rather than report the lock.
    #[test]
    fn the_only_account_left_is_waited_for_until_the_time_is_up() {
        let lab = &Lab::new();
        lab.automate();
        lab.uses("a", 100);
        let admission = lab.asks(r#""operation":"select""#);
        let busy_for = |milliseconds: i64| move |id: &str, _: &Asked, _: u64| if id == "b" && lab.spent.get() < milliseconds { failed("home_busy") } else { lab.fresh(id) };
        let route = lab.tried(&admission, &busy_for(8000)).ok().unwrap();
        assert_eq!(route.path(&["auth", "accessToken"]).ok().unwrap().s().ok().unwrap(), "fixture-token-b");
        assert!(lab.spent.get() >= 8000 && lab.spent.get() < 8200);
        // Waiting for one account does not read the other again.
        assert_eq!((slot(Ok(route)), lab.reads("a")), ("b".to_string(), 1));
        // A lock that outlasts the admission is what the caller is told of.
        assert_eq!(code(lab.tried(&admission, &busy_for(60_000))), "routing_account_busy");
        assert!(lab.spent.get() >= SELECT_BUDGET_MS && lab.spent.get() < SELECT_BUDGET_MS + 100);
        // Reads that used the time up without a lock in the way are told of as that.
        let slow = |_: &str, _: &Asked, _: u64| {
            lab.spent.set(lab.spent.get() + 16_000);
            failed("timeout")
        };
        assert_eq!(code(lab.tried(&admission, &slow)), "routing_validation_timeout");
        assert_eq!(lab.reads.borrow().len(), 2);
        // The time left is all a read is given.
        assert_eq!(lab.reads.borrow()[1].budget, READ_BUDGET_MS);
        let slower = |_: &str, _: &Asked, _: u64| {
            lab.spent.set(lab.spent.get() + 25_000);
            failed("timeout")
        };
        assert_eq!(code(lab.tried(&admission, &slower)), "routing_validation_timeout");
        assert_eq!(lab.reads.borrow()[1].budget, 5000);
    }

    /// Nobody waits for a validation made in the background. Queueing for the lock would
    /// put it in front of an admission, so it gives up at once and the next wake repeats it.
    #[test]
    fn work_nobody_waits_for_does_not_queue_for_a_lock() {
        let lab = Lab::new();
        lab.automate();
        lab.uses("a", 100);
        let background = lab.asks(r#""operation":"select","intent":"rebind","previousSlot":"b""#);
        let busy = |_: &str, _: &Asked, _: u64| failed("home_busy");
        assert_eq!(code(lab.tried(&background, &busy)), "routing_account_busy");
        assert_eq!((lab.reads.borrow().len(), lab.spent.get()), (1, 0));
        // It is passed over, not refused: no line is left for it, as one is for an admission.
        let passed = lab.route(&busy, |route| answered(route, Some(&lab.line(r#""operation":"select","intent":"rebind","previousSlot":"b""#))));
        assert_eq!(passed, (r#"{"error":"routing_account_busy"}"#.to_string(), false));
        assert!(lab.events().is_empty());
        let refused = lab.route(&busy, |route| answered(route, Some(&lab.line(r#""operation":"select""#))));
        assert_eq!(refused, (r#"{"error":"routing_account_busy"}"#.to_string(), false));
        assert_eq!(lab.events().len(), 1);
    }

    #[test]
    fn a_refresh_stays_with_the_account_it_was_asked_for() {
        let lab = Lab::new();
        lab.automate();
        lab.uses("a", 100);
        let refresh = lab.asks(r#""operation":"refresh","previousSlot":"a","accountId":"a""#);
        // An account with nothing left still has its sign-in renewed.
        assert_eq!(slot(lab.given(&refresh)), "a");
        let busy_once = |id: &str, asked: &Asked, _: u64| {
            assert!(id == "a" && asked.refresh);
            if lab.reads("a") == 1 {
                failed("home_busy")
            } else {
                lab.fresh(id)
            }
        };
        assert_eq!(slot(lab.tried(&refresh, &busy_once)), "a");
        assert_eq!(lab.reads("a"), 2);
        // A lock that stays held is waited for less long than the bridge waits.
        let busy = |_: &str, _: &Asked, _: u64| failed("home_busy");
        assert_eq!(code(lab.tried(&refresh, &busy)), "routing_account_busy");
        assert!(lab.spent.get() >= 2500 && lab.spent.get() < REFRESH_BUDGET_MS);
        assert_eq!(lab.reads("b"), 0);
        // The account signed in at that home is not the one the session has.
        assert_eq!(code(lab.given(&lab.asks(r#""operation":"refresh","previousSlot":"a","accountId":"b""#))), "routing_refresh_failed");
        assert_eq!(code(lab.tried(&refresh, &|_, _, _| failed("authentication_required"))), "routing_refresh_failed");
        // An account the collector has not listed can be renewed all the same.
        lab.save("status.json", &obj! {"providers" => obj! {"codex" => obj! {"observedAt" => noon().o(), "slots" => Vec::<V>::new()}}});
        assert_eq!(slot(lab.given(&refresh)), "a");
    }

    #[test]
    fn what_cannot_be_trusted_is_refused() {
        let lab = Lab::new();
        lab.automate();
        lab.uses("a", 100);
        let request = lab.asks(r#""operation":"select""#);
        lab.accounts("disabled", vec![V::s_of("b")].into());
        assert_eq!(code(lab.given(&request)), "routing_unavailable");
        lab.accounts("disabled", Vec::<V>::new().into());
        // A snapshot an hour old, one from the future, and one that says no time.
        lab.collected("ok", 0, 3600);
        assert_eq!(code(lab.given(&request)), "routing_stale");
        lab.collected("ok", 0, -60);
        assert_eq!(code(lab.given(&request)), "routing_stale");
        lab.save("status.json", &obj! {"providers" => obj! {"codex" => obj! {"slots" => Vec::<V>::new()}}});
        assert_eq!(code(lab.given(&request)), "routing_stale");
        lab.collected("ok", 0, 0);
        assert_eq!(slot(lab.given(&request)), "b");
        // Two homes signed in as one subscription.
        lab.recorded(&[("b", "identityKey", "identity-a")]);
        assert_eq!(code(lab.given(&request)), "routing_duplicate_identity");
        // A record that belongs to another home leaves its account out.
        lab.recorded(&[("b", "binding", "changed")]);
        assert_eq!(code(lab.given(&request)), "routing_unavailable");
        lab.recorded(&[]);
        // A home signed in as someone else since the collector looked.
        let other = |id: &str, _: &Asked, _: u64| {
            let mut read = lab.fresh(id);
            if let Ok(account) = &mut read.outcome {
                account.identity_key = "identity-other".into();
            }
            read
        };
        assert_eq!(code(lab.tried(&request, &other)), "routing_unavailable");
        // Requests sent somewhere the user set.
        let elsewhere = |id: &str, _: &Asked, _: u64| {
            let mut read = lab.fresh(id);
            if let Ok(account) = &mut read.outcome {
                account.standard_transport = id != "b";
                account.model_provider = if id == "a" { "elsewhere".into() } else { String::new() };
            }
            read
        };
        assert_eq!(code(lab.tried(&request, &elsewhere)), "routing_unavailable");
        // A sign-in that was not answered.
        let unsigned = |id: &str, _: &Asked, _: u64| {
            let mut read = lab.fresh(id);
            if let Ok(account) = &mut read.outcome {
                account.auth = None;
            }
            read
        };
        assert_eq!(code(lab.tried(&request, &unsigned)), "routing_auth_unavailable");
        lab.conflicted.set(true);
        assert_eq!(code(lab.tried(&request, &|_, _, _| panic!("nothing is read"))), "routing_environment_conflict");
    }

    #[test]
    fn a_request_is_one_of_three_and_says_so() {
        let lab = Lab::new();
        let unexpected = |_: &str, _: &Asked, _: u64| -> HomeRead { panic!("nothing is read") };
        let asks = |members: &str| code(lab.tried(&json::parse_foreign(&format!("{{{members}}}")).ok().unwrap(), &unexpected));
        for members in [r#""operation":"choose""#, r#""intent":"admit""#, r#""operation":"select","intent":"move""#, r#""operation":"refresh","intent":"rebind""#, r#""operation":"exec","intent":"rebind""#] {
            assert_eq!(asks(members), "routing_invalid_request", "{members}");
        }
        for request in ["[]", r#""select""#, "7", "null"] {
            assert_eq!(code(lab.tried(&json::parse_foreign(request).ok().unwrap(), &unexpected)), "routing_invalid_request", "{request}");
        }
        // What is wrong with the request is said before what is wrong with the caller.
        lab.conflicted.set(true);
        assert_eq!(asks(r#""operation":"choose""#), "routing_invalid_request");
    }

    #[test]
    fn how_long_a_session_has_had_its_account_is_kept_while_it_keeps_it() {
        let lab = Lab::new();
        let since = |members: &str| lab.given(&lab.asks(members)).ok().unwrap().path(&["criticalState", "selectedAt"]).ok().unwrap().s().ok().unwrap();
        let earlier = "2026-10-07T11:00:00.000Z";
        assert_eq!(since(&format!(r#""operation":"select","previousSlot":"a","criticalState":{{"selected":"a","selectedAt":"{earlier}"}}"#)), earlier);
        // A session given another account, or one that never said, starts counting now.
        lab.uses("b", 100);
        assert_eq!(since(&format!(r#""operation":"select","previousSlot":"b","criticalState":{{"selected":"b","selectedAt":"{earlier}"}}"#)), noon().o());
        assert_eq!(since(r#""operation":"select","previousSlot":"a","criticalState":{"selected":"a"}"#), noon().o());
        assert_eq!(since(r#""operation":"select","previousSlot":"a""#), noon().o());
    }

    #[test]
    fn a_refusal_is_one_line_and_leaves_its_code_and_the_time() {
        let lab = Lab::new();
        let unexpected = |_: &str, _: &Asked, _: u64| -> HomeRead { panic!("nothing is read") };
        let answer = |line: Option<&str>| lab.route(&unexpected, |route| answered(route, line));
        let refused = |code: &str| (format!(r#"{{"error":"{code}"}}"#), false);
        assert_eq!(answer(None), refused("routing_invalid_request"));
        assert_eq!(answer(Some("")), refused("routing_invalid_request"));
        assert_eq!(answer(Some(&format!(r#"{{"operation":"select","cwd":"{}"}}"#, "c".repeat(LINE_UNITS)))), refused("routing_invalid_request"));
        assert_eq!(answer(Some("[]")), refused("routing_invalid_request"));
        assert_eq!(answer(Some("select")), refused("routing_failed"));
        assert_eq!(answer(Some(r#"{"operation":"select","operation":"exec"}"#)), refused("routing_failed"));
        // Settings HotPl8 would not have written are not acted on.
        lab.save("policy.json", &obj! {"schemaVersion" => 2, "mode" => "sideways"});
        assert_eq!(answer(Some(&lab.line(r#""operation":"select""#))), refused("routing_failed"));
        lab.save("policy.json", &lab.policy);
        // Someone else is inside the boundary every action is authorized in.
        let held = files::lock(&lab.directory.join("action-control.lock")).ok().unwrap();
        assert_eq!(answer(Some(&lab.line(r#""operation":"select""#))), refused("routing_control_unavailable"));
        drop(held);
        let events = lab.events();
        let codes: Vec<String> = events.iter().map(|line| json::parse(line, "").ok().unwrap().g("code").ok().unwrap().s().ok().unwrap()).collect();
        assert_eq!(codes, ["routing_invalid_request", "routing_invalid_request", "routing_invalid_request", "routing_invalid_request", "routing_failed", "routing_failed", "routing_failed", "routing_control_unavailable"]);
        for line in &events {
            let named: Vec<String> = json::parse(line, "").ok().unwrap().props().ok().unwrap().iter().map(|(name, _)| name.to_string()).collect();
            assert_eq!(named, ["at", "code"]);
        }
        // An account that is given is answered on one line, with its sign-in, and leaves none.
        let (line, given) = lab.route(&|id, _, _| lab.fresh(id), |route| answered(route, Some(&lab.line(r#""operation":"select""#))));
        assert!(given && !line.contains('\n') && line.starts_with(r#"{"slot":"a","home":"#) && line.ends_with(r#""auth":{"accessToken":"fixture-token-a","chatgptAccountId":"a"}}"#), "{}", line.replace("fixture-token-a", "..."));
        assert_eq!(lab.events().len(), events.len());
    }

    #[test]
    fn a_request_is_the_first_line_written() {
        let line = |written: &[u8]| asked_line(written);
        assert_eq!(line(b"{\"operation\":\"select\"}\nmore\n").as_deref(), Some(r#"{"operation":"select"}"#));
        assert_eq!(line(b"{}\r\n").as_deref(), Some("{}"));
        assert_eq!(line(b"{}").as_deref(), Some("{}"));
        assert_eq!(line(b"\xef\xbb\xbf{}\n").as_deref(), Some("{}"));
        assert_eq!(line(b"{}\xef\xbb\xbf\n").as_deref(), Some("{}\u{feff}"));
        assert_eq!(line(b"").as_deref(), Some(""));
        // As long as a request may be, in the longest letters there are, and one letter more.
        let long = |letters: usize| [b"\xef\xbb\xbf".to_vec(), "\u{20ac}".repeat(letters).into_bytes(), b"\r\n".to_vec()].concat();
        assert_eq!(line(&long(LINE_UNITS)).map(|line| length(&line)), Some(LINE_UNITS));
        assert_eq!(line(&long(LINE_UNITS + 1)), None);
        // A line that is not text is not a request, and is read as far as it is one.
        assert_eq!(line(b"\xff{}\n").as_deref(), Some("\u{fffd}{}"));
    }

    #[test]
    fn the_command_takes_each_of_its_words_once() {
        let words = |list: &[&str]| -> Vec<OsString> { list.iter().map(OsString::from).collect() };
        let place = std::env::temp_dir();
        let (root, state) = (place.join("release").to_string_lossy().into_owned(), place.join("state").to_string_lossy().into_owned());
        let started = spelled(&words(&["--state", &state, "--codex", "codex-stand-in", "--root", &root])).unwrap();
        assert_eq!((started.root, started.state, started.codex.as_deref()), (place.join("release"), place.join("state"), Some("codex-stand-in")));
        assert!(spelled(&words(&["--root", &root, "--state", &state])).unwrap().codex.is_none());
        for wrong in [&["--root", &root][..], &["--state", &state], &["--root", &root, "--state", &state, "--state", &state], &["--root", &root, "--state", &state, "--codex"], &["--root", &root, "--state", &state, "--refresh"]] {
            assert!(spelled(&words(wrong)).is_none(), "{wrong:?}");
        }
    }
}

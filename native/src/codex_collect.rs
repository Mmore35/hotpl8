//! One collection of the registered Codex accounts: what each account's limits say, which
//! account each meter would use, and what is kept for the next collection.

use crate::automation;
use crate::capacity::capacity_accounts;
use crate::codex::{codex_eligibility, select_codex_slot};
use crate::codex_read::{Account, HomeRead, READ_BUDGET_MS};
use crate::critical::critical_decision;
use crate::files;
use crate::json;
use crate::policy::{assert_codex_policy, home_path};
use crate::ps::*;
use crate::sha256;
use crate::time::Dto;
use crate::{hash, obj};
use std::io::Write;
use std::path::Path;

/// The meters HotPl8 measures. Any other limit an account reports is listed, unsupported.
const METERS: [&str; 2] = ["codex", "codex_bengalfox"];

/// A limit's name: 1 to 80 letters, digits, `_` or `-`.
fn limit_name(id: &str) -> bool {
    (1..=80).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A limit HotPl8 lists without measuring it.
fn unsupported(id: &str) -> V {
    obj! {"meter" => id, "status" => "unsupported", "windows" => obj! {}, "warm" => "unmeasured"}
}

/// `$value -eq $word` for a value that is one thing: a list or an object is no word.
fn says(value: &V, word: &V) -> R<bool> {
    match value {
        V::Arr(_) | V::Obj(_) | V::Hash(_) => Ok(false),
        one => one.eq(word),
    }
}

/// One measured limit, or `None` where the row does not hold what a measured limit holds.
fn measured(id: &str, row: &V, previous: &V, now: Dto) -> R<Option<V>> {
    if !row.is_obj() || !V::s_of(id).in_s(&METERS)? || !says(&row.g("limitId")?, &V::s_of(id))? {
        return Ok(None);
    }
    if !row.has("primary")? || !row.has("secondary")? {
        return Ok(None);
    }
    let now_seconds = V::I64(now.unix_seconds());
    let mut windows: Vec<(String, V)> = Vec::new();
    let mut full = false;
    for key in ["primary", "secondary"] {
        let window = row.g(key)?;
        if window.is_null() {
            continue;
        }
        let minutes = window.g("windowDurationMins")?;
        if !minutes.is_number() || !minutes.is_in_list(&[V::I32(300), V::I32(10080)])? {
            return Ok(None);
        }
        let duration = minutes.s()?;
        let used = window.g("usedPercent")?;
        if windows.iter().any(|(known, _)| *known == duration) || !used.is_number() || used.lt_i(0)? || used.gt_i(100)? {
            return Ok(None);
        }
        if !window.has("resetsAt")? {
            return Ok(None);
        }
        let resets = window.g("resetsAt")?;
        if !resets.is_null() {
            if !resets.is_number() || resets.le_i(0)? || resets.floor()?.ne(&resets)? {
                return Ok(None);
            }
            if catch(|| Dto::from_unix_seconds(resets.to_long()?))?.is_none() {
                return Ok(None);
            }
        }
        let mut anchor = "unconfirmed";
        let old = previous.gd(id)?.g("windows")?.gd(&duration)?;
        if !resets.is_null() && resets.le(&now_seconds)? {
            anchor = "expired";
        } else if old.t()? && !old.g("resetsAt")?.is_null() && used.gt_i(0)? && old.g("usedPercent")?.gt_i(0)? && old.g("resetsAt")?.sub(&resets)?.dbl()?.abs() <= 5.0 {
            // An earlier reading whose time cannot be read confirms nothing.
            let confirmed = catch(|| {
                let age = now.since(Dto::of_external(&old.g("observedAt")?)?).total_seconds();
                Ok(age >= 30.0 || (age >= 0.0 && old.g("anchorState")?.eq_s("observed-active")?))
            })?;
            if confirmed == Some(true) {
                anchor = "observed-active";
            }
        }
        let used = used.dbl()?;
        full = full || (used == 100.0 && !resets.is_null() && resets.gt(&now_seconds)?);
        let reading = obj! {
            "usedPercent" => dbl(used)?,
            "remainingPercent" => dbl(100.0 - used)?,
            "resetsAt" => resets,
            "anchorState" => anchor,
            "observedAt" => now.o(),
        };
        windows.push((duration, reading));
    }
    if windows.is_empty() {
        return Ok(None);
    }
    let spend = row.g("spendControlReached")?;
    let reached = row.g("rateLimitReachedType")?;
    let allowed = row.g("allowed")?;
    let refused = row.has("allowed")? && says(&allowed, &V::Bool(false))?;
    let mut state = "observed";
    if matches!(spend, V::Bool(true)) || !reached.is_null() {
        state = "blocked";
    }
    if spend.is_null() {
        state = "constraint_unknown";
    }
    if (!spend.is_null() && !spend.is_bool()) || (row.has("allowed")? && !allowed.is_bool()) {
        state = "unsupported";
    }
    if refused {
        state = "blocked";
    }
    let mut reason = V::Null;
    if state == "blocked" {
        reason = "restricted".into();
        if says(&reached, &"rate_limit_reached".into())? && matches!(spend, V::Bool(false)) && !refused && full {
            reason = "quota_exhausted".into();
        }
    }
    let warm = if windows.iter().any(|(duration, _)| duration == "300") { "unmeasured" } else { "not applicable: no five-hour window" };
    let windows = new_obj(windows.iter().map(|(duration, reading)| (duration.as_str(), reading.clone())).collect());
    Ok(Some(obj! {"meter" => id, "status" => state, "blockReason" => reason, "windows" => windows, "warm" => warm}))
}

/// ConvertTo-CodexBuckets: one account's limits, by the name the account gives each. A
/// row the rule cannot read (a list or an object where a number, a word or a yes-or-no
/// belongs) is listed as unsupported, like any other row that does not measure a limit.
pub fn codex_buckets(quota: &V, previous: &V, now: Dto) -> R<V> {
    if !quota.is_obj() {
        return Ok(obj! {});
    }
    let mut map = quota.g("rateLimitsByLimitId")?;
    if map.is_null() {
        let single = quota.g("rateLimits")?;
        let id = if single.is_obj() { single.g("limitId")? } else { V::Null };
        if id.is_arr() || id.is_obj() || !id.t()? {
            return Ok(obj! {});
        }
        map = new_obj(vec![(id.s()?.as_str(), single)]);
    }
    if !map.is_obj() {
        return Ok(obj! {});
    }
    let mut result: Vec<(String, V)> = Vec::new();
    for (id, row) in map.props()? {
        if !limit_name(&id) {
            continue;
        }
        let bucket = match measured(&id, &row, previous, now) {
            Ok(Some(bucket)) => bucket,
            Ok(None) => unsupported(&id),
            Err(stop) if !stop.thrown() => unsupported(&id),
            Err(stop) => return Err(stop),
        };
        result.push((id.to_string(), bucket));
    }
    Ok(new_obj(result.iter().map(|(id, bucket)| (id.as_str(), bucket.clone())).collect()))
}

/// One collection is given this long. An account it has no time left for is read first
/// by the next.
const BUDGET_MS: i64 = 20_000;

/// A home another reader holds is asked for again after this long.
const BUSY_PAUSE_MS: i64 = 75;

/// The history is cut back once it passes the first size, to its last lines that fit the second.
const HISTORY_LIMIT: u64 = 4_194_304;
const HISTORY_KEPT: usize = 2_097_152;
const HISTORY_LINES: usize = 256;

/// What one collection is given.
pub struct Collection<'a> {
    /// The provider's own part of the policy.
    pub policy: &'a V,
    /// Where the provider keeps what it remembers between collections.
    pub state: &'a Path,
    /// The state directory, where a hold is kept.
    pub control: &'a Path,
    /// What the snapshot before this one shows for the provider.
    pub previous: &'a V,
    /// Reads one account's home within so many milliseconds.
    pub read: &'a dyn Fn(&str, u64) -> HomeRead,
    pub clock: &'a dyn Fn() -> R<Dto>,
    /// Milliseconds since the collection began.
    pub elapsed: &'a dyn Fn() -> i64,
    /// Waits so many milliseconds.
    pub pause: &'a dyn Fn(u64),
}

/// `$value.name`, for a value read from a file: only an object has members.
fn member(value: &V, name: &str) -> V {
    if value.is_obj() {
        value.gd(name).unwrap_or(V::Null)
    } else {
        V::Null
    }
}

/// What the last collection kept of an account, when it is what a collection writes and
/// was written for this home. Anything else is no record, and the account starts over.
fn kept(state: &V, id: &str, binding: &str) -> V {
    let record = member(&member(state, "slots"), id);
    let text = |name: &str| matches!(member(&record, name), V::Null | V::Str(_));
    let whole = ["identityKey", "lastAttemptAt", "lastSuccessAt", "retryAfter", "planType", "previousPlanType", "planChangedAt"].into_iter().all(text)
        && matches!(member(&record, "buckets"), V::Null | V::Obj(_))
        && member(&record, "binding").as_str().is_some_and(|known| known.eq_ignore_ascii_case(binding));
    if whole {
        record
    } else {
        V::Null
    }
}

/// When a text a collection wrote says, if it says.
fn instant(value: &V) -> Option<Dto> {
    Dto::parse_external(value.as_str()?).ok()
}

/// Reads one account inside what is left of the collection's time. A home someone else is
/// reading (starting a session holds it for some seconds) is waited for inside that time
/// rather than shown as busy.
fn read_within(c: &Collection, home: &str) -> HomeRead {
    let began = (c.elapsed)();
    let budget = (BUDGET_MS - began).min(READ_BUDGET_MS as i64);
    loop {
        let left = (budget - ((c.elapsed)() - began)).max(1);
        let read = (c.read)(home, left as u64);
        if !matches!(read.outcome, Err("home_busy")) || (c.elapsed)() - began + BUSY_PAUSE_MS >= budget {
            return read;
        }
        (c.pause)(BUSY_PAUSE_MS as u64);
        // A busy machine can oversleep; no read is started past the budget.
        if (c.elapsed)() - began >= budget {
            return read;
        }
    }
}

/// Keeps the history of what was read, which reset experiments and soak audits use: one
/// line a collection, limits only. Nothing depends on it, so nothing that goes wrong
/// with it is a failure.
fn remember(directory: &Path, result: &V) {
    let path = directory.join("codex-observations.jsonl");
    if std::fs::metadata(&path).is_ok_and(|file| file.len() > HISTORY_LIMIT) {
        let Ok(bytes) = std::fs::read(&path) else { return };
        let text = String::from_utf8_lossy(bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes)).into_owned();
        let all: Vec<&str> = text.lines().collect();
        let mut tail = &all[all.len().saturating_sub(HISTORY_LINES)..];
        while tail.len() > 1 && tail.iter().map(|line| line.len() + 1).sum::<usize>() - 1 > HISTORY_KEPT {
            tail = &tail[1..];
        }
        if files::write_text(&path, &(tail.join("\n") + "\n"), true).is_err() {
            return;
        }
    }
    let Ok(line) = json::compact(result, 24) else { return };
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = file.write_all(format!("{line}\n").as_bytes());
    }
}

/// Every account of one Codex provider read once, and what the provider would use for
/// each meter.
pub fn collect(c: &Collection) -> R<V> {
    let policy = c.policy;
    assert_codex_policy(policy)?;
    let state_path = c.state.join("codex-state.json");
    let state = json::read_or_null(&state_path);
    let Some(directory) = c.state.to_str() else { return unreadable() };
    let now = (c.clock)()?.utc();
    // Oldest attempt first, so a slow large fleet cannot starve its last accounts. One
    // never attempted comes before all, and accounts attempted together keep their order.
    let mut queue = policy.g("slots")?.arr();
    let attempted = |slot: &V| {
        let id = slot.g("id").ok()?;
        Some(instant(&member(&member(&member(&state, "slots"), id.as_str()?), "lastAttemptAt"))?.ticks)
    };
    queue.sort_by_key(attempted);
    let disabled = policy.g("disabled")?.each();
    let reserve = policy.g("reserve")?.each();
    let mut slots: Vec<V> = Vec::new();
    let mut next: Vec<(String, V)> = Vec::new();
    for slot in &queue {
        let id = slot.g("id")?.s()?;
        let home = slot.g("home")?.s()?;
        let binding = sha256::hash(&home_path(&home)?);
        let old = kept(&state, &id, &binding);
        let unread = |status: &'static str| HomeRead { elapsed_ms: 0, outcome: Err(status) };
        let read = if V::s_of(&id).is_in_list(&disabled)? {
            unread("disabled")
        } else if (c.elapsed)() >= BUDGET_MS {
            unread("collection_budget")
        } else if instant(&member(&old, "retryAfter")).is_some_and(|retry| retry.ticks > now.ticks) {
            unread("backoff")
        } else {
            read_within(c, &home)
        };
        // Collection and dispatch must agree about what the subscription read can serve.
        // An address or a provider the user set is not a subscription's own account.
        let status = match &read.outcome {
            Ok(account) if !account.standard_transport || !(account.model_provider.is_empty() || account.model_provider.eq_ignore_ascii_case("openai")) => "unsupported_configuration",
            Ok(_) => "ok",
            Err(name) => name,
        };
        let observed = (c.clock)()?.utc();
        let [mut buckets, mut last_success, mut identity, mut plan, mut previous_plan, mut plan_changed] =
            ["buckets", "lastSuccessAt", "identityKey", "planType", "previousPlanType", "planChangedAt"].map(|name| member(&old, name));
        if let (Ok(account), "ok") = (&read.outcome, status) {
            let same = identity.as_str().is_some_and(|known| !known.is_empty() && known.eq_ignore_ascii_case(&account.identity_key));
            buckets = codex_buckets(&account.quota, if same { &buckets } else { &V::Null }, observed)?;
            // A plan that changes on one subscription is the evidence a lapse leaves
            // behind. Another sign-in in this home starts a new record instead.
            let known = plan.as_str().filter(|known| !known.is_empty()).map(str::to_string);
            let read_plan = account.plan_type.as_str();
            if !same {
                (previous_plan, plan_changed) = (V::Null, V::Null);
            } else if let Some(known) = known.as_ref().filter(|known| !known.eq_ignore_ascii_case("unknown") && read_plan != "unknown" && read_plan != known.as_str()) {
                (previous_plan, plan_changed) = (known.as_str().into(), observed.o().into());
            }
            if read_plan != "unknown" || !same || known.is_none() {
                plan = read_plan.into();
            }
            last_success = observed.o().into();
            identity = account.identity_key.as_str().into();
        }
        let attempt = if ["collection_budget", "backoff"].contains(&status) { member(&old, "lastAttemptAt") } else { observed.o().into() };
        let retry = match status {
            "rate_limited" => observed.plus_seconds(300)?.o().into(),
            "backoff" => member(&old, "retryAfter"),
            _ => V::Null,
        };
        let label = slot.g("label")?;
        let account = read.outcome.as_ref().ok();
        let said = |of: fn(&Account) -> &String| account.map_or("", |account| of(account).as_str());
        // The stream's name is a local pseudonym for status, never the key a sign-in is bound by.
        let stream = sha256::hash(&format!("{directory}|usage|{}", identity.s()?));
        slots.push(obj! {
            "id" => id.as_str(),
            "label" => if label.t()? { label.s()? } else { id.clone() },
            "status" => status,
            "observedAt" => &last_success,
            "lastAttemptAt" => &attempt,
            "elapsedMs" => read.elapsed_ms,
            "buckets" => &buckets,
            "planType" => account.map_or(V::Null, |account| account.plan_type.as_str().into()),
            "defaultModel" => said(|account| &account.model),
            "modelProvider" => said(|account| &account.model_provider),
            "streamKey" => stream,
        });
        let record = obj! {
            "binding" => binding,
            "identityKey" => identity,
            "lastAttemptAt" => attempt,
            "lastSuccessAt" => last_success,
            "buckets" => buckets,
            "retryAfter" => retry,
            "planType" => plan,
            "previousPlanType" => previous_plan,
            "planChangedAt" => plan_changed,
        };
        next.push((id, record));
    }
    // Two homes signed in to one subscription are not two lots of capacity.
    let mut first: Vec<(String, &V)> = Vec::new();
    for (slot, (_, record)) in slots.iter().zip(&next) {
        let identity = record.g("identityKey")?;
        let (true, Some(identity)) = (slot.g("status")?.eq_s("ok")?, identity.as_str().filter(|identity| !identity.is_empty())) else { continue };
        match first.iter().find(|(known, _)| known.eq_ignore_ascii_case(identity)) {
            Some((_, other)) => {
                slot.set("status", "duplicate_subscription".into())?;
                other.set("status", "duplicate_subscription".into())?;
            }
            None => first.push((identity.to_string(), slot)),
        }
    }
    let hold = match automation::hold(c.control, (c.clock)()?) {
        Some(hold) => obj! {"until" => hold.until.o(), "reason" => hold.reason},
        None => V::Null,
    };
    let snapshot = obj! {"providers" => hash! {"codex" => hash! {"slots" => slots.clone()}}};
    let mut recommendations: Vec<(&str, V)> = Vec::new();
    let mut critical: Vec<(&str, V)> = Vec::new();
    let mut decisions: Vec<V> = Vec::new();
    for meter in METERS {
        let prior = member(&member(c.previous, "recommendations"), meter);
        let state = member(&member(c.previous, "critical"), meter);
        let selected = select_codex_slot(&slots, policy, meter, &prior.s()?, &hold, (c.clock)()?.utc(), &state)?;
        let decision = critical_decision(&capacity_accounts(&snapshot, policy, "codex", now, meter, false)?, policy, &prior.s()?, &state, now)?;
        decision.set("selected", selected.clone())?;
        if selected.ne(&prior)? {
            decision.set("selectedAt", now.o().into())?;
        }
        let emergency = decision.g("active")?.t()?;
        let mut accounts = Vec::new();
        for slot in &slots {
            let id = slot.g("id")?;
            accounts.push(obj! {"slot" => &id, "reason" => codex_eligibility(slot, policy, meter, now, emergency)?, "reserve" => id.is_in_list(&reserve)?});
        }
        decisions.push(obj! {"meter" => meter, "selected" => &selected, "policy" => policy.g("order")?, "accounts" => accounts});
        recommendations.push((meter, selected));
        critical.push((meter, decision));
    }
    let named = policy.g("defaultMeter")?;
    let default = if named.t()? { named.s()? } else { "codex".to_string() };
    let recommended = recommendations.iter().find(|(meter, _)| meter.eq_ignore_ascii_case(&default)).map_or(V::Null, |(_, selected)| selected.clone());
    let result = obj! {
        "status" => "observed",
        "observedAt" => (c.clock)()?.utc().o(),
        "defaultMeter" => default,
        "recommendations" => new_obj(recommendations),
        "recommendedSlot" => recommended,
        "slots" => slots,
        "warm" => "unmeasured: automatic Codex warming unavailable",
        "hold" => hold,
        "elapsedMs" => (c.elapsed)(),
        "critical" => new_obj(critical),
        "decisions" => decisions,
    };
    let slots = new_obj(next.iter().map(|(id, record)| (id.as_str(), record.clone())).collect());
    files::write_json(&state_path, &obj! {"schemaVersion" => 1, "slots" => slots}, 24)?;
    remember(c.state, &result);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::scratch;
    use std::cell::{Cell, RefCell};
    use std::path::PathBuf;

    /// tests/parity/codex-buckets.json holds what PowerShell's rule answered for each
    /// case; tests/test-codex.ps1 holds PowerShell's rule to the same file.
    #[test]
    fn limits_read_as_the_shared_cases_say() {
        set_core(false);
        let cases = json::parse(include_str!("../../tests/parity/codex-buckets.json"), "codex-buckets.json").ok().unwrap();
        let cases = cases.g("cases").ok().unwrap().arr();
        assert!(cases.len() > 100);
        let mut wrong = Vec::new();
        for case in &cases {
            let field = |name: &str| case.g(name).ok().unwrap();
            let now = Dto::of(&field("now")).ok().unwrap();
            let answer = match codex_buckets(&field("quota"), &field("previous"), now) {
                Ok(buckets) => json::compact(&buckets, 12).ok().unwrap(),
                Err(stop) => format!("stopped: {}", stop.message()),
            };
            let expected = json::compact(&field("expected"), 12).ok().unwrap();
            if answer != expected {
                wrong.push(format!("{}\n  expected {expected}\n  answered {answer}", field("name").s().ok().unwrap()));
            }
        }
        assert!(wrong.is_empty(), "{} of {} cases differ:\n{}", wrong.len(), cases.len(), wrong.join("\n"));
    }

    const NOON: &str = "2026-10-07T12:00:00.0000000+00:00";

    /// One provider's collections in a directory of their own. No Codex is started: each
    /// test says what a read answers. Time passes only as a test says, `clock` being the
    /// hour it is and `spent` the milliseconds the collection has used.
    struct Lab {
        directory: PathBuf,
        clock: Cell<Dto>,
        spent: Cell<i64>,
        pauses: Cell<u32>,
        /// How much longer than asked each pause lasts.
        oversleep: Cell<i64>,
    }

    impl Lab {
        fn new() -> Lab {
            set_core(false);
            Lab { directory: scratch("codex-collect"), clock: Cell::new(Dto::parse(NOON).ok().unwrap()), spent: Cell::new(0), pauses: Cell::new(0), oversleep: Cell::new(0) }
        }

        fn home(&self, id: &str) -> String {
            self.directory.join(format!("home-{id}")).to_string_lossy().into_owned()
        }

        /// A policy of the accounts named, in that order, and whatever `more` sets.
        fn policy(&self, ids: &[&str], more: Vec<(&str, V)>) -> V {
            let slots: Vec<V> = ids.iter().map(|id| obj! {"id" => *id, "home" => self.home(id)}).collect();
            let prefer: Vec<V> = ids.iter().map(|id| V::s_of(id)).collect();
            let policy = obj! {"slots" => slots, "prefer" => prefer, "reserve" => Vec::<V>::new(), "order" => "soonest-reset", "margin5h" => 25, "margin7d" => 20, "margin7dWork" => 5};
            for (name, value) in more {
                policy.add_member(name, value, true).ok().unwrap();
            }
            policy
        }

        fn pass(&self, seconds: i64) {
            self.clock.set(self.clock.get().plus_seconds(seconds).ok().unwrap());
        }

        fn now(&self) -> String {
            self.clock.get().o()
        }

        fn tried(&self, policy: &V, previous: &V, read: &dyn Fn(&str, u64) -> HomeRead) -> R<V> {
            self.spent.set(0);
            self.pauses.set(0);
            collect(&Collection {
                policy,
                state: &self.directory,
                control: &self.directory,
                previous,
                read,
                clock: &|| Ok(self.clock.get()),
                elapsed: &|| self.spent.get(),
                pause: &|milliseconds| {
                    self.spent.set(self.spent.get() + milliseconds as i64 + self.oversleep.get());
                    self.pauses.set(self.pauses.get() + 1);
                },
            })
        }

        fn collect(&self, policy: &V, previous: &V, read: &dyn Fn(&str, u64) -> HomeRead) -> V {
            match self.tried(policy, previous, read) {
                Ok(result) => result,
                Err(stop) => panic!("the collection stopped: {}", stop.message()),
            }
        }

        fn state(&self) -> PathBuf {
            self.directory.join("codex-state.json")
        }

        /// What the collection keeps of one account.
        fn kept(&self, id: &str, name: &str) -> String {
            at(&json::read_or_null(&self.state()), &["slots", id, name])
        }

        /// The key a record is bound to its home by.
        fn binding(&self, id: &str) -> String {
            sha256::hash(&home_path(&self.home(id)).ok().unwrap())
        }

        /// Leaves a record of account `a` as the last collection's, `changed` in place
        /// of what a collection writes for those members.
        fn leave(&self, changed: &[(&str, &str)]) {
            let usual = [
                ("binding", json::text(&self.binding("a"))),
                ("identityKey", r#""a""#.to_string()),
                ("lastAttemptAt", format!(r#""{NOON}""#)),
                ("lastSuccessAt", format!(r#""{NOON}""#)),
                ("buckets", "null".to_string()),
                ("retryAfter", "null".to_string()),
                ("planType", r#""plus""#.to_string()),
                ("previousPlanType", "null".to_string()),
                ("planChangedAt", "null".to_string()),
            ];
            let members: Vec<String> =
                usual.iter().map(|(name, usual)| format!(r#""{name}":{}"#, changed.iter().find(|(known, _)| known == name).map_or(usual.as_str(), |(_, own)| own))).collect();
            std::fs::write(self.state(), format!(r#"{{"schemaVersion":1,"slots":{{"a":{{{}}}}}}}"#, members.join(","))).unwrap();
        }
    }

    /// The account a home in a `Lab` belongs to.
    fn of(home: &str) -> &str {
        home.rsplit('-').next().unwrap()
    }

    /// What a signed-in account answers: one weekly window, `used` percent of it spent.
    fn account(identity: &str, plan: &str, used: i32) -> HomeRead {
        let quota = format!(r#"{{"rateLimits":{{"limitId":"codex","primary":{{"usedPercent":{used},"windowDurationMins":10080,"resetsAt":1791720000}},"secondary":null,"spendControlReached":false}}}}"#);
        let quota = json::parse(&quota, "").ok().unwrap();
        HomeRead { elapsed_ms: 40, outcome: Ok(Account { quota, identity_key: identity.into(), plan_type: plan.into(), model: "gpt-fixture".into(), model_provider: "openai".into(), standard_transport: true }) }
    }

    fn failed(name: &'static str) -> HomeRead {
        HomeRead { elapsed_ms: 5, outcome: Err(name) }
    }

    /// What `value` holds along `path`, as JSON.
    fn at(value: &V, path: &[&str]) -> String {
        json::compact(&value.path(path).ok().unwrap(), 24).ok().unwrap()
    }

    /// One account's row in what a collection answers.
    fn row(result: &V, id: &str) -> V {
        result.g("slots").ok().unwrap().arr().into_iter().find(|slot| slot.g("id").ok().unwrap().as_str() == Some(id)).unwrap()
    }

    /// The accounts in the order a collection read them, each with how its read went.
    fn went(result: &V) -> String {
        let rows = result.g("slots").ok().unwrap().arr();
        rows.iter().map(|slot| format!("{} {}", slot.g("id").ok().unwrap().s().ok().unwrap(), slot.g("status").ok().unwrap().s().ok().unwrap())).collect::<Vec<_>>().join(", ")
    }

    #[test]
    fn every_account_is_read_once_and_one_is_recommended() {
        let lab = Lab::new();
        let policy = lab.policy(&["a", "b"], vec![("reserve", vec![V::s_of("b")].into())]);
        policy.g("slots").ok().unwrap().arr()[0].add_member("label", "First".into(), true).ok().unwrap();
        let asked = RefCell::new(Vec::new());
        let first = lab.collect(&policy, &V::Null, &|home, budget| {
            asked.borrow_mut().push((of(home).to_string(), budget));
            lab.spent.set(lab.spent.get() + 40);
            account(of(home), "plus", 10)
        });
        assert_eq!(*asked.borrow(), [("a".to_string(), 12_000), ("b".to_string(), 12_000)]);
        let window = format!(r#"{{"usedPercent":10,"remainingPercent":90,"resetsAt":1791720000,"anchorState":"unconfirmed","observedAt":"{NOON}"}}"#);
        let buckets = format!(r#"{{"codex":{{"meter":"codex","status":"observed","blockReason":null,"windows":{{"10080":{window}}},"warm":"not applicable: no five-hour window"}}}}"#);
        let stream = sha256::hash(&format!("{}|usage|a", lab.directory.to_str().unwrap()));
        assert_eq!(
            at(&first, &[]),
            format!(
                concat!(
                    r#"{{"status":"observed","observedAt":"{now}","defaultMeter":"codex","recommendations":{{"codex":"a","codex_bengalfox":null}},"recommendedSlot":"a","#,
                    r#""slots":[{{"id":"a","label":"First","status":"ok","observedAt":"{now}","lastAttemptAt":"{now}","elapsedMs":40,"buckets":{buckets},"planType":"plus","defaultModel":"gpt-fixture","modelProvider":"openai","streamKey":"{stream}"}},"#,
                    r#"{b}],"warm":"unmeasured: automatic Codex warming unavailable","hold":null,"elapsedMs":80,"critical":{critical},"decisions":[{{"meter":"codex","selected":"a","policy":"soonest-reset","accounts":[{{"slot":"a","reason":"eligible","reserve":false}},{{"slot":"b","reason":"eligible","reserve":true}}]}},"#,
                    r#"{{"meter":"codex_bengalfox","selected":null,"policy":"soonest-reset","accounts":[{{"slot":"a","reason":"meter_unknown","reserve":false}},{{"slot":"b","reason":"meter_unknown","reserve":true}}]}}]}}"#
                ),
                now = NOON,
                buckets = buckets,
                stream = stream,
                b = at(&row(&first, "b"), &[]),
                critical = at(&first, &["critical"]),
            )
        );
        assert_eq!(at(&row(&first, "b"), &["label"]), r#""b""#);
        assert_eq!(at(&first, &["critical", "codex", "selected"]), r#""a""#);
        assert_eq!(at(&first, &["critical", "codex", "selectedAt"]), format!(r#""{NOON}""#));
        // What binds a record to its sign-in and its home is kept, and is shown to no one.
        assert!(!at(&first, &[]).contains("identityKey") && !at(&first, &[]).contains(&lab.binding("a")));
        assert_eq!(lab.kept("a", "binding"), json::text(&lab.binding("a")));
        assert_eq!(lab.kept("a", "identityKey"), r#""a""#);
        assert_eq!(lab.kept("b", "buckets"), buckets);
        let history = std::fs::read_to_string(lab.directory.join("codex-observations.jsonl")).unwrap();
        assert_eq!(history, at(&first, &[]) + "\n");

        // A choice that stands keeps the time it was made.
        lab.pass(60);
        let second = lab.collect(&policy, &first, &|home, _| account(of(home), "plus", 10));
        assert_eq!(at(&second, &["critical", "codex", "selectedAt"]), format!(r#""{NOON}""#));
        assert_eq!(std::fs::read_to_string(lab.directory.join("codex-observations.jsonl")).unwrap().lines().count(), 2);
    }

    #[test]
    fn the_account_attempted_longest_ago_is_read_first() {
        let lab = Lab::new();
        // A second passes during each read.
        let read = |home: &str, _: u64| {
            lab.pass(1);
            account(of(home), "plus", 10)
        };
        assert_eq!(went(&lab.collect(&lab.policy(&["a", "b"], vec![]), &V::Null, &read)), "a ok, b ok");
        assert_eq!(went(&lab.collect(&lab.policy(&["c", "b", "a"], vec![]), &V::Null, &read)), "c ok, a ok, b ok");

        // Accounts attempted in the same instant keep the policy's order.
        let still = Lab::new();
        let read = |home: &str, _: u64| account(of(home), "plus", 10);
        still.collect(&still.policy(&["a", "b", "c"], vec![]), &V::Null, &read);
        assert_eq!(went(&still.collect(&still.policy(&["c", "a", "b"], vec![]), &V::Null, &read)), "c ok, a ok, b ok");

        // The order is the instants', whatever zone each was written in.
        let zoned = Lab::new();
        std::fs::write(zoned.state(), r#"{"slots":{"a":{"lastAttemptAt":"2026-10-07T13:00:00.0000000+02:00"},"b":{"lastAttemptAt":"2026-10-07T11:30:00.0000000+00:00"}}}"#).unwrap();
        assert_eq!(went(&zoned.collect(&zoned.policy(&["b", "a"], vec![]), &V::Null, &read)), "a ok, b ok");
    }

    #[test]
    fn an_account_is_not_read_while_it_is_disabled_backing_off_or_out_of_time() {
        let lab = Lab::new();
        let policy = lab.policy(&["a", "b", "c", "d"], vec![("disabled", vec![V::s_of("d")].into())]);
        let asked = RefCell::new(Vec::new());
        // The first account is told to slow down, and the second uses up the collection's time.
        let read = |home: &str, _: u64| {
            asked.borrow_mut().push(of(home).to_string());
            match (of(home), asked.borrow().len()) {
                ("a", 1) => failed("rate_limited"),
                ("b", 2) => {
                    lab.spent.set(20_000);
                    account("b", "plus", 10)
                }
                (id, _) => account(id, "plus", 10),
            }
        };
        let first = lab.collect(&policy, &V::Null, &read);
        assert_eq!(went(&first), "a rate_limited, b ok, c collection_budget, d disabled");
        assert_eq!(*asked.borrow(), ["a", "b"]);
        assert_eq!(at(&row(&first, "c"), &["lastAttemptAt"]), "null");
        assert_eq!(at(&row(&first, "d"), &["lastAttemptAt"]), format!(r#""{NOON}""#));
        assert_eq!(lab.kept("a", "retryAfter"), r#""2026-10-07T12:05:00.0000000+00:00""#);

        // Four minutes on the first is still left alone, and the one there was no time for goes first.
        lab.pass(240);
        let second = lab.collect(&policy, &first, &read);
        assert_eq!(went(&second), "c ok, a backoff, b ok, d disabled");
        assert_eq!(asked.borrow()[2..], ["c", "b"]);
        assert_eq!(at(&row(&second, "a"), &["lastAttemptAt"]), format!(r#""{NOON}""#));
        assert_eq!(lab.kept("a", "retryAfter"), r#""2026-10-07T12:05:00.0000000+00:00""#);

        lab.pass(120);
        let third = lab.collect(&policy, &second, &read);
        assert_eq!(went(&third), "a ok, b ok, c ok, d disabled");
        assert_eq!(lab.kept("a", "retryAfter"), "null");
    }

    #[test]
    fn a_busy_home_is_asked_again_inside_its_time() {
        let lab = Lab::new();
        let policy = lab.policy(&["a", "b"], vec![]);
        let asked = RefCell::new(Vec::new());
        let lets_go_after = Cell::new(3);
        // Each try takes five milliseconds, and another reader holds the first home for a while.
        let read = |home: &str, budget: u64| {
            lab.spent.set(lab.spent.get() + 5);
            asked.borrow_mut().push((of(home).to_string(), budget));
            if of(home) == "a" && asked.borrow().len() < lets_go_after.get() {
                return failed("home_busy");
            }
            account(of(home), "plus", 10)
        };
        assert_eq!(went(&lab.collect(&policy, &V::Null, &read)), "a ok, b ok");
        assert_eq!(*asked.borrow(), [("a".to_string(), 12_000), ("a".to_string(), 11_920), ("a".to_string(), 11_840), ("b".to_string(), 12_000)]);
        assert_eq!(lab.pauses.get(), 2);

        // A home held throughout is shown as busy inside one read's time, and the next account is still read.
        asked.borrow_mut().clear();
        lets_go_after.set(usize::MAX);
        lab.pass(60);
        assert_eq!(went(&lab.collect(&policy, &V::Null, &read)), "a home_busy, b ok");
        assert_eq!(asked.borrow().len(), 151);
        assert_eq!(asked.borrow()[149..], [("a".to_string(), 80), ("b".to_string(), 8_075)]);

        // A pause that lasts too long starts no read past the time there is.
        asked.borrow_mut().clear();
        lab.oversleep.set(20_000);
        lab.pass(60);
        assert_eq!(went(&lab.collect(&policy, &V::Null, &read)), "a home_busy, b collection_budget");
        assert_eq!(*asked.borrow(), [("a".to_string(), 12_000)]);
    }

    #[test]
    fn only_a_subscriptions_own_transport_is_a_recommendation() {
        let lab = Lab::new();
        let set = |provider: &str, standard: bool| {
            let mut read = account("one", "plus", 10);
            let account = read.outcome.as_mut().ok().unwrap();
            (account.model_provider, account.standard_transport) = (provider.into(), standard);
            read
        };
        let read = |home: &str, _: u64| match of(home) {
            "a" => set("openai", false),
            "b" => set("other", true),
            "c" => set("OpenAI", true),
            _ => set("", true),
        };
        let result = lab.collect(&lab.policy(&["a", "b", "c", "d"], vec![]), &V::Null, &read);
        // The last two are one subscription, which this test does not ask about.
        assert_eq!(went(&result), "a unsupported_configuration, b unsupported_configuration, c duplicate_subscription, d duplicate_subscription");
        // What the home says of itself is shown; its limits are not taken as a subscription's.
        let b = row(&result, "b");
        assert_eq!(
            [at(&b, &["planType"]), at(&b, &["defaultModel"]), at(&b, &["modelProvider"]), at(&b, &["buckets"]), at(&b, &["observedAt"])],
            [r#""plus""#, r#""gpt-fixture""#, r#""other""#, "null", "null"]
        );
        assert_eq!(lab.kept("b", "identityKey"), "null");
        assert_eq!(at(&lab.collect(&lab.policy(&["a", "b"], vec![]), &V::Null, &read), &["recommendedSlot"]), "null");
    }

    #[test]
    fn what_was_last_read_is_kept_when_a_read_fails() {
        let lab = Lab::new();
        let policy = lab.policy(&["a", "b"], vec![]);
        let first = lab.collect(&policy, &V::Null, &|home, _| account(of(home), "plus", 10));
        lab.pass(60);
        let later = lab.now();
        let second = lab.collect(&policy, &first, &|home, _| if of(home) == "a" { failed("authentication_required") } else { account("b", "plus", 10) });
        assert_eq!(went(&second), "a authentication_required, b ok");
        let a = row(&second, "a");
        assert_eq!([at(&a, &["observedAt"]), at(&a, &["lastAttemptAt"])], [json::text(NOON), json::text(&later)]);
        assert_eq!(at(&a, &["buckets"]), at(&row(&first, "a"), &["buckets"]));
        assert_eq!([at(&a, &["planType"]), at(&a, &["defaultModel"]), at(&a, &["elapsedMs"])], ["null", r#""""#, "5"]);
        assert_eq!(at(&a, &["streamKey"]), at(&row(&first, "a"), &["streamKey"]));
        assert_eq!([lab.kept("a", "planType"), lab.kept("a", "lastSuccessAt")], [r#""plus""#.to_string(), json::text(NOON)]);
        // The choice moves, and says when.
        assert_eq!(at(&second, &["recommendedSlot"]), r#""b""#);
        assert_eq!(at(&second, &["critical", "codex", "selectedAt"]), json::text(&later));
        assert_eq!(at(&second, &["decisions"]).matches(r#"{"slot":"a","reason":"authentication_required","reserve":false}"#).count(), 2);
    }

    #[test]
    fn a_record_follows_the_sign_in_it_was_read_from() {
        let lab = Lab::new();
        let policy = lab.policy(&["a"], vec![]);
        let anchor = |result: &V| at(&row(result, "a"), &["buckets", "codex", "windows", "10080", "anchorState"]);
        let plans = || [lab.kept("a", "planType"), lab.kept("a", "previousPlanType"), lab.kept("a", "planChangedAt")];
        assert_eq!(anchor(&lab.collect(&policy, &V::Null, &|_, _| account("one", "plus", 10))), r#""unconfirmed""#);
        assert_eq!(plans(), [r#""plus""#, "null", "null"]);

        // The same sign-in, a minute on: its reset is one seen before, and its plan has changed.
        lab.pass(60);
        let changed = lab.now();
        let second = lab.collect(&policy, &V::Null, &|_, _| account("ONE", "pro", 10));
        assert_eq!(anchor(&second), r#""observed-active""#);
        assert_eq!(plans(), [r#""pro""#.to_string(), r#""plus""#.to_string(), json::text(&changed)]);

        // A read that names no plan leaves the plan known.
        lab.pass(60);
        let third = lab.collect(&policy, &V::Null, &|_, _| account("one", "unknown", 10));
        assert_eq!(at(&row(&third, "a"), &["planType"]), r#""unknown""#);
        assert_eq!(plans(), [r#""pro""#.to_string(), r#""plus""#.to_string(), json::text(&changed)]);

        // Another sign-in in the same home starts the record again.
        lab.pass(60);
        let fourth = lab.collect(&policy, &V::Null, &|_, _| account("two", "plus", 10));
        assert_eq!(anchor(&fourth), r#""unconfirmed""#);
        assert_eq!(plans(), [r#""plus""#, "null", "null"]);
        assert_ne!(at(&row(&fourth, "a"), &["streamKey"]), at(&row(&third, "a"), &["streamKey"]));
    }

    #[test]
    fn a_record_that_is_not_this_homes_starts_over() {
        let lab = Lab::new();
        let policy = lab.policy(&["a"], vec![]);
        let asked = Cell::new(0);
        // What is left of the last success, after a read that fails.
        let left = |changed: &[(&str, &str)]| {
            lab.leave(changed);
            at(&row(&lab.collect(&policy, &V::Null, &|_, _| {
                asked.set(asked.get() + 1);
                failed("authentication_required")
            }), "a"), &["observedAt"])
        };
        assert_eq!(left(&[]), json::text(NOON));
        assert_eq!(left(&[("binding", &json::text(&lab.binding("a").to_uppercase()))]), json::text(NOON));
        // Written for another home, or not what a collection writes.
        assert_eq!(left(&[("binding", &json::text(&lab.binding("b")))]), "null");
        assert_eq!(lab.kept("a", "binding"), json::text(&lab.binding("a")));
        assert_eq!(left(&[("binding", "null")]), "null");
        assert_eq!(left(&[("buckets", "[]")]), "null");
        assert_eq!(left(&[("lastSuccessAt", "5")]), "null");
        assert_eq!(left(&[("planType", "{}")]), "null");
        assert_eq!(asked.get(), 7);

        // A time to wait until holds a read back only while it can be read as a time.
        assert_eq!(left(&[("retryAfter", r#""2026-10-07T12:00:01.0000000+00:00""#)]), json::text(NOON));
        assert_eq!(asked.get(), 7);
        assert_eq!(left(&[("retryAfter", r#""soon""#)]), json::text(NOON));
        assert_eq!(asked.get(), 8);

        // A file that is not the collection's own is written again.
        std::fs::write(lab.state(), "not what a collection writes").unwrap();
        assert_eq!(went(&lab.collect(&policy, &V::Null, &|_, _| account("a", "plus", 10))), "a ok");
        assert_eq!(lab.kept("a", "identityKey"), r#""a""#);
    }

    #[test]
    fn one_subscription_in_two_homes_is_not_two() {
        let lab = Lab::new();
        let policy = lab.policy(&["a", "b", "c", "d", "e"], vec![]);
        let read = |home: &str, _: u64| match of(home) {
            "a" | "d" => account("one", "plus", 10),
            "c" => account("ONE", "plus", 10),
            "e" => failed("timeout"),
            _ => account("two", "plus", 10),
        };
        let result = lab.collect(&policy, &V::Null, &read);
        assert_eq!(went(&result), "a duplicate_subscription, b ok, c duplicate_subscription, d duplicate_subscription, e timeout");
        assert_eq!(at(&result, &["recommendedSlot"]), r#""b""#);
        // An account that was not read this time is not counted, whatever it was last time.
        lab.pass(60);
        let result = lab.collect(&lab.policy(&["a", "b"], vec![]), &V::Null, &|home, _| if of(home) == "a" { failed("timeout") } else { account("one", "plus", 10) });
        assert_eq!(went(&result), "a timeout, b ok");
    }

    #[test]
    fn a_hold_and_the_meter_asked_for_are_shown_with_the_choice() {
        let lab = Lab::new();
        let read = |home: &str, _: u64| account(of(home), "plus", 10);
        std::fs::write(lab.directory.join("hold.json"), r#"{"until":"2026-10-07T13:00:00.0000000+00:00","reason":"lunch"}"#).unwrap();
        // Under a hold the account in use stays the choice, and with none in use there is no choice.
        let policy = lab.policy(&["a", "b"], vec![("defaultMeter", "CODEX".into())]);
        let using = json::parse(r#"{"recommendations":{"codex":"b"}}"#, "").ok().unwrap();
        let held = lab.collect(&policy, &using, &read);
        assert_eq!(at(&held, &["hold"]), r#"{"until":"2026-10-07T13:00:00.0000000+00:00","reason":"lunch"}"#);
        assert_eq!([at(&held, &["defaultMeter"]), at(&held, &["recommendedSlot"])], [r#""CODEX""#, r#""b""#]);
        assert_eq!(at(&lab.collect(&policy, &V::Null, &read), &["recommendedSlot"]), "null");

        lab.pass(3600);
        let free = lab.collect(&lab.policy(&["a", "b"], vec![("defaultMeter", "codex_bengalfox".into())]), &V::Null, &read);
        assert_eq!(at(&free, &["hold"]), "null");
        assert_eq!([at(&free, &["defaultMeter"]), at(&free, &["recommendedSlot"])], [r#""codex_bengalfox""#, "null"]);
    }

    #[test]
    fn the_history_is_cut_back_to_its_last_lines() {
        let lab = Lab::new();
        let path = lab.directory.join("codex-observations.jsonl");
        let line = |n: usize| format!("{n:05}{}", "x".repeat(19_995));
        let old: Vec<String> = (0..300).map(line).collect();
        std::fs::write(&path, format!("\u{feff}{}\n", old.join("\n"))).unwrap();
        let result = lab.collect(&lab.policy(&["a"], vec![]), &V::Null, &|_, _| account("a", "plus", 10));
        let text = std::fs::read_to_string(&path).unwrap();
        let kept: Vec<&str> = text.strip_prefix('\u{feff}').unwrap().lines().collect();
        // The last 104 lines are what fits in 2,097,152 bytes.
        assert_eq!(kept.len(), 105);
        assert_eq!([kept[0], kept[103]], [line(196), line(299)]);
        assert_eq!(kept[104], at(&result, &[]));

        // A history that cannot be written fails nothing.
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert_eq!(went(&lab.collect(&lab.policy(&["a"], vec![]), &V::Null, &|_, _| account("a", "plus", 10))), "a ok");
    }

    #[test]
    fn a_policy_that_cannot_be_used_reads_no_account() {
        let lab = Lab::new();
        let policy = lab.policy(&["a", "b"], vec![("disabled", vec![V::s_of("c")].into())]);
        let stop = lab.tried(&policy, &V::Null, &|_, _| panic!("an account was read")).err().unwrap();
        assert_eq!(stop.message(), "invalid_preference");
        assert!(!lab.state().exists());
    }
}

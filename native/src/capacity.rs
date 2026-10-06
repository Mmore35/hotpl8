//! src/capacity.ps1: capacity is expressed in relative weekly units within one
//! provider/meter only. Unknown conversions are not inferred from monthly prices or
//! selection weights.

use crate::contract::{age_seconds, resolve_window};
use crate::critical::{critical_decision, critical_setting};
use crate::obj;
use crate::ps::*;
use crate::time::Dto;
use std::cell::RefCell;
use std::path::PathBuf;

thread_local! {
    static SOURCE: RefCell<PathBuf> = RefCell::new(PathBuf::new());
    static CATALOG: RefCell<Option<V>> = const { RefCell::new(None) };
}
/// The data/capacity-profiles.json this request's release ships. It is read when a rule
/// first asks for it, as PowerShell reads it.
pub fn set_source(file: PathBuf) {
    SOURCE.with(|cell| *cell.borrow_mut() = file);
    CATALOG.with(|cell| *cell.borrow_mut() = None);
}
/// Get-Hotpl8CapacityCatalog
pub fn catalog() -> R<V> {
    if let Some(known) = CATALOG.with(|cell| cell.borrow().clone()) {
        return Ok(known);
    }
    let Some(read) = crate::json::read_file(&SOURCE.with(|cell| cell.borrow().clone()))? else {
        return unreadable_as("This copy of HotPl8 has no data/capacity-profiles.json.");
    };
    CATALOG.with(|cell| *cell.borrow_mut() = Some(read.clone()));
    Ok(read)
}

/// Assert-Hotpl8CapacityPolicy
pub fn assert_capacity_policy(part: &V) -> R<()> {
    for (name, c) in part.g("capacity")?.props()? {
        if !slot_name(&name, 40) || !c.is_obj() {
            return fail("Invalid capacity account.");
        }
        for (field, _) in c.props()? {
            if !V::s_of(&field).in_s(&["profile", "weekly", "fiveHour", "scoped", "evidence"])? {
                return fail("Invalid capacity field.");
            }
        }
        let profile = c.g("profile")?;
        if profile.t()? && !catalog()?.g("profiles")?.gd(&profile.s()?)?.t()? {
            return fail("Unknown capacity profile.");
        }
        for key in ["weekly", "fiveHour"] {
            let value = c.g(key)?;
            if !value.is_null() && (!value.is_number() || value.le_i(0)? || value.gt_i(1000000)?) {
                return fail("Capacity must be a positive finite number.");
            }
        }
        for (scope, value) in c.g("scoped")?.props()? {
            if !slot_name(&scope, 80) || !value.is_number() || value.le_i(0)? || value.gt_i(1000000)? {
                return fail("Invalid scoped capacity.");
            }
        }
        let evidence = c.g("evidence")?;
        if evidence.t()? && length(&evidence.s()?) > 240 {
            return fail("Capacity evidence is too long.");
        }
    }
    Ok(())
}

/// Test-Hotpl8DetectedPlan, from src/providers/claude-plans.ps1.
fn detected_plan(plan: &V, now: Dto) -> R<bool> {
    if !plan.t()? || !plan.g("status")?.in_s(&["detected", "partial"])? {
        return Ok(false);
    }
    let age = catch(|| Ok(now.since(Dto::of(&plan.g("observedAt")?)?).total_seconds()))?;
    Ok(age.is_some_and(|age| (-5.0..=1200.0).contains(&age)))
}

/// Test-Hotpl8FreshTimestamp, from src/common.ps1.
pub fn fresh_timestamp(timestamp: &V, now: Dto) -> R<bool> {
    Ok(age_seconds(timestamp, now)?.is_some_and(|age| (-5.0..=900.0).contains(&age)))
}

/// Get-Hotpl8AccountCapacity
pub fn account_capacity(part: &V, slot: &str, provider: &str, meter: &str, detected: &V, now: Dto) -> R<V> {
    let c = part.g("capacity")?.gd(slot)?;
    let profile_id = if c.g("profile")?.t()? {
        c.g("profile")?.sv()?
    } else if provider == "claude" && detected.g("status")?.eq_s("detected")? && detected_plan(detected, now)? {
        detected.g("profile")?.sv()?
    } else {
        V::Null
    };
    let mut profile = if profile_id.t()? { catalog()?.g("profiles")?.gd(&profile_id.s()?)? } else { V::Null };
    if profile.t()? && (profile.g("provider")?.ne_s(provider)? || (provider == "codex" && profile.g("meter")?.ne(&V::s_of(meter))?)) {
        profile = V::Null;
    }
    let weekly = if c.g("weekly")?.is_null() { profile.g("weekly")? } else { c.g("weekly")? };
    let short = if c.g("fiveHour")?.is_null() { profile.g("fiveHour")? } else { c.g("fiveHour")? };
    let confidence = if c.g("weekly")?.t()? || c.g("fiveHour")?.t()? {
        "user estimate".into()
    } else if profile.t()? {
        profile.g("confidence")?
    } else {
        "capacity setup needed".into()
    };
    Ok(obj! {
        "weekly" => weekly,
        "fiveHour" => short,
        "scoped" => c.g("scoped")?,
        "profile" => profile_id,
        "confidence" => confidence,
    })
}

/// New-Hotpl8CapacityWindow
fn capacity_window(name: &str, remaining: V, full: V, reset: V, now: Dto, confirmed: bool, observed_at: &V) -> R<V> {
    let (mut remaining, mut reset) = (remaining, reset);
    if resolve_window(&remaining, &reset, observed_at, now, false)?.g("rolledOver")?.t()? {
        remaining = V::Dbl(100.0);
        reset = V::Null;
    }
    let at = catch(|| if reset.t()? { Ok(Some(Dto::parse(&reset.s()?)?)) } else { Ok(None) })?.flatten();
    let valid = remaining.is_number() && remaining.ge_i(0)? && remaining.le_i(100)? && at.is_none_or(|at| at.ticks > now.ticks);
    Ok(obj! {
        "name" => name,
        "remaining" => remaining,
        "full" => full,
        "valid" => valid,
        "resetAt" => match at {
            Some(at) if confirmed => at.o().into(),
            _ => V::Null,
        },
    })
}

/// `$windows | Where-Object name -EQ $name | Select-Object -First 1`
fn first_named(windows: &[V], name: &str) -> R<Option<V>> {
    for window in windows {
        if window.g("name")?.eq_s(name)? {
            return Ok(Some(window.clone()));
        }
    }
    Ok(None)
}
/// The '300' window, else the '10080' one.
fn primary_window(windows: &[V]) -> R<Option<V>> {
    match first_named(windows, "300")? {
        Some(window) => Ok(Some(window)),
        None => first_named(windows, "10080"),
    }
}
/// `$windows | Where-Object {$null -eq $_.full}`
fn unconverted(windows: &[V]) -> R<Vec<V>> {
    filter(windows, |window| Ok(window.g("full")?.is_null()))
}
/// `($windows | Where-Object {$null -ne $_.full} | ForEach-Object {$_.full*$_.remaining/100} | Measure-Object -Minimum).Minimum`
fn least_usable(windows: &[V]) -> R<V> {
    let mut amounts = Vec::new();
    for window in windows {
        let full = window.g("full")?;
        if !full.is_null() {
            amounts.push(full.mul(&window.g("remaining")?)?.div(&V::I32(100))?);
        }
    }
    measure_min(&amounts)
}

/// Get-Hotpl8CapacityAccounts
pub fn capacity_accounts(snapshot: &V, part: &V, provider: &str, now: Dto, meter: &str, quota_headroom: bool) -> R<Vec<V>> {
    let claude = provider == "claude";
    let ids = held(if claude { part.g("prefer")?.arr() } else { pluck(&part.g("slots")?.arr(), "id")? })?;
    let disabled = part.g("disabled")?.arr();
    let ids = unique(&filter(&ids, |id| Ok(!id.is_null() && !id.is_in_list(&disabled)?))?)?;
    let mut seen = Keys::new();
    let mut out = Vec::new();
    for id in &ids {
        let slot = if claude {
            filter(&snapshot.g("slots")?.arr(), |item| item.g("slot")?.eq(id))?
        } else {
            filter(&snapshot.path(&["providers", "codex", "slots"])?.arr(), |item| item.g("id")?.eq(id))?
        };
        let s = if slot.len() == 1 { slot[0].clone() } else { V::Null };
        let stream = s.g("streamKey")?;
        if stream.t()? && s.g("status")?.in_s(&["ok", "duplicate_subscription"])? {
            let V::Str(key) = &stream else { return unreadable() };
            if seen.contains(key)? {
                continue;
            }
            seen.insert(key)?;
        }
        let c = account_capacity(part, &id.s()?, provider, meter, &s.g("plan")?, now)?;
        let mut fresh = s.t()? && s.g("status")?.eq_s("ok")? && fresh_timestamp(&s.g("observedAt")?, now)?;
        let mut windows: Vec<V> = Vec::new();
        let mut blocked = false;
        let mut reason: V = "".into();
        let mut block_reason = V::Null;
        if claude {
            fresh = fresh && s.g("fresh")?.t()?;
            let left = |used: V| -> R<V> {
                if used.is_number() {
                    V::I32(100).sub(&used)
                } else {
                    Ok(V::Null)
                }
            };
            let observed = s.g("observedAt")?;
            windows.push(capacity_window("10080", left(s.g("used7d")?)?, c.g("weekly")?, s.g("reset7d")?, now, true, &observed)?);
            windows.push(capacity_window("300", left(s.g("used5h")?)?, c.g("fiveHour")?, s.g("reset5h")?, now, true, &observed)?);
            for model in part.g("claudeModels")?.arr() {
                if !model.t()? {
                    continue;
                }
                let scope = filter(&s.g("scoped")?.arr(), |item| item.g("name")?.eq(&model))?;
                let w = if scope.len() == 1 { scope[0].clone() } else { V::Null };
                let name = model.s()?;
                windows.push(capacity_window(&name, left(w.g("pct")?)?, c.g("scoped")?.gd(&name)?, w.g("resetsAt")?, now, true, &observed)?);
            }
        } else {
            let b = s.g("buckets")?.gd(meter)?;
            blocked = b.g("status")?.ne_s("observed")?;
            reason = if b.t()? { b.g("status")? } else { "meter_unknown".into() };
            if blocked && b.g("blockReason")?.t()? {
                block_reason = b.g("blockReason")?.sv()?;
            }
            let entries = b.g("windows")?.props()?;
            for (name, w) in &entries {
                let reset = catch(|| {
                    if w.g("resetsAt")?.t()? {
                        Ok(V::from(Dto::from_unix_seconds(w.g("resetsAt")?.to_long()?)?.o()))
                    } else {
                        Ok(V::Null)
                    }
                })?
                .unwrap_or(V::Null);
                let weekly = text_eq(name, "10080")?;
                let mut full = if weekly { c.g("weekly")? } else { c.g("fiveHour")? };
                // A single weekly-only subscription needs no cross-account conversion.
                if ids.len() == 1 && weekly && entries.len() == 1 && full.is_null() {
                    full = V::I32(1);
                    c.set("weekly", V::I32(1))?;
                    c.set("confidence", "single-account normalization".into())?;
                }
                let confirmed = w.g("anchorState")?.eq_s("observed-active")?;
                windows.push(capacity_window(name, w.g("remainingPercent")?, full, reset, now, confirmed, &w.g("observedAt")?)?);
            }
        }
        let mut basis = "calibrated";
        if quota_headroom {
            let profile = if c.g("profile")?.t()? { catalog()?.g("profiles")?.gd(&c.g("profile")?.s()?)? } else { V::Null };
            let primary = primary_window(&windows)?;
            let primary_full = match &primary {
                Some(window) => window.g("full")?,
                None => V::Null,
            };
            let calibrated = !primary_full.is_null();
            let has_profile =
                profile.t()? && profile.g("provider")?.eq_s(provider)? && (provider != "codex" || profile.g("meter")?.eq(&V::s_of(meter))?);
            let weight = if has_profile {
                profile.g("sessionMultiplier")?
            } else if calibrated {
                primary_full.clone()
            } else if ids.len() == 1 {
                V::I32(1)
            } else {
                V::Null
            };
            basis = if has_profile || !calibrated { "plan" } else { "calibrated" };
            for window in &windows {
                if primary.as_ref().is_some_and(|primary| window.same_ref(primary)) {
                    window.set("full", weight.clone())?;
                } else if !calibrated {
                    window.set("full", V::Null)?;
                } else if !window.g("full")?.is_null() {
                    window.set("full", window.g("full")?.div(&primary_full)?.mul(&weight)?)?;
                }
            }
            c.set("weekly", weight)?;
            let confidence = if unconverted(&windows)?.is_empty() { "calibrated current-window estimate" } else { "weekly/model conversion unavailable" };
            c.set("confidence", confidence.into())?;
        }
        let known = fresh && !windows.is_empty() && filter(&windows, |window| Ok(!window.g("valid")?.t()?))?.is_empty();
        let missing = unconverted(&windows)?;
        let scaled = known && !c.g("weekly")?.is_null() && (quota_headroom || missing.is_empty());
        let mut gross = V::Null;
        let mut percent = V::Null;
        if known {
            percent = measure_min(&windows.iter().map(|window| window.g("remaining")).collect::<R<Vec<V>>>()?)?;
        }
        if scaled {
            gross = least_usable(&windows)?;
        }
        let known_zero = known && blocked && reason.eq_s("blocked")? && percent.eq_i(0)?;
        let refill_expected = known_zero
            && block_reason.eq_s("quota_exhausted")?
            && filter(&windows, |window| Ok(window.g("remaining")?.le_i(0)? && !window.g("resetAt")?.t()?))?.is_empty();
        out.push(obj! {
            "slot" => id.sv()?,
            "profile" => c.g("profile")?,
            "fresh" => known,
            "scaled" => scaled,
            "knownZero" => known_zero,
            "refillExpected" => refill_expected,
            "weekly" => c.g("weekly")?,
            "weightBasis" => basis,
            "unconvertedConstraints" => pluck(&missing, "name")?,
            "windows" => windows,
            "gross" => gross,
            "bindingRemaining" => percent,
            "blocked" => blocked,
            "reason" => reason,
            "blockReason" => block_reason,
            "reserve" => id.is_in(&part.g("reserve")?)?,
            "confidence" => c.g("confidence")?,
        });
    }
    Ok(out)
}

/// Get-Hotpl8CapacityAmount: null, or a double.
pub fn capacity_amount(account: &V, part: &V, at: Dto, project: bool, emergency: bool, assume_refill: bool) -> R<V> {
    if !account.g("scaled")?.t()? || (account.g("blocked")?.t()? && !(project && assume_refill)) {
        return Ok(V::Null);
    }
    let mut units = V::Dbl(f64::MAX);
    for w in account.g("windows")?.each() {
        let mut left = V::Dbl(w.g("remaining")?.dbl()?);
        if project && w.g("resetAt")?.t()? && Dto::of(&w.g("resetAt")?)?.ticks <= at.ticks {
            left = V::I32(100);
        }
        let reserve = account.g("reserve")?;
        let mut margin = if w.g("name")?.eq_s("300")? {
            V::Dbl(part.g("margin5h")?.dbl()?)
        } else if reserve.t()? {
            V::Dbl(part.g("margin7d")?.dbl()?)
        } else if !part.g("margin7dWork")?.is_null() {
            V::Dbl(part.g("margin7dWork")?.dbl()?)
        } else {
            V::Dbl(part.g("margin7d")?.dbl()?)
        };
        if emergency && !reserve.t()? {
            margin = if part.path(&["critical", "drainToZero"])?.t()? { V::I32(0) } else { V::Dbl(critical_setting(part, "floorPercent", 1.0)?) };
        }
        if left.le_i(0)? || left.lt(&margin)? {
            return Ok(V::Dbl(0.0));
        }
        let full = w.g("full")?;
        if !full.is_null() {
            units = math_pick(&units, &full.mul(&left)?.div(&V::I32(100))?, false)?;
        }
    }
    let (weekly, units) = (account.g("weekly")?.dbl()?, units.dbl()?);
    Ok(V::Dbl(if units < weekly { units } else { weekly }))
}

/// Get-Hotpl8ProviderCapacity
pub fn provider_capacity(snapshot: &V, part: &V, provider: &str, now: Dto, meter: &str, quota_headroom: bool) -> R<V> {
    let claude = provider == "claude";
    let mut accounts = capacity_accounts(snapshot, part, provider, now, meter, quota_headroom)?;
    let mut coverage = V::Null;
    if quota_headroom {
        let usable = |a: &V| -> R<bool> { Ok(a.g("fresh")?.t()? && (!a.g("blocked")?.t()? || a.g("knownZero")?.t()?)) };
        let mut excluded = Vec::new();
        for a in &accounts {
            if !usable(a)? {
                excluded.push(obj! {"slot" => a.g("slot")?, "reason" => if a.g("fresh")?.t()? { "blocked" } else { "unreadable" }});
            }
        }
        accounts = filter(&accounts, usable)?;
        if !filter(&accounts, |a| Ok(!a.g("scaled")?.t()? || a.g("weekly")?.is_null()))?.is_empty()
            || unique_count(&pluck(&accounts, "weightBasis")?)? > 1
        {
            for a in &accounts {
                let windows = a.g("windows")?.arr();
                let primary = primary_window(&windows)?;
                for w in &windows {
                    let weight = if primary.as_ref().is_some_and(|primary| w.same_ref(primary)) { V::Dbl(1.0) } else { V::Null };
                    w.set("full", weight)?;
                }
                a.set("weekly", V::Dbl(1.0))?;
                a.set("scaled", true.into())?;
                a.set("weightBasis", "equal".into())?;
                let missing = pluck(&unconverted(&windows)?, "name")?;
                let confidence = if missing.is_empty() { "equal-weight current-window estimate" } else { "weekly/model conversion unavailable" };
                a.set("unconvertedConstraints", missing.into())?;
                a.set("gross", least_usable(&windows)?)?;
                a.set("confidence", confidence.into())?;
            }
        }
        coverage = obj! {"measured" => accounts.len() as i32, "excluded" => excluded};
    }
    let denominator_known = !accounts.is_empty()
        && filter(&accounts, |a| Ok(a.g("weekly")?.is_null()))?.is_empty()
        && unique_count(&pluck(&accounts, "weightBasis")?)? <= 1;
    let total =
        if denominator_known { measure_sum(&accounts.iter().map(|a| a.g("weekly")).collect::<R<Vec<V>>>()?)? } else { V::Null };
    let complete =
        denominator_known && filter(&accounts, |a| Ok(!a.g("scaled")?.t()? || (a.g("blocked")?.t()? && !a.g("knownZero")?.t()?)))?.is_empty();
    let projection_complete = complete && filter(&accounts, |a| Ok(a.g("blocked")?.t()? && !a.g("refillExpected")?.t()?))?.is_empty();
    let mut hold = if claude { snapshot.g("hold")? } else { snapshot.path(&["providers", "codex", "hold"])? };
    let selected = if claude { snapshot.g("active")?.s()? } else { snapshot.path(&["providers", "codex", "recommendedSlot"])?.s()? };
    if hold.t()? && catch(|| Ok(Dto::of(&hold.g("until")?)?.ticks <= now.ticks))? == Some(true) {
        hold = V::Null;
    }
    let mut pause = snapshot.g("automationPause")?;
    if pause.t()? && catch(|| Ok(Dto::of(&pause.g("until")?)?.ticks <= now.ticks))? == Some(true) {
        pause = V::Null;
    }
    let restricted = if quota_headroom {
        hold.t()?
    } else {
        hold.t()? || pause.t()? || (claude && (part.g("mode")?.eq_s("monitor")? || part.g("switchEnabled")?.is_false()?))
    };
    let state = if claude { snapshot.g("critical")? } else { snapshot.path(&["providers", "codex", "critical"])?.gd(meter)? };
    let critical = critical_decision(&accounts, part, &selected, &state, now)?;
    let emergency = critical.g("active")?.t()?;
    let mut upcoming = Vec::new();
    for a in &accounts {
        if a.g("fresh")?.t()? && (!a.g("blocked")?.t()? || a.g("knownZero")?.t()?) {
            for w in a.g("windows")?.arr() {
                let at = w.g("resetAt")?;
                if at.t()? && Dto::of(&at)?.ticks > now.ticks {
                    upcoming.push(w);
                }
            }
        }
    }
    // Two resets at one instant are interchangeable below unless their text differs.
    let resets = sort(
        &upcoming,
        |a, b| Ok(Dto::of(&a.g("resetAt")?)?.ticks.cmp(&Dto::of(&b.g("resetAt")?)?.ticks)),
        |a, b| matches!((a.g("resetAt"), b.g("resetAt")), (Ok(V::Str(left)), Ok(V::Str(right))) if left == right),
    )?;
    let other = |a: &V| -> R<bool> { Ok(restricted && a.g("slot")?.ne(&V::s_of(&selected))?) };
    let mut next: Option<Dto> = None;
    let mut solid = V::Dbl(0.0);
    let mut future = V::Dbl(0.0);
    let mut unknown = V::Dbl(0.0);
    for a in &accounts {
        let scaled = a.g("scaled")?.t()?;
        if scaled && a.g("knownZero")?.t()? {
            continue;
        }
        if !scaled || a.g("blocked")?.t()? {
            let weekly = a.g("weekly")?;
            if weekly.t()? {
                unknown = unknown.add(&weekly)?;
            }
            continue;
        }
        if other(a)? {
            continue;
        }
        solid = solid.add(&capacity_amount(a, part, now, false, emergency, false)?)?;
    }
    let mut later: Option<Dto> = None;
    let mut later_future = V::Dbl(0.0);
    if complete {
        for reset in &resets {
            let at = Dto::of(&reset.g("resetAt")?)?;
            if at.ticks > now.plus_seconds(8 * 86400)?.ticks {
                break;
            }
            let mut candidate = V::Dbl(0.0);
            for a in &accounts {
                if (a.g("blocked")?.t()? && !a.g("refillExpected")?.t()?) || other(a)? {
                    continue;
                }
                candidate = candidate.add(&capacity_amount(a, part, at, true, emergency, a.g("refillExpected")?.t()?)?)?;
            }
            if candidate.le(&solid.add(&V::Dbl(0.0000001))?)? {
                continue;
            }
            if at.ticks <= now.plus_seconds(86400)?.ticks {
                next = Some(at);
                future = candidate;
            } else {
                later = Some(at);
                later_future = candidate;
            }
            break;
        }
    }
    let gain = if next.is_some() { math_pick(&V::Dbl(0.0), &future.sub(&solid)?, true)? } else { V::Null };
    let later_gain = if later.is_some() { math_pick(&V::Dbl(0.0), &later_future.sub(&solid)?, true)? } else { V::Null };
    // 100*$amount/$total
    let share = |amount: &V| -> R<V> { V::I32(100).mul(amount)?.div(&total) };
    let usable_share = || -> R<V> { math_pick(&V::Dbl(100.0), &share(&solid)?, false) };
    let gain_share = |gain: &V| -> R<V> { math_pick(&V::I32(100).sub(&share(&solid)?)?, &share(gain)?, false) };
    Ok(obj! {
        "metric" => if quota_headroom { "plan-weighted-quota-headroom" } else { "weighted-weekly-capacity" },
        "unit" => if quota_headroom { "relative session headroom" } else { "relative weekly allowance" },
        "totalUnits" => &total,
        "complete" => complete,
        "accounts" => accounts.clone(),
        "measured" => where_truthy(&accounts, "scaled")?.len() as i32,
        "usableNowPercent" => if complete { usable_share()? } else { V::Null },
        "knownUsablePercent" => if total.t()? { usable_share()? } else { V::I32(0) },
        "unknownPercent" => if total.t()? { share(&unknown)? } else { V::I32(100) },
        "nextResetAt" => next.map_or(V::Null, |at| at.o().into()),
        "projectionHorizonHours" => 24,
        "projectionComplete" => projection_complete,
        "coverage" => coverage,
        "projectedGainPercent" => if complete && next.is_some() { gain_share(&gain)? } else { V::Null },
        "laterRefillAt" => later.map_or(V::Null, |at| at.o().into()),
        "laterRefillGainPercent" => if complete && later.is_some() { gain_share(&later_gain)? } else { V::Null },
        "projectionAssumption" => "First positive gain within 24h, else the first within 8 days as text; no further consumption; blocked accounts stay blocked unless the block is a quota exhaustion with a confirmed reset; other limits and policy still apply",
        "critical" => critical,
        "restricted" => restricted,
        "confidence" => if quota_headroom {
            "quota headroom estimate; not a token budget"
        } else if complete {
            "estimate"
        } else {
            "capacity setup or fresh reading needed"
        },
    })
}

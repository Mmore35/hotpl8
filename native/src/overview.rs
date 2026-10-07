//! src/overview.ps1: the cached, normalized weekly inventory printed above a status. It is
//! not a token or work-hour budget.

use crate::capacity::{fresh_timestamp, provider_capacity};
use crate::claude::{claude_selection, margin_7d_for, model_block, test_ok, Accounts};
use crate::codex::{codex_eligibility, select_codex_slot};
use crate::contract::resolve_window;
use crate::insights::health;
use crate::observation::claude_observation;
use crate::policy::switching;
use crate::ps::*;
use crate::registry::{configured_providers, provider_driver, provider_view};
use crate::time::Dto;
use crate::{cat, hash, obj};

/// Test-Hotpl8FutureReset
fn future_reset(reset: &V, now: Dto, unix: bool) -> R<bool> {
    let future = catch(|| {
        if reset.is_null() || text_eq(&reset.s()?, "")? {
            return Ok(false);
        }
        let at = if unix { Dto::from_unix_seconds(reset.to_long()?)? } else { Dto::parse(&reset.s()?)? };
        Ok(at.ticks > now.ticks)
    })?;
    Ok(future.unwrap_or(false))
}
/// Test-Hotpl8OverviewPercent
fn overview_percent(value: &V) -> R<bool> {
    Ok(value.is_number() && value.ge_i(0)? && value.le_i(100)?)
}
/// `$list.Count` as PowerShell holds it.
fn count(length: usize) -> R<i32> {
    i32::try_from(length).or_else(|_| unreadable())
}

/// Get-Hotpl8NativeOverview for its one family: the value it files under that name.
fn native_overview(snapshot: &V, policy: &V, now: Dto, family: &str) -> R<V> {
    let claude = family == "claude";
    let part = if claude { policy.clone() } else { policy.g("codex")? };
    let configured = held(if claude {
        filter(&policy.g("prefer")?.arr(), |id| Ok(!id.is_null()))?
    } else {
        pluck(&filter(&part.g("slots")?.arr(), |slot| slot.t())?, "id")?
    })?;
    let disabled = part.g("disabled")?;
    let ids = unique(&filter(&configured, |id| Ok(!id.is_in(&disabled)?))?)?;
    let observations = held(if claude { snapshot.g("slots")?.arr() } else { snapshot.path(&["providers", "codex", "slots"])?.arr() })?;
    // The unified Codex graph is always the main allowance, never Spark.
    let meter = if claude { "overall weekly" } else { "codex" };
    let mut members: Vec<V> = Vec::new();
    let mut identities = Keys::new();
    let mut claude_accounts = Accounts::default();
    let mut codex_accounts: Vec<V> = Vec::new();
    let mut duplicates = 0i32;
    for id in &ids {
        let matches = filter(&observations, |observation| observation.g(if claude { "slot" } else { "id" })?.eq(id))?;
        let s = if matches.len() == 1 { matches[0].clone() } else { V::Null };
        // Only deduplicate when the snapshot actually supplies identity evidence.
        // Failed legacy reads can share an empty-identity hash; never collapse those.
        let identity = if s.g("streamKey")?.t()? && s.g("status")?.in_s(&["ok", "duplicate_subscription"])? { s.g("streamKey")?.s()? } else { String::new() };
        if !identity.is_empty() {
            if identities.contains(&identity)? {
                duplicates += 1;
                continue;
            }
            identities.insert(&identity)?;
        }
        let mut fresh = s.t()? && s.g("status")?.eq_s("ok")? && fresh_timestamp(&s.g("observedAt")?, now)?;
        let mut remaining = V::Null;
        let mut reason: V = "no_observation".into();
        let mut eligible = false;
        let mut weekly_reset = V::Null;
        if s.t()? {
            reason = if fresh {
                "weekly_unmeasured".into()
            } else if s.g("status")?.ne_s("ok")? {
                s.g("status")?.sv()?
            } else {
                "stale".into()
            };
        }
        if claude {
            fresh = fresh && s.g("fresh")?.t()?;
            // An elapsed reset we were told about before it happened is a
            // refill, not a broken reading. A cold window reaches the same
            // state by the other route and keeps its own exemption.
            let w7 = resolve_window(&s.g("used7d")?, &s.g("reset7d")?, &s.g("observedAt")?, now, false)?;
            let w5 = resolve_window(&s.g("used5h")?, &s.g("reset5h")?, &s.g("observedAt")?, now, false)?;
            let weekly = fresh && overview_percent(&w7.g("used")?)? && (w7.g("rolledOver")?.t()? || future_reset(&w7.g("resetAt")?, now, false)?);
            if weekly {
                remaining = V::Dbl(100.0 - w7.g("used")?.dbl()?);
                weekly_reset = if w7.g("resetAt")?.t()? { Dto::of(&w7.g("resetAt")?)?.o().into() } else { V::Null };
            }
            let short = fresh
                && overview_percent(&w5.g("used")?)?
                && (w5.g("rolledOver")?.t()?
                    || future_reset(&w5.g("resetAt")?, now, false)?
                    || (s.g("cold")?.t()? && s.g("used5h")?.eq_i(0)? && !s.g("reset5h")?.t()?));
            let model = model_block(&s.g("scoped")?, policy, id.to_int()?, now, &s.g("observedAt")?)?;
            let e = hash! {
                "h5" => if short { V::Dbl(100.0 - w5.g("used")?.dbl()?) } else { V::Null },
                "h7" => &remaining,
                "fresh" => short && weekly,
                "modelBlocked" => model.t()?,
                "obj" => hash! {"usage" => hash! {
                    "fiveHour" => hash! {"resetsAt" => w5.g("resetAt")?},
                    "sevenDay" => hash! {"resetsAt" => w7.g("resetAt")?},
                }},
            };
            e.set("observation", claude_observation(&s, policy)?)?;
            claude_accounts.put(id.to_int()?, e.clone());
            eligible = test_ok(&e, V::Dbl(policy.g("margin5h")?.dbl()?), margin_7d_for(policy, id)?, now)?.t()? && e.g("h5")?.gt_i(0)? && remaining.gt_i(0)?;
            if fresh {
                reason = if model.t()? {
                    model
                } else if eligible {
                    "eligible".into()
                } else if !weekly || !short {
                    "window_unmeasured".into()
                } else {
                    "below_margin".into()
                };
            } else if s.t()? && s.g("status")?.eq_s("ok")? {
                reason = "stale".into();
            }
        } else {
            let b = s.path(&["buckets", "codex"])?;
            let w = b.path(&["windows", "10080"])?;
            let rolled = resolve_window(&w.g("usedPercent")?, &w.g("resetsAt")?, &w.g("observedAt")?, now, true)?;
            if fresh
                && (b.g("status")?.eq_s("observed")? || (b.g("status")?.eq_s("blocked")? && w.g("usedPercent")?.eq_i(100)?))
                && overview_percent(&rolled.g("used")?)?
                && (rolled.g("rolledOver")?.t()? || future_reset(&rolled.g("resetAt")?, now, true)?)
            {
                remaining = V::Dbl(100.0 - rolled.g("used")?.dbl()?);
                if w.g("anchorState")?.eq_s("observed-active")? && !rolled.g("resetAt")?.is_null() {
                    weekly_reset = Dto::from_unix_seconds(rolled.g("resetAt")?.to_long()?)?.o().into();
                }
            }
            if s.t()? {
                reason = codex_eligibility(&s, &part, meter, now, false)?;
                eligible = reason.eq_s("eligible")?;
                codex_accounts.push(s.clone());
            }
        }
        members.push(obj! {
            "slot" => id.sv()?,
            "remainingPercent" => remaining,
            "weeklyResetAt" => weekly_reset,
            "eligible" => eligible,
            "reason" => reason,
            "reserve" => id.is_in(&part.g("reserve")?)?,
        });
    }
    let measured = count(filter(&members, |member| Ok(!member.g("remainingPercent")?.is_null()))?.len())?;
    let mut sum = 0.0;
    for member in &members {
        let percent = member.g("remainingPercent")?;
        if !percent.is_null() {
            sum += percent.dbl()?;
        }
    }
    let total = count(members.len())?;
    let known = if total > 0 { dbl(sum / f64::from(total))? } else { V::Dbl(0.0) };
    let unknown = if total > 0 { dbl(100.0 * f64::from(total - measured) / f64::from(total))? } else { V::Dbl(100.0) };
    let ready = !where_truthy(&members, "eligible")?.is_empty();
    let mut availability = if total == 0 {
        "No accounts enabled"
    } else if !ready {
        "Unavailable now - see details"
    } else if claude {
        "Ready"
    } else {
        "Ready for next launch"
    }
    .to_string();
    let automation;
    let mut selected = V::Null;
    if claude {
        let switching = switching(policy)?;
        let pause = snapshot.g("automationPause")?;
        let paused = pause.t()? && (pause.g("invalid")?.t()? || future_reset(&pause.g("until")?, now, false)?);
        let hold = snapshot.g("hold")?;
        let held = hold.t()? && future_reset(&hold.g("until")?, now, false)?;
        automation = if policy.g("mode")?.eq_s("monitor")? && !paused {
            "monitor only"
        } else if paused {
            "automation paused"
        } else if held {
            "rotation held"
        } else if switching {
            "automatic selection on"
        } else {
            "manual selection"
        };
        if total > 0 {
            let mut prefer = Vec::new();
            for member in &members {
                prefer.push(member.g("slot")?.to_int()?);
            }
            let active = snapshot.g("active")?;
            let (target, active_ok) = claude_selection(policy, &prefer, &claude_accounts, active.to_int()?, now, &snapshot.g("critical")?)?;
            selected = if held || paused || !switching {
                if active_ok { active } else { V::Null }
            } else if !target.is_null() {
                target
            } else if active_ok {
                active
            } else {
                V::Null
            };
            if ready && !selected.t()? {
                availability = "Account available - manual selection needed".to_string();
            }
        }
    } else {
        let codex = snapshot.path(&["providers", "codex"])?;
        let mut hold = codex.g("hold")?;
        if hold.t()? && !future_reset(&hold.g("until")?, now, false)? {
            hold = V::Null;
        }
        if total > 0 {
            selected = select_codex_slot(&codex_accounts, &part, meter, &codex.g("recommendedSlot")?.s()?, &hold, now, &codex.path(&["critical", "codex"])?)?;
        }
        if ready && !selected.t()? {
            availability = "Account available - selection held".to_string();
        }
        automation = "native launches; managed sessions need adoption evidence";
    }
    let health = health(&snapshot.g("collector")?, now, family)?;
    if total > 0 && count(filter(&members, |member| member.g("reason")?.eq_s("stale"))?.len())? == total {
        availability = "Readings stale - refresh".to_string();
    }
    let sign_in = filter(&members, |member| member.g("reason")?.in_s(&["authentication_required", "relogin_required", "no_credentials"]))?.len();
    if sign_in > 0 {
        availability += "; sign-in needed";
    }
    if !["manual / no collector evidence", "recent collection completed", "collecting"].contains(&health.as_str()) {
        availability = cat!(availability, "; ", health);
    }
    let capacity = provider_capacity(snapshot, &part, family, now, meter, false)?;
    let immediate = provider_capacity(snapshot, &part, family, now, meter, true)?;
    let critical = capacity.path(&["critical", "active"])?.t()?;
    if critical {
        let ranked = capacity.path(&["critical", "ranked"])?;
        for member in &members {
            if member.g("slot")?.is_in(&ranked)? {
                member.set("eligible", true.into())?;
                member.set("reason", "critical_allowance".into())?;
            }
        }
    }
    if critical && selected.t()? {
        availability = if claude { "Ready / critical" } else { "Ready for next launch / critical" }.to_string();
    }
    Ok(obj! {
        "schemaVersion" => 2,
        "capacity" => capacity,
        "immediate" => immediate,
        "computedAt" => now.o(),
        "metric" => "normalized-weekly-headroom",
        "scope" => meter,
        "accounts" => total,
        "measured" => measured,
        "disabled" => count(held_count(&configured)?)? - count(ids.len())?,
        "duplicates" => duplicates,
        "knownRemainingPercent" => &known,
        "unknownPercent" => unknown,
        "remainingPercent" => if total > 0 && measured == total { known.clone() } else { V::Null },
        "includesReserve" => !where_truthy(&members, "reserve")?.is_empty(),
        "availability" => availability,
        "automation" => automation,
        "collectionHealth" => health,
        "selected" => selected,
        "members" => members,
    })
}

/// Get-Hotpl8ProviderOverview
pub fn provider_overview(snapshot: &V, policy: &V, now: Dto) -> R<V> {
    let policy = if policy.t()? { policy.clone() } else { obj! {} };
    let result = obj! {};
    for r in configured_providers(&policy, true)? {
        let id = r.g("id")?.s()?;
        let view = provider_view(snapshot, &policy, &id, &[])?;
        let value = native_overview(&view.g("snapshot")?, &view.g("policy")?, now, &view.g("provider")?.s()?)?;
        value.add_member("name", r.g("name")?, true)?;
        value.add_member("driver", r.g("driver")?, true)?;
        result.add_member(&id, value, true)?;
    }
    Ok(result)
}

/// The members of Get-Hotpl8CapacityDisplay that the text reads.
struct Display {
    state: String,
    gain: V,
    next_reset_at: V,
}
/// Get-Hotpl8CapacityDisplay
fn capacity_display(p: &V) -> R<Display> {
    let c = if p.g("immediate")?.t()? { p.g("immediate")? } else { p.g("capacity")? };
    let complete = c.g("complete")?.t()?;
    let mut state = if complete {
        cat!(c.g("usableNowPercent")?.tenths()?, "% available now")
    } else if c.g("coverage")?.t()? && c.path(&["coverage", "measured"])?.eq_i(0)? {
        "No account readable now".to_string()
    } else if c.g("totalUnits")?.is_null() {
        "Plan allowance unknown; total unavailable".to_string()
    } else {
        cat!("Partial: ", c.g("measured")?, "/", p.g("accounts")?, " measured; total unavailable")
    };
    if c.g("metric")?.eq_s("plan-weighted-quota-headroom")? && complete {
        state += " (estimate)";
    }
    let weekly_uncertain = filter(&c.g("accounts")?.arr(), |account| {
        if !V::s_of("10080").is_in(&account.g("unconvertedConstraints")?)? {
            return Ok(false);
        }
        let near = filter(&account.g("windows")?.arr(), |window| {
            Ok(window.g("name")?.eq_s("10080")? && window.g("remaining")?.gt_i(0)? && window.g("remaining")?.le_i(20)?)
        })?;
        Ok(!near.is_empty())
    })?
    .len();
    if weekly_uncertain > 0 && complete {
        state = state.replace("(estimate)", "(weekly cap uncertain)");
    }
    if !p.g("remainingPercent")?.is_null() {
        state = cat!(state, " / ", p.g("remainingPercent")?.tenths()?, "% weekly left");
    }
    if p.g("accounts")?.eq_i(0)? {
        state = "No accounts enabled".to_string();
    }
    let stale = filter(&p.g("members")?.arr(), |member| member.g("reason")?.eq_s("stale"))?.len();
    if stale > 0 {
        state = cat!(state, " / ", stale.to_string(), " expired; awaiting update");
    }
    Ok(Display { state, gain: c.g("projectedGainPercent")?, next_reset_at: c.g("nextResetAt")? })
}

/// `.ToUpper()` for a name in plain ASCII; any other spelling depends on the culture.
fn upper(text: &str) -> R<String> {
    if !printable(text) {
        return unreadable();
    }
    Ok(text.to_ascii_uppercase())
}

/// Format-Hotpl8Overview
pub fn format_overview(overview: &V) -> R<Vec<String>> {
    if !overview.is_obj() {
        return unreadable();
    }
    let mut lines = Vec::new();
    for (provider, p) in overview.props()? {
        let display = capacity_display(&p)?;
        let name = p.g("name")?;
        let title = if name.t()? {
            match name.as_str() {
                Some(text) => upper(text)?,
                None => return unreadable(),
            }
        } else {
            upper(&provider)?
        };
        lines.push(cat!(title, ": ", display.state, "; ", p.g("availability")?, "; ", p.g("automation")?));
        let capacity = p.g("capacity")?;
        if capacity.t()? {
            let display = capacity_display(&p)?;
            lines.push(cat!("  Capacity: ", display.state, "; ", capacity.path(&["critical", "reason"])?));
            lines.push(cat!("  Membership: ", p.g("accounts")?, " enabled; ", p.g("disabled")?, " disabled; ", p.g("duplicates")?, " duplicate entries excluded."));
            if !display.gain.is_null() {
                lines.push(cat!("  Next reset: +", display.gain.tenths()?, "% available at ", display.next_reset_at, "; assumes no further consumption."));
            }
        }
        if p.g("includesReserve")?.t()? {
            lines.push("  Includes reserve allowance.".to_string());
        }
        if p.g("driver")?.eq_s("claude-cswap")? && capacity.t()? {
            let mut profiles = Vec::new();
            for account in where_truthy(&capacity.g("accounts")?.arr(), "profile")? {
                profiles.push(account.g("slot")?.add(&V::s_of("="))?.add(&account.g("profile")?)?.s()?);
            }
            if !profiles.is_empty() {
                lines.push(cat!("  Profiles: ", profiles.join(", ")));
            }
        }
    }
    lines.push("Weekly headroom is an equal-account average, not a token budget; tiers may differ. Short/model limits determine readiness.".to_string());
    Ok(lines)
}

/// Get-Hotpl8ParkCandidates: accounts that look unfunded, from cached evidence only.
/// 'canceled' needs a current reading that reports no paid plan. 'dormant' is a sign-in
/// failure that has outlasted a week; it never claims a cause.
pub fn park_candidates(snapshot: &V, policy: &V, now: Dto) -> R<Vec<V>> {
    let mut out = Vec::new();
    if !snapshot.t()? || !policy.t()? || !fresh_timestamp(&snapshot.g("generatedAt")?, now)? {
        return Ok(out);
    }
    for r in configured_providers(policy, false)? {
        let driver = provider_driver(&r.g("driver")?)?;
        let part = r.g("policy")?;
        let id = r.g("id")?;
        let payload = if id.ceq_s("claude")? && !snapshot.path(&["providers", "claude"])?.t()? {
            snapshot.clone()
        } else {
            snapshot.g("providers")?.gd(&id.s()?)?
        };
        let numeric = driver.g("slotKind")?.eq_s("numeric")?;
        let ids = held(if numeric { part.g("prefer")?.arr() } else { pluck(&filter(&part.g("slots")?.arr(), |slot| slot.t())?, "id")? })?;
        let disabled = part.g("disabled")?;
        for id in filter(&ids, |id| Ok(!id.is_null() && !id.is_in(&disabled)?))? {
            let rows = filter(&payload.g("slots")?.arr(), |row| {
                Ok(row.t()? && if numeric { text_eq(&row.g("slot")?.s()?, &id.s()?)? } else { row.g("id")?.ceq(&id)? })
            })?;
            if rows.len() != 1 {
                continue;
            }
            let row = &rows[0];
            let mut reason = "";
            let mut last = V::Null;
            let label: V;
            if numeric {
                // The login in use is never offered, whatever its last reading says.
                if !row.g("active")?.t()? && row.g("status")?.in_s(&["relogin_required", "no_credentials"])? {
                    reason = "dormant";
                    last = row.g("lastGoodAt")?;
                }
                let named = part.g("labels")?.gd(&id.s()?)?;
                label = if named.t()? { named.sv()? } else { cat!("Slot ", id).into() };
            } else {
                if row.g("status")?.in_s(&["authentication_required", "subscription_login_required"])? {
                    reason = "dormant";
                    last = row.g("observedAt")?;
                } else if row.g("status")?.eq_s("ok")? && row.g("planType")?.ceq_s("free")? && fresh_timestamp(&row.g("observedAt")?, now)? {
                    reason = "canceled";
                    last = row.g("observedAt")?;
                }
                let named = filter(&part.g("slots")?.arr(), |slot| slot.g("id")?.ceq(&id))?.first().cloned().unwrap_or(V::Null).g("label")?.s()?;
                label = if named.is_empty() { id.sv()? } else { named.into() };
            }
            if reason.is_empty() {
                continue;
            }
            let days = catch(|| {
                let days = now.since(Dto::parse(&last.s()?)?).total_days().floor();
                if days < f64::from(i32::MIN) || days > f64::from(i32::MAX) {
                    return throw();
                }
                Ok(days as i32)
            })?;
            // No recorded last reading means no evidence of a long absence.
            if reason == "dormant" && days.is_none_or(|days| days < 7) {
                continue;
            }
            out.push(obj! {
                "provider" => r.g("id")?,
                "providerName" => r.g("name")?,
                "family" => driver.g("provider")?,
                "slot" => id.sv()?,
                "label" => label,
                "reason" => reason,
                "days" => days.map(V::I32),
                "lastReadingAt" => last,
                "planType" => row.g("planType")?,
            });
        }
    }
    Ok(out)
}

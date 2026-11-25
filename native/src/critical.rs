//! Pure emergency selection.

use crate::obj;
use crate::ps::*;
use crate::time::Dto;
use std::cmp::Ordering;

/// Get-Hotpl8CriticalSetting
#[track_caller]
pub fn critical_setting(part: &V, name: &str, default: f64) -> R<f64> {
    let value = part.g("critical")?.g(name)?;
    if value.is_null() {
        Ok(default)
    } else {
        value.dbl()
    }
}

/// Assert-Hotpl8CriticalPolicy
pub fn assert_critical_policy(part: &V) -> R<()> {
    let c = part.g("critical")?;
    if !c.t()? {
        return Ok(());
    }
    if !c.is_obj() {
        return fail("critical must be an object.");
    }
    for (name, _) in c.props()? {
        if !V::s_of(&name).in_s(&["enabled", "enterPercent", "exitPercent", "floorPercent", "drainToZero", "pollSeconds", "dwellSeconds", "advantagePercent"])? {
            return fail("Invalid critical setting.");
        }
    }
    for key in ["enabled", "drainToZero"] {
        let value = c.g(key)?;
        if !value.is_null() && !value.is_bool() {
            return fail("Invalid critical boolean.");
        }
    }
    for key in ["enterPercent", "exitPercent", "floorPercent", "advantagePercent"] {
        let value = c.g(key)?;
        if !value.is_null() && (!value.is_number() || value.lt_i(0)? || value.gt_i(100)?) {
            return fail("Invalid critical percentage.");
        }
    }
    if critical_setting(part, "exitPercent", 25.0)? <= critical_setting(part, "enterPercent", 20.0)? {
        return fail("Critical exit must exceed entry.");
    }
    if critical_setting(part, "floorPercent", 1.0)? > critical_setting(part, "enterPercent", 20.0)? {
        return fail("Critical floor exceeds entry.");
    }
    for key in ["pollSeconds", "dwellSeconds"] {
        let value = c.g(key)?;
        if !value.is_null() && (!value.is_number() || value.lt_i(60)? || value.gt_i(300)?) {
            return fail("Critical timing must be 60-300 seconds.");
        }
    }
    Ok(())
}

/// Get-Hotpl8CriticalDecision. `previous_id` is the caller's value after its [string]
/// parameter conversion: null has already become the empty string.
pub fn critical_decision(accounts: &[V], part: &V, previous_id: &str, state: &V, now: Dto) -> R<V> {
    let previous = V::s_of(previous_id);
    let work = filter(accounts, |account| Ok(!account.g("reserve")?.t()?))?;
    let known = filter(&work, |account| Ok(account.g("fresh")?.t()? && !account.g("blocked")?.t()?))?;
    let threshold =
        V::Dbl(if state.g("active")?.t()? { critical_setting(part, "exitPercent", 25.0)? } else { critical_setting(part, "enterPercent", 20.0)? });
    let active = part.path(&["critical", "enabled"])?.is_true()?
        && !known.is_empty()
        && filter(&known, |account| account.g("bindingRemaining")?.gt(&threshold))?.is_empty()
        && !filter(&known, |account| account.g("bindingRemaining")?.gt_i(0))?.is_empty();
    let mut selected = previous.clone();
    let mut since = state.g("selectedAt")?;
    let mut basis = "normal policy";
    let mut reason = "normal policy";
    let mut ranking: Vec<V> = Vec::new();
    if active {
        let floor = if part.path(&["critical", "drainToZero"])?.t()? { V::I32(0) } else { V::Dbl(critical_setting(part, "floorPercent", 1.0)?) };
        let eligible = filter(&known, |account| {
            let left = account.g("bindingRemaining")?;
            Ok(left.gt_i(0)? && left.ge(&floor)?)
        })?;
        let scaled = !eligible.is_empty() && filter(&eligible, |account| Ok(!account.g("scaled")?.t()?))?.is_empty();
        basis = if scaled { "usable capacity" } else { "binding-window percentage; capacity unknown" };
        let amount = |account: &V| account.g(if scaled { "gross" } else { "bindingRemaining" });
        ranking = sort(
            &eligible,
            |a, b| {
                let first = order_keys(&amount(a)?.neg()?, &amount(b)?.neg()?)?;
                if first != Ordering::Equal {
                    return Ok(first);
                }
                let held = |account: &V| -> R<i32> { Ok(if account.g("slot")?.eq(&previous)? { 0 } else { 1 }) };
                let second = held(a)?.cmp(&held(b)?);
                if second != Ordering::Equal {
                    return Ok(second);
                }
                // Two accounts can only tie on every key when their names differ by case
                // alone, which the culture decides.
                match order_keys(&a.g("slot")?, &b.g("slot")?)? {
                    Ordering::Equal if !a.same_ref(b) => unreadable(),
                    third => Ok(third),
                }
            },
            |a, b| a.same_ref(b),
        )?;
        let best = ranking.first().cloned().unwrap_or(V::Null);
        let prior = filter(&eligible, |account| account.g("slot")?.eq(&previous))?;
        selected = if best.t()? { best.g("slot")? } else { V::Null };
        reason = "largest remaining allowance";
        if best.t()? && !prior.is_empty() && selected.ne(&previous)? {
            let mut age = 0.0;
            if since.t()? {
                let V::Str(text) = &since else { return unreadable() };
                if let Some(parsed) = catch(|| Dto::parse(text))? {
                    age = now.since(parsed).total_seconds();
                }
            }
            let before = amount(&prior[0])?;
            let after = amount(&best)?;
            if age < critical_setting(part, "dwellSeconds", 60.0)?
                || after.lt(&before.mul(&V::Dbl(1.0 + critical_setting(part, "advantagePercent", 10.0)? / 100.0))?)?
            {
                selected = previous.clone();
                reason = "retained to avoid churn";
            }
        }
        if !since.t()? || selected.ne(&state.g("selected")?)? {
            since = now.o().into();
        }
    }
    let floor_percent = if part.path(&["critical", "drainToZero"])?.t()? { V::I32(0) } else { V::Dbl(critical_setting(part, "floorPercent", 1.0)?) };
    Ok(obj! {
        "active" => active,
        "selected" => selected,
        "selectedAt" => since,
        "reason" => reason,
        "basis" => basis,
        "coverage" => format!("{}/{}", known.len(), work.len()),
        "pollSeconds" => if active { V::Dbl(critical_setting(part, "pollSeconds", 60.0)?) } else { V::I32(300) },
        "ranked" => ranking.iter().map(|account| account.g("slot")).collect::<R<Vec<V>>>()?,
        "floorPercent" => floor_percent,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse;

    /// Accounts are ranked by what each holds in weeks of the smallest plan: 3% of an Ultra
    /// week is 0.3, and 20% of a Max five-hour window is 0.1.
    #[test]
    fn critical_mode_ranks_by_usable_capacity_across_plans() {
        set_core(false);
        let now = Dto::parse("2026-11-13T19:36:00.0000000+00:00").ok().unwrap();
        let slot = |id: i32, used5h: &str, limit: &str, used7d: i32, profile: &str| {
            format!(r#"{{"slot":{id},"status":"ok","fresh":true,"observedAt":"2026-11-13T19:36:00.0000000+00:00","used5h":{used5h},"limit5h":"{limit}","reset5h":"2026-11-13T21:30:00.0000000+00:00","used7d":{used7d},"reset7d":"2026-11-15T22:00:00.0000000+00:00","plan":{{"status":"detected","profile":"{profile}","observedAt":"2026-11-13T19:36:00.0000000+00:00"}}}}"#)
        };
        let snapshot = parse(&format!(r#"{{"slots":[{},{}]}}"#, slot(1, "null", "none", 97, "claude-max-20x"), slot(2, "80", "reported", 50, "claude-max-5x")), "").ok().unwrap();
        let part = parse(r#"{"prefer":[2,1],"reserve":[],"critical":{"enabled":true}}"#, "").ok().unwrap();
        let accounts = crate::capacity::capacity_accounts(&snapshot, &part, "claude", now, "", false).ok().unwrap();
        // In the policy's order, Max first.
        let gross: Vec<f64> = accounts.iter().map(|account| (account.g("gross").ok().unwrap().dbl().ok().unwrap() * 100.0).round() / 100.0).collect();
        assert_eq!(gross, [0.1, 0.3]);
        let decision = critical_decision(&accounts, &part, "", &V::Null, now).ok().unwrap();
        assert_eq!(crate::json::write(&decision.g("basis").ok().unwrap(), 0).ok().unwrap(), r#""usable capacity""#);
        assert_eq!(decision.g("ranked").ok().unwrap().each().iter().map(|id| id.s().ok().unwrap()).collect::<Vec<String>>(), ["1", "2"]);
    }
}

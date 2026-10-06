//! src/critical.ps1: pure emergency selection.

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
        return throw();
    }
    for (name, _) in c.props()? {
        if !V::s_of(&name).in_s(&["enabled", "enterPercent", "exitPercent", "floorPercent", "drainToZero", "pollSeconds", "dwellSeconds", "advantagePercent"])? {
            return throw();
        }
    }
    for key in ["enabled", "drainToZero"] {
        let value = c.g(key)?;
        if !value.is_null() && !value.is_bool() {
            return throw();
        }
    }
    for key in ["enterPercent", "exitPercent", "floorPercent", "advantagePercent"] {
        let value = c.g(key)?;
        if !value.is_null() && (!value.is_number() || value.lt_i(0)? || value.gt_i(100)?) {
            return throw();
        }
    }
    if critical_setting(part, "exitPercent", 25.0)? <= critical_setting(part, "enterPercent", 20.0)? {
        return throw();
    }
    if critical_setting(part, "floorPercent", 1.0)? > critical_setting(part, "enterPercent", 20.0)? {
        return throw();
    }
    for key in ["pollSeconds", "dwellSeconds"] {
        let value = c.g(key)?;
        if !value.is_null() && (!value.is_number() || value.lt_i(60)? || value.gt_i(300)?) {
            return throw();
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
                    Ordering::Equal if !a.same_ref(b) => decline(),
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
                let V::Str(text) = &since else { return decline() };
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

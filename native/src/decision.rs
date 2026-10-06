//! src/provider-decision.ps1: no native calls, state writes or provider-name policy branches.

use crate::contract::{provider_account, provider_margin, setting};
use crate::critical::critical_decision;
use crate::obj;
use crate::ps::*;
use crate::selection::selection_key;
use crate::time::Dto;
use std::cmp::Ordering;

/// `Sort-Object reserve,degraded,rankKey,preference,id`
fn rank_order(a: &V, b: &V) -> R<Ordering> {
    for name in ["reserve", "degraded", "rankKey", "preference"] {
        let order = order_keys(&a.g(name)?, &b.g(name)?)?;
        if order != Ordering::Equal {
            return Ok(order);
        }
    }
    let (left, right) = (a.g("id")?.s()?, b.g("id")?.s()?);
    if left == right {
        return Ok(Ordering::Equal);
    }
    // Names that differ by case alone are ordered by the culture.
    match order_text(&left, &right)? {
        Ordering::Equal => decline(),
        order => Ok(order),
    }
}
fn same_id(a: &V, b: &V) -> bool {
    matches!((a.g("id"), b.g("id")), (Ok(V::Str(left)), Ok(V::Str(right))) if left == right)
}
fn ids(rows: &[V]) -> R<Vec<V>> {
    rows.iter().map(|row| row.g("id")).collect()
}
/// `$rows | Where-Object id -CEQ $id`
fn with_id(rows: &[V], id: &V) -> R<Vec<V>> {
    filter(rows, |row| row.g("id")?.ceq(id))
}

/// Get-Hotpl8ProviderDecision, for the one intent the status path uses.
pub fn provider_decision(accounts: &V, policy: &V, context: &V, now: Dto) -> R<V> {
    let intent = if context.g("intent")?.t()? { context.g("intent")?.s()? } else { "observe".to_string() };
    if !V::s_of(&intent).in_s(&["observe", "admit", "rebind", "refresh", "control", "warm", "probe"])? {
        return throw();
    }
    if intent != "observe" {
        return decline();
    }
    let scopes = filter(&context.g("scopes")?.arr(), |scope| scope.t())?;
    let mut rows = Vec::new();
    for account in accounts.arr() {
        if account.t()? {
            rows.push(provider_account(&account, policy, &scopes, now)?);
        }
    }
    // Every duplicate is excluded; array order cannot decide which identity wins.
    for row in &rows {
        if with_id(&rows, &row.g("id")?)?.len() > 1 {
            row.set("reason", "duplicate_observation".into())?;
            row.set("valid", false.into())?;
        } else if row.g("identityKey")?.t()? {
            let key = row.g("identityKey")?;
            if filter(&rows, |other| other.g("identityKey")?.ceq(&key))?.len() > 1 {
                row.set("reason", "duplicate_subscription".into())?;
                row.set("valid", false.into())?;
            }
        }
    }
    let previous = if context.g("bindingKnown")?.is_true()? { context.g("previousId")?.sv()? } else { V::Null };
    let mut capacity = Vec::new();
    for row in &rows {
        capacity.push(obj! {
            "slot" => row.g("id")?,
            "reserve" => row.g("reserve")?,
            "fresh" => row.g("valid")?,
            "blocked" => !row.g("valid")?.t()?,
            "bindingRemaining" => row.g("bindingRemaining")?,
            "scaled" => row.g("scaled")?,
            "gross" => row.g("gross")?,
        });
    }
    let critical = if context.g("eligibilityOnly")?.is_true()? {
        obj! {
            "active" => false,
            "selected" => &previous,
            "ranked" => Vec::<V>::new(),
            "pollSeconds" => 300,
            "selectedAt" => context.path(&["criticalState", "selectedAt"])?,
            "reason" => "eligibility only",
        }
    } else {
        critical_decision(&capacity, policy, &previous.s()?, &context.g("criticalState")?, now)?
    };
    let order = setting(policy, "order", "prefer".into())?;
    let mut eligible = Vec::new();
    for row in &rows {
        let mut reason = row.g("reason")?;
        if !reason.t()? {
            for window in filter(&row.g("windows")?.arr(), |window| window.g("state")?.eq_s("observed"))? {
                let left = window.g("remainingPercent")?;
                if left.le_i(0)?
                    || left.lt(&provider_margin(policy, row, &window, critical.g("active")?.t()? || context.g("emergency")?.is_true()?)?)?
                {
                    reason = "below_margin".into();
                    break;
                }
            }
        }
        row.add_member("eligible", V::Bool(!reason.t()?), false)?;
        row.set("reason", if reason.t()? { reason } else { "eligible".into() })?;
        let weekly = row.g("weeklyRemaining")?;
        let degraded = !weekly.is_null() && weekly.lt(&setting(policy, "margin7d", V::I32(20))?)?;
        let mut key = V::Dbl(row.g("preference")?.dbl()?);
        if order.eq_s("soonest-reset")? {
            key = V::Dbl(f64::MAX);
            if row.g("resetAt")?.t()? {
                key = V::Dbl(Dto::of(&row.g("resetAt")?)?.unix_seconds() as f64);
            }
        } else if order.in_s(&["weekly-expiry", "balanced"])? {
            key = selection_key(&order.s()?, &row.g("shortRemaining")?, &row.g("weeklyRemaining")?, &row.g("weeklyResetAt")?, now)?;
        }
        if degraded {
            key = weekly.neg_dbl()?;
        }
        row.add_member("degraded", degraded.into(), false)?;
        row.add_member("rankKey", key, false)?;
        if row.g("eligible")?.t()? {
            eligible.push(row.clone());
        }
    }
    let mut ordered = sort(&eligible, rank_order, same_id)?;
    let mut proposed = match ordered.first() {
        Some(best) => best.g("id")?,
        None => V::Null,
    };
    let prior = with_id(&eligible, &previous)?;
    if critical.g("active")?.t()? && !critical.g("ranked")?.each().is_empty() {
        ordered = Vec::new();
        for id in critical.g("ranked")?.each() {
            ordered.extend(with_id(&eligible, &id)?);
        }
        let selected = critical.g("selected")?;
        proposed = if with_id(&ordered, &selected)?.is_empty() { V::Null } else { selected };
    } else if prior.len() == 1 && proposed.t()? && proposed.cne(&previous)? {
        let (best, old) = (&ordered[0], &prior[0]);
        if best.g("reserve")?.eq(&old.g("reserve")?)? && best.g("degraded")?.eq(&old.g("degraded")?)? {
            if best.g("degraded")?.t()? {
                if best.g("weeklyRemaining")?.le(&old.g("weeklyRemaining")?)? {
                    proposed = previous.clone();
                }
            } else if order.eq_s("soonest-reset")? {
                if best.g("resetAt")?.t()?
                    && old.g("resetAt")?.t()?
                    && V::Dbl(Dto::of(&old.g("resetAt")?)?.since(Dto::of(&best.g("resetAt")?)?).total_minutes())
                        .lt(&setting(policy, "resetLeadMin", V::I32(10))?)?
                {
                    proposed = previous.clone();
                }
            } else if !best.g("shortRemaining")?.is_null()
                && best.g("shortRemaining")?.lt(&setting(policy, "margin5h", V::I32(25))?.add(&setting(policy, "hysteresis", V::I32(10))?)?)?
            {
                proposed = previous.clone();
            }
        }
    }
    let mut target = proposed.clone();
    let mut suppression = V::Null;
    if context.g("safetyInvalid")?.is_true()? {
        suppression = "safety_state_invalid".into();
    } else {
        if context.g("hold")?.is_true()? {
            if !previous.t()? {
                suppression = "binding_unknown".into();
                target = V::Null;
            } else if prior.len() == 1 {
                target = previous.clone();
            } else {
                target = V::Null;
                suppression = "held_account_unavailable".into();
            }
        }
        if !target.t()? && !suppression.t()? {
            suppression = "unavailable".into();
        }
        suppression = if suppression.t()? { suppression } else { "observe_only".into() };
    }
    let permitted = !suppression.t()?;
    Ok(obj! {
        "accounts" => rows.clone(),
        "ranked" => ids(&ordered)?,
        "allRanked" => ids(&sort(&rows, rank_order, same_id)?)?,
        "proposedSlot" => proposed,
        "targetSlot" => target,
        "actionPermitted" => permitted,
        "suppressionReason" => suppression,
        "manual" => false,
        "requiresNativeValidation" => permitted,
        "critical" => critical,
    })
}

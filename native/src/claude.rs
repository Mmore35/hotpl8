//! The rules of src/providers/claude.ps1 that the status path reads: which account the
//! cached readings would select. Nothing here talks to an account.

use crate::capacity::capacity_accounts;
use crate::contract::{provider_margin, strings};
use crate::decision::provider_decision;
use crate::observation::{add_observation_capacity, claude_entry_observation};
use crate::ps::*;
use crate::time::Dto;
use crate::{hash, obj};

/// `$claudeAccounts`: a table keyed by slot number.
#[derive(Default)]
pub struct Accounts(Vec<(i32, V)>);
impl Accounts {
    pub fn put(&mut self, slot: i32, entry: V) {
        match self.0.iter_mut().find(|(known, _)| *known == slot) {
            Some(found) => found.1 = entry,
            None => self.0.push((slot, entry)),
        }
    }
    fn get(&self, slot: i32) -> V {
        self.0.iter().find(|(known, _)| *known == slot).map_or(V::Null, |(_, entry)| entry.clone())
    }
}

/// Get-ClaudeModelBlock
pub fn model_block(scopes: &V, policy: &V, slot: i32, now: Dto, observed_at: &V) -> R<V> {
    let models = filter(&policy.g("claudeModels")?.arr(), |model| model.t())?;
    if models.is_empty() {
        return Ok(V::Null);
    }
    let stamp = if observed_at.t()? { observed_at.clone() } else { now.o().into() };
    let mut windows = Vec::new();
    for model in models {
        let matches = filter(&scopes.arr(), |scope| scope.g("name")?.ceq(&model))?;
        let scope = if matches.len() == 1 { matches[0].clone() } else { V::Null };
        windows.push(obj! {
            "name" => model.sv()?,
            "scope" => model.sv()?,
            "role" => "scoped",
            "state" => if scope.t()? { "observed" } else { "unknown" },
            "required" => true,
            "usedPercent" => scope.g("pct")?,
            "resetAt" => scope.g("resetsAt")?,
            "observedAt" => &stamp,
            "resetConfirmed" => scope.g("resetsAt")?.t()?,
            "resetRequired" => true,
        });
    }
    let account = hash! {"id" => slot.to_string(), "status" => "ok", "observedAt" => &stamp, "windows" => windows};
    let decision = provider_decision(&vec![account].into(), policy, &hash! {"intent" => "observe", "eligibilityOnly" => true}, now)?;
    let reason = decision.g("accounts")?.first()?.g("reason")?;
    Ok(if reason.eq_s("eligible")? {
        V::Null
    } else if reason.eq_s("below_margin")? {
        "model_below_margin".into()
    } else if reason.eq_s("reset_unconfirmed")? {
        "model_reset_unconfirmed".into()
    } else {
        "model_quota_unknown".into()
    })
}

/// Test-Ok. PowerShell reads the clock here; every time it compares is that same reading,
/// so the answer is the one any single instant gives.
pub fn test_ok(e: &V, m: V, margin7d: V, now: Dto) -> R<V> {
    let mut windows = Vec::new();
    for shape in [["300", "short", "h5"], ["10080", "weekly", "h7"]] {
        let headroom = e.g(shape[2])?;
        windows.push(obj! {
            "name" => shape[0],
            "scope" => "",
            "role" => shape[1],
            "state" => "observed",
            "required" => true,
            "usedPercent" => if headroom.is_number() { V::Dbl(100.0 - headroom.dbl()?) } else { V::Null },
            "resetAt" => V::Null,
            "observedAt" => now.o(),
            "resetConfirmed" => false,
        });
    }
    let account = hash! {
        "id" => "headroom",
        "status" => if e.g("fresh")?.t()? { "ok" } else { "stale" },
        "observedAt" => now.o(),
        "windows" => windows,
        "blockedReason" => if e.g("modelBlocked")?.t()? { V::s_of("model_quota_unknown") } else { V::Null },
    };
    let policy = hash! {"margin5h" => m, "margin7d" => margin7d};
    let decision = provider_decision(&vec![account].into(), &policy, &hash! {"intent" => "observe", "eligibilityOnly" => true}, now)?;
    decision.g("accounts")?.first()?.g("eligible")
}

/// Get-Margin7dFor
pub fn margin_7d_for(policy: &V, n: &V) -> R<V> {
    let reserve = n.sv()?.is_in_list(&strings(&policy.g("reserve")?)?)?;
    provider_margin(policy, &hash! {"reserve" => reserve}, &hash! {"role" => "weekly"}, false)
}

/// Get-ClaudeProviderDecision, called as Get-ClaudeSelection calls it: without a context.
fn claude_provider_decision(policy: &V, prefer: &[i32], accounts: &Accounts, active: i32, now: Dto, critical_state: &V) -> R<V> {
    // Legacy Claude omitted these fields as zero. Registered views already carry
    // descriptor defaults; preserve explicit values without mutating either input.
    let decision_policy = hash! {};
    for (name, value) in policy.props()? {
        decision_policy.set(&name, value)?;
    }
    for key in ["margin5h", "hysteresis"] {
        if decision_policy.g(key)?.is_null() {
            decision_policy.set(key, V::I32(0))?;
        }
    }
    let mut observations = Vec::new();
    for id in prefer {
        observations.push(claude_entry_observation(&accounts.get(*id))?);
    }
    let mut slots = Vec::new();
    for id in prefer {
        let e = accounts.get(*id);
        let (h5, h7) = (e.g("h5")?, e.g("h7")?);
        let usage = e.path(&["obj", "usage"])?;
        slots.push(obj! {
            "slot" => *id,
            "status" => if e.g("fresh")?.t()? && !e.g("modelBlocked")?.t()? { "ok" } else { "unavailable" },
            "fresh" => e.g("fresh")?.t()?,
            "observedAt" => if e.g("observedAt")?.t()? { e.g("observedAt")? } else { now.o().into() },
            "used5h" => if h5.is_number() { V::I32(100).sub(&h5)? } else { V::Null },
            "used7d" => if h7.is_number() { V::I32(100).sub(&h7)? } else { V::Null },
            "reset5h" => usage.path(&["fiveHour", "resetsAt"])?,
            "reset7d" => usage.path(&["sevenDay", "resetsAt"])?,
            "scoped" => usage.g("scoped")?,
        });
    }
    let capacity = capacity_accounts(&obj! {"slots" => slots}, policy, "claude", now, "codex", false)?;
    let observations = add_observation_capacity(&observations, &capacity)?;
    let context = hash! {"intent" => "observe", "previousId" => active.to_string(), "bindingKnown" => active > 0, "criticalState" => critical_state};
    provider_decision(&observations.into(), &decision_policy, &context, now)
}

/// Get-ClaudeSelection: the target and whether the active account is still eligible.
pub fn claude_selection(policy: &V, prefer: &[i32], accounts: &Accounts, active: i32, now: Dto, critical_state: &V) -> R<(V, bool)> {
    let decision = claude_provider_decision(policy, prefer, accounts, active, now, critical_state)?;
    let active_text = active.to_string();
    let proposed = decision.g("proposedSlot")?;
    let target = if proposed.t()? && proposed.ne_s(&active_text)? { V::I32(proposed.to_int()?) } else { V::Null };
    let active_ok = filter(&decision.g("accounts")?.each(), |account| Ok(account.g("id")?.eq_s(&active_text)? && account.g("eligible")?.t()?))?.len() == 1;
    let ranked = if decision.path(&["critical", "active"])?.t()? { decision.g("ranked")? } else { decision.g("allRanked")? };
    for id in ranked.each() {
        id.to_int()?;
    }
    Ok((target, active_ok))
}

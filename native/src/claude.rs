//! The Claude rules the status path reads: which account the
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
    pub fn get(&self, slot: i32) -> V {
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

/// Get-ClaudeProviderDecision. Without a context the decision only observes.
pub fn claude_provider_decision(policy: &V, prefer: &[i32], accounts: &Accounts, active: i32, now: Dto, critical_state: &V, context: Option<&V>) -> R<V> {
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
        let for_warm = match context {
            Some(context) => context.g("intent")?.eq_s("warm")? && context.g("actionSlot")?.sv()?.ceq_s(&id.to_string())?,
            None => false,
        };
        observations.push(claude_entry_observation(&V::I32(*id), &accounts.get(*id), policy, now, for_warm)?);
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
    let observing = hash! {"intent" => "observe", "previousId" => active.to_string(), "bindingKnown" => active > 0, "criticalState" => critical_state};
    provider_decision(&observations.into(), &decision_policy, context.unwrap_or(&observing), now)
}

/// What Get-ClaudeSelection answers.
pub struct Selection {
    /// The account to move to, when it is not the active one.
    pub target: V,
    /// Whether the active account is still eligible.
    pub active_ok: bool,
    pub ranked: Vec<i32>,
    pub critical: V,
}

/// Get-ClaudeSelection
pub fn claude_selection(policy: &V, prefer: &[i32], accounts: &Accounts, active: i32, now: Dto, critical_state: &V) -> R<Selection> {
    let decision = claude_provider_decision(policy, prefer, accounts, active, now, critical_state, None)?;
    let active_text = active.to_string();
    let proposed = decision.g("proposedSlot")?;
    let target = if proposed.t()? && proposed.ne_s(&active_text)? { V::I32(proposed.to_int()?) } else { V::Null };
    let active_ok = filter(&decision.g("accounts")?.each(), |account| Ok(account.g("id")?.eq_s(&active_text)? && account.g("eligible")?.t()?))?.len() == 1;
    let critical = decision.g("critical")?;
    let ranked = if critical.g("active")?.t()? { decision.g("ranked")? } else { decision.g("allRanked")? };
    let ranked = ranked.each().iter().map(V::to_int).collect::<R<Vec<i32>>>()?;
    Ok(Selection { target, active_ok, ranked, critical })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse;

    fn entry(h5: i32, h7: i32, reset: &str, cold: bool) -> V {
        let native = format!(
            r#"{{"usageStatus":"ok","usageAgeSeconds":10,"usage":{{"fiveHour":{{"pct":{},"resetsAt":"{reset}"}},"sevenDay":{{"pct":{},"resetsAt":"2026-10-09T12:00:00.0000000+00:00"}}}}}}"#,
            100 - h5,
            100 - h7
        );
        hash! {"h5" => V::Dbl(f64::from(h5)), "h7" => V::Dbl(f64::from(h7)), "fresh" => true, "cold" => cold, "obj" => parse(&native, "").ok().unwrap()}
    }

    /// What Get-ClaudeProviderDecision answers for each of these, on both PowerShell
    /// editions: reason, target, permitted, manual, native validation, proposal, accounts.
    const DECIDED: &str = "observe|observe_only|1|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
rebind||1|True|False|True|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
rebind monitor|monitor_only|1|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
rebind paused|automation_paused|1|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
rebind switching off|switching_disabled|1|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
rebind held|selection_held|2|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
rebind blocked|outside_work_hours|1|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
rebind unbound|binding_unknown|1|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
rebind unbound held|binding_unknown||False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
rebind unsafe|safety_state_invalid|1|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
warm cold||3|True|False|True|1|1=eligible/True/True,2=eligible/True/True,3=eligible/True/True,4=reset_unconfirmed/False/False
warm unconfirmed|action_ineligible|4|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
warm off|action_disabled|3|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=eligible/True/True,4=reset_unconfirmed/False/False
warm unknown|action_target_unknown|9|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
warm none|action_target_unknown||False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
warm ineligible|action_ineligible|3|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=eligible/True/True,4=reset_unconfirmed/False/False
warm held||3|True|False|True|1|1=eligible/True/True,2=eligible/True/True,3=eligible/True/True,4=reset_unconfirmed/False/False
warm paused|automation_paused|3|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=eligible/True/True,4=reset_unconfirmed/False/False
probe unconfirmed||4|True|False|True|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
probe blocked|daily_attempt_limit|1|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
refresh||2|True|False|True|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
refresh unknown|binding_unknown|2|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
refresh unbound|binding_unknown||False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
control||2|True|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
admit||1|True|False|True|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
admit pinned||3|True|True|True|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
admit pinned unknown|binding_changed|1|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
admit held||2|True|False|True|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False
observe held|observe_only|2|False|False|False|1|1=eligible/True/True,2=eligible/True/True,3=reset_unconfirmed/False/False,4=reset_unconfirmed/False/False";

    #[test]
    fn each_intent_is_permitted_or_turned_down_for_one_reason() {
        let now = Dto::parse("2026-10-06T12:00:00.0000000+00:00").ok().unwrap();
        let policy = parse(r#"{"prefer":[1,2,3,4],"order":"prefer","margin5h":25,"margin7d":20,"hysteresis":10}"#, "").ok().unwrap();
        let mut accounts = Accounts::default();
        accounts.put(1, entry(80, 70, "2026-10-06T14:00:00.0000000+00:00", false));
        accounts.put(2, entry(60, 50, "2026-10-06T15:00:00.0000000+00:00", false));
        // Two accounts whose short window has no reset time: one cold, one not.
        accounts.put(3, entry(95, 90, "", true));
        accounts.put(4, entry(95, 90, "", false));
        let decide = |extra: Option<V>| {
            let context = extra.map(|extra| {
                let context = obj! {"previousId" => "2", "bindingKnown" => true, "criticalState" => V::Null, "mode" => "automate", "switching" => true, "paused" => false, "hold" => false};
                for (name, value) in extra.props().ok().unwrap() {
                    context.add_member(&name, value, true).ok().unwrap();
                }
                context
            });
            claude_provider_decision(&policy, &[1, 2, 3, 4], &accounts, 2, now, &V::Null, context.as_ref())
        };
        let cases = [
            ("observe", None),
            ("rebind", Some(obj! {"intent" => "rebind"})),
            ("rebind monitor", Some(obj! {"intent" => "rebind", "mode" => "monitor"})),
            ("rebind paused", Some(obj! {"intent" => "rebind", "paused" => true})),
            ("rebind switching off", Some(obj! {"intent" => "rebind", "switching" => false})),
            ("rebind held", Some(obj! {"intent" => "rebind", "hold" => true})),
            ("rebind blocked", Some(obj! {"intent" => "rebind", "actionBlock" => "outside_work_hours"})),
            ("rebind unbound", Some(obj! {"intent" => "rebind", "bindingKnown" => false})),
            ("rebind unbound held", Some(obj! {"intent" => "rebind", "bindingKnown" => false, "hold" => true})),
            ("rebind unsafe", Some(obj! {"intent" => "rebind", "safetyInvalid" => true})),
            ("warm cold", Some(obj! {"intent" => "warm", "actionSlot" => "3", "actionEligible" => true, "actionEnabled" => true})),
            ("warm unconfirmed", Some(obj! {"intent" => "warm", "actionSlot" => "4", "actionEligible" => true, "actionEnabled" => true})),
            ("warm off", Some(obj! {"intent" => "warm", "actionSlot" => "3", "actionEligible" => true, "actionEnabled" => false})),
            ("warm unknown", Some(obj! {"intent" => "warm", "actionSlot" => "9", "actionEligible" => true, "actionEnabled" => true})),
            ("warm none", Some(obj! {"intent" => "warm", "actionEligible" => true, "actionEnabled" => true})),
            ("warm ineligible", Some(obj! {"intent" => "warm", "actionSlot" => "3", "actionEligible" => false, "actionEnabled" => true})),
            ("warm held", Some(obj! {"intent" => "warm", "actionSlot" => "3", "actionEligible" => true, "actionEnabled" => true, "hold" => true})),
            ("warm paused", Some(obj! {"intent" => "warm", "actionSlot" => "3", "actionEligible" => true, "actionEnabled" => true, "paused" => true})),
            ("probe unconfirmed", Some(obj! {"intent" => "probe", "actionSlot" => "4", "actionEligible" => true, "actionEnabled" => true})),
            ("probe blocked", Some(obj! {"intent" => "probe", "actionSlot" => "1", "actionEligible" => true, "actionEnabled" => true, "actionBlock" => "daily_attempt_limit"})),
            ("refresh", Some(obj! {"intent" => "refresh", "identityKnown" => true})),
            ("refresh unknown", Some(obj! {"intent" => "refresh"})),
            ("refresh unbound", Some(obj! {"intent" => "refresh", "identityKnown" => true, "bindingKnown" => false})),
            ("control", Some(obj! {"intent" => "control", "safetyInvalid" => true})),
            ("admit", Some(obj! {"intent" => "admit"})),
            ("admit pinned", Some(obj! {"intent" => "admit", "pin" => "3"})),
            ("admit pinned unknown", Some(obj! {"intent" => "admit", "pin" => "9"})),
            ("admit held", Some(obj! {"intent" => "admit", "hold" => true})),
            ("observe held", Some(obj! {"intent" => "observe", "hold" => true})),
        ];
        let mut said = Vec::new();
        for (name, extra) in cases {
            let d = decide(extra).ok().unwrap();
            let text = |key: &str| d.g(key).ok().unwrap().s().ok().unwrap();
            let rows = d.g("accounts").ok().unwrap().each();
            let reasons: Vec<String> = rows
                .iter()
                .map(|row| {
                    let part = |key: &str| row.g(key).ok().unwrap().s().ok().unwrap();
                    format!("{}={}/{}/{}", part("id"), part("reason"), part("valid"), part("eligible"))
                })
                .collect();
            said.push(format!(
                "{name}|{}|{}|{}|{}|{}|{}|{}",
                text("suppressionReason"),
                text("targetSlot"),
                text("actionPermitted"),
                text("manual"),
                text("requiresNativeValidation"),
                text("proposedSlot"),
                reasons.join(",")
            ));
        }
        for (said, decided) in said.iter().zip(DECIDED.lines()) {
            assert_eq!(said, decided);
        }
        assert_eq!(said.len(), DECIDED.lines().count());
        assert!(decide(Some(obj! {"intent" => "nonsense"})).err().unwrap().thrown());
    }
}

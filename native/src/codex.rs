//! The rules of src/providers/codex.ps1 that the status path reads, and the Codex lines
//! of `hotpl8 status`.

use crate::capacity::capacity_accounts;
use crate::critical::critical_decision;
use crate::decision::provider_decision;
use crate::observation::{add_observation_capacity, codex_observation};
use crate::ps::*;
use crate::time::{local_offset_minutes, Dto};
use crate::{cat, hash, obj};

/// Get-CodexEligibility
pub fn codex_eligibility(slot: &V, policy: &V, meter: &str, now: Dto, emergency: bool) -> R<V> {
    let account = codex_observation(slot, meter)?;
    let context = hash! {"intent" => "observe", "scopes" => vec![V::s_of(meter)], "eligibilityOnly" => true, "emergency" => emergency};
    let decision = provider_decision(&vec![account].into(), policy, &context, now)?;
    let reason = decision.g("accounts")?.first()?.g("reason")?;
    // Public compatibility codes; the shared decision keeps its detailed reason.
    if reason.in_s(&["window_unknown", "model_quota_unknown"])? {
        return Ok("unknown".into());
    }
    if reason.eq_s("window_stale")? {
        return Ok("stale".into());
    }
    Ok(reason)
}

/// Select-CodexSlot
pub fn select_codex_slot(slots: &[V], policy: &V, meter: &str, previous_id: &str, hold: &V, now: Dto, critical_state: &V) -> R<V> {
    let mut observations = Vec::new();
    for slot in slots {
        observations.push(codex_observation(slot, meter)?);
    }
    let snapshot = obj! {"providers" => hash! {"codex" => hash! {"slots" => slots.to_vec()}}};
    let capacity = capacity_accounts(&snapshot, policy, "codex", now, meter, false)?;
    let observations = add_observation_capacity(&observations, &capacity)?;
    let context = hash! {
        "intent" => "observe",
        "scopes" => vec![V::s_of(meter)],
        "previousId" => previous_id,
        "bindingKnown" => !previous_id.is_empty(),
        "hold" => hold.t()?,
        "criticalState" => critical_state,
    };
    provider_decision(&observations.into(), policy, &context, now)?.g("targetSlot")
}

/// `$reasons`: a table keyed by slot name. Its comparison ignores case by the rules of
/// the current culture, so names that differ by case alone decline.
#[derive(Default)]
struct Reasons(Vec<(String, V)>);
impl Reasons {
    fn find(&self, key: &str) -> R<Option<usize>> {
        for (index, (known, _)) in self.0.iter().enumerate() {
            if known == key {
                return Ok(Some(index));
            }
            if !printable(known) || !printable(key) || known.eq_ignore_ascii_case(key) {
                return decline();
            }
        }
        Ok(None)
    }
    fn put(&mut self, key: String, value: V) -> R<()> {
        match self.find(&key)? {
            Some(index) => self.0[index].1 = value,
            None => self.0.push((key, value)),
        }
        Ok(())
    }
    fn get(&self, key: &str) -> R<V> {
        Ok(self.find(key)?.map_or(V::Null, |index| self.0[index].1.clone()))
    }
}

/// Format-CodexStatus
pub fn format_codex_status(codex: &V, policy: &V, now: Dto) -> R<Vec<String>> {
    let recommended = codex.g("recommendedSlot")?;
    let mut chosen = if recommended.t()? { recommended.s()? } else { "unavailable".to_string() };
    let meter = codex.g("defaultMeter")?.s()?;
    let critical_accounts = capacity_accounts(&obj! {"providers" => hash! {"codex" => codex}}, policy, "codex", now, &meter, false)?;
    let states = codex.g("critical")?;
    // `$null.$name` is null whatever the name; any other name taken from data is checked.
    let state = if states.is_null() { V::Null } else { states.gd(&meter)? };
    let critical = critical_decision(&critical_accounts, policy, &chosen, &state, now)?;
    let mut reasons = Reasons::default();
    for slot in codex.g("slots")?.arr() {
        let mut reason = slot.g("status")?.sv()?;
        if reason.eq_s("ok")? {
            match catch(|| Ok(now.since(Dto::of(&slot.g("observedAt")?)?).total_seconds()))? {
                Some(age) => {
                    if age < -5.0 || age > 900.0 {
                        reason = "stale".into();
                    }
                }
                None => reason = "unknown".into(),
            }
            if reason.eq_s("ok")? && policy.t()? {
                reason = codex_eligibility(&slot, policy, &meter, now, critical.g("active")?.t()?)?;
            }
        }
        reasons.put(slot.g("id")?.s()?, reason)?;
    }
    // A cached selection is a historical decision. Recheck admission at display
    // time without polling or rewriting the snapshot, including per-slot age.
    if reasons.find(&chosen)?.is_none() || !reasons.get(&chosen)?.in_s(&["ok", "eligible"])? {
        chosen = "unavailable".to_string();
    }
    let mut lines = vec![cat!("Codex: next launch = ", chosen, " | ", codex.g("status")?, " | observed ", codex.g("observedAt")?)];
    for slot in codex.g("slots")?.arr() {
        let reason = reasons.get(&slot.g("id")?.s()?)?;
        lines.push(cat!("  ", slot.g("label")?, " [", slot.g("id")?, "] ", reason, " | quota observed ", slot.g("observedAt")?));
        for (name, bucket) in slot.g("buckets")?.props()? {
            let mut parts = Vec::new();
            for (window, w) in bucket.g("windows")?.props()? {
                let resets_at = w.g("resetsAt")?;
                let reset = if resets_at.is_null() {
                    "unknown".to_string()
                } else {
                    let at = Dto::from_unix_seconds(resets_at.to_long()?)?;
                    Dto { ticks: at.ticks, offset_minutes: local_offset_minutes(at, now)? }.month_day_time()
                };
                let duration = if text_eq(&window, "300")? { "5h" } else { "7d" };
                parts.push(cat!(duration, " ", w.g("remainingPercent")?, "% remaining; reset ", reset, " (", w.g("anchorState")?, ")"));
            }
            lines.push(cat!("    ", &*name, ": ", bucket.g("status")?, " | ", parts.join(" | "), " | warm: ", bucket.g("warm")?));
        }
    }
    Ok(lines)
}

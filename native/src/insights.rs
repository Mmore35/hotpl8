//! The reading half of src/insights.ps1: the stored snapshot as a reader sees it, and the
//! text of `hotpl8 status` and `hotpl8 explain`.

use std::path::Path;

use crate::capacity::fresh_timestamp;
use crate::codex::format_codex_status;
use crate::json;
use crate::overview::{format_overview, park_candidates, provider_overview};
use crate::pause::pause;
use crate::ps::*;
use crate::registry::{configured_providers, provider_view};
use crate::time::Dto;
use crate::{cat, obj};

/// Get-Hotpl8Health
pub fn health(collector: &V, now: Dto, provider: &str) -> R<String> {
    if !collector.t()? {
        return Ok("manual / no collector evidence".to_string());
    }
    let state = catch(|| {
        let started = Dto::of(&collector.g("startedAt")?)?;
        if started.ticks > now.plus_seconds(5)?.ticks {
            return Ok("collector state invalid");
        }
        let completed_at = collector.g("completedAt")?;
        if !completed_at.t()? || Dto::of(&completed_at)?.ticks < started.ticks {
            if now.since(started).total_seconds() > 240.0 {
                return Ok("collector stalled");
            }
            return Ok("collecting");
        }
        let completed = Dto::of(&completed_at)?;
        if now.since(completed).total_seconds() > 900.0 {
            return Ok("collector overdue");
        }
        let providers = collector.g("providers")?;
        if !provider.is_empty() && providers.g(provider)?.t()? {
            let p = providers.g(provider)?;
            if p.g("failureCode")?.eq_s("state_io_failed")? {
                return Ok("local state write failed; retrying");
            }
            if p.g("status")?.eq_s("ok")? {
                let age = now.since(Dto::of(&p.g("lastSuccessAt")?)?).total_seconds();
                if age > 900.0 || age < -5.0 {
                    return Ok("provider readings stale");
                }
                return Ok("recent collection completed");
            }
            return Ok("provider checks incomplete");
        }
        for (_, entry) in providers.props()? {
            if entry.g("failureCode")?.eq_s("state_io_failed")? {
                return Ok("local state write failed; retrying");
            }
        }
        if collector.g("status")?.ne_s("ok")? {
            return Ok("provider checks incomplete");
        }
        Ok("recent collection completed")
    })?;
    Ok(state.unwrap_or("collector state invalid").to_string())
}

/// Read-Hotpl8Snapshot as `status` and `explain` call it. `explicit` says the reader
/// policy came from -PreviewPolicy; otherwise it is the stored policy, read once.
pub fn read_snapshot(directory: &Path, reader_policy: &V, explicit: bool, now: Dto) -> R<V> {
    let mut s = json::read_file(&directory.join("status.json"))?.unwrap_or(V::Null);
    let c = json::read_file(&directory.join("collector.json"))?.unwrap_or(V::Null);
    let pause = pause(directory, now)?;
    // First collection can stall before there is a snapshot. Show that evidence too.
    if !s.t()? && (c.t()? || pause.t()?) {
        s = obj! {"schemaVersion" => 2, "generatedAt" => V::Null, "slots" => Vec::<V>::new()};
    }
    if !s.t()? {
        return Ok(s);
    }
    if c.t()? {
        // A failed trailing collector.json write can leave its earlier
        // "started" marker behind a successfully published snapshot.
        // Prefer the completed evidence embedded in that newer snapshot.
        let newer = catch(|| {
            let embedded = s.path(&["collector", "completedAt"])?;
            if !embedded.t()? {
                return Ok(true);
            }
            let completed = Dto::of(&embedded)?;
            Ok(Dto::of(&c.g("startedAt")?)?.ticks > completed.ticks || (c.g("completedAt")?.t()? && Dto::of(&c.g("completedAt")?)?.ticks >= completed.ticks))
        })?;
        if newer.unwrap_or(true) {
            s.add_member("collector", c, true)?;
        }
    }
    s.add_member("automationPause", pause, true)?;
    if explicit {
        s.add_member("displayPolicy", "explicit reader policy".into(), true)?;
    }
    s.add_member("providerOverview", provider_overview(&s, reader_policy, now)?, true)?;
    // Advice only: a detector failure must never cost a reader its snapshot.
    let candidates = catch(|| park_candidates(&s, reader_policy, now))?.unwrap_or_default();
    s.add_member("parkCandidates", candidates.into(), true)?;
    Ok(s)
}

/// `$name + …`: the text only when the name is a string.
fn name_text(name: &V) -> R<String> {
    match name.as_str() {
        Some(text) => Ok(text.to_string()),
        None => decline(),
    }
}

/// `$line -replace '^Codex', $name`
fn rename_codex(line: &str, name: &str) -> R<String> {
    if name.contains('$') {
        return decline();
    }
    match line.get(..5) {
        Some(head) if head.eq_ignore_ascii_case("codex") => Ok(cat!(name, &line[5..])),
        _ => Ok(line.to_string()),
    }
}

/// Format-Hotpl8Forecast
fn format_forecast(forecast: &V) -> R<String> {
    if !forecast.t()? {
        return Ok("Pace: not enough fresh history".to_string());
    }
    let hours = forecast.g("secondsToLimit")?.div(&V::I32(3600))?.round1()?;
    let outlook = if forecast.g("lastsToReset")?.t()? { "likely lasts to reset" } else { "may run out before reset" };
    Ok(cat!("Weekly pace: ", forecast.g("pace")?, "; ~", hours, "h to limit at cycle-average usage; ", outlook))
}

/// `[string](100-$used)+'% remaining'`, or `unknown` without a reading.
fn remaining_text(used: &V) -> R<String> {
    if used.is_null() {
        return Ok("unknown".to_string());
    }
    Ok(cat!(V::I32(100).sub(used)?.s()?, "% remaining"))
}

/// Format-Hotpl8Status: the text of `hotpl8 status`. `now` is the request's single clock
/// reading, so every line describes the same instant.
pub fn format_status(status: &V, policy: &V, state_directory: &Path, now: Dto) -> R<Vec<String>> {
    let mut lines = Vec::new();
    for line in format_overview(&status.g("providerOverview")?)? {
        lines.push(safe_text(&line));
    }
    lines.push(cat!("HotPl8 | generated ", safe_text(&status.g("generatedAt")?.s()?)));
    if status.g("collector")?.t()? {
        lines.push(health(&status.g("collector")?, now, "")?);
    }
    let pause = pause(state_directory, now)?;
    if pause.t()? {
        lines.push(cat!("AUTOMATION PAUSED: ", safe_text(&pause.g("reason")?.s()?)));
    }
    let age = now.since(Dto::of(&status.g("generatedAt")?)?).total_seconds();
    if age > 900.0 || age < -5.0 {
        lines.push("STALE: refresh before relying on these readings.".to_string());
    }
    for registration in configured_providers(policy, false)? {
        let view = provider_view(status, policy, &registration.g("id")?.s()?, &["providerOverview", "parkCandidates"])?;
        let name = name_text(&registration.g("name")?)?;
        let snapshot = view.g("snapshot")?;
        if view.g("provider")?.eq_s("claude")? {
            lines.push(safe_text(&cat!(name, ": active slot ", snapshot.g("active")?, " | ", snapshot.g("verdict")?)));
            for account in snapshot.g("slots")?.arr() {
                let five_hour = remaining_text(&account.g("used5h")?)?;
                let weekly = remaining_text(&account.g("used7d")?)?;
                lines.push(safe_text(&cat!("  ", account.g("label")?, " [", account.g("slot")?, "] 5h ", five_hour, " | 7d ", weekly, " | ", account.g("status")?)));
                if account.g("warmOutcome")?.t()? {
                    lines.push(cat!("    warm: ", account.path(&["warmOutcome", "outcome"])?));
                }
                if fresh_timestamp(&account.g("observedAt")?, now)? && account.g("forecast")?.t()? {
                    lines.push(cat!("    ", format_forecast(&account.g("forecast")?)?));
                }
            }
        } else if snapshot.path(&["providers", "codex"])?.t()? {
            for line in format_codex_status(&snapshot.path(&["providers", "codex"])?, &view.path(&["policy", "codex"])?, now)? {
                lines.push(safe_text(&rename_codex(&line, &name)?));
            }
        } else {
            lines.push(cat!(name, ": not configured or no observation yet."));
        }
    }
    Ok(lines)
}

/// The `slot: reason; rank` lines under a Claude-shaped decision.
fn decision_lines(lines: &mut Vec<String>, title: &str, decision: &V) -> R<()> {
    lines.push(cat!(title, ": ", decision.g("reason")?, "; policy ", decision.g("policy")?));
    for r in decision.g("accounts")?.arr() {
        lines.push(cat!("  slot ", r.g("slot")?, ": ", r.g("reason")?, "; rank ", r.g("rank")?));
    }
    Ok(())
}
/// The lines of one per-meter decision; `verb` names what the selection is.
fn meter_lines(lines: &mut Vec<String>, title: &str, verb: &str, d: &V) -> R<()> {
    let selected = if d.g("selected")?.t()? { d.g("selected")? } else { "none".into() };
    lines.push(cat!(title, " ", d.g("meter")?, ": ", verb, " ", selected, "; policy ", d.g("policy")?));
    for r in d.g("accounts")?.arr() {
        lines.push(cat!("  ", r.g("slot")?, ": ", r.g("reason")?, "; reserve=", r.g("reserve")?));
    }
    Ok(())
}

/// Format-Hotpl8Explanation
pub fn format_explanation(snapshot: &V, now: Dto) -> R<Vec<String>> {
    if !snapshot.t()? || !snapshot.g("generatedAt")?.t()? {
        return Ok(vec!["No observation. Run hotpl8 refresh.".to_string()]);
    }
    let mut lines = Vec::new();
    let age = catch(|| Ok(now.since(Dto::of(&snapshot.g("generatedAt")?)?).total_seconds()))?.unwrap_or(99999.0);
    if age > 900.0 || age < -5.0 {
        lines.push("STALE: these are the decisions at the last observation, not a current recommendation.".to_string());
    }
    let overview = snapshot.g("providerOverview")?;
    if overview.t()? {
        lines.extend(format_overview(&overview)?);
    }
    lines.push(cat!("Observed: ", snapshot.g("generatedAt")?));
    let pause = snapshot.g("automationPause")?;
    if pause.t()? {
        lines.push(cat!("Automation paused: ", pause.g("reason")?));
    }
    let critical = snapshot.g("critical")?;
    if critical.g("active")?.t()? {
        lines.push(cat!("Claude critical: ", critical.g("reason")?, " / ", critical.g("basis")?, " / checks ", critical.g("pollSeconds")?, "s"));
    }
    let decision = snapshot.g("decision")?;
    if decision.t()? {
        decision_lines(&mut lines, "Claude", &decision)?;
    }
    let codex = snapshot.path(&["providers", "codex"])?;
    for (name, c) in codex.g("critical")?.props()? {
        if c.g("active")?.t()? {
            lines.push(cat!("Codex ", &*name, " critical: ", c.g("reason")?, " / ", c.g("basis")?, " / checks ", c.g("pollSeconds")?, "s"));
        }
    }
    for d in codex.g("decisions")?.arr() {
        meter_lines(&mut lines, "Codex", "next launch", &d)?;
    }
    lines.push("Native launches use the recommendation. Managed host sessions require their own confirmed routing evidence.".to_string());
    for (entry, value) in snapshot.g("providers")?.props()? {
        if text_eq(&entry, "codex")? {
            continue;
        }
        let named = overview.gd(&entry)?.g("name")?;
        let name = if named.t()? { name_text(&named)? } else { entry.to_string() };
        if value.g("decision")?.t()? {
            decision_lines(&mut lines, &name, &value.g("decision")?)?;
        }
        for d in value.g("decisions")?.arr() {
            meter_lines(&mut lines, &name, "proposed", &d)?;
        }
    }
    Ok(lines)
}

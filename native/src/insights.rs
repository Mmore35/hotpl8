//! src/insights.ps1: the stored snapshot as a reader sees it, the text of `hotpl8 status`
//! and `hotpl8 explain`, and what the collector adds to a reading before it is stored.

use std::path::Path;

use crate::activity::add_action_event;
use crate::capacity::fresh_timestamp;
use crate::codex::format_codex_status;
use crate::files;
use crate::forecast::{forecast, update_history};
use crate::json;
use crate::overview::{format_overview, park_candidates, provider_overview};
use crate::pause::pause;
use crate::ps::*;
use crate::registry::{configured_providers, copy, provider_state_directory, provider_view};
use crate::replay::replay;
use crate::time::Dto;
use crate::{cat, hash, obj};

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
pub fn name_text(name: &V) -> R<String> {
    match name.as_str() {
        Some(text) => Ok(text.to_string()),
        None => unreadable(),
    }
}

/// `$line -replace '^Codex', $name`
pub fn rename_codex(line: &str, name: &str) -> R<String> {
    if name.contains('$') {
        return unreadable();
    }
    match line.get(..5) {
        Some(head) if head.eq_ignore_ascii_case("codex") => Ok(cat!(name, &line[5..])),
        _ => Ok(line.to_string()),
    }
}

/// A forecast in words.
pub fn format_forecast(forecast: &V) -> R<String> {
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

/// The text of `hotpl8 status`. `now` is the request's single clock
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
    for r in decision.g("accounts")?.each() {
        lines.push(cat!("  slot ", r.g("slot")?, ": ", r.g("reason")?, "; rank ", r.g("rank")?));
    }
    Ok(())
}
/// The lines of one per-meter decision; `verb` names what the selection is.
fn meter_lines(lines: &mut Vec<String>, title: &str, verb: &str, d: &V) -> R<()> {
    let selected = if d.g("selected")?.t()? { d.g("selected")? } else { "none".into() };
    lines.push(cat!(title, " ", d.g("meter")?, ": ", verb, " ", selected, "; policy ", d.g("policy")?));
    for r in d.g("accounts")?.each() {
        lines.push(cat!("  ", r.g("slot")?, ": ", r.g("reason")?, "; reserve=", r.g("reserve")?));
    }
    Ok(())
}

/// What `hotpl8 explain` prints, a line at a time. A view that shows the overview of
/// every provider itself asks for the lines without it.
pub fn format_explanation(snapshot: &V, now: Dto, with_overview: bool) -> R<Vec<String>> {
    if !snapshot.t()? || !snapshot.g("generatedAt")?.t()? {
        return Ok(vec!["No observation. Run hotpl8 refresh.".to_string()]);
    }
    let mut lines = Vec::new();
    let age = catch(|| Ok(now.since(Dto::of(&snapshot.g("generatedAt")?)?).total_seconds()))?.unwrap_or(99999.0);
    if age > 900.0 || age < -5.0 {
        lines.push("STALE: these are the decisions at the last observation, not a current recommendation.".to_string());
    }
    let overview = snapshot.g("providerOverview")?;
    if with_overview && overview.t()? {
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
    for d in codex.g("decisions")?.each() {
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
        for d in value.g("decisions")?.each() {
            meter_lines(&mut lines, &name, "proposed", &d)?;
        }
    }
    Ok(lines)
}

/// History and the activity record are kept for whoever reads them later. A file of
/// theirs that is blocked must not discard the readings just taken, or the state that
/// keeps the next action safe: it is noted, and the collection goes on.
fn kept_aside(directory: &Path, code: &str, body: impl FnOnce() -> R<()>) {
    if let Err(stop) = body() {
        files::event(directory, code, Some(&stop));
    }
}

/// What one provider's reading says besides its numbers. Each
/// fresh weekly reading gets a pace, a change of account or recommendation is recorded,
/// and the decision the rules would have made is set beside the one that was made.
fn add_native_insights(snapshot: &V, policy: &V, directory: &Path, previous: &V, now: Dto) -> R<()> {
    let keeps_history = policy.g("historyEnabled")?.eq(&V::Bool(true))?;
    let history = if keeps_history { json::read_or_null(&directory.join("usage-history.json")) } else { V::Null };
    let samples_of = |key: &str| filter(&history.g("samples")?.each(), |sample| sample.g("key")?.eq_s(key));
    let mut new_samples = Vec::new();
    for slot in snapshot.g("slots")?.arr() {
        if !slot.t()? {
            continue;
        }
        slot.add_member("forecast", V::Null, true)?;
        if !slot.g("fresh")?.t()? || !slot.g("observedAt")?.t()? {
            continue;
        }
        let key = cat!("claude/", slot.g("streamKey")?, "/10080");
        let f = forecast(&slot.g("used7d")?, &slot.g("reset7d")?, &slot.g("observedAt")?, 10080, now, &samples_of(&key)?)?;
        slot.add_member("forecast", f.clone(), true)?;
        if f.t()? {
            new_samples.push(hash! {"key" => key.as_str(), "observedAt" => slot.g("observedAt")?, "resetAt" => slot.g("reset7d")?, "used" => slot.g("used7d")?});
        }
    }
    for slot in snapshot.path(&["providers", "codex", "slots"])?.arr() {
        if !slot.t()? {
            continue;
        }
        for (name, bucket) in slot.g("buckets")?.props()? {
            bucket.add_member("forecast", V::Null, true)?;
            if slot.g("status")?.ne_s("ok")? {
                continue;
            }
            let window = bucket.g("windows")?.g("10080")?;
            if !window.t()? || bucket.g("status")?.ne_s("observed")? || window.g("anchorState")?.ne_s("observed-active")? {
                continue;
            }
            let key = cat!("codex/", slot.g("streamKey")?, "/", &*name, "/10080");
            let reset = V::from(Dto::from_unix_seconds(window.g("resetsAt")?.to_long()?)?.o());
            let f = forecast(&window.g("usedPercent")?, &reset, &slot.g("observedAt")?, 10080, now, &samples_of(&key)?)?;
            bucket.add_member("forecast", f.clone(), true)?;
            if f.t()? {
                new_samples.push(hash! {"key" => key.as_str(), "observedAt" => slot.g("observedAt")?, "resetAt" => reset, "used" => window.g("usedPercent")?});
            }
        }
    }
    if keeps_history {
        kept_aside(directory, "history_output_failed", || update_history(directory, &new_samples, now).map(|_| ()));
    }
    snapshot.add_member("automationPause", pause(directory, now)?, true)?;
    let (active, was_active) = (snapshot.g("active")?, previous.g("active")?);
    if active.t()? && was_active.t()? && active.ne(&was_active)? {
        let slot = active.s()?;
        kept_aside(directory, "activity_output_failed", || add_action_event(directory, "claude", &slot, "active_changed", "observed_account_change", now));
    }
    let next = snapshot.path(&["providers", "codex", "recommendedSlot"])?;
    if next.t()? && next.ne(&previous.path(&["providers", "codex", "recommendedSlot"])?)? {
        let slot = next.s()?;
        kept_aside(directory, "activity_output_failed", || add_action_event(directory, "codex", &slot, "recommendation", "next_launch_only", now));
    }
    let events = json::read_or_null(&directory.join("activity.json")).g("events")?.each();
    snapshot.add_member("recentActions", events[events.len().saturating_sub(5)..].to_vec().into(), true)?;
    let shadow = replay(&[snapshot.clone()], policy)?;
    snapshot.add_member("shadow", shadow.g("decisions")?.arr().into(), true)
}

/// The insights of every registered provider, each worked out in the
/// provider's own shape and then named for the provider it belongs to.
pub fn add_insights(snapshot: &V, policy: &V, directory: &Path, previous: &V, now: Dto) -> R<()> {
    let (mut events, mut shadow) = (Vec::new(), Vec::new());
    for r in configured_providers(policy, false)? {
        let id = r.g("id")?.s()?;
        let view = provider_view(snapshot, policy, &id, &[])?;
        let old = provider_view(previous, policy, &id, &[])?;
        let state = provider_state_directory(directory, &id)?;
        if !state.exists() {
            continue;
        }
        let native = view.g("snapshot")?;
        add_native_insights(&native, &view.g("policy")?, &state, &old.g("snapshot")?, now)?;
        let family = view.g("provider")?.s()?;
        let payload = if family == "claude" { native.clone() } else { native.path(&["providers", "codex"])? };
        if id == "claude" {
            for key in ["slots", "decision", "critical"] {
                if payload.has(key)? {
                    snapshot.add_member(key, payload.g(key)?, true)?;
                }
            }
        } else if snapshot.g("providers")?.t()? && snapshot.g("providers")?.has(&id)? {
            snapshot.g("providers")?.set(&id, payload)?;
        }
        for event in native.g("recentActions")?.each() {
            if !event.t()? || !(event.g("provider")?.ceq_s(&family)? || event.g("provider")?.ceq_s(&id)?) {
                continue;
            }
            let copy = copy(&event)?;
            copy.set("provider", id.as_str().into())?;
            events.push(copy);
        }
        let prefix = format!("{family}/");
        for decision in native.g("shadow")?.each() {
            let stream = decision.g("stream")?;
            let Some(stream) = stream.as_str() else { continue };
            if !stream.get(..prefix.len()).is_some_and(|head| head.eq_ignore_ascii_case(&prefix)) {
                continue;
            }
            if view.path(&["driver", "slotKind"])?.eq_s("native-home")? {
                let meter = stream.split('/').nth(1).unwrap_or("");
                if !r.path(&["definition", "meters"])?.arr().iter().any(|known| known.as_str() == Some(meter)) {
                    continue;
                }
            }
            let copy = copy(&decision)?;
            copy.set("stream", format!("{id}{}", &stream[family.len()..]).into())?;
            shadow.push(copy);
        }
    }
    snapshot.add_member("automationPause", pause(directory, now)?, true)?;
    // Events of the same instant keep the order they were recorded in.
    events.sort_by_key(|event| event.g("at").ok().and_then(|at| at.as_str().map(str::to_string)).unwrap_or_default());
    snapshot.add_member("recentActions", events.split_off(events.len().saturating_sub(5)).into(), true)?;
    snapshot.add_member("shadow", shadow.into(), true)?;
    snapshot.add_member("providerOverview", provider_overview(snapshot, policy, now)?, true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse;

    const STALE: &str = "STALE: these are the decisions at the last observation, not a current recommendation.";
    const HEADROOM: &str = "Weekly headroom is an equal-account average, not a token budget; tiers may differ. Short/model limits determine readiness.";
    const NATIVE: &str = "Native launches use the recommendation. Managed host sessions require their own confirmed routing evidence.";

    #[test]
    fn an_explanation_gives_the_recorded_reasons_and_says_when_they_are_old() {
        set_core(false);
        let now = Dto::parse("2026-09-13T12:00:00.0000000+00:00").ok().unwrap();
        let explained = |text: &str| format_explanation(&parse(text, "").ok().unwrap(), now, true).ok().unwrap();
        assert_eq!(format_explanation(&V::Null, now, true).ok().unwrap(), ["No observation. Run hotpl8 refresh."]);
        assert_eq!(explained(r#"{"slots":[]}"#), ["No observation. Run hotpl8 refresh."]);
        let decision = r#"{"policy":"balanced","reason":"switch held","accounts":[{"slot":2,"reason":"model_below_margin","rank":1}]}"#;
        let codex = r#"{"decisions":[{"meter":"codex","selected":"a","policy":"prefer","accounts":[{"slot":"a","reason":"eligible","reserve":false}]}]}"#;
        assert_eq!(
            explained(&format!(r#"{{"generatedAt":"2026-09-13T11:00:00.0000000+00:00","decision":{decision},"providers":{{"codex":{codex}}}}}"#)),
            [
                STALE,
                "Observed: 2026-09-13T11:00:00.0000000+00:00",
                "Claude: switch held; policy balanced",
                "  slot 2: model_below_margin; rank 1",
                "Codex codex: next launch a; policy prefer",
                "  a: eligible; reserve=False",
                NATIVE,
            ]
        );
        // A provider registered under another name explains itself under that name.
        let alias = r#"{"policy":"prefer","reason":"switch held","accounts":[{"slot":2,"reason":"scoped_margin","rank":1}]}"#;
        assert_eq!(
            explained(&format!(r#"{{"generatedAt":"2026-09-13T12:00:00.0000000+00:00","automationPause":{{"reason":"away"}},"providers":{{"codex":{codex},"fictional":{{"decision":{alias},"decisions":[]}}}},"providerOverview":{{}}}}"#)),
            [
                HEADROOM,
                "Observed: 2026-09-13T12:00:00.0000000+00:00",
                "Automation paused: away",
                "Codex codex: next launch a; policy prefer",
                "  a: eligible; reserve=False",
                NATIVE,
                "fictional: switch held; policy prefer",
                "  slot 2: scoped_margin; rank 1",
            ]
        );
        // Nothing decided is nothing said: no line is made up for a decision, or for the
        // accounts of one, that is not there.
        assert_eq!(explained(r#"{"generatedAt":"2026-09-13T12:00:00.0000000+00:00","providers":{}}"#), ["Observed: 2026-09-13T12:00:00.0000000+00:00", NATIVE]);
        assert_eq!(
            explained(r#"{"generatedAt":"2026-09-13T12:00:00.0000000+00:00","decision":{"policy":"prefer","reason":"no eligible account"},"providers":{"codex":{"decisions":[{"meter":"codex","policy":"prefer"}]},"fictional":{"decision":{"policy":"prefer","reason":"switch held"}}}}"#),
            [
                "Observed: 2026-09-13T12:00:00.0000000+00:00",
                "Claude: no eligible account; policy prefer",
                "Codex codex: next launch none; policy prefer",
                NATIVE,
                "fictional: switch held; policy prefer",
            ]
        );
        // A view that shows the overview itself is given the rest.
        let shown = format!(r#"{{"generatedAt":"2026-09-13T12:00:00.0000000+00:00","decision":{decision},"providers":{{}},"providerOverview":{{}}}}"#);
        assert_eq!(explained(&shown)[0], HEADROOM);
        assert_eq!(
            format_explanation(&parse(&shown, "").ok().unwrap(), now, false).ok().unwrap(),
            ["Observed: 2026-09-13T12:00:00.0000000+00:00", "Claude: switch held; policy balanced", "  slot 2: model_below_margin; rank 1", NATIVE]
        );
    }
}

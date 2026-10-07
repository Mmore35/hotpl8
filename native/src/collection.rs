//! src/collection.ps1: when each provider is next read. The times outlive the scheduler, a
//! manual refresh and a restart, so a provider that is failing is left alone for a while
//! whoever asks.

use crate::json;
use crate::obj;
use crate::ps::*;
use crate::registry::{self, provider_definition, provider_driver};
use crate::time::Dto;
use std::path::Path;

/// Get-Hotpl8CollectionState
pub fn collection_state(directory: &Path) -> R<V> {
    let mut state = json::read_or_null(&directory.join("collector.json"));
    if !state.is_obj() {
        state = obj! {"schemaVersion" => 1, "providers" => obj! {}};
    }
    // An older or partial record may hold timing alone. The map is derived, so it is
    // rebuilt rather than failing every provider's next result.
    if !state.g("providers")?.is_obj() {
        state.add_member("providers", obj! {}, true)?;
    }
    Ok(state)
}

/// Test-Hotpl8CollectionDue. cswap keeps each account's own polling deadlines, so a healthy
/// provider that asks to be read every minute is read on every wake; a second cache here
/// could let its valid readings expire. Neither path cancels the wait after a failure.
pub fn collection_due(state: &V, provider: &str, scheduled: bool, now: Dto) -> bool {
    let due = || -> R<bool> {
        let record = state.g("providers")?.gd(provider)?;
        let next = record.g("nextAttemptAt")?;
        if !next.t()? {
            return Ok(true);
        }
        if !record.g("failures")?.t()? && (!scheduled || provider_driver(&provider_definition(provider)?.g("driver")?)?.g("healthyPollSeconds")?.eq_i(60)?) {
            return Ok(true);
        }
        Ok(Dto::of_external(&next)?.ticks <= now.ticks)
    };
    due().unwrap_or(true)
}

/// Set-Hotpl8CollectionResult. Failing to write this machine's own state is not a provider
/// turning a request down: it is tried again at the next wake, while a failed provider is
/// left for longer each time.
pub fn set_collection_result(state: &V, provider: &str, success: bool, now: Dto, healthy_seconds: i32, failure_code: Option<&str>) -> R<()> {
    let providers = state.g("providers")?;
    let old = providers.gd(provider)?;
    let local = failure_code == Some("state_io_failed");
    let was_local = old.g("failureCode").and_then(|code| code.eq_s("state_io_failed")).unwrap_or(false);
    let prior = if was_local && !local { 0 } else { old.g("failures").and_then(|count| count.to_int()).unwrap_or(0) };
    let failures = if success { 0 } else { prior.saturating_add(1).clamp(1, 10) };
    let delay = if success {
        healthy_seconds.clamp(60, 300)
    } else if local {
        60
    } else {
        (300 * (1 << (failures - 1).min(3))).min(1800)
    };
    let at = now.o();
    let record = obj! {
        "lastAttemptAt" => at.as_str(),
        "lastSuccessAt" => if success { V::from(at.as_str()) } else { old.g("lastSuccessAt").unwrap_or(V::Null) },
        "failures" => failures,
        "nextAttemptAt" => now.plus_seconds(i64::from(delay))?.o(),
        "status" => if success { "ok" } else { "unavailable" },
    };
    if let (false, Some(code)) = (success, failure_code.filter(|code| !code.is_empty())) {
        record.add_member("failureCode", code.into(), false)?;
    }
    providers.add_member(provider, record, true)
}

/// Get-Hotpl8CodexFailure: what is shown for Codex while it cannot be read. A retry that
/// was skipped is not a new failure, so the earlier reason is kept when none is given.
pub fn codex_failure(previous: &V, status: &str, failure_code: &V) -> R<V> {
    let mut slots = Vec::new();
    for slot in previous.g("slots")?.arr() {
        if !slot.t()? {
            continue;
        }
        let copy = registry::copy(&slot)?;
        if copy.is_obj() && copy.g("status")?.ne_s("disabled")? {
            copy.add_member("status", status.into(), true)?;
        }
        slots.push(copy);
    }
    Ok(obj! {
        "status" => status,
        "observedAt" => previous.g("observedAt")?,
        "recommendedSlot" => V::Null,
        "recommendations" => obj! {},
        "decisions" => Vec::<V>::new(),
        "slots" => slots,
        "failureCode" => if failure_code.t()? { failure_code.clone() } else { previous.g("failureCode")? },
        "failureStage" => "codex_collection",
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::scratch;

    fn at(text: &str) -> Dto {
        Dto::parse(text).ok().unwrap()
    }
    fn text(value: &V) -> String {
        json::write(value, 8).ok().unwrap().replace(['\n', ' '], "")
    }

    #[test]
    fn a_failing_provider_waits_longer_each_time() {
        let directory = scratch("collection");
        let state = collection_state(&directory).ok().unwrap();
        assert_eq!(text(&state), r#"{"schemaVersion":1,"providers":{}}"#);
        let now = at("2026-10-06T12:00:00.0000000+00:00");
        assert!(collection_due(&state, "claude", true, now));
        let waits = [300, 600, 1200, 1800, 1800];
        for (index, wait) in waits.iter().enumerate() {
            set_collection_result(&state, "claude", false, now, 300, Some("unexpected_collection_error")).ok().unwrap();
            let record = state.path(&["providers", "claude"]).ok().unwrap();
            assert_eq!(record.g("failures").ok().unwrap().to_int().ok(), Some(index as i32 + 1));
            assert_eq!(record.g("nextAttemptAt").ok().unwrap().s().ok().unwrap(), now.plus_seconds(*wait).ok().unwrap().o());
        }
        for _ in 0..8 {
            set_collection_result(&state, "claude", false, now, 300, None).ok().unwrap();
        }
        let record = state.path(&["providers", "claude"]).ok().unwrap();
        assert_eq!(text(&record), r#"{"lastAttemptAt":"2026-10-06T12:00:00.0000000+00:00","lastSuccessAt":null,"failures":10,"nextAttemptAt":"2026-10-06T12:30:00.0000000+00:00","status":"unavailable"}"#);
        // Not due until its time, scheduled or asked for; due from then on.
        assert!(!collection_due(&state, "claude", false, at("2026-10-06T12:29:59.0000000+00:00")));
        assert!(collection_due(&state, "claude", true, at("2026-10-06T12:30:00.0000000+00:00")));
        // A local write failure is tried again at the next wake and forgets nothing else.
        set_collection_result(&state, "claude", false, now, 300, Some("state_io_failed")).ok().unwrap();
        let record = state.path(&["providers", "claude"]).ok().unwrap();
        assert_eq!(record.g("nextAttemptAt").ok().unwrap().s().ok().unwrap(), "2026-10-06T12:01:00.0000000+00:00");
        assert_eq!(record.g("failureCode").ok().unwrap().s().ok().unwrap(), "state_io_failed");
        set_collection_result(&state, "claude", false, now, 300, Some("unexpected_collection_error")).ok().unwrap();
        assert_eq!(state.path(&["providers", "claude", "failures"]).ok().unwrap().to_int().ok(), Some(1));
        set_collection_result(&state, "claude", true, now, 20, None).ok().unwrap();
        let record = state.path(&["providers", "claude"]).ok().unwrap();
        assert_eq!(text(&record), r#"{"lastAttemptAt":"2026-10-06T12:00:00.0000000+00:00","lastSuccessAt":"2026-10-06T12:00:00.0000000+00:00","failures":0,"nextAttemptAt":"2026-10-06T12:01:00.0000000+00:00","status":"ok"}"#);
        std::fs::write(directory.join("collector.json"), r#"{"startedAt":"x","providers":[]}"#).unwrap();
        assert_eq!(text(&collection_state(&directory).ok().unwrap()), r#"{"startedAt":"x","providers":{}}"#);
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn a_time_that_cannot_be_read_is_due() {
        let state = json::parse(r#"{"providers":{"claude":{"failures":2,"nextAttemptAt":"soon"}}}"#, "").ok().unwrap();
        assert!(collection_due(&state, "claude", true, at("2026-10-06T12:00:00.0000000+00:00")));
    }

    #[test]
    fn codex_keeps_its_accounts_while_it_cannot_be_read() {
        let previous = json::parse(r#"{"observedAt":"t","failureCode":"old","slots":[{"id":"a","status":"ok"},null,{"id":"b","status":"disabled"}]}"#, "").ok().unwrap();
        let failed = codex_failure(&previous, "backoff", &V::Null).ok().unwrap();
        assert_eq!(
            text(&failed),
            r#"{"status":"backoff","observedAt":"t","recommendedSlot":null,"recommendations":{},"decisions":[],"slots":[{"id":"a","status":"backoff"},{"id":"b","status":"disabled"}],"failureCode":"old","failureStage":"codex_collection"}"#
        );
        let first = codex_failure(&V::Null, "collection_failed", &V::from("state_io_failed")).ok().unwrap();
        assert_eq!(first.g("failureCode").ok().unwrap().s().ok().unwrap(), "state_io_failed");
        assert_eq!(first.g("slots").ok().unwrap().arr().len(), 0);
    }
}

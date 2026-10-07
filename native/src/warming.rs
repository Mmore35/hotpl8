//! src/warming.ps1: what became of a request to open an account's window. A program that
//! ran to its end is an attempt, never proof that the provider opened anything.

use crate::files;
use crate::json;
use crate::obj;
use crate::ps::*;
use crate::registry;
use crate::time::Dto;
use std::path::Path;

/// New-Hotpl8WarmOutcome
pub fn new_warm_outcome(provider: &str, slot: &str, identity: &str, meter: &str, succeeded: bool, now: Dto) -> R<V> {
    Ok(obj! {
        "schemaVersion" => 1,
        "id" => files::guid(),
        "provider" => provider,
        "slot" => slot,
        "identity" => identity,
        "meter" => meter,
        "sentAt" => now.o(),
        "expiresAt" => now.plus_seconds(18_000)?.o(),
        "outcome" => if succeeded { "sent" } else { "failed" },
        "observedAt" => V::Null,
        "resetAt" => V::Null,
    })
}

/// Update-Hotpl8WarmOutcome: the outcome as the latest reading leaves it. Null when there
/// was none.
pub fn update_warm_outcome(outcome: &V, identity: &str, observed_at: &V, reset_at: &V, fresh: bool, now: Dto) -> R<V> {
    if !outcome.t()? {
        return Ok(V::Null);
    }
    let result = registry::copy(outcome)?;
    if result.g("identity")?.ne_s(identity)? {
        result.set("outcome", "account_changed".into())?;
        return Ok(result);
    }
    if result.g("outcome")?.in_s(&["failed", "account_changed", "expired"])? {
        return Ok(result);
    }
    let read = || -> R<()> {
        let sent = Dto::of_external(&result.g("sentAt")?)?;
        let expires = Dto::of_external(&result.g("expiresAt")?)?;
        if now.ticks >= expires.ticks {
            return result.set("outcome", "expired".into());
        }
        if fresh && observed_at.t()? && reset_at.t()? {
            let observed = Dto::parse_external(&observed_at.s()?)?;
            let reset = Dto::parse_external(&reset_at.s()?)?;
            // Bound the window and reject stale, pre-request or future observations.
            if observed.ticks > sent.ticks
                && observed.ticks <= now.plus_seconds(5)?.ticks
                && now.since(observed).total_seconds() <= 900.0
                && reset.ticks > now.ticks
                && reset.ticks <= sent.plus_seconds(18_300)?.ticks
            {
                result.set("outcome", "observed-active".into())?;
                result.set("observedAt", observed.o().into())?;
                result.set("resetAt", reset.o().into())?;
                return result.set("expiresAt", reset.o().into());
            }
        }
        if result.g("outcome")?.in_s(&["sent", "requested"])? && now.since(sent).total_minutes() >= 15.0 {
            result.set("outcome", "unconfirmed".into())?;
        }
        Ok(())
    };
    if catch(read)?.is_none() {
        result.set("outcome", "unconfirmed".into())?;
    }
    Ok(result)
}

/// Read-Hotpl8WarmOutcomes
pub fn warm_outcomes(directory: &Path) -> V {
    match json::read_or_null(&directory.join("warm-outcomes.json")) {
        V::Null => obj! {},
        outcomes => outcomes,
    }
}

/// Save-Hotpl8WarmOutcomes
pub fn save_warm_outcomes(directory: &Path, outcomes: &V) -> R<()> {
    files::write_json(&directory.join("warm-outcomes.json"), outcomes, 10)
}

/// Test-Hotpl8WarmPending: a request already made for this account is still open, so
/// another must not be sent.
pub fn warm_pending(outcome: &V, identity: &str, now: Dto) -> R<bool> {
    if !outcome.t()? || outcome.g("identity")?.ne_s(identity)? || outcome.g("outcome")?.in_s(&["failed", "expired", "account_changed"])? {
        return Ok(false);
    }
    Ok(catch(|| Ok(Dto::of_external(&outcome.g("expiresAt")?)?.ticks > now.ticks))?.unwrap_or(true))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::scratch;

    fn at(text: &str) -> Dto {
        Dto::parse(text).ok().unwrap()
    }
    fn outcome_of(value: &V) -> String {
        value.g("outcome").ok().unwrap().s().ok().unwrap()
    }

    /// What Windows PowerShell answers: the outcome, when it was seen, its reset, its
    /// expiry, and whether it still holds back another request.
    const UPDATED: &str = "\
nothing|sent|||2026-10-06T17:00:00.0000000+00:00|True
other|account_changed|||2026-10-06T17:00:00.0000000+00:00|False
seen|observed-active|2026-10-06T12:01:00.0000000+00:00|2026-10-06T17:01:00.0000000+00:00|2026-10-06T17:01:00.0000000+00:00|True
seen before|sent|||2026-10-06T17:00:00.0000000+00:00|True
seen at send|sent|||2026-10-06T17:00:00.0000000+00:00|True
not fresh|sent|||2026-10-06T17:00:00.0000000+00:00|True
reset far|sent|||2026-10-06T17:00:00.0000000+00:00|True
reset edge|observed-active|2026-10-06T12:01:00.0000000+00:00|2026-10-06T17:05:00.0000000+00:00|2026-10-06T17:05:00.0000000+00:00|True
reset past|sent|||2026-10-06T17:00:00.0000000+00:00|True
seen ahead|observed-active|2026-10-06T12:02:05.0000000+00:00|2026-10-06T17:01:00.0000000+00:00|2026-10-06T17:01:00.0000000+00:00|True
seen too far ahead|sent|||2026-10-06T17:00:00.0000000+00:00|True
seen stale|unconfirmed|||2026-10-06T17:00:00.0000000+00:00|True
quarter|unconfirmed|||2026-10-06T17:00:00.0000000+00:00|True
before quarter|sent|||2026-10-06T17:00:00.0000000+00:00|True
bad times|unconfirmed|||2026-10-06T17:00:00.0000000+00:00|True
expired|expired|||2026-10-06T17:00:00.0000000+00:00|False
none|null
requested|requested|||2026-10-06T17:00:00.0000000+00:00|True
requested quarter|unconfirmed|||2026-10-06T17:00:00.0000000+00:00|True
failed|failed|||2026-10-06T17:00:00.0000000+00:00|False
bad sent|unconfirmed|||2026-10-06T17:00:00.0000000+00:00|True
bad expiry|unconfirmed|||whenever|True
active again|observed-active|2026-10-06T12:30:00.0000000+00:00|2026-10-06T17:02:00.0000000+00:00|2026-10-06T17:02:00.0000000+00:00|True
active later|observed-active|2026-10-06T12:01:00.0000000+00:00|2026-10-06T17:01:00.0000000+00:00|2026-10-06T17:01:00.0000000+00:00|True
active ended|expired|2026-10-06T12:01:00.0000000+00:00|2026-10-06T17:01:00.0000000+00:00|2026-10-06T17:01:00.0000000+00:00|False";

    #[test]
    fn a_request_is_confirmed_only_by_a_reading_taken_after_it() {
        let sent = at("2026-10-06T12:00:00.0000000+00:00");
        let made = new_warm_outcome("claude", "3", "who", "fiveHour", true, sent).ok().unwrap();
        assert_eq!(made.g("expiresAt").ok().unwrap().s().ok().unwrap(), "2026-10-06T17:00:00.0000000+00:00");
        assert_eq!(made.g("id").ok().unwrap().s().ok().unwrap().len(), 32);
        assert_eq!(outcome_of(&new_warm_outcome("claude", "3", "who", "fiveHour", false, sent).ok().unwrap()), "failed");
        let line = |name: &str, outcome: &V, identity: &str, seen: &str, reset: &str, fresh: bool, now: &str| {
            let text = |text: &str| if text.is_empty() { V::Null } else { V::from(text) };
            let now = at(&format!("2026-10-06T{now}.0000000+00:00"));
            let updated = update_warm_outcome(outcome, identity, &text(seen), &text(reset), fresh, now).ok().unwrap();
            if updated.is_null() {
                return format!("{name}|null");
            }
            let field = |name: &str| updated.g(name).ok().unwrap().s().ok().unwrap();
            let pending = if warm_pending(&updated, identity, now).ok().unwrap() { "True" } else { "False" };
            format!("{name}|{}|{}|{}|{}|{pending}", field("outcome"), field("observedAt"), field("resetAt"), field("expiresAt"))
        };
        let changed = |name: &str, value: &str| {
            let copy = registry::copy(&made).ok().unwrap();
            copy.set(name, value.into()).ok().unwrap();
            copy
        };
        let (seen, reset, soon) = ("2026-10-06T12:01:00Z", "2026-10-06T17:01:00Z", "12:02:00");
        let active = update_warm_outcome(&made, "who", &seen.into(), &reset.into(), true, at("2026-10-06T12:02:00.0000000+00:00")).ok().unwrap();
        let answered = [
            line("nothing", &made, "who", "", "", true, soon),
            line("other", &made, "other", "", "", true, soon),
            line("seen", &made, "who", seen, reset, true, soon),
            line("seen before", &made, "who", "2026-10-06T11:59:00Z", reset, true, soon),
            line("seen at send", &made, "who", "2026-10-06T12:00:00Z", reset, true, soon),
            line("not fresh", &made, "who", seen, reset, false, soon),
            line("reset far", &made, "who", seen, "2026-10-06T17:05:01Z", true, soon),
            line("reset edge", &made, "who", seen, "2026-10-06T17:05:00Z", true, soon),
            line("reset past", &made, "who", seen, "2026-10-06T12:02:00Z", true, soon),
            line("seen ahead", &made, "who", "2026-10-06T12:02:05Z", reset, true, soon),
            line("seen too far ahead", &made, "who", "2026-10-06T12:02:06Z", reset, true, soon),
            line("seen stale", &made, "who", seen, reset, true, "12:16:01"),
            line("quarter", &made, "who", "", "", true, "12:15:00"),
            line("before quarter", &made, "who", "", "", true, "12:14:59"),
            line("bad times", &made, "who", "soon", "later", true, soon),
            line("expired", &made, "who", "", "", true, "17:00:00"),
            line("none", &V::Null, "who", "", "", true, soon),
            line("requested", &changed("outcome", "requested"), "who", "", "", true, soon),
            line("requested quarter", &changed("outcome", "requested"), "who", "", "", true, "12:15:00"),
            line("failed", &changed("outcome", "failed"), "who", seen, reset, true, soon),
            line("bad sent", &changed("sentAt", "whenever"), "who", "", "", true, soon),
            line("bad expiry", &changed("expiresAt", "whenever"), "who", "", "", true, soon),
            line("active again", &active, "who", "2026-10-06T12:30:00Z", "2026-10-06T17:02:00Z", true, "12:31:00"),
            line("active later", &active, "who", "", "", true, "13:31:00"),
            line("active ended", &active, "who", "", "", true, "17:01:00"),
        ];
        for (answer, expected) in answered.iter().zip(UPDATED.lines()) {
            assert_eq!(answer, expected);
        }
        assert_eq!(answered.len(), UPDATED.lines().count());
        // The outcome handed in is never the one changed.
        assert_eq!(outcome_of(&made), "sent");
    }

    #[test]
    fn an_open_request_holds_back_another() {
        let sent = at("2026-10-06T12:00:00.0000000+00:00");
        let made = new_warm_outcome("claude", "3", "who", "fiveHour", true, sent).ok().unwrap();
        let later = at("2026-10-06T16:59:59.0000000+00:00");
        assert!(warm_pending(&made, "who", later).ok().unwrap());
        assert!(!warm_pending(&made, "other", later).ok().unwrap());
        assert!(!warm_pending(&made, "who", at("2026-10-06T17:00:00.0000000+00:00")).ok().unwrap());
        assert!(!warm_pending(&V::Null, "who", later).ok().unwrap());
        made.set("expiresAt", "whenever".into()).ok().unwrap();
        assert!(warm_pending(&made, "who", later).ok().unwrap());
        made.set("outcome", "failed".into()).ok().unwrap();
        assert!(!warm_pending(&made, "who", later).ok().unwrap());
        let directory = scratch("warm");
        assert_eq!(json::write(&warm_outcomes(&directory), 4).ok().unwrap(), "{}");
        let all = warm_outcomes(&directory);
        all.add_member("claude:3", made, true).ok().unwrap();
        save_warm_outcomes(&directory, &all).ok().unwrap();
        assert_eq!(outcome_of(&warm_outcomes(&directory).g("claude:3").ok().unwrap()), "failed");
        std::fs::remove_dir_all(&directory).unwrap();
    }
}

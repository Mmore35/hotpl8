//! src/automation.ps1 and Get-Hold: what stops an action the policy would otherwise allow.
//! A caller that changes the files here holds tick.lock.

use crate::files;
use crate::json;
use crate::obj;
use crate::ps::*;
use crate::time::{hours_minutes, Dto};
use std::path::Path;

/// Test-Hotpl8WorkTime
pub fn work_time(schedule: &V, now: Dto) -> R<bool> {
    if !schedule.t()? {
        return Ok(true);
    }
    let zone = schedule.g("timeZone")?;
    let local = if zone.t()? { now.in_zone(&zone.s()?)? } else { now.local()? };
    let start = hours_minutes(&schedule.g("start")?.s()?)?;
    let end = hours_minutes(&schedule.g("end")?.s()?)?;
    let (day, time) = (local.day_of_week() as i32, local.time_of_day());
    let days = schedule.g("days")?.arr();
    let works = |day: i32| V::I32(day).is_in_list(&days);
    if start == end {
        return Ok(false);
    }
    if start < end {
        return Ok(works(day)? && time >= start && time < end);
    }
    // An overnight interval belongs to the day on which it starts.
    if time >= start {
        return works(day);
    }
    Ok(time < end && works((day + 6) % 7)?)
}

/// Get-Hotpl8Pause as the collector reads it. A pause that cannot be read is a pause: the
/// collector goes on observing and takes no action.
pub fn pause(directory: &Path, now: Dto) -> V {
    crate::pause::pause(directory, now).unwrap_or_else(|_| obj! {"until" => V::Null, "reason" => "invalid_pause", "invalid" => true})
}

/// Get-Hotpl8ActionBlock
pub fn action_block(policy: &V, directory: &Path, provider: &str, slot: &str, kind: &str, now: Dto) -> R<Option<&'static str>> {
    if pause(directory, now).t()? {
        return Ok(Some("automation_paused"));
    }
    if kind == "switch" {
        return Ok(None);
    }
    let automation = policy.g("automation")?;
    if !work_time(&automation.g("schedule")?, now)? {
        return Ok(Some("outside_work_hours"));
    }
    if V::from(format!("{provider}:{slot}")).is_in_list(&automation.g("warmExcluded")?.arr())? {
        return Ok(Some("account_excluded"));
    }
    let limit = match automation.g("dailyAttemptLimit")? {
        V::Null => 12,
        limit => limit.to_int()?,
    };
    let budget = directory.join("attempt-budget.json");
    let ledger = json::read_or_null(&budget);
    if budget.exists() && !ledger.t()? {
        return Ok(Some("attempt_state_invalid"));
    }
    let outcomes = directory.join("warm-outcomes.json");
    if kind == "warm" && outcomes.exists() && !json::read_or_null(&outcomes).t()? {
        return Ok(Some("warm_state_invalid"));
    }
    let key = format!("{}/{provider}/{slot}", now.utc().date());
    // A count that is not a number is a ledger that cannot be relied on.
    Ok(match ledger.gd(&key).and_then(|spent| spent.ge_i(limit)) {
        Ok(false) => None,
        Ok(true) => Some("daily_attempt_limit"),
        Err(_) => Some("attempt_state_invalid"),
    })
}

/// Add-Hotpl8Attempt: today's counts are kept, earlier days are dropped.
pub fn add_attempt(directory: &Path, provider: &str, slot: &str, now: Dto) -> R<()> {
    let day = now.utc().date();
    let path = directory.join("attempt-budget.json");
    let mut next: Vec<(String, i32)> = Vec::new();
    let old = json::read_or_null(&path);
    if old.is_obj() {
        for (name, value) in old.props()? {
            if name.starts_with(&format!("{day}/")) {
                next.push((name.to_string(), value.to_int()?));
            }
        }
    }
    let key = format!("{day}/{provider}/{slot}");
    match next.iter_mut().find(|(name, _)| *name == key) {
        Some((_, count)) => *count = count.saturating_add(1),
        None => next.push((key, 1)),
    }
    let ledger = new_obj(next.iter().map(|(name, count)| (name.as_str(), V::I32(*count))).collect());
    files::write_json(&path, &ledger, 2)
}

/// A hold someone placed on the active account: until when, and why.
pub struct Hold {
    pub until: Dto,
    pub reason: String,
}

/// Get-Hold. Anything about the file that cannot be read means no hold: a hold is a
/// convenience that expires, never the thing that keeps an account safe.
pub fn hold(directory: &Path, now: Dto) -> Option<Hold> {
    let read = || -> R<Option<Hold>> {
        let hold = json::read_or_null(&directory.join("hold.json"));
        let until = hold.g("until")?;
        if !until.t()? {
            return Ok(None);
        }
        let until = Dto::parse_external(&until.s()?)?;
        if until.ticks <= now.ticks {
            return Ok(None);
        }
        let reason = hold.g("reason")?;
        Ok(Some(Hold { until, reason: if reason.t()? { reason.s()? } else { "hold".into() } }))
    };
    read().unwrap_or(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::scratch;
    use crate::json::parse;

    fn at(text: &str) -> Dto {
        Dto::parse(text).ok().unwrap()
    }

    #[test]
    fn work_hours_follow_the_schedule_and_its_zone() {
        // 2026-10-06 is a Tuesday.
        let day = parse(r#"{"start":"09:00","end":"17:00","days":[1,2,3,4,5],"timeZone":"UTC"}"#, "").ok().unwrap();
        assert!(work_time(&V::Null, at("2026-10-06T03:00:00.0000000+00:00")).ok().unwrap());
        assert!(work_time(&day, at("2026-10-06T09:00:00.0000000+00:00")).ok().unwrap());
        assert!(!work_time(&day, at("2026-10-06T17:00:00.0000000+00:00")).ok().unwrap());
        assert!(!work_time(&day, at("2026-10-04T12:00:00.0000000+00:00")).ok().unwrap());
        let night = parse(r#"{"start":"22:00","end":"06:00","days":[2],"timeZone":"UTC"}"#, "").ok().unwrap();
        assert!(work_time(&night, at("2026-10-06T23:00:00.0000000+00:00")).ok().unwrap());
        assert!(work_time(&night, at("2026-10-07T05:59:00.0000000+00:00")).ok().unwrap());
        assert!(!work_time(&night, at("2026-10-07T06:00:00.0000000+00:00")).ok().unwrap());
        assert!(!work_time(&night, at("2026-10-06T05:00:00.0000000+00:00")).ok().unwrap());
        let never = parse(r#"{"start":"09:00","end":"09:00","days":[2],"timeZone":"UTC"}"#, "").ok().unwrap();
        assert!(!work_time(&never, at("2026-10-06T09:00:00.0000000+00:00")).ok().unwrap());
        let nowhere = parse(r#"{"start":"09:00","end":"17:00","days":[2],"timeZone":"No/Such_Zone"}"#, "").ok().unwrap();
        assert!(work_time(&nowhere, at("2026-10-06T09:00:00.0000000+00:00")).err().unwrap().thrown());
    }

    #[test]
    fn an_action_is_blocked_for_one_named_reason() {
        let directory = scratch("block");
        let now = at("2026-10-06T12:00:00.0000000+00:00");
        let policy = parse(r#"{"automation":{"dailyAttemptLimit":2,"warmExcluded":["claude:3"]}}"#, "").ok().unwrap();
        let block = |slot: &str, kind: &str| action_block(&policy, &directory, "claude", slot, kind, now).ok().unwrap();
        assert_eq!(block("1", "warm"), None);
        assert_eq!(block("3", "warm"), Some("account_excluded"));
        add_attempt(&directory, "claude", "1", now).ok().unwrap();
        assert_eq!(block("1", "warm"), None);
        add_attempt(&directory, "claude", "1", now).ok().unwrap();
        assert_eq!(block("1", "warm"), Some("daily_attempt_limit"));
        assert_eq!(block("2", "probe"), None);
        // The next day starts a new count and forgets the old one.
        let tomorrow = at("2026-10-07T00:00:01.0000000+00:00");
        assert_eq!(action_block(&policy, &directory, "claude", "1", "warm", tomorrow).ok().unwrap(), None);
        add_attempt(&directory, "claude", "2", tomorrow).ok().unwrap();
        let ledger = json::read_or_null(&directory.join("attempt-budget.json"));
        assert_eq!(json::dump(&ledger).ok().unwrap(), json::dump(&parse(r#"{"2026-10-07/claude/2":1}"#, "").ok().unwrap()).ok().unwrap());
        std::fs::write(directory.join("warm-outcomes.json"), "{oh no").unwrap();
        assert_eq!(block("2", "warm"), Some("warm_state_invalid"));
        assert_eq!(block("2", "probe"), None);
        std::fs::write(directory.join("attempt-budget.json"), "[]").unwrap();
        assert_eq!(block("2", "probe"), Some("attempt_state_invalid"));
        std::fs::write(directory.join("automation-pause.json"), "{oh no").unwrap();
        assert_eq!(block("2", "switch"), Some("automation_paused"));
        assert!(pause(&directory, now).g("invalid").ok().unwrap().t().ok().unwrap());
        std::fs::write(directory.join("automation-pause.json"), r#"{"until":"2026-10-06T11:00:00.0000000+00:00"}"#).unwrap();
        assert_eq!(block("2", "switch"), None);
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn a_hold_lasts_until_its_time_and_fails_open() {
        let directory = scratch("hold");
        let now = at("2026-10-06T12:00:00.0000000+00:00");
        assert!(hold(&directory, now).is_none());
        let write = |text: &str| std::fs::write(directory.join("hold.json"), text).unwrap();
        write(r#"{"until":"2026-10-06T13:00:00Z","reason":"burn"}"#);
        let held = hold(&directory, now).unwrap();
        assert_eq!((held.until.o().as_str(), held.reason.as_str()), ("2026-10-06T13:00:00.0000000+00:00", "burn"));
        write(r#"{"until":"2026-10-06T13:00:00Z"}"#);
        assert_eq!(hold(&directory, now).unwrap().reason, "hold");
        for gone in [r#"{"until":"2026-10-06T12:00:00Z"}"#, r#"{"until":"not a timestamp"}"#, "{oh no", r#"{"reason":"x"}"#, r#"{"until":5}"#] {
            write(gone);
            assert!(hold(&directory, now).is_none(), "{gone}");
        }
        std::fs::remove_dir_all(&directory).unwrap();
    }
}

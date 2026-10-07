//! The warm schedule of src/providers/claude.ps1: at which minute of a five-hour cycle each
//! account's window is opened, so that the accounts' windows end apart rather than
//! together.

use crate::ps::*;
use crate::time::Dto;

/// The length of a short window, in minutes: the cycle every offset is a minute of.
pub const CYCLE_MINUTES: i32 = 300;

/// Get-CycleMinute. The cycle is counted from the Unix epoch, not from when anything
/// started, so every machine and every run agrees on where in the cycle a minute falls.
pub fn cycle_minute(now: Dto) -> i32 {
    (now.unix_seconds().div_euclid(60) % i64::from(CYCLE_MINUTES)) as i32
}

/// The minute of the cycle each account's window opens at.
#[derive(Debug, PartialEq)]
pub struct Offsets(Vec<(i32, i32)>);
impl Offsets {
    pub fn of(&self, slot: i32) -> Option<i32> {
        self.0.iter().find(|(known, _)| *known == slot).map(|(_, offset)| *offset)
    }
    fn put(&mut self, slot: i32, offset: i32) {
        match self.0.iter_mut().find(|(known, _)| *known == slot) {
            Some(found) => found.1 = offset,
            None => self.0.push((slot, offset)),
        }
    }
}

/// Get-WarmOffsets. `maintain` has no schedule: a cold window is opened when it is seen.
/// The other patterns give each cluster of accounts a share of the cycle in proportion to
/// its weight, so an account that lasts twenty times longer holds the floor twenty times
/// longer. Offsets fall on a ten-minute grid.
pub fn warm_offsets(policy: &V, prefer: &[i32]) -> R<Option<Offsets>> {
    let named = policy.g("pattern")?;
    let pattern = if named.t()? { named.sv()? } else { V::s_of("maintain") };
    if pattern.eq_s("maintain")? {
        return Ok(None);
    }
    // One account has nothing to be apart from.
    let n = prefer.len();
    if n <= 1 {
        return Ok(None);
    }
    let weights = policy.g("weights")?;
    let mut weight: Vec<(i32, f64)> = Vec::new();
    for slot in prefer {
        let mut v = 1.0;
        if weights.t()? {
            let given = weights.g(&slot.to_string())?;
            if !given.is_null() {
                v = given.dbl().unwrap_or(1.0);
            }
        }
        if v <= 0.0 {
            v = 1.0;
        }
        match weight.iter_mut().find(|(known, _)| known == slot) {
            Some(found) => found.1 = v,
            None => weight.push((*slot, v)),
        }
    }
    let weight_of = |slot: &i32| weight.iter().find(|(known, _)| known == slot).map_or(0.0, |(_, v)| *v);

    let mut g = 1;
    if pattern.eq_s("synced")? {
        g = n as i64;
    } else if pattern.eq_s("clustered")? {
        let group = policy.g("warmGroup")?;
        g = if group.is_null() { 2 } else { i64::from(group.to_int()?) };
    }
    let g = g.clamp(1, n as i64) as usize;

    let clusters: Vec<(&[i32], f64)> = prefer.chunks(g).map(|members| (members, members.iter().map(weight_of).sum())).collect();
    let total: f64 = clusters.iter().map(|(_, sum)| sum).sum();
    if total <= 0.0 {
        return Ok(None);
    }
    let mut offsets = Offsets(Vec::new());
    let mut before = 0.0;
    for (members, sum) in clusters {
        let minute = ((f64::from(CYCLE_MINUTES) * before / total) / 10.0).round_ties_even() * 10.0;
        let offset = (minute as i64 % i64::from(CYCLE_MINUTES)) as i32;
        for member in members {
            offsets.put(*member, offset);
        }
        before += sum;
    }
    Ok(Some(offsets))
}

/// Test-AtPhase: whether the cycle is within `window` minutes after `offset`. The arc is
/// one-sided on purpose: a window opened early ends early, and the accounts drift
/// together again.
pub fn at_phase(offset: i32, window: i32, now: Dto) -> bool {
    let mut d = cycle_minute(now) - offset;
    if d < 0 {
        d += CYCLE_MINUTES;
    }
    d < window
}

/// Get-PhaseOffsetOf: the minute of the cycle this account's open window ends at. None
/// for an account with no window open.
pub fn phase_offset_of(account: &V) -> R<Option<i32>> {
    let short = account.path(&["usage", "fiveHour"])?;
    if !short.t()? {
        return Ok(None);
    }
    let reset = short.g("resetsAt")?.s()?;
    if blank(&reset)? {
        return Ok(None);
    }
    let Some(at) = catch(|| Dto::parse_external(&reset))? else { return Ok(None) };
    Ok(i32::try_from(at.unix_seconds().div_euclid(60)).ok().map(|minutes| minutes % CYCLE_MINUTES))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse;

    fn offsets(prefer: &[i32], policy: &str) -> String {
        let policy = parse(policy, "").ok().unwrap();
        let Some(offsets) = warm_offsets(&policy, prefer).ok().unwrap() else { return "null".into() };
        let mut slots: Vec<i32> = prefer.to_vec();
        slots.sort_unstable();
        slots.dedup();
        slots.iter().map(|slot| format!("{slot}={}", offsets.of(*slot).unwrap())).collect::<Vec<_>>().join(" ")
    }

    /// The fleet shapes tests/test-tick.sh held Get-WarmOffsets to.
    #[test]
    fn a_pattern_spreads_the_accounts_over_the_cycle() {
        assert_eq!(offsets(&[3, 2, 1], r#"{"pattern":"maintain"}"#), "null");
        assert_eq!(offsets(&[3, 2, 1], "{}"), "null");
        assert_eq!(offsets(&[1], r#"{"pattern":"even"}"#), "null");
        assert_eq!(offsets(&[3, 2, 1], r#"{"pattern":"even"}"#), "1=200 2=100 3=0");
        assert_eq!(offsets(&[5, 4, 3, 2, 1], r#"{"pattern":"even"}"#), "1=240 2=180 3=120 4=60 5=0");
        assert_eq!(offsets(&[3, 2, 1], r#"{"pattern":"synced"}"#), "1=0 2=0 3=0");
        // Two pairs two and a half hours apart: a two-hour burst and a thirty-minute gap.
        assert_eq!(offsets(&[4, 3, 2, 1], r#"{"pattern":"clustered","warmGroup":2}"#), "1=150 2=150 3=0 4=0");
        assert_eq!(offsets(&[4, 3, 2, 1], r#"{"pattern":"clustered"}"#), "1=150 2=150 3=0 4=0");
        assert_eq!(offsets(&[3, 2, 1], r#"{"pattern":"clustered","warmGroup":1}"#), "1=200 2=100 3=0");
        assert_eq!(offsets(&[3, 2, 1], r#"{"pattern":"clustered","warmGroup":9}"#), "1=0 2=0 3=0");
        // An account twenty times the size beside a small one: the small one's window
        // opens at minute 290, not at the 150 an even spacing gives.
        assert_eq!(offsets(&[1, 2], r#"{"pattern":"even","weights":{"1":20,"2":1}}"#), "1=0 2=290");
        assert_eq!(offsets(&[2, 1], r#"{"pattern":"even","weights":{"2":1}}"#), "1=150 2=0");
        assert_eq!(offsets(&[2, 1], r#"{"pattern":"even","weights":{"2":0,"1":-3}}"#), "1=150 2=0");
    }

    #[test]
    fn the_cycle_is_counted_from_the_epoch() {
        let at = |text: &str| Dto::parse(text).ok().unwrap();
        assert_eq!(cycle_minute(at("1970-01-01T05:00:00.0000000+00:00")), 0);
        assert_eq!(cycle_minute(at("2026-10-06T12:00:00.0000000+00:00")), 0);
        assert_eq!(cycle_minute(at("2026-10-06T14:00:59.0000000+02:00")), 0);
        assert_eq!(cycle_minute(at("2026-10-06T10:02:00.0000000+00:00")), 182);
        let now = at("2026-10-06T12:07:00.0000000+00:00");
        assert!(at_phase(7, 15, now) && at_phase(0, 15, now));
        // An offset late in the cycle is reached from the start of the next one.
        assert!(at_phase(293, 15, now));
        assert!(!at_phase(292, 15, now) && !at_phase(8, 15, now));
        let account = |reset: &str| parse(&format!(r#"{{"usage":{{"fiveHour":{{"pct":1,"resetsAt":"{reset}"}}}}}}"#), "").ok().unwrap();
        assert_eq!(phase_offset_of(&account("2026-10-06T12:07:30+00:00")).ok().unwrap(), Some(7));
        assert_eq!(phase_offset_of(&account("")).ok().unwrap(), None);
        assert_eq!(phase_offset_of(&account("soon")).ok().unwrap(), None);
        assert_eq!(phase_offset_of(&parse(r#"{"usage":null}"#, "").ok().unwrap()).ok().unwrap(), None);
    }
}

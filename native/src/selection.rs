//! The key candidates for selection are ordered by.

use crate::ps::*;
use crate::time::Dto;

/// Get-Hotpl8SelectionKey. Optional policies keep reserve/degraded tiers outside this key.
pub fn selection_key(order: &str, five_remaining: &V, week_remaining: &V, week_reset: &V, now: Dto) -> R<V> {
    let never = V::Dbl(f64::MAX);
    let reset = match catch(|| Dto::parse(&week_reset.s()?))? {
        Some(reset) if reset.ticks > now.ticks => reset,
        _ => return Ok(never),
    };
    if text_eq(order, "weekly-expiry")? {
        return Ok(V::Dbl(reset.unix_seconds() as f64));
    }
    if text_eq(order, "balanced")? {
        if !week_remaining.is_number() {
            return Ok(never);
        }
        // Sustainable weekly allowance per remaining five-hour interval, limited
        // by the current short window. Higher useful headroom sorts first.
        let intervals = math_pick(&V::I32(1), &dbl(reset.since(now).total_hours() / 5.0)?, true)?;
        let sustainable = V::Dbl(week_remaining.dbl()?).div(&intervals)?;
        let short = if five_remaining.is_number() { V::Dbl(five_remaining.dbl()?) } else { V::I32(100) };
        return math_pick(&short, &sustainable, false)?.neg();
    }
    Ok(never)
}

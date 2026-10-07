//! Estimates anchored to what a provider reported, never to the clock
//! rolling over, and the readings kept to make them.

use crate::files;
use crate::json;
use crate::obj;
use crate::ps::*;
use crate::time::Dto;
use std::cmp::Ordering;
use std::path::Path;

/// A test inside `try{...}catch{$false}`: a row that cannot be read is not kept.
fn kept(test: impl FnOnce() -> R<bool>) -> R<bool> {
    Ok(catch(test)?.unwrap_or(false))
}

/// `Sort-Object observedAt`. Rows of one stream are never taken at the same instant, and
/// rows of different streams that are keep the order they had.
fn by_time(rows: &[V]) -> R<Vec<V>> {
    let mut keyed = Vec::with_capacity(rows.len());
    for row in rows {
        keyed.push((row.g("observedAt")?, row.clone()));
    }
    let mut failed = None;
    keyed.sort_by(|left, right| {
        order_keys(&left.0, &right.0).unwrap_or_else(|stop| {
            failed.get_or_insert(stop);
            Ordering::Equal
        })
    });
    match failed {
        Some(stop) => Err(stop),
        None => Ok(keyed.into_iter().map(|(_, row)| row).collect()),
    }
}

/// Where a weekly reading is heading at the average rate of its cycle. Null when the reading is too old, too early in its cycle, or not a
/// reading at all.
pub fn forecast(used: &V, reset_at: &V, observed_at: &V, minutes: i32, now: Dto, samples: &[V]) -> R<V> {
    if !used.is_number() || used.le_i(0)? || used.gt_i(100)? {
        return Ok(V::Null);
    }
    let Some((at, reset)) = catch(|| Ok((Dto::parse_external(&observed_at.s()?)?, Dto::parse_external(&reset_at.s()?)?)))? else {
        return Ok(V::Null);
    };
    let cycle = f64::from(minutes) * 60.0;
    let age = now.since(at).total_seconds();
    let left = reset.since(at).total_seconds();
    let elapsed = cycle - left;
    let least = if minutes == 10_080 { 86_400.0 } else { 900.0 };
    if age < -5.0 || age > 900.0 || reset.ticks <= now.ticks || elapsed < least || elapsed > cycle {
        return Ok(V::Null);
    }
    let amount = used.dbl()?;
    let expected = 100.0 * elapsed / cycle;
    let estimate = (100.0 - amount) / (amount / elapsed);
    let earliest = at.plus_seconds(-21_600)?;
    let valid = filter(samples, |sample| {
        kept(|| {
            let taken = Dto::of_external(&sample.g("observedAt")?)?;
            let spent = sample.g("used")?;
            Ok(sample.g("resetAt")?.eq(reset_at)? && spent.is_number() && spent.ge_i(0)? && spent.le(used)? && taken.ticks <= at.ticks && taken.ticks >= earliest.ticks)
        })
    })?;
    let valid = by_time(&valid)?;
    let mut recent = V::Null;
    if valid.len() >= 3 {
        let first = &valid[0];
        let span = at.since(Dto::of_external(&first.g("observedAt")?)?).total_seconds();
        let delta = amount - first.g("used")?.dbl()?;
        if (1800.0..=21_600.0).contains(&span) && delta > 0.0 {
            recent = dbl((100.0 - amount) / (delta / span))?;
        }
    }
    Ok(obj! {
        "observedAt" => at.o(),
        "expectedUsed" => dbl(crate::num::round1(expected)?)?,
        "used" => dbl(amount)?,
        "pace" => if amount - expected >= 10.0 { "ahead" } else if expected - amount >= 10.0 { "behind" } else { "on track" },
        "secondsToLimit" => dbl(estimate.round_ties_even())?,
        "lastsToReset" => estimate >= left,
        "recentSecondsToLimit" => recent,
        "basis" => "cycle-average",
        "confidence" => "estimate",
    })
}

/// The usage history with these readings added: two weeks of readings, one per stream each half hour or whenever
/// its cycle changes, and never more than 4,096.
pub fn update_history(directory: &Path, rows: &[V], now: Dto) -> R<Vec<V>> {
    let path = directory.join("usage-history.json");
    let old = json::read_or_null(&path);
    let (oldest, newest) = (now.plus_seconds(-1_209_600)?, now.plus_seconds(5)?);
    let mut samples = filter(&old.g("samples")?.each(), |sample| {
        kept(|| {
            let time = Dto::of_external(&sample.g("observedAt")?)?;
            let used = sample.g("used")?;
            Ok(time.ticks > oldest.ticks && time.ticks <= newest.ticks && used.is_number() && used.ge_i(0)? && used.le_i(100)?)
        })
    })?;
    for row in rows {
        let key = row.g("key")?;
        let known = by_time(&filter(&samples, |sample| sample.g("key")?.eq(&key))?)?;
        let add = match known.last() {
            None => true,
            Some(last) => {
                last.g("resetAt")?.ne(&row.g("resetAt")?)?
                    || Dto::of_external(&row.g("observedAt")?)?.since(Dto::of_external(&last.g("observedAt")?)?).total_minutes() >= 30.0
            }
        };
        if add {
            samples.push(row.clone());
        }
    }
    let mut samples = by_time(&samples)?;
    if samples.len() > 4096 {
        samples.drain(..samples.len() - 4096);
    }
    files::write_json(&path, &obj! {"schemaVersion" => 1, "samples" => samples.clone()}, 8)?;
    Ok(samples)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::scratch;

    const NOW: &str = "2026-10-06T12:00:00.0000000+00:00";
    const CYCLE: &str = "2026-10-09T12:00:00.0000000+00:00";
    const SEEN: &str = "2026-10-06T11:58:00.0000000+00:00";

    fn number(value: &V) -> String {
        if value.is_null() { "null".to_string() } else { format!("{}", value.dbl().ok().unwrap()) }
    }
    fn sample(key: &str, observed: &str, reset: &str, used: V) -> V {
        obj! {"key" => key, "observedAt" => observed, "resetAt" => reset, "used" => used}
    }
    fn line(name: &str, used: V, reset: &str, seen: V, minutes: i32, samples: &[V]) -> String {
        let made = forecast(&used, &reset.into(), &seen, minutes, Dto::parse(NOW).ok().unwrap(), samples).ok().unwrap();
        if made.is_null() {
            return format!("{name}|none");
        }
        let field = |name: &str| made.g(name).ok().unwrap();
        let fields = [
            name.to_string(),
            field("observedAt").s().ok().unwrap(),
            number(&field("expectedUsed")),
            number(&field("used")),
            field("pace").s().ok().unwrap(),
            number(&field("secondsToLimit")),
            field("lastsToReset").s().ok().unwrap(),
            number(&field("recentSecondsToLimit")),
        ];
        fields.join("|")
    }

    /// What PowerShell answers for these readings, on both of its editions.
    const FORECAST: &str = "\
plain|2026-10-06T11:58:00.0000000+00:00|57.1|30|behind|806120|True|null
int|2026-10-06T11:58:00.0000000+00:00|57.1|30|behind|806120|True|null
ahead|2026-10-06T11:58:00.0000000+00:00|57.1|91.5|ahead|32094|False|null
on track|2026-10-06T11:58:00.0000000+00:00|57.1|55|on track|282665|True|null
half|2026-10-06T11:59:30.0000000+00:00|85.7|0.5|behind|103155630|True|null
zero|none
over|none
full|2026-10-06T11:58:00.0000000+00:00|57.1|100|ahead|0|False|null
text|none
old|none
edge old|2026-10-06T11:45:00.0000000+00:00|57|30|behind|804300|True|null
future|2026-10-06T12:00:05.0000000+00:00|57.1|30|behind|806412|True|null
too future|none
reset past|none
early|none
long|none
bad reset|none
null seen|none
short|2026-10-06T11:58:00.0000000+00:00|59.3|40|behind|16020|True|null
short early|none
recent|2026-10-06T11:58:00.0000000+00:00|57.1|30|behind|806120|True|252000
recent two|2026-10-06T11:58:00.0000000+00:00|57.1|30|behind|806120|True|null
recent flat|2026-10-06T11:58:00.0000000+00:00|57.1|28|behind|888377|True|null";

    #[test]
    fn a_forecast_needs_a_fresh_reading_well_into_its_cycle() {
        let week = |name: &str, used: V, reset: &str, seen: &str| line(name, used, reset, seen.into(), 10_080, &[]);
        let samples = [
            sample("k", "2026-10-06T10:58:00.0000000+00:00", CYCLE, V::Dbl(29.0)),
            sample("k", "2026-10-06T09:58:00.0000000+00:00", CYCLE, V::I32(28)),
            sample("k", "2026-10-06T11:28:00.0000000+00:00", CYCLE, V::Dbl(29.5)),
            sample("k", "2026-10-06T05:00:00.0000000+00:00", CYCLE, V::I32(1)),
            sample("k", "2026-10-06T11:00:00.0000000+00:00", "2026-10-02T12:00:00.0000000+00:00", V::I32(2)),
            sample("k", "not a time", CYCLE, V::I32(2)),
            sample("k", "2026-10-06T11:40:00.0000000+00:00", CYCLE, V::I32(31)),
        ];
        let flat = [samples[1].clone(), samples[1].clone(), samples[1].clone()];
        let answered = [
            week("plain", V::Dbl(30.0), CYCLE, SEEN),
            week("int", V::I32(30), CYCLE, SEEN),
            week("ahead", V::Dbl(91.5), CYCLE, SEEN),
            week("on track", V::I32(55), CYCLE, SEEN),
            week("half", V::Dbl(0.5), "2026-10-07T12:00:00Z", "2026-10-06T11:59:30Z"),
            week("zero", V::I32(0), CYCLE, SEEN),
            week("over", V::Dbl(100.5), CYCLE, SEEN),
            week("full", V::I32(100), CYCLE, SEEN),
            week("text", "30".into(), CYCLE, SEEN),
            week("old", V::I32(30), CYCLE, "2026-10-06T11:44:59Z"),
            week("edge old", V::I32(30), CYCLE, "2026-10-06T11:45:00Z"),
            week("future", V::I32(30), CYCLE, "2026-10-06T12:00:05Z"),
            week("too future", V::I32(30), CYCLE, "2026-10-06T12:00:06Z"),
            week("reset past", V::I32(30), "2026-10-06T11:59:00Z", "2026-10-06T11:58:00Z"),
            week("early", V::I32(30), "2026-10-13T00:00:00Z", "2026-10-06T11:58:00Z"),
            week("long", V::I32(30), "2026-10-14T00:00:00Z", "2026-10-06T11:58:00Z"),
            week("bad reset", V::I32(30), "whenever", "2026-10-06T11:58:00Z"),
            line("null seen", V::I32(30), CYCLE, V::Null, 10_080, &[]),
            line("short", V::I32(40), "2026-10-06T14:00:00Z", "2026-10-06T11:58:00Z".into(), 300, &[]),
            line("short early", V::I32(40), "2026-10-06T16:50:00Z", "2026-10-06T11:58:00Z".into(), 300, &[]),
            line("recent", V::Dbl(30.0), CYCLE, SEEN.into(), 10_080, &samples),
            line("recent two", V::Dbl(30.0), CYCLE, SEEN.into(), 10_080, &[samples[0].clone(), samples[2].clone()]),
            line("recent flat", V::I32(28), CYCLE, SEEN.into(), 10_080, &flat),
        ];
        for (answer, expected) in answered.iter().zip(FORECAST.lines()) {
            assert_eq!(answer, expected);
        }
        assert_eq!(answered.len(), FORECAST.lines().count());
    }

    /// The rows PowerShell 7 keeps and writes. Windows PowerShell keeps the same rows, and
    /// leaves the ones it has just added out of order until the next time it writes.
    const HISTORY: &str = "\
first|a@11:00|a@11:00=10
too soon|a@11:00,b@11:29|a@11:00=10,b@11:29=50
half hour|a@11:00,b@11:29,a@11:30,b@11:31|a@11:00=10,b@11:29=50,a@11:30=11,b@11:31=0
tie|a@11:00,b@11:29,a@11:30,c@11:30,d@11:30,b@11:31|a@11:00=10,b@11:29=50,a@11:30=11,c@11:30=1.5,d@11:30=2.5,b@11:31=0
early row|e@10:00,a@11:00,b@11:29,a@11:30,c@11:30,d@11:30,b@11:31|e@10:00=3.5,a@11:00=10,b@11:29=50,a@11:30=11,c@11:30=1.5,d@11:30=2.5,b@11:31=0
none|e@10:00,a@11:00,b@11:29,a@11:30,c@11:30,d@11:30,b@11:31|e@10:00=3.5,a@11:00=10,b@11:29=50,a@11:30=11,c@11:30=1.5,d@11:30=2.5,b@11:31=0
seeded|a@11:00,z@11:10|a@11:00=5,z@11:10=7
bad row|THROWN
broken file|a@11:40|a@11:40=6
array file|a@11:40|a@11:40=6";

    #[test]
    fn history_keeps_one_reading_a_half_hour_for_each_stream() {
        let directory = scratch("history");
        let path = directory.join("usage-history.json");
        let step = |name: &str, rows: &[V], seed: &str| {
            if !seed.is_empty() {
                std::fs::write(&path, seed).unwrap();
            }
            let Ok(kept) = update_history(&directory, rows, Dto::parse(NOW).ok().unwrap()) else { return format!("{name}|THROWN") };
            let mark = |row: &V| format!("{}@{}", row.g("key").ok().unwrap().s().ok().unwrap(), &row.g("observedAt").ok().unwrap().s().ok().unwrap()[11..16]);
            let kept: Vec<String> = kept.iter().map(mark).collect();
            let written = json::read_or_null(&path).g("samples").ok().unwrap().each();
            let written: Vec<String> = written.iter().map(|row| format!("{}={}", mark(row), number(&row.g("used").ok().unwrap()))).collect();
            format!("{name}|{}|{}", kept.join(","), written.join(","))
        };
        let row = |key: &str, observed: &str, reset: &str, used: f64| sample(key, &format!("2026-10-06T{observed}:00.0000000+00:00"), reset, V::Dbl(used));
        let seeded = r#"{"schemaVersion":1,"samples":[{"key":"a","observedAt":"2026-09-22T12:00:00.0000000+00:00","resetAt":"x","used":5},{"key":"a","observedAt":"2026-10-06T12:00:06.0000000+00:00","resetAt":"x","used":5},{"key":"a","observedAt":"2026-10-06T11:00:00.0000000+00:00","resetAt":"x","used":101},{"key":"a","observedAt":"soon","resetAt":"x","used":5},{"key":"z","observedAt":"2026-10-06T11:10:00.0000000+00:00","resetAt":"x","used":7},{"key":"a","observedAt":"2026-10-06T11:00:00.0000000+00:00","resetAt":"x","used":5}]}"#;
        let answered = [
            step("first", &[row("a", "11:00", CYCLE, 10.0)], ""),
            step("too soon", &[row("a", "11:29", CYCLE, 11.0), row("b", "11:29", CYCLE, 50.0)], ""),
            step("half hour", &[row("a", "11:30", CYCLE, 11.0), row("b", "11:31", "2026-10-16T12:00:00.0000000+00:00", 0.0)], ""),
            step("tie", &[row("c", "11:30", CYCLE, 1.5), row("d", "11:30", CYCLE, 2.5)], ""),
            step("early row", &[row("e", "10:00", CYCLE, 3.5)], ""),
            step("none", &[], ""),
            step("seeded", &[], seeded),
            step("bad row", &[sample("a", "soon", "x", V::Dbl(5.0))], ""),
            step("broken file", &[row("a", "11:40", "x", 6.0)], "{oh no"),
            step("array file", &[row("a", "11:40", "x", 6.0)], "[1,2]"),
        ];
        for (answer, expected) in answered.iter().zip(HISTORY.lines()) {
            assert_eq!(answer, expected);
        }
        assert_eq!(answered.len(), HISTORY.lines().count());
        std::fs::remove_dir_all(&directory).unwrap();
    }
}

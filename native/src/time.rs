//! System.DateTimeOffset and System.TimeSpan, for the timestamps state files carry.
//! Only the round-trip form `yyyy-MM-ddTHH:mm:ss[.fffffff](Z|±hh:mm)` is modelled; other
//! spellings depend on the caller's culture and decline.

use crate::ps::{decline, desktop, throw, R, V};

pub const TICKS_PER_SECOND: i64 = 10_000_000;
const TICKS_PER_MINUTE: i64 = 60 * TICKS_PER_SECOND;
const TICKS_PER_HOUR: i64 = 60 * TICKS_PER_MINUTE;
const TICKS_PER_DAY: i64 = 24 * TICKS_PER_HOUR;
const MAX_TICKS: i64 = 3_155_378_975_999_999_999;
/// Seconds from 0001-01-01 to 1970-01-01.
const UNIX_EPOCH_SECONDS: i64 = 62_135_596_800;

/// An instant (UTC ticks since 0001-01-01) and the offset it was written with.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Dto {
    pub ticks: i64,
    pub offset_minutes: i32,
}

fn leap(year: i64) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}
fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}
/// Days from 0001-01-01 to the given date.
fn days_before(year: i64, month: i64, day: i64) -> i64 {
    let y = year - 1;
    let mut days = y * 365 + y / 4 - y / 100 + y / 400;
    for m in 1..month {
        days += days_in_month(year, m);
    }
    days + day - 1
}
/// (year, month, day) of a day count from 0001-01-01.
fn date_of(mut days: i64) -> (i64, i64, i64) {
    let mut year = 1 + days / 366;
    days -= days_before(year, 1, 1);
    loop {
        let length = if leap(year) { 366 } else { 365 };
        if days < length {
            break;
        }
        days -= length;
        year += 1;
    }
    let mut month = 1;
    while days >= days_in_month(year, month) {
        days -= days_in_month(year, month);
        month += 1;
    }
    (year, month, days + 1)
}

fn number(bytes: &[u8]) -> Option<i64> {
    if bytes.is_empty() || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(bytes.iter().fold(0, |sum, b| sum * 10 + (b - b'0') as i64))
}

impl Dto {
    /// [datetimeoffset]::Parse($text)
    #[track_caller]
    pub fn parse(text: &str) -> R<Dto> {
        if text.chars().all(char::is_whitespace) {
            return throw();
        }
        let b = text.as_bytes();
        if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' {
            return decline();
        }
        let part = |from: usize, to: usize| number(&b[from..to]);
        let (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) =
            (part(0, 4), part(5, 7), part(8, 10), part(11, 13), part(14, 16), part(17, 19))
        else {
            return decline();
        };
        let mut at = 19;
        let mut fraction = 0i64;
        if b[at] == b'.' {
            let digits = b[at + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
            if !(1..=7).contains(&digits) {
                return decline();
            }
            fraction = number(&b[at + 1..at + 1 + digits]).unwrap() * 10i64.pow(7 - digits as u32);
            at += 1 + digits;
        }
        let offset_minutes = match &b[at..] {
            [b'Z'] => 0,
            [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] => {
                let (Some(hours), Some(minutes)) = (number(&[*h1, *h2]), number(&[*m1, *m2])) else { return decline() };
                if minutes > 59 || hours * 60 + minutes > 14 * 60 {
                    return decline();
                }
                (hours * 60 + minutes) as i32 * if *sign == b'-' { -1 } else { 1 }
            }
            _ => return decline(),
        };
        if year < 1 || !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) || hour > 23 || minute > 59 || second > 59 {
            return decline();
        }
        let local = days_before(year, month, day) * TICKS_PER_DAY
            + hour * TICKS_PER_HOUR
            + minute * TICKS_PER_MINUTE
            + second * TICKS_PER_SECOND
            + fraction;
        let ticks = local - offset_minutes as i64 * TICKS_PER_MINUTE;
        if !(0..=MAX_TICKS).contains(&ticks) {
            return decline();
        }
        Ok(Dto { ticks, offset_minutes })
    }
    /// [datetimeoffset]::Parse($value) for a value from a state file: null throws.
    #[track_caller]
    pub fn of(value: &V) -> R<Dto> {
        match value {
            V::Null => throw(),
            V::Str(text) => Dto::parse(text),
            _ => decline(),
        }
    }

    fn fields(self) -> (i64, i64, i64, i64, i64, i64, i64) {
        let local = self.ticks + self.offset_minutes as i64 * TICKS_PER_MINUTE;
        let (year, month, day) = date_of(local / TICKS_PER_DAY);
        let rest = local % TICKS_PER_DAY;
        (
            year,
            month,
            day,
            rest / TICKS_PER_HOUR,
            rest / TICKS_PER_MINUTE % 60,
            rest / TICKS_PER_SECOND % 60,
            rest % TICKS_PER_SECOND,
        )
    }
    fn offset_text(self) -> String {
        let minutes = self.offset_minutes.abs();
        format!("{}{:02}:{:02}", if self.offset_minutes < 0 { '-' } else { '+' }, minutes / 60, minutes % 60)
    }
    /// .ToString('o')
    pub fn o(self) -> String {
        let (year, month, day, hour, minute, second, fraction) = self.fields();
        format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{fraction:07}{}", self.offset_text())
    }
    /// .ToString('MM-dd HH:mm zzz')
    pub fn month_day_time(self) -> String {
        let (_, month, day, hour, minute, _, _) = self.fields();
        format!("{month:02}-{day:02} {hour:02}:{minute:02} {}", self.offset_text())
    }
    /// .UtcDateTime.ToString('yyyy-MM-dd')
    pub fn utc_date(self) -> String {
        let (year, month, day) = date_of(self.ticks / TICKS_PER_DAY);
        format!("{year:04}-{month:02}-{day:02}")
    }
    /// .ToUniversalTime()
    pub fn utc(self) -> Dto {
        Dto { ticks: self.ticks, offset_minutes: 0 }
    }
    /// .ToUnixTimeSeconds()
    pub fn unix_seconds(self) -> i64 {
        self.ticks / TICKS_PER_SECOND - UNIX_EPOCH_SECONDS
    }
    /// [datetimeoffset]::FromUnixTimeSeconds($seconds)
    #[track_caller]
    pub fn from_unix_seconds(seconds: i64) -> R<Dto> {
        if !(-UNIX_EPOCH_SECONDS..=253_402_300_799).contains(&seconds) {
            return throw();
        }
        Ok(Dto { ticks: (seconds + UNIX_EPOCH_SECONDS) * TICKS_PER_SECOND, offset_minutes: 0 })
    }
    /// .AddSeconds / .AddMinutes / .AddHours / .AddDays with a whole number.
    #[track_caller]
    pub fn plus_seconds(self, seconds: i64) -> R<Dto> {
        let Some(ticks) = seconds.checked_mul(TICKS_PER_SECOND).and_then(|t| self.ticks.checked_add(t)) else { return decline() };
        let local = ticks + self.offset_minutes as i64 * TICKS_PER_MINUTE;
        if !(0..=MAX_TICKS).contains(&ticks) || !(0..=MAX_TICKS).contains(&local) {
            return decline();
        }
        Ok(Dto { ticks, offset_minutes: self.offset_minutes })
    }
    /// `$this - $other`, as a TimeSpan.
    pub fn since(self, other: Dto) -> Span {
        Span(self.ticks - other.ticks)
    }
}

/// System.TimeSpan. Windows PowerShell multiplies the ticks by a reciprocal constant where
/// PowerShell 7 divides, so the two can differ in the last place.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Span(pub i64);

impl Span {
    fn total(self, ticks_per_unit: i64) -> f64 {
        if desktop() {
            self.0 as f64 * (1.0 / ticks_per_unit as f64)
        } else {
            self.0 as f64 / ticks_per_unit as f64
        }
    }
    pub fn total_seconds(self) -> f64 {
        self.total(TICKS_PER_SECOND)
    }
    pub fn total_minutes(self) -> f64 {
        self.total(TICKS_PER_MINUTE)
    }
    pub fn total_hours(self) -> f64 {
        self.total(TICKS_PER_HOUR)
    }
    pub fn total_days(self) -> f64 {
        self.total(TICKS_PER_DAY)
    }
}

/// The machine's UTC offset at an instant, in minutes: what .ToLocalTime() applies.
/// Only instants near the request's own time are answered, and only where the offset is
/// not about to change, so a daylight-saving rule the system and .NET could read
/// differently never decides the text.
#[track_caller]
pub fn local_offset_minutes(at: Dto, now: Dto) -> R<i32> {
    let two_years = 730 * TICKS_PER_DAY;
    if (at.ticks - now.ticks).abs() > two_years {
        return decline();
    }
    let offset = system_offset(at.ticks)?;
    for near in [at.ticks - 3 * TICKS_PER_HOUR, at.ticks + 3 * TICKS_PER_HOUR] {
        if system_offset(near)? != offset {
            return decline();
        }
    }
    Ok(offset)
}

#[cfg(windows)]
#[track_caller]
fn system_offset(ticks: i64) -> R<i32> {
    #[repr(C)]
    #[derive(Default)]
    struct SystemTime {
        year: u16,
        month: u16,
        day_of_week: u16,
        day: u16,
        hour: u16,
        minute: u16,
        second: u16,
        milliseconds: u16,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn SystemTimeToTzSpecificLocalTimeEx(zone: *const core::ffi::c_void, universal: *const SystemTime, local: *mut SystemTime) -> i32;
    }
    let (year, month, day) = date_of(ticks / TICKS_PER_DAY);
    let rest = ticks % TICKS_PER_DAY;
    let universal = SystemTime {
        year: year as u16,
        month: month as u16,
        day_of_week: 0,
        day: day as u16,
        hour: (rest / TICKS_PER_HOUR) as u16,
        minute: (rest / TICKS_PER_MINUTE % 60) as u16,
        second: (rest / TICKS_PER_SECOND % 60) as u16,
        milliseconds: 0,
    };
    let mut local = SystemTime::default();
    // SAFETY: both pointers refer to live, correctly laid out SYSTEMTIME values; a null
    // zone selects the current time zone.
    let done = unsafe { SystemTimeToTzSpecificLocalTimeEx(core::ptr::null(), &universal, &mut local) };
    if done == 0 {
        return decline();
    }
    let seconds = |t: &SystemTime| {
        days_before(t.year as i64, t.month as i64, t.day as i64) * 86_400 + t.hour as i64 * 3600 + t.minute as i64 * 60 + t.second as i64
    };
    let difference = seconds(&local) - seconds(&universal);
    if difference % 60 != 0 {
        return decline();
    }
    Ok((difference / 60) as i32)
}

#[cfg(target_os = "macos")]
#[track_caller]
fn system_offset(ticks: i64) -> R<i32> {
    use core::ffi::{c_char, c_int, c_long};
    #[repr(C)]
    struct Tm {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: *const c_char,
    }
    extern "C" {
        fn tzset();
        fn localtime_r(time: *const i64, result: *mut Tm) -> *mut Tm;
    }
    // .NET reads TZ its own way; without it both follow the system zone.
    if std::env::var_os("TZ").is_some_and(|value| !value.is_empty()) {
        return decline();
    }
    let seconds = ticks / TICKS_PER_SECOND - UNIX_EPOCH_SECONDS;
    let mut local = Tm { sec: 0, min: 0, hour: 0, mday: 0, mon: 0, year: 0, wday: 0, yday: 0, isdst: 0, gmtoff: 0, zone: core::ptr::null() };
    // SAFETY: time_t is a 64-bit integer on macOS and `local` is a live struct tm.
    let done = unsafe {
        tzset();
        localtime_r(&seconds, &mut local)
    };
    if done.is_null() || local.gmtoff % 60 != 0 {
        return decline();
    }
    Ok((local.gmtoff / 60) as i32)
}

#[cfg(not(any(windows, target_os = "macos")))]
#[track_caller]
fn system_offset(_ticks: i64) -> R<i32> {
    decline()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::num::double_text;
    use crate::ps::set_core;

    #[test]
    fn round_trip_form_is_parsed_and_printed() {
        let at = Dto::parse("2026-09-12T11:59:18Z").ok().unwrap();
        assert_eq!(at.o(), "2026-09-12T11:59:18.0000000+00:00");
        let at = Dto::parse("2026-10-07T23:26:23.5-05:00").ok().unwrap();
        assert_eq!(at.o(), "2026-10-07T23:26:23.5000000-05:00");
        assert_eq!(at.utc().o(), "2026-10-08T04:26:23.5000000+00:00");
        assert_eq!(at.month_day_time(), "10-07 23:26 -05:00");
        assert_eq!(Dto::parse("0001-01-01T00:00:00Z").ok().unwrap().ticks, 0);
        assert_eq!(Dto::parse("9999-12-31T23:59:59.9999999Z").ok().unwrap().ticks, MAX_TICKS);
        assert_eq!(Dto::parse("2024-02-29T00:00:00Z").ok().unwrap().o(), "2024-02-29T00:00:00.0000000+00:00");
        assert_eq!(Dto::parse("1970-01-01T00:00:00Z").ok().unwrap().unix_seconds(), 0);
        assert_eq!(Dto::from_unix_seconds(1791000000).ok().unwrap().o(), "2026-10-03T04:00:00.0000000+00:00");
    }

    #[test]
    fn other_spellings_stop() {
        assert!(matches!(Dto::parse(""), Err(crate::ps::Stop::Throw(_))));
        assert!(matches!(Dto::parse("  "), Err(crate::ps::Stop::Throw(_))));
        for text in [
            "2026-09-12 11:59:18Z",
            "2026-09-12T11:59:18",
            "2026-09-12T11:59:18z",
            "2026-09-12T11:59:18.12345678Z",
            "2026-02-29T00:00:00Z",
            "2026-09-12T24:00:00Z",
            "2026-09-12T11:59:60Z",
            "0000-01-01T00:00:00Z",
            "2026-09-12T11:59:18+15:00",
            "0001-01-01T00:00:00+01:00",
            "tomorrow",
        ] {
            assert!(matches!(Dto::parse(text), Err(crate::ps::Stop::Decline(_))), "{text}");
        }
    }

    #[test]
    fn totals_differ_by_edition() {
        let span = Span(1234567890123);
        set_core(false);
        assert_eq!(format!("{:?}", span.total_minutes()), "2057.6131502050002");
        assert_eq!(format!("{:?}", span.total_hours()), "34.29355250341666");
        assert_eq!(format!("{:?}", span.total_days()), "1.4288980209756943");
        assert_eq!(double_text(span.total_seconds()), "123456.7890123");
        assert_eq!(format!("{:?}", Span(36000000001).total_minutes()), "60.00000000166667");
        let (from, to) = (Dto::parse("2026-10-05T04:25:40.5001825+00:00").ok().unwrap(), Dto::parse("2026-10-07T23:26:23-05:00").ok().unwrap());
        assert_eq!(format!("{:?}", to.since(from).total_seconds()), "259242.49981749998");
        set_core(true);
        assert_eq!(format!("{:?}", span.total_minutes()), "2057.613150205");
        assert_eq!(format!("{:?}", span.total_hours()), "34.29355250341667");
        assert_eq!(format!("{:?}", span.total_days()), "1.4288980209756945");
        assert_eq!(format!("{:?}", Span(36000000001).total_minutes()), "60.00000000166666");
        assert_eq!(format!("{:?}", to.since(from).total_seconds()), "259242.4998175");
        assert_eq!(format!("{:?}", to.since(from).total_hours() / 5.0), "14.402361100972223");
    }
}

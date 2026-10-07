//! System.DateTimeOffset and System.TimeSpan, for the timestamps state files carry.
//! Only the round-trip form `yyyy-MM-ddTHH:mm:ss[.fffffff](Z|±hh:mm)` is modelled; other
//! spellings depend on the caller's culture and are not read.

use crate::ps::{unreadable, desktop, throw, R, V};

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
            return unreadable();
        }
        let part = |from: usize, to: usize| number(&b[from..to]);
        let (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) =
            (part(0, 4), part(5, 7), part(8, 10), part(11, 13), part(14, 16), part(17, 19))
        else {
            return unreadable();
        };
        let mut at = 19;
        let mut fraction = 0i64;
        if b[at] == b'.' {
            let digits = b[at + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
            if !(1..=7).contains(&digits) {
                return unreadable();
            }
            fraction = number(&b[at + 1..at + 1 + digits]).unwrap() * 10i64.pow(7 - digits as u32);
            at += 1 + digits;
        }
        let offset_minutes = match &b[at..] {
            [b'Z'] => 0,
            [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] => {
                let (Some(hours), Some(minutes)) = (number(&[*h1, *h2]), number(&[*m1, *m2])) else { return unreadable() };
                if minutes > 59 || hours * 60 + minutes > 14 * 60 {
                    return unreadable();
                }
                (hours * 60 + minutes) as i32 * if *sign == b'-' { -1 } else { 1 }
            }
            _ => return unreadable(),
        };
        if year < 1 || !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) || hour > 23 || minute > 59 || second > 59 {
            return unreadable();
        }
        let local = days_before(year, month, day) * TICKS_PER_DAY
            + hour * TICKS_PER_HOUR
            + minute * TICKS_PER_MINUTE
            + second * TICKS_PER_SECOND
            + fraction;
        let ticks = local - offset_minutes as i64 * TICKS_PER_MINUTE;
        if !(0..=MAX_TICKS).contains(&ticks) {
            return unreadable();
        }
        Ok(Dto { ticks, offset_minutes })
    }
    /// [datetimeoffset]::Parse($value) for a value from a state file: null throws.
    #[track_caller]
    pub fn of(value: &V) -> R<Dto> {
        match value {
            V::Null => throw(),
            V::Str(text) => Dto::parse(text),
            _ => unreadable(),
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
        let Some(ticks) = seconds.checked_mul(TICKS_PER_SECOND).and_then(|t| self.ticks.checked_add(t)) else { return unreadable() };
        let local = ticks + self.offset_minutes as i64 * TICKS_PER_MINUTE;
        if !(0..=MAX_TICKS).contains(&ticks) || !(0..=MAX_TICKS).contains(&local) {
            return unreadable();
        }
        Ok(Dto { ticks, offset_minutes: self.offset_minutes })
    }
    /// [datetimeoffset]::UtcNow
    #[track_caller]
    pub fn now() -> R<Dto> {
        let Ok(since) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) else { return unreadable() };
        let Ok(ticks) = i64::try_from(since.as_nanos() / 100) else { return unreadable() };
        Ok(Dto { ticks: UNIX_EPOCH_SECONDS * TICKS_PER_SECOND + ticks, offset_minutes: 0 })
    }
    /// `$this - $other`, as a TimeSpan.
    pub fn since(self, other: Dto) -> Span {
        Span(self.ticks - other.ticks)
    }
}

/// What the collector needs beyond the reader: times written by other programs and by
/// hand, wall-clock text for the lines it prints, and arithmetic on measured ages.
impl Dto {
    /// [datetimeoffset]::Parse($text) for text HotPl8 did not write: a native program's
    /// timestamp, or a file a person or another tool keeps. The ISO spellings are read,
    /// with or without seconds, a fraction or an offset (none means this machine's time);
    /// anything else is refused as PowerShell refused it, where a caller can catch it.
    #[track_caller]
    pub fn parse_external(text: &str) -> R<Dto> {
        let b = text.trim().as_bytes();
        let part = |from: usize, to: usize| if to <= b.len() { number(&b[from..to]) } else { None };
        if b.len() < 10 || b[4] != b'-' || b[7] != b'-' {
            return throw();
        }
        let (Some(year), Some(month), Some(day)) = (part(0, 4), part(5, 7), part(8, 10)) else { return throw() };
        let (mut hour, mut minute, mut second, mut fraction) = (0, 0, 0, 0i64);
        let mut at = 10;
        if at < b.len() {
            if !matches!(b[at], b'T' | b't' | b' ') || b.len() < 16 || b[13] != b':' {
                return throw();
            }
            let (Some(h), Some(m)) = (part(11, 13), part(14, 16)) else { return throw() };
            (hour, minute) = (h, m);
            at = 16;
            if at < b.len() && b[at] == b':' {
                let Some(s) = part(17, 19) else { return throw() };
                second = s;
                at = 19;
                if at < b.len() && b[at] == b'.' {
                    let digits = b[at + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
                    if !(1..=7).contains(&digits) {
                        return throw();
                    }
                    fraction = number(&b[at + 1..at + 1 + digits]).unwrap() * 10i64.pow(7 - digits as u32);
                    at += 1 + digits;
                }
            }
        }
        if year < 1 || !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) || hour > 23 || minute > 59 || second > 59 {
            return throw();
        }
        let wall = days_before(year, month, day) * TICKS_PER_DAY
            + hour * TICKS_PER_HOUR
            + minute * TICKS_PER_MINUTE
            + second * TICKS_PER_SECOND
            + fraction;
        let offset_minutes = match &b[at..] {
            [] => {
                // The wall time is this machine's: its offset then, settled in two steps
                // so that a time near a clock change lands on the side the system picks.
                if !(0..=MAX_TICKS).contains(&wall) {
                    return throw();
                }
                let first = local_offset_minutes(Dto { ticks: wall, offset_minutes: 0 })?;
                let guess = wall - first as i64 * TICKS_PER_MINUTE;
                if !(0..=MAX_TICKS).contains(&guess) {
                    return throw();
                }
                local_offset_minutes(Dto { ticks: guess, offset_minutes: 0 })?
            }
            [b'Z' | b'z'] => 0,
            [sign @ (b'+' | b'-'), rest @ ..] => {
                let (hours, minutes) = match rest {
                    [h1, h2] => (number(&[*h1, *h2]), Some(0)),
                    [h1, h2, m1, m2] | [h1, h2, b':', m1, m2] => (number(&[*h1, *h2]), number(&[*m1, *m2])),
                    _ => (None, None),
                };
                let (Some(hours), Some(minutes)) = (hours, minutes) else { return throw() };
                if minutes > 59 || hours * 60 + minutes > 14 * 60 {
                    return throw();
                }
                (hours * 60 + minutes) as i32 * if *sign == b'-' { -1 } else { 1 }
            }
            _ => return throw(),
        };
        let ticks = wall - offset_minutes as i64 * TICKS_PER_MINUTE;
        if !(0..=MAX_TICKS).contains(&ticks) {
            return throw();
        }
        Ok(Dto { ticks, offset_minutes })
    }
    /// [datetimeoffset]::Parse([string]$value) for a value another program wrote.
    #[track_caller]
    pub fn of_external(value: &V) -> R<Dto> {
        match value {
            V::Str(text) => Dto::parse_external(text),
            _ => throw(),
        }
    }
    /// .AddSeconds($seconds) with a measured number. Windows PowerShell rounds the step to
    /// a millisecond; PowerShell 7 keeps every tick of it.
    #[track_caller]
    pub fn plus(self, seconds: f64) -> R<Dto> {
        if !seconds.is_finite() || seconds.abs() > 315_537_897_600.0 {
            return throw();
        }
        let step = if desktop() {
            (seconds * 1000.0 + if seconds >= 0.0 { 0.5 } else { -0.5 }) as i64 * (TICKS_PER_SECOND / 1000)
        } else {
            let whole = seconds.trunc();
            whole as i64 * TICKS_PER_SECOND + ((seconds - whole) * TICKS_PER_SECOND as f64) as i64
        };
        let ticks = self.ticks + step;
        let local = ticks + self.offset_minutes as i64 * TICKS_PER_MINUTE;
        if !(0..=MAX_TICKS).contains(&ticks) || !(0..=MAX_TICKS).contains(&local) {
            return throw();
        }
        Ok(Dto { ticks, offset_minutes: self.offset_minutes })
    }
    /// [datetimeoffset]::FromUnixTimeMilliseconds($milliseconds)
    #[track_caller]
    pub fn from_unix_milliseconds(milliseconds: i64) -> R<Dto> {
        if !(-UNIX_EPOCH_SECONDS * 1000..=253_402_300_799_999).contains(&milliseconds) {
            return throw();
        }
        Ok(Dto { ticks: UNIX_EPOCH_SECONDS * TICKS_PER_SECOND + milliseconds * (TICKS_PER_SECOND / 1000), offset_minutes: 0 })
    }
    /// .ToLocalTime()
    #[track_caller]
    pub fn local(self) -> R<Dto> {
        Ok(Dto { ticks: self.ticks, offset_minutes: local_offset_minutes(self)? })
    }
    /// The same instant on the clocks of a named time zone.
    #[track_caller]
    pub fn in_zone(self, zone: &str) -> R<Dto> {
        Ok(Dto { ticks: self.ticks, offset_minutes: zone_offset_minutes(zone, self)? })
    }
    /// .ToString('HH:mm')
    pub fn hour_minute(self) -> String {
        let (_, _, _, hour, minute, _, _) = self.fields();
        format!("{hour:02}:{minute:02}")
    }
    /// .ToString('HH:mm:ss')
    pub fn hour_minute_second(self) -> String {
        let (_, _, _, hour, minute, second, _) = self.fields();
        format!("{hour:02}:{minute:02}:{second:02}")
    }
    /// .ToString('yyyy-MM-dd')
    pub fn date(self) -> String {
        let (year, month, day, _, _, _, _) = self.fields();
        format!("{year:04}-{month:02}-{day:02}")
    }
    /// .ToString('MM-dd HH:mm')
    pub fn month_day_hour_minute(self) -> String {
        let (_, month, day, hour, minute, _, _) = self.fields();
        format!("{month:02}-{day:02} {hour:02}:{minute:02}")
    }
    /// [int].DayOfWeek: Sunday is 0.
    pub fn day_of_week(self) -> i64 {
        let local = self.ticks + self.offset_minutes as i64 * TICKS_PER_MINUTE;
        // 0001-01-01 was a Monday.
        (local / TICKS_PER_DAY + 1) % 7
    }
    /// .TimeOfDay, in ticks.
    pub fn time_of_day(self) -> i64 {
        (self.ticks + self.offset_minutes as i64 * TICKS_PER_MINUTE) % TICKS_PER_DAY
    }
}

/// [timespan]::ParseExact($text,'hh\:mm',$null), in ticks.
#[track_caller]
pub fn hours_minutes(text: &str) -> R<i64> {
    let b = text.as_bytes();
    if b.len() != 5 || b[2] != b':' {
        return throw();
    }
    let (Some(hours), Some(minutes)) = (number(&b[0..2]), number(&b[3..5])) else { return throw() };
    if hours > 23 || minutes > 59 {
        return throw();
    }
    Ok(hours * TICKS_PER_HOUR + minutes * TICKS_PER_MINUTE)
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

thread_local! {
    static ZONE: std::cell::Cell<Option<i32>> = const { std::cell::Cell::new(None) };
}

/// Test-only: answer as a machine this many minutes east of UTC would, so that an expected
/// answer reads the same wherever the suite runs.
pub fn set_zone(minutes: Option<i32>) {
    ZONE.with(|cell| cell.set(minutes));
}

/// The machine's UTC offset at an instant, in minutes, by the system's own time-zone rules.
#[track_caller]
pub fn local_offset_minutes(at: Dto) -> R<i32> {
    match ZONE.with(|cell| cell.get()) {
        Some(minutes) => Ok(minutes),
        None => system_offset(at.ticks),
    }
}

/// The UTC offset, in minutes, of a named time zone at an instant: what
/// [TimeZoneInfo]::FindSystemTimeZoneById($zone) and a conversion give. A name the system
/// does not know is refused where a caller can catch it.
#[track_caller]
pub fn zone_offset_minutes(zone: &str, at: Dto) -> R<i32> {
    named_offset(zone, at.ticks)
}

#[cfg(windows)]
#[repr(C)]
#[derive(Default, Clone, Copy)]
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
/// DYNAMIC_TIME_ZONE_INFORMATION
#[cfg(windows)]
#[repr(C)]
struct ZoneRules {
    bias: i32,
    standard_name: [u16; 32],
    standard_date: SystemTime,
    standard_bias: i32,
    daylight_name: [u16; 32],
    daylight_date: SystemTime,
    daylight_bias: i32,
    key_name: [u16; 128],
    dynamic_daylight_time_disabled: u8,
}
#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn SystemTimeToTzSpecificLocalTimeEx(zone: *const ZoneRules, universal: *const SystemTime, local: *mut SystemTime) -> i32;
}
#[cfg(windows)]
#[link(name = "advapi32")]
extern "system" {
    fn EnumDynamicTimeZoneInformation(index: u32, zone: *mut ZoneRules) -> u32;
}

#[cfg(windows)]
#[track_caller]
fn offset_under(zone: *const ZoneRules, ticks: i64) -> R<i32> {
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
    // SAFETY: both time pointers refer to live, correctly laid out SYSTEMTIME values; the
    // zone is null, which selects the current time zone, or a live rule set.
    let done = unsafe { SystemTimeToTzSpecificLocalTimeEx(zone, &universal, &mut local) };
    if done == 0 {
        return unreadable();
    }
    let seconds = |t: &SystemTime| {
        days_before(t.year as i64, t.month as i64, t.day as i64) * 86_400 + t.hour as i64 * 3600 + t.minute as i64 * 60 + t.second as i64
    };
    let difference = seconds(&local) - seconds(&universal);
    if difference % 60 != 0 {
        return unreadable();
    }
    Ok((difference / 60) as i32)
}

#[cfg(windows)]
#[track_caller]
fn system_offset(ticks: i64) -> R<i32> {
    offset_under(core::ptr::null(), ticks)
}

/// Windows names its zones by registry key ("Pacific Standard Time"), in any case.
#[cfg(windows)]
#[track_caller]
fn named_offset(zone: &str, ticks: i64) -> R<i32> {
    let wanted: Vec<u16> = zone.encode_utf16().collect();
    let lower = |unit: u16| if (b'A' as u16..=b'Z' as u16).contains(&unit) { unit + 32 } else { unit };
    for index in 0.. {
        // SAFETY: the structure is plain data, for which all-zero is a valid value.
        let mut rules: ZoneRules = unsafe { core::mem::zeroed() };
        // SAFETY: `rules` is a live structure of the size the system fills in.
        if unsafe { EnumDynamicTimeZoneInformation(index, &mut rules) } != 0 {
            break;
        }
        let length = rules.key_name.iter().position(|unit| *unit == 0).unwrap_or(rules.key_name.len());
        let name = &rules.key_name[..length];
        if !wanted.is_empty() && name.len() == wanted.len() && name.iter().zip(&wanted).all(|(a, b)| lower(*a) == lower(*b)) {
            return offset_under(&rules, ticks);
        }
    }
    throw()
}

#[cfg(all(unix, target_pointer_width = "64"))]
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
    let seconds = ticks / TICKS_PER_SECOND - UNIX_EPOCH_SECONDS;
    let mut local = Tm { sec: 0, min: 0, hour: 0, mday: 0, mon: 0, year: 0, wday: 0, yday: 0, isdst: 0, gmtoff: 0, zone: core::ptr::null() };
    // SAFETY: on a 64-bit Unix time_t is a 64-bit integer, and `local` is a live struct tm
    // in the layout macOS and Linux share.
    let done = unsafe {
        tzset();
        localtime_r(&seconds, &mut local)
    };
    if done.is_null() || local.gmtoff % 60 != 0 {
        return unreadable();
    }
    Ok((local.gmtoff / 60) as i32)
}

/// Unix names its zones by file under the zone database ("America/Los_Angeles"). The C
/// library reads the file, rules for future years included, when TZ names it. The variable
/// is set and put back while no other thread of the program runs.
#[cfg(all(unix, target_pointer_width = "64"))]
#[track_caller]
fn named_offset(zone: &str, ticks: i64) -> R<i32> {
    let plain = !zone.is_empty() && zone.split('/').all(|part| !part.is_empty() && part != "." && part != "..");
    if !plain || !std::path::Path::new("/usr/share/zoneinfo").join(zone).is_file() {
        return throw();
    }
    let before = std::env::var_os("TZ");
    std::env::set_var("TZ", zone);
    let offset = system_offset(ticks);
    match before {
        Some(value) => std::env::set_var("TZ", value),
        None => std::env::remove_var("TZ"),
    }
    offset
}

#[cfg(not(any(windows, all(unix, target_pointer_width = "64"))))]
#[track_caller]
fn system_offset(_ticks: i64) -> R<i32> {
    unreadable()
}
#[cfg(not(any(windows, all(unix, target_pointer_width = "64"))))]
#[track_caller]
fn named_offset(_zone: &str, _ticks: i64) -> R<i32> {
    unreadable()
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
        assert!(Dto::parse("").is_err_and(|stop| stop.thrown()));
        assert!(Dto::parse("  ").is_err_and(|stop| stop.thrown()));
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
            assert!(Dto::parse(text).is_err_and(|stop| !stop.thrown()), "{text}");
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

    #[test]
    fn times_other_programs_write() {
        set_zone(Some(-420));
        let read = |text: &str| Dto::parse_external(text).ok().unwrap().o();
        assert_eq!(read("2026-10-06T12:34:56.123456+00:00"), "2026-10-06T12:34:56.1234560+00:00");
        assert_eq!(read("2026-10-06T12:34:56+00:00"), "2026-10-06T12:34:56.0000000+00:00");
        assert_eq!(read("2026-10-06T12:34:56Z"), "2026-10-06T12:34:56.0000000+00:00");
        assert_eq!(read("2026-10-06 12:34Z"), "2026-10-06T12:34:00.0000000+00:00");
        assert_eq!(read("2026-10-06T12:34:56-0700"), "2026-10-06T12:34:56.0000000-07:00");
        assert_eq!(read("2026-10-06T12:34:56+05"), "2026-10-06T12:34:56.0000000+05:00");
        assert_eq!(read("2026-10-06T12:34:56"), "2026-10-06T12:34:56.0000000-07:00");
        assert_eq!(read(" 2026-10-06 "), "2026-10-06T00:00:00.0000000-07:00");
        for text in ["", "not a timestamp", "2026-10-06T", "2026-10-06T12", "2026-13-06T12:34:56Z", "2026-10-06T12:34:56.Z", "2026-10-06T12:34:56+1", "06/10/2026"] {
            assert!(Dto::parse_external(text).is_err_and(|stop| stop.thrown()), "{text}");
        }
        set_zone(None);
    }

    #[test]
    fn measured_ages_and_wall_clocks() {
        let at = Dto::parse("2026-10-06T12:00:00Z").ok().unwrap();
        set_core(false);
        assert_eq!(at.plus(-12.3456789).ok().unwrap().o(), "2026-10-06T11:59:47.6540000+00:00");
        assert_eq!(at.plus(0.0005).ok().unwrap().o(), "2026-10-06T12:00:00.0010000+00:00");
        set_core(true);
        assert_eq!(at.plus(-12.3456789).ok().unwrap().o(), "2026-10-06T11:59:47.6543212+00:00");
        assert_eq!(at.plus(90.0).ok().unwrap().o(), "2026-10-06T12:01:30.0000000+00:00");
        assert!(at.plus(f64::NAN).is_err());
        assert_eq!(Dto::from_unix_milliseconds(1791000000123).ok().unwrap().o(), "2026-10-03T04:00:00.1230000+00:00");
        let wall = Dto::parse("2026-10-06T23:05:09-07:00").ok().unwrap();
        assert_eq!(wall.hour_minute(), "23:05");
        assert_eq!(wall.hour_minute_second(), "23:05:09");
        assert_eq!(wall.date(), "2026-10-06");
        assert_eq!(wall.utc().date(), "2026-10-07");
        assert_eq!(wall.month_day_hour_minute(), "10-06 23:05");
        assert_eq!(wall.day_of_week(), 2);
        assert_eq!(wall.utc().day_of_week(), 3);
        assert_eq!(Dto::parse("2026-10-04T00:00:00Z").ok().unwrap().day_of_week(), 0);
        assert_eq!(wall.time_of_day(), hours_minutes("23:05").ok().unwrap() + 9 * TICKS_PER_SECOND);
        assert!(hours_minutes("24:00").is_err());
        assert!(hours_minutes("9:00").is_err());
    }

    #[test]
    fn named_zones() {
        let at = Dto::parse("2026-07-01T12:00:00Z").ok().unwrap();
        assert_eq!(zone_offset_minutes("UTC", at).ok().unwrap(), 0);
        let name = if cfg!(windows) { "pacific standard time" } else { "America/Los_Angeles" };
        assert_eq!(zone_offset_minutes(name, at).ok().unwrap(), -420);
        assert_eq!(zone_offset_minutes(name, Dto::parse("2026-12-01T12:00:00Z").ok().unwrap()).ok().unwrap(), -480);
        assert_eq!(at.in_zone(name).ok().unwrap().hour_minute(), "05:00");
        for unknown in ["", "No Such Zone", "../etc/passwd"] {
            assert!(zone_offset_minutes(unknown, at).is_err_and(|stop| stop.thrown()), "{unknown}");
        }
    }
}

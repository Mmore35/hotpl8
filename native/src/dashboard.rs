//! `hotpl8 watch` and `hotpl8 nyan`: one frame of the dashboard, worked out from the
//! collector's cached files. A row that moves is kept as what it shows, so the instants
//! between two readings repaint it without reading anything again.

use std::cmp::Ordering;
use std::rc::Rc;

use crate::capacity::{detected_plan, fresh_timestamp};
use crate::contract::resolve_window;
use crate::insights::{health, name_text};
use crate::nyan::{self, Scene, Sprite};
use crate::overview::{future_reset, provider_overview, upper};
use crate::paint::{self, bar, budget_tone, cells, clean, padded, pulsed, right, settled, tween, Border, Colours, Glide, Span, Tone, Tweens};
use crate::policy::actions;
use crate::ps::*;
use crate::registry::{configured_providers, provider_accounts, provider_definition, provider_view, Account};
use crate::time::Dto;
use crate::tray::{codex_account_state, read_retrying};
use crate::{cat, hash, obj};

/// One row of the frame, and how to draw it again if it moves.
pub struct Line {
    pub spans: Vec<Span>,
    pub live: Option<Live>,
}

/// A row that changes between two readings of the state.
pub struct Live {
    paint: Paint,
    border: Option<Border>,
    until: f64,
    looped: bool,
    /// Milliseconds between two repaints while it moves.
    pub rate: u64,
}

enum Paint {
    Quota(Quota),
    Bar(Bar),
    Title(Title),
    Nyan { sprite: Rc<Sprite>, scene: Scene, width: usize, row: usize },
}

impl Live {
    /// Whether the row still changes that long after the dashboard opened.
    pub fn moving(&self, seconds: f64) -> bool {
        self.looped || seconds < self.until
    }

    /// The row at that instant, between the frame's edges.
    pub fn spans(&self, seconds: f64) -> Vec<Span> {
        let spans = match &self.paint {
            Paint::Quota(quota) => quota.spans(seconds),
            Paint::Bar(bar) => bar.spans(seconds),
            Paint::Title(title) => title.spans(seconds),
            Paint::Nyan { sprite, scene, width, row } => sprite.row(*scene, seconds, *width, *row),
        };
        match self.border {
            Some(border) => border.around(&spans),
            None => spans,
        }
    }
}

fn row(text: impl AsRef<str>, tone: Tone) -> Line {
    Line { spans: vec![Span::new(text, tone)], live: None }
}

fn edged(line: Line, border: Border) -> Line {
    Line { spans: border.around(&line.spans), live: line.live.map(|live| Live { border: Some(border), ..live }) }
}

/// What is asked of one frame.
pub struct View {
    pub width: usize,
    pub height: usize,
    /// How far the accounts are scrolled.
    pub offset: usize,
    pub frozen: bool,
    /// How long the dashboard has been open.
    pub seconds: f64,
    pub nyan: bool,
    pub motion: bool,
    /// For output that is not a terminal: no motion, and the cat in plain characters.
    pub plain: bool,
    pub colours: Colours,
}

pub struct Frame {
    pub lines: Vec<Line>,
    /// The scroll position the frame shows, which is what the next key moves from.
    pub offset: usize,
}

/// Get-DashboardAge
fn age(at: &V, now: Dto) -> R<Option<f64>> {
    if !at.t()? {
        return Ok(None);
    }
    catch(|| Ok(now.since(Dto::parse(&at.s()?)?).total_seconds()))
}

/// Format-DashboardAge: two units at most, seconds only under a minute.
fn span_text(seconds: f64) -> String {
    let s = seconds.floor().max(0.0) as i64;
    if s >= 86400 {
        format!("{}d {:02}h", s / 86400, s % 86400 / 3600)
    } else if s >= 3600 {
        format!("{}h {:02}m", s / 3600, s % 3600 / 60)
    } else if s >= 60 {
        format!("{}m", s / 60)
    } else {
        format!("{s}s")
    }
}

/// Format-DashboardReset. The day is named in English wherever HotPl8 runs.
fn reset_text(reset: &V, now: Dto, unix: bool, wide: bool, unconfirmed: bool) -> R<String> {
    const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    if reset.is_null() || text_eq(&reset.s()?, "")? {
        return Ok("reset ?".to_string());
    }
    let text = catch(|| {
        let at = if unix { Dto::from_unix_seconds(reset.to_long()?)? } else { Dto::parse(&reset.s()?)? };
        if at.ticks <= now.ticks {
            return Ok("reset due".to_string());
        }
        if unconfirmed {
            return Ok("reset unconfirmed".to_string());
        }
        let mut text = format!("reset {}", span_text(at.since(now).total_seconds()));
        if wide {
            let local = at.local()?;
            text += &format!("  ·  {} {}", DAYS[local.day_of_week() as usize], local.hour_minute());
        }
        Ok(text)
    })?;
    Ok(text.unwrap_or_else(|| "reset ?".to_string()))
}

/// Format-DashboardState
fn state_text(state: &str) -> R<String> {
    let named = V::s_of(state);
    Ok(if named.in_s(&["authentication_required", "subscription_login_required", "relogin_required", "no_credentials"])? {
        "SIGN-IN NEEDED".to_string()
    } else if named.in_s(&["timeout", "transport_failed", "rpc_failed", "collection_failed"])? {
        "READ UNAVAILABLE".to_string()
    } else if named.eq_s("unsupported_configuration")? {
        "CUSTOM CONFIGURATION".to_string()
    } else if named.eq_s("duplicate_subscription")? {
        "DUPLICATE ACCOUNT".to_string()
    } else if named.eq_s("backoff")? {
        "RETRYING LATER".to_string()
    } else if named.eq_s("rate_limited")? {
        "RATE LIMITED".to_string()
    } else {
        upper(&state.replace('_', " "))?
    })
}

/// Get-DashboardBadgeTone. One meaning per colour: mint is usable or chosen, lavender is
/// held back on purpose, red is out of balance, amber needs a look, muted is inert.
fn badge_tone(badge: &str) -> R<Tone> {
    // The four characters outside ASCII that some runtime reads as a letter's other case.
    if badge.chars().any(|c| matches!(c, '\u{130}' | '\u{131}' | '\u{17f}' | '\u{212a}')) {
        return unreadable();
    }
    let badge = badge.to_ascii_uppercase();
    let has = |words: &[&str]| words.iter().any(|word| badge.contains(word));
    Ok(if has(&["EXHAUSTED", "LOW BALANCE", "BLOCKED"]) {
        Tone::Red
    } else if has(&["DISABLED", "MONITORED", "NO OBSERVATION"]) {
        Tone::Muted
    } else if has(&["RESERVE"]) {
        Tone::Lavender
    } else if ["ACTIVE", "NEXT LAUNCH", "AVAILABLE"].iter().any(|word| badge.starts_with(word)) {
        Tone::Mint
    } else {
        Tone::Amber
    })
}

/// Format-DashboardForecast
fn forecast_text(forecast: &V) -> R<Option<String>> {
    if !forecast.t()? {
        return Ok(None);
    }
    let hours = forecast.g("secondsToLimit")?.div(&V::I32(3600))?.round()?;
    let outlook = if forecast.g("lastsToReset")?.t()? { "lasts to reset" } else { "may run out first" };
    Ok(Some(cat!("pace ", forecast.g("pace")?, "  ·  ~", hours, "h to limit  ·  ", outlook)))
}

/// Format-DashboardWarmOutcome
fn warm_text(outcome: &str) -> R<String> {
    let named = V::s_of(outcome);
    for (name, text) in [("observed-active", "warm ok"), ("requested", "warm sent"), ("sent", "warm sent"), ("expired", "warm done"), ("unconfirmed", "warm unconfirmed"), ("failed", "warm failed"), ("account_changed", "warm lost")] {
        if named.eq_s(name)? {
            return Ok(text.to_string());
        }
    }
    Ok(format!("warm {}", outcome.replace('_', " ")))
}

/// Format-Hotpl8ParkReason, from src/overview.ps1.
pub(crate) fn park_reason(candidate: &V) -> R<String> {
    if candidate.g("reason")?.eq_s("canceled")? {
        return Ok(cat!("plan ended (now ", candidate.g("planType")?, ")"));
    }
    Ok(cat!("no reading for ", candidate.g("days")?, " days"))
}

/// `$name + …` where the name starts the text: nothing adds nothing.
fn lead(name: &V) -> R<String> {
    match name {
        V::Null => Ok(String::new()),
        other => name_text(other),
    }
}

/// `'{0:0}' -f $value`: nothing prints as nothing.
fn whole_text(value: &V) -> R<String> {
    if value.is_null() {
        return Ok(String::new());
    }
    value.whole()
}

/// One window of an account: how much is left, and when it comes back.
#[derive(Clone)]
struct Quota {
    label: String,
    size: usize,
    left: Option<f64>,
    low: bool,
    health: Tone,
    percent: String,
    reset: String,
    motion: bool,
    glide: Option<Glide>,
}

impl Quota {
    fn spans(&self, seconds: f64) -> Vec<Span> {
        let pulse = if self.low && self.motion { paint::pulse(seconds) } else { 0.0 };
        let mark = if self.low && (pulse >= 0.5 || !self.motion) { "!" } else { " " };
        let mut spans = vec![Span::new(format!("    {}", padded(&self.label, cells(&self.label).max(3))), Tone::Muted), Span::new(mark, Tone::Red)];
        match self.left {
            Some(left) => {
                let shown = if self.motion { tween(left, self.glide, seconds) } else { left };
                let reveal = if self.motion { paint::reveal(seconds) } else { 1.0 };
                spans.extend(bar(shown, 0.0, 0.0, self.size, pulsed(self.health, pulse), reveal, -1.0));
            }
            None => spans.push(Span::new("·".repeat(self.size), Tone::Border)),
        }
        spans.push(Span::new(format!("  {}", self.percent), self.health));
        spans.push(Span::new(format!("   {}", self.reset), Tone::Muted));
        spans
    }
}

/// What a provider can use at once, as one bar.
#[derive(Clone)]
struct Bar {
    value: f64,
    gain: f64,
    unknown: f64,
    size: usize,
    low: bool,
    percent: String,
    refill: String,
    weekly: String,
    motion: bool,
    glide: Option<Glide>,
}

impl Bar {
    fn shimmers(&self) -> bool {
        self.motion && self.gain >= 0.5
    }

    fn spans(&self, seconds: f64) -> Vec<Span> {
        let health = budget_tone(self.value);
        let pulse = if self.low && self.motion { paint::pulse(seconds) } else { 0.0 };
        let reveal = if self.motion { paint::reveal(seconds) } else { 1.0 };
        let shimmer = if self.shimmers() { (seconds / 3.2) % 1.0 } else { -1.0 };
        let edge = if self.low { Tone::Red.mixed(Tone::Border, 1.0 - pulse) } else { Tone::Border };
        // The same glide as the account bars: the fill moves, the printed number does not lie.
        let shown = if self.motion { tween(self.value, self.glide, seconds) } else { self.value };
        let mut spans = vec![Span::plain("  "), Span::new("[", edge)];
        spans.extend(bar(shown, self.gain, self.unknown, self.size, pulsed(health, pulse), reveal, shimmer));
        spans.push(Span::new("]", edge));
        if !self.percent.is_empty() {
            spans.push(Span::new(format!("  {}", self.percent), health));
        }
        if !self.refill.is_empty() {
            spans.push(Span::new(format!("  {}", self.refill), Tone::Muted));
        }
        if !self.weekly.is_empty() {
            spans.push(Span::new(format!("   {}", self.weekly), Tone::Muted));
        }
        spans
    }
}

/// The frame's first row. Only the mascot moves.
#[derive(Clone)]
struct Title {
    nyan: bool,
    motion: bool,
    rest: Vec<Span>,
}

impl Title {
    fn left(&self, seconds: f64) -> String {
        if self.nyan {
            "  hotpl8  ·  nyan".to_string()
        } else {
            format!("  {}  hotpl8", paint::cat(seconds, self.motion))
        }
    }

    fn spans(&self, seconds: f64) -> Vec<Span> {
        let mut spans = vec![Span::new(self.left(seconds), Tone::Rose)];
        spans.extend(self.rest.iter().cloned());
        spans
    }
}

/// Get-Hotpl8AutomationView: what HotPl8 will do on its own, as the collector last applied
/// it. The snapshot's actions already reflect observe-only runs and pauses; the policy is
/// only a fallback for snapshots written before actions were recorded.
struct Automation {
    switching: &'static str,
    until: V,
    warming: bool,
}

fn automation(status: &V, policy: &V, now: Dto) -> R<Automation> {
    let configured = actions(policy, false)?;
    let acting = |allowed: bool| -> R<bool> { Ok(allowed && status.g("mode")?.ne_s("monitor")?) };
    let recorded = status.g("actions")?;
    let recorded = if recorded.t()? { Some(recorded) } else { None };
    let fallback = match recorded {
        Some(_) => None,
        None => Some((acting(configured.switching)?, acting(configured.warming)?)),
    };
    let does = |name: &str| -> R<bool> {
        match (&recorded, fallback) {
            (Some(recorded), _) => recorded.g(name)?.t(),
            (None, Some((switching, warming))) => Ok(if name == "switching" { switching } else { warming }),
            (None, None) => Ok(false),
        }
    };
    let pause = status.g("automationPause")?;
    let paused = pause.t()? && (pause.g("invalid")?.t()? || future_reset(&pause.g("until")?, now, false)?);
    let hold = status.g("hold")?;
    let held = hold.t()? && future_reset(&hold.g("until")?, now, false)?;
    let switching = if paused && acting(configured.switching)? {
        "paused"
    } else if !does("switching")? {
        "off"
    } else if held {
        "held"
    } else {
        "on"
    };
    let until = match switching {
        "paused" => pause.g("until")?,
        "held" => hold.g("until")?,
        _ => V::Null,
    };
    Ok(Automation { switching, until, warming: does("warming")? })
}

/// Get-Hotpl8AutomationTitleSpans. Plain words in neutral tones: being off is a choice,
/// not a fault.
fn automation_spans(view: &Automation, now: Dto, warming: bool, duration: bool, short: bool) -> R<Vec<Span>> {
    let mut left = String::new();
    if view.until.t()? && duration {
        if let Some(age) = age(&view.until, now)? {
            if age < 0.0 {
                left = format!(" {}", span_text(-age));
            }
        }
    }
    let on = view.switching == "on";
    let glyph = match view.switching {
        "on" => "● ",
        "off" => "○ ",
        _ => "◐ ",
    };
    let mut spans = vec![Span::new(glyph, if on { Tone::Mint } else { Tone::Muted }), Span::new(format!("{}{}{left}", if short { "auto " } else { "auto-switch " }, view.switching), Tone::Muted)];
    if warming && view.warming {
        spans.push(Span::new("   ● ", Tone::Mint));
        spans.push(Span::new("warming on", Tone::Muted));
    }
    Ok(spans)
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Preview,
    Frozen,
    Reading,
}

/// A word on the right of the title, and what it shortens to when the row is tight.
#[derive(Clone)]
struct Meta {
    text: String,
    tone: Tone,
    short: Option<String>,
    last: Option<&'static str>,
    kind: Kind,
    age: bool,
}

/// New-DashboardTitleRow
fn title(status: &V, now: Dto, width: usize, view: &View, motion: bool, automation: Option<&Automation>) -> R<Line> {
    let title = Title { nyan: view.nyan, motion, rest: Vec::new() };
    let left = cells(&title.left(view.seconds)) as i64;
    let word = |text: &str, tone: Tone, kind: Kind| Meta { text: text.to_string(), tone, short: None, last: None, kind, age: false };
    let mut all = Vec::new();
    if status.g("displayPolicy")?.t()? {
        all.push(Meta { short: Some("PREVIEW".to_string()), ..word("PREVIEW POLICY", Tone::Lavender, Kind::Preview) });
    }
    if view.frozen {
        all.push(word("FROZEN", Tone::Amber, Kind::Frozen));
    }
    all.push(match age(&status.g("generatedAt")?, now)? {
        None => Meta { last: Some("no data"), ..word("no reading", Tone::Amber, Kind::Reading) },
        Some(age) if age < -5.0 => Meta { short: Some("clock".to_string()), ..word("clock mismatch", Tone::Amber, Kind::Reading) },
        Some(age) if age > 900.0 => Meta { short: Some("stale".to_string()), ..word(&format!("stale {}", span_text(age)), Tone::Amber, Kind::Reading) },
        Some(age) => Meta { short: Some(span_text(age)), age: true, ..word(&format!("read {} ago", span_text(age)), Tone::Muted, Kind::Reading) },
    });
    let measure = |meta: &[Meta]| (meta.iter().map(|m| cells(&m.text) as i64 + 3).sum::<i64>() - 3).max(0);
    let mut meta = all.clone();
    let mut auto: Vec<Span> = Vec::new();
    if let Some(automation) = automation {
        // When both sides cannot fit, content gives way in a fixed order so that nothing
        // is cut mid-word and neither the state nor a reading warning is lost: warming,
        // the reading-age wording, the pause or hold duration, the reading age, warning
        // detail, the word "auto-switch", then "no reading" shortens. Only if that is
        // still too wide do FROZEN and then PREVIEW POLICY step aside, and the rest is
        // fitted again at full detail.
        const WITHOUT: [&[Kind]; 3] = [&[], &[Kind::Frozen], &[Kind::Frozen, Kind::Preview]];
        'fitting: for without in WITHOUT {
            meta = all.iter().filter(|m| !without.contains(&m.kind)).cloned().collect();
            if let Some((_, before)) = without.split_last() {
                if meta.len() == all.iter().filter(|m| !before.contains(&m.kind)).count() {
                    continue;
                }
            }
            let (mut warming, mut duration, mut short) = (true, true, false);
            for level in 0..=7 {
                match level {
                    1 => warming = false,
                    2 => meta.iter_mut().filter(|m| m.age).for_each(|m| m.text = m.short.clone().unwrap_or_default()),
                    3 => duration = false,
                    4 if meta.len() > 1 => meta.retain(|m| !m.age),
                    5 => meta.iter_mut().filter(|m| !m.age).for_each(|m| {
                        if let Some(short) = &m.short {
                            m.text = short.clone();
                        }
                    }),
                    6 => short = true,
                    7 => meta.iter_mut().for_each(|m| {
                        if let Some(last) = m.last {
                            m.text = last.to_string();
                        }
                    }),
                    _ => {}
                }
                auto = automation_spans(automation, now, warming, duration, short)?;
                let taken = 3 + auto.iter().map(|span| cells(&span.text) as i64).sum::<i64>();
                if width as i64 - 2 - left - measure(&meta) - taken >= 2 {
                    break 'fitting;
                }
            }
        }
    }
    let mut used = left;
    let mut rest = Vec::new();
    if !auto.is_empty() {
        used += 3 + auto.iter().map(|span| cells(&span.text) as i64).sum::<i64>();
        rest.push(Span::plain("   "));
        rest.extend(auto);
    }
    rest.push(Span::plain(" ".repeat((width as i64 - 2 - used - measure(&meta)).max(2) as usize)));
    for (index, word) in meta.iter().enumerate() {
        if index > 0 {
            rest.push(Span::new(" · ", Tone::Border));
        }
        rest.push(Span::new(&word.text, word.tone));
    }
    let title = Title { rest, ..title };
    let live = if !view.nyan && motion { Some(Live { paint: Paint::Title(title.clone()), border: None, until: 0.0, looped: true, rate: 200 }) } else { None };
    Ok(Line { spans: title.spans(view.seconds), live })
}

/// A few words about one automation event, using the account labels people know.
struct Note {
    text: String,
    age: String,
    /// Amber for what needs a look, mint for what happened in the last five minutes.
    tone: Tone,
}

/// Get-DashboardActivityNote
fn note(event: &V, accounts: &[Account], now: Dto) -> R<Note> {
    let slot = event.g("slot")?.s()?;
    let named = catch(|| {
        let mut found = Vec::new();
        for account in accounts {
            if V::s_of(&account.provider).ceq(&event.g("provider")?)? && V::s_of(&account.slot).ceq_s(&slot)? {
                found.push(&account.label);
            }
        }
        match found.as_slice() {
            [label] if label.t()? => Ok(Some(label.s()?)),
            _ => Ok(None),
        }
    })?;
    let label = clean(&named.flatten().unwrap_or(slot));
    let reason = event.g("reason")?.s()?;
    let (kind, why) = (V::s_of(&event.g("kind")?.s()?), V::s_of(&reason));
    let mut tone = Tone::Muted;
    let mut failing = |ok: bool, done: &str, failed: &str| {
        if !ok {
            tone = Tone::Amber;
        }
        format!("{} {label}", if ok { done } else { failed })
    };
    let text = if kind.eq_s("switch")? {
        failing(why.eq_s("native_switch_succeeded")?, "switched →", "switch failed →")
    } else if kind.eq_s("active_changed")? {
        format!("active → {label}")
    } else if kind.eq_s("warm_attempt")? {
        failing(why.eq_s("sent")?, "warm sent ·", "warm failed ·")
    } else if kind.eq_s("warm_outcome")? {
        let outcome = warm_text(&reason)?;
        failing(!why.in_s(&["unconfirmed", "failed", "account_changed"])?, &format!("{outcome} ·"), &format!("{outcome} ·"))
    } else if kind.eq_s("recovery_probe")? {
        failing(why.eq_s("sent")?, "probe sent ·", "probe failed ·")
    } else if kind.eq_s("credential_unrenewed")? {
        failing(false, "", "sign-in not renewed ·")
    } else if kind.eq_s("recommendation")? {
        let provider = event.g("provider")?;
        let known = catch(|| provider_definition(&provider.s()?)?.g("name"))?;
        let name = match known {
            Some(name) => name_text(&name)?,
            None => provider.s()?,
        };
        if !printable(&name) {
            return unreadable();
        }
        format!("{} next → {label}", name.to_ascii_lowercase())
    } else {
        format!("{} · {label}", event.g("kind")?.s()?.replace('_', " "))
    };
    let seconds = age(&event.g("at")?, now)?;
    if tone != Tone::Amber && seconds.is_some_and(|seconds| seconds < 300.0) {
        tone = Tone::Mint;
    }
    Ok(Note { text: clean(&text), age: seconds.map(span_text).unwrap_or_default(), tone })
}

/// One configured provider as its family's rules read it.
struct Provider {
    id: String,
    family: String,
    name: V,
    numeric: bool,
    snapshot: V,
    policy: V,
}

/// What a view of the snapshot hands on as it is: the dashboard reads these from the
/// snapshot itself.
const CARRIED: [&str; 4] = ["providerOverview", "parkCandidates", "recentActions", "shadow"];

fn providers(status: &V, policy: &V) -> R<Vec<Provider>> {
    let mut providers = Vec::new();
    for registration in configured_providers(policy, true)? {
        let id = registration.g("id")?.s()?;
        let view = provider_view(status, policy, &id, &CARRIED)?;
        providers.push(Provider {
            family: view.g("provider")?.s()?,
            name: registration.g("name")?,
            numeric: view.path(&["driver", "slotKind"])?.eq_s("numeric")?,
            snapshot: view.g("snapshot")?,
            policy: view.g("policy")?,
            id,
        });
    }
    Ok(providers)
}

/// One reading of a window, as the snapshot holds it.
struct Reading<'a> {
    label: &'a str,
    used: &'a V,
    reset: &'a V,
    observed: &'a V,
    unix: bool,
    unconfirmed: bool,
    stale: bool,
    key: String,
}

/// One layout of the frame's rows. Only a layout records where a bar is going.
struct Pass<'a> {
    status: &'a V,
    policy: &'a V,
    accounts: &'a [Account],
    providers: &'a [Provider],
    now: Dto,
    width: usize,
    seconds: f64,
    motion: bool,
    tweens: &'a mut Tweens,
}

impl Pass<'_> {
    /// New-DashboardQuotaRow
    fn quota(&mut self, reading: Reading) -> R<Line> {
        // A window whose own reported reset has passed since we read it refilled. Draw
        // the refilled window and say the confirming read has not landed yet, instead of
        // stamping the pre-reset value 'reset due'. A stale reading is never rolled over:
        // it already lost the right to speak for the account.
        let window = if reading.stale {
            hash! {"used" => reading.used, "resetAt" => reading.reset, "rolledOver" => false}
        } else {
            resolve_window(reading.used, reading.reset, reading.observed, self.now, reading.unix)?
        };
        let value = window.g("used")?;
        let left = if value.is_number() && value.ge_i(0)? && value.le_i(100)? { Some(100.0 - value.dbl()?) } else { None };
        let fresh = left.filter(|_| !reading.stale);
        let reset_at = window.g("resetAt")?;
        // A full window with no reset time has not started; say so instead of 'reset ?'.
        let reset = match left {
            None => "no reading".to_string(),
            Some(_) if window.g("rolledOver")?.t()? => if self.width >= 80 { "reset · awaiting read" } else { "awaiting read" }.to_string(),
            Some(left) if left >= 100.0 && (reset_at.is_null() || text_eq(&reset_at.s()?, "")?) => "idle".to_string(),
            Some(_) => reset_text(&reset_at, self.now, reading.unix, self.width >= 96, reading.unconfirmed)?,
        };
        let glide = match left {
            Some(left) if self.motion && !reading.key.is_empty() && self.seconds > 0.0 => self.tweens.anchor(&format!("quota|{}", reading.key), left, self.seconds),
            _ => None,
        };
        let quota = Quota {
            label: reading.label.to_string(),
            size: if self.width >= 80 { 20 } else { 12 },
            left,
            low: fresh.is_some_and(|left| left < 10.0),
            health: fresh.map_or(Tone::Muted, budget_tone),
            percent: left.map_or_else(|| "   ?".to_string(), |left| format!("{}%", right(&crate::num::double_whole(left), 3))),
            reset,
            motion: self.motion,
            glide,
        };
        let live = if self.motion && left.is_some() { Some(Live { until: settled(glide), looped: quota.low, rate: 150, border: None, paint: Paint::Quota(quota.clone()) }) } else { None };
        Ok(Line { spans: quota.spans(self.seconds), live })
    }

    /// What is wrong with the readings as a whole, above the first provider.
    fn warnings(&self, out: &mut Vec<Line>, global: &V, stale: bool) -> R<()> {
        let now = self.now;
        if !global.g("generatedAt")?.t()? {
            out.push(row("  no reading yet  ·  hotpl8 refresh", Tone::Amber));
        } else if stale {
            out.push(row("  ! readings stale  ·  hotpl8 refresh", Tone::Amber));
        }
        let mut slots = global.g("slots")?.arr();
        let mut readable = global.g("parkedReadable")?.arr();
        for (_, provider) in global.g("providers")?.props()? {
            slots.extend(filter(&provider.g("slots")?.each(), |slot| Ok(slot.t()? && !read_retrying(slot, now)?))?);
            readable.extend(provider.g("parkedReadable")?.arr());
        }
        let unavailable = filter(&slots, |slot| Ok(slot.t()? && !slot.g("status")?.in_s(&["ok", "disabled"])?))?.len();
        // When every unavailable account has been unreadable for over a week, name it
        // and offer the two real choices instead of a general pointer. Other account
        // problems are shown on the account's own row.
        let candidates = global.g("parkCandidates")?.each();
        let dormant = filter(&candidates, |candidate| Ok(candidate.t()? && candidate.g("reason")?.eq_s("dormant")?))?;
        let ended = filter(&candidates, |candidate| Ok(candidate.t()? && candidate.g("reason")?.eq_s("canceled")?))?;
        let who = |list: &[V], many: &str| -> R<String> {
            match list {
                [only] => Ok(cat!(only.g("label")?.s()?, ": ", park_reason(only)?)),
                _ => Ok(format!("{} {many}", list.len())),
            }
        };
        if unavailable > 0 && dormant.len() >= unavailable {
            out.push(row(format!("  ! {}  ·  sign in, or hotpl8 park", who(&dormant, "accounts unread for over a week")?), Tone::Amber));
        }
        if !ended.is_empty() {
            out.push(row(format!("  ! {}  ·  hotpl8 park", who(&ended, "accounts no longer have a paid plan")?), Tone::Amber));
        }
        for account in filter(&readable, |account| Ok(account.t()? && account.g("slot")?.t()?))? {
            let label = account.g("label")?;
            let name = if label.t()? { label.s()? } else { cat!("Slot ", account.g("slot")?) };
            out.push(row(format!("  {name} is readable again  ·  hotpl8 unpark"), Tone::Cyan));
        }
        let collector = global.g("collector")?;
        if collector.t()? {
            let health = health(&collector, now, "")?;
            if !V::s_of(&health).in_s(&["recent collection completed", "collecting", "provider checks incomplete"])? {
                out.push(row(format!("  ! {health}"), Tone::Amber));
            }
        }
        Ok(())
    }

    /// New-DashboardAccountRow
    fn account(name: &str, id: &str, badge: &str, accent: Tone, selected: bool) -> R<Line> {
        let spans = vec![
            Span::plain("  "),
            if selected { Span::new("● ", accent) } else { Span::new("○ ", Tone::Border) },
            Span::new(name, if selected { Tone::Text } else { Tone::Muted }),
            Span::new(format!("  [{id}]  ·  "), Tone::Border),
            Span::new(badge, badge_tone(badge)?),
        ];
        Ok(Line { spans, live: None })
    }

    fn heading(provider: &Provider, family: &str, count: usize) -> R<String> {
        let name = provider.name.s()?;
        let name = if name.is_empty() { family.to_string() } else { upper(&name)? };
        Ok(format!("  {name}  /  {count} subscription{}", if count == 1 { "" } else { "s" }))
    }

    /// The accounts of a provider whose slots are numbered.
    fn claude(&mut self, out: &mut Vec<Line>, provider: &Provider, stale: bool, compact: bool) -> R<()> {
        let (status, policy, now) = (&provider.snapshot, &provider.policy, self.now);
        let mut slots = filter(&status.g("slots")?.each(), |slot| Ok(!slot.is_null()))?;
        if slots.is_empty() && policy.g("labels")?.t()? {
            slots = policy.g("labels")?.props()?.into_iter().map(|(name, label)| obj! {"slot" => &*name, "label" => label, "status" => "no observation"}).collect();
        }
        out.push(row(Self::heading(provider, "CLAUDE", slots.len())?, Tone::Peach));
        if slots.is_empty() {
            out.push(row("    none in this snapshot", Tone::Muted));
        }
        for slot in &slots {
            let (observed, id, state) = (slot.g("observedAt")?, slot.g("slot")?, slot.g("status")?);
            let is_stale = stale || !slot.g("fresh")?.t()? || (observed.t()? && !fresh_timestamp(&observed, now)?);
            let mut badge = if slot.g("active")?.t()? {
                "ACTIVE"
            } else if id.is_in(&policy.g("reserve")?)? {
                "RESERVE"
            } else {
                "MONITORED"
            }
            .to_string();
            if state.ne_s("ok")? {
                badge = state_text(&state.s()?)?;
            } else if is_stale {
                badge = "STALE".to_string();
            } else if slot.g("cold")?.t()? {
                badge += " · resting";
            }
            let label = slot.g("label")?;
            let name = if label.t()? { label.s()? } else { cat!("Slot ", id) };
            let disabled = id.is_in(&policy.g("disabled")?)? || state.eq_s("disabled")?;
            if disabled {
                badge = "DISABLED".to_string();
            }
            let plan = slot.g("plan")?;
            let detected = detected_plan(&plan, now)?;
            if detected {
                badge = cat!(badge, " · ", plan.g("label")?);
            }
            out.push(Self::account(&name, &id.s()?, &badge, Tone::Peach, slot.g("active")?.t()? && !disabled)?);
            if disabled {
                continue;
            }
            for (label, used, reset) in [("5h", "used5h", "reset5h"), ("7d", "used7d", "reset7d")] {
                let key = cat!(provider.id, "|", id, "|", label);
                out.push(self.quota(Reading { label, used: &slot.g(used)?, reset: &slot.g(reset)?, observed: &observed, unix: false, unconfirmed: false, stale: is_stale, key })?);
            }
            if compact {
                continue;
            }
            if is_stale {
                let text = match age(&observed, now)? {
                    Some(age) => format!("last read {} ago  ·  awaiting update", span_text(age)),
                    None => "no valid reading  ·  hotpl8 explain".to_string(),
                };
                out.push(row(format!("    {text}"), Tone::Amber));
            } else if let Some(forecast) = forecast_text(&slot.g("forecast")?)? {
                out.push(row(format!("    {forecast}"), Tone::Muted));
            }
            let (mut notes, mut attention) = (Vec::new(), false);
            let warm = slot.g("warmOutcome")?;
            if warm.t()? {
                let outcome = warm.g("outcome")?.s()?;
                notes.push(warm_text(&outcome)?);
                attention = V::s_of(&outcome).in_s(&["unconfirmed", "failed", "account_changed"])?;
            }
            let block = slot.g("actionBlock")?;
            if block.t()? {
                let block = block.s()?;
                notes.push(if text_eq(&block, "automation_paused")? { "warming paused".to_string() } else { format!("warming off · {}", block.replace('_', " ")) });
            }
            let model = slot.g("modelBlock")?;
            if model.t()? {
                notes.push(model.s()?.replace('_', " "));
                attention = true;
            }
            if plan.t()? && !detected {
                notes.push("plan unverified".to_string());
            }
            for scope in slot.g("scoped")?.arr() {
                if scope.t()? {
                    notes.push(cat!(lead(&scope.g("name")?)?, " ", scope.g("pct")?, "% used"));
                }
            }
            if !notes.is_empty() {
                out.push(row(format!("    {}", notes.join("  ·  ")), if attention { Tone::Amber } else { Tone::Muted }));
            }
            out.push(row("", Tone::Text));
        }
        Ok(())
    }

    /// The accounts of a provider whose slots are named.
    fn codex(&mut self, out: &mut Vec<Line>, provider: &Provider, compact: bool) -> R<()> {
        let (status, policy, now) = (&provider.snapshot, &provider.policy, self.now);
        let (codex, part) = (status.path(&["providers", "codex"])?, policy.g("codex")?);
        let mut configured = filter(&part.g("slots")?.each(), |slot| Ok(!slot.is_null()))?;
        if configured.is_empty() {
            configured = filter(&codex.g("slots")?.each(), |slot| Ok(!slot.is_null()))?;
        }
        out.push(row(Self::heading(provider, "CODEX", configured.len())?, Tone::Cyan));
        if configured.is_empty() {
            out.push(row("    none enrolled yet", Tone::Muted));
        }
        let failure = codex.g("failureCode")?;
        if failure.eq_s("state_io_failed")? {
            out.push(row("    ! local state write failed; retrying · last readings below", Tone::Amber));
        } else if failure.t()? {
            out.push(row(cat!("    ! read failed  ·  ", failure, " / ", codex.g("failureStage")?), Tone::Amber));
        }
        for config in &configured {
            let id = config.g("id")?;
            let item = filter(&codex.g("slots")?.each(), |slot| slot.g("id")?.eq(&id))?.first().cloned().unwrap_or(V::Null);
            let label = config.g("label")?;
            let name = if label.t()? { label.s()? } else { id.s()? };
            let is_stale = age(&item.g("observedAt")?, now)?.is_none_or(|age| !(-5.0..=900.0).contains(&age));
            let mut badge = codex_account_state(&item, &part, &codex, now)?;
            let disabled = id.is_in(&part.g("disabled")?)? || item.g("status")?.eq_s("disabled")?;
            if disabled {
                badge = "DISABLED".to_string();
            }
            out.push(Self::account(&name, &id.s()?, &badge, Tone::Cyan, badge == "NEXT LAUNCH")?);
            if disabled {
                continue;
            }
            if !item.t()? || !item.g("buckets")?.t()? {
                out.push(row("    no reading yet", Tone::Muted));
            }
            let mut buckets = Vec::new();
            for (name, bucket) in item.g("buckets")?.props()? {
                if !text_eq(&name, "codex_bengalfox")? {
                    buckets.push((text_eq(&name, "codex")?, name, bucket));
                }
            }
            let buckets = sort(&buckets, |a, b| if a.0 == b.0 { order_text(&a.1, &b.1) } else { Ok(b.0.cmp(&a.0)) }, |_, _| false)?;
            for (main, bucket_name, bucket) in &buckets {
                if !main {
                    let state = bucket.g("status")?;
                    let state = if state.eq_s("constraint_unknown")? {
                        "limit unknown"
                    } else if state.eq_s("blocked")? {
                        "blocked"
                    } else if state.eq_s("unsupported")? {
                        "unsupported quota"
                    } else {
                        ""
                    };
                    out.push(if state.is_empty() { row(format!("    {bucket_name}"), Tone::Muted) } else { row(format!("    {bucket_name}  ·  {state}"), Tone::Amber) });
                }
                // A window is named by its length in minutes.
                let mut windows = Vec::new();
                for (minutes, window) in bucket.g("windows")?.props()? {
                    if minutes.is_empty() || !minutes.bytes().all(|b| b.is_ascii_digit()) {
                        return unreadable();
                    }
                    let Ok(length) = minutes.parse::<i32>() else { return unreadable() };
                    windows.push((length, minutes, window));
                }
                let windows = sort(&windows, |a, b| Ok::<Ordering, Stop>(a.0.cmp(&b.0)), |_, _| false)?;
                for (_, minutes, window) in &windows {
                    let label = match &**minutes {
                        "300" => "5h".to_string(),
                        "10080" => "7d".to_string(),
                        other => format!("{other}m"),
                    };
                    let key = cat!(provider.id, "|", id, "|", &**bucket_name, "|", &**minutes);
                    out.push(self.quota(Reading {
                        label: &label,
                        used: &window.g("usedPercent")?,
                        reset: &window.g("resetsAt")?,
                        observed: &window.g("observedAt")?,
                        unix: true,
                        unconfirmed: window.g("anchorState")?.eq_s("unconfirmed")?,
                        stale: is_stale,
                        key,
                    })?);
                }
                if windows.is_empty() {
                    out.push(row("    no quota yet", Tone::Muted));
                }
                if compact {
                    continue;
                }
                if !is_stale {
                    if let Some(forecast) = forecast_text(&bucket.g("forecast")?)? {
                        out.push(row(format!("    {forecast}"), Tone::Muted));
                    }
                }
                let plan = item.g("planType")?;
                if plan.t()? && plan.ne_s("unknown")? {
                    out.push(row(cat!("    plan ", plan), Tone::Muted));
                }
            }
            if !compact {
                out.push(row("", Tone::Text));
            }
        }
        Ok(())
    }

    /// Get-Hotpl8DashboardRows: every account, provider by provider.
    fn rows(&mut self, compact: bool, list_lone_event: bool) -> R<Vec<Line>> {
        let (status, now) = (self.status, self.now);
        if self.accounts.is_empty() && !status.t()? {
            return Ok(vec![
                row("  No accounts yet.", Tone::Text),
                row("  Connect your first account: hotpl8 setup", Tone::Cyan),
                row("  Or ask your agent to add a Claude or Codex account.", Tone::Text),
                row("  Complete provider sign-in only when needed.", Tone::Peach),
                row("  HotPl8 connects the account and reads usage for you.", Tone::Mint),
            ]);
        }
        let mut out = Vec::new();
        let stale = age(&status.g("generatedAt")?, now)?.is_none_or(|age| !(-5.0..=900.0).contains(&age));
        let providers = self.providers;
        for (index, provider) in providers.iter().enumerate() {
            if index == 0 {
                self.warnings(&mut out, if status.t()? { status } else { &provider.snapshot }, stale)?;
            }
            if provider.family == "claude" {
                self.claude(&mut out, provider, stale, compact)?;
            } else {
                self.codex(&mut out, provider, compact)?;
            }
        }
        // The footer shows the latest event when it has room; list history when there is
        // more than that, or when the caller found no room for a single event.
        let events = status.g("recentActions")?.each();
        let recorded = filter(&events, |event| event.t())?.len();
        if !compact && (recorded > 1 || (recorded == 1 && list_lone_event)) {
            out.push(row("  RECENT", Tone::Muted));
            for event in &events[events.len().saturating_sub(3)..] {
                let note = note(event, self.accounts, now)?;
                let when = if note.age.is_empty() { String::new() } else { format!("  |  {} ago", note.age) };
                out.push(row(format!("    {}{when}", note.text), if note.tone == Tone::Amber { Tone::Amber } else { Tone::Muted }));
            }
        }
        Ok(out)
    }

    /// Get-Hotpl8OverviewRows: a heading and a bar for each provider.
    fn overview(&mut self, width: usize) -> R<Vec<Line>> {
        let cached = self.status.g("providerOverview")?;
        let overview = if cached.t()? { cached } else { provider_overview(self.status, self.policy, self.now)? };
        let mut out = Vec::new();
        for (id, p) in overview.props()? {
            let Some(provider) = self.providers.iter().find(|provider| *provider.id == *id) else { return unreadable() };
            let name = p.g("name")?;
            let title = if name.t()? { upper(&name_text(&name)?)? } else { upper(&id)? };
            let chips = chips(&provider.snapshot, &p, &provider.family)?;
            out.push(header(&title, if provider.numeric { Tone::Peach } else { Tone::Cyan }, chips, width));
            out.push(self.capacity(&p, width, &id)?);
        }
        Ok(out)
    }

    /// New-DashboardOverviewBarRow
    fn capacity(&mut self, p: &V, width: usize, key: &str) -> R<Line> {
        let now = self.now;
        let c = if p.g("immediate")?.t()? { p.g("immediate")? } else { p.g("capacity")? };
        let complete = c.g("complete")?.t()?;
        let value = c.g("knownUsablePercent")?.dbl()?;
        let coming = |amount: &str, at: &str| -> R<f64> {
            let amount = c.g(amount)?;
            if complete && !amount.is_null() && c.g(at)?.t()? {
                amount.dbl()
            } else {
                Ok(0.0)
            }
        };
        let until = |at: &str| -> R<String> { Ok(span_text(Dto::parse(&c.g(at)?.s()?)?.since(now).total_seconds())) };
        let gain = coming("projectedGainPercent", "nextResetAt")?;
        let unknown = if complete { 0.0 } else { c.g("unknownPercent")?.dbl()? };
        let estimate = c.g("metric")?.eq_s("plan-weighted-quota-headroom")?;
        let percent = if complete { format!("{}{}% now", if estimate { "~" } else { "" }, whole_text(&c.g("usableNowPercent")?)?) } else { String::new() };
        // A refill beyond 24h is text only: it never hatches or shimmers the bar.
        let later = coming("laterRefillGainPercent", "laterRefillAt")?;
        let refill = if gain >= 0.5 {
            format!("+{}% in {}", crate::num::double_whole(gain), until("nextResetAt")?)
        } else if later >= 0.5 {
            format!("+{}% in {}", crate::num::double_whole(later), until("laterRefillAt")?)
        } else if complete && c.g("nextResetAt")?.t()? {
            format!("reset {}", until("nextResetAt")?)
        } else if complete && !c.g("projectionComplete")?.t()? {
            "refill unconfirmed".to_string()
        } else {
            String::new()
        };
        // Weekly-only accounts have no separate weekly figure: the estimate is the weekly figure.
        let accounts = c.g("accounts")?.arr();
        let shorter = filter(&accounts, |account| Ok(!filter(&account.g("windows")?.each(), |window| window.g("name")?.ne_s("10080"))?.is_empty()))?;
        let weekly_only = !accounts.is_empty() && shorter.is_empty();
        let remaining = p.g("remainingPercent")?;
        let mut weekly = if !remaining.is_null() && ((estimate && !weekly_only) || (remaining.dbl()? - value).abs() >= 0.5) { format!("7d {}%", whole_text(&remaining)?) } else { String::new() };
        let text = cells(&percent) as i64 + if refill.is_empty() { 0 } else { 2 + cells(&refill) as i64 };
        let room = width as i64 - 8 - text;
        let mut size = (room - if weekly.is_empty() { 0 } else { 3 + cells(&weekly) as i64 }).min(40);
        if size < 12 && !weekly.is_empty() {
            weekly.clear();
            size = room.min(40);
        }
        let glide = if self.motion && !key.is_empty() && self.seconds > 0.0 { self.tweens.anchor(&format!("overview|{key}"), value, self.seconds) } else { None };
        let bar = Bar { value, gain, unknown, size: size.max(8) as usize, low: complete && value < 10.0, percent, refill, weekly, motion: self.motion, glide };
        let live = if self.motion && (complete || value > 0.0) { Some(Live { until: settled(glide), looped: bar.low || bar.shimmers(), rate: 150, border: None, paint: Paint::Bar(bar.clone()) }) } else { None };
        Ok(Line { spans: bar.spans(self.seconds), live })
    }
}

/// Get-DashboardChips. Provider-level words only: the automation state lives in the title
/// bar and account problems on their own account rows, so neither repeats here.
fn chips(snapshot: &V, p: &V, family: &str) -> R<Vec<(String, Tone)>> {
    let c = if p.g("immediate")?.t()? { p.g("immediate")? } else { p.g("capacity")? };
    let mut chips = Vec::new();
    let selected = p.g("selected")?;
    if family != "claude" && selected.t()? {
        let mut slots = snapshot.g("slots")?.arr();
        slots.extend(snapshot.path(&["providers", "codex", "slots"])?.arr());
        let labelled = filter(&slots, |slot| Ok(slot.t()? && slot.g("id")?.ceq(&selected)? && slot.g("label")?.t()?))?;
        let name = match labelled.first() {
            Some(slot) => slot.g("label")?.s()?,
            None => selected.s()?,
        };
        chips.push((clean(&format!("next: {name}")), Tone::Mint));
    }
    if c.path(&["critical", "active"])?.t()? {
        chips.push(("CRITICAL".to_string(), Tone::Rose));
    }
    Ok(chips)
}

/// New-DashboardHeaderRow
fn header(title: &str, accent: Tone, mut chips: Vec<(String, Tone)>, width: usize) -> Line {
    let length = |chips: &[(String, Tone)]| chips.iter().map(|(text, _)| cells(text) + 2).sum::<usize>().saturating_sub(2);
    // Keep the row on one line: drop the quietest chips first when space is short.
    while !chips.is_empty() && 2 + cells(title) + 2 + length(&chips) + 2 > width {
        let quietest = chips.iter().rposition(|(_, tone)| *tone == Tone::Muted).unwrap_or(chips.len() - 1);
        chips.remove(quietest);
    }
    let mut spans = vec![Span::new(format!("  {title}"), accent)];
    if !chips.is_empty() {
        let gap = (width as i64 - 4 - cells(title) as i64 - length(&chips) as i64).max(2);
        spans.push(Span::plain(" ".repeat(gap as usize)));
        for (index, (text, tone)) in chips.iter().enumerate() {
            if index > 0 {
                spans.push(Span::plain("  "));
            }
            spans.push(Span::new(text, *tone));
        }
    }
    Line { spans, live: None }
}

/// Get-DashboardFooterParts: the keys, and the latest automation event beside the page
/// indicator when it fits.
struct Footer {
    keys: &'static str,
    gap: usize,
    activity: Option<(String, Tone)>,
}

fn footer(status: &V, accounts: &[Account], now: Dto, inside: usize, page: &str) -> R<Footer> {
    // Narrow frames drop key hints before they can crowd the page indicator.
    let keys = ["  q quit  ·  space freeze  ·  ↑↓ scroll", "  q quit  ·  ↑↓ scroll"].into_iter().find(|keys| cells(keys) + cells(page) + 4 <= inside).unwrap_or("  q  ·  ↑↓");
    let gap = (inside as i64 - 2 - cells(keys) as i64 - cells(page) as i64).max(2) as usize;
    let mut activity = None;
    if let Some(event) = filter(&status.g("recentActions")?.each(), |event| event.t())?.last() {
        let note = note(event, accounts, now)?;
        let text = if note.age.is_empty() { note.text } else { format!("{}  ·  {} ago", note.text, note.age) };
        if cells(&text) + 4 <= gap {
            activity = Some((text, note.tone));
        }
    }
    Ok(Footer { keys, gap, activity })
}

/// A few words where the dashboard would be: for a terminal too small for it, and for a
/// state that cannot be read.
pub fn words(lines: &[&str], width: usize, height: usize) -> Frame {
    let width = width.clamp(1, 110);
    Frame { lines: lines.iter().take(height.max(1)).map(|text| row(padded(&clean(text), width), Tone::Muted)).collect(), offset: 0 }
}

/// Get-Hotpl8DashboardFrame
pub fn frame(status: &V, policy: &V, now: Dto, view: &View, tweens: &mut Tweens) -> R<Frame> {
    let width = view.width.clamp(1, 110);
    if width < 48 || view.height < 17 {
        return Ok(words(&["hotpl8 (=^.^=)", "Make the terminal larger.", "Q quit / Esc back"], width, view.height));
    }
    let (inside, height) = (width - 2, view.height);
    let motion = view.motion && !view.plain && !policy.path(&["display", "reducedMotion"])?.t()?;
    let accounts = provider_accounts(policy)?;
    let providers = providers(status, policy)?;
    // Nothing to switch between until an account exists, so first run stays quiet.
    let automation = if status.t()? || !accounts.is_empty() { Some(automation(status, policy, now)?) } else { None };
    let mut pass = Pass { status, policy, accounts: &accounts, providers: &providers, now, width, seconds: view.seconds, motion, tweens };
    let mut rows = pass.rows(height < 32, false)?;
    let summary = pass.overview(inside)?;
    let mut cat: Vec<Line> = Vec::new();
    if let Some(scene) = Scene::fitting(inside, height, summary.len(), view.colours).filter(|_| view.nyan) {
        if view.plain {
            cat = nyan::plain().into_iter().map(|spans| Line { spans, live: None }).collect();
        } else {
            let sprite = nyan::sprite()?;
            for row in 0..scene.rows() {
                let paint = Paint::Nyan { sprite: sprite.clone(), scene, width: inside, row };
                let live = Live { paint, border: None, until: 0.0, looped: true, rate: 42 };
                let spans = live.spans(if motion { view.seconds } else { 0.0 });
                cat.push(Line { spans, live: Some(live).filter(|_| motion) });
            }
        }
    }
    let available = (height as i64 - 7 - summary.len() as i64 - cat.len() as i64).max(1) as usize;
    let page_of = |count: usize, at: usize| if count > available { format!("[{}-{}/{count}]", at + 1, count.min(at + available)) } else { String::new() };
    let resolved = |count: usize| view.offset.min(count.saturating_sub(available));
    // A single recent event must appear somewhere: list it when the footer has no room.
    if height >= 32 && filter(&status.g("recentActions")?.each(), |event| event.t())?.len() == 1 {
        let page = page_of(rows.len(), resolved(rows.len()));
        if footer(status, &accounts, now, inside, &page)?.activity.is_none() {
            rows = pass.rows(false, true)?;
        }
    }
    // Prefer showing every account over spending the viewport on forecasts and other
    // optional lines above an account that would otherwise disappear below the fold.
    // Base this on actual content, not just a fixed terminal height.
    if height >= 32 && rows.len() > available {
        let compact = pass.rows(true, false)?;
        if compact.len() <= available {
            rows = compact;
        }
    }
    let offset = resolved(rows.len());
    let border = Border::new(inside);
    let rule = |left: char, right: char| row(format!("{left}{}{right}", "─".repeat(inside)), Tone::Border);
    let mut lines = vec![rule('╭', '╮'), edged(title(status, now, inside, view, motion, automation.as_ref())?, border)];
    lines.extend(cat.into_iter().map(|line| edged(line, border)));
    lines.push(rule('├', '┤'));
    lines.extend(summary.into_iter().map(|line| edged(line, border)));
    lines.push(rule('├', '┤'));
    // A thumb in the right border shows where the details viewport sits.
    let count = rows.len();
    let (mut thumb, mut thumb_at) = (0, 0);
    if count > available {
        thumb = (available * available / count).max(1);
        thumb_at = (offset as f64 / (count - available).max(1) as f64 * (available - thumb) as f64).round_ties_even() as usize;
    }
    for (index, line) in rows.into_iter().skip(offset).take(available).enumerate() {
        let on_thumb = thumb > 0 && (thumb_at..thumb_at + thumb).contains(&index);
        lines.push(edged(line, if on_thumb { Border { glyph: '┃', tone: Tone::Muted, ..border } } else { border }));
    }
    lines.push(rule('├', '┤'));
    let page = page_of(count, offset);
    let parts = footer(status, &accounts, now, inside, &page)?;
    let mut spans = vec![Span::new(parts.keys, Tone::Muted)];
    let mut gap = parts.gap;
    let paged = if page.is_empty() { 0 } else { 2 };
    if let Some((activity, tone)) = &parts.activity {
        spans.push(Span::plain(" ".repeat(gap - cells(activity) - paged)));
        spans.push(Span::new(activity, *tone));
        gap = paged;
    }
    if gap > 0 {
        spans.push(Span::plain(" ".repeat(gap)));
    }
    if !page.is_empty() {
        spans.push(Span::new(&page, Tone::Muted));
    }
    lines.push(edged(Line { spans, live: None }, border));
    lines.push(rule('╰', '╯'));
    Ok(Frame { lines, offset })
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::json::parse;

    /// A Saturday. The accounts are those of tests/fixtures/screenshots.ps1 after a collection
    /// 42 seconds earlier: two of each family, one Claude account resting.
    pub const NOON: &str = "2026-09-12T12:00:00.0000000+00:00";
    pub const POLICY: &str = r#"{"prefer":[1,2],"reserve":[2],"capacity":{"2":{"fiveHour":1.5,"weekly":5},"1":{"fiveHour":0.3,"weekly":1}},"codex":{"margin7d":20,"defaultMeter":"codex","margin5h":25,"margin7dWork":5,"capacity":{"work":{"fiveHour":1.5,"weekly":5},"personal":{"fiveHour":0.3,"weekly":1}},"slots":[{"id":"work","label":"Work"},{"id":"personal","label":"Personal"}]},"schemaVersion":2,"mode":"monitor","labels":{"2":"Reserve","1":"Everyday"}}"#;
    pub const STATUS: &str = r#"{"collector":{"status":"ok","completedAt":"2026-09-12T11:59:18.0000000+00:00","startedAt":"2026-09-12T11:59:15.0000000+00:00"},"providers":{"codex":{"capacity":{"work":{"fiveHour":1.5,"weekly":5},"personal":{"fiveHour":0.3,"weekly":1}},"slots":[{"label":"Work","status":"ok","observedAt":"2026-09-12T11:59:18.0000000+00:00","id":"work","buckets":{"codex":{"status":"observed","forecast":{"observedAt":"2026-09-12T11:59:18.0000000+00:00","expectedUsed":57.1,"used":41,"pace":"behind","secondsToLimit":497266,"lastsToReset":true,"recentSecondsToLimit":null,"basis":"cycle-average","confidence":"estimate"},"windows":{"10080":{"resetsAt":1789473600,"usedPercent":41,"anchorState":"observed-active","remainingPercent":59},"300":{"resetsAt":1789221600,"usedPercent":26,"anchorState":"observed-active","remainingPercent":74}}}}},{"label":"Personal","status":"ok","observedAt":"2026-09-12T11:59:18.0000000+00:00","id":"personal","buckets":{"codex":{"windows":{"10080":{"resetsAt":1789279200,"usedPercent":89,"anchorState":"observed-active","remainingPercent":11}},"status":"observed"}}}],"recommendedSlot":"work","defaultMeter":"codex"}},"generatedAt":"2026-09-12T11:59:18.0000000+00:00","hold":null,"active":1,"slots":[{"forecast":{"observedAt":"2026-09-12T11:59:18.0000000+00:00","expectedUsed":69,"used":54,"pace":"behind","secondsToLimit":355698,"lastsToReset":true,"recentSecondsToLimit":null,"basis":"cycle-average","confidence":"estimate"},"reset7d":"2026-09-14T16:00:00.0000000+00:00","reset5h":"2026-09-12T13:23:00.0000000+00:00","label":"Everyday","fresh":true,"used5h":38,"active":true,"observedAt":"2026-09-12T11:59:18.0000000+00:00","status":"ok","slot":1,"used7d":54},{"actionBlock":"outside_work_hours","label":"Reserve","used7d":17,"fresh":true,"used5h":0,"cold":true,"warmOutcome":{"outcome":"unconfirmed"},"reset5h":"","reset7d":"2026-09-17T12:00:00.0000000+00:00","slot":2,"status":"ok","observedAt":"2026-09-12T11:59:18.0000000+00:00","active":false}],"recentActions":[{"provider":"claude","kind":"warm_outcome","reason":"unconfirmed","slot":2}]}"#;

    fn noon() -> Dto {
        crate::display::packaged_data(&std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(".."));
        crate::time::set_zone(Some(0));
        set_core(false);
        Dto::parse(NOON).ok().unwrap()
    }

    /// One frame as output that is no terminal is given it.
    fn view(width: usize, height: usize) -> View {
        View { width, height, offset: 0, frozen: false, seconds: 0.0, nyan: false, motion: false, plain: true, colours: Colours::True }
    }

    /// As a terminal is given it, the cat flying.
    fn lit(seconds: f64, motion: bool) -> View {
        View { seconds, motion, nyan: true, plain: false, ..view(100, 40) }
    }

    fn drawn_under(policy: &str, view: &View) -> Frame {
        let now = noon();
        frame(&parse(STATUS, "").ok().unwrap(), &parse(policy, "").ok().unwrap(), now, view, &mut Tweens::default()).ok().unwrap()
    }

    fn drawn(view: &View) -> Frame {
        drawn_under(POLICY, view)
    }

    /// Each row between the frame's edges without the blanks that fill it, and a rule as its
    /// two ends.
    fn rows(frame: &Frame) -> Vec<String> {
        let inside = |line: &Line| {
            let text: Vec<char> = paint::text(&line.spans).chars().collect();
            let inner: String = text[1..text.len() - 1].iter().collect();
            match inner.chars().all(|cell| cell == '─') {
                true => [text[0], text[text.len() - 1]].iter().collect(),
                false => inner.trim_end().to_owned(),
            }
        };
        frame.lines.iter().map(inside).collect()
    }

    /// A row with words at both ends of it, in a frame that wide.
    fn across(width: usize, left: &str, right: &str) -> String {
        format!("{left}{}{right}", " ".repeat(width - 4 - cells(left) - cells(right)))
    }

    /// Which of the accounts' rows the thumb is beside.
    fn thumb(frame: &Frame) -> Vec<usize> {
        let texts: Vec<String> = frame.lines.iter().map(|line| paint::text(&line.spans)).collect();
        let first = texts.iter().enumerate().filter(|(_, text)| text.starts_with('├')).nth(1).unwrap().0 + 1;
        texts.iter().enumerate().filter(|(_, text)| text.ends_with('┃')).map(|(index, _)| index - first).collect()
    }

    #[test]
    fn a_frame_is_its_title_what_can_be_used_now_and_every_account() {
        let frame = drawn(&View { nyan: true, ..view(100, 40) });
        let expected = vec![
            "╭╮".to_owned(),
            across(100, "  hotpl8  ·  nyan   ○ auto-switch off", "read 42s ago"),
            r#"  ~~~~~~[::::] /\_/\"#.to_owned(),
            "  ~~~~~~[::::]( o.o )  hotpl8 / nyan".to_owned(),
            r#"         "  "  " ""#.to_owned(),
            "├┤".to_owned(),
            "  CLAUDE".to_owned(),
            "  [█████████████████████████████████████▍▒▒]  ~94% now  +6% in 1h 23m   7d 65%".to_owned(),
            across(100, "  CODEX", "next: Work"),
            "  [███████████████████▌▒▒▒▒▒▒··············]  ~49% now  +16% in 2h 00m   7d 35%".to_owned(),
            "├┤".to_owned(),
            "  CLAUDE  /  2 subscriptions".to_owned(),
            "  ● Everyday  [1]  ·  ACTIVE".to_owned(),
            "    5h  ████████████▍·······   62%   reset 1h 23m  ·  Sat 13:23".to_owned(),
            "    7d  █████████▏··········   46%   reset 2d 04h  ·  Mon 16:00".to_owned(),
            "    pace behind  ·  ~99h to limit  ·  lasts to reset".to_owned(),
            "".to_owned(),
            "  ○ Reserve  [2]  ·  RESERVE · resting".to_owned(),
            "    5h  ████████████████████  100%   idle".to_owned(),
            "    7d  ████████████████▌···   83%   reset 5d 00h  ·  Thu 12:00".to_owned(),
            "    warm unconfirmed  ·  warming off · outside work hours".to_owned(),
            "".to_owned(),
            "  CODEX  /  2 subscriptions".to_owned(),
            "  ● Work  [work]  ·  NEXT LAUNCH".to_owned(),
            "    5h  ██████████████▊·····   74%   reset 2h 00m  ·  Sat 14:00".to_owned(),
            "    7d  ███████████▊········   59%   reset 3d 00h  ·  Tue 12:00".to_owned(),
            "    pace behind  ·  ~138h to limit  ·  lasts to reset".to_owned(),
            "".to_owned(),
            "  ○ Personal  [personal]  ·  AVAILABLE".to_owned(),
            "    7d  ██▏·················   11%   reset 18h 00m  ·  Sun 06:00".to_owned(),
            "".to_owned(),
            "├┤".to_owned(),
            across(100, "  q quit  ·  space freeze  ·  ↑↓ scroll", "warm unconfirmed · Reserve"),
            "╰╯".to_owned(),
        ];
        assert_eq!(rows(&frame), expected);
        assert_eq!(frame.offset, 0);
        assert!(thumb(&frame).is_empty());
    }

    #[test]
    fn every_row_is_as_wide_as_the_frame() {
        for (width, height) in [(48, 17), (48, 24), (60, 18), (60, 34), (72, 32), (100, 40), (110, 50), (200, 60), (47, 40), (100, 16), (1, 1), (0, 0)] {
            for nyan in [false, true] {
                for (plain, motion) in [(true, false), (false, false), (false, true)] {
                    for colours in [Colours::True, Colours::Indexed] {
                        let frame = drawn(&View { nyan, plain, motion, colours, seconds: 0.4, offset: 2, ..view(width, height) });
                        let wide = width.clamp(1, 110);
                        assert!(frame.lines.len() <= height.max(1), "{width}x{height} is {} rows", frame.lines.len());
                        for line in &frame.lines {
                            assert_eq!(cells(&paint::text(&line.spans)), wide, "{width}x{height}: {}", paint::text(&line.spans));
                            if let Some(live) = &line.live {
                                assert_eq!(cells(&paint::text(&live.spans(1.3))), wide, "{width}x{height}: {}", paint::text(&live.spans(1.3)));
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn a_terminal_too_small_for_the_dashboard_is_told_so() {
        for (width, height) in [(47, 40), (100, 16)] {
            let frame = drawn(&view(width, height));
            let texts: Vec<String> = frame.lines.iter().map(|line| paint::text(&line.spans)).collect();
            assert_eq!(texts, [padded("hotpl8 (=^.^=)", width), padded("Make the terminal larger.", width), padded("Q quit / Esc back", width)]);
            assert!(frame.lines.iter().all(|line| line.live.is_none()));
        }
        let texts: Vec<String> = drawn(&view(10, 2)).lines.iter().map(|line| paint::text(&line.spans)).collect();
        assert_eq!(texts, ["hotpl8 (=^", "Make the t"]);
        let texts: Vec<String> = words(&["one\ttwo", "three"], 400, 0).lines.iter().map(|line| paint::text(&line.spans)).collect();
        assert_eq!(texts.len(), 1);
        assert_eq!(cells(&texts[0]), 110);
    }

    #[test]
    fn accounts_that_do_not_fit_are_scrolled_under_a_thumb() {
        let at = |offset: usize| drawn(&View { offset, ..view(60, 18) });
        let top = at(0);
        let shown = rows(&top);
        assert_eq!(shown[8], "  CLAUDE  /  2 subscriptions");
        assert_eq!(shown[16], across(60, "  q quit  ·  space freeze  ·  ↑↓ scroll", "[1-7/13]"));
        assert_eq!((top.offset, thumb(&top)), (0, vec![0, 1, 2]));

        let middle = at(3);
        let shown = rows(&middle);
        assert_eq!(shown[8], "    7d  █████▌······   46%   reset 2d 04h");
        assert_eq!(shown[14], "    5h  ████████▉···   74%   reset 2h 00m");
        assert_eq!(shown[16], across(60, "  q quit  ·  space freeze  ·  ↑↓ scroll", "[4-10/13]"));
        assert_eq!((middle.offset, thumb(&middle)), (3, vec![2, 3, 4]));

        // A position past the last row is brought back to it: that is how End is answered.
        for past in [7, 999, usize::MAX] {
            let end = at(past);
            let shown = rows(&end);
            assert_eq!(shown[8], "    7d  █████████▉··   83%   reset 5d 00h");
            assert_eq!(shown[14], "    7d  █▎··········   11%   reset 18h 00m");
            assert_eq!(shown[16], across(60, "  q quit  ·  space freeze  ·  ↑↓ scroll", "[7-13/13]"));
            assert_eq!((end.offset, thumb(&end)), (6, vec![4, 5, 6]));
        }
        // What is above the accounts does not scroll.
        assert_eq!(rows(&top)[..8], rows(&at(999))[..8]);
    }

    #[test]
    fn a_narrow_frame_says_less_in_its_title_and_beside_its_bars() {
        let shown = rows(&drawn(&view(48, 17)));
        assert_eq!(shown[1], across(48, "  (=^.^=)  hotpl8   ○ auto-switch off", "42s"));
        assert_eq!(shown[4], "  [██████████████▒]  ~94% now  +6% in 1h 23m");
        assert_eq!(shown[5], across(48, "  CODEX", "next: Work"));
        assert_eq!(shown[6], "  [██████▊▒▒·····]  ~49% now  +16% in 2h 00m");
        assert_eq!(shown[15], across(48, "  q quit  ·  ↑↓ scroll", "[1-6/13]"));
    }

    #[test]
    fn a_lone_event_is_listed_where_the_keys_leave_it_no_room() {
        let shown = rows(&drawn(&view(60, 34)));
        let at = shown.iter().position(|row| row == "  RECENT").unwrap();
        assert_eq!(shown[at + 1], "    warm unconfirmed · Reserve");
        assert_eq!(shown[shown.len() - 2], "  q quit  ·  space freeze  ·  ↑↓ scroll");
        // Beside the keys where there is room, as the first test has it.
        assert!(!rows(&drawn(&view(100, 40))).iter().any(|row| row == "  RECENT"));
    }

    #[test]
    fn rows_are_drawn_closer_together_before_an_account_is_scrolled_away() {
        let accounts = |shown: &[String]| ["● Everyday", "○ Reserve", "● Work", "○ Personal"].iter().all(|name| shown.iter().any(|row| row.trim_start().starts_with(name)));
        let pace = |shown: &[String]| shown.iter().filter(|row| row.trim_start().starts_with("pace behind")).count();
        let close = drawn(&view(72, 32));
        let shown = rows(&close);
        assert!(accounts(&shown));
        assert_eq!((pace(&shown), shown.len()), (0, 24));
        assert!(!shown[8..21].iter().any(|row| row.is_empty()));
        assert_eq!(shown[22], "  q quit  ·  space freeze  ·  ↑↓ scroll");
        // With the room for them, the forecasts and the blank rows between accounts are back.
        let roomy = rows(&drawn(&view(72, 44)));
        assert!(accounts(&roomy));
        assert_eq!(pace(&roomy), 2);
        assert!(roomy[8..roomy.len() - 3].iter().any(|row| row.is_empty()));
    }

    #[test]
    fn a_row_that_moves_is_drawn_again_as_a_new_frame_would_draw_it() {
        let (now, status, policy) = (noon(), parse(STATUS, "").ok().unwrap(), parse(POLICY, "").ok().unwrap());
        let mut tweens = Tweens::default();
        let first = frame(&status, &policy, now, &lit(0.2, true), &mut tweens).ok().unwrap();
        let later = frame(&status, &policy, now, &lit(0.7, true), &mut tweens).ok().unwrap();
        let (mut moving, mut looped, mut changed) = (0, 0, 0);
        for (before, after) in first.lines.iter().zip(&later.lines) {
            match &before.live {
                Some(row) => {
                    moving += 1;
                    looped += usize::from(row.moving(3600.0));
                    assert!(row.moving(0.2));
                    assert_eq!(row.spans(0.7), after.spans);
                    changed += usize::from(row.spans(0.2) != row.spans(0.7));
                }
                None => assert_eq!(before.spans, after.spans),
            }
        }
        // The cat's rows and both bars of what can be used never rest; the seven windows do.
        let cat = Scene::fitting(98, 40, 4, Colours::True).unwrap().rows();
        assert_eq!((moving, looped), (cat + 2 + 7, cat + 2));
        // Every bar is still filling, and the cat has flown on.
        assert!(changed > 9, "{changed} rows changed");

        // A row at rest is the row a dashboard without motion draws.
        let still = drawn(&lit(0.0, false));
        let mut rested = 0;
        for (line, at_rest) in first.lines.iter().zip(&still.lines) {
            if let Some(row) = line.live.as_ref().filter(|row| !row.moving(60.0)) {
                rested += 1;
                assert_eq!(row.spans(60.0), at_rest.spans);
            }
        }
        assert_eq!(rested, 7);
    }

    #[test]
    fn the_mascot_blinks_in_a_title_that_keeps_its_width() {
        let frame = drawn(&View { nyan: false, ..lit(0.0, true) });
        let title = frame.lines[1].live.as_ref().unwrap();
        let (open, shut) = (paint::text(&title.spans(1.0)), paint::text(&title.spans(10.7)));
        assert!(open.contains("(=^.^=)") && shut.contains("(=-.-=)"));
        assert_eq!(open.replace("(=^.^=)", "(=-.-=)"), shut);
        assert!(title.moving(3600.0));
        // The cat flies in its own rows, and the title says so instead.
        assert!(drawn(&lit(0.0, true)).lines[1].live.is_none());
    }

    #[test]
    fn nothing_moves_for_output_that_is_no_terminal_or_a_reader_who_asked_for_rest() {
        let at_rest = |frame: Frame| frame.lines.iter().all(|line| line.live.is_none());
        assert!(!at_rest(drawn(&lit(0.3, true))));
        assert!(at_rest(drawn(&lit(0.3, false))));
        assert!(at_rest(drawn(&View { plain: true, ..lit(0.3, true) })));
        let resting = POLICY.replacen('{', r#"{"display":{"reducedMotion":true},"#, 1);
        assert!(at_rest(drawn_under(&resting, &lit(0.3, true))));
        // And what is drawn at rest does not depend on when.
        let texts = |frame: Frame| -> Vec<Vec<Span>> { frame.lines.into_iter().map(|line| line.spans).collect() };
        assert!(texts(drawn(&lit(0.3, false))) == texts(drawn(&lit(7.9, false))));
    }

    #[test]
    fn a_state_that_cannot_be_read_draws_no_frame() {
        let now = noon();
        let policy = parse(POLICY, "").ok().unwrap();
        for unreadable in [r#""providers":5"#, r#""providers":{"codex":{"slots":[{"id":"work","buckets":[1]}]}}"#] {
            let status = parse(&format!(r#"{{"generatedAt":"2026-09-12T11:59:18.0000000+00:00","slots":[],{unreadable}}}"#), "").ok().unwrap();
            assert!(frame(&status, &policy, now, &view(100, 40), &mut Tweens::default()).is_err(), "{unreadable}");
        }
    }

    /// A Thursday, and a fleet read at that instant: three Claude accounts, the third in use
    /// and the first held in reserve, and one Codex account. Its policy was written before
    /// there were modes.
    pub const THURSDAY: &str = "2026-09-10T12:00:00.0000000+00:00";
    pub const FLEET_POLICY: &str = r#"{"labels":{"2":"work","1":"reserve","3":"work2"},"prefer":[1,2,3],"reserve":[1],"codex":{"defaultMeter":"codex","slots":[{"id":"main","label":"Main"}]}}"#;
    pub const FLEET: &str = r#"{"active":3,"generatedAt":"2026-09-10T12:00:00.0000000+00:00","providers":{"codex":{"slots":[{"label":"Main","status":"ok","observedAt":"2026-09-10T12:00:00.0000000+00:00","id":"main","buckets":{"codex_bengalfox":{"windows":{"300":{"resetsAt":1789059600,"usedPercent":0,"anchorState":"unconfirmed","remainingPercent":100}},"status":"constraint_unknown"},"codex":{"windows":{"10080":{"resetsAt":1789300800,"usedPercent":35,"anchorState":"observed-active","remainingPercent":65}},"status":"observed"}}}],"recommendedSlot":"main","defaultMeter":"codex"}},"slots":[{"reset7d":"2026-09-12T12:00:00.0000000+00:00","label":"Claude 1","fresh":true,"used5h":25,"active":false,"reset5h":"2026-09-10T14:00:00.0000000+00:00","status":"ok","slot":1,"used7d":50},{"reset7d":"2026-09-12T12:00:00.0000000+00:00","label":"Claude 2","fresh":true,"used5h":25,"active":false,"reset5h":"2026-09-10T14:00:00.0000000+00:00","status":"ok","slot":2,"used7d":50},{"reset7d":"2026-09-12T12:00:00.0000000+00:00","label":"Claude 3","fresh":true,"used5h":25,"active":true,"reset5h":"2026-09-10T14:00:00.0000000+00:00","status":"ok","slot":3,"used7d":50}]}"#;

    fn thursday() -> Dto {
        noon();
        Dto::parse(THURSDAY).ok().unwrap()
    }

    /// That Thursday at another time of day.
    fn clock(time: &str) -> String {
        format!("2026-09-10T{time}.0000000+00:00")
    }

    /// `text` with the one `old` in it said as `new`.
    fn with(text: &str, old: &str, new: &str) -> String {
        assert_eq!(text.matches(old).count(), 1, "{old}");
        text.replacen(old, new, 1)
    }

    /// `text` with `old` said as `new` in each of the three Claude accounts.
    fn with_each(text: &str, old: &str, new: &str) -> String {
        assert_eq!(text.matches(old).count(), 3, "{old}");
        text.replace(old, new)
    }

    /// A status with what `old` says of Claude account `slot` said as `new`.
    fn of_account(status: &str, slot: usize, old: &str, new: &str) -> String {
        const OPENS: &str = r#"{"reset7d""#;
        let mut parts: Vec<String> = status.split(OPENS).map(str::to_owned).collect();
        assert_eq!(parts.len(), 4);
        parts[slot] = with(&parts[slot], old, new);
        parts.join(OPENS)
    }

    /// An object with more members.
    fn and(object: &str, members: &str) -> String {
        format!("{},{members}}}", object.strip_suffix('}').unwrap())
    }

    /// The fleet with another outcome and time for the Codex account's own reading.
    fn main_read(outcome: &str, observed: &str) -> String {
        let read = r#""label":"Main","status":"ok","observedAt":"2026-09-10T12:00:00.0000000+00:00""#;
        with(FLEET, read, &format!(r#""label":"Main","status":"{outcome}","observedAt":"{}""#, clock(observed)))
    }

    /// The fleet read at another time of day.
    fn generated(time: &str) -> String {
        with(FLEET, r#""generatedAt":"2026-09-10T12:00:00.0000000+00:00""#, &format!(r#""generatedAt":"{}""#, clock(time)))
    }

    /// The fleet's policy with switching between accounts allowed, and with it left alone.
    fn automated() -> String {
        and(FLEET_POLICY, r#""mode":"automate","switchEnabled":true"#)
    }

    fn monitored() -> String {
        and(FLEET_POLICY, r#""mode":"monitor""#)
    }

    /// A status with what the collector did on its last run.
    fn acted(status: &str, switching: bool, warming: bool) -> String {
        and(status, &format!(r#""actions":{{"switching":{switching},"warming":{warming},"probing":false}}"#))
    }

    /// The fleet with every optional line on its Claude accounts and a second Codex account,
    /// the one to launch next: the first has nothing left. With the policy that names both.
    pub fn crowded() -> (String, String) {
        const LEFT: &str = r#""usedPercent":35,"anchorState":"observed-active","remainingPercent":65"#;
        let main = FLEET.split_once(r#"{"codex":{"slots":["#).unwrap().1.split_once(r#"],"recommendedSlot""#).unwrap().0;
        let work = with(&with(&with(main, r#""label":"Main""#, r#""label":"Work""#), r#""id":"main""#, r#""id":"work""#), LEFT, r#""usedPercent":22,"anchorState":"observed-active","remainingPercent":78"#);
        let spent = with(&with(main, LEFT, r#""usedPercent":100,"anchorState":"observed-active","remainingPercent":0"#), r#""status":"observed""#, r#""status":"blocked""#);
        let status = with(&with(FLEET, main, &format!("{spent},{work}")), r#""recommendedSlot":"main""#, r#""recommendedSlot":"work""#);
        let status = with_each(&status, r#""status":"ok","slot""#, r#""warmOutcome":{"outcome":"observed-active"},"actionBlock":"outside_work_hours","modelBlock":"model_below_margin","status":"ok","slot""#);
        (status, with(FLEET_POLICY, r#"{"id":"main","label":"Main"}"#, r#"{"id":"main","label":"Main"},{"id":"work","label":"Work"}"#))
    }

    /// A terminal that wide and tall, as it is first drawn.
    pub fn terminal(width: usize, height: usize) -> View {
        View { plain: false, motion: true, ..view(width, height) }
    }

    /// The frame of a state as it was that Thursday. No status is a state never collected.
    pub fn fleet_drawn(status: &str, policy: &str, view: &View) -> Frame {
        let now = thursday();
        let status = if status.is_empty() { V::Null } else { parse(status, "").ok().unwrap() };
        frame(&status, &parse(policy, "").ok().unwrap(), now, view, &mut Tweens::default()).ok().unwrap()
    }

    /// Every row of a frame as it is shown, one to a line.
    pub fn page(frame: &Frame) -> String {
        frame.lines.iter().map(|line| paint::text(&line.spans)).collect::<Vec<_>>().join("\n")
    }

    /// The fleet's frame with room for every row.
    fn fleet(status: &str) -> String {
        page(&fleet_drawn(status, FLEET_POLICY, &terminal(100, 100)))
    }

    /// The title of a frame.
    fn title_of(status: &str, policy: &str, view: &View) -> String {
        paint::text(&fleet_drawn(status, policy, view).lines[1].spans)
    }

    /// Whether a row gives that window that much left: its name, its bar, the percentage.
    pub fn leaves(page: &str, window: &str, percent: &str) -> bool {
        page.lines().any(|line| line.split_whitespace().collect::<Vec<_>>().windows(3).any(|said| said[0] == window && said[2] == percent))
    }

    /// Whether a title says a word or phrase as one of its own, not as part of another.
    fn says(title: &str, phrase: &str) -> bool {
        let apart = |beside: Option<char>| beside.is_none_or(|c| c.is_whitespace() || c == '·');
        title.match_indices(phrase).any(|(at, found)| apart(title[..at].chars().next_back()) && apart(title[at + found.len()..].chars().next()))
    }

    /// The rows of a frame the cat flies in.
    fn cat_rows(frame: &Frame) -> Vec<String> {
        let flies = |line: &&Line| matches!(line.live.as_ref().map(|live| &live.paint), Some(Paint::Nyan { .. }));
        frame.lines.iter().filter(flies).map(|line| paint::text(&line.spans)).collect()
    }

    #[test]
    fn a_policy_with_no_account_is_shown_how_to_connect_the_first() {
        let first = fleet_drawn("", r#"{"mode":"monitor","prefer":[],"codex":{"slots":[]}}"#, &terminal(80, 24));
        let shown = rows(&first);
        // No collector is implied to be running, and with no account there is nothing to
        // switch between: the title stays quiet.
        assert_eq!(shown[1], across(80, "  (=^.^=)  hotpl8", "no reading"));
        assert_eq!(
            shown[8..13],
            [
                "  No accounts yet.",
                "  Connect your first account: hotpl8 setup",
                "  Or ask your agent to add a Claude or Codex account.",
                "  Complete provider sign-in only when needed.",
                "  HotPl8 connects the account and reads usage for you."
            ]
        );
        let text = page(&first);
        for unsaid in ["AccountHome", "hotpl8 refresh", "LIVE", "every 5m", "auto-switch"] {
            assert!(!text.contains(unsaid), "{unsaid}");
        }
    }

    #[test]
    fn a_reading_gone_stale_and_an_account_signed_out_each_say_what_to_do() {
        let text = fleet(&of_account(&generated("11:00:00"), 1, r#""status":"ok""#, r#""status":"authentication_required""#));
        assert!(text.contains("hotpl8 refresh") && text.contains("SIGN-IN NEEDED") && !text.contains("account unavailable"), "{text}");
    }

    #[test]
    fn one_busy_or_slow_codex_read_retries_quietly_until_its_last_success_ages_out() {
        for (failure, named) in [("home_busy", "HOME BUSY"), ("timeout", "TIMEOUT")] {
            let text = fleet(&main_read(failure, "11:55:00"));
            assert!(text.contains("READ RETRYING") && !text.contains("account unavailable"), "{text}");
            let text = fleet(&main_read(failure, "11:00:00"));
            assert!(!text.contains("READ RETRYING") && text.contains(named) && !text.contains("account unavailable"), "{text}");
        }
        let text = fleet(&main_read("transport_failed", "12:00:00"));
        assert!(text.contains("TRANSPORT FAILED") && !text.contains("account unavailable"), "{text}");
        assert_eq!(badge_tone("READ RETRYING").ok().unwrap(), Tone::Amber);
    }

    #[test]
    fn the_trouble_of_one_account_is_on_its_own_row_and_never_a_general_line() {
        assert!(!fleet(FLEET).contains("account unavailable"));
        let text = fleet(&main_read("authentication_required", "12:00:00"));
        assert!(text.contains("AUTHENTICATION REQUIRED") && !text.contains("account unavailable") && !text.contains("provider checks incomplete"), "{text}");
        // What can be used now says nothing of it either.
        let summary = text.lines().skip(3).take(4).collect::<Vec<_>>().join("\n");
        for word in ["SIGN-IN", "read", "plan unknown", "UNAVAILABLE", "PICK MANUALLY", "NO LAUNCH", "monitor"] {
            assert!(!summary.contains(word), "{word}: {summary}");
        }
    }

    #[test]
    fn every_account_is_shown_and_a_meter_that_is_not_the_chosen_one_is_not() {
        let text = fleet(FLEET);
        for said in ["3 subscriptions", "1 subscription", "Claude 1", "Claude 2", "Claude 3", "NEXT LAUNCH", "ACTIVE", "Main  [main]"] {
            assert!(text.contains(said), "{said}: {text}");
        }
        assert!(leaves(&text, "5h", "75%") && leaves(&text, "7d", "65%"), "{text}");
        assert!(!text.contains("    Main") && !text.contains("Spark"), "{text}");
    }

    #[test]
    fn accounts_never_read_are_listed_without_a_balance() {
        let text = fleet("");
        for said in ["reserve", "Main", "NO OBSERVATION"] {
            assert!(text.contains(said), "{said}: {text}");
        }
        assert!(!text.contains(" 100%"), "{text}");
    }

    #[test]
    fn a_codex_account_read_long_ago_or_used_up_is_not_the_next_launch() {
        let text = fleet(&main_read("ok", "11:00:00"));
        assert!(text.contains("STALE") && !text.contains("NEXT LAUNCH"), "{text}");
        let spent = with(FLEET, r#""anchorState":"observed-active","remainingPercent":65"#, r#""anchorState":"observed-active","remainingPercent":0"#);
        assert!(!fleet(&spent).contains("NEXT LAUNCH"));
    }

    #[test]
    fn a_reset_that_has_passed_is_due_and_one_not_confirmed_is_no_countdown() {
        let now = thursday();
        let said = |reset: V, unix: bool, wide: bool, unconfirmed: bool| reset_text(&reset, now, unix, wide, unconfirmed).ok().unwrap();
        assert_eq!(said(V::from(clock("11:59:59")), false, false, false), "reset due");
        // An hour on, as seconds since 1970.
        let hour = || V::from(1_789_045_200_i64);
        assert_eq!(said(hour(), true, false, true), "reset unconfirmed");
        assert_eq!(said(hour(), true, false, false), "reset 1h 00m");
        assert_eq!(said(hour(), true, true, false), "reset 1h 00m  ·  Thu 13:00");
        for unknown in [V::Null, V::from("")] {
            assert_eq!(said(unknown, false, true, false), "reset ?");
        }
        // A reset HotPl8 never writes is not guessed at: no frame is drawn.
        assert!(reset_text(&V::from("soon"), now, false, true, false).is_err());
        assert_eq!([0.0, 59.9, 3599.0, 3600.0, 187200.0, -5.0].map(span_text), ["0s", "59s", "59m", "1h 00m", "2d 04h", "0s"]);
    }

    #[test]
    fn a_reset_that_elapsed_after_the_reading_refills_the_bar() {
        // Every account's plan is known and its five hour reset has passed. What differs is
        // whether the reset had already passed when the reading arrived.
        let elapsed = |observed: &str, reset: &str| {
            let known = format!(r#""reset5h":"{}","plan":{{"status":"detected","profile":"claude-pro","observedAt":"{THURSDAY}"}},"observedAt":"{}","status":"ok""#, clock(reset), clock(observed));
            with_each(FLEET, r#""reset5h":"2026-09-10T14:00:00.0000000+00:00","status":"ok""#, &known)
        };
        let rolled = elapsed("11:55:00", "11:59:59");
        let text = fleet(&rolled);
        assert!(leaves(&text, "5h", "100%"), "{text}");
        assert!(text.contains("reset · awaiting read") && !text.contains("reset due"), "{text}");
        // The fleet stays measured: its total is a percentage, not the dotted unknown.
        assert!(!text.contains("? now"), "{text}");
        let narrow = page(&fleet_drawn(&rolled, FLEET_POLICY, &terminal(79, 100)));
        assert!(narrow.contains("awaiting read") && !narrow.contains("reset · awaiting read"), "{narrow}");

        let text = fleet(&elapsed("11:59:40", "11:59:30"));
        assert!(leaves(&text, "5h", "75%") && text.contains("reset due") && !text.contains("? now"), "{text}");
        // Nothing can be told of now: the Claude total stays empty rather than invented.
        let lines: Vec<&str> = text.lines().collect();
        let at = lines.iter().position(|line| line.starts_with("│  CLAUDE ")).unwrap();
        assert!(!lines[at + 1].contains("% now"), "{}", lines[at + 1]);

        // A reading that never arrived is not refilled by a reset that passed.
        let text = fleet(&with_each(&rolled, r#""used5h":25"#, r#""used5h":null"#));
        assert!(text.contains("no reading") && !leaves(&text, "5h", "100%"), "{text}");
    }

    #[test]
    fn the_title_states_auto_switch_as_the_collector_last_applied_it() {
        let (on, wide) = (automated(), terminal(100, 40));
        let title = title_of(&acted(FLEET, true, false), &on, &wide);
        assert!(title.contains("● auto-switch on") && !title.contains("warming"), "{title}");
        // A run that only observed reports switching off, though the policy allows it.
        let title = title_of(&acted(FLEET, false, false), &on, &wide);
        assert!(title.contains("○ auto-switch off"), "{title}");
        let title = title_of(&and(FLEET, r#""mode":"monitor""#), &on, &wide);
        assert!(title.contains("auto-switch off"), "{title}");
        let title = title_of(&and(FLEET, r#""mode":"automate""#), &monitored(), &wide);
        assert!(title.contains("auto-switch off"), "{title}");
        let paused = and(&acted(FLEET, false, false), &format!(r#""automationPause":{{"until":"{}"}}"#, clock("12:42:00")));
        let title = title_of(&paused, &on, &wide);
        assert!(title.contains("◐ auto-switch paused 42m"), "{title}");
        let held = and(&acted(FLEET, true, true), &format!(r#""hold":{{"until":"{}"}}"#, clock("14:00:00")));
        let title = title_of(&held, &on, &wide);
        assert!(title.contains("◐ auto-switch held 2h 00m") && title.contains("● warming on"), "{title}");
    }

    #[test]
    fn the_auto_switch_state_is_kept_at_every_width() {
        for width in [48, 60, 79, 100] {
            let title = title_of(FLEET, FLEET_POLICY, &terminal(width, 40));
            // A policy from before there were modes keeps the switching it had.
            assert!(title.contains("● auto-switch on") && cells(&title) == width, "{width}: {title}");
        }
    }

    #[test]
    fn a_narrow_title_gives_way_in_whole_words_and_keeps_the_state_and_any_warning() {
        let (on, monitor, stale) = (automated(), monitored(), generated("10:55:00"));
        let paused_stale = and(&acted(&stale, false, false), &format!(r#""automationPause":{{"until":"{}"}}"#, clock("15:00:00")));
        let held = and(&acted(FLEET, true, false), &format!(r#""hold":{{"until":"{}"}}"#, clock("14:00:00")));
        let preview_stale = and(&stale, r#""displayPolicy":true"#);
        // A state and its policy, whether it is frozen, a word of each side that every width
        // keeps, and what a wide title says in full.
        let cases: [(&str, &str, &str, bool, [&str; 2], [&str; 2]); 9] = [
            ("off, stale", stale.as_str(), monitor.as_str(), false, ["off", "stale"], ["○ auto-switch off", "stale 1h 05m"]),
            ("accounts, never read", "", on.as_str(), false, ["on", "no reading"], ["● auto-switch on", "no reading"]),
            ("frozen", FLEET, on.as_str(), true, ["on", "FROZEN"], ["● auto-switch on", "FROZEN · read 0s ago"]),
            ("paused, stale", paused_stale.as_str(), on.as_str(), false, ["paused", "stale"], ["◐ auto-switch paused 3h 00m", "stale 1h 05m"]),
            ("held", held.as_str(), on.as_str(), false, ["held", "0s"], ["◐ auto-switch held 2h 00m", "read 0s ago"]),
            // Two things to say on the right: the warning about the reading outlasts FROZEN.
            ("frozen, stale", stale.as_str(), monitor.as_str(), true, ["off", "stale"], ["○ auto-switch off", "FROZEN · stale 1h 05m"]),
            ("frozen, paused, stale", paused_stale.as_str(), on.as_str(), true, ["paused", "stale"], ["◐ auto-switch paused 3h 00m", "FROZEN · stale 1h 05m"]),
            ("frozen, never read", "", on.as_str(), true, ["on", "no reading|no data"], ["● auto-switch on", "FROZEN · no reading"]),
            ("preview, stale", preview_stale.as_str(), monitor.as_str(), false, ["off", "stale"], ["○ auto-switch off", "PREVIEW POLICY · stale 1h 05m"]),
        ];
        for (name, status, policy, frozen, words, full) in cases {
            for width in [48, 50, 52, 56, 60, 79, 100] {
                let title = title_of(status, policy, &View { frozen, motion: false, ..terminal(width, 40) });
                let label = format!("{name} at {width}: {title}");
                // Two cells before the edge: nothing was cut to fit.
                assert!(cells(&title) == width && title.ends_with("  │"), "{label}");
                assert!(title.split_whitespace().any(|word| word == "auto" || word == "auto-switch"), "{label}");
                for word in words {
                    assert!(word.split('|').any(|either| says(&title, either)), "{label} lacks {word}");
                }
                for phrase in full.iter().filter(|_| width == 100) {
                    assert!(title.contains(phrase), "{label} lacks {phrase}");
                }
            }
        }
    }

    #[test]
    fn the_next_codex_launch_is_named_and_a_lone_event_is_not_said_twice() {
        let event = format!(r#"{{"provider":"codex","slot":"main","kind":"recommendation","reason":"next_launch_only","at":"{}"}}"#, clock("11:55:00"));
        let one = and(FLEET, &format!(r#""recentActions":[{event}]"#));
        let text = fleet(&one);
        assert!(text.contains("next: Main") && !text.contains("RECENT"), "{text}");
        // Too narrow for the row of keys to carry it: the one event stays listed.
        let narrow = page(&fleet_drawn(&one, FLEET_POLICY, &terminal(48, 100)));
        assert!(narrow.contains("RECENT") && narrow.contains("codex next"), "{narrow}");
        assert!(fleet(&and(FLEET, &format!(r#""recentActions":[{event},{event}]"#))).contains("RECENT"));
    }

    #[test]
    fn a_sign_in_that_was_not_renewed_is_listed_as_a_warning() {
        let event = |kind: &str, reason: &str| format!(r#"{{"provider":"codex","slot":"main","kind":"{kind}","reason":"{reason}","at":"{}"}}"#, clock("11:59:00"));
        let status = and(FLEET, &format!(r#""recentActions":[{},{}]"#, event("warm_attempt", "sent"), event("credential_unrenewed", "warm")));
        let drawn = fleet_drawn(&status, FLEET_POLICY, &terminal(100, 100));
        let tone_of = |phrase: &str| drawn.lines.iter().flat_map(|line| &line.spans).find(|span| span.text.contains(phrase)).map(|span| span.tone);
        assert_eq!(tone_of("sign-in not renewed · Main"), Some(Tone::Amber), "{}", page(&drawn));
        assert_eq!(tone_of("warm sent · Main"), Some(Tone::Muted));
    }

    #[test]
    fn a_changed_bar_glides_to_its_new_value_under_a_number_that_is_already_exact() {
        let (now, policy) = (thursday(), parse(FLEET_POLICY, "").ok().unwrap());
        let mut tweens = Tweens::default();
        let mut window = |status: &str, seconds: f64| {
            let drawn = frame(&parse(status, "").ok().unwrap(), &policy, now, &View { seconds, ..terminal(100, 100) }, &mut tweens).ok().unwrap();
            drawn.lines.into_iter().find(|line| paint::text(&line.spans).contains("5h ")).unwrap()
        };
        window(FLEET, 10.0);
        let used = of_account(FLEET, 1, r#""used5h":25"#, r#""used5h":75"#);
        let row = window(&used, 10.0);
        // A quarter is left, drawn part of the way down from the three quarters on screen.
        let text = paint::text(&row.spans);
        assert!(leaves(&text, "5h", "25%"), "{text}");
        let live = row.live.as_ref().unwrap();
        assert!(live.until > 10.0 && live.moving(10.2) && !live.moving(10.6));
        let later = paint::text(&window(&used, 10.6).spans);
        assert!(leaves(&later, "5h", "25%"), "{later}");
        let bar = |text: &str| text.split_whitespace().nth(2).unwrap().to_owned();
        assert_ne!(bar(&text), bar(&later));
        // Between the two layouts the row is drawn as the second one has it.
        assert_eq!(paint::text(&live.spans(10.6)), later);
    }

    #[test]
    fn a_narrow_frame_and_a_last_page_fit_the_terminal() {
        for width in [50, 79, 100, 110] {
            for offset in [0, 999] {
                let drawn = fleet_drawn(FLEET, FLEET_POLICY, &View { offset, ..terminal(width, 18) });
                assert!(drawn.lines.len() <= 18, "{width} from {offset}");
                for line in &drawn.lines {
                    assert_eq!(cells(&paint::text(&line.spans)), width);
                }
            }
        }
        assert!(leaves(&page(&fleet_drawn(FLEET, FLEET_POLICY, &View { offset: 999, ..terminal(79, 18) })), "7d", "65%"));
    }

    #[test]
    fn a_standard_terminal_shows_what_can_be_used_now_above_the_accounts() {
        let drawn = fleet_drawn(FLEET, FLEET_POLICY, &terminal(79, 23));
        let text = page(&drawn);
        assert!(drawn.lines.len() <= 23 && text.contains("% now"), "{text}");
        let (claude, codex, accounts) = (text.find("│  CLAUDE ").unwrap(), text.find("│  CODEX ").unwrap(), text.find("CLAUDE  /").unwrap());
        assert!(claude < codex && codex < accounts, "{text}");
    }

    #[test]
    fn a_label_cannot_drive_the_terminal_and_a_wide_one_keeps_the_edges_aligned() {
        let named = of_account(FLEET, 1, r#""label":"Claude 1""#, r#""label":"\u001b[2J\r\n中文 cafe""#);
        let drawn = fleet_drawn(&named, FLEET_POLICY, &terminal(50, 100));
        for line in &drawn.lines {
            let text = paint::text(&line.spans);
            assert_eq!(cells(&text), 50, "{text}");
            assert!(!text.chars().any(char::is_control), "{text:?}");
        }
        assert!(page(&drawn).contains("[2J  中文 cafe  [1]"), "{}", page(&drawn));
    }

    #[test]
    fn a_codex_login_switched_off_shows_no_balance_from_before() {
        let text = fleet(&main_read("disabled", "12:00:00"));
        assert!(text.contains("Main  [main]  ·  DISABLED"), "{text}");
        assert!(!leaves(&text, "7d", "65%") && !text.contains("NEXT LAUNCH"), "{text}");
    }

    #[test]
    fn accounts_with_every_optional_line_cannot_hide_the_codex_account_to_launch_next() {
        let (status, policy) = crowded();
        for width in [79, 110] {
            let drawn = fleet_drawn(&status, &policy, &terminal(width, 40));
            let text = page(&drawn);
            for said in ["Main  [main]", "EXHAUSTED", "Work  [work]", "NEXT LAUNCH"] {
                assert!(text.contains(said), "{width} lacks {said}: {text}");
            }
            assert!(leaves(&text, "7d", "78%") && drawn.lines.len() <= 40, "{text}");
            for line in &drawn.lines {
                assert_eq!(cells(&paint::text(&line.spans)), width);
            }
        }
        let last = page(&fleet_drawn(&status, &policy, &View { offset: 999, ..terminal(79, 24) }));
        assert!(last.contains("Work  [work]") && leaves(&last, "7d", "78%"), "{last}");
        // Where every row fits there is nowhere to scroll to.
        assert_eq!(fleet_drawn(&status, &policy, &View { offset: 10, ..terminal(110, 40) }).offset, 0);
    }

    #[test]
    fn an_account_last_read_long_ago_is_stale_though_the_collector_just_ran() {
        let text = fleet(&of_account(FLEET, 1, r#""status":"ok""#, &format!(r#""observedAt":"{}","status":"ok""#, clock("11:00:00"))));
        assert!(text.contains("Claude 1  [1]  ·  STALE"), "{text}");
    }

    #[test]
    fn the_cat_is_as_large_as_leaves_the_accounts_their_room() {
        let sizes = |colours: Colours| {
            [(48, 24), (79, 28), (94, 35), (110, 40), (79, 17)].map(|(width, height)| {
                let drawn = fleet_drawn(FLEET, FLEET_POLICY, &View { nyan: true, colours, ..terminal(width, height) });
                assert!(drawn.lines.len() <= height, "{width}x{height}");
                for line in &drawn.lines {
                    assert_eq!(cells(&paint::text(&line.spans)), width);
                }
                let flown = cat_rows(&drawn);
                // Whole cells are whole cells: no half blocks where a terminal draws them with gaps.
                assert!(colours == Colours::True || !flown.iter().any(|row| row.contains(['▀', '▄', '█'])), "{width}x{height}");
                flown.len()
            })
        };
        assert_eq!(sizes(Colours::True), [5, 5, 5, 9, 0]);
        assert_eq!(sizes(Colours::Indexed), [0, 10, 10, 18, 0]);
    }

    #[test]
    fn the_cat_between_two_layouts_is_the_cat_the_next_layout_draws() {
        let (now, status, policy) = (noon(), parse(STATUS, "").ok().unwrap(), parse(POLICY, "").ok().unwrap());
        for colours in [Colours::True, Colours::Indexed] {
            // Both drawings, through every frame of the cat and on into its second lap.
            for (width, height) in [(110, 40), (81, 30)] {
                let laid = |seconds: f64| frame(&status, &policy, now, &View { colours, width, height, ..lit(seconds, true) }, &mut Tweens::default()).ok().unwrap();
                let first = laid(0.001);
                assert!(!cat_rows(&first).is_empty(), "{width}x{height}");
                for tick in 1..=13 {
                    let seconds = f64::from(tick) / 12.0 + 0.001;
                    let next = laid(seconds);
                    for (before, after) in first.lines.iter().zip(&next.lines) {
                        if let Some(live) = before.live.as_ref().filter(|live| matches!(live.paint, Paint::Nyan { .. })) {
                            assert!(live.spans(seconds) == after.spans, "{width}x{height} at {seconds}");
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn a_terminal_is_sent_only_the_colours_it_can_show() {
        let sent = |colours: Colours| {
            let mut out = String::new();
            for line in &fleet_drawn(FLEET, FLEET_POLICY, &View { nyan: true, colours, ..terminal(113, 33) }).lines {
                paint::ansi(&line.spans, colours, &mut out);
            }
            out
        };
        // Every colour is one of the fixed ones by its number, and none of the first sixteen,
        // which a theme may repaint.
        let fixed = sent(Colours::Indexed);
        assert!(fixed.contains("\x1b[48;5;234m"));
        let mut colours = 0;
        for code in fixed.split("\x1b[").skip(1).map(|rest| &rest[..=rest.find(['m', 'K']).unwrap()]) {
            if code == "K" {
                continue;
            }
            let number = code.strip_prefix("38;5;").or_else(|| code.strip_prefix("48;5;")).and_then(|number| number.strip_suffix('m')).and_then(|number| number.parse::<u16>().ok());
            assert!(number.is_some_and(|number| (16..=255).contains(&number)), "{code}");
            colours += 1;
        }
        assert!(colours > 100, "{colours} colours");
        let full = sent(Colours::True);
        assert!(full.contains("\x1b[38;2;220;225;238m") && full.contains("\x1b[48;2;18;23;35m"));
        assert!(!full.contains("\x1b[38;5;") && !full.contains("\x1b[48;5;"));
    }
}

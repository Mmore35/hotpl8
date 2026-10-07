//! `hotpl8 tray`: what the tray shows and what it may announce, worked out in one start.
//! The window, its menu and which announcements were already made stay with src/tray.ps1.

use crate::automation::work_time;
use crate::capacity::fresh_timestamp;
use crate::codex::codex_eligibility;
use crate::insights::{format_explanation, format_forecast, health, name_text};
use crate::overview::{format_overview, provider_overview, upper};
use crate::ps::*;
use crate::registry::{configured_providers, provider_view};
use crate::time::Dto;
use crate::{cat, obj};

/// The lines of an explanation the tray leaves out: the overview above them says the same.
const LEFT_OUT: [&str; 8] = ["CLAUDE:", "CODEX:", "  Includes reserve", "Weekly headroom", "  Capacity:", "  Profiles:", "  Membership:", "  Next reset:"];

/// `$line -match '(?i)^' + $start`, for a start of printable ASCII. The four characters
/// outside ASCII that some runtime reads as a letter's other case are not read.
fn starts(line: &str, start: &str) -> R<bool> {
    let mut rest = line.chars();
    for wanted in start.chars() {
        match rest.next() {
            Some(found) if found.eq_ignore_ascii_case(&wanted) => {}
            Some('\u{130}' | '\u{131}' | '\u{17f}' | '\u{212a}') if wanted.is_ascii_alphabetic() => return unreadable(),
            _ => return Ok(false),
        }
    }
    Ok(true)
}

/// `$text -replace ('(?i)^' + [regex]::Escape($family) + $after), ($name + $after)`
fn renamed(text: &str, family: &str, after: &str, name: &str) -> R<String> {
    if name.contains('$') || !printable(family) {
        return unreadable();
    }
    let start = cat!(family, after);
    if !starts(text, &start)? {
        return Ok(text.to_string());
    }
    Ok(cat!(name, after, &text[start.len()..]))
}

/// Test-Hotpl8CodexReadRetrying: one busy or slow read is not an outage.
fn read_retrying(slot: &V, now: Dto) -> R<bool> {
    Ok(slot.g("status")?.in_s(&["home_busy", "timeout"])? && fresh_timestamp(&slot.g("observedAt")?, now)?)
}

/// Get-Hotpl8CodexAccountState
pub fn codex_account_state(slot: &V, part: &V, provider: &V, now: Dto) -> R<String> {
    if !slot.t()? {
        return Ok("NO OBSERVATION".to_string());
    }
    let status = slot.g("status")?;
    if slot.g("id")?.is_in(&part.g("disabled")?)? || status.eq_s("disabled")? {
        return Ok("DISABLED".to_string());
    }
    if read_retrying(slot, now)? {
        return Ok("READ RETRYING".to_string());
    }
    if status.ne_s("ok")? {
        return upper(&status.s()?.replace('_', " "));
    }
    if !fresh_timestamp(&slot.g("observedAt")?, now)? {
        return Ok("STALE".to_string());
    }
    for (_, window) in slot.path(&["buckets", "codex", "windows"])?.props()? {
        let remaining = window.g("remainingPercent")?;
        if remaining.is_number() && remaining.eq_i(0)? {
            return Ok("EXHAUSTED".to_string());
        }
    }
    let eligibility = codex_eligibility(slot, part, "codex", now, provider.path(&["critical", "codex", "active"])?.t()?)?;
    if eligibility.eq_s("eligible")? {
        let recommended = provider.path(&["recommendations", "codex"])?;
        let next = if recommended.t()? {
            recommended
        } else if provider.g("defaultMeter")?.eq_s("codex")? {
            provider.g("recommendedSlot")?
        } else {
            V::Null
        };
        return Ok(if slot.g("id")?.eq(&next)? { "NEXT LAUNCH" } else { "AVAILABLE" }.to_string());
    }
    Ok(if eligibility.eq_s("below_margin")? {
        "LOW BALANCE"
    } else if eligibility.eq_s("blocked")? {
        "BLOCKED"
    } else {
        "LIMIT UNCONFIRMED"
    }
    .to_string())
}

/// `[string]$used + '%'`, or `unknown` without a reading.
fn used_text(used: &V) -> R<String> {
    if used.is_null() {
        return Ok("unknown".to_string());
    }
    Ok(cat!(used.s()?, "%"))
}

/// Each account of one provider's view, as its family names it.
fn account_lines(snapshot: &V, policy: &V, now: Dto) -> R<Vec<String>> {
    let mut lines = Vec::new();
    for s in snapshot.g("slots")?.arr() {
        if !s.t()? {
            continue;
        }
        let fresh = s.g("fresh")?.t()? && fresh_timestamp(&s.g("observedAt")?, now)?;
        lines.push(cat!("Claude ", s.g("label")?, ": ", s.g("status")?, if fresh { "" } else { " / stale" }));
        lines.push(cat!("  5h used: ", used_text(&s.g("used5h")?)?, "; weekly used: ", used_text(&s.g("used7d")?)?));
        if fresh && s.g("forecast")?.t()? {
            lines.push(cat!("  ", format_forecast(&s.g("forecast")?)?));
        }
        if s.g("warmOutcome")?.t()? {
            lines.push(cat!("  warm: ", s.path(&["warmOutcome", "outcome"])?));
        }
        if s.g("actionBlock")?.t()? {
            lines.push(cat!("  warming: ", s.g("actionBlock")?));
        }
    }
    let codex = snapshot.path(&["providers", "codex"])?;
    for s in codex.g("slots")?.arr() {
        let fresh = s.g("status")?.eq_s("ok")? && fresh_timestamp(&s.g("observedAt")?, now)?;
        lines.push(cat!("Codex ", s.g("label")?, " [", s.g("id")?, "]: ", codex_account_state(&s, &policy.g("codex")?, &codex, now)?));
        for (name, bucket) in s.g("buckets")?.props()? {
            if text_eq(&name, "codex_bengalfox")? {
                continue;
            }
            for (minutes, window) in bucket.g("windows")?.props()? {
                lines.push(cat!("  ", &*name, " ", &*minutes, "m: ", window.g("usedPercent")?, "% used; reset ", window.g("anchorState")?));
            }
            if fresh && bucket.g("forecast")?.t()? {
                lines.push(cat!("  ", format_forecast(&bucket.g("forecast")?)?));
            }
        }
    }
    Ok(lines)
}

/// Something the tray may announce once: `key` names what it is about.
struct Alert {
    key: String,
    title: String,
    text: String,
}
impl Alert {
    fn new(key: String, title: &str, text: String) -> Alert {
        Alert { key, title: title.to_string(), text }
    }
}

/// A pace that runs out before its reset.
fn runs_out(forecast: &V) -> R<bool> {
    Ok(forecast.t()? && !forecast.g("lastsToReset")?.t()?)
}

/// What one provider's view gives to announce. Nothing is
/// announced unless the owner asked for it, or outside the hours they work.
fn view_alerts(snapshot: &V, policy: &V, now: Dto) -> R<Vec<Alert>> {
    let mut alerts = Vec::new();
    if !policy.g("notificationsEnabled")?.is_true()? || !work_time(&policy.path(&["automation", "schedule"])?, now)? {
        return Ok(alerts);
    }
    let collector = snapshot.g("collector")?;
    let state = health(&collector, now, "")?;
    let repeated = collector.g("incompleteRuns")?.ge_i(2)?;
    if state == "collector stalled" || state == "collector overdue" || (state == "provider checks incomplete" && repeated) {
        alerts.push(Alert::new("collector".to_string(), "HotPl8 needs attention", cat!(state, ". Run hotpl8 doctor.")));
    }
    for s in snapshot.g("slots")?.arr() {
        if s.g("status")?.in_s(&["relogin_required", "no_credentials"])? {
            let text = cat!("Slot ", s.g("slot")?, " needs sign-in. Run: hotpl8 add -Provider claude");
            alerts.push(Alert::new(cat!("claude/", s.g("slot")?, "/auth"), "Claude sign-in needed", text));
        }
        if s.g("fresh")?.t()? && fresh_timestamp(&s.g("observedAt")?, now)? && runs_out(&s.g("forecast")?)? {
            // Identity and window duration identify the stream; recovery rearms it.
            alerts.push(Alert::new(cat!("claude/", s.g("streamKey")?, "/weekly"), "Claude weekly quota may run out", format_forecast(&s.g("forecast")?)?));
        }
    }
    let codex = snapshot.path(&["providers", "codex"])?;
    for s in codex.g("slots")?.arr() {
        if s.g("status")?.in_s(&["authentication_required", "subscription_login_required"])? {
            alerts.push(Alert::new(cat!("codex/", s.g("id")?, "/auth"), "Codex sign-in needed", cat!("Slot ", s.g("id")?, " needs native sign-in.")));
        }
        for (name, bucket) in s.g("buckets")?.props()? {
            if s.g("status")?.eq_s("ok")? && fresh_timestamp(&s.g("observedAt")?, now)? && runs_out(&bucket.g("forecast")?)? {
                let key = cat!("codex/", s.g("streamKey")?, "/", &*name, "/weekly");
                alerts.push(Alert::new(key, "Codex weekly quota may run out", format_forecast(&bucket.g("forecast")?)?));
            }
        }
    }
    if fresh_timestamp(&snapshot.g("generatedAt")?, now)? {
        let accounts = filter(&snapshot.path(&["decision", "accounts"])?.arr(), |account| account.t())?;
        let eligible = filter(&accounts, |account| {
            let reason = account.g("reason")?;
            Ok(!reason.is_null() && starts(&reason.s()?, "eligible_")?)
        })?;
        if !accounts.is_empty() && eligible.is_empty() {
            alerts.push(Alert::new("claude/no-eligible".to_string(), "No eligible Claude account", "Run hotpl8 explain for the recorded reasons.".to_string()));
        }
        for d in codex.g("decisions")?.arr() {
            let accounts = d.g("accounts")?.arr();
            if d.g("meter")?.eq(&codex.g("defaultMeter")?)? && !accounts.is_empty() && filter(&accounts, |account| account.g("reason")?.eq_s("eligible"))?.is_empty() {
                alerts.push(Alert::new(cat!("codex/", d.g("meter")?, "/no-eligible"), "No eligible Codex account", "Run hotpl8 explain before the next launch.".to_string()));
            }
        }
    }
    Ok(alerts)
}

/// What the tray shows, with `notify`: whether it may announce anything now. The tray
/// asks that before it reads which announcements it has already made, so a quiet hour
/// forgets none of them.
///
/// `snapshot` is one `read_snapshot` returned: either nothing at all, or a snapshot that
/// carries its `providerOverview` already worked out for this policy and instant.
pub fn model(snapshot: &V, policy: &V, now: Dto) -> R<V> {
    let overview = if snapshot.t()? { snapshot.g("providerOverview")? } else { provider_overview(snapshot, policy, now)? };
    let mut details = format_overview(&overview)?;
    for line in format_explanation(snapshot, now)? {
        let mut left_out = false;
        for start in LEFT_OUT {
            left_out = left_out || starts(&line, start)?;
        }
        if !left_out {
            details.push(line);
        }
    }
    let (mut alerts, mut seen) = (Vec::new(), Keys::new());
    for registration in configured_providers(policy, false)? {
        let view = provider_view(snapshot, policy, &registration.g("id")?.s()?, &["providerOverview", "parkCandidates"])?;
        let (family, name) = (view.g("provider")?.s()?, name_text(&registration.g("name")?)?);
        for line in account_lines(&view.g("snapshot")?, &view.g("policy")?, now)? {
            details.push(renamed(&line, &family, " ", &name)?);
        }
        for mut alert in view_alerts(&view.g("snapshot")?, &view.g("policy")?, now)? {
            if starts(&alert.key, &cat!(family, "/"))? {
                alert.key = cat!(registration.g("id")?, &alert.key[family.len()..]);
                alert.title = renamed(&alert.title, &family, "", &name)?;
            }
            if !seen.contains(&alert.key)? {
                seen.insert(&alert.key)?;
                alerts.push(obj! {"key" => alert.key, "title" => alert.title, "text" => alert.text});
            }
        }
    }
    let details: Vec<String> = details.iter().map(|line| safe_text(line)).collect();
    Ok(obj! {
        "providerOverview" => overview,
        "title" => cat!("HotPl8 - ", health(&snapshot.g("collector")?, now, "")?),
        "details" => details.join(if cfg!(windows) { "\r\n" } else { "\n" }),
        "alerts" => alerts,
        "notify" => policy.g("notificationsEnabled")?.is_true()? && work_time(&policy.path(&["automation", "schedule"])?, now)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::{parse, write};

    /// A Sunday.
    const NOON: &str = "2026-09-13T12:00:00.0000000+00:00";
    const HOUR_AGO: &str = "2026-09-13T11:00:00.0000000+00:00";
    const RUNS_OUT: &str = r#"{"pace":"fast","secondsToLimit":7200,"lastsToReset":false}"#;
    const PACE: &str = "Weekly pace: fast; ~2h to limit at cycle-average usage; may run out before reset";

    fn noon() -> Dto {
        crate::display::packaged_data(&std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(".."));
        crate::time::set_zone(Some(0));
        set_core(false);
        Dto::parse(NOON).ok().unwrap()
    }

    fn policy(more: &str) -> V {
        let codex = r#"{"prefer":["a","b"],"defaultMeter":"codex","margin7dWork":5,"order":"soonest-reset","reserve":[],"margin5h":25,"margin7d":20,"modelMeters":{"fixture-model":"codex"},"slots":[{"id":"a","home":"home A"},{"id":"b","home":"home B"}]}"#;
        parse(&format!(r#"{{"schemaVersion":2,"mode":"monitor","prefer":[1,2],"codex":{codex}{more}}}"#), "").ok().unwrap()
    }

    /// A Codex account as a collection leaves it: one weekly window, on a pace that runs out.
    fn account(id: &str, status: &str, observed: &str, used: i32) -> String {
        format!(
            r#"{{"id":"{id}","label":"{id}","status":"{status}","streamKey":"stream-{id}","observedAt":"{observed}","buckets":{{"codex":{{"meter":"codex","status":"observed","blockReason":null,"forecast":{RUNS_OUT},"windows":{{"10080":{{"usedPercent":{used},"remainingPercent":{},"resetsAt":1789304400,"anchorState":"observed-active","observedAt":"{observed}"}}}}}}}},"defaultModel":"fixture-model","modelProvider":"openai"}}"#,
            100 - used
        )
    }

    /// One Claude account read now and one that must sign in; two Codex accounts.
    fn snapshot(codex: &[String], policy: &V, now: Dto) -> V {
        let text = format!(
            r#"{{"generatedAt":"{NOON}","collector":{{"startedAt":"{NOON}","completedAt":"{NOON}","status":"ok"}},"slots":[{{"slot":1,"label":"one","status":"ok","fresh":true,"observedAt":"{NOON}","used5h":10,"used7d":54,"streamKey":"stream-one","forecast":{RUNS_OUT}}},{{"slot":2,"label":"two","status":"relogin_required","fresh":false,"observedAt":"{NOON}","used5h":null,"used7d":null}}],"decision":{{"policy":"balanced","reason":"switch held","accounts":[{{"slot":1,"reason":"model_below_margin","rank":1}}]}},"providers":{{"codex":{{"observedAt":"{NOON}","defaultMeter":"codex","recommendedSlot":"a","recommendations":{{"codex":"a"}},"slots":[{}],"decisions":[{{"meter":"codex","reason":"none","accounts":[{{"slot":"a","reason":"below_margin"}}]}}]}}}}}}"#,
            codex.join(",")
        );
        let snapshot = parse(&text, "").ok().unwrap();
        snapshot.add_member("providerOverview", provider_overview(&snapshot, policy, now).ok().unwrap(), true).ok().unwrap();
        snapshot
    }

    fn lines(shown: &V) -> Vec<String> {
        shown.g("details").ok().unwrap().s().ok().unwrap().lines().map(str::to_string).collect()
    }

    fn keys(shown: &V) -> Vec<String> {
        shown.g("alerts").ok().unwrap().arr().iter().map(|alert| alert.g("key").ok().unwrap().s().ok().unwrap()).collect()
    }

    #[test]
    fn a_line_start_is_compared_without_case_and_a_family_takes_its_registered_name() {
        assert!(starts("CODEX: ready", "Codex:").ok().unwrap());
        assert!(!starts("Codex", "Codex:").ok().unwrap());
        assert!(!starts(" Codex: ready", "Codex:").ok().unwrap());
        // U+212A reads as a k to a runtime that ignores case; it is not guessed at.
        assert!(starts("\u{212a}odex", "kodex").is_err());
        assert!(!starts("\u{212a}odex", "1odex").ok().unwrap());
        assert_eq!(renamed("codex a [a]: STALE", "Codex", " ", "Fictional").ok().unwrap(), "Fictional a [a]: STALE");
        assert_eq!(renamed("  codex 10080m", "codex", " ", "Fictional").ok().unwrap(), "  codex 10080m");
        assert_eq!(renamed("Codex sign-in needed", "codex", "", "Fictional").ok().unwrap(), "Fictional sign-in needed");
        assert!(renamed("Codex a", "codex", " ", "Fic$1tional").is_err());
    }

    #[test]
    fn a_codex_account_is_named_by_the_first_thing_that_stops_it() {
        let now = noon();
        let policy = policy("");
        let part = policy.g("codex").ok().unwrap();
        let provider = parse(r#"{"defaultMeter":"codex","recommendedSlot":"a","recommendations":{"codex":"a"}}"#, "").ok().unwrap();
        let state = |text: &str, part: &V| codex_account_state(&parse(text, "").ok().unwrap(), part, &provider, now).ok().unwrap();
        assert_eq!(codex_account_state(&V::Null, &part, &provider, now).ok().unwrap(), "NO OBSERVATION");
        assert_eq!(state(&account("a", "disabled", NOON, 10), &part), "DISABLED");
        let off = parse(r#"{"disabled":["a"]}"#, "").ok().unwrap();
        assert_eq!(state(&account("a", "ok", NOON, 10), &off), "DISABLED");
        assert_eq!(state(&account("a", "timeout", NOON, 10), &part), "READ RETRYING");
        assert_eq!(state(&account("a", "home_busy", NOON, 10), &part), "READ RETRYING");
        assert_eq!(state(&account("a", "timeout", HOUR_AGO, 10), &part), "TIMEOUT");
        assert_eq!(state(&account("a", "authentication_required", NOON, 10), &part), "AUTHENTICATION REQUIRED");
        assert_eq!(state(&account("a", "ok", HOUR_AGO, 10), &part), "STALE");
        assert_eq!(state(&account("a", "ok", NOON, 100), &part), "EXHAUSTED");
        assert_eq!(state(&account("a", "ok", NOON, 10), &part), "NEXT LAUNCH");
        assert_eq!(state(&account("b", "ok", NOON, 10), &part), "AVAILABLE");
        assert_eq!(state(&account("a", "ok", NOON, 97), &part), "LOW BALANCE");
    }

    #[test]
    fn the_window_shows_each_account_under_one_copy_of_its_provider() {
        let now = noon();
        let policy = policy("");
        let snapshot = snapshot(&[account("a", "ok", NOON, 10), account("b", "authentication_required", NOON, 100)], &policy, now);
        let before = write(&snapshot, 24).ok().unwrap();
        let shown = model(&snapshot, &policy, now).ok().unwrap();
        assert_eq!(write(&snapshot, 24).ok().unwrap(), before);
        assert_eq!(shown.g("title").ok().unwrap().s().ok().unwrap(), "HotPl8 - recent collection completed");
        assert_eq!(write(&shown.g("providerOverview").ok().unwrap(), 24).ok().unwrap(), write(&snapshot.g("providerOverview").ok().unwrap(), 24).ok().unwrap());
        let lines = lines(&shown);
        // The explanation repeats the overview above it; the window shows one copy.
        for (start, times) in [("CLAUDE:", 1), ("CODEX:", 1), ("  Capacity:", 2), ("  Membership:", 2), ("  Next reset:", 1), ("Weekly headroom", 1)] {
            assert_eq!(lines.iter().filter(|line| line.starts_with(start)).count(), times, "{start}");
        }
        let pace = format!("  {PACE}");
        let has = |wanted: &[&str]| lines.windows(wanted.len()).any(|found| found == wanted);
        assert!(has(&["Observed: 2026-09-13T12:00:00.0000000+00:00", "  slot 1: model_below_margin; rank 1"]));
        assert!(has(&["Native launches use the recommendation. Managed host sessions require their own confirmed routing evidence."]));
        assert!(has(&["Claude one: ok", "  5h used: 10%; weekly used: 54%", &pace, "Claude two: relogin_required / stale", "  5h used: unknown; weekly used: unknown"]));
        assert!(has(&["Codex a [a]: NEXT LAUNCH", "  codex 10080m: 10% used; reset observed-active", &pace, "Codex b [b]: AUTHENTICATION REQUIRED", "  codex 10080m: 100% used; reset observed-active"]));
    }

    #[test]
    fn nothing_observed_is_said_once() {
        let now = noon();
        let shown = model(&V::Null, &policy(""), now).ok().unwrap();
        assert_eq!(shown.g("title").ok().unwrap().s().ok().unwrap(), "HotPl8 - manual / no collector evidence");
        assert_eq!(lines(&shown).iter().filter(|line| *line == "No observation. Run hotpl8 refresh.").count(), 1);
        assert!(keys(&shown).is_empty());
        assert!(!shown.g("notify").ok().unwrap().t().ok().unwrap());
    }

    #[test]
    fn an_announcement_is_made_only_when_asked_for_and_in_working_hours() {
        let now = noon();
        let accounts = [account("a", "ok", NOON, 10), account("b", "authentication_required", NOON, 100)];
        let asked = policy(r#","notificationsEnabled":true"#);
        let shown = model(&snapshot(&accounts, &asked, now), &asked, now).ok().unwrap();
        assert!(shown.g("notify").ok().unwrap().t().ok().unwrap());
        let keys_shown = keys(&shown);
        for key in ["claude/stream-one/weekly", "claude/2/auth", "claude/no-eligible", "codex/stream-a/codex/weekly", "codex/b/auth", "codex/codex/no-eligible"] {
            assert_eq!(keys_shown.iter().filter(|found| *found == key).count(), 1, "{key}");
        }
        let weekly = shown.g("alerts").ok().unwrap().arr().into_iter().find(|alert| alert.g("key").ok().unwrap().eq_s("claude/stream-one/weekly").ok().unwrap()).unwrap();
        assert_eq!(weekly.g("title").ok().unwrap().s().ok().unwrap(), "Claude weekly quota may run out");
        assert_eq!(weekly.g("text").ok().unwrap().s().ok().unwrap(), PACE);
        // Not asked for: nothing said, or `false`.
        for quiet in ["", r#","notificationsEnabled":false"#] {
            let policy = policy(quiet);
            let shown = model(&snapshot(&accounts, &policy, now), &policy, now).ok().unwrap();
            assert!(keys(&shown).is_empty() && !shown.g("notify").ok().unwrap().t().ok().unwrap(), "{quiet}");
        }
        // Asked for, on a Sunday, by someone who works on Mondays.
        let monday = policy(r#","notificationsEnabled":true,"automation":{"schedule":{"days":[1],"start":"09:00","end":"17:00","timeZone":"UTC"}}"#);
        let shown = model(&snapshot(&accounts, &monday, now), &monday, now).ok().unwrap();
        assert!(keys(&shown).is_empty() && !shown.g("notify").ok().unwrap().t().ok().unwrap());
    }

    #[test]
    fn a_reading_that_has_aged_announces_no_pace_and_a_stalled_collector_is_announced() {
        let now = noon();
        let asked = policy(r#","notificationsEnabled":true"#);
        let aged = snapshot(&[account("a", "ok", HOUR_AGO, 10)], &asked, now);
        let first = aged.g("slots").ok().unwrap().first().ok().unwrap();
        first.add_member("observedAt", HOUR_AGO.into(), true).ok().unwrap();
        aged.add_member("collector", parse(&format!(r#"{{"startedAt":"{HOUR_AGO}"}}"#), "").ok().unwrap(), true).ok().unwrap();
        let shown = model(&aged, &asked, now).ok().unwrap();
        let keys = keys(&shown);
        assert!(!keys.iter().any(|key| key.ends_with("/weekly")), "{keys:?}");
        assert_eq!(keys.iter().filter(|key| *key == "collector").count(), 1);
        assert_eq!(shown.g("title").ok().unwrap().s().ok().unwrap(), "HotPl8 - collector stalled");
        let lines = lines(&shown);
        assert!(lines.iter().any(|line| line == "Claude one: ok / stale") && lines.iter().any(|line| line == "Codex a [a]: STALE"));
        assert!(!lines.iter().any(|line| line.contains("Weekly pace")));
    }

    #[test]
    fn a_reading_that_is_not_one_hotpl8_writes_is_refused() {
        let now = noon();
        let policy = policy("");
        let snapshot = snapshot(&[account("a", "ok", NOON, 10)], &policy, now);
        snapshot.g("slots").ok().unwrap().first().ok().unwrap().add_member("used7d", parse(r#"{"value":54}"#, "").ok().unwrap(), true).ok().unwrap();
        assert!(model(&snapshot, &policy, now).is_err());
    }
}

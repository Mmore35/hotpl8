//! The policy checks of src/config.ps1, src/automation.ps1 and src/providers/codex.ps1.
//! Each refusal is said in the words HotPl8 has always used for it: the collector, which is
//! still PowerShell, refuses the same policy with the same sentence.

use crate::capacity::assert_capacity_policy;
use crate::critical::assert_critical_policy;
use crate::ps::*;
use crate::registry;

const ORDERS: [&str; 4] = ["prefer", "soonest-reset", "weekly-expiry", "balanced"];
const LATER_ORDERS: [&str; 2] = ["weekly-expiry", "balanced"];

/// `$null -ne $value -and (-not (Test-Hotpl8Number $value) -or $value -lt low -or $value -gt high)`
fn outside(value: &V, low: i32, high: i32) -> R<bool> {
    Ok(!value.is_null() && (!value.is_number() || value.lt_i(low)? || value.gt_i(high)?))
}
/// `[Math]::Floor($value) -ne $value`
fn fraction(value: &V) -> R<bool> {
    value.floor()?.ne(value)
}
/// `$null -ne $list -and ($list -isnot [array] -or the list repeats an item)`, then the
/// same list holding a null.
fn unique_array(list: &V, repeated: &str, null: &str) -> R<()> {
    if list.is_null() {
        return Ok(());
    }
    if !list.is_arr() || unique_count(&list.each())? != list.arr().len() {
        return fail(repeated);
    }
    if list.arr().iter().any(V::is_null) {
        return fail(null);
    }
    Ok(())
}
/// The names of an object's members, none of which may be outside `allowed`.
fn fields_within(object: &V, allowed: &[&str], refusal: &str) -> R<()> {
    for (name, _) in object.props()? {
        if !V::s_of(&name).in_s(allowed)? {
            return fail(refusal);
        }
    }
    Ok(())
}

/// Assert-Hotpl8Policy
pub fn assert_policy(policy: &V) -> R<()> {
    if !policy.is_obj() {
        return fail("Invalid policy: expected an object.");
    }
    let version = policy.g("schemaVersion")?;
    if version.eq_i(3)? && version.is_number() {
        let allowed =
            ["schemaVersion", "mode", "providers", "switchEnabled", "warm", "probeEnabled", "automation", "historyEnabled", "notificationsEnabled", "display"];
        for (name, _) in policy.props()? {
            if !allowed.contains(&&*name) {
                return fail("Invalid version 3 policy field.");
            }
        }
        if !policy.g("mode")?.is_cin_list(&[V::s_of("monitor"), V::s_of("automate")])? {
            return fail("Invalid policy: version 3 requires mode.");
        }
        let control = registry::copy(policy)?;
        control.remove_member("providers")?;
        control.set("schemaVersion", V::I32(2))?;
        assert_policy(&control)?;
        let mut native_homes = Keys::new();
        let mut global_owners = 0;
        for r in registry::configured_providers(policy, false)? {
            let driver = registry::provider_driver(&r.g("driver")?)?;
            let id = r.g("id")?.s()?;
            let view = registry::provider_view(&V::Null, policy, &id, &[])?;
            let part = r.g("policy")?;
            if driver.g("provider")?.eq_s("claude")? {
                for key in [
                    "schemaVersion", "mode", "switchEnabled", "warm", "probeEnabled", "automation", "historyEnabled", "notificationsEnabled",
                    "display", "providers", "codex",
                ] {
                    if part.has(key)? {
                        return fail("Provider policy contains a global or foreign setting.");
                    }
                }
                assert_policy(&view.g("policy")?)?;
                if part.g("prefer")?.each().iter().any(|n| !n.is_null()) {
                    global_owners += 1;
                }
            } else {
                assert_codex_policy(&part)?;
                for slot in part.g("slots")?.arr() {
                    let home = home_key(&slot.g("home")?.s()?)?;
                    if native_homes.contains(&home)? {
                        return fail("Native account home is enrolled under more than one provider.");
                    }
                    native_homes.insert(&home)?;
                }
            }
            if !r.path(&["definition", "capabilities", "warming"])?.t()? && part.g("warm")?.t()? {
                return fail("Provider does not support warming.");
            }
        }
        if global_owners > 1 {
            return fail("The native global activation driver supports only one configured provider owner.");
        }
        return Ok(());
    }
    let versioned = [V::I32(1), V::I32(2)];
    if !version.is_null() && (!version.is_number() || !version.is_in_list(&versioned)?) {
        return fail("Invalid policy: unsupported schemaVersion.");
    }
    let v2_fields = ["automation", "disabled", "claudeModels", "historyEnabled", "notificationsEnabled", "capacity", "critical", "display"];
    if version.ne(&V::I32(2))? {
        for (name, _) in policy.props()? {
            if V::s_of(&name).in_s(&v2_fields)? {
                return fail("New operational settings require schemaVersion 2.");
            }
        }
    }
    if version.is_in_list(&versioned)? {
        let mut allowed = vec![
            "schemaVersion", "mode", "prefer", "reserve", "labels", "weights", "switchEnabled", "warm", "probeEnabled", "order", "pattern",
            "margin5h", "margin7d", "margin7dWork", "hysteresis", "warmMin7d", "warmMin7dWork", "maxUsageAgeS", "staleQuarantineS", "warmFloorMin",
            "warmPhaseWindowMin", "warmGroup", "resetLeadMin", "codex",
        ];
        if version.eq_i(2)? {
            allowed.extend(v2_fields);
            assert_automation_policy(policy)?;
        }
        fields_within(policy, &allowed, "Invalid policy: unknown versioned field.")?;
    }
    let codex = policy.g("codex")?;
    if version.ne(&V::I32(2))? && (codex.g("capacity")?.t()? || codex.g("critical")?.t()?) {
        return fail("Capacity and critical settings require schemaVersion 2.");
    }
    let mode = policy.g("mode")?;
    if mode.t()? && !mode.in_s(&["monitor", "automate"])? {
        return fail("Invalid policy: mode must be monitor or automate.");
    }
    for key in ["warm", "switchEnabled", "probeEnabled"] {
        let value = policy.g(key)?;
        if !value.is_null() && !value.is_bool() {
            return fail(format!("Invalid policy field: {key}"));
        }
    }
    if version.is_in_list(&versioned)? && !mode.t()? {
        return fail("Invalid policy: versioned policy requires mode.");
    }
    for key in ["margin5h", "margin7d", "margin7dWork", "hysteresis", "warmMin7d", "warmMin7dWork"] {
        if outside(&policy.g(key)?, 0, 100)? {
            return fail(format!("Invalid policy field: {key}"));
        }
    }
    for key in ["maxUsageAgeS", "staleQuarantineS", "warmFloorMin", "warmPhaseWindowMin", "warmGroup", "resetLeadMin"] {
        if outside(&policy.g(key)?, 0, 604800)? {
            return fail(format!("Invalid policy field: {key}"));
        }
    }
    for key in ["maxUsageAgeS", "staleQuarantineS", "warmFloorMin", "warmPhaseWindowMin", "warmGroup"] {
        let value = policy.g(key)?;
        if !value.is_null() && value.le_i(0)? {
            return fail(format!("Invalid policy field: {key}"));
        }
    }
    let order = policy.g("order")?;
    if order.t()? && !order.in_s(&ORDERS)? {
        return fail("Invalid policy field: order");
    }
    if version.ne(&V::I32(2))?
        && (order.in_s(&LATER_ORDERS)? || codex.g("order")?.in_s(&LATER_ORDERS)? || (!codex.is_null() && codex.has("disabled")?))
    {
        return fail("New selection options require policy version 2.");
    }
    let pattern = policy.g("pattern")?;
    if pattern.t()? && !pattern.in_s(&["maintain", "even", "clustered", "synced"])? {
        return fail("Invalid policy field: pattern");
    }
    let mut seen = Keys::new();
    for n in policy.g("prefer")?.arr() {
        if n.is_null() {
            continue;
        }
        if !n.is_number() || n.le_i(0)? || n.gt_i(10000)? || fraction(&n)? || seen.contains(&n.s()?)? {
            return fail("Invalid policy field: prefer");
        }
        seen.insert(&n.s()?)?;
    }
    for n in policy.g("reserve")?.arr() {
        if !n.is_null() && !seen.contains(&n.s()?)? {
            return fail("Invalid policy field: reserve");
        }
    }
    for (_, value) in policy.g("labels")?.props()? {
        let text = value.s()?;
        if has_control(&text) || length(&text) > 80 {
            return fail("Invalid policy field: labels");
        }
    }
    assert_capacity_policy(policy)?;
    assert_critical_policy(policy)?;
    let display = policy.g("display")?;
    if display.t()? {
        for (name, value) in display.props()? {
            if !V::s_of(&name).in_s(&["reducedMotion", "noColor"])? || !value.is_bool() {
                return fail("Invalid display setting.");
            }
        }
    }
    for (_, value) in policy.g("weights")?.props()? {
        if !value.is_number() || value.le_i(0)? || value.gt_i(10000)? {
            return fail("Invalid policy field: weights");
        }
    }
    Ok(())
}

/// Assert-Hotpl8AutomationPolicy
fn assert_automation_policy(policy: &V) -> R<()> {
    let a = policy.g("automation")?;
    for name in ["disabled", "claudeModels"] {
        unique_array(&policy.g(name)?, &format!("Invalid array: {name}"), &format!("Null array entry: {name}"))?;
    }
    if a.t()? {
        if !a.is_obj() {
            return fail("automation must be an object.");
        }
        fields_within(&a, &["schedule", "dailyAttemptLimit", "warmExcluded", "continue"], "Invalid automation field.")?;
        let proceed = a.g("continue")?;
        if !proceed.is_null() && !proceed.is_bool() {
            return fail("automation.continue must be true or false.");
        }
        let limit = a.g("dailyAttemptLimit")?;
        if !limit.is_null() && (!limit.is_number() || limit.lt_i(1)? || limit.gt_i(100)? || fraction(&limit)?) {
            return fail("dailyAttemptLimit must be an integer from 1 to 100.");
        }
        let excluded = a.g("warmExcluded")?;
        unique_array(&excluded, "warmExcluded must be a unique array.", "Null warming exclusion.")?;
        for id in excluded.each() {
            if id.is_null() {
                continue;
            }
            let Some(text) = id.as_str() else { return fail("Invalid warming exclusion.") };
            // The pattern's `$` also accepts a final line feed; that spelling is not read.
            if has_control(text) {
                return unreadable();
            }
            let Some((provider, slot)) = text.split_once(':') else { return fail("Invalid warming exclusion.") };
            let lower = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-';
            if !(1..=40).contains(&provider.len()) || !provider.as_bytes()[0].is_ascii_lowercase() || !provider.bytes().all(lower) || !slot_name(slot, 40) {
                return fail("Invalid warming exclusion.");
            }
            let definition = registry::provider_definition(provider)?;
            let driver = registry::provider_driver(&definition.g("driver")?)?;
            if driver.g("slotKind")?.eq_s("numeric")? && !slot.bytes().all(|b| b.is_ascii_digit()) {
                return fail("Invalid warming exclusion.");
            }
        }
        let s = a.g("schedule")?;
        if s.t()? {
            if !s.is_obj() {
                return fail("schedule must be an object.");
            }
            fields_within(&s, &["start", "end", "days", "timeZone"], "Invalid schedule field.")?;
            for t in [s.g("start")?, s.g("end")?] {
                let Some(text) = t.as_str() else { return fail("Work hours must use HH:mm.") };
                if has_control(text) {
                    return unreadable();
                }
                let b = text.as_bytes();
                let hour = b.len() == 5 && (((b[0] == b'0' || b[0] == b'1') && b[1].is_ascii_digit()) || (b[0] == b'2' && (b'0'..=b'3').contains(&b[1])));
                if !hour || b[2] != b':' || !(b'0'..=b'5').contains(&b[3]) || !b[4].is_ascii_digit() {
                    return fail("Work hours must use HH:mm.");
                }
            }
            let days = s.g("days")?;
            if !days.is_arr() || days.arr().is_empty() || unique_count(&days.each())? != days.arr().len() {
                return fail("Work days must be a nonempty unique array.");
            }
            for d in days.arr() {
                if !d.is_number() || d.lt_i(0)? || d.gt_i(6)? || fraction(&d)? {
                    return fail("Work days must be 0 (Sunday) through 6.");
                }
            }
            // `timeZone` is not judged here: which zone names this machine knows is a question
            // for the collector, which works by the schedule. Nothing shown depends on it.
        }
    }
    let prefer = policy.g("prefer")?;
    for n in policy.g("disabled")?.arr() {
        if !n.is_null() && !n.is_in(&prefer)? {
            return fail("Disabled Claude slot must be enrolled.");
        }
    }
    for name in policy.g("claudeModels")?.each() {
        if name.is_null() {
            continue;
        }
        let Some(text) = name.as_str() else { return fail("Invalid Claude scoped model name.") };
        if !slot_name(text, 80) {
            return fail("Invalid Claude scoped model name.");
        }
    }
    for key in ["historyEnabled", "notificationsEnabled"] {
        let value = policy.g(key)?;
        if !value.is_null() && !value.is_bool() {
            return fail(format!("{key} must be Boolean."));
        }
    }
    Ok(())
}

/// Assert-CodexPolicy
pub fn assert_codex_policy(policy: &V) -> R<()> {
    assert_capacity_policy(policy)?;
    assert_critical_policy(policy)?;
    fields_within(
        policy,
        &[
            "slots", "prefer", "reserve", "disabled", "order", "defaultMeter", "modelMeters", "margin5h", "margin7d", "margin7dWork", "hysteresis",
            "resetLeadMin", "capacity", "critical",
        ],
        "invalid_codex_field",
    )?;
    let mut ids = Keys::new();
    let mut homes = Keys::new();
    for slot in policy.g("slots")?.arr() {
        if !slot.t()? {
            return fail("invalid_slot");
        }
        let id = slot.g("id")?.s()?;
        if !slot_name(&id, 40) {
            return fail("invalid_slot");
        }
        let home = home_key(&slot.g("home")?.s()?)?;
        if ids.contains(&id)? || homes.contains(&home)? {
            return fail("duplicate_slot_or_home");
        }
        ids.insert(&id)?;
        homes.insert(&home)?;
        let label = slot.g("label")?.s()?;
        if has_control(&label) || length(&label) > 80 {
            return fail("invalid_label");
        }
    }
    for name in ["prefer", "reserve", "disabled"] {
        let mut seen = Keys::new();
        for id in policy.g(name)?.arr() {
            if !id.t()? {
                continue;
            }
            let id = id.s()?;
            if !ids.contains(&id)? || seen.contains(&id)? {
                return fail("invalid_preference");
            }
            seen.insert(&id)?;
        }
    }
    for key in ["margin5h", "margin7d", "margin7dWork", "hysteresis"] {
        if outside(&policy.g(key)?, 0, 100)? {
            return fail("invalid_margin");
        }
    }
    let meter = policy.g("defaultMeter")?;
    if meter.t()? && !meter.in_s(&["codex", "codex_bengalfox"])? {
        return fail("invalid_meter");
    }
    let order = policy.g("order")?;
    if order.t()? && !order.in_s(&ORDERS)? {
        return fail("invalid_order");
    }
    // Legacy maps are inert compatibility data; native owns model availability.
    if policy.has("modelMeters")? && !policy.g("modelMeters")?.is_obj() {
        return fail("invalid_model_meter");
    }
    if outside(&policy.g("resetLeadMin")?, 0, 604800)? {
        return fail("invalid_reset_lead");
    }
    for id in policy.g("disabled")?.arr() {
        if id.t()? && !ids.contains(&id.s()?)? {
            return fail("invalid_disabled_slot");
        }
    }
    Ok(())
}

/// A native account home as the checks compare it: its full path, lower-cased.
fn home_key(path: &str) -> R<String> {
    Ok(home_path(path)?.to_ascii_lowercase())
}

/// `[IO.Path]::GetFullPath` of a native account home. Apart from the short names Windows
/// keeps, only paths that call leaves as written are modelled: any other home it would
/// rewrite is not one HotPl8 enrolls, and is not read.
pub fn home_path(path: &str) -> R<String> {
    if path.is_empty() {
        // A missing home is not rooted.
        return fail("invalid_home");
    }
    if !printable(path) || path.len() > 200 {
        return unreadable();
    }
    // [IO.Path]::IsPathRooted: a leading separator, or on Windows a drive.
    let b = path.as_bytes();
    let rooted = match cfg!(windows) {
        true => b[0] == b'\\' || b[0] == b'/' || (b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':'),
        false => b[0] == b'/',
    };
    if !rooted {
        return fail("invalid_home");
    }
    let rest = if cfg!(windows) {
        if b.len() < 3 || !b[0].is_ascii_alphabetic() || b[1] != b':' || !(b[2] == b'\\' || b[2] == b'/') {
            return unreadable();
        }
        &path[3..]
    } else {
        if !path.starts_with('/') || path.contains('\\') {
            return unreadable();
        }
        &path[1..]
    };
    let rest = if cfg!(windows) { rest.replace('/', "\\") } else { rest.to_string() };
    let separator = if cfg!(windows) { '\\' } else { '/' };
    if rest.is_empty() {
        return unreadable();
    }
    for segment in rest.split(separator) {
        let stem = segment.split('.').next().unwrap_or("").to_ascii_lowercase();
        let device = matches!(stem.as_str(), "con" | "prn" | "aux" | "nul" | "conin$" | "conout$")
            || ((stem.starts_with("com") || stem.starts_with("lpt")) && stem.len() == 4 && stem.as_bytes()[3].is_ascii_digit());
        if segment.is_empty()
            || segment == "."
            || segment == ".."
            || segment.ends_with('.')
            || segment.ends_with(' ')
            || segment.starts_with(' ')
            || segment.contains(['<', '>', ':', '"', '|', '?', '*'])
            || device
        {
            return unreadable();
        }
    }
    let head = if cfg!(windows) { path[..2].to_string() + "\\" } else { "/".to_string() };
    let full = long_names(head + &rest);
    // The names Windows gives back are compared and hashed as the rest are.
    if !printable(&full) {
        return unreadable();
    }
    Ok(full)
}

/// What `GetFullPath` makes of a path on Windows that may hold a short name (`PROGRA~1`):
/// the names of the directories as they are kept, for as much of the path as exists. The
/// temporary directory of an account whose name is long is spelled with one.
#[cfg(windows)]
fn long_names(full: String) -> String {
    #[link(name = "kernel32")]
    extern "system" {
        fn GetLongPathNameW(short: *const u16, long: *mut u16, size: u32) -> u32;
    }
    if !full.contains('~') {
        return full;
    }
    let mut end = full.len();
    loop {
        let short: Vec<u16> = full[..end].encode_utf16().chain([0]).collect();
        let mut long = vec![0u16; 512];
        // SAFETY: the name is live, NUL-terminated UTF-16, and the size is the buffer's own.
        let mut size = unsafe { GetLongPathNameW(short.as_ptr(), long.as_mut_ptr(), long.len() as u32) } as usize;
        if size > long.len() {
            long = vec![0u16; size];
            // SAFETY: as above.
            size = unsafe { GetLongPathNameW(short.as_ptr(), long.as_mut_ptr(), long.len() as u32) } as usize;
        }
        if size > 0 && size <= long.len() {
            return String::from_utf16_lossy(&long[..size]) + &full[end..];
        }
        // Nothing is there under that name: the part of the path above it may be.
        let absent = matches!(std::io::Error::last_os_error().raw_os_error(), Some(2 | 3));
        match full[..end].rfind('\\') {
            Some(at) if absent && at > 2 => end = at,
            _ => return full,
        }
    }
}
#[cfg(not(windows))]
fn long_names(full: String) -> String {
    full
}

/// What a policy lets the collector do.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Actions {
    pub switching: bool,
    pub warming: bool,
    pub probing: bool,
    pub continuing: bool,
}

/// Get-Hotpl8Actions
pub fn actions(policy: &V, observe_only: bool) -> R<Actions> {
    let enabled = !observe_only && policy.g("mode")?.ne_s("monitor")?;
    let legacy = policy.g("schemaVersion")?.is_null();
    Ok(Actions {
        switching: enabled && ((legacy && policy.g("switchEnabled")?.is_null()) || policy.g("switchEnabled")?.is_true()?),
        warming: enabled && policy.g("warm")?.is_true()?,
        probing: enabled && ((legacy && policy.g("probeEnabled")?.is_null()) || policy.g("probeEnabled")?.is_true()?),
        continuing: enabled && policy.path(&["automation", "continue"])?.ne(&V::Bool(false))?,
    })
}
/// Whether a command that may act would switch.
pub fn switching(policy: &V) -> R<bool> {
    Ok(actions(policy, false)?.switching)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_home_is_named_by_its_full_path() {
        let (home, other) = if cfg!(windows) { ("C:/fixture/Home A", r"C:\fixture\Home A") } else { ("/fixture/Home A", "/fixture/Home A") };
        assert_eq!(home_path(home).ok().unwrap(), other);
        assert_eq!(home_key(home).ok().unwrap(), other.to_ascii_lowercase());
        assert_eq!(home_path("").err().unwrap().message(), "invalid_home");
        assert_eq!(home_path("fixture/relative").err().unwrap().message(), "invalid_home");
        // A name GetFullPath would rewrite is not one HotPl8 enrolls.
        for rewritten in ["fixture/..", "fixture/.", "fixture/trailing.", "fixture//twice"] {
            let root = if cfg!(windows) { "C:\\" } else { "/" };
            assert!(!home_path(&format!("{root}{rewritten}")).err().unwrap().thrown(), "{rewritten}");
        }
        // Nothing is there to give a longer name: the path is as written.
        let absent = if cfg!(windows) { r"C:\fixture~1\no~such\home" } else { "/fixture~1/no~such/home" };
        assert_eq!(home_path(absent).ok().unwrap(), absent);
    }

    /// Windows spells a temporary directory with a short name when the account's is long,
    /// and PowerShell reads such a home as its long one. Only Windows keeps short names,
    /// and only on a volume that is set to.
    #[cfg(windows)]
    #[test]
    fn a_home_written_with_short_names_is_its_long_one() {
        #[link(name = "kernel32")]
        extern "system" {
            fn GetShortPathNameW(long: *const u16, short: *mut u16, size: u32) -> u32;
        }
        let lab = home_path(crate::files::tests::scratch("short-names").to_str().unwrap()).ok().unwrap();
        let long = format!(r"{lab}\a long directory name\another long name");
        std::fs::create_dir_all(&long).unwrap();
        let wide: Vec<u16> = long.encode_utf16().chain([0]).collect();
        let mut short = vec![0u16; 512];
        // SAFETY: the name is live, NUL-terminated UTF-16, and the size is the buffer's own.
        let size = unsafe { GetShortPathNameW(wide.as_ptr(), short.as_mut_ptr(), short.len() as u32) } as usize;
        assert!(size > 0 && size < short.len());
        let short = String::from_utf16_lossy(&short[..size]);
        if short != long {
            assert!(short.contains('~'), "{short}");
            assert_eq!(home_path(&short).ok().unwrap(), long);
            assert_eq!(home_path(&short.replace('\\', "/")).ok().unwrap(), long);
            assert_eq!(home_key(&short.to_ascii_lowercase()).ok().unwrap(), long.to_ascii_lowercase());
            // As much of the path as exists is given its long names.
            assert_eq!(home_path(&format!(r"{short}\absent\deeper")).ok().unwrap(), format!(r"{long}\absent\deeper"));
            let above = &short[..short.rfind('\\').unwrap()];
            assert_eq!(home_path(&format!(r"{above}\NOSUCH~1\home")).ok().unwrap(), format!(r"{lab}\a long directory name\NOSUCH~1\home"));
        }
        std::fs::remove_dir_all(&lab).unwrap();
    }
}

//! The doctor's facts: what one state directory and this machine hold. Reading them runs no
//! provider and writes nothing. `runtime` and whether Claude's continue hook is present are
//! PowerShell's to add, and src/diagnostics.ps1 prints the report. `capabilities` is the
//! same kind of report, of what this copy can do with what it finds.

use std::path::Path;
use std::time::UNIX_EPOCH;

use crate::agent::instant;
use crate::capacity::{detected_plan, fresh_timestamp};
use crate::files;
use crate::insights::{health, read_snapshot};
use crate::json;
use crate::obj;
use crate::overview::park_candidates;
use crate::policy::{actions, assert_codex_policy, assert_policy};
use crate::ps::*;
use crate::registry::{configured_providers, provider_accounts, provider_driver, provider_view};
use crate::time::{Dto, TICKS_PER_SECOND};
use crate::version::version;

/// What this machine has installed, found by whoever asks.
#[derive(Clone, Copy)]
pub struct Found {
    pub cswap: bool,
    pub codex: bool,
}

/// A marker's name is the session it was written for: '^[A-Za-z0-9-]+$', whose end also
/// stands before one last line feed.
fn marker_name(name: &str) -> bool {
    let name = name.strip_suffix('\n').unwrap_or(name);
    !name.is_empty() && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

/// A file a listing shows without being asked for the hidden ones.
fn shown(entry: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        entry.is_file() && entry.file_attributes() & 2 == 0
    }
    #[cfg(not(windows))]
    {
        entry.is_file()
    }
}

/// When automatic continue last fired: the newest marker of the `continue` directory.
fn last_continue(directory: &Path) -> R<V> {
    let markers = directory.join("continue");
    let mut newest = None;
    let mut look = |name: &std::ffi::OsStr, entry: std::io::Result<std::fs::Metadata>| {
        let Ok(entry) = entry else { return };
        if name.to_str().is_some_and(marker_name) && shown(&entry) {
            if let Ok(written) = entry.modified() {
                newest = newest.max(Some(written));
            }
        }
    };
    if markers.is_dir() {
        let Ok(entries) = std::fs::read_dir(&markers) else { return throw() };
        for entry in entries.flatten() {
            look(&entry.file_name(), entry.metadata());
        }
    } else if markers.is_file() {
        look(std::ffi::OsStr::new("continue"), markers.metadata());
    }
    let Some(written) = newest else { return Ok(V::Null) };
    let Ok(since) = written.duration_since(UNIX_EPOCH) else { return throw() };
    let Ok(whole) = i64::try_from(since.as_secs()) else { return throw() };
    let second = Dto::from_unix_seconds(whole)?;
    debug_assert!(TICKS_PER_SECOND == 10_000_000);
    Ok(Dto { ticks: second.ticks + i64::from(since.subsec_nanos() / 100), offset_minutes: 0 }.o().into())
}

/// Get-Hotpl8Doctor, but for `runtime` and `continue.hookPresent`.
pub fn facts(root: &Path, directory: &Path, found: Found, now: Dto) -> R<V> {
    let policy = json::read_or_null(&directory.join("policy.json"));
    let checked = || -> R<()> {
        assert_policy(&policy)?;
        if policy.path(&["codex", "slots"])?.t()? {
            assert_codex_policy(&policy.g("codex")?)?;
        }
        Ok(())
    };
    let valid = checked().is_ok();
    let status = json::read_or_null(&directory.join("status.json"));
    let age = match instant(&status.g("generatedAt").unwrap_or(V::Null)) {
        Ok(Some(at)) => Some(now.utc().since(at.utc()).total_seconds().round_ties_even()),
        _ => None,
    };
    // Do not create a lock or any other file during a doctor read.
    let lock = directory.join("tick.lock");
    let busy = lock.exists() && files::held(&lock);
    // Count only: labels are private and this report is the redacted export.
    let parked = if valid { park_candidates(&status, &policy, now).map_or(0, |candidates| candidates.len()) } else { 0 };
    let registered = obj! {};
    if valid {
        let accounts = provider_accounts(&policy)?;
        for registration in configured_providers(&policy, true)? {
            let id = registration.g("id")?.s()?;
            let driver = provider_driver(&registration.g("driver")?)?;
            let facts = obj! {
                "driver" => registration.g("driver")?,
                "configured" => accounts.iter().any(|account| account.provider == id),
                "installed" => if driver.g("slotKind")?.eq_s("numeric")? { found.cswap } else { found.codex },
            };
            registered.add_member(&id, facts, true)?;
        }
    }
    // Read only: whether automatic continue is on, and when it last fired.
    let continued = || -> R<V> { Ok(obj! {"enabled" => actions(&policy, false)?.continuing, "lastAt" => last_continue(directory)?}) };
    let continued = if valid { continued().unwrap_or(V::Null) } else { V::Null };
    Ok(obj! {
        "providers" => &registered,
        "version" => version(root)?,
        "policyPresent" => directory.join("policy.json").exists(),
        "policyValid" => valid,
        "mode" => if policy.g("mode")?.t()? { policy.g("mode")? } else { "legacy".into() },
        "claudeConfigured" => registered.path(&["claude", "configured"])?.t()?,
        "codexConfigured" => registered.path(&["codex", "configured"])?.t()?,
        "cswapFound" => found.cswap,
        "codexFound" => found.codex,
        "snapshotAgeSeconds" => age.map_or(V::Null, V::Dbl),
        "snapshotFresh" => age.is_some_and(|age| (-5.0..=900.0).contains(&age)),
        "collectorBusy" => busy,
        "parkCandidates" => i32::try_from(parked).unwrap_or(i32::MAX),
        "continue" => continued,
    })
}

fn count(items: usize) -> i32 {
    i32::try_from(items).unwrap_or(i32::MAX)
}

/// Get-Hotpl8Capabilities, but for `runtime`: what this copy can do with what is configured
/// and installed here.
pub fn capabilities(root: &Path, directory: &Path, found: Found, now: Dto) -> R<V> {
    let doctor = facts(root, directory, found, now)?;
    let stored = json::read_or_null(&directory.join("policy.json"));
    let status = read_snapshot(directory, &stored, false, now)?;
    let policy = if stored.t()? { stored } else { obj! {} };
    let providers = obj! {};
    for registration in configured_providers(&policy, true)? {
        let id = registration.g("id")?.s()?;
        let view = provider_view(&status, &policy, &id, &[])?;
        let part = if view.g("provider")?.eq_s("claude")? { view.g("snapshot")? } else { view.path(&["snapshot", "providers", "codex"])? };
        let slots = part.g("slots")?.each();
        let numeric = view.path(&["driver", "slotKind"])?.eq_s("numeric")?;
        let able = registration.path(&["definition", "capabilities"])?;
        let fresh = filter(&slots, |slot| Ok(slot.g("status")?.eq_s("ok")? && fresh_timestamp(&slot.g("observedAt")?, now)?))?.len();
        let facts = obj! {
            "installed" => if numeric { found.cswap } else { found.codex },
            "configured" => provider_accounts(&policy)?.iter().any(|account| account.provider == id),
            "freshAccounts" => count(fresh),
            "observe" => if numeric { "supported adapter" } else { "native app-server" },
            "selection" => if numeric { "experimental" } else { "next-launch" },
            "warming" => if able.g("warming")?.t()? { "experimental" } else { "unsupported" },
            "authentication" => "native; verify with refresh",
            "driver" => registration.g("driver")?,
            "capabilities" => &able,
            "contexts" => obj! {
                "native" => if able.g("nativeLaunch")?.t()? { "next-launch" } else { "global-native-activation" },
                "t3" => if able.g("t3Rollover")?.t()? { "managed bridge: qualified request boundary" } else { "native client adoption" },
            },
        };
        if numeric {
            facts.add_member("planDetection", "automatic profile discovery".into(), true)?;
            facts.add_member("detectedPlans", count(filter(&slots, |slot| detected_plan(&slot.g("plan")?, now))?.len()).into(), true)?;
        }
        providers.add_member(&id, facts, true)?;
    }
    Ok(obj! {
        "schemaVersion" => 1,
        "platform" => if cfg!(windows) { "windows-preview" } else { "source-only-unqualified" },
        "policyValid" => doctor.g("policyValid")?,
        "collector" => health(&json::read_or_null(&directory.join("collector.json")), now, "")?,
        "providers" => &providers,
        "capacity" => "configured relative-window estimates",
        "critical" => "opt-in; action-scope selection",
        "motion" => "cat and nyan; reduced-motion supported",
        "tray" => cfg!(windows),
        "macHandoff" => "docs/plans/macos-handoff.md",
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::tests::{changed, noon, set, state};
    use crate::display::packaged_data;
    use crate::files::tests::scratch;
    use std::fs;
    use std::path::PathBuf;
    use std::time::{Duration, SystemTime};

    fn root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("..")
    }
    const BOTH: Found = Found { cswap: true, codex: true };
    const NEITHER: Found = Found { cswap: false, codex: false };

    fn text(facts: &V) -> String {
        json::compact(facts, 12).unwrap()
    }
    fn member(facts: &V, path: &[&str]) -> String {
        json::compact(&obj! {"is" => facts.path(path).unwrap()}, 12).unwrap()
    }

    #[test]
    fn a_directory_with_nothing_in_it_is_reported_as_that() {
        packaged_data(&root());
        let directory = scratch("doctor-empty");
        let facts = facts(&root(), &directory, NEITHER, noon()).unwrap();
        let version = fs::read_to_string(root().join("VERSION")).unwrap();
        assert_eq!(
            text(&facts),
            format!(
                "{{\"providers\":{{}},\"version\":\"{}\",\"policyPresent\":false,\"policyValid\":false,\"mode\":\"legacy\",\"claudeConfigured\":false,\"codexConfigured\":false,\"cswapFound\":false,\"codexFound\":false,\"snapshotAgeSeconds\":null,\"snapshotFresh\":false,\"collectorBusy\":false,\"parkCandidates\":0,\"continue\":null}}",
                version.trim()
            )
        );
        assert!(fs::read_dir(&directory).unwrap().next().is_none(), "the doctor wrote something");
    }

    #[test]
    fn a_valid_policy_names_its_providers_and_what_is_installed_for_them() {
        let directory = state("doctor-valid");
        let both = facts(&root(), &directory, BOTH, noon()).unwrap();
        assert_eq!(member(&both, &["policyPresent"]), r#"{"is":true}"#);
        assert_eq!(member(&both, &["policyValid"]), r#"{"is":true}"#);
        assert_eq!(member(&both, &["mode"]), r#"{"is":"monitor"}"#);
        assert_eq!(
            member(&both, &["providers"]),
            r#"{"is":{"claude":{"driver":"claude-cswap","configured":true,"installed":true},"codex":{"driver":"codex-app-server","configured":true,"installed":true}}}"#
        );
        assert_eq!(member(&both, &["claudeConfigured"]), r#"{"is":true}"#);
        assert_eq!(member(&both, &["codexConfigured"]), r#"{"is":true}"#);
        // Each provider is installed when its own program is found, and not the other's.
        let claude = facts(&root(), &directory, Found { cswap: true, codex: false }, noon()).unwrap();
        assert_eq!(member(&claude, &["providers", "claude", "installed"]), r#"{"is":true}"#);
        assert_eq!(member(&claude, &["providers", "codex", "installed"]), r#"{"is":false}"#);
        assert_eq!(member(&claude, &["cswapFound"]), r#"{"is":true}"#);
        assert_eq!(member(&claude, &["codexFound"]), r#"{"is":false}"#);
        let codex = facts(&root(), &directory, Found { cswap: false, codex: true }, noon()).unwrap();
        assert_eq!(member(&codex, &["providers", "claude", "installed"]), r#"{"is":false}"#);
        assert_eq!(member(&codex, &["providers", "codex", "installed"]), r#"{"is":true}"#);
    }

    #[test]
    fn the_snapshot_is_as_old_as_the_clock_says_and_fresh_for_fifteen_minutes() {
        let directory = state("doctor-age");
        let at = |seconds: f64| facts(&root(), &directory, BOTH, noon().plus(seconds).unwrap()).unwrap();
        // The fixture's snapshot was written 42 seconds before noon.
        let now = at(0.0);
        assert!(matches!(now.g("snapshotAgeSeconds").unwrap(), V::Dbl(age) if age == 42.0));
        assert_eq!(member(&now, &["snapshotFresh"]), r#"{"is":true}"#);
        assert_eq!(member(&at(858.0), &["snapshotFresh"]), r#"{"is":true}"#);
        assert_eq!(member(&at(859.0), &["snapshotFresh"]), r#"{"is":false}"#);
        // A clock a little behind the file's is a clock, and one far behind is not trusted.
        assert_eq!(member(&at(-47.0), &["snapshotFresh"]), r#"{"is":true}"#);
        assert_eq!(member(&at(-48.0), &["snapshotFresh"]), r#"{"is":false}"#);
        // Half a second is rounded to the even second.
        assert!(matches!(at(0.5).g("snapshotAgeSeconds").unwrap(), V::Dbl(age) if age == 42.0));
        assert!(matches!(at(1.5).g("snapshotAgeSeconds").unwrap(), V::Dbl(age) if age == 44.0));
        fs::write(directory.join("status.json"), r#"{"generatedAt":"yesterday"}"#).unwrap();
        assert_eq!(member(&at(0.0), &["snapshotAgeSeconds"]), r#"{"is":null}"#);
        assert_eq!(member(&at(0.0), &["snapshotFresh"]), r#"{"is":false}"#);
    }

    #[test]
    fn a_policy_that_is_not_valid_is_named_and_nothing_is_read_from_it() {
        let directory = state("doctor-invalid");
        fs::write(directory.join("policy.json"), r#"{"mode":"automate","prefer":"one"}"#).unwrap();
        let facts = facts(&root(), &directory, BOTH, noon()).unwrap();
        assert_eq!(member(&facts, &["policyPresent"]), r#"{"is":true}"#);
        assert_eq!(member(&facts, &["policyValid"]), r#"{"is":false}"#);
        assert_eq!(member(&facts, &["mode"]), r#"{"is":"automate"}"#);
        assert_eq!(member(&facts, &["providers"]), r#"{"is":{}}"#);
        assert_eq!(member(&facts, &["continue"]), r#"{"is":null}"#);
        assert_eq!(member(&facts, &["parkCandidates"]), r#"{"is":0}"#);
    }

    #[test]
    fn accounts_that_could_be_parked_are_counted_and_not_named() {
        let directory = state("doctor-park");
        let count = |seconds: f64| member(&facts(&root(), &directory, BOTH, noon().plus(seconds).unwrap()).unwrap(), &["parkCandidates"]);
        assert_eq!(count(0.0), r#"{"is":0}"#);
        // An account read just now whose plan is no longer a paid one.
        changed(&directory, "status.json", |status| {
            for slot in status.path(&["providers", "codex", "slots"]).unwrap().arr() {
                set(&slot, "planType", "free".into());
            }
        });
        assert_eq!(count(0.0), r#"{"is":2}"#);
        // A snapshot that is no longer fresh is evidence of nothing.
        assert_eq!(count(3600.0), r#"{"is":0}"#);
    }

    #[test]
    fn a_held_lock_is_a_busy_collector_and_looking_makes_no_lock() {
        let directory = state("doctor-lock");
        let busy = |directory: &Path| member(&facts(&root(), directory, BOTH, noon()).unwrap(), &["collectorBusy"]);
        assert_eq!(busy(&directory), r#"{"is":false}"#);
        assert!(!directory.join("tick.lock").exists(), "the doctor made a lock");
        let held = files::lock(&directory.join("tick.lock")).ok().unwrap();
        assert_eq!(busy(&directory), r#"{"is":true}"#);
        drop(held);
        assert_eq!(busy(&directory), r#"{"is":false}"#);
    }

    #[test]
    fn continue_reports_whether_it_is_on_and_its_newest_marker() {
        let directory = state("doctor-continue");
        let report = |directory: &Path| member(&facts(&root(), directory, BOTH, noon()).unwrap(), &["continue"]);
        // The fixture policy only watches.
        assert_eq!(report(&directory), r#"{"is":{"enabled":false,"lastAt":null}}"#);
        changed(&directory, "policy.json", |policy| set(policy, "mode", "automate".into()));
        assert_eq!(report(&directory), r#"{"is":{"enabled":true,"lastAt":null}}"#);
        let markers = directory.join("continue");
        fs::create_dir(&markers).unwrap();
        let written = |name: &str, seconds: u64, nanos: u32| {
            let file = fs::File::create(markers.join(name)).unwrap();
            file.set_modified(SystemTime::UNIX_EPOCH + Duration::new(seconds, nanos)).unwrap();
        };
        // 2026-09-12T11:00:00Z is 1789210800.
        written("session-A1", 1_789_210_800, 123_456_700);
        written("session-B2", 1_789_210_700, 0);
        assert_eq!(report(&directory), r#"{"is":{"enabled":true,"lastAt":"2026-09-12T11:00:00.1234567+00:00"}}"#);
        // A newer file that is not a marker changes nothing: a name of other letters, a directory.
        written("session.tmp", 1_789_210_900, 0);
        written("under_score", 1_789_210_900, 0);
        fs::create_dir(markers.join("later")).unwrap();
        assert_eq!(report(&directory), r#"{"is":{"enabled":true,"lastAt":"2026-09-12T11:00:00.1234567+00:00"}}"#);
        written("session-C3", 1_789_210_900, 0);
        assert_eq!(report(&directory), r#"{"is":{"enabled":true,"lastAt":"2026-09-12T11:01:40.0000000+00:00"}}"#);
    }

    #[cfg(windows)]
    #[test]
    fn a_hidden_marker_is_not_one_a_listing_shows() {
        use std::os::windows::fs::OpenOptionsExt;
        let directory = state("doctor-hidden");
        changed(&directory, "policy.json", |policy| set(policy, "mode", "automate".into()));
        let markers = directory.join("continue");
        fs::create_dir(&markers).unwrap();
        fs::OpenOptions::new().write(true).create(true).truncate(true).attributes(2).open(markers.join("session-A1")).unwrap();
        assert_eq!(member(&facts(&root(), &directory, BOTH, noon()).unwrap(), &["continue"]), r#"{"is":{"enabled":true,"lastAt":null}}"#);
    }

    #[test]
    fn the_version_is_the_one_of_the_release_asked_about() {
        packaged_data(&root());
        let release = scratch("doctor-release");
        fs::write(release.join("VERSION"), "9.8.7\n").unwrap();
        let directory = scratch("doctor-release-state");
        assert_eq!(member(&facts(&release, &directory, NEITHER, noon()).unwrap(), &["version"]), r#"{"is":"9.8.7"}"#);
    }

    #[test]
    fn marker_names_are_letters_digits_and_hyphens() {
        for name in ["a", "A-1", "0123456789-abc-XYZ", "session\n"] {
            assert!(marker_name(name), "{name:?}");
        }
        for name in ["", "\n", "a.b", "a_b", "a b", "é", "a\n\n", "\na"] {
            assert!(!marker_name(name), "{name:?}");
        }
    }

    /// What the report says of each shipped provider, but for what is found of it here.
    fn provider(claude: bool, found: &str) -> String {
        if claude {
            format!(
                r#"{{{found},"observe":"supported adapter","selection":"experimental","warming":"experimental","authentication":"native; verify with refresh","driver":"claude-cswap","capabilities":{{"observation":true,"enrollment":true,"selection":true,"nativeLaunch":false,"warming":true,"recoveryProbe":true,"t3Rollover":false}},"contexts":{{"native":"global-native-activation","t3":"native client adoption"}},"planDetection":"automatic profile discovery","detectedPlans":0}}"#
            )
        } else {
            format!(
                r#"{{{found},"observe":"native app-server","selection":"next-launch","warming":"unsupported","authentication":"native; verify with refresh","driver":"codex-app-server","capabilities":{{"observation":true,"enrollment":true,"selection":true,"nativeLaunch":true,"warming":false,"recoveryProbe":false,"t3Rollover":true}},"contexts":{{"native":"next-launch","t3":"managed bridge: qualified request boundary"}}}}"#
            )
        }
    }
    fn report(valid: bool, collector: &str, claude: &str, codex: &str) -> String {
        let (platform, tray) = if cfg!(windows) { ("windows-preview", true) } else { ("source-only-unqualified", false) };
        format!(
            r#"{{"schemaVersion":1,"platform":"{platform}","policyValid":{valid},"collector":"{collector}","providers":{{"claude":{},"codex":{}}},"capacity":"configured relative-window estimates","critical":"opt-in; action-scope selection","motion":"cat and nyan; reduced-motion supported","tray":{tray},"macHandoff":"docs/plans/macos-handoff.md"}}"#,
            provider(true, claude),
            provider(false, codex)
        )
    }

    #[test]
    fn capabilities_report_each_registered_provider_and_what_is_fresh_of_it() {
        let directory = state("doctor-capabilities");
        let found = capabilities(&root(), &directory, Found { cswap: true, codex: false }, noon()).unwrap();
        assert_eq!(
            text(&found),
            report(true, "manual / no collector evidence", r#""installed":true,"configured":true,"freshAccounts":2"#, r#""installed":false,"configured":true,"freshAccounts":2"#)
        );
        // Each provider is installed when its own program is found, and not the other's.
        let other = capabilities(&root(), &directory, Found { cswap: false, codex: true }, noon()).unwrap();
        assert_eq!(member(&other, &["providers", "claude", "installed"]), r#"{"is":false}"#);
        assert_eq!(member(&other, &["providers", "codex", "installed"]), r#"{"is":true}"#);
    }

    #[test]
    fn capabilities_count_what_was_read_lately_and_the_plans_found_lately() {
        let directory = state("doctor-capabilities-fresh");
        let counted = |now: Dto| {
            let report = capabilities(&root(), &directory, BOTH, now).unwrap();
            let count = |path: &[&str]| report.path(path).unwrap().to_int().unwrap();
            (count(&["providers", "claude", "freshAccounts"]), count(&["providers", "codex", "freshAccounts"]), count(&["providers", "claude", "detectedPlans"]))
        };
        assert_eq!(counted(noon()), (2, 2, 0));
        changed(&directory, "status.json", |status| {
            let slots = status.g("slots").unwrap().arr();
            // An account whose read failed is not a fresh one, however lately it was tried.
            set(&slots[0], "status", "unavailable".into());
            set(&slots[1], "plan", obj! {"status" => "detected", "observedAt" => "2026-09-12T11:40:00.0000000+00:00", "profile" => "claude-pro"});
            set(&status.path(&["providers", "codex", "slots"]).unwrap().arr()[0], "observedAt", "2026-09-12T11:45:00.0000000+00:00".into());
        });
        // A reading is fresh for fifteen minutes and a plan for twenty, to the second.
        assert_eq!(counted(noon()), (1, 2, 1));
        assert_eq!(counted(noon().plus(1.0).unwrap()), (1, 1, 0));
        assert_eq!(counted(noon().plus(900.0).unwrap()), (0, 0, 0));
    }

    #[test]
    fn capabilities_of_a_directory_with_nothing_in_it_name_what_could_be_registered() {
        packaged_data(&root());
        let directory = scratch("doctor-capabilities-empty");
        let nothing = r#""installed":false,"configured":false,"freshAccounts":0"#;
        let said = || capabilities(&root(), &directory, NEITHER, noon()).map(|report| text(&report)).map_err(|stop| stop.message());
        assert_eq!(said(), Ok(report(false, "manual / no collector evidence", nothing, nothing)));
        assert!(fs::read_dir(&directory).unwrap().next().is_none(), "the report wrote something");
        fs::write(directory.join("collector.json"), r#"{"status":"ok","startedAt":"2026-09-12T11:59:00.0000000+00:00","completedAt":"2026-09-12T11:59:18.0000000+00:00"}"#).unwrap();
        assert_eq!(said(), Ok(report(false, "recent collection completed", nothing, nothing)));
        fs::write(directory.join("policy.json"), r#"{"mode":"automate","prefer":"one"}"#).unwrap();
        // A policy the reader cannot lay a snapshot out by is refused, and nothing is guessed.
        let refused = said().unwrap_err();
        assert!(refused.starts_with("This state cannot be shown: one of its values is not one HotPl8 writes (") && refused.ends_with("Run hotpl8 refresh; if that changes nothing, run hotpl8 doctor."), "{refused}");
    }
}

//! src/provider-actions.ps1: the short boundary every action is authorized inside. A writer
//! of state takes tick.lock and then action-control.lock, and no native program is run
//! while action-control.lock is held. A change made after an action was authorized governs
//! the next action, not the one already admitted.

use crate::automation;
use crate::files::{self, Unlocked};
use crate::json;
use crate::policy::actions;
use crate::ps::*;
use crate::registry;
use crate::sha256;
use crate::time::Dto;
use std::io::ErrorKind;
use std::path::Path;
use std::time::{Duration, Instant};

/// Invoke-Hotpl8ControlWrite
pub fn control_write<T>(directory: &Path, timeout_ms: u64, action: impl FnOnce() -> R<T>) -> R<T> {
    let clock = Instant::now();
    let _lock = loop {
        match files::lock(&directory.join("action-control.lock")) {
            Ok(lock) => break lock,
            Err(Unlocked::Refused) => return fail("action_state_unavailable"),
            Err(Unlocked::Busy) if clock.elapsed() >= Duration::from_millis(timeout_ms) => return fail("action_control_busy"),
            Err(Unlocked::Busy) => std::thread::sleep(Duration::from_millis(15)),
        }
    };
    action()
}

/// Get-Hotpl8ControlGeneration: one name for the exact bytes of every file that decides
/// whether an action may happen. These are settings and leases, never credentials.
pub fn control_generation(directory: &Path) -> R<String> {
    let mut parts = Vec::new();
    for name in ["policy.json", "hold.json", "automation-pause.json", "automation-leases.json"] {
        let path = directory.join(name);
        // Only a missing file is absent; any other failure stops.
        match std::fs::metadata(&path) {
            Err(error) if error.kind() == ErrorKind::NotFound => parts.push(format!("{name}:absent")),
            Err(error) => return Stop::io(&error, &path),
            Ok(file) if file.is_dir() => return fail("action_state_unavailable"),
            Ok(_) => match std::fs::read(&path) {
                Ok(bytes) => parts.push(format!("{name}:{}", sha256::hex(&sha256::digest(&bytes), true))),
                Err(error) => return Stop::io(&error, &path),
            },
        }
    }
    Ok(sha256::hash(&parts.join("|")))
}

/// Invoke-Hotpl8ActionAuthorization
pub fn action_authorization<T>(directory: &Path, expected_generation: &str, authorize: impl FnOnce() -> R<T>) -> R<T> {
    control_write(directory, 1000, || {
        if expected_generation.is_empty() || control_generation(directory)? != expected_generation {
            return fail("action_state_changed");
        }
        authorize()
    })
}

/// Get-Hotpl8ControlSnapshot: the policy, and the generation it was read under.
pub fn control_snapshot(directory: &Path) -> R<(V, String)> {
    control_write(directory, 1000, || {
        let before = control_generation(directory)?;
        let policy = json::read_or_null(&directory.join("policy.json"));
        let after = control_generation(directory)?;
        if before != after {
            return fail("action_state_changed");
        }
        Ok((policy, after))
    })
}

/// Get-Hotpl8ProviderActionContext
pub fn provider_action_context(policy: &V, directory: &Path, context: &V, now: Dto) -> R<V> {
    let copy = registry::copy(context)?;
    let actions = actions(policy, false)?;
    let pause = automation::pause(directory, now);
    let intent = context.g("intent")?;
    copy.add_member("mode", if policy.g("mode")?.eq_s("monitor")? { "monitor" } else { "automate" }.into(), true)?;
    copy.add_member("switching", actions.switching.into(), true)?;
    copy.add_member("paused", pause.t()?.into(), true)?;
    copy.add_member("hold", automation::hold(directory, now).is_some().into(), true)?;
    if pause.g("invalid")?.t()? && !intent.in_s(&["refresh", "control"])? {
        copy.add_member("safetyInvalid", true.into(), true)?;
    }
    if intent.in_s(&["warm", "probe"])? {
        let enabled = if intent.eq_s("warm")? { actions.warming } else { actions.probing };
        copy.add_member("actionEnabled", enabled.into(), true)?;
    }
    Ok(copy)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::{scratch, shared_rules};
    use crate::obj;

    #[test]
    fn the_control_files_say_what_the_shared_cases_say() {
        set_core(false);
        let cases = shared_rules("control").arr();
        assert!(cases.len() > 20);
        let mut wrong = Vec::new();
        for case in &cases {
            let field = |name: &str| case.g(name).ok().unwrap();
            let directory = scratch("shared-control");
            for (name, text) in field("files").props().ok().unwrap() {
                std::fs::write(directory.join(&*name), text.s().ok().unwrap()).unwrap();
            }
            // The name of the files' bytes, the hold, and what an action is told of them.
            let answered = || -> R<V> {
                let now = Dto::of(&field("now"))?;
                let (policy, generation) = control_snapshot(&directory)?;
                let hold = match automation::hold(&directory, now) {
                    Some(hold) => obj! {"until" => hold.until.o(), "reason" => hold.reason},
                    None => V::Null,
                };
                let context = provider_action_context(&policy, &directory, &field("context"), now)?;
                Ok(obj! {"generation" => generation, "hold" => hold, "context" => context})
            };
            let answer = match answered() {
                Ok(answer) => json::compact(&answer, 12).ok().unwrap(),
                Err(stop) => format!("stopped: {}", stop.message()),
            };
            let expected = json::compact(&field("expected"), 12).ok().unwrap();
            if answer != expected {
                wrong.push(format!("{}\n  expected {expected}\n  answered {answer}", field("name").s().ok().unwrap()));
            }
            std::fs::remove_dir_all(&directory).unwrap();
        }
        assert!(wrong.is_empty(), "{} of {} cases differ:\n{}", wrong.len(), cases.len(), wrong.join("\n"));
    }

    #[test]
    fn the_generation_names_the_bytes_of_the_control_files() {
        let directory = scratch("generation");
        let empty = control_generation(&directory).ok().unwrap();
        assert_eq!(empty, sha256::hash("policy.json:absent|hold.json:absent|automation-pause.json:absent|automation-leases.json:absent"));
        std::fs::write(directory.join("policy.json"), "abc").unwrap();
        let named = "policy.json:BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD|hold.json:absent|automation-pause.json:absent|automation-leases.json:absent";
        assert_eq!(control_generation(&directory).ok().unwrap(), sha256::hash(named));
        // An empty file and one with a byte order mark are named by their exact bytes.
        std::fs::write(directory.join("automation-leases.json"), "").unwrap();
        std::fs::write(directory.join("automation-pause.json"), [0xEF, 0xBB, 0xBF, 0x7B, 0x7D]).unwrap();
        let named = "policy.json:BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD|hold.json:absent|automation-pause.json:AA25E978046D680EF8740D837E6DE5BC1E2A2DC6089DBDA1012544B538D53F65|automation-leases.json:E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855";
        assert_eq!(control_generation(&directory).ok().unwrap(), sha256::hash(named));
        // A state directory that is not there has every file absent.
        assert_eq!(control_generation(&directory.join("none")).ok().unwrap(), empty);
        std::fs::create_dir(directory.join("hold.json")).unwrap();
        assert_eq!(control_generation(&directory).err().unwrap().said(), Some("action_state_unavailable"));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn an_action_is_authorized_only_under_the_generation_it_was_decided_on() {
        let directory = scratch("authorize");
        std::fs::write(directory.join("policy.json"), r#"{"mode":"automate"}"#).unwrap();
        let (policy, generation) = control_snapshot(&directory).ok().unwrap();
        assert!(policy.g("mode").ok().unwrap().eq_s("automate").ok().unwrap());
        assert_eq!(action_authorization(&directory, &generation, || Ok(7)).ok(), Some(7));
        // No one writes a control file while an action is being authorized.
        let inside = action_authorization(&directory, &generation, || Ok(control_write(&directory, 20, || Ok(())).err().unwrap().said().map(str::to_string)));
        assert_eq!(inside.ok().unwrap().as_deref(), Some("action_control_busy"));
        assert_eq!(action_authorization(&directory, "", || Ok(7)).err().unwrap().said(), Some("action_state_changed"));
        std::fs::write(directory.join("hold.json"), "{}").unwrap();
        assert_eq!(action_authorization(&directory, &generation, || Ok(7)).err().unwrap().said(), Some("action_state_changed"));
        // Someone else inside the boundary is waited for, for a moment.
        let held = files::lock(&directory.join("action-control.lock")).ok().unwrap();
        assert_eq!(control_write(&directory, 60, || Ok(())).err().unwrap().said(), Some("action_control_busy"));
        drop(held);
        assert_eq!(control_write(&directory.join("none"), 60, || Ok(())).err().unwrap().said(), Some("action_state_unavailable"));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn the_context_carries_what_the_files_say_now() {
        let directory = scratch("context");
        let now = Dto::parse("2026-10-06T12:00:00.0000000+00:00").ok().unwrap();
        let policy = json::parse(r#"{"schemaVersion":2,"warm":true,"switchEnabled":true}"#, "").ok().unwrap();
        let context = obj! {"intent" => "warm", "previousId" => "1", "actionSlot" => "2"};
        let made = provider_action_context(&policy, &directory, &context, now).ok().unwrap();
        let text = json::write(&made, 4).ok().unwrap().replace(['\n', ' '], "");
        assert_eq!(text, r#"{"intent":"warm","previousId":"1","actionSlot":"2","mode":"automate","switching":true,"paused":false,"hold":false,"actionEnabled":true}"#);
        // A hold stops a switch. It leaves warming, which is enabled on its own, as it was.
        std::fs::write(directory.join("hold.json"), r#"{"until":"2026-10-06T13:00:00Z"}"#).unwrap();
        let listed = || std::fs::read_dir(&directory).unwrap().map(|entry| entry.unwrap().file_name()).collect::<Vec<_>>();
        let before = listed();
        let made = provider_action_context(&policy, &directory, &context, now).ok().unwrap();
        let text = json::write(&made, 4).ok().unwrap().replace(['\n', ' '], "");
        assert_eq!(text, r#"{"intent":"warm","previousId":"1","actionSlot":"2","mode":"automate","switching":true,"paused":false,"hold":true,"actionEnabled":true}"#);
        assert_eq!(listed(), before, "the context is only read");
        std::fs::write(directory.join("automation-pause.json"), "{oh no").unwrap();
        let made = provider_action_context(&policy, &directory, &obj! {"intent" => "probe"}, now).ok().unwrap();
        let text = json::write(&made, 4).ok().unwrap().replace(['\n', ' '], "");
        assert_eq!(text, r#"{"intent":"probe","mode":"automate","switching":true,"paused":true,"hold":true,"safetyInvalid":true,"actionEnabled":false}"#);
        let made = provider_action_context(&policy, &directory, &obj! {"intent" => "refresh"}, now).ok().unwrap();
        assert!(made.g("safetyInvalid").ok().unwrap().is_null());
        // A pause ends at a time spelled as HotPl8 writes it. PowerShell took a date alone
        // as a pause that can be read; here it is one that cannot, which blocks as much.
        std::fs::write(directory.join("automation-pause.json"), r#"{"until":"2999-01-01"}"#).unwrap();
        let made = provider_action_context(&policy, &directory, &obj! {"intent" => "switch"}, now).ok().unwrap();
        let text = json::write(&made, 4).ok().unwrap().replace(['\n', ' '], "");
        assert_eq!(text, r#"{"intent":"switch","mode":"automate","switching":true,"paused":true,"hold":true,"safetyInvalid":true}"#);
        std::fs::remove_dir_all(&directory).unwrap();
    }
}

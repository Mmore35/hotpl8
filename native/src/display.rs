//! `hotpl8 status` and `hotpl8 explain`: the state on disk, shown under a policy.

use std::path::{Path, PathBuf};

use crate::obj;
use crate::ps::{self, fail, R, V};
use crate::request::{full_path, Command, Request};
use crate::time::Dto;
use crate::{capacity, insights, json, pause, policy, registry};

/// The data files the rules read are this release's own, the ones its PowerShell reads.
pub fn packaged_data(root: &Path) {
    let data = root.join("data");
    registry::set_source(data.join("providers"));
    capacity::set_source(data.join("capacity-profiles.json"));
}

/// Where the state is: where the caller says, where the environment says, where the
/// installer recorded, and otherwise beside the code, which is how a checkout runs.
pub fn state_directory(root: &Path, explicit: Option<&Path>) -> R<PathBuf> {
    if let Some(explicit) = explicit {
        return Ok(explicit.to_path_buf());
    }
    let named = match std::env::var_os("HOTPL8_STATE_DIRECTORY").filter(|value| !value.is_empty()) {
        Some(named) => named,
        None => {
            let installed = json::read_file(&root.join("install-state.json"))?.unwrap_or(V::Null);
            let directory = installed.g("stateDirectory")?;
            if !directory.t()? {
                return Ok(root.to_path_buf());
            }
            directory.s()?.into()
        }
    };
    match full_path(&named) {
        Some(path) => Ok(path),
        None => ps::unreadable_as("The state directory HotPl8 was given is not a path."),
    }
}

fn lines(lines: Vec<String>) -> String {
    lines.into_iter().flat_map(|line| [line, "\n".to_owned()]).collect()
}

/// The value as JSON no deeper than `limit`, or its typed dump for the parity suite.
fn value(value: &V, limit: usize, dump: bool) -> R<String> {
    let text = json::write(value, limit)?;
    if dump {
        return json::dump(value);
    }
    Ok(text + "\n")
}

pub fn answer(request: &Request) -> R<String> {
    ps::set_core(request.core);
    crate::time::set_zone(request.zone);
    packaged_data(&request.root);
    let state = state_directory(&request.root, request.state.as_deref())?;
    // One clock reading per request: every line of an answer describes the same instant.
    let now = match request.now {
        Some(now) => now,
        None => Dto::now()?,
    };
    let policy_file = match &request.policy {
        Some(preview) => preview.clone(),
        None => state.join("policy.json"),
    };
    let Some(policy) = json::read_file(&policy_file)? else {
        return fail("No valid policy.json. Run hotpl8 setup or see docs/install.md.");
    };
    policy::assert_policy(&policy)?;
    let status = insights::read_snapshot(&state, &policy, request.policy.is_some(), now)?;
    if request.command == Command::Explain {
        if status.t()? {
            status.add_member("automationPause", pause::pause(&state, now)?, true)?;
        }
        if request.as_json {
            let answer = obj! {
                "generatedAt" => status.g("generatedAt")?,
                "claude" => status.g("decision")?,
                "codex" => status.path(&["providers", "codex", "decisions"])?,
                "pause" => status.g("automationPause")?,
                "providerOverview" => status.g("providerOverview")?,
            };
            return value(&answer, 16, request.dump);
        }
        return Ok(lines(insights::format_explanation(&status, now)?.iter().map(|line| ps::safe_text(line)).collect()));
    }
    if !status.t()? || !status.g("generatedAt")?.t()? {
        return Ok(lines(vec!["No cached status. Run hotpl8 refresh.".to_owned()]));
    }
    if request.as_json {
        return value(&status, 24, request.dump);
    }
    Ok(lines(insights::format_status(&status, &policy, &state, now)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_state_is_where_the_caller_then_the_release_says() {
        let root = std::env::temp_dir().join(format!("hotpl8-native-state-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let mut request = Request::new(Command::Status, root.clone());
        if std::env::var_os("HOTPL8_STATE_DIRECTORY").is_none() {
            assert_eq!(state_directory(&request.root, request.state.as_deref()).ok().unwrap(), root);
            let recorded = root.join("elsewhere");
            std::fs::write(root.join("install-state.json"), format!("{{\"stateDirectory\":{:?}}}", recorded.to_str().unwrap())).unwrap();
            assert_eq!(state_directory(&request.root, request.state.as_deref()).ok().unwrap(), recorded);
        }
        request.state = Some(root.join("named"));
        assert_eq!(state_directory(&request.root, request.state.as_deref()).ok().unwrap(), root.join("named"));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_state_without_a_policy_says_what_to_run() {
        let root = std::env::temp_dir().join(format!("hotpl8-native-nopolicy-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let mut request = Request::new(Command::Status, root.clone());
        request.state = Some(root.clone());
        let stop = answer(&request).err().unwrap();
        assert!(stop.ruled());
        assert_eq!(stop.message(), "No valid policy.json. Run hotpl8 setup or see docs/install.md.");
        std::fs::write(root.join("policy.json"), "{\"mode\": monitor}").unwrap();
        let stop = answer(&request).err().unwrap();
        assert!(!stop.ruled());
        assert_eq!(stop.message(), "policy.json is not JSON as HotPl8 writes it (line 1, column 10).");
        std::fs::remove_dir_all(&root).unwrap();
    }
}

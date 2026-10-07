//! src/providers/claude-plans.ps1: which subscription each Claude account has, asked at
//! most every fifteen minutes. Knowing the plan is optional: it cannot change sign-in,
//! quota or which account is eligible.

use crate::files;
use crate::json;
use crate::process;
use crate::obj;
use crate::ps::*;
use crate::sha256::hash;
use crate::time::Dto;
use std::path::{Path, PathBuf};

const PROFILES: [(&str, &str, i32); 3] = [("claude-pro", "Pro", 1), ("claude-max-5x", "Max 5x", 5), ("claude-max-20x", "Max 20x", 20)];

/// `$id -notmatch '^[1-9][0-9]{0,3}$'`, the other way round.
fn numbered(id: &str) -> bool {
    let body = id.strip_suffix('\n').unwrap_or(id).as_bytes();
    (1..=4).contains(&body.len()) && body[0] != b'0' && body.iter().all(u8::is_ascii_digit)
}

/// The Python cswap runs under: beside cswap.exe (a venv or pipx install as well), or the
/// one its launcher script names. A cswap of any other kind keeps working, with the plan
/// unknown.
fn python(cswap: &str) -> Option<PathBuf> {
    let path = Path::new(cswap);
    let name = path.file_name()?.to_str()?;
    if name.eq_ignore_ascii_case("cswap.exe") {
        let beside = path.parent()?;
        return [Some(beside), beside.parent()].into_iter().flatten().map(|directory| directory.join("python.exe")).find(|candidate| candidate.exists());
    }
    if !name.eq_ignore_ascii_case("cswap") {
        return None;
    }
    // '^#!(/[^\r\n]+/python[0-9.]*)\s*$'
    let bytes = std::fs::read(path).ok().filter(|bytes| bytes.len() <= 1_048_576)?;
    let text = String::from_utf8_lossy(&bytes);
    let named = text.split(['\r', '\n']).next()?.strip_prefix("#!")?.trim_end();
    let last = named.rfind("/python")?;
    let version = &named[last + "/python".len()..];
    if !named.starts_with('/') || last < 2 || !version.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        return None;
    }
    Some(PathBuf::from(named)).filter(|candidate| candidate.exists())
}

/// What the helper beside cswap's own Python says of these accounts. It reads through
/// cswap's own readers and prints only a projection that names no credential. Whatever
/// goes wrong the answer is nothing: sign-in and provider output must not reach a
/// diagnostic.
pub fn helper<'a>(cswap: &'a str, root: &'a Path) -> impl FnOnce(&[String]) -> Option<V> + 'a {
    move |pending| {
        let python = python(cswap)?;
        let script = root.join("src").join("providers").join("claude_plan.py");
        let mut words = vec![script.to_str()?];
        words.extend(pending.iter().map(String::as_str));
        let read = process::run(python.to_str()?, &words, 45_000).ok()?;
        if read.exit_code != 0 {
            return None;
        }
        json::parse(&read.output, "").ok()
    }
}

/// Read-Hotpl8ClaudePlans. An account is known by its email and organization together;
/// both the inventory and the helper must name the same organization, and an email alone
/// is never enough. Only an allow-listed projection is kept: no credential, no raw profile.
pub fn plans(accounts: &[V], directory: &Path, now: Dto, reader: impl FnOnce(&[String]) -> Option<V>) -> R<V> {
    let path = directory.join("claude-plans.json");
    let cache = json::read_or_null(&path);
    let result = obj! {};
    let mut pending: Vec<(String, String)> = Vec::new();
    for account in accounts {
        let id = account.g("number")?.s()?;
        if !numbered(&id) || account.g("disabled")?.is_true()? || account.g("enabled")?.is_false()? {
            continue;
        }
        let binding = hash(&format!("{}|{}", account.g("email")?.s()?, account.g("organizationUuid")?.s()?));
        let prior = cache.g("accounts")?.g(&id)?;
        let reuse = catch(|| {
            if !cache.g("schemaVersion")?.eq_i(1)? || !prior.g("identityKey")?.eq_s(&binding)? {
                return Ok(false);
            }
            let next = Dto::parse_external(&prior.g("nextAttemptAt")?.s()?)?;
            Ok(next.since(now).0 > 0 && next.since(now.plus_seconds(86_400)?).0 <= 0)
        })?;
        if reuse == Some(true) {
            result.add_member(&id, prior, false)?;
        } else {
            pending.push((id, binding));
        }
    }
    if pending.is_empty() {
        return Ok(result);
    }
    let ids: Vec<String> = pending.iter().map(|(id, _)| id.clone()).collect();
    let data = reader(&ids).unwrap_or(V::Null);
    for (id, binding) in &pending {
        let mut matches = Vec::new();
        for row in data.g("accounts")?.each() {
            if text_eq(&row.g("slot")?.s()?, id)? {
                matches.push(row);
            }
        }
        let row = if data.g("schemaVersion")?.eq_i(1)? && matches.len() == 1 { matches.remove(0) } else { V::Null };
        let (mut status, mut profile, mut label, mut multiplier, mut retry) = (V::from("unavailable"), V::Null, V::Null, V::Null, V::I32(900));
        if row.t()? && row.g("identityKey")?.eq_s(binding)? {
            let said = row.g("status")?;
            if said.in_s(&["detected", "partial", "unsupported", "identity_mismatch", "no_credentials", "rate_limited", "authentication_required", "unavailable"])? {
                status = said;
            }
            if status.eq_s("detected")? {
                let named = row.g("profile")?.s()?;
                match PROFILES.iter().find(|(known, _, _)| named.eq_ignore_ascii_case(known)) {
                    Some((_, name, sessions)) => (profile, label, multiplier) = (V::from(named), V::from(*name), V::I32(*sessions)),
                    None => status = V::from("unsupported"),
                }
            }
            if status.eq_s("partial")? && row.g("label")?.in_s(&["Pro", "Max (tier unknown)", "Team", "Enterprise"])? {
                label = row.g("label")?.sv()?;
            }
            let after = row.g("retryAfterSeconds")?;
            if status.eq_s("rate_limited")? && after.is_number() {
                retry = math_pick(&V::I32(900), &math_pick(&V::I32(86_400), &after, false)?, true)?;
            }
        }
        let row = obj! {
            "status" => status,
            "identityKey" => binding.as_str(),
            "profile" => profile,
            "label" => label,
            "sessionMultiplier" => multiplier,
            "source" => "anthropic-oauth-profile",
            "observedAt" => now.o(),
            "nextAttemptAt" => now.plus(retry.dbl()?)?.o(),
        };
        result.add_member(id, row, false)?;
    }
    // The caller holds the collector's lock. What is not written is asked again next time.
    let _ = files::write_json(&path, &obj! {"schemaVersion" => V::I32(1), "accounts" => result.clone()}, 6);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::scratch;
    use crate::json::parse;
    use std::cell::Cell;

    fn account(email: &str, organization: Option<&str>) -> V {
        let organization = organization.map_or(String::new(), |id| format!(r#","organizationUuid":"{id}""#));
        parse(&format!(r#"{{"number":1,"email":"{email}"{organization}}}"#), "").ok().unwrap()
    }
    fn said(identity: &str, more: &str) -> Option<V> {
        parse(&format!(r#"{{"schemaVersion":1,"accounts":[{{"slot":1,"identityKey":"{identity}"{more}}}]}}"#), "").ok()
    }
    fn text(plans: &V, name: &str) -> String {
        plans.g("1").ok().unwrap().g(name).ok().unwrap().s().ok().unwrap()
    }

    /// tests/test-claude-plans.ps1, with the helper's answer given.
    #[test]
    fn a_plan_is_asked_for_seldom_and_kept_without_an_identity() {
        let directory = scratch("plans");
        let now = Dto::parse("2026-09-14T12:00:00.0000000+00:00").ok().unwrap();
        let at = |minutes: i64| now.plus_seconds(minutes * 60).ok().unwrap();
        let calls = Cell::new(0);
        let mut one = account("fictional@example.invalid", Some("fictional-org"));
        let key = |account: &V| hash(&format!("{}|{}", account.g("email").ok().unwrap().s().ok().unwrap(), "fictional-org"));
        let ask = |account: &V, minutes: i64, more: &str| {
            let identity = key(account);
            plans(std::slice::from_ref(account), &directory, at(minutes), |slots| {
                assert_eq!(slots, ["1"]);
                calls.set(calls.get() + 1);
                said(&identity, more)
            })
            .ok()
            .unwrap()
        };
        let pro = r#","status":"detected","profile":"claude-pro","retryAfterSeconds":3600"#;
        let first = ask(&one, 0, pro);
        assert_eq!((text(&first, "profile").as_str(), text(&first, "label").as_str(), calls.get()), ("claude-pro", "Pro", 1));
        assert_eq!(text(&first, "sessionMultiplier"), "1");
        assert_eq!(text(&first, "nextAttemptAt"), "2026-09-14T12:15:00.0000000+00:00");
        // A cached answer is not asked for again on every wake.
        let cached = ask(&one, 5, pro);
        assert_eq!((text(&cached, "profile").as_str(), calls.get()), ("claude-pro", 1));
        // A changed plan is seen at the next asking.
        let max = r#","status":"detected","profile":"claude-max-5x","retryAfterSeconds":3600"#;
        let updated = ask(&one, 16, max);
        assert_eq!((text(&updated, "label").as_str(), text(&updated, "sessionMultiplier").as_str(), calls.get()), ("Max 5x", "5", 2));
        // The same slot holding another account is another account.
        one = account("replacement@example.invalid", Some("fictional-org"));
        let replaced = ask(&one, 17, max);
        assert_eq!(calls.get(), 3);
        assert_ne!(text(&replaced, "identityKey"), text(&first, "identityKey"));
        // A rate limit is waited out, and claims no plan meanwhile.
        let limited = ask(&one, 33, r#","status":"rate_limited","profile":"claude-max-5x","retryAfterSeconds":3600"#);
        ask(&one, 55, max);
        assert_eq!((text(&limited, "status").as_str(), text(&limited, "profile").as_str(), calls.get()), ("rate_limited", "", 4));
        assert_eq!(text(&limited, "nextAttemptAt"), "2026-09-14T13:33:00.0000000+00:00");
        // An answer about another identity labels nothing.
        let foreign = plans(std::slice::from_ref(&one), &directory, at(180), |_| said("foreign", r#","status":"detected","profile":"claude-max-20x","label":"secret""#)).ok().unwrap();
        assert_eq!((text(&foreign, "status").as_str(), text(&foreign, "profile").as_str(), text(&foreign, "label").as_str()), ("unavailable", "", ""));
        // An inventory that names no organization stays unknown.
        let bare = account("replacement@example.invalid", None);
        let identity = key(&one);
        let unknown = plans(&[bare], &directory, at(240), |_| said(&identity, r#","status":"detected","profile":"claude-pro""#)).ok().unwrap();
        assert_eq!((text(&unknown, "status").as_str(), text(&unknown, "profile").as_str()), ("unavailable", ""));
        // The file names no email, no organization and nothing the provider said.
        let kept = std::fs::read_to_string(directory.join("claude-plans.json")).unwrap();
        assert!(kept.contains("\"schemaVersion\": 1") && !kept.contains("example.invalid") && !kept.contains("fictional-org") && !kept.contains("secret"));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn what_the_helper_says_is_projected() {
        let directory = scratch("plans-shape");
        let now = Dto::parse("2026-09-14T12:00:00.0000000+00:00").ok().unwrap();
        let one = account("fictional@example.invalid", Some("fictional-org"));
        let identity = hash("fictional@example.invalid|fictional-org");
        let ask = |more: &str| {
            let _ = std::fs::remove_file(directory.join("claude-plans.json"));
            let plans = plans(std::slice::from_ref(&one), &directory, now, |_| said(&identity, more)).ok().unwrap();
            ["status", "profile", "label", "sessionMultiplier", "nextAttemptAt"].map(|name| text(&plans, name)).join("|")
        };
        let soon = "2026-09-14T12:15:00.0000000+00:00";
        assert_eq!(ask(r#","status":"detected","profile":"claude-max-20x""#), format!("detected|claude-max-20x|Max 20x|20|{soon}"));
        assert_eq!(ask(r#","status":"detected","profile":"claude-team""#), format!("unsupported||||{soon}"));
        assert_eq!(ask(r#","status":"partial","label":"Team""#), format!("partial||Team||{soon}"));
        assert_eq!(ask(r#","status":"partial","label":"Free""#), format!("partial||||{soon}"));
        assert_eq!(ask(r#","status":"surprising""#), format!("unavailable||||{soon}"));
        assert_eq!(ask(r#","status":"rate_limited","retryAfterSeconds":5"#), format!("rate_limited||||{soon}"));
        assert_eq!(ask(r#","status":"rate_limited","retryAfterSeconds":999999"#), "rate_limited||||2026-09-15T12:00:00.0000000+00:00");
        // No answer, and an account that is switched off, are not errors.
        let none = plans(std::slice::from_ref(&one), &directory, now.plus_seconds(86_400 * 2).ok().unwrap(), |_| None).ok().unwrap();
        assert_eq!(text(&none, "status"), "unavailable");
        let off = parse(r#"{"number":1,"email":"a@example.invalid","organizationUuid":"o","enabled":false}"#, "").ok().unwrap();
        let skipped = plans(&[off], &directory, now, |_| panic!("asked")).ok().unwrap();
        assert!(skipped.props().ok().unwrap().is_empty());
        assert!(numbered("9999") && !numbered("0") && !numbered("01") && !numbered("12345") && !numbered("x"));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn python_is_found_beside_cswap() {
        let directory = scratch("plans-python");
        let scripts = directory.join("Scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        let cswap = scripts.join("cswap.exe");
        assert_eq!(python(cswap.to_str().unwrap()), None);
        std::fs::write(directory.join("python.exe"), "").unwrap();
        assert_eq!(python(cswap.to_str().unwrap()), Some(directory.join("python.exe")));
        std::fs::write(scripts.join("python.exe"), "").unwrap();
        assert_eq!(python(cswap.to_str().unwrap()), Some(scripts.join("python.exe")));
        assert_eq!(python(scripts.join("cswap-stub.cmd").to_str().unwrap()), None);
        // A launcher script names its interpreter on its first line.
        let launcher = directory.join("cswap");
        for line in ["#!/usr/bin/env python3", "#!/python3", "#!relative/bin/python", "#!/opt/x/python3 -E", "# no"] {
            std::fs::write(&launcher, format!("{line}\nimport sys\n")).unwrap();
            assert_eq!(python(launcher.to_str().unwrap()), None, "{line}");
        }
        std::fs::remove_dir_all(&directory).unwrap();
    }
}

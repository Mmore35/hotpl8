//! Which shipped routine reads a registered provider, what its
//! reading comes to for the collector, and what is shown for a provider that could not be
//! read. A definition selects a routine by name; it never names a program.

use crate::claude_tick::{self, claude_tick};
use crate::codex::{format_codex_status, select_codex_slot};
use crate::codex_collect::{self, Collection};
use crate::codex_read::HomeRead;
use crate::collection::codex_failure;
use crate::json;
use crate::obj;
use crate::pause::pause;
use crate::ps::*;
use crate::registry::{self, provider_driver, provider_state_directory, provider_view};
use crate::time::Dto;
use std::path::Path;
use std::time::{Duration, Instant};

/// What a collection is given besides the provider it reads.
pub struct Reading<'a> {
    pub policy: &'a V,
    /// The state directory: where the pause, the hold and the action lock are kept.
    pub directory: &'a Path,
    /// The control generation the policy was read under.
    pub generation: &'a str,
    pub cswap: Option<&'a str>,
    pub observe_only: bool,
    /// The release this program belongs to.
    pub root: &'a Path,
    /// The user's home directory, where cswap keeps what it stores.
    pub home: &'a Path,
    pub clock: &'a dyn Fn() -> R<Dto>,
    /// Reads the Codex account in the home named, within so many milliseconds.
    pub codex: &'a dyn Fn(&str, u64) -> HomeRead,
}

/// What one provider's reading came to.
pub struct Collected {
    pub payload: V,
    /// The provider's lines of status.txt.
    pub lines: Vec<String>,
    /// What to print when the collection did something to an account.
    pub action: Option<String>,
    /// At least one account was read, or is switched off on purpose.
    pub success: bool,
    /// Some account was neither.
    pub incomplete: bool,
    /// How long a healthy provider is left before it is read again.
    pub healthy_seconds: i32,
}

/// The switches a provider's routine is given only when its definition allows the act.
const SWITCHES: [(&str, &str); 3] = [("selection", "switchEnabled"), ("warming", "warm"), ("recoveryProbe", "probeEnabled")];

/// One reading of a registered provider, by the routine its definition's driver names.
/// `old` is what the snapshot before this one shows for the provider.
pub fn registered_collection(registration: &V, reading: &Reading, old: &V) -> R<Collected> {
    let id = registration.g("id")?.s()?;
    let driver = provider_driver(&registration.g("driver")?)?;
    let capabilities = registration.path(&["definition", "capabilities"])?;
    if !capabilities.g("observation")?.t()? {
        return fail("Provider observation is unavailable.");
    }
    let state = provider_state_directory(reading.directory, &id)?;
    if let Err(error) = std::fs::create_dir_all(&state) {
        return Stop::io(&error, &state);
    }
    let view = provider_view(&V::Null, reading.policy, &id, &[])?;
    let native = view.g("policy")?;
    for (capability, switch) in SWITCHES {
        if !capabilities.g(capability)?.t()? {
            native.add_member(switch, false.into(), true)?;
        }
    }
    // Global pause belongs to the installation, not the adapter's quota cache.
    if state != reading.directory && pause(reading.directory, (reading.clock)()?)?.t()? {
        for (_, switch) in SWITCHES {
            native.add_member(switch, false.into(), true)?;
        }
    }
    match driver.g("id")?.s()?.as_str() {
        "claude-cswap" => {
            let request = claude_tick::Request {
                policy: &native,
                state: &state,
                control: reading.directory,
                generation: Some(reading.generation),
                provider: &id,
                cswap: reading.cswap,
                observe_only: reading.observe_only,
                root: reading.root,
                home: reading.home,
                clock: reading.clock,
            };
            // A provider without accounts is never read: the collector skips it first.
            let Some(result) = claude_tick(&request)? else { return throw() };
            let slots = result.payload.g("slots")?;
            let healthy = filter(&slots.each(), |slot| Ok(slot.g("fresh")?.t()? || slot.g("status")?.eq_s("disabled")?))?.len();
            Ok(Collected {
                success: healthy > 0,
                incomplete: healthy != slots.arr().len(),
                healthy_seconds: driver.g("healthyPollSeconds")?.to_int()?,
                payload: result.payload,
                lines: result.lines,
                action: result.action,
            })
        }
        "codex-app-server" => {
            let part = registration.g("policy")?;
            let began = Instant::now();
            let payload = codex_collect::collect(&Collection {
                policy: &part,
                state: &state,
                control: reading.directory,
                previous: old,
                read: reading.codex,
                clock: reading.clock,
                elapsed: &|| i64::try_from(began.elapsed().as_millis()).unwrap_or(i64::MAX),
                pause: &|milliseconds| std::thread::sleep(Duration::from_millis(milliseconds)),
            })?;
            let slots = payload.g("slots")?;
            let healthy = filter(&slots.each(), |slot| slot.g("status")?.in_s(&["ok", "disabled"]))?.len();
            let meter = part.g("defaultMeter")?;
            let critical = match meter.as_str() {
                Some(name) => payload.g("critical")?.gd(name)?,
                None if meter.is_null() => V::Null,
                None => return unreadable(),
            };
            let cadence = if critical.g("active")?.t()? { critical.g("pollSeconds")?.to_int()? } else { driver.g("healthyPollSeconds")?.to_int()? };
            Ok(Collected {
                lines: format_codex_status(&payload, &part, (reading.clock)()?)?,
                action: None,
                success: healthy > 0,
                incomplete: healthy != slots.arr().len(),
                healthy_seconds: cadence,
                payload,
            })
        }
        _ => fail("Unsupported collection driver."),
    }
}

/// One subscription, and the first provider and account it was seen under.
struct Seen {
    identity: String,
    provider: String,
    slot: V,
    registration: V,
}

/// Two providers signed into the same subscription are not
/// two lots of capacity. Both accounts are marked, each provider chooses again without its
/// own, and the providers this happened to are named.
pub fn collected_ownership(registrations: &[V], payloads: &[(String, V)], directory: &Path, now: Dto) -> R<Vec<String>> {
    let payload_of = |id: &str| payloads.iter().find(|(known, _)| known == id).map_or(V::Null, |(_, payload)| payload.clone());
    let mut seen: Vec<Seen> = Vec::new();
    let mut conflicts: Vec<(String, V)> = Vec::new();
    let mut conflict = |id: &str, registration: &V| match conflicts.iter().position(|(known, _)| known == id) {
        Some(index) => conflicts[index].1 = registration.clone(),
        None => conflicts.push((id.to_string(), registration.clone())),
    };
    for r in registrations {
        if !r.g("driver")?.ceq_s("codex-app-server")? {
            continue;
        }
        let id = r.g("id")?.s()?;
        let state = json::read_or_null(&provider_state_directory(directory, &id)?.join("codex-state.json"));
        for slot in filter(&payload_of(&id).g("slots")?.each(), |slot| slot.g("status")?.eq_s("ok"))? {
            let name = slot.g("id")?;
            let Some(name) = name.as_str() else { return unreadable() };
            if name.is_empty() {
                continue;
            }
            let identity = state.g("slots")?.gd(name)?.g("identityKey")?.s()?;
            if identity.is_empty() {
                continue;
            }
            match seen.iter().find(|known| known.identity == identity) {
                Some(other) => {
                    if other.provider != id {
                        slot.set("status", "duplicate_subscription".into())?;
                        other.slot.set("status", "duplicate_subscription".into())?;
                        conflict(&id, r);
                        conflict(&other.provider, &other.registration);
                    }
                }
                // The table's keys ignore case by the rules of the current culture.
                None if seen.iter().any(|known| !printable(&known.identity) || !printable(&identity) || known.identity.eq_ignore_ascii_case(&identity)) => return unreadable(),
                None => seen.push(Seen { identity, provider: id.clone(), slot, registration: r.clone() }),
            }
        }
    }
    for (id, r) in &conflicts {
        let payload = payload_of(id);
        let part = r.g("policy")?;
        for meter in r.path(&["definition", "meters"])?.arr() {
            let Some(meter) = meter.as_str() else { return unreadable() };
            let prior = payload.g("recommendations")?.gd(meter)?.s()?;
            let selected = select_codex_slot(&payload.g("slots")?.each(), &part, meter, &prior, &payload.g("hold")?, now, &payload.g("critical")?.gd(meter)?)?;
            payload.g("recommendations")?.add_member(meter, selected.clone(), true)?;
            for decision in filter(&payload.g("decisions")?.each(), |decision| decision.g("meter")?.ceq_s(meter))? {
                decision.set("selected", selected.clone())?;
                for account in decision.g("accounts")?.arr() {
                    let wanted = account.g("slot")?;
                    let slot = filter(&payload.g("slots")?.each(), |slot| slot.g("id")?.ceq(&wanted))?.into_iter().next();
                    if let Some(slot) = slot {
                        if slot.g("status")?.eq_s("duplicate_subscription")? {
                            account.set("reason", "duplicate_subscription".into())?;
                        }
                    }
                }
            }
        }
        let own = part.g("defaultMeter")?;
        let default_meter = if own.t()? { own } else { r.path(&["definition", "defaultMeter"])? };
        let Some(default_meter) = default_meter.as_str() else { return unreadable() };
        payload.set("recommendedSlot", payload.g("recommendations")?.gd(default_meter)?)?;
    }
    Ok(conflicts.into_iter().map(|(id, _)| id).collect())
}

/// What is shown for a provider while it cannot be read. Its
/// accounts stay listed, and none of them is called fresh or in use.
pub fn registered_failure(registration: &V, previous: &V, reason: &str, failure_code: Option<&str>) -> R<V> {
    let driver = provider_driver(&registration.g("driver")?)?;
    if driver.g("provider")?.eq_s("codex")? {
        return codex_failure(previous, reason, &failure_code.map_or(V::Null, V::from));
    }
    let payload = if previous.t()? { registry::copy(previous)? } else { obj! {"slots" => Vec::<V>::new()} };
    for slot in filter(&payload.g("slots")?.each(), |slot| slot.t())? {
        slot.add_member("fresh", false.into(), true)?;
        slot.add_member("active", false.into(), true)?;
        slot.add_member("status", reason.into(), true)?;
    }
    let Some(name) = registration.g("name")?.as_str().map(str::to_string) else { return unreadable() };
    payload.add_member("active", 0.into(), true)?;
    payload.add_member("verdict", format!("{name} unavailable: {reason}").into(), true)?;
    payload.add_member("hold", V::Null, true)?;
    payload.add_member("claudeError", reason.into(), true)?;
    Ok(payload)
}

//! src/provider-registry.ps1: the packaged provider definitions, and the policy and
//! snapshot each provider's own rules are shown.

use crate::obj;
use crate::ps::*;
use std::cell::RefCell;
use std::rc::Rc;

thread_local! {
    static CATALOG: RefCell<Vec<V>> = const { RefCell::new(Vec::new()) };
}
/// The packaged definitions in Get-Hotpl8ProviderCatalog's order: display order, then id.
pub fn set_catalog(definitions: Vec<V>) {
    CATALOG.with(|cell| *cell.borrow_mut() = definitions);
}
fn catalog() -> Vec<V> {
    CATALOG.with(|cell| cell.borrow().clone())
}

/// Copy-Hotpl8ProviderValue: a round trip through JSON text. Values read from a file come
/// back as they were; numbers PowerShell made itself come back as the edition reads them.
pub fn copy(value: &V) -> R<V> {
    copy_carrying(value, &[])
}
/// The same copy, with the named top-level members carried over as they are.
fn copy_carrying(value: &V, carried: &[&str]) -> R<V> {
    Ok(match value {
        V::Null | V::Bool(_) | V::Str(_) => value.clone(),
        V::I32(x) if desktop() => V::I32(*x),
        V::I32(x) => V::I64(i64::from(*x)),
        V::I64(x) if desktop() => i32::try_from(*x).map(V::I32).unwrap_or(V::I64(*x)),
        V::I64(x) => V::I64(*x),
        // Windows PowerShell reads its own text for a double back as a decimal.
        V::Dbl(_) if desktop() => return decline(),
        V::Dbl(x) => V::Dbl(*x),
        V::Dec(x) if desktop() && x.scale > 0 => V::Dec(*x),
        V::Dec(x) if desktop() && x.mant > i64::MAX as u128 => V::Dec(*x),
        V::Dec(_) => return decline(),
        V::Arr(items) => V::Arr(Rc::new(items.iter().map(copy).collect::<R<Vec<V>>>()?)),
        V::Obj(o) => {
            let mut items = Vec::new();
            for (name, member) in o.borrow().items.iter() {
                let kept = carried.iter().any(|skip| name.eq_ignore_ascii_case(skip));
                items.push((name.clone(), if kept { member.clone() } else { copy(member)? }));
            }
            V::Obj(Rc::new(RefCell::new(Props { items })))
        }
        V::Hash(_) => return decline(),
    })
}

/// Get-Hotpl8ProviderDriver
pub fn provider_driver(id: &V) -> R<V> {
    let id = id.s()?;
    let window = |name: &str, required: bool| obj! {"id" => name, "minutes" => if name == "300" { 300 } else { 10080 }, "required" => required};
    match id.as_str() {
        "claude-cswap" => Ok(obj! {
            "id" => id.as_str(),
            "provider" => "claude",
            "slotKind" => "numeric",
            "healthyPollSeconds" => 60,
            "meters" => vec![V::s_of("claude")],
            "windows" => vec![window("300", true), window("10080", true)],
            "capabilities" => obj! {
                "observation" => true, "enrollment" => true, "selection" => true, "nativeLaunch" => false,
                "warming" => true, "recoveryProbe" => true, "t3Rollover" => false,
            },
            "integrations" => obj! {"native" => "claude", "t3" => "claudeAgent"},
        }),
        "codex-app-server" => Ok(obj! {
            "id" => id.as_str(),
            "provider" => "codex",
            "slotKind" => "native-home",
            "healthyPollSeconds" => 300,
            "meters" => vec![V::s_of("codex"), V::s_of("codex_bengalfox")],
            "windows" => vec![window("300", false), window("10080", false)],
            "capabilities" => obj! {
                "observation" => true, "enrollment" => true, "selection" => true, "nativeLaunch" => true,
                "warming" => false, "recoveryProbe" => false, "t3Rollover" => true,
            },
            "integrations" => obj! {"native" => "codex", "t3" => "codex"},
        }),
        _ if printable(&id) => throw(),
        _ => decline(),
    }
}

/// Get-Hotpl8ProviderDefinition
pub fn provider_definition(id: &str) -> R<V> {
    let wanted = V::s_of(id);
    let matches = filter(&catalog(), |definition| definition.g("id")?.ceq(&wanted))?;
    if matches.len() != 1 {
        return throw();
    }
    copy(&matches[0])
}

/// Get-Hotpl8ProviderControls
fn provider_controls(policy: &V) -> R<V> {
    let controls = obj! {};
    for name in ["schemaVersion", "mode", "switchEnabled", "warm", "probeEnabled", "automation"] {
        if policy.has(name)? {
            controls.add_member(name, copy(&policy.g(name)?)?, true)?;
        }
    }
    Ok(controls)
}

const LEGACY: [&str; 23] = [
    "prefer", "reserve", "labels", "weights", "disabled", "claudeModels", "capacity", "critical", "codex", "order", "pattern",
    "margin5h", "margin7d", "margin7dWork", "hysteresis", "warmMin7d", "warmMin7dWork", "maxUsageAgeS", "staleQuarantineS",
    "warmFloorMin", "warmPhaseWindowMin", "warmGroup", "resetLeadMin",
];

/// Get-Hotpl8ConfiguredProviders
pub fn configured_providers(policy: &V, include_unconfigured: bool) -> R<Vec<V>> {
    if !policy.is_obj() {
        return throw();
    }
    // In-memory callers may have nested dictionaries inside a policy object.
    // Normalize their representation without mutating the supplied object.
    let policy = copy(policy)?;
    if policy.has("schemaVersion")? {
        let version = policy.g("schemaVersion")?;
        if version.n().is_none() || !version.is_in_list(&[V::I32(1), V::I32(2), V::I32(3)])? {
            return throw();
        }
    }
    let mut configured: Vec<(String, V)> = Vec::new();
    if policy.g("schemaVersion")?.eq_i(3)? {
        let providers = policy.g("providers")?;
        if !providers.is_obj() {
            return throw();
        }
        // Reject even empty legacy fields: there must be one unambiguous owner.
        for (name, _) in policy.props()? {
            if V::s_of(&name).in_s(&LEGACY)? {
                return throw();
            }
        }
        let entries = providers.props()?;
        if entries.len() > 32 {
            return throw();
        }
        for (name, value) in entries {
            let definition = provider_definition(&name)?;
            if !value.is_obj() {
                return throw();
            }
            let part = copy(&definition.g("policyDefaults")?)?;
            for (member, item) in value.props()? {
                part.add_member(&member, copy(&item)?, true)?;
            }
            let driver = provider_driver(&definition.g("driver")?)?;
            if driver.g("provider")?.eq_s("codex")? {
                if part.has("modelMeters")? && !part.g("modelMeters")?.is_obj() {
                    return throw();
                }
                if !part.has("defaultMeter")? {
                    part.add_member("defaultMeter", definition.g("defaultMeter")?, false)?;
                }
                let meter = part.g("defaultMeter")?;
                if !meter.is_str() || !meter.is_cin_list(&definition.g("meters")?.arr())? {
                    return throw();
                }
            }
            configured.push((name.to_string(), part));
        }
    } else {
        if policy.has("providers")? {
            return throw();
        }
        if policy.has("prefer")? {
            configured.push(("claude".to_string(), copy(&policy)?));
        }
        if policy.has("codex")? {
            if !policy.g("codex")?.is_obj() {
                return throw();
            }
            configured.push(("codex".to_string(), copy(&policy.g("codex")?)?));
        }
    }
    let mut out = Vec::new();
    for definition in catalog() {
        let id = definition.g("id")?;
        let part = configured.iter().find(|(key, _)| id.as_str() == Some(key.as_str())).map(|(_, part)| part.clone());
        if part.is_none() && !include_unconfigured {
            continue;
        }
        let is_configured = part.is_some();
        out.push(obj! {
            "id" => &id,
            "name" => definition.g("name")?,
            "driver" => definition.g("driver")?,
            "definition" => copy(&definition)?,
            "policy" => part,
            "controls" => provider_controls(&policy)?,
            "configured" => is_configured,
            "isLegacy" => policy.g("schemaVersion")?.ne(&V::I32(3))?,
        });
    }
    Ok(out)
}

/// Get-Hotpl8ConfiguredProvider
fn configured_provider(policy: &V, provider: &str, include_unconfigured: bool) -> R<V> {
    provider_definition(provider)?;
    let matches = filter(&configured_providers(policy, include_unconfigured)?, |r| r.g("id")?.ceq_s(provider))?;
    if matches.len() != 1 {
        return throw();
    }
    Ok(matches[0].clone())
}

/// Get-Hotpl8ProviderView. `carried` names snapshot members the caller never reads from the
/// view: they are passed through instead of being copied.
pub fn provider_view(snapshot: &V, policy: &V, provider: &str, carried: &[&str]) -> R<V> {
    let r = configured_provider(policy, provider, true)?;
    let driver = provider_driver(&r.g("driver")?)?;
    let part = if r.g("policy")?.t()? { copy(&r.g("policy")?)? } else { obj! {} };
    let native_policy = copy(&r.g("controls")?)?;
    let family = driver.g("provider")?.s()?;
    // Native adapters retain their existing shapes behind this compatibility
    // boundary. Provider IDs elsewhere remain the registered ID, never this key.
    if family == "claude" {
        for (name, value) in part.props()? {
            native_policy.add_member(&name, copy(&value)?, true)?;
        }
        native_policy.remove_member("codex")?;
    } else {
        native_policy.add_member("codex", part, true)?;
    }
    if policy.g("schemaVersion")?.eq_i(3)? {
        native_policy.add_member("schemaVersion", V::I32(2), true)?;
    }
    for key in ["historyEnabled", "notificationsEnabled", "display"] {
        if policy.has(key)? {
            native_policy.add_member(key, copy(&policy.g(key)?)?, true)?;
        }
    }
    let native_snapshot = if snapshot.t()? { copy_carrying(snapshot, carried)? } else { obj! {} };
    let payload = if provider == "claude" && !snapshot.path(&["providers", "claude"])?.t()? {
        snapshot.clone()
    } else {
        snapshot.g("providers")?.g(provider)?
    };
    if family == "claude" {
        for key in ["slots", "active", "decision", "hold", "critical", "verdict", "proposedSlot"] {
            native_snapshot.add_member(key, copy(&payload.g(key)?)?, true)?;
        }
        native_snapshot.add_member("providers", obj! {}, true)?;
    } else {
        native_snapshot.add_member("slots", Vec::<V>::new().into(), true)?;
        native_snapshot.add_member("providers", obj! {"codex" => copy(&payload)?}, true)?;
    }
    let collector = native_snapshot.g("collector")?;
    if collector.t()? {
        let observed = copy(&snapshot.g("collector")?.g("providers")?.g(provider)?)?;
        collector.add_member("providers", obj! {family.as_str() => observed}, true)?;
    }
    Ok(obj! {
        "providerId" => provider,
        "provider" => family.as_str(),
        "driver" => driver,
        "registration" => r,
        "policy" => native_policy,
        "snapshot" => native_snapshot,
    })
}

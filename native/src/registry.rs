//! src/provider-registry.ps1: the provider definitions a release ships, and the policy and
//! snapshot each provider's own rules are shown.

use crate::json;
use crate::obj;
use crate::ps::*;
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

thread_local! {
    static SOURCE: RefCell<PathBuf> = RefCell::new(PathBuf::new());
    static CATALOG: RefCell<Option<Vec<V>>> = const { RefCell::new(None) };
}
/// The directory of definitions this request's release ships. They are read when a rule
/// first asks for them, which is where PowerShell calls Get-Hotpl8ProviderCatalog: a state
/// that needs no definition is shown by a copy that has none.
pub fn set_source(directory: PathBuf) {
    SOURCE.with(|cell| *cell.borrow_mut() = directory);
    CATALOG.with(|cell| *cell.borrow_mut() = None);
}
pub fn catalog() -> R<Vec<V>> {
    if let Some(known) = CATALOG.with(|cell| cell.borrow().clone()) {
        return Ok(known);
    }
    let read = read_catalog(&SOURCE.with(|cell| cell.borrow().clone()))?;
    CATALOG.with(|cell| *cell.borrow_mut() = Some(read.clone()));
    Ok(read)
}

fn unlisted<T>(error: std::io::Error) -> R<T> {
    unreadable_as(format!("The provider definitions of this copy cannot be listed: {error}."))
}
/// What `Get-ChildItem -Filter '*.json' -File` lists: no directory and no hidden file.
fn listed(entry: &std::fs::DirEntry, name: &str) -> R<bool> {
    // The filter ignores case wherever the platform's file names do.
    let json = if cfg!(target_os = "linux") { name.ends_with(".json") } else { name.to_ascii_lowercase().ends_with(".json") };
    if !json || !entry.path().is_file() {
        return Ok(false);
    }
    #[cfg(windows)]
    let hidden = std::os::windows::fs::MetadataExt::file_attributes(&entry.metadata().or_else(unlisted)?) & 2 != 0;
    #[cfg(not(windows))]
    let hidden = name.starts_with('.');
    Ok(!hidden)
}

/// Get-Hotpl8ProviderCatalog: every definition in the directory, checked, in display order
/// and then by id.
fn read_catalog(directory: &Path) -> R<Vec<V>> {
    if !directory.is_dir() {
        return fail("Packaged provider catalog is missing.");
    }
    let mut files = Vec::new();
    for entry in std::fs::read_dir(directory).or_else(unlisted)? {
        let entry = entry.or_else(unlisted)?;
        let Ok(name) = entry.file_name().into_string() else { return unreadable() };
        if listed(&entry, &name)? {
            files.push(name);
        }
    }
    files.sort();
    if files.is_empty() || files.len() > 32 {
        return fail("Invalid provider catalog size.");
    }
    let mut definitions = Vec::with_capacity(files.len());
    let mut seen = Keys::new();
    for name in &files {
        let file = directory.join(name);
        if std::fs::metadata(&file).or_else(unlisted)?.len() > 131_072 {
            return fail("Provider definition exceeds size limit.");
        }
        // A file that is not JSON is refused by its name and the place it stops being JSON,
        // where PowerShell says "Invalid provider definition JSON."
        let Some(definition) = json::read_file(&file)? else { return unreadable() };
        assert_definition(&definition)?;
        let id = definition.g("id")?.s()?;
        if name[..name.len() - ".json".len()] != id || seen.contains(&id)? {
            return fail("Duplicate provider ID or mismatched definition filename.");
        }
        seen.insert(&id)?;
        definitions.push(definition);
    }
    let order = |left: &V, right: &V| match order_keys(&left.path(&["display", "order"])?, &right.path(&["display", "order"])?)? {
        std::cmp::Ordering::Equal => order_keys(&left.g("id")?, &right.g("id")?),
        decided => Ok(decided),
    };
    sort(&definitions, order, |_, _| false)
}

/// Assert-Hotpl8ProviderObject
fn assert_object(value: &V, allowed: &[&str], required: &[&str]) -> R<()> {
    if !value.is_obj() {
        return fail("Invalid provider definition: expected an object.");
    }
    for (name, _) in value.props()? {
        if !allowed.contains(&&*name) {
            return fail("Invalid provider definition: unknown field.");
        }
    }
    for name in required {
        if !value.has(name)? {
            return fail("Invalid provider definition: missing field.");
        }
    }
    Ok(())
}
/// `$id -cmatch '^[a-z][a-z0-9-]{0,39}$'`. The pattern's `$` also matches before a final
/// line feed.
fn provider_id(text: &str) -> bool {
    let body = text.strip_suffix('\n').unwrap_or(text);
    body.len() <= 40 && body.starts_with(|first: char| first.is_ascii_lowercase()) && body.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Assert-Hotpl8ProviderDefinition
fn assert_definition(definition: &V) -> R<()> {
    const FIELDS: [&str; 12] = [
        "schemaVersion", "id", "name", "driver", "defaultMeter", "meters", "windows", "policyDefaults", "modelMeters", "capabilities",
        "integrations", "display",
    ];
    let required: Vec<&str> = FIELDS.into_iter().filter(|field| *field != "modelMeters").collect();
    assert_object(definition, &FIELDS, &required)?;
    let version = definition.g("schemaVersion")?;
    if !version.is_number() || version.ne(&V::I32(1))? {
        return fail("Invalid provider definition version.");
    }
    let id = definition.g("id")?;
    if !id.as_str().is_some_and(provider_id) {
        return fail("Invalid provider ID.");
    }
    let name = definition.g("name")?;
    let Some(shown) = name.as_str() else { return fail("Invalid provider display name.") };
    if blank(shown)? || length(shown) > 80 || has_control(shown) {
        return fail("Invalid provider display name.");
    }
    if !definition.g("driver")?.is_str() {
        return fail("Invalid provider driver.");
    }
    let driver = provider_driver(&definition.g("driver")?)?;
    for legacy in ["claude", "codex"] {
        if id.ceq_s(legacy)? && driver.g("provider")?.cne(&V::s_of(legacy))? {
            return fail("Legacy provider IDs must retain their native driver.");
        }
    }
    let meters = definition.g("meters")?;
    if !meters.is_arr() || meters.arr().is_empty() || meters.arr().len() > 8 {
        return fail("Invalid provider meters.");
    }
    let native_meters = driver.g("meters")?.arr();
    let mut seen = Keys::new();
    for meter in meters.arr() {
        let Some(text) = meter.as_str() else { return fail("Unsupported or duplicate provider meter.") };
        if !meter.is_cin_list(&native_meters)? || seen.contains(text)? {
            return fail("Unsupported or duplicate provider meter.");
        }
        seen.insert(text)?;
    }
    let default_meter = definition.g("defaultMeter")?;
    if !default_meter.is_str() || !default_meter.is_cin_list(&meters.arr())? {
        return fail("Invalid provider default meter.");
    }
    // A definition may narrow supported meters but cannot weaken window evidence.
    let windows = definition.g("windows")?;
    let native_windows = driver.g("windows")?.arr();
    if !windows.is_arr() || windows.arr().len() != native_windows.len() {
        return fail("Invalid provider windows.");
    }
    let mut seen = Keys::new();
    for window in windows.arr() {
        assert_object(&window, &["id", "minutes", "required"], &["id", "minutes", "required"])?;
        let mismatch = || fail("Provider windows do not match the native contract.");
        let window_id = window.g("id")?;
        let Some(text) = window_id.as_str() else { return mismatch() };
        let native = filter(&native_windows, |item| item.g("id")?.ceq(&window_id))?;
        if native.len() != 1 || seen.contains(text)? {
            return mismatch();
        }
        let (minutes, needed) = (window.g("minutes")?, window.g("required")?);
        if !minutes.is_number() || minutes.ne(&native[0].g("minutes")?)? || !needed.is_bool() || needed.ne(&native[0].g("required")?)? {
            return mismatch();
        }
        seen.insert(text)?;
    }
    let defaults = definition.g("policyDefaults")?;
    assert_object(&defaults, &["order", "margin5h", "margin7d", "margin7dWork", "hysteresis", "resetLeadMin"], &[])?;
    for (name, value) in defaults.props()? {
        if &*name == "order" {
            let orders = ["prefer", "soonest-reset", "weekly-expiry", "balanced"].map(V::s_of);
            if !value.is_str() || !value.is_cin_list(&orders)? {
                return fail("Invalid provider default ordering.");
            }
        } else {
            let max = if &*name == "resetLeadMin" { 604_800 } else { 100 };
            if !value.is_number() || value.lt_i(0)? || value.gt_i(max)? {
                return fail("Invalid provider default threshold.");
            }
        }
    }
    // Optional legacy metadata is never used for native account selection.
    if definition.has("modelMeters")? {
        let models = definition.g("modelMeters")?;
        if !models.is_obj() || models.props()?.len() > 256 {
            return fail("Invalid provider model mappings.");
        }
    }
    let implemented = driver.g("capabilities")?;
    let known = implemented.props()?;
    let known: Vec<&str> = known.iter().map(|(name, _)| &**name).collect();
    let capabilities = definition.g("capabilities")?;
    assert_object(&capabilities, &known, &known)?;
    for (name, value) in capabilities.props()? {
        if !value.is_bool() || (value.t()? && !implemented.gd(&name)?.t()?) {
            return fail("Provider capability is not implemented by its driver.");
        }
    }
    let integrations = definition.g("integrations")?;
    assert_object(&integrations, &["native", "t3"], &[])?;
    for (name, value) in integrations.props()? {
        if !value.is_str() || value.cne(&driver.g("integrations")?.gd(&name)?)? {
            return fail("Provider integration does not match the native driver.");
        }
    }
    if capabilities.g("t3Rollover")?.t()? && !integrations.g("t3")?.t()? {
        return fail("T3 rollover requires a supported T3 integration.");
    }
    let display = definition.g("display")?;
    assert_object(&display, &["order"], &["order"])?;
    let order = display.g("order")?;
    if !order.is_number() || order.lt_i(0)? || order.gt_i(10_000)? || order.floor()?.ne(&order)? {
        return fail("Invalid provider display ordering.");
    }
    Ok(())
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
        // Windows PowerShell reads its own text for a double back by the text's shape:
        // a whole number, a decimal, or with an exponent a double again.
        V::Dbl(x) if desktop() => json::number(&crate::num::double_json(*x))?,
        V::Dbl(x) => V::Dbl(*x),
        V::Dec(x) if desktop() && x.scale > 0 => V::Dec(*x),
        V::Dec(x) if desktop() && x.mant > i64::MAX as u128 => V::Dec(*x),
        V::Dec(_) => return unreadable(),
        V::Arr(items) => V::Arr(Rc::new(items.iter().map(copy).collect::<R<Vec<V>>>()?)),
        V::Obj(o) => {
            let mut items = Vec::new();
            for (name, member) in o.borrow().items.iter() {
                let kept = carried.iter().any(|skip| name.eq_ignore_ascii_case(skip));
                items.push((name.clone(), if kept { member.clone() } else { copy(member)? }));
            }
            V::Obj(Rc::new(RefCell::new(Props { items })))
        }
        V::Hash(_) => return unreadable(),
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
        _ if printable(&id) => fail("Unknown provider driver. Only shipped native contracts may be registered."),
        _ => unreadable(),
    }
}

/// Get-Hotpl8ProviderDefinition
pub fn provider_definition(id: &str) -> R<V> {
    let wanted = V::s_of(id);
    let matches = filter(&catalog()?, |definition| definition.g("id")?.ceq(&wanted))?;
    if matches.len() != 1 {
        return fail("Provider is not registered.");
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
        return fail("Provider configuration requires a policy object.");
    }
    // In-memory callers may have nested dictionaries inside a policy object.
    // Normalize their representation without mutating the supplied object.
    let policy = copy(policy)?;
    if policy.has("schemaVersion")? {
        let version = policy.g("schemaVersion")?;
        if version.n().is_none() || !version.is_in_list(&[V::I32(1), V::I32(2), V::I32(3)])? {
            return fail("Unsupported provider policy version.");
        }
    }
    let catalog = catalog()?;
    let mut configured: Vec<(String, V)> = Vec::new();
    if policy.g("schemaVersion")?.eq_i(3)? {
        let providers = policy.g("providers")?;
        if !providers.is_obj() {
            return fail("Policy version 3 requires a providers map.");
        }
        // Reject even empty legacy fields: there must be one unambiguous owner.
        for (name, _) in policy.props()? {
            if V::s_of(&name).in_s(&LEGACY)? {
                return fail("Policy version 3 cannot mix legacy and registered provider settings.");
            }
        }
        let entries = providers.props()?;
        if entries.len() > 32 {
            return fail("Too many configured providers.");
        }
        for (name, value) in entries {
            let definition = provider_definition(&name)?;
            if !value.is_obj() {
                return fail("Provider policy must be an object.");
            }
            let part = copy(&definition.g("policyDefaults")?)?;
            for (member, item) in value.props()? {
                part.add_member(&member, copy(&item)?, true)?;
            }
            let driver = provider_driver(&definition.g("driver")?)?;
            if driver.g("provider")?.eq_s("codex")? {
                if part.has("modelMeters")? && !part.g("modelMeters")?.is_obj() {
                    return fail("Invalid provider model mappings.");
                }
                if !part.has("defaultMeter")? {
                    part.add_member("defaultMeter", definition.g("defaultMeter")?, false)?;
                }
                let meter = part.g("defaultMeter")?;
                if !meter.is_str() || !meter.is_cin_list(&definition.g("meters")?.arr())? {
                    return fail("Configured meter is not supported by the provider definition.");
                }
            }
            configured.push((name.to_string(), part));
        }
    } else {
        if policy.has("providers")? {
            return fail("Registered provider configuration requires policy version 3.");
        }
        if policy.has("prefer")? {
            configured.push(("claude".to_string(), copy(&policy)?));
        }
        if policy.has("codex")? {
            if !policy.g("codex")?.is_obj() {
                return fail("Codex policy must be an object.");
            }
            configured.push(("codex".to_string(), copy(&policy.g("codex")?)?));
        }
        for (id, _) in &configured {
            let mut registered = false;
            for definition in &catalog {
                registered |= definition.g("id")?.as_str() == Some(id.as_str());
            }
            if !registered {
                return fail("Configured legacy provider is missing from the catalog.");
            }
        }
    }
    let mut out = Vec::new();
    for definition in catalog {
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
pub fn configured_provider(policy: &V, provider: &str, include_unconfigured: bool) -> R<V> {
    provider_definition(provider)?;
    let matches = filter(&configured_providers(policy, include_unconfigured)?, |r| r.g("id")?.ceq_s(provider))?;
    if matches.len() != 1 {
        return fail("Provider is not configured.");
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

/// Get-Hotpl8ProviderStateDirectory: a provider named as its family keeps its state in the
/// state directory itself, any other in a directory of its own.
pub fn provider_state_directory(directory: &Path, provider: &str) -> R<PathBuf> {
    let definition = provider_definition(provider)?;
    let driver = provider_driver(&definition.g("driver")?)?;
    if driver.g("provider")?.ceq_s(provider)? {
        return Ok(directory.to_path_buf());
    }
    Ok(directory.join("providers").join(provider))
}

/// How many accounts Get-Hotpl8ProviderAccounts lists for one configured provider.
pub fn provider_account_count(registration: &V) -> R<usize> {
    let driver = provider_driver(&registration.g("driver")?)?;
    let part = registration.g("policy")?;
    if driver.g("slotKind")?.eq_s("numeric")? {
        return Ok(part.g("prefer")?.arr().len());
    }
    Ok(filter(&part.g("slots")?.each(), |slot| slot.t())?.len())
}

/// One account a policy configures.
pub struct Account {
    pub provider: String,
    pub slot: String,
    pub label: V,
}

/// One account as its provider's part of the policy names it.
struct Named {
    provider: V,
    part: V,
    id: V,
    slot: String,
    label: V,
}

/// The accounts of every configured provider, in the order the policy gives them.
fn named_accounts(policy: &V) -> R<Vec<Named>> {
    let mut accounts = Vec::new();
    for registration in configured_providers(policy, false)? {
        let driver = provider_driver(&registration.g("driver")?)?;
        let (provider, part) = (registration.g("id")?, registration.g("policy")?);
        if driver.g("slotKind")?.eq_s("numeric")? {
            for id in part.g("prefer")?.arr() {
                let slot = id.s()?;
                let label = part.g("labels")?.gd(&slot)?;
                accounts.push(Named { provider: provider.clone(), part: part.clone(), id, slot, label });
            }
        } else {
            for row in filter(&part.g("slots")?.each(), |slot| slot.t())? {
                accounts.push(Named { provider: provider.clone(), part: part.clone(), id: row.g("id")?, slot: row.g("id")?.s()?, label: row.g("label")? });
            }
        }
    }
    Ok(accounts)
}

/// Get-Hotpl8ProviderAccounts: who each account is, in the order the policy gives them.
pub fn provider_accounts(policy: &V) -> R<Vec<Account>> {
    named_accounts(policy)?.into_iter().map(|named| Ok(Account { provider: named.provider.s()?, slot: named.slot, label: named.label })).collect()
}

/// Get-Hotpl8ProviderAccounts, each account the row a PowerShell command is given.
pub fn provider_account_rows(policy: &V) -> R<Vec<V>> {
    let row = |named: &Named| {
        Ok(obj! {
            "provider" => &named.provider,
            "slot" => named.slot.as_str(),
            "label" => &named.label,
            "capacity" => named.part.g("capacity")?.gd(&named.slot)?,
            "disabled" => named.id.is_in(&named.part.g("disabled")?)?,
            "reserve" => named.id.is_in(&named.part.g("reserve")?)?,
        })
    };
    named_accounts(policy)?.iter().map(row).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const CODEX: &str = include_str!("../../data/providers/codex.json");

    /// The Codex definition with one piece of its text changed.
    fn edited(old: &str, new: &str) -> String {
        assert_eq!(CODEX.matches(old).count(), 1, "{old}");
        CODEX.replace(old, new)
    }
    fn renamed(id: &str, order: &str) -> String {
        edited("\"id\": \"codex\"", &format!("\"id\": \"{id}\"")).replace("\"order\": 20", &format!("\"order\": {order}"))
    }
    /// The ids a directory of these files registers, in order, or why it registers none.
    fn registered(label: &str, files: &[(&str, String)]) -> Result<Vec<String>, String> {
        let directory = std::env::temp_dir().join(format!("hotpl8-native-catalog-{label}-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        for (name, text) in files {
            std::fs::write(directory.join(name), text).unwrap();
        }
        let read = ids(read_catalog(&directory));
        std::fs::remove_dir_all(&directory).unwrap();
        read
    }
    fn ids(catalog: R<Vec<V>>) -> Result<Vec<String>, String> {
        match catalog {
            Ok(definitions) => Ok(definitions.iter().map(|definition| definition.g("id").ok().unwrap().s().ok().unwrap()).collect()),
            Err(stop) => Err(stop.message()),
        }
    }

    #[test]
    fn the_definitions_a_release_ships_are_read_in_display_order() {
        let shipped = Path::new(env!("CARGO_MANIFEST_DIR")).join("../data/providers");
        assert_eq!(ids(read_catalog(&shipped)), Ok(vec!["claude".to_owned(), "codex".to_owned()]));
    }

    #[test]
    fn a_definition_added_to_a_copy_is_registered() {
        let directory = std::env::temp_dir().join(format!("hotpl8-native-catalog-added-{}", std::process::id()));
        std::fs::create_dir_all(directory.join("kept.json")).unwrap();
        std::fs::write(directory.join("notes.txt"), "not a definition").unwrap();
        for (name, text) in [
            ("codex.json", CODEX.to_owned()),
            ("fictional.json", renamed("fictional", "30")),
            ("zeta.json", renamed("zeta", "5")),
            ("codex-two.json", renamed("codex-two", "20")),
        ] {
            std::fs::write(directory.join(name), text).unwrap();
        }
        // Display order first, then the id; a directory and a file of another kind are no definitions.
        assert_eq!(ids(read_catalog(&directory)), Ok(["zeta", "codex", "codex-two", "fictional"].map(str::to_owned).to_vec()));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn a_definition_the_rules_refuse_is_refused_in_their_words() {
        let one = |label: &str, text: String| registered(label, &[("codex.json", text)]).unwrap_err();
        for (label, old, new, said) in [
            ("driver", "\"driver\": \"codex-app-server\"", "\"driver\": \"shell\"", "Unknown provider driver. Only shipped native contracts may be registered."),
            ("field", "\"schemaVersion\": 1,", "\"schemaVersion\": 1, \"command\": \"run\",", "Invalid provider definition: unknown field."),
            ("version", "\"schemaVersion\": 1,", "\"schemaVersion\": \"1\",", "Invalid provider definition version."),
            ("id", "\"id\": \"codex\"", "\"id\": \"Codex\"", "Invalid provider ID."),
            ("name", "\"name\": \"Codex\"", "\"name\": \" \"", "Invalid provider display name."),
            ("legacy", "\"driver\": \"codex-app-server\"", "\"driver\": \"claude-cswap\"", "Legacy provider IDs must retain their native driver."),
            ("meter", "\"defaultMeter\": \"codex\"", "\"defaultMeter\": \"claude\"", "Invalid provider default meter."),
            ("window", "\"minutes\": 300, \"required\": false", "\"minutes\": 300, \"required\": true", "Provider windows do not match the native contract."),
            ("threshold", "\"margin5h\": 25", "\"margin5h\": 101", "Invalid provider default threshold."),
            ("capability", "\"warming\": false", "\"warming\": true", "Provider capability is not implemented by its driver."),
            ("integration", "\"t3\": \"codex\"", "\"t3\": \"claudeAgent\"", "Provider integration does not match the native driver."),
            ("order", "\"order\": 20", "\"order\": 2.5", "Invalid provider display ordering."),
        ] {
            assert_eq!(one(label, edited(old, new)), said, "{label}");
        }
        assert_eq!(registered("filename", &[("fictional.json", CODEX.to_owned())]).unwrap_err(), "Duplicate provider ID or mismatched definition filename.");
        assert_eq!(registered("empty", &[]).unwrap_err(), "Invalid provider catalog size.");
        assert_eq!(registered("large", &[("codex.json", format!("{CODEX}{}", " ".repeat(131_072)))]).unwrap_err(), "Provider definition exceeds size limit.");
        assert_eq!(one("json", "codex".to_owned()), "codex.json is not JSON as HotPl8 writes it (line 1, column 1).");
        assert_eq!(ids(read_catalog(Path::new("no-such-directory"))).unwrap_err(), "Packaged provider catalog is missing.");
    }
}

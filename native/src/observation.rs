//! src/provider-observation.ps1: native and public shapes enter the observation contract
//! here. These decoders do not read state, fetch quota, select accounts or own credentials.

use crate::ps::*;
use crate::time::Dto;
use crate::{hash, obj};

/// ConvertTo-Hotpl8ClaudeObservation
pub fn claude_observation(slot: &V, policy: &V) -> R<V> {
    let mut windows = Vec::new();
    for shape in [["300", "short", "used5h", "reset5h"], ["10080", "weekly", "used7d", "reset7d"]] {
        let used = slot.g(shape[2])?;
        let reset = slot.g(shape[3])?;
        windows.push(obj! {
            "name" => shape[0],
            "scope" => "",
            "role" => shape[1],
            "state" => if used.is_null() { "unknown" } else { "observed" },
            "required" => true,
            "usedPercent" => &used,
            "resetAt" => &reset,
            "observedAt" => slot.g("observedAt")?,
            "resetConfirmed" => reset.t()?,
            "resetRequired" => shape[1] == "weekly" || used.ne(&V::I32(0))?,
        });
    }
    for model in filter(&policy.g("claudeModels")?.arr(), |model| model.t())? {
        let scopes = filter(&slot.g("scoped")?.arr(), |scope| scope.g("name")?.ceq(&model))?;
        let scope = if scopes.len() == 1 { scopes[0].clone() } else { V::Null };
        windows.push(obj! {
            "name" => model.sv()?,
            "scope" => model.sv()?,
            "role" => "scoped",
            "state" => if scope.t()? { "observed" } else { "unknown" },
            "required" => true,
            "usedPercent" => scope.g("pct")?,
            "resetAt" => scope.g("resetsAt")?,
            "observedAt" => slot.g("observedAt")?,
            "resetConfirmed" => scope.g("resetsAt")?.t()?,
            "resetRequired" => true,
        });
    }
    let status = slot.g("status")?;
    let status = if status.t()? && status.ne_s("ok")? {
        status.sv()?
    } else if slot.g("fresh")?.is_false()? {
        "stale".into()
    } else {
        "ok".into()
    };
    Ok(obj! {
        "id" => slot.g("slot")?.sv()?,
        "status" => status,
        "observedAt" => slot.g("observedAt")?,
        "identityKey" => slot.g("streamKey")?.sv()?,
        "windows" => windows,
        "blockedReason" => slot.g("modelReason")?,
    })
}

/// ConvertTo-Hotpl8ClaudeEntryObservation without -ForWarm. The status path always
/// supplies the entry's observation; the legacy headroom shape is not modelled.
pub fn claude_entry_observation(entry: &V) -> R<V> {
    let observation = entry.g("observation")?;
    if !observation.t()? {
        return unreadable();
    }
    Ok(observation)
}

/// ConvertTo-Hotpl8CodexObservation
pub fn codex_observation(slot: &V, meter: &str) -> R<V> {
    let bucket = slot.g("buckets")?.gd(meter)?;
    let mut windows = Vec::new();
    let mut malformed = false;
    for (name, w) in bucket.g("windows")?.props()? {
        let mut reset = V::Null;
        // Published used/remaining values describe one observation. A stale or
        // corrupted mirror cannot authorize work by choosing its happier half.
        let (used, left) = (w.g("usedPercent")?, w.g("remainingPercent")?);
        if !used.is_number() || !left.is_number() || left.lt_i(0)? || left.gt_i(100)? || ((used.dbl()? + left.dbl()?) - 100.0).abs() > 0.000001 {
            malformed = true;
        }
        if !w.g("resetsAt")?.is_null() {
            reset = match catch(|| Ok(Dto::from_unix_seconds(w.g("resetsAt")?.to_long()?)?.o()))? {
                Some(text) => text.into(),
                None => "invalid".into(),
            };
        }
        // Legacy snapshots stamped the enclosing account only. Inherit that
        // original observation, never the current clock or a newer collector time.
        let has_stamp = if !w.t()? {
            false
        } else {
            match &w {
                V::Obj(_) => w.has("observedAt")?,
                V::Arr(_) | V::Hash(_) => return unreadable(),
                _ => false,
            }
        };
        let stamp = if has_stamp { w.g("observedAt")? } else { slot.g("observedAt")? };
        let role = if text_eq(&name, "300")? {
            "short"
        } else if text_eq(&name, "10080")? {
            "weekly"
        } else {
            "scoped"
        };
        windows.push(obj! {
            "name" => &*name,
            "scope" => meter,
            "role" => role,
            "state" => "observed",
            "required" => true,
            "usedPercent" => used,
            "resetAt" => reset,
            "observedAt" => stamp,
            "resetConfirmed" => w.g("anchorState")?.eq_s("observed-active")?,
        });
    }
    let blocked: V = if !bucket.t()? {
        "meter_unknown".into()
    } else if bucket.g("status")?.ne_s("observed")? {
        bucket.g("status")?.sv()?
    } else if malformed {
        "window_malformed".into()
    } else {
        V::Null
    };
    Ok(obj! {
        "id" => slot.g("id")?.sv()?,
        "status" => slot.g("status")?.sv()?,
        "observedAt" => slot.g("observedAt")?,
        "identityKey" => slot.g("streamKey")?.sv()?,
        "windows" => windows,
        "blockedReason" => blocked,
    })
}

/// Add-Hotpl8ObservationCapacity
pub fn add_observation_capacity(observations: &[V], capacity_accounts: &[V]) -> R<Vec<V>> {
    let mut out = Vec::new();
    for observation in observations {
        let copy = observation.shallow()?;
        let id = observation.g("id")?;
        let capacity = filter(capacity_accounts, |account| account.g("slot")?.ceq(&id))?;
        if capacity.len() == 1 {
            copy.add_member("capacity", hash! {"scaled" => capacity[0].g("scaled")?, "gross" => capacity[0].g("gross")?}, true)?;
        }
        out.push(copy);
    }
    Ok(out)
}

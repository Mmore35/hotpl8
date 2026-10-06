//! src/leases.ps1 and Get-Hotpl8Pause of src/automation.ps1: what is holding automation
//! back. Only the reading side is here; nothing writes a ledger.

use crate::json;
use crate::obj;
use crate::ps::*;
use crate::time::Dto;
use std::io::ErrorKind;
use std::path::Path;

const DAY_SECONDS: i64 = 86_400;

/// Test-Hotpl8LeaseId, giving the id in the one case the ledger's key table compares.
fn lease_id(value: &V) -> R<Option<String>> {
    let Some(text) = value.as_str() else { return Ok(None) };
    // The pattern's `$` also accepts a final line feed; that spelling is left to PowerShell.
    if has_control(text) {
        return decline();
    }
    let b = text.as_bytes();
    let shaped = b.len() == 36 && b.iter().enumerate().all(|(i, c)| if matches!(i, 8 | 13 | 18 | 23) { *c == b'-' } else { c.is_ascii_hexdigit() });
    if !shaped || text == "00000000-0000-0000-0000-000000000000" {
        return Ok(None);
    }
    Ok(Some(text.to_ascii_lowercase()))
}
/// Test-Hotpl8LeaseOwner
fn lease_owner(value: &V) -> R<bool> {
    let Some(text) = value.as_str() else { return Ok(false) };
    Ok((1..=80).contains(&length(text)) && !blank(text)? && !has_control(text))
}
/// ConvertFrom-Hotpl8LeaseTime
fn lease_time(value: &V) -> R<Dto> {
    let Some(text) = value.as_str() else { return throw() };
    if has_control(text) {
        return decline();
    }
    let lower = text.to_ascii_lowercase();
    if !lower.ends_with('z') && !lower.ends_with("+00:00") {
        return throw();
    }
    Dto::parse(text)
}

/// Read-Hotpl8LeaseLedger. `None` is the ledger PowerShell reports as invalid.
fn read_ledger(directory: &Path) -> R<Option<V>> {
    let path = directory.join("automation-leases.json");
    let file = match std::fs::symlink_metadata(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Some(obj! {"schemaVersion" => 1, "entries" => Vec::<V>::new()})),
        Err(_) => return decline(),
    };
    if file.file_type().is_symlink() {
        return decline();
    }
    if file.is_dir() || file.len() > 262_144 {
        return Ok(None);
    }
    let Some(ledger) = json::read_file(&path)? else { return Ok(None) };
    catch(|| {
        let version = ledger.g("schemaVersion")?;
        let entries = ledger.g("entries")?;
        if !ledger.is_obj() || !matches!(version, V::I32(_) | V::I64(_)) || version.ne(&V::I32(1))? || !entries.is_arr() || entries.arr().len() > 256 {
            return throw();
        }
        for (name, _) in ledger.props()? {
            if !V::s_of(&name).in_s(&["schemaVersion", "entries"])? {
                return throw();
            }
        }
        let mut ids: Vec<String> = Vec::new();
        for entry in entries.each() {
            if !entry.is_obj() {
                return throw();
            }
            let Some(id) = lease_id(&entry.g("leaseId")?)? else { return throw() };
            if ids.contains(&id) {
                return throw();
            }
            ids.push(id);
            let fields = ["leaseId", "owner", "minutes", "acquiredAt", "until", "releasedAt", "retainUntil"];
            let members = entry.props()?;
            if members.len() != fields.len() {
                return throw();
            }
            for (name, _) in members {
                if !V::s_of(&name).in_s(&fields)? {
                    return throw();
                }
            }
            let retain = lease_time(&entry.g("retainUntil")?)?;
            let released = match entry.g("releasedAt")? {
                V::Null => None,
                value => Some(lease_time(&value)?),
            };
            if entry.g("acquiredAt")?.is_null() {
                let Some(released) = released else { return throw() };
                if !entry.g("owner")?.is_null() || !entry.g("minutes")?.is_null() || !entry.g("until")?.is_null() {
                    return throw();
                }
                if retain.ticks < released.plus_seconds(DAY_SECONDS)?.ticks {
                    return throw();
                }
            } else {
                let minutes = entry.g("minutes")?;
                if !lease_owner(&entry.g("owner")?)? || !matches!(minutes, V::I32(_) | V::I64(_)) || minutes.lt_i(1)? || minutes.gt_i(1440)? {
                    return throw();
                }
                let acquired = lease_time(&entry.g("acquiredAt")?)?;
                let until = lease_time(&entry.g("until")?)?;
                if until.ticks != acquired.plus_seconds(minutes.to_long()? * 60)?.ticks || retain.ticks < until.plus_seconds(DAY_SECONDS)?.ticks {
                    return throw();
                }
                if let Some(released) = released {
                    if retain.ticks < released.plus_seconds(DAY_SECONDS)?.ticks {
                        return throw();
                    }
                }
            }
        }
        Ok(ledger.clone())
    })
}

/// Get-Hotpl8LeasePause
fn lease_pause(directory: &Path, now: Dto) -> R<V> {
    let Some(ledger) = read_ledger(directory)? else {
        return Ok(obj! {"until" => V::Null, "reason" => "invalid_leases", "invalid" => true, "leaseCount" => V::Null});
    };
    let mut latest: Option<Dto> = None;
    let mut active = 0i32;
    for entry in ledger.g("entries")?.each() {
        let until = entry.g("until")?;
        if until.is_null() || !entry.g("releasedAt")?.is_null() {
            continue;
        }
        let until = lease_time(&until)?;
        if until.ticks > now.ticks {
            active += 1;
            if latest.is_none_or(|known| until.ticks > known.ticks) {
                latest = Some(until);
            }
        }
    }
    let Some(latest) = latest else { return Ok(V::Null) };
    Ok(obj! {"until" => latest.utc().o(), "reason" => "agent_leases", "invalid" => false, "leaseCount" => active})
}

/// Get-Hotpl8Pause
pub fn pause(directory: &Path, now: Dto) -> R<V> {
    let leases = lease_pause(directory, now)?;
    if leases.g("invalid")?.t()? {
        return Ok(leases);
    }
    let path = directory.join("automation-pause.json");
    let invalid = || obj! {"until" => V::Null, "reason" => "invalid_pause", "invalid" => true};
    let pause = match std::fs::metadata(&path) {
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(leases),
        Err(_) => return decline(),
        Ok(file) if file.is_dir() => return Ok(invalid()),
        Ok(_) => json::read_file(&path)?.unwrap_or(V::Null),
    };
    let found = catch(|| {
        let until = pause.g("until")?;
        if !until.t()? {
            return throw();
        }
        let at = Dto::of(&until)?;
        if at.ticks > now.ticks {
            if !leases.t()? {
                return Ok(Some(pause.clone()));
            }
            let lease_until = leases.g("until")?;
            let later = if at.ticks > Dto::of(&lease_until)?.ticks { until } else { lease_until };
            return Ok(Some(obj! {"until" => later, "reason" => "manual_and_agent_leases", "invalid" => false, "leaseCount" => leases.g("leaseCount")?}));
        }
        Ok(None)
    })?;
    Ok(match found {
        None => invalid(),
        Some(Some(value)) => value,
        Some(None) => leases,
    })
}

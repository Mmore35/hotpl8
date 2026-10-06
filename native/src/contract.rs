//! src/provider-contract.ps1, and Resolve-Hotpl8Window from src/common.ps1.

use crate::ps::*;
use crate::time::Dto;
use crate::{cat, hash, obj};

/// Get-Hotpl8ProviderSetting
#[track_caller]
pub fn setting(policy: &V, name: &str, default: V) -> R<V> {
    let value = policy.g(name)?;
    Ok(if value.is_null() { default } else { value })
}

/// `($Now - [datetimeoffset]::Parse([string]$value)).TotalSeconds` inside try/catch.
pub fn age_seconds(value: &V, now: Dto) -> R<Option<f64>> {
    catch(|| Ok(now.since(Dto::parse(&value.s()?)?).total_seconds()))
}

/// Resolve-Hotpl8Window: a hash table with used, resetAt and rolledOver.
pub fn resolve_window(used: &V, reset_at: &V, observed_at: &V, now: Dto, unix: bool) -> R<V> {
    let result = hash! {"used" => used, "resetAt" => reset_at, "rolledOver" => false};
    if reset_at.is_null() || text_eq(&reset_at.s()?, "")? {
        return Ok(result);
    }
    let parsed = catch(|| if unix { Dto::from_unix_seconds(reset_at.to_long()?) } else { Dto::parse(&reset_at.s()?) })?;
    let Some(at) = parsed else { return Ok(result) };
    if at.ticks > now.ticks {
        return Ok(result);
    }
    if !used.is_number() || used.dbl()? < 0.0 || used.dbl()? > 100.0 {
        return Ok(result);
    }
    let observed = catch(|| if observed_at.t()? { Ok(Some(Dto::parse(&observed_at.s()?)?)) } else { Ok(None) })?.flatten();
    match observed {
        Some(observed) if observed.ticks < at.ticks => Ok(hash! {"used" => V::Dbl(0.0), "resetAt" => V::Null, "rolledOver" => true}),
        _ => Ok(result),
    }
}

/// ConvertTo-Hotpl8ProviderWindow
pub fn provider_window(window: &V, now: Dto, max_age_seconds: f64) -> R<V> {
    let mut reason = V::Null;
    let mut remaining = V::Null;
    let mut reset = V::Null;
    let mut rolled = false;
    let state = window.g("state")?.s()?;
    let name = window.g("name")?;
    let malformed = match name.as_str() {
        None => true,
        Some(text) => blank(text)? || length(text) > 128 || has_control(text),
    } || !window.g("scope")?.is_str()
        || !window.g("role")?.in_s(&["short", "weekly", "scoped"])?
        || !window.g("required")?.is_bool()
        || !V::s_of(&state).in_s(&["observed", "not_applicable", "unknown"])?;
    if malformed {
        reason = "window_malformed".into();
    } else if text_eq(&state, "not_applicable")? {
        if window.g("required")?.is_true()? {
            reason = "window_required".into();
        }
    } else if !text_eq(&state, "observed")? {
        reason = "window_unknown".into();
    } else {
        let used = window.g("usedPercent")?;
        if !used.is_number() || used.lt_i(0)? || used.gt_i(100)? {
            reason = "window_malformed".into();
        } else {
            let age = age_seconds(&window.g("observedAt")?, now)?;
            if age.is_none_or(|age| age < -5.0 || age > max_age_seconds) {
                reason = "window_stale".into();
            }
            if !window.g("resetConfirmed")?.is_bool() {
                reason = "window_malformed".into();
            }
            if window.g("resetRequired")?.is_true()? && !window.g("resetAt")?.t()? {
                reason = "reset_unconfirmed".into();
            }
            let resolved = resolve_window(&used, &window.g("resetAt")?, &window.g("observedAt")?, now, false)?;
            remaining = V::I32(100).sub(&V::Dbl(resolved.g("used")?.dbl()?))?;
            rolled = resolved.g("rolledOver")?.t()?;
            if window.g("resetAt")?.t()? {
                let at = catch(|| Dto::parse(&window.g("resetAt")?.s()?))?;
                match at {
                    None => reason = "window_malformed".into(),
                    Some(at) => {
                        if at.ticks <= now.ticks && !rolled {
                            reason = "reset_unconfirmed".into();
                        }
                        if at.ticks > now.ticks && window.g("resetConfirmed")?.is_true()? {
                            reset = at.utc().o().into();
                        }
                    }
                }
            }
        }
    }
    Ok(obj! {
        "name" => window.g("name")?.sv()?,
        "scope" => window.g("scope")?.sv()?,
        "role" => window.g("role")?.sv()?,
        "state" => state,
        "required" => window.g("required")?.is_true()?,
        "remainingPercent" => remaining,
        "resetAt" => reset,
        "observedAt" => window.g("observedAt")?,
        "rolledOver" => rolled,
        "reason" => reason,
    })
}

/// `@($list | ForEach-Object { [string]$_ })`
pub fn strings(list: &V) -> R<Vec<V>> {
    list.arr().iter().map(V::sv).collect()
}

/// `$windows | Where-Object resetAt | Sort-Object resetAt | Select-Object -First 1`, then
/// its resetAt. The values are this module's own UTC timestamps, all of one width, so the
/// earliest is the ordinal minimum whichever culture sorts them.
fn first_reset(windows: &[V]) -> R<V> {
    let mut first: Option<String> = None;
    for window in windows {
        let at = window.g("resetAt")?;
        if !at.t()? {
            continue;
        }
        let V::Str(text) = &at else { return decline() };
        if first.as_deref().is_none_or(|known| &**text < known) {
            first = Some(text.to_string());
        }
    }
    Ok(first.map_or(V::Null, V::from))
}

/// ConvertTo-Hotpl8ProviderAccount
pub fn provider_account(account: &V, policy: &V, scopes: &[V], now: Dto) -> R<V> {
    let id = account.g("id")?.s()?;
    let id_value = V::s_of(&id);
    let mut reason = V::Null;
    let reserve = match account.g("reserve")? {
        V::Null => id_value.is_in_list(&strings(&policy.g("reserve")?)?)?,
        value => value.t()?,
    };
    let mut preference = match account.g("preference")? {
        V::Null => strings(&policy.g("prefer")?)?.iter().position(|item| item.as_str() == Some(id.as_str())).map_or(-1, |at| at as i32),
        value => value.to_int()?,
    };
    if preference < 0 {
        preference = i32::MAX;
    }
    let status = account.g("status")?;
    if id.is_empty() {
        reason = "account_unknown".into();
    } else if account.g("enabled")?.is_false()? || id_value.is_in_list(&strings(&policy.g("disabled")?)?)? {
        reason = "disabled".into();
    } else if account.g("identityValid")?.is_false()? || account.g("bindingValid")?.is_false()? {
        reason = "binding_changed".into();
    } else if status.ne_s("ok")? {
        reason = if status.t()? { status.sv()? } else { "unknown".into() };
    } else if account.g("blockedReason")?.t()? {
        reason = account.g("blockedReason")?.sv()?;
    } else {
        let age = age_seconds(&account.g("observedAt")?, now)?;
        let stale = match age {
            None => true,
            Some(age) => age < -5.0 || V::Dbl(age).gt(&setting(policy, "maxUsageAgeS", V::I32(900))?)?,
        };
        if stale {
            reason = "stale".into();
        }
    }
    let input: Vec<V> = account.g("windows")?.arr().into_iter().filter(|window| !window.is_null()).collect();
    for scope in scopes {
        let mut observed = 0;
        for window in &input {
            if window.g("scope")?.ceq(scope)? && window.g("state")?.eq_s("observed")? {
                observed += 1;
            }
        }
        if observed == 0 && !reason.t()? {
            reason = "model_quota_unknown".into();
        }
    }
    let mut normalized = Vec::new();
    for window in &input {
        normalized.push(provider_window(window, now, setting(policy, "maxUsageAgeS", V::I32(900))?.dbl()?)?);
    }
    // Validate before scope filtering: malformed scope metadata cannot hide a
    // required constraint by making it appear to belong to an unrelated model.
    if !reason.t()? && !filter(&normalized, |window| window.g("reason")?.eq_s("window_malformed"))?.is_empty() {
        reason = "window_malformed".into();
    }
    let windows = filter(&normalized, |window| {
        Ok(scopes.is_empty() || !window.g("scope")?.t()? || window.g("scope")?.is_cin_list(scopes)?)
    })?;
    let mut seen = Keys::new();
    for window in &windows {
        let key = cat!(window.g("scope")?, "/", window.g("name")?);
        if seen.contains(&key)? && !reason.t()? {
            reason = "duplicate_window".into();
        }
        seen.insert(&key)?;
        if window.g("reason")?.t()? && !reason.t()? {
            reason = window.g("reason")?;
        }
    }
    let observed = filter(&windows, |window| window.g("state")?.eq_s("observed"))?;
    if observed.is_empty() && !reason.t()? {
        reason = "window_unknown".into();
    }
    let short = filter(&observed, |window| window.g("role")?.eq_s("short"))?;
    let week = filter(&observed, |window| window.g("role")?.eq_s("weekly"))?;
    let least = |list: &[V]| -> R<V> {
        if list.is_empty() {
            return Ok(V::Null);
        }
        measure_min(&list.iter().map(|window| window.g("remainingPercent")).collect::<R<Vec<V>>>()?)
    };
    let short_left = least(&short)?;
    let week_left = least(&week)?;
    let binding = least(&observed)?;
    let reset = first_reset(if short.is_empty() { &week } else { &short })?;
    let weekly_reset = first_reset(&week)?;
    let capacity = account.g("capacity")?;
    let scaled = capacity.g("scaled")?.is_true()? && capacity.g("gross")?.is_number() && capacity.g("gross")?.ge_i(0)?;
    Ok(obj! {
        "id" => id,
        "identityKey" => account.g("identityKey")?.sv()?,
        "reserve" => reserve,
        "preference" => preference,
        "reason" => &reason,
        "valid" => !reason.t()?,
        "windows" => windows,
        "shortRemaining" => short_left,
        "weeklyRemaining" => week_left,
        "bindingRemaining" => binding,
        "resetAt" => reset,
        "weeklyResetAt" => weekly_reset,
        "scaled" => scaled,
        "gross" => if scaled { capacity.g("gross")? } else { V::Null },
        "observedAt" => account.g("observedAt")?,
    })
}

/// Get-Hotpl8ProviderMargin
pub fn provider_margin(policy: &V, account: &V, window: &V, emergency: bool) -> R<V> {
    if emergency && policy.path(&["critical", "enabled"])?.is_true()? && !account.g("reserve")?.t()? {
        if policy.path(&["critical", "drainToZero"])?.t()? {
            return Ok(V::I32(0));
        }
        return setting(&policy.g("critical")?, "floorPercent", V::I32(1));
    }
    if window.g("role")?.eq_s("short")? {
        return setting(policy, "margin5h", V::I32(25));
    }
    if !account.g("reserve")?.t()? && !policy.g("margin7dWork")?.is_null() {
        return policy.g("margin7dWork");
    }
    setting(policy, "margin7d", V::I32(20))
}

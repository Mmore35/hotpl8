//! src/replay.ps1: replay runs the production selectors over recorded readings without
//! calling a provider or writing state. The collector publishes one reading's decisions as
//! `shadow`: what each ordering would have picked.

use crate::capacity::{capacity_accounts, fresh_timestamp};
use crate::claude::{claude_selection, Accounts};
use crate::codex::select_codex_slot;
use crate::critical::critical_decision;
use crate::observation::claude_observation;
use crate::ps::*;
use crate::registry::{configured_providers, copy, provider_view};
use crate::time::Dto;
use crate::{hash, obj};

const ORDERS: [&str; 4] = ["prefer", "soonest-reset", "weekly-expiry", "balanced"];
const METERS: [&str; 2] = ["codex", "codex_bengalfox"];
const LIMITATION: &str = "Observed-trace comparison only. Alternate choices change future usage; this does not measure quota savings.";

/// What one stream carries from reading to reading: `$prior`, `$criticalStates`,
/// `$switches`, `$reserves` and `$unavailable` under one key.
struct Stream {
    key: String,
    prior: V,
    critical: V,
    switches: i32,
    reserves: i32,
    unavailable: i32,
}
#[derive(Default)]
struct Streams(Vec<Stream>);
impl Streams {
    fn known(&self, key: &str) -> Option<&Stream> {
        self.0.iter().find(|stream| stream.key == key)
    }
    fn of(&mut self, key: &str) -> &mut Stream {
        let at = match self.0.iter().position(|stream| stream.key == key) {
            Some(at) => at,
            None => {
                self.0.push(Stream { key: key.to_string(), prior: V::Null, critical: V::Null, switches: 0, reserves: 0, unavailable: 0 });
                self.0.len() - 1
            }
        };
        &mut self.0[at]
    }
}

/// Where `$prior.Keys|Sort-Object` puts a stream. A native stream takes one of twelve
/// names, and the two PowerShell editions disagree on whether `/` or `_` comes first.
fn stream_rank(key: &str) -> usize {
    let meters = if desktop() { ["codex/codex/", "codex/codex_bengalfox/"] } else { ["codex/codex_bengalfox/", "codex/codex/"] };
    let mut rank = 0;
    for prefix in ["claude/", meters[0], meters[1]] {
        for order in ["balanced", "prefer", "soonest-reset", "weekly-expiry"] {
            if key.strip_prefix(prefix) == Some(order) {
                return rank;
            }
            rank += 1;
        }
    }
    rank
}

/// Test-Hotpl8FutureReset for a recorded hold: one that cannot be read holds nothing.
fn held(until: &V, now: Dto) -> R<bool> {
    Ok(catch(|| Ok(Dto::parse_external(&until.s()?)?.ticks > now.ticks))?.unwrap_or(false))
}

/// New-Hotpl8ReplayRow
fn replay_row(stream: &mut Stream, now: Dto, choice: &V, current: &V, reserve: &V) -> R<V> {
    if choice.t()? && current.t()? && choice.ne(current)? {
        stream.switches += 1;
    }
    let is_reserve = choice.t()? && choice.is_in(reserve)?;
    if is_reserve {
        stream.reserves += 1;
    }
    if !choice.t()? {
        stream.unavailable += 1;
    }
    stream.prior = choice.clone();
    Ok(obj! {"stream" => stream.key.as_str(), "at" => now.o(), "selected" => choice, "reserve" => is_reserve})
}

/// The rows of Invoke-Hotpl8NativeReplay: each decision, then each stream's totals.
struct Replayed {
    decisions: Vec<V>,
    summary: Vec<V>,
}

/// Invoke-Hotpl8NativeReplay
fn native_replay(frames: &[V], policy: &V) -> R<Replayed> {
    let mut decisions = Vec::new();
    let mut streams = Streams::default();
    for frame in frames {
        let now = Dto::of(&frame.g("generatedAt")?)?;
        for order in ORDERS {
            let p = copy(policy)?;
            p.add_member("order", order.into(), true)?;
            if p.g("prefer")?.t()? {
                let mut accounts = Accounts::default();
                for s in frame.g("slots")?.arr() {
                    if !s.t()? {
                        continue;
                    }
                    let (used5, used7) = (s.g("used5h")?, s.g("used7d")?);
                    let e = hash! {
                        "observation" => claude_observation(&s, &p)?,
                        "h5" => if used5.is_null() { V::Null } else { V::I32(100).sub(&used5)? },
                        "h7" => if used7.is_null() { V::Null } else { V::I32(100).sub(&used7)? },
                        "fresh" => s.g("fresh")?.t()? && fresh_timestamp(&s.g("observedAt")?, now)? && !s.g("slot")?.is_in(&p.g("disabled")?)?,
                        "modelBlocked" => s.g("modelBlock")?.t()?,
                        "obj" => hash! {"usage" => hash! {
                            "fiveHour" => hash! {"resetsAt" => s.g("reset5h")?},
                            "sevenDay" => hash! {"resetsAt" => s.g("reset7d")?},
                        }},
                    };
                    accounts.put(s.g("slot")?.to_int()?, e);
                }
                let key = format!("claude/{order}");
                let current = match streams.known(&key) {
                    Some(stream) => stream.prior.clone(),
                    None => frame.g("active")?,
                };
                let mut prefer = Vec::new();
                for id in p.g("prefer")?.arr() {
                    prefer.push(id.to_int()?);
                }
                let stream = streams.of(&key);
                let found = claude_selection(&p, &prefer, &accounts, current.to_int()?, now, &stream.critical)?;
                // Get-Hotpl8ClaudeCritical asks the decision the selection has just made.
                stream.critical = found.critical;
                let choice = if held(&frame.path(&["hold", "until"])?, now)? {
                    if found.active_ok { current.clone() } else { V::Null }
                } else if !found.target.is_null() {
                    found.target
                } else if found.active_ok {
                    current.clone()
                } else {
                    V::Null
                };
                decisions.push(replay_row(stream, now, &choice, &current, &p.g("reserve")?)?);
            }
            let part = p.g("codex")?;
            if part.g("slots")?.t()? {
                part.add_member("order", order.into(), true)?;
                let codex = frame.path(&["providers", "codex"])?;
                for meter in METERS {
                    let stream = streams.of(&format!("codex/{meter}/{order}"));
                    let current = stream.prior.clone();
                    let choice = select_codex_slot(&codex.g("slots")?.arr(), &part, meter, &current.s()?, &codex.g("hold")?, now, &stream.critical)?;
                    let critical = capacity_accounts(frame, &part, "codex", now, meter, false)?;
                    stream.critical = critical_decision(&critical, &part, &current.s()?, &stream.critical, now)?;
                    decisions.push(replay_row(stream, now, &choice, &current, &part.g("reserve")?)?);
                }
            }
        }
    }
    streams.0.sort_by_key(|stream| stream_rank(&stream.key));
    let summary = streams.0.iter().map(|stream| {
        obj! {"stream" => stream.key.as_str(), "switches" => stream.switches, "reserveSelections" => stream.reserves, "unavailable" => stream.unavailable}
    });
    Ok(Replayed { decisions, summary: summary.collect() })
}

/// Invoke-Hotpl8Replay
pub fn replay(frames: &[V], policy: &V) -> R<V> {
    let (mut decisions, mut summary) = (Vec::new(), Vec::new());
    for r in configured_providers(policy, false)? {
        let id = r.g("id")?.s()?;
        let mut views = Vec::new();
        for frame in frames {
            views.push(provider_view(frame, policy, &id, &[])?);
        }
        let Some(first) = views.first() else { continue };
        let mut snapshots = Vec::new();
        for view in &views {
            snapshots.push(view.g("snapshot")?);
        }
        let native = native_replay(&snapshots, &first.g("policy")?)?;
        let family = first.g("provider")?.s()?;
        let narrow = first.path(&["driver", "slotKind"])?.eq_s("native-home")?;
        let meters = r.path(&["definition", "meters"])?.arr();
        for (rows, kept) in [(native.decisions, &mut decisions), (native.summary, &mut summary)] {
            for row in rows {
                let stream = row.g("stream")?.s()?;
                let meter = stream.split('/').nth(1).map_or(V::Null, V::s_of);
                if narrow && !meter.is_cin_list(&meters)? {
                    continue;
                }
                let Some(rest) = stream.get(family.len()..) else { return throw() };
                row.set("stream", format!("{id}{rest}").into())?;
                kept.push(row);
            }
        }
    }
    let count = i32::try_from(frames.len()).or_else(|_| unreadable())?;
    Ok(obj! {"schemaVersion" => 1, "frames" => count, "decisions" => decisions, "summary" => summary, "limitation" => LIMITATION})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::shared_rules;
    use crate::json::parse;
    use std::path::Path;

    /// The readings and cases are the ones tests/test-shared-rules.ps1 gives to
    /// Invoke-Hotpl8Replay, and the lines are what it answers under Windows PowerShell:
    /// each decision's stream, time, pick and reserve mark, each stream's totals, and the
    /// number of readings. PowerShell 7 answers the same with the totals in its own order.
    const FRAMES: &str = include_str!("../../tests/parity/replay-frames.txt");
    const REPLAYED: &str = include_str!("../../tests/parity/replay-expected.txt");

    fn replayed(name: &str, policy: &V, pick: &[usize]) -> Vec<String> {
        let lines: Vec<&str> = FRAMES.lines().collect();
        let frames: Vec<V> = pick.iter().map(|at| parse(lines[*at], "").ok().unwrap()).collect();
        let text = |value: R<V>| value.and_then(|value| if value.is_null() { Ok("null".to_string()) } else { value.s() }).ok().unwrap();
        let r = match replay(&frames, policy) {
            Ok(r) => r,
            Err(stop) => return vec![format!("{name}|THROWN {}", stop.message())],
        };
        let mut said = Vec::new();
        for d in r.g("decisions").ok().unwrap().each() {
            said.push(format!("{name}|{}|{}|{}|{}", text(d.g("stream")), text(d.g("at")), text(d.g("selected")), text(d.g("reserve"))));
        }
        for s in r.g("summary").ok().unwrap().each() {
            said.push(format!("{name}|sum|{}|{}|{}|{}", text(s.g("stream")), text(s.g("switches")), text(s.g("reserveSelections")), text(s.g("unavailable"))));
        }
        said.push(format!("{name}|frames|{}|{}", text(r.g("frames")), text(r.g("schemaVersion"))));
        said
    }
    fn all() -> Vec<String> {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../data");
        crate::registry::set_source(data.join("providers"));
        crate::capacity::set_source(data.join("capacity-profiles.json"));
        let cases = shared_rules("replay").arr();
        assert!(cases.len() > 7);
        let mut said = Vec::new();
        for case in &cases {
            let field = |name: &str| case.g(name).ok().unwrap();
            let pick: Vec<usize> = field("pick").each().iter().map(|at| at.s().ok().unwrap().parse().unwrap()).collect();
            said.extend(replayed(&field("name").s().ok().unwrap(), &field("policy"), &pick));
        }
        said
    }

    #[test]
    fn each_ordering_picks_what_powershell_picks() {
        set_core(false);
        let said = all();
        for (said, expected) in said.iter().zip(REPLAYED.lines()) {
            assert_eq!(said, expected);
        }
        assert_eq!(said.len(), REPLAYED.lines().count());
        // PowerShell 7 lists the Spark streams ahead of the main ones.
        set_core(true);
        let core = all();
        set_core(false);
        let spark = core.iter().position(|line| line == "one|sum|codex/codex_bengalfox/balanced|0|0|0").unwrap();
        let main = core.iter().position(|line| line == "one|sum|codex/codex/balanced|0|0|0").unwrap();
        assert!(spark < main);
        let (mut core, mut desktop) = (core, said);
        core.sort();
        desktop.sort();
        assert_eq!(core, desktop);
    }
}

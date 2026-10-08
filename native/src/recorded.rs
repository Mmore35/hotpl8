//! The cases of tests/parity/rule-cases.json, answered again. Each is a call one of
//! PowerShell's own suites made of a rule while PowerShell still held it: what was asked and
//! what it answered, with PowerShell's types kept. The rules are the program's alone now, and
//! these tests hold them to what was answered then.
//!
//! A case is never edited to make it pass. A rule that is meant to change has its cases
//! changed with it, by hand and in review. Where the program is meant to differ from
//! PowerShell, the case keeps PowerShell's answer and says so beside it: `"program"` is
//! `refuses` or `answers`, and `"why"` names the difference.

use crate::claude::{self, Accounts};
use crate::ps::*;
use crate::time::Dto;
use crate::{capacity, codex, contract, critical, decision, insights, json, observation, overview, selection, sha256};

/// A decimal from the digits .NET prints for it.
fn decimal(text: &str) -> V {
    if text.contains('.') {
        let read = json::parse(&format!("{{\"held\":{text}}}"), "a decimal").ok().unwrap().g("held").ok().unwrap();
        assert!(matches!(read, V::Dec(_)), "{text} is not read as a decimal");
        read
    } else {
        V::Dec(crate::num::Dec::from_i64(text.parse().unwrap()))
    }
}

/// A value of the case file as the value PowerShell held. The file is JSON, with what JSON
/// cannot say spelled out: {"$l": "5"} is a 64-bit integer, {"$m": "4.50"} a decimal,
/// {"$d": "<bits>"} a double, {"$t": "<time>"} an instant and {"$h": {...}} a hash table, its
/// keys in ordinal order.
/// A whole number is a 32-bit integer and any other object is a [pscustomobject].
///
/// A double that is no number is refused here, as everywhere the program makes one: it holds
/// none, and no file can carry one to it.
fn typed(value: &V) -> R<V> {
    Ok(match value {
        V::Arr(items) => items.iter().map(typed).collect::<R<Vec<V>>>()?.into(),
        V::Obj(_) => {
            let members = value.props().ok().unwrap();
            if let [(name, inner)] = &members[..] {
                let text = || inner.s().ok().unwrap();
                match &**name {
                    "$l" => return Ok(V::I64(text().parse().unwrap())),
                    "$m" => return Ok(decimal(&text())),
                    "$d" => return dbl(f64::from_bits(u64::from_str_radix(&text(), 16).unwrap())),
                    "$h" => return Ok(new_hash(named(&inner.props().ok().unwrap())?.iter().map(|(name, item)| (&**name, item.clone())).collect())),
                    // The program holds an instant as the text it is written as.
                    "$t" => return Ok(inner.clone()),
                    _ => {}
                }
            }
            new_obj(named(&members)?.iter().map(|(name, item)| (&**name, item.clone())).collect())
        }
        other => other.clone(),
    })
}

fn named(members: &[(std::rc::Rc<str>, V)]) -> R<Vec<(std::rc::Rc<str>, V)>> {
    members.iter().map(|(name, item)| Ok((name.clone(), typed(item)?))).collect()
}

/// A document PowerShell's rule read through JSON before it looked at it: a hash table
/// inside it is the object JSON makes of one.
fn document(value: V) -> V {
    match &value {
        V::Arr(items) => items.iter().cloned().map(document).collect::<Vec<V>>().into(),
        V::Obj(held) | V::Hash(held) => new_obj(held.borrow().items.iter().map(|(name, item)| (&**name, document(item.clone()))).collect()),
        _ => value,
    }
}

fn quoted(text: &str, out: &mut String) {
    out.push('"');
    for unit in text.encode_utf16() {
        match unit {
            34 => out.push_str("\\\""),
            92 => out.push_str("\\\\"),
            32..=126 => out.push(unit as u8 as char),
            _ => out.push_str(&format!("\\u{unit:04x}")),
        }
    }
    out.push('"');
}

/// A value the program holds, written as the case file writes one.
fn written(value: &V, out: &mut String) {
    let listed = |items: &[(std::rc::Rc<str>, V)], out: &mut String| {
        out.push('{');
        for (index, (name, item)) in items.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            quoted(name, out);
            out.push(':');
            written(item, out);
        }
        out.push('}');
    };
    match value {
        V::Null => out.push_str("null"),
        V::Bool(held) => out.push_str(if *held { "true" } else { "false" }),
        V::I32(held) => out.push_str(&held.to_string()),
        V::I64(held) => out.push_str(&format!("{{\"$l\":\"{held}\"}}")),
        V::Dec(held) => out.push_str(&format!("{{\"$m\":\"{}\"}}", held.text())),
        V::Dbl(held) => out.push_str(&format!("{{\"$d\":\"{:016x}\"}}", held.to_bits())),
        V::Str(held) => quoted(held, out),
        V::Arr(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                written(item, out);
            }
            out.push(']');
        }
        V::Obj(held) => listed(&held.borrow().items, out),
        V::Hash(held) => {
            let mut items = held.borrow().items.clone();
            items.sort_by(|a, b| a.0.encode_utf16().cmp(b.0.encode_utf16()));
            out.push_str("{\"$h\":");
            listed(&items, out);
            out.push('}');
        }
    }
}

/// What a caller that keeps a function's output in a variable holds: nothing, the one
/// thing written, or the list of them.
fn kept(mut wrote: Vec<V>) -> V {
    match wrote.len() {
        0 => V::Null,
        1 => wrote.remove(0),
        _ => wrote.into(),
    }
}

/// What a case asked, by the parameter names PowerShell's function had.
struct Asked {
    case: V,
    /// Each value handed to the rule, beside how it was written when it was handed over.
    given: std::cell::RefCell<Vec<(V, String)>>,
}
impl Asked {
    fn raw(&self, name: &str) -> Option<V> {
        self.case.props().ok().unwrap().into_iter().find(|(known, _)| &**known == name).map(|(_, value)| value)
    }
    /// A parameter left out is null, as PowerShell left it.
    fn value(&self, name: &str) -> R<V> {
        Ok(self.give(self.raw(name).map_or(Ok(V::Null), |value| typed(&value))?))
    }
    fn give(&self, value: V) -> V {
        let mut text = String::new();
        written(&value, &mut text);
        self.given.borrow_mut().push((value.clone(), text));
        value
    }
    /// Whether the rule left everything it was handed as it was.
    fn untouched(&self) -> bool {
        self.given.borrow().iter().all(|(value, before)| {
            let mut after = String::new();
            written(value, &mut after);
            after == *before
        })
    }
    fn list(&self, name: &str) -> R<Vec<V>> {
        Ok(self.value(name)?.each())
    }
    fn text(&self, name: &str, otherwise: &str) -> String {
        self.raw(name).map_or(otherwise.to_string(), |value| value.s().ok().unwrap())
    }
    fn flag(&self, name: &str) -> bool {
        self.raw(name).is_some_and(|value| matches!(value, V::Bool(true)))
    }
    fn whole(&self, name: &str) -> i32 {
        match self.raw(name) {
            Some(V::I32(held)) => held,
            other => panic!("{name} is not a whole number: {}", other.is_some()),
        }
    }
    fn instant(&self, name: &str) -> Dto {
        let held = self.raw(name).unwrap_or_else(|| panic!("the case names no {name}"));
        Dto::parse(&held.g("$t").ok().unwrap().s().ok().unwrap()).ok().unwrap()
    }
    /// A table of Claude accounts, keyed by slot number.
    fn accounts(&self, name: &str) -> R<Accounts> {
        let mut accounts = Accounts::default();
        match self.value(name)? {
            V::Hash(held) => {
                for (slot, entry) in held.borrow().items.iter() {
                    accounts.put(slot.parse().unwrap(), entry.clone());
                }
            }
            V::Null => {}
            _ => panic!("{name} is not a table of accounts"),
        }
        Ok(accounts)
    }
    fn slots(&self, name: &str) -> R<Vec<i32>> {
        Ok(self.list(name)?.iter().map(|slot| slot.to_int().ok().unwrap()).collect())
    }
}

fn answered(rule: &str, asked: &Asked) -> R<V> {
    let value = |name: &str| asked.value(name);
    let read = |name: &str| asked.value(name).map(|held| asked.give(document(held)));
    Ok(match rule {
        "capacity::provider_capacity" => {
            capacity::provider_capacity(&value("Snapshot")?, &value("Part")?, &asked.text("Provider", ""), asked.instant("Now"), &asked.text("Meter", "codex"), asked.flag("QuotaHeadroom"))?
        }
        "capacity::capacity_accounts" => {
            kept(capacity::capacity_accounts(&value("Snapshot")?, &value("Part")?, &asked.text("Provider", ""), asked.instant("Now"), &asked.text("Meter", "codex"), asked.flag("QuotaHeadroom"))?)
        }
        "capacity::capacity_amount" => {
            capacity::capacity_amount(&value("Account")?, &value("Part")?, asked.instant("At"), asked.flag("Project"), asked.flag("Emergency"), asked.flag("AssumeRefill"))?
        }
        "capacity::account_capacity" => {
            capacity::account_capacity(&value("Part")?, &asked.text("Slot", ""), &asked.text("Provider", ""), &asked.text("Meter", "codex"), &value("DetectedPlan")?, asked.instant("Now"))?
        }
        "capacity::detected_plan" => capacity::detected_plan(&value("Plan")?, asked.instant("Now"))?.into(),
        "capacity::assert_capacity_policy" => {
            capacity::assert_capacity_policy(&value("Part")?)?;
            V::Null
        }
        "critical::critical_decision" => critical::critical_decision(&asked.list("Accounts")?, &value("Part")?, &asked.text("PreviousId", ""), &value("State")?, asked.instant("Now"))?,
        "overview::provider_overview" => overview::provider_overview(&read("Snapshot")?, &read("Policy")?, asked.instant("Now"))?,
        "decision::provider_decision" => decision::provider_decision(&value("Accounts")?, &value("Policy")?, &value("Context")?, asked.instant("Now"))?,
        "observation::claude_observation" => observation::claude_observation(&value("Slot")?, &value("Policy")?)?,
        "observation::claude_entry_observation" => observation::claude_entry_observation(&value("Id")?, &value("Entry")?, &value("Policy")?, asked.instant("Now"), asked.flag("ForWarm"))?,
        "observation::codex_observation" => observation::codex_observation(&value("Slot")?, &asked.text("Meter", ""))?,
        "contract::provider_account" => contract::provider_account(&value("Account")?, &value("Policy")?, &asked.list("Scopes")?, asked.instant("Now"))?,
        "codex::codex_eligibility" => codex::codex_eligibility(&value("Slot")?, &value("Policy")?, &asked.text("Meter", ""), asked.instant("Now"), asked.flag("Emergency"))?,
        "codex::select_codex_slot" => {
            codex::select_codex_slot(&asked.list("Slots")?, &value("Policy")?, &asked.text("Meter", ""), &asked.text("PreviousId", ""), &value("Hold")?, asked.instant("Now"), &value("CriticalState")?)?
        }
        "claude::claude_provider_decision" => {
            let context = value("Context")?;
            claude::claude_provider_decision(&read("Policy")?, &asked.slots("Prefer")?, &asked.accounts("Accounts")?, asked.whole("Active"), asked.instant("Now"), &value("CriticalState")?, if context.is_null() { None } else { Some(&context) })?
        }
        "claude::claude_selection" => {
            let (policy, prefer, accounts, active, now, state) = (read("policy")?, asked.slots("prefer")?, asked.accounts("acc")?, asked.whole("active"), asked.instant("Now"), value("CriticalState")?);
            let chosen = claude::claude_selection(&policy, &prefer, &accounts, active, now, &state)?;
            let ranked: Vec<V> = chosen.ranked.iter().map(|slot| V::I32(*slot)).collect();
            crate::hash! {
                "target" => chosen.target,
                "activeOk" => chosen.active_ok,
                "ranked" => ranked,
                "critical" => chosen.critical,
                "decision" => claude::claude_provider_decision(&policy, &prefer, &accounts, active, now, &state, None)?,
            }
        }
        "claude::margin_7d_for" => claude::margin_7d_for(&read("policy")?, &value("n")?)?,
        "selection::selection_key" => selection::selection_key(&asked.text("Order", ""), &value("FiveRemaining")?, &value("WeekRemaining")?, &value("WeekReset")?, asked.instant("Now"))?,
        "insights::health" => insights::health(&value("Collector")?, asked.instant("Now"), &asked.text("Provider", ""))?.into(),
        "codex_collect::codex_buckets" => crate::codex_collect::codex_buckets(&value("Quota")?, &value("PreviousBuckets")?, asked.instant("Now"))?,
        "codex_read::plan_name" => crate::codex_read::plan_name(&value("Value")?).into(),
        "registry::assert_definition" => {
            crate::registry::assert_definition(&value("Definition")?)?;
            V::Null
        }
        "policy::assert_automation_policy" => {
            crate::policy::assert_automation_policy(&value("Policy")?)?;
            V::Null
        }
        _ => panic!("no rule is named {rule}"),
    })
}

/// Why a case may say the program is meant to differ from PowerShell. Each is a difference
/// docs/plans/rust-read-side.md lists.
const WHY: [&str; 3] = ["a time is not one HotPl8 writes", "a number is none", "a time zone is judged where it is used"];

/// The cases of the rules whose names begin as given, each answered and compared.
fn hold(family: &str) {
    set_core(false);
    let data = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../data");
    crate::registry::set_source(data.join("providers"));
    capacity::set_source(data.join("capacity-profiles.json"));
    let (mut seen, mut wrong) = (0, Vec::new());
    for (number, line) in include_str!("../../tests/parity/rule-cases.json").lines().enumerate().filter(|(_, line)| line.starts_with("{\"rule\"")) {
        let case = json::parse(line.trim_end_matches(','), "rule-cases.json").ok().unwrap();
        let field = |name: &str| case.g(name).ok().unwrap();
        let rule = field("rule").s().ok().unwrap();
        if !rule.starts_with(family) {
            continue;
        }
        seen += 1;
        let (answer, digest, refused) = (field("answer"), field("digest"), field("refused"));
        let asked = Asked { case: field("asked"), given: Default::default() };
        let now = answered(&rule, &asked);
        // A rule decides; it does not alter the readings, the policy or the state it is shown.
        if !asked.untouched() {
            wrong.push(format!("line {}: {rule} [{}]: the rule changed what it was asked", number + 1, field("from").s().ok().unwrap()));
        }
        // A case that says the program differs holds PowerShell's answer beside the saying, and
        // is held here to the saying alone: that the program refuses, or that it answers what
        // PowerShell refused.
        if let Some(says) = field("program").as_str() {
            let why = field("why").s().ok().unwrap();
            let held = match says {
                "refuses" => now.is_err(),
                "answers" => now.is_ok() && !refused.is_null(),
                _ => false,
            };
            if !held || !WHY.contains(&&*why) {
                wrong.push(format!("line {}: {rule} [{}]: the case says the program {says} ({why})", number + 1, field("from").s().ok().unwrap()));
            }
            continue;
        }
        let (expected, said) = match now {
            Ok(answer_now) => {
                let mut text = String::new();
                written(&answer_now, &mut text);
                if !digest.is_null() {
                    (format!("an answer whose digest is {}", digest.s().ok().unwrap()), format!("an answer whose digest is {}", &sha256::hash(&text)[..16]))
                } else if !refused.is_null() {
                    (format!("refused: {}", refused.s().ok().unwrap()), text)
                } else {
                    let mut expected = String::new();
                    written(&typed(&answer).ok().unwrap(), &mut expected);
                    (expected, text)
                }
            }
            Err(stop) => (if refused.is_null() { "an answer".to_string() } else { format!("refused: {}", refused.s().ok().unwrap()) }, format!("refused: {}", stop.message())),
        };
        if expected != said {
            let at = expected.bytes().zip(said.bytes()).take_while(|(a, b)| a == b).count().saturating_sub(60);
            let shown = |text: &str| text.chars().skip(at).take(200).collect::<String>();
            wrong.push(format!("line {}: {rule} [{}]\n  expected ...{}\n  answered ...{}", number + 1, field("from").s().ok().unwrap(), shown(&expected), shown(&said)));
        }
    }
    assert!(seen > 0, "no case is of {family}");
    assert!(wrong.is_empty(), "{} of {seen} cases differ:\n{}", wrong.len(), wrong.join("\n"));
}

#[test]
fn a_value_is_written_as_it_is_read() {
    set_core(false);
    let text = r#"{"a":[1,{"$l":"5"},{"$m":"4.50"},{"$m":"7"},{"$d":"3ff8000000000000"},"q\"\\\u00e9",null,true],"b":{"$h":{"1":{},"b":[]}}}"#;
    let mut again = String::new();
    written(&typed(&json::parse(text, "").ok().unwrap()).ok().unwrap(), &mut again);
    assert_eq!(again, text);
    assert!(matches!(typed(&json::parse(r#"{"$d":"3ff8000000000000"}"#, "").ok().unwrap()), Ok(V::Dbl(held)) if held == 1.5));
    assert!(typed(&json::parse(r#"{"$d":"7ff0000000000000"}"#, "").ok().unwrap()).is_err());
    assert_eq!(kept(Vec::new()).is_null(), true);
    // A rule that altered what it was handed would be seen.
    let asked = Asked { case: json::parse(r#"{"Policy":{"margin5h":25}}"#, "").ok().unwrap(), given: Default::default() };
    let policy = asked.value("Policy").ok().unwrap();
    assert!(asked.untouched());
    policy.set("margin5h", V::I32(26)).ok().unwrap();
    assert!(!asked.untouched());
}

#[test]
fn capacity_is_what_the_cases_say() {
    hold("capacity::");
}
#[test]
fn the_critical_choice_is_what_the_cases_say() {
    hold("critical::");
}
#[test]
fn the_overview_is_what_the_cases_say() {
    hold("overview::");
}
#[test]
fn a_decision_is_what_the_cases_say() {
    hold("decision::");
}
#[test]
fn an_observation_is_what_the_cases_say() {
    hold("observation::");
    hold("contract::");
}
#[test]
fn the_codex_choice_is_what_the_cases_say() {
    hold("codex::");
}
#[test]
fn the_claude_choice_is_what_the_cases_say() {
    hold("claude::");
}
#[test]
fn the_limits_of_a_codex_account_are_what_the_cases_say() {
    hold("codex_collect::");
    hold("codex_read::");
}

#[test]
fn a_definition_and_a_policy_are_checked_as_the_cases_say() {
    hold("registry::");
    hold("policy::");
}

#[test]
fn an_order_and_a_collector_are_what_the_cases_say() {
    hold("selection::");
    hold("insights::");
}

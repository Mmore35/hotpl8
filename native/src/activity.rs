//! The activity record of src/insights.ps1: what HotPl8 did or saw happen to an account,
//! newest last, for `hotpl8 status` to show.

use crate::files;
use crate::json;
use crate::obj;
use crate::ps::*;
use crate::time::Dto;
use std::path::Path;

/// How many events the record keeps.
const KEPT: usize = 100;

/// Add-Hotpl8ActionEvent
pub fn add_action_event(directory: &Path, provider: &str, slot: &str, kind: &str, reason: &str, now: Dto) -> R<()> {
    let path = directory.join("activity.json");
    let mut events = filter(&json::read_or_null(&path).g("events")?.each(), |event| event.t())?;
    events.push(obj! {"id" => files::guid(), "at" => now.o(), "provider" => provider, "slot" => slot, "kind" => kind, "reason" => reason});
    let first = events.len().saturating_sub(KEPT);
    files::write_json(&path, &obj! {"schemaVersion" => 1, "events" => events.split_off(first)}, 6)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::scratch;

    #[test]
    fn the_record_keeps_the_newest_hundred() {
        let directory = scratch("activity");
        let now = Dto::parse("2026-10-06T12:00:00.0000000+00:00").ok().unwrap();
        // Whatever was there and is not an event is dropped rather than carried.
        std::fs::write(directory.join("activity.json"), r#"{"schemaVersion":1,"events":[null,{"id":"old","kind":"switch"}]}"#).unwrap();
        add_action_event(&directory, "claude", "2", "switch", "native_switch_succeeded", now).ok().unwrap();
        let read = || json::read_or_null(&directory.join("activity.json"));
        let events = read().g("events").ok().unwrap().each();
        assert_eq!(events.len(), 2);
        assert_eq!(
            json::write(&events[1], 4).ok().unwrap().replace(&events[1].g("id").ok().unwrap().s().ok().unwrap(), "ID"),
            "{\n  \"id\": \"ID\",\n  \"at\": \"2026-10-06T12:00:00.0000000+00:00\",\n  \"provider\": \"claude\",\n  \"slot\": \"2\",\n  \"kind\": \"switch\",\n  \"reason\": \"native_switch_succeeded\"\n}"
        );
        for count in 0..KEPT {
            add_action_event(&directory, "claude", &count.to_string(), "warm_attempt", "sent", now).ok().unwrap();
        }
        let events = read().g("events").ok().unwrap().each();
        assert_eq!(events.len(), KEPT);
        assert_eq!(events[0].g("slot").ok().unwrap().s().ok().unwrap(), "0");
        assert_eq!(read().g("schemaVersion").ok().unwrap().to_int().ok().unwrap(), 1);
        // A record that cannot be read is begun again.
        std::fs::write(directory.join("activity.json"), "{oh no").unwrap();
        add_action_event(&directory, "codex", "1", "recommendation", "next_launch_only", now).ok().unwrap();
        assert_eq!(read().g("events").ok().unwrap().each().len(), 1);
        std::fs::remove_dir_all(&directory).unwrap();
    }
}

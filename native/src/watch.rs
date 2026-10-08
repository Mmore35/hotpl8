//! The dashboard where it is shown: kept open on a terminal, and as one frame of text for
//! anything else.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use crate::dashboard::{frame, words, Frame, View};
use crate::paint::{self, Colours, Tweens};
use crate::ps::{R, V};
use crate::request::{Command, Request};
use crate::terminal::{Key, Terminal};
use crate::time::Dto;

/// How often an open dashboard reads the state again.
const SECOND: Duration = Duration::from_secs(1);
/// How long a state that cannot be read is given to mend before the reason is shown in
/// place of the last frame.
const PATIENCE: Duration = Duration::from_secs(5);

/// Whether there is a dashboard to draw: a policy with an account in it. A policy that is
/// not a valid one is refused, as every command refuses it.
pub fn ready(request: &Request) -> R<bool> {
    crate::display::prepare(request);
    let state = crate::display::state_directory(&request.root, request.state.as_deref())?;
    let Some(policy) = crate::json::read_file(&request.policy.clone().unwrap_or_else(|| state.join("policy.json")))? else {
        return Ok(false);
    };
    crate::policy::assert_policy(&policy)?;
    Ok(!crate::registry::provider_accounts(&policy)?.is_empty())
}

/// One frame as text. Pipes and hosts that are no terminal get it without colours or
/// movement, as tall as it needs: they must never wait on a key.
pub fn still(request: &Request, status: &V, policy: &V, now: Dto) -> R<String> {
    let nyan = request.command == Command::Nyan;
    let view = match request.shot {
        Some(shot) => View { width: shot.width, height: shot.height, offset: shot.offset, frozen: shot.frozen, seconds: shot.seconds, nyan, motion: !request.reduced_motion, plain: shot.plain, colours: shot.colours },
        None => View { width: 100, height: 10000, offset: 0, frozen: false, seconds: 0.0, nyan, motion: false, plain: true, colours: Colours::here() },
    };
    let drawn = frame(status, policy, now, &view, &mut Tweens::default())?;
    let mut out = String::new();
    for line in &drawn.lines {
        match request.shot {
            Some(shot) if shot.ansi => paint::ansi(&line.spans, shot.colours, &mut out),
            _ => out.push_str(&paint::text(&line.spans)),
        }
        out.push('\n');
    }
    if request.shot.is_some() {
        out.push_str(&format!("offset {}\n", drawn.offset));
    }
    Ok(out)
}

/// Show-Hotpl8Dashboard, on a terminal: the dashboard kept open until a key closes it, and
/// the exit status it closed with. `None` where there is no terminal to keep it open on.
/// What cannot be read before anything is drawn is refused as any command refuses it. Once
/// the dashboard is open it stays open: the last frame is kept, then the reason is shown.
pub fn open(request: &Request) -> R<Option<u8>> {
    crate::display::prepare(request);
    let mut shown = crate::display::read(request)?;
    let Some(mut terminal) = Terminal::open() else { return Ok(None) };
    let set = |name: &str| std::env::var_os(name).is_some_and(|value| !value.is_empty());
    let (nyan, colours) = (request.command == Command::Nyan, Colours::here());
    let (bare, at_rest) = (request.no_color || set("NO_COLOR"), request.reduced_motion || set("HOTPL8_REDUCED_MOTION"));
    let mut release = Release::of(&request.root);
    let clock = Instant::now();
    let mut tweens = Tweens::default();
    let (mut offset, mut frozen, mut seconds) = (0, false, 0.0);
    let mut drawn: Option<Drawn> = None;
    // What the terminal was last written: its rows, and whether without colours.
    let (mut written, mut written_plain): (Vec<String>, Option<bool>) = (Vec::new(), None);
    let mut failing: Option<(Duration, String)> = None;
    let (mut next, mut looked, mut asked) = (Duration::ZERO, None::<Duration>, true);
    loop {
        let started = clock.elapsed();
        if looked.is_none_or(|at| started - at >= SECOND) {
            looked = Some(started);
            match release.look() {
                Look::Replaced => return Ok(Some(crate::HANDED_OFF)),
                Look::Named(title) => terminal.title(&title),
                Look::Same => {}
            }
        }
        if started >= next {
            // A frozen dashboard shows one instant: its clock stops with its state.
            if !frozen {
                seconds = started.as_secs_f64();
            }
            let (columns, rows) = terminal.size();
            let (width, height) = (columns.saturating_sub(1).max(1), rows.saturating_sub(1).max(1));
            let resized = drawn.as_ref().is_none_or(|drawn| (drawn.width, drawn.height) != (width, height));
            let laid = resized || asked || (!frozen && drawn.as_ref().is_some_and(|drawn| started - drawn.at >= SECOND));
            if laid {
                asked = false;
                let mut trouble = None;
                if !frozen && drawn.is_some() {
                    match crate::display::read(request) {
                        Ok(read) => shown = read,
                        Err(stop) => trouble = Some(stop.message()),
                    }
                }
                let plain = bare || shown.policy.path(&["display", "noColor"]).and_then(|quiet| quiet.t()).unwrap_or(false);
                let view = View { width, height, offset, frozen, seconds, nyan, motion: !at_rest, plain, colours };
                let frame = match frame(&shown.status, &shown.policy, shown.now, &view, &mut tweens) {
                    Ok(frame) => Some(frame),
                    Err(stop) => {
                        trouble.get_or_insert(stop.message());
                        None
                    }
                };
                failing = trouble.map(|reason| (failing.take().map_or(started, |(since, _)| since), reason));
                let patient = failing.as_ref().is_none_or(|(since, _)| started - *since < PATIENCE);
                let frame = match frame {
                    Some(frame) if patient => frame,
                    _ => words(&["hotpl8 (=^.^=)", failing.as_ref().map_or("", |(_, reason)| reason), "Q quit"], width, height),
                };
                offset = frame.offset;
                drawn = Some(Drawn::of(frame, width, height, started, seconds, plain, colours));
            }
            // Rows that move are drawn again at this one instant, and once more when they
            // come to rest. A frame just laid out is already at it.
            let mut rate: Option<u64> = None;
            if let Some(Drawn { frame, lines, moved, .. }) = drawn.as_mut().filter(|_| !frozen) {
                for (index, line) in frame.lines.iter().enumerate() {
                    let Some(live) = &line.live else { continue };
                    let moving = live.moving(seconds);
                    if !laid && (moving || moved[index]) {
                        lines[index].clear();
                        paint::ansi(&live.spans(seconds), colours, &mut lines[index]);
                    }
                    moved[index] = moving;
                    if moving {
                        rate = Some(rate.map_or(live.rate, |rate| rate.min(live.rate)));
                    }
                }
            }
            if let Some(drawn) = &drawn {
                let mut text = String::new();
                if written_plain != Some(drawn.plain) {
                    text.push_str(&if drawn.plain { "\x1b[0m".to_owned() } else { colours.backdrop() });
                    text.push_str("\x1b[2J");
                }
                if !text.is_empty() || resized {
                    text.push_str("\x1b[H");
                    text.push_str(&drawn.lines.join("\r\n"));
                    text.push_str("\x1b[J");
                } else {
                    // Only the rows that changed are written.
                    for (index, line) in drawn.lines.iter().enumerate() {
                        if written.get(index) != Some(line) {
                            text.push_str(&format!("\x1b[{};1H{line}", index + 1));
                        }
                    }
                    if drawn.lines.len() < written.len() {
                        text.push_str(&format!("\x1b[{};1H\x1b[J", drawn.lines.len() + 1));
                    }
                }
                // A terminal that takes nothing more is gone.
                if !text.is_empty() && !terminal.write(&text) {
                    return Ok(Some(crate::FAILED));
                }
                written.clone_from(&drawn.lines);
                written_plain = Some(drawn.plain);
            }
            // Drawing is part of the wait, so a slow frame is followed by no burst.
            next = started + Duration::from_millis(rate.unwrap_or(1000));
        }
        for key in terminal.keys() {
            match key {
                Key::Quit => return Ok(Some(0)),
                Key::Freeze => frozen = !frozen,
                key => offset = scrolled(offset, key),
            }
            // Every key is answered at once, with the state as it is now.
            (next, asked) = (Duration::ZERO, true);
        }
        std::thread::sleep(next.saturating_sub(clock.elapsed()).clamp(Duration::from_millis(1), Duration::from_millis(16)));
    }
}

/// Move-Hotpl8DashboardScroll. The frame brings a position past the last row back to it.
fn scrolled(offset: usize, key: Key) -> usize {
    match key {
        Key::Home => 0,
        Key::End => usize::MAX,
        Key::Up => offset.saturating_sub(1),
        Key::Down => offset.saturating_add(1),
        Key::PageUp => offset.saturating_sub(10),
        Key::PageDown => offset.saturating_add(10),
        Key::Quit | Key::Freeze | Key::Other => offset,
    }
}

/// A frame as it was laid out, and each of its rows as the terminal is written it.
struct Drawn {
    frame: Frame,
    width: usize,
    height: usize,
    /// When it was laid out, by the dashboard's clock.
    at: Duration,
    lines: Vec<String>,
    /// The rows that were moving when they were last drawn.
    moved: Vec<bool>,
    plain: bool,
}

impl Drawn {
    fn of(frame: Frame, width: usize, height: usize, at: Duration, seconds: f64, plain: bool, colours: Colours) -> Drawn {
        let lines = frame.lines.iter().map(|line| {
            let mut text = String::new();
            match plain {
                // What is right of a row is cleared for both: a window can be wider than the frame.
                true => text = paint::text(&line.spans) + "\x1b[K",
                false => paint::ansi(&line.spans, colours, &mut text),
            }
            text
        });
        let lines = lines.collect();
        let moved = frame.lines.iter().map(|line| line.live.as_ref().is_some_and(|live| live.moving(seconds))).collect();
        Drawn { frame, width, height, at, lines, moved, plain }
    }
}

/// What an open dashboard looks at every second, so that it is not left showing a release
/// that is no longer the one in force.
struct Release {
    /// An installation that updates itself, and the commit this release was built from.
    delivery: Option<(PathBuf, String)>,
    /// This program's file as it was when the dashboard opened. An installation that keeps
    /// its release under `app` puts another release there on an update or a rollback.
    program: Option<(PathBuf, Stamp)>,
    /// How many looks in a row found no program: an update moves one release out before it
    /// moves the next in.
    missing: u32,
    title: String,
}

type Stamp = (u64, Option<SystemTime>, Option<SystemTime>);

enum Look {
    Same,
    /// What the terminal's window is to be called from now on.
    Named(String),
    /// Another release is in force. The dashboard closes with `HANDED_OFF`, and what
    /// started it opens that release's.
    Replaced,
}

fn stamp(program: &Path) -> std::io::Result<Stamp> {
    let file = std::fs::metadata(program)?;
    Ok((file.len(), file.modified().ok(), file.created().ok()))
}

impl Release {
    fn of(root: &Path) -> Release {
        let text = |file: &Path, name: &str| crate::json::read_file(file).ok().flatten().and_then(|value| value.g(name).ok()).filter(|value| value.t().unwrap_or(false)).and_then(|value| value.s().ok());
        let installation = std::env::var_os("HOTPL8_INSTALL_DIRECTORY").filter(|named| !named.is_empty()).map(PathBuf::from);
        let delivery = installation.and_then(|installation| Some((installation, text(&root.join("build-info.json"), "sha")?)));
        let program = std::env::current_exe().ok().and_then(|program| Some((stamp(&program).ok()?, program))).map(|(stamp, program)| (program, stamp));
        Release { delivery, program, missing: 0, title: String::new() }
    }

    fn look(&mut self) -> Look {
        if let Some((program, opened)) = &self.program {
            match stamp(program) {
                Ok(now) if now == *opened => self.missing = 0,
                Ok(_) => return Look::Replaced,
                Err(_) => {
                    self.missing += 1;
                    // Gone for good: the installation was removed.
                    if self.missing >= 3 {
                        return Look::Replaced;
                    }
                }
            }
        }
        let Some((installation, build)) = &self.delivery else { return Look::Same };
        let text = |file: &str, name: &str| crate::json::read_file(&installation.join(file)).ok().flatten().and_then(|value| value.g(name).ok()).filter(|value| value.t().unwrap_or(false)).and_then(|value| value.s().ok());
        if text("current.json", "sha").is_some_and(|sha| !sha.eq_ignore_ascii_case(build)) {
            return Look::Replaced;
        }
        let commit: String = build.chars().take(12).collect();
        let title = paint::clean(&format!("HotPl8 main {commit} | {}", text("delivery-status.json", "state").unwrap_or_default()));
        if title == self.title {
            return Look::Same;
        }
        self.title.clone_from(&title);
        Look::Named(title)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dashboard::tests::{NOON, POLICY, STATUS};
    use crate::files::tests::scratch;
    use crate::request::Shot;

    /// A request for the dashboard of a scratch state, at the fixture's instant.
    fn asked(command: Command, state: &Path) -> Request {
        let mut request = Request::new(command, Path::new(env!("CARGO_MANIFEST_DIR")).join(".."));
        (request.state, request.core, request.zone, request.now) = (Some(state.to_path_buf()), false, Some(0), Dto::parse(NOON).ok());
        request
    }

    #[test]
    fn there_is_a_dashboard_once_an_account_is_enrolled() {
        let state = scratch("ready");
        let request = asked(Command::Watch, &state);
        assert!(!ready(&request).ok().unwrap());
        std::fs::write(state.join("policy.json"), r#"{"schemaVersion":2,"mode":"monitor"}"#).unwrap();
        assert!(!ready(&request).ok().unwrap());
        std::fs::write(state.join("policy.json"), POLICY).unwrap();
        assert!(ready(&request).ok().unwrap());
        // A policy that is not one is refused, as every command refuses it.
        std::fs::write(state.join("policy.json"), r#"{"schemaVersion":2,"mode":"sometimes"}"#).unwrap();
        assert!(ready(&request).err().unwrap().ruled());
        std::fs::remove_dir_all(&state).unwrap();
    }

    #[test]
    fn output_that_is_no_terminal_gets_one_frame_as_tall_as_it_needs() {
        let state = scratch("still");
        std::fs::write(state.join("policy.json"), POLICY).unwrap();
        std::fs::write(state.join("status.json"), STATUS).unwrap();
        let mut request = asked(Command::Nyan, &state);
        let text = crate::display::answer(&request).ok().unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 34);
        assert!(lines.iter().all(|line| paint::cells(line) == 100));
        assert!(lines[0].starts_with('╭') && lines[33].starts_with('╰') && lines[3].contains("hotpl8 / nyan"));
        assert!(!text.contains('\x1b') && text.ends_with("╯\n"));

        // A test's frame is one of a terminal that size, and says where it is scrolled to.
        let shot = Shot { width: 60, height: 18, offset: 999, seconds: 0.0, frozen: false, plain: true, ansi: false, colours: Colours::True };
        request.shot = Some(shot);
        let text = crate::display::answer(&request).ok().unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!((lines.len(), lines[18]), (19, "offset 6"));
        assert!(lines[..18].iter().all(|line| paint::cells(line) == 60));
        // The cat is left out where it would leave the accounts too few rows.
        assert!(!text.contains('\x1b') && !text.contains("hotpl8 / nyan"));

        // With its colours, as the terminal is written them.
        request.shot = Some(Shot { plain: false, ansi: true, ..shot });
        let text = crate::display::answer(&request).ok().unwrap();
        assert_eq!(text.lines().count(), 19);
        assert!(text.starts_with("\x1b[38;2;") && text.ends_with("offset 6\n"));
        std::fs::remove_dir_all(&state).unwrap();
    }

    #[test]
    fn a_key_scrolls_from_where_the_frame_is() {
        assert_eq!([Key::Up, Key::Down, Key::PageUp, Key::PageDown, Key::Home, Key::End].map(|key| scrolled(12, key)), [11, 13, 2, 22, 0, usize::MAX]);
        assert_eq!([Key::Up, Key::PageUp, Key::Home].map(|key| scrolled(3, key)), [2, 0, 0]);
        assert_eq!([Key::Down, Key::PageDown].map(|key| scrolled(usize::MAX, key)), [usize::MAX, usize::MAX]);
        assert_eq!([Key::Quit, Key::Freeze, Key::Other].map(|key| scrolled(5, key)), [5, 5, 5]);
    }

    #[test]
    fn a_row_is_written_with_what_clears_the_rest_of_its_line() {
        let plain = Drawn::of(words(&["one", "two"], 5, 9), 5, 9, SECOND, 1.0, true, Colours::True);
        assert_eq!(plain.lines, ["one  \x1b[K", "two  \x1b[K"]);
        assert_eq!((plain.moved.clone(), plain.at, plain.width, plain.height, plain.plain), (vec![false, false], SECOND, 5, 9, true));
        let coloured = Drawn::of(words(&["one"], 5, 9), 5, 9, SECOND, 1.0, false, Colours::Indexed);
        assert!(coloured.lines[0].starts_with("\x1b[38;5;") && coloured.lines[0].ends_with("one  \x1b[K"));
    }

    const BUILD: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn a_dashboard_is_named_for_its_release_and_closes_when_another_is_in_force() {
        let installation = scratch("release");
        let mut release = Release { delivery: Some((installation.clone(), BUILD.to_owned())), program: None, missing: 0, title: String::new() };
        let named = |look: Look| match look {
            Look::Named(title) => title,
            _ => String::new(),
        };
        // An installation still being put in place has no release in force to compare with.
        assert_eq!(named(release.look()), "HotPl8 main 0123456789ab | ");
        assert!(matches!(release.look(), Look::Same));
        std::fs::write(installation.join("current.json"), format!(r#"{{"sha":"{}"}}"#, BUILD.to_uppercase())).unwrap();
        std::fs::write(installation.join("delivery-status.json"), r#"{"state":"current"}"#).unwrap();
        assert_eq!(named(release.look()), "HotPl8 main 0123456789ab | current");
        assert!(matches!(release.look(), Look::Same));
        std::fs::write(installation.join("delivery-status.json"), r#"{"state":"update pending"}"#).unwrap();
        assert_eq!(named(release.look()), "HotPl8 main 0123456789ab | update pending");
        // A pointer caught half written is not another release.
        std::fs::write(installation.join("current.json"), r#"{"sha":"#).unwrap();
        assert!(matches!(release.look(), Look::Same));
        std::fs::write(installation.join("current.json"), format!(r#"{{"sha":"{}"}}"#, "f".repeat(40))).unwrap();
        assert!(matches!(release.look(), Look::Replaced));
        std::fs::remove_dir_all(&installation).unwrap();
    }

    #[test]
    fn a_dashboard_closes_when_its_own_program_is_replaced_or_gone() {
        let directory = scratch("program");
        let (program, aside) = (directory.join("hotpl8-native"), directory.join("aside"));
        std::fs::write(&program, "one release").unwrap();
        let opened = || Release { delivery: None, program: Some((program.clone(), stamp(&program).unwrap())), missing: 0, title: String::new() };
        let mut release = opened();
        assert!(matches!(release.look(), Look::Same));
        // An update moves one release out before it moves the next in.
        std::fs::rename(&program, &aside).unwrap();
        assert!(matches!(release.look(), Look::Same));
        assert!(matches!(release.look(), Look::Same));
        std::fs::rename(&aside, &program).unwrap();
        assert!(matches!(release.look(), Look::Same));
        assert_eq!(release.missing, 0);
        // Gone for good: the installation was removed.
        std::fs::rename(&program, &aside).unwrap();
        assert!(matches!(release.look(), Look::Same));
        assert!(matches!(release.look(), Look::Same));
        assert!(matches!(release.look(), Look::Replaced));
        // Another release where this one was.
        std::fs::write(&program, "the release after it").unwrap();
        assert!(matches!(opened().look(), Look::Same));
        assert!(matches!(release.look(), Look::Replaced));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn a_policy_being_tried_is_named_in_the_title_and_nothing_is_written() {
        let state = scratch("tried");
        std::fs::write(state.join("policy.json"), POLICY).unwrap();
        std::fs::write(state.join("status.json"), STATUS).unwrap();
        for command in [Command::Watch, Command::Nyan] {
            let mut request = asked(command, &state);
            assert!(!crate::display::answer(&request).ok().unwrap().contains("PREVIEW POLICY"));
            request.policy = Some(state.join("policy.json"));
            assert!(crate::display::answer(&request).ok().unwrap().contains("PREVIEW POLICY"));
        }
        let mut kept: Vec<_> = std::fs::read_dir(&state).unwrap().map(|entry| entry.unwrap().file_name()).collect();
        kept.sort();
        assert_eq!(kept, ["policy.json", "status.json"]);
        assert_eq!(std::fs::read_to_string(state.join("status.json")).unwrap(), STATUS);
        std::fs::remove_dir_all(&state).unwrap();
    }

    #[test]
    fn scrolling_stops_at_the_last_page_and_comes_back_from_it() {
        use crate::dashboard::tests::{crowded, fleet_drawn, leaves, page, terminal};
        let (status, policy) = crowded();
        for (nyan, height) in [(false, 21), (true, 28)] {
            // Each key moves from where the frame before it settled.
            let shown = |offset: &mut usize| {
                let drawn = fleet_drawn(&status, &policy, &View { offset: *offset, nyan, ..terminal(79, height) });
                *offset = drawn.offset;
                page(&drawn)
            };
            let (mut offset, mut text) = (0, String::new());
            for _ in 0..25 {
                offset = scrolled(offset, Key::Down);
                text = shown(&mut offset);
            }
            assert!(leaves(&text, "7d", "78%") && text.contains("-15/15]"), "{text}");
            if !nyan {
                assert!(text.contains("[6-15/15]") && offset == 5, "{offset}: {text}");
            }
            for key in [Key::End, Key::Down, Key::PageDown] {
                offset = scrolled(offset, key);
            }
            let text = shown(&mut offset);
            assert!(leaves(&text, "7d", "78%") && offset < 15, "{offset}: {text}");
            offset = scrolled(offset, Key::Up);
            assert!(!shown(&mut offset).contains("-15/15]"));
        }
        assert_eq!(scrolled(0, Key::PageUp), 0);
    }
}

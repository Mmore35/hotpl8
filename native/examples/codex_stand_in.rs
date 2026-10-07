//! A stand-in for the program Codex ships, for the tests of native/src/codex_read.rs. It
//! is started the way Codex is (`app-server --stdio` in a home named by CODEX_HOME) and
//! does what the file `stand-in.txt` in that home says. It knows no account, no network
//! and no real Codex, and is never part of a release.
//!
//! Each line of the file is `<when> <what> [<with>]`. `<when>` is `start`, or the method
//! of a request; every line for a method is done, in order, each time that method is
//! asked. A request with no line gets no answer. `<what>` is one of:
//!
//! - `reply <json>`: an answer whose result is `<json>`
//! - `error <json>`: an answer whose error is `<json>`
//! - `raw <text>`: `<text>` as a line of its own
//! - `part <text>`: `<text>` with no line end
//! - `long <count>`: a line of `<count>` letters
//! - `errors <count>`: `<count>` bytes on the error stream
//! - `wait <milliseconds>`, `hang`, `exit <status>`
//!
//! In `<text>` and `<json>`, `$ID` is the number of the request being answered, and in
//! `<text>` `<CR>`, `<LF>` and `<BOM>` are those characters. The home is left two files:
//! `started.txt` (the words, directory and home the program was started with) and
//! `heard.txt` (every line it was sent).

use std::io::{BufRead, Write};
use std::path::Path;

/// The text between `before` and the next `"`, for requests written the one way HotPl8 writes them.
fn quoted<'a>(line: &'a str, before: &str) -> Option<&'a str> {
    let rest = &line[line.find(before)? + before.len()..];
    rest.split('"').next()
}

fn act(what: &str, with: &str, id: &str) {
    let text = with.replace("$ID", id);
    let mut out = std::io::stdout().lock();
    let _ = match what {
        "reply" => writeln!(out, "{{\"id\":{id},\"result\":{text}}}"),
        "error" => writeln!(out, "{{\"id\":{id},\"error\":{text}}}"),
        "raw" => writeln!(out, "{text}"),
        "part" => write!(out, "{}", text.replace("<CR>", "\r").replace("<LF>", "\n").replace("<BOM>", "\u{feff}")),
        "long" => writeln!(out, "{}", "a".repeat(with.parse().unwrap())),
        "errors" => std::io::stderr().write_all(&vec![b'e'; with.parse().unwrap()]),
        "wait" => {
            std::thread::sleep(std::time::Duration::from_millis(with.parse().unwrap()));
            Ok(())
        }
        "hang" => loop {
            std::thread::sleep(std::time::Duration::from_secs(60));
        },
        "exit" => std::process::exit(with.parse().unwrap()),
        other => panic!("stand-in.txt asks for `{other}`, which the stand-in does not do"),
    };
    let _ = out.flush();
}

fn main() {
    let words: Vec<String> = std::env::args().skip(1).collect();
    let Some(home) = std::env::var_os("CODEX_HOME") else { std::process::exit(7) };
    let home = Path::new(&home);
    let directory = std::env::current_dir().unwrap();
    std::fs::write(home.join("started.txt"), format!("words {}\ndirectory {}\nhome {}\n", words.join(" "), directory.display(), home.display())).unwrap();
    if words != ["app-server", "--stdio"] {
        std::process::exit(7);
    }
    let script = std::fs::read_to_string(home.join("stand-in.txt")).unwrap();
    let steps: Vec<(&str, &str, &str)> = script
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| {
            let mut parts = line.splitn(3, ' ');
            (parts.next().unwrap(), parts.next().unwrap(), parts.next().unwrap_or(""))
        })
        .collect();
    let run = |when: &str, id: &str| steps.iter().filter(|(known, _, _)| *known == when).for_each(|(_, what, with)| act(what, with, id));
    run("start", "0");
    let mut heard = std::fs::File::create(home.join("heard.txt")).unwrap();
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        writeln!(heard, "{line}").unwrap();
        let id = line.strip_prefix("{\"id\":").map(|rest| rest.chars().take_while(char::is_ascii_digit).collect::<String>());
        if let (Some(id), Some(method)) = (id, quoted(&line, "\"method\":\"")) {
            run(method, &id);
        }
    }
}

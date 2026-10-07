//! src/common.ps1, the process half: a native program run to its end, within a time and
//! an amount of output, and never left running behind the collector.

use crate::ps::*;
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// What a finished program left: its exit status and everything it printed to stdout.
pub struct Finished {
    pub exit_code: i32,
    pub output: String,
}

/// The most either stream may carry before the program is given up on.
const OUTPUT_LIMIT: usize = 1_048_576;

/// The only words a batch shim is started with: fixed verbs and numeric accounts. A shell
/// reads the line, so nothing else is ever put on it.
fn batch_line(arguments: &[&str]) -> bool {
    let number = |text: &str| !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit());
    match arguments {
        ["list", "--json"] => true,
        ["switch", account] => number(account),
        ["run", account, "--", "claude", "--model", "haiku", "--strict-mcp-config", "-p", "."] => number(account),
        _ => false,
    }
}

fn command(executable: &str, arguments: &[&str]) -> R<Command> {
    let extension = std::path::Path::new(executable).extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    if extension != "cmd" && extension != "bat" {
        let mut command = Command::new(executable);
        command.args(arguments);
        return Ok(command);
    }
    if executable.contains(['"', '%', '&', '|', '<', '>', '!', '^', '\r', '\n']) || !batch_line(arguments) {
        return fail("unsupported_batch_arguments");
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let root = std::env::var_os("SystemRoot").unwrap_or_default();
        let mut command = Command::new(std::path::Path::new(&root).join("System32").join("cmd.exe"));
        command.raw_arg(format!("/d /s /c \"\"{executable}\" {}\"", arguments.join(" ")));
        Ok(command)
    }
    #[cfg(not(windows))]
    fail("unsupported_batch_arguments")
}

/// Stop-Hotpl8Process: a program still running is given a moment, then ended with every
/// program it started.
pub(crate) fn stop(child: &mut Child) {
    if matches!(child.try_wait(), Ok(Some(_))) {
        return;
    }
    let deadline = Instant::now() + Duration::from_millis(300);
    while Instant::now() < deadline {
        if matches!(child.try_wait(), Ok(Some(_))) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let root = std::env::var_os("SystemRoot").unwrap_or_default();
        let killer = Command::new(std::path::Path::new(&root).join("System32").join("taskkill.exe"))
            .args(["/PID", &child.id().to_string(), "/T", "/F"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .spawn();
        if let Ok(mut killer) = killer {
            let deadline = Instant::now() + Duration::from_millis(1000);
            while Instant::now() < deadline && !matches!(killer.try_wait(), Ok(Some(_))) {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
    #[cfg(unix)]
    {
        extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        // SAFETY: the program was started as the leader of its own process group, so the
        // negative id names it and what it started, and nothing else.
        unsafe { kill(-(child.id() as i32), 9) };
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(windows)]
pub(crate) const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Ends the program when the collector stops waiting for it, however it stops.
pub(crate) struct Running(pub(crate) Child);
impl Drop for Running {
    fn drop(&mut self) {
        stop(&mut self.0);
    }
}

/// Invoke-Hotpl8Process. The program reads nothing: its input is empty, as it is under the
/// scheduler.
pub fn run(executable: &str, arguments: &[&str], timeout_ms: u64) -> R<Finished> {
    let started = Instant::now();
    let mut command = command(executable, arguments)?;
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let Ok(child) = command.spawn() else { return fail("process_start_failed") };
    let mut running = Running(child);
    let (sender, receiver) = mpsc::channel::<(bool, Vec<u8>)>();
    let pump = |stream: Option<Box<dyn Read + Send>>, kept: bool| {
        let (Some(mut stream), sender) = (stream, sender.clone()) else { return };
        std::thread::spawn(move || {
            let mut buffer = [0u8; 4096];
            loop {
                let count = stream.read(&mut buffer).unwrap_or(0);
                // An empty chunk says the stream has ended.
                if sender.send((kept, buffer[..count].to_vec())).is_err() || count == 0 {
                    break;
                }
            }
        });
    };
    pump(running.0.stdout.take().map(|s| Box::new(s) as Box<dyn Read + Send>), true);
    pump(running.0.stderr.take().map(|s| Box::new(s) as Box<dyn Read + Send>), false);
    drop(sender);
    let mut output = Vec::new();
    let (mut ended, mut counts) = (0, [0usize; 2]);
    loop {
        if started.elapsed() > Duration::from_millis(timeout_ms) {
            return fail("process_timeout");
        }
        match receiver.recv_timeout(Duration::from_millis(5)) {
            Ok((_, chunk)) if chunk.is_empty() => ended += 1,
            Ok((kept, chunk)) => {
                counts[kept as usize] += chunk.len();
                if counts[kept as usize] > OUTPUT_LIMIT {
                    return fail("process_output_limit");
                }
                if kept {
                    output.extend_from_slice(&chunk);
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => ended = 2,
        }
        if ended >= 2 {
            if let Ok(Some(status)) = running.0.try_wait() {
                #[cfg(unix)]
                let code = {
                    use std::os::unix::process::ExitStatusExt;
                    status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
                };
                #[cfg(not(unix))]
                let code = status.code().unwrap_or(-1);
                // A byte-order mark is not part of what the program said.
                let said = output.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&output);
                return Ok(Finished { exit_code: code, output: String::from_utf8_lossy(said).into_owned() });
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::tests::scratch;

    fn script(directory: &std::path::Path, body_windows: &str, body_unix: &str) -> String {
        if cfg!(windows) {
            let path = directory.join("stub.cmd");
            std::fs::write(&path, format!("@echo off\r\n{body_windows}\r\n")).unwrap();
            path.to_string_lossy().into_owned()
        } else {
            let path = directory.join("stub");
            std::fs::write(&path, format!("#!/bin/sh\n{body_unix}\n")).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            path.to_string_lossy().into_owned()
        }
    }

    #[test]
    fn output_and_exit_status_come_back() {
        let directory = scratch("run");
        let stub = script(&directory, "echo %1 %2\r\necho no 1>&2\r\nexit /b 3", "echo \"$1\" \"$2\"; echo no >&2; exit 3");
        let done = run(&stub, &["switch", "12"], 20_000).ok().unwrap();
        assert_eq!(done.exit_code, 3);
        assert_eq!(done.output.trim(), "switch 12");
        std::fs::remove_dir_all(&directory).unwrap();
    }

    /// A file saved with a byte-order mark and printed as it is: the mark is dropped, as
    /// the PowerShell collector dropped it.
    #[test]
    fn a_byte_order_mark_is_not_output() {
        let directory = scratch("mark");
        std::fs::write(directory.join("said.json"), b"\xef\xbb\xbf{\"a\":1}").unwrap();
        let stub = script(&directory, "type \"%~dp0said.json\"", "cat \"$(dirname \"$0\")/said.json\"");
        let done = run(&stub, &["list", "--json"], 20_000).ok().unwrap();
        assert_eq!((done.exit_code, done.output.as_str()), (0, "{\"a\":1}"));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn a_shim_takes_only_the_fixed_words() {
        assert!(batch_line(&["list", "--json"]));
        assert!(batch_line(&["run", "3", "--", "claude", "--model", "haiku", "--strict-mcp-config", "-p", "."]));
        assert!(!batch_line(&["switch", "1 & calc"]));
        assert!(!batch_line(&["switch", ""]));
        assert!(!batch_line(&["list"]));
        for (executable, arguments) in [("a.cmd", vec!["switch", "x"]), ("a&b.cmd", vec!["list", "--json"]), ("a.BAT", vec!["remove", "1"])] {
            let stop = command(executable, &arguments).err().unwrap();
            assert_eq!(stop.said(), Some("unsupported_batch_arguments"));
        }
    }

    #[test]
    fn a_program_that_overstays_is_ended() {
        let directory = scratch("slow");
        let stub = script(&directory, "ping -n 30 127.0.0.1 >nul", "sleep 30");
        let started = Instant::now();
        let stop = run(&stub, &["list", "--json"], 400).err().unwrap();
        assert_eq!(stop.said(), Some("process_timeout"));
        assert!(started.elapsed() < Duration::from_secs(10));
        let missing = run(&directory.join("none.exe").to_string_lossy(), &[], 400).err().unwrap();
        assert_eq!(missing.said(), Some("process_start_failed"));
        // The directory can be removed only once nothing started from it still runs.
        let mut removed = false;
        for _ in 0..50 {
            if std::fs::remove_dir_all(&directory).is_ok() {
                removed = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(removed);
    }
}

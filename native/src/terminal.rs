//! The terminal the dashboard is kept open on: its size, its keys, and its screen, which is
//! given back as it was found. Each system is asked directly; there is no crate behind this.

use std::io::{IsTerminal, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

/// What a key asks of the dashboard.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Key {
    Quit,
    Freeze,
    Home,
    End,
    Up,
    Down,
    PageUp,
    PageDown,
    /// Any other key: the dashboard reads the state again.
    Other,
}

/// Whether someone is at both ends. Only then is a dashboard kept open.
pub fn attended() -> bool {
    std::io::stdin().is_terminal() && std::io::stdout().is_terminal()
}

/// How the terminal was found, for whoever gives it back: the dashboard when it closes, or a
/// panic, which this program ends on without running what closes it.
static FOUND: Mutex<Option<platform::Found>> = Mutex::new(None);
/// Set when the terminal is gone or the system asked the program to end.
static ENDED: AtomicBool = AtomicBool::new(false);

/// The terminal while the dashboard has its other screen.
pub struct Terminal {
    keys: platform::Keys,
}

impl Terminal {
    /// The terminal with the dashboard's screen opened on it and its cursor hidden, or `None`
    /// where there is no terminal that can be drawn on.
    pub fn open() -> Option<Terminal> {
        if !attended() {
            return None;
        }
        let (found, keys) = platform::open()?;
        ENDED.store(false, Ordering::Relaxed);
        *FOUND.lock().ok()? = Some(found);
        let before = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |panic| {
            close();
            before(panic);
        }));
        let mut terminal = Terminal { keys };
        terminal.write("\x1b[?1049h\x1b[?25l").then_some(terminal)
    }

    /// Columns and rows of the window.
    pub fn size(&self) -> (usize, usize) {
        platform::size().unwrap_or((80, 24))
    }

    /// The keys pressed since the last call. It never waits for one.
    pub fn keys(&mut self) -> Vec<Key> {
        if ENDED.load(Ordering::Relaxed) {
            return vec![Key::Quit];
        }
        self.keys.pressed()
    }

    /// Whether the terminal took the text.
    pub fn write(&mut self, text: &str) -> bool {
        let mut out = std::io::stdout().lock();
        out.write_all(text.as_bytes()).is_ok() && out.flush().is_ok()
    }

    /// What the window is called. The name it had comes back where the system can say it.
    pub fn title(&mut self, title: &str) {
        platform::title(title);
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        close();
    }
}

/// The screen, the cursor and the terminal's modes as they were found. Once.
fn close() {
    let Some(found) = FOUND.lock().ok().and_then(|mut found| found.take()) else { return };
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(b"\x1b[0m\x1b[?25h\x1b[?1049l");
    let _ = out.flush();
    platform::restore(&found);
}

/// The keys in what a terminal sent, which is taken out of `sent`. `settled` says nothing
/// more has come for a while: an escape character on its own is then the Escape key, and
/// until then it may be the start of an arrow's sequence, which stays in `sent`.
#[cfg(any(unix, test))]
fn keys_in(sent: &mut Vec<u8>, settled: bool) -> Vec<Key> {
    let mut keys = Vec::new();
    let mut at = 0;
    while at < sent.len() {
        let byte = sent[at];
        if byte != 0x1b {
            at += 1;
            // The bytes after the first of one character are not keys of their own.
            match byte {
                b'q' | b'Q' | 0x03 => keys.push(Key::Quit),
                b' ' => keys.push(Key::Freeze),
                0x80..=0xbf => {}
                _ => keys.push(Key::Other),
            }
            continue;
        }
        let Some(&next) = sent.get(at + 1) else {
            if settled {
                keys.push(Key::Quit);
                at += 1;
            }
            break;
        };
        if next != b'[' && next != b'O' {
            // A key held with Alt.
            keys.push(Key::Other);
            at += 2;
            continue;
        }
        let Some(length) = sent[at + 2..].iter().position(|byte| (0x40..=0x7e).contains(byte)) else {
            if settled {
                keys.push(Key::Other);
                at = sent.len();
            }
            break;
        };
        keys.push(match &sent[at + 2..=at + 2 + length] {
            b"A" => Key::Up,
            b"B" => Key::Down,
            b"H" | b"1~" | b"7~" => Key::Home,
            b"F" | b"4~" | b"8~" => Key::End,
            b"5~" => Key::PageUp,
            b"6~" => Key::PageDown,
            _ => Key::Other,
        });
        at += 3 + length;
    }
    sent.drain(..at);
    keys
}

#[cfg(windows)]
mod platform {
    use super::Key;
    use core::ffi::c_void;
    use std::os::windows::io::AsRawHandle;

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct KeyEvent {
        down: i32,
        repeat: u16,
        key: u16,
        scan: u16,
        character: u16,
        control: u32,
    }

    /// INPUT_RECORD, whose largest event is a key's.
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct Event {
        kind: u16,
        key: KeyEvent,
    }

    /// CONSOLE_SCREEN_BUFFER_INFO
    #[repr(C)]
    #[derive(Default)]
    struct Screen {
        size: [i16; 2],
        cursor: [i16; 2],
        attributes: u16,
        /// Left, top, right and bottom of the window, each inside it.
        window: [i16; 4],
        largest: [i16; 2],
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetConsoleMode(console: *mut c_void, mode: *mut u32) -> i32;
        fn SetConsoleMode(console: *mut c_void, mode: u32) -> i32;
        fn GetConsoleScreenBufferInfo(console: *mut c_void, screen: *mut Screen) -> i32;
        fn GetNumberOfConsoleInputEvents(console: *mut c_void, waiting: *mut u32) -> i32;
        fn ReadConsoleInputW(console: *mut c_void, events: *mut Event, capacity: u32, read: *mut u32) -> i32;
        fn GetConsoleTitleW(title: *mut u16, capacity: u32) -> u32;
        fn SetConsoleTitleW(title: *const u16) -> i32;
    }

    /// Ctrl+C is a signal while this is set, and a key once it is not.
    const PROCESSED_INPUT: u32 = 0x0001;
    const PROCESSED_OUTPUT: u32 = 0x0001;
    /// The console reads escape sequences, as every other terminal does.
    const VIRTUAL_TERMINAL: u32 = 0x0004;

    pub struct Found {
        input: u32,
        output: u32,
        title: Option<Vec<u16>>,
    }

    pub struct Keys;

    fn input() -> *mut c_void {
        std::io::stdin().as_raw_handle()
    }

    fn output() -> *mut c_void {
        std::io::stdout().as_raw_handle()
    }

    pub fn open() -> Option<(Found, Keys)> {
        let (mut typed, mut shown) = (0, 0);
        // SAFETY: both handles are this process's own streams and each mode is a live u32;
        // the call fails, and writes nothing, for a stream that is no console.
        if unsafe { GetConsoleMode(input(), &mut typed) == 0 || GetConsoleMode(output(), &mut shown) == 0 } {
            return None;
        }
        // SAFETY: the handle is the console's, and a console that reads no escape sequences
        // refuses the mode and keeps the one it had.
        if unsafe { SetConsoleMode(output(), shown | PROCESSED_OUTPUT | VIRTUAL_TERMINAL) } == 0 {
            return None;
        }
        let mut title = vec![0u16; 1024];
        // SAFETY: `title` holds the 1024 units it is said to; the call writes no more.
        let length = unsafe { GetConsoleTitleW(title.as_mut_ptr(), 1024) } as usize;
        title.truncate(length.min(1023));
        title.push(0);
        // SAFETY: as above. A console that keeps Ctrl+C a signal ends the program on it,
        // which the system then clears up after.
        unsafe { SetConsoleMode(input(), typed & !PROCESSED_INPUT) };
        Some((Found { input: typed, output: shown, title: Some(title).filter(|_| length > 0) }, Keys))
    }

    pub fn restore(found: &Found) {
        // SAFETY: the handles are the console's, the modes are the ones it gave, and the
        // title is the one it gave with the zero that ends it.
        unsafe {
            SetConsoleMode(output(), found.output);
            SetConsoleMode(input(), found.input);
            if let Some(title) = &found.title {
                SetConsoleTitleW(title.as_ptr());
            }
        }
    }

    pub fn size() -> Option<(usize, usize)> {
        let mut screen = Screen::default();
        // SAFETY: `screen` is a live structure of the layout the call fills.
        if unsafe { GetConsoleScreenBufferInfo(output(), &mut screen) } == 0 {
            return None;
        }
        let [left, top, right, bottom] = screen.window.map(i32::from);
        Some((usize::try_from(right - left + 1).ok()?, usize::try_from(bottom - top + 1).ok()?))
    }

    pub fn title(title: &str) {
        let wide: Vec<u16> = title.encode_utf16().chain([0]).collect();
        // SAFETY: `wide` ends with the zero the call reads up to.
        unsafe { SetConsoleTitleW(wide.as_ptr()) };
    }

    impl Keys {
        pub fn pressed(&mut self) -> Vec<Key> {
            const KEY: u16 = 1;
            const CONTROL: u32 = 0x0004 | 0x0008;
            let mut keys = Vec::new();
            loop {
                let mut waiting = 0;
                // SAFETY: `waiting` is a live u32.
                if unsafe { GetNumberOfConsoleInputEvents(input(), &mut waiting) } == 0 || waiting == 0 {
                    return keys;
                }
                let (mut event, mut read) = (Event::default(), 0);
                // SAFETY: there is room for the one event asked for, and an event is waiting,
                // so the call does not wait for one.
                if unsafe { ReadConsoleInputW(input(), &mut event, 1, &mut read) } == 0 || read == 0 {
                    return keys;
                }
                if event.kind != KEY || event.key.down == 0 {
                    continue;
                }
                keys.push(match event.key.key {
                    0x51 | 0x1b => Key::Quit,
                    0x43 if event.key.control & CONTROL != 0 => Key::Quit,
                    0x20 => Key::Freeze,
                    0x24 => Key::Home,
                    0x23 => Key::End,
                    0x26 => Key::Up,
                    0x28 => Key::Down,
                    0x21 => Key::PageUp,
                    0x22 => Key::PageDown,
                    // Shift, Ctrl, Alt and the locks are no key until another is pressed.
                    0x10..=0x12 | 0x14 | 0x90 | 0x91 => continue,
                    _ => Key::Other,
                });
            }
        }
    }
}

#[cfg(unix)]
mod platform {
    use super::{keys_in, Key, ENDED};
    use core::ffi::{c_int, c_ulong};
    use std::io::{Read, Write};
    use std::sync::atomic::Ordering;
    use std::sync::mpsc::{channel, Receiver};
    use std::time::{Duration, Instant};

    /// struct termios, which is at most 72 bytes on the systems HotPl8 is built for. Only
    /// the system reads what is in it.
    #[repr(C, align(8))]
    #[derive(Clone, Copy)]
    pub struct Modes([u8; 256]);

    #[repr(C)]
    #[derive(Default)]
    struct Window {
        rows: u16,
        columns: u16,
        across: u16,
        down: u16,
    }

    extern "C" {
        fn tcgetattr(terminal: c_int, modes: *mut Modes) -> c_int;
        fn tcsetattr(terminal: c_int, when: c_int, modes: *const Modes) -> c_int;
        fn cfmakeraw(modes: *mut Modes);
        fn ioctl(terminal: c_int, request: c_ulong, ...) -> c_int;
        fn signal(signal: c_int, handler: extern "C" fn(c_int)) -> usize;
    }

    #[cfg(target_os = "macos")]
    const WINDOW_SIZE: c_ulong = 0x4008_7468;
    #[cfg(not(target_os = "macos"))]
    const WINDOW_SIZE: c_ulong = 0x5413;
    /// The change applies once what was written has been sent, and drops what was typed.
    const FLUSHED: c_int = 2;

    pub struct Found(Modes);

    pub struct Keys {
        sent: Receiver<u8>,
        waiting: Vec<u8>,
        since: Option<Instant>,
    }

    extern "C" fn ended(_signal: c_int) {
        ENDED.store(true, Ordering::Relaxed);
    }

    pub fn open() -> Option<(Found, Keys)> {
        let mut found = Modes([0; 256]);
        // SAFETY: `found` is larger than the structure the call fills, and as aligned.
        if unsafe { tcgetattr(0, &mut found) } != 0 {
            return None;
        }
        let mut raw = found;
        // SAFETY: `raw` is the structure the system just filled. Without echo and without
        // lines, each key arrives as it is pressed and Ctrl+C is a key.
        if unsafe {
            cfmakeraw(&mut raw);
            tcsetattr(0, FLUSHED, &raw)
        } != 0
        {
            return None;
        }
        // A terminal that closes, or a request to end, closes the dashboard as a key does.
        for asked in [1, 2, 15] {
            // SAFETY: the handler only stores to an atomic, which a signal handler may do.
            unsafe { signal(asked, ended) };
        }
        let (send, sent) = channel();
        // Reading waits, so it has a thread of its own, which ends with the program.
        std::thread::spawn(move || {
            let mut typed = std::io::stdin().lock();
            let mut bytes = [0u8; 64];
            loop {
                match typed.read(&mut bytes) {
                    Ok(count) if count > 0 => {
                        if bytes[..count].iter().any(|byte| send.send(*byte).is_err()) {
                            return;
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    _ => return ENDED.store(true, Ordering::Relaxed),
                }
            }
        });
        Some((Found(found), Keys { sent, waiting: Vec::new(), since: None }))
    }

    pub fn restore(found: &Found) {
        // SAFETY: the modes are the ones the terminal gave.
        unsafe { tcsetattr(0, FLUSHED, &found.0) };
    }

    pub fn size() -> Option<(usize, usize)> {
        let mut window = Window::default();
        // SAFETY: the request fills a structure of this layout, passed as the one argument
        // the request reads.
        if unsafe { ioctl(1, WINDOW_SIZE, &mut window as *mut Window) } != 0 {
            return None;
        }
        Some((usize::from(window.columns), usize::from(window.rows))).filter(|(columns, rows)| *columns > 0 && *rows > 0)
    }

    /// A terminal is told its title in a sequence, and none says what it was.
    pub fn title(title: &str) {
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(format!("\x1b]0;{title}\x07").as_bytes());
        let _ = out.flush();
    }

    impl Keys {
        pub fn pressed(&mut self) -> Vec<Key> {
            let before = self.waiting.len();
            self.waiting.extend(self.sent.try_iter());
            if self.waiting.len() != before || self.since.is_none() {
                self.since = Some(Instant::now());
            }
            let settled = self.since.is_some_and(|since| since.elapsed() >= Duration::from_millis(50));
            let keys = keys_in(&mut self.waiting, settled);
            if self.waiting.is_empty() {
                self.since = None;
            }
            keys
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(sent: &[u8], settled: bool) -> (Vec<Key>, Vec<u8>) {
        let mut sent = sent.to_vec();
        let keys = keys_in(&mut sent, settled);
        (keys, sent)
    }

    #[test]
    fn a_terminal_sends_keys_as_characters_and_sequences() {
        assert_eq!(read(b"q", false), (vec![Key::Quit], vec![]));
        assert_eq!(read(b"Q \x03", false), (vec![Key::Quit, Key::Freeze, Key::Quit], vec![]));
        assert_eq!(read(b"\x1b[A\x1b[B\x1bOA\x1bOB", false), (vec![Key::Up, Key::Down, Key::Up, Key::Down], vec![]));
        assert_eq!(read(b"\x1b[H\x1b[1~\x1b[7~\x1bOH", false).0, vec![Key::Home; 4]);
        assert_eq!(read(b"\x1b[F\x1b[4~\x1b[8~\x1bOF", false).0, vec![Key::End; 4]);
        assert_eq!(read(b"\x1b[5~\x1b[6~", false).0, vec![Key::PageUp, Key::PageDown]);
        // Keys the dashboard has no use for still ask it to look again, once each.
        assert_eq!(read(b"x\r\x1b[1;5C\x1b[2~\x1bx", false), (vec![Key::Other; 5], vec![]));
        assert_eq!(read("é".as_bytes(), false), (vec![Key::Other], vec![]));
        assert_eq!(read(b"", true), (vec![], vec![]));
    }

    #[test]
    fn an_escape_is_the_escape_key_once_nothing_follows_it() {
        assert_eq!(read(b"\x1b", false), (vec![], b"\x1b".to_vec()));
        assert_eq!(read(b"\x1b", true), (vec![Key::Quit], vec![]));
        // The start of a sequence waits for its end, and what came before it is read.
        assert_eq!(read(b" \x1b[", false), (vec![Key::Freeze], b"\x1b[".to_vec()));
        assert_eq!(read(b"\x1b[5", false), (vec![], b"\x1b[5".to_vec()));
        assert_eq!(read(b"\x1b[5", true), (vec![Key::Other], vec![]));
        let mut sent = b"\x1b[".to_vec();
        assert_eq!(keys_in(&mut sent, false), vec![]);
        sent.push(b'B');
        assert_eq!(keys_in(&mut sent, false), vec![Key::Down]);
        assert!(sent.is_empty());
    }
}

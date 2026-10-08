//! What the dashboard is drawn with: text in a tone, the cells it takes, bars, the motion
//! of a value, and the escape codes a terminal colours them by.

use std::collections::HashMap;

pub type Rgb = [u8; 3];

/// The dashboard's own background: it never borrows the terminal's.
pub const BACKGROUND: Rgb = [18, 23, 35];
const WHITE: Tone = Tone::Rgb([255, 255, 255]);

/// A colour by what it means. Provider accents (peach, cyan) never say how an account is
/// doing; that is always `budget_tone`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Tone {
    Text,
    Muted,
    Border,
    Rose,
    Peach,
    Cyan,
    Lavender,
    Mint,
    Amber,
    Red,
    Rgb(Rgb),
}

impl Tone {
    pub fn rgb(self) -> Rgb {
        match self {
            Tone::Text => [220, 225, 238],
            Tone::Muted => [143, 156, 181],
            Tone::Border => [65, 79, 105],
            Tone::Rose => [246, 169, 193],
            Tone::Peach => [255, 155, 92],
            Tone::Cyan => [97, 208, 220],
            Tone::Lavender => [194, 180, 255],
            Tone::Mint => [151, 222, 191],
            Tone::Amber => [244, 207, 137],
            Tone::Red => [239, 98, 104],
            Tone::Rgb(rgb) => rgb,
        }
    }

    /// This tone moved `amount` of the way (0 to 1) to another.
    pub fn mixed(self, target: Tone, amount: f64) -> Tone {
        Tone::Rgb(between(self.rgb(), target.rgb(), amount.clamp(0.0, 1.0)))
    }
}

fn between(a: Rgb, b: Rgb, t: f64) -> Rgb {
    std::array::from_fn(|i| (f64::from(a[i]) + (f64::from(b[i]) - f64::from(a[i])) * t).round_ties_even() as u8)
}

/// How much is left, as a colour: red when nearly out, through amber, to green.
pub fn budget_tone(left: f64) -> Tone {
    const STOPS: [(f64, Rgb); 5] = [(0.0, [222, 48, 65]), (10.0, [239, 65, 67]), (25.0, [255, 148, 63]), (40.0, [244, 214, 70]), (100.0, [91, 220, 135])];
    let value = left.clamp(0.0, 100.0);
    for pair in STOPS.windows(2) {
        let ((low, a), (high, b)) = (pair[0], pair[1]);
        if value <= high {
            return Tone::Rgb(between(a, b, (value - low) / (high - low)));
        }
    }
    Tone::Muted
}

/// A character a terminal would act on or hide: Unicode's control and format characters.
/// Text from a cached file never reaches the terminal with one.
fn unprintable(c: char) -> bool {
    const FORMAT: [(u32, u32); 21] = [
        (0xad, 0xad),
        (0x600, 0x605),
        (0x61c, 0x61c),
        (0x6dd, 0x6dd),
        (0x70f, 0x70f),
        (0x890, 0x891),
        (0x8e2, 0x8e2),
        (0x180e, 0x180e),
        (0x200b, 0x200f),
        (0x202a, 0x202e),
        (0x2060, 0x2064),
        (0x2066, 0x206f),
        (0xfeff, 0xfeff),
        (0xfff9, 0xfffb),
        (0x110bd, 0x110bd),
        (0x110cd, 0x110cd),
        (0x13430, 0x1343f),
        (0x1bca0, 0x1bca3),
        (0x1d173, 0x1d17a),
        (0xe0001, 0xe0001),
        (0xe0020, 0xe007f),
    ];
    let code = c as u32;
    c.is_control() || (code >= 0xad && FORMAT.iter().any(|(low, high)| (*low..=*high).contains(&code)))
}

/// The text with every such character replaced by a space.
pub fn clean(text: &str) -> String {
    text.chars().map(|c| if unprintable(c) { ' ' } else { c }).collect()
}

/// How many terminal cells a character takes: two for East Asian wide characters and
/// emoji, none for a mark that combines with the character before it.
fn char_cells(c: char) -> usize {
    let code = c as u32;
    let wide = code >= 0x1100
        && (code <= 0x115f
            || (0x2e80..=0xa4cf).contains(&code)
            || (0xac00..=0xd7a3).contains(&code)
            || (0xf900..=0xfaff).contains(&code)
            || (0xfe10..=0xfe6f).contains(&code)
            || (0xff00..=0xff60).contains(&code)
            || (0xffe0..=0xffe6).contains(&code)
            || code >= 0x1f300);
    let combining = (0x300..=0x36f).contains(&code)
        || (0x1ab0..=0x1aff).contains(&code)
        || (0x1dc0..=0x1dff).contains(&code)
        || (0x20d0..=0x20ff).contains(&code)
        || (0xfe00..=0xfe0f).contains(&code)
        || (0xfe20..=0xfe2f).contains(&code)
        || (0xe0100..=0xe01ef).contains(&code);
    if combining {
        0
    } else if wide {
        2
    } else {
        1
    }
}

/// How many terminal cells a text takes.
pub fn cells(text: &str) -> usize {
    text.chars().map(char_cells).sum()
}

/// As much of the start of a text as fits `width` cells, and the cells it takes.
fn fitting(text: &str, width: usize) -> (&str, usize) {
    let mut used = 0;
    for (at, c) in text.char_indices() {
        let size = char_cells(c);
        if used + size > width {
            return (&text[..at], used);
        }
        used += size;
    }
    (text, used)
}

/// A text cut or padded with spaces to exactly `width` cells.
pub fn padded(text: &str, width: usize) -> String {
    let text = clean(text);
    let (kept, used) = fitting(&text, width);
    format!("{kept}{}", " ".repeat(width - used))
}

/// A text padded with spaces on the left to `width` cells.
pub fn right(text: &str, width: usize) -> String {
    format!("{}{text}", " ".repeat(width.saturating_sub(cells(text))))
}

/// A stretch of text in one tone. `background` is `None` on the dashboard's own.
#[derive(Clone, Debug, PartialEq)]
pub struct Span {
    pub text: String,
    pub tone: Tone,
    pub background: Option<Tone>,
}

impl Span {
    pub fn new(text: impl AsRef<str>, tone: Tone) -> Span {
        Span { text: clean(text.as_ref()), tone, background: None }
    }
    pub fn plain(text: impl AsRef<str>) -> Span {
        Span::new(text, Tone::Text)
    }
}

/// What a row shows without its colours.
pub fn text(spans: &[Span]) -> String {
    spans.iter().map(|span| span.text.as_str()).collect()
}

/// The frame's edges around a row: what fits `width` cells, padded to it, between a left
/// edge and `glyph`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Border {
    pub width: usize,
    pub glyph: char,
    pub tone: Tone,
}

impl Border {
    pub fn new(width: usize) -> Border {
        Border { width, glyph: '│', tone: Tone::Border }
    }

    pub fn around(&self, spans: &[Span]) -> Vec<Span> {
        let mut out = vec![Span::new("│", Tone::Border)];
        let mut used = 0;
        for span in spans {
            // A wide character that does not fit ends its span; a narrower one after it may still fit.
            let (kept, size) = fitting(&span.text, self.width - used);
            if !kept.is_empty() {
                out.push(Span { text: kept.to_string(), ..*span });
                used += size;
            }
        }
        if used < self.width {
            out.push(Span::plain(" ".repeat(self.width - used)));
        }
        out.push(Span::new(self.glyph.to_string(), self.tone));
        out
    }
}

/// One bar vocabulary everywhere: `█` usable now (to an eighth of a cell), `▒` what a
/// reset will return, `╌` allowance that is not measured, `·` empty track. `reveal` (0 to
/// 1) grows the bar into place; `shimmer` (0 to 1, or negative for none) is where a
/// highlight sits on the returning part.
pub fn bar(value: f64, gain: f64, unknown: f64, size: usize, tone: Tone, reveal: f64, shimmer: f64) -> Vec<Span> {
    const PARTIAL: [char; 7] = ['▏', '▎', '▍', '▌', '▋', '▊', '▉'];
    let size = size.max(1);
    // Multiplied before it is divided, as the rule was written: a bar's cells are whole
    // numbers, and a half can fall either way on the order.
    let cells = |part: f64| part * size as f64 / 100.0;
    let r = reveal.clamp(0.0, 1.0);
    let solid = value.clamp(0.0, 100.0) * r;
    let with_gain = (solid + gain.max(0.0) * r).min(100.0);
    let with_unknown = (with_gain + unknown.max(0.0) * r).min(100.0);
    let filled = cells(solid);
    let whole = (filled + 1e-9).floor() as usize;
    let eighths = ((filled - whole as f64) * 8.0 + 1e-9).floor() as usize;
    let partial = if whole < size && eighths > 0 { Some(PARTIAL[eighths - 1]) } else { None };
    let used = whole + usize::from(partial.is_some());
    let upto = |part: f64| cells(part).round_ties_even() as usize;
    let gains = upto(with_gain).saturating_sub(used);
    let unknowns = upto(with_unknown).saturating_sub(used + gains);
    let empty = size.saturating_sub(used + gains + unknowns);

    let mut spans = Vec::new();
    let mut run = |glyph: char, count: usize, tone: Tone| {
        if count > 0 {
            spans.push(Span::new(glyph.to_string().repeat(count), tone));
        }
    };
    run('█', whole, tone);
    if let Some(partial) = partial {
        run(partial, 1, tone);
    }
    let returning = tone.mixed(Tone::Rgb(BACKGROUND), 0.45);
    if gains > 0 && (0.0..1.0).contains(&shimmer) {
        let spark = ((shimmer * gains as f64).floor() as usize).min(gains - 1);
        run('▒', spark, returning);
        run('▒', 1, returning.mixed(WHITE, 0.5));
        run('▒', gains - spark - 1, returning);
    } else {
        run('▒', gains, returning);
    }
    run('╌', unknowns, Tone::Amber);
    run('·', empty, Tone::Border);
    spans
}

/// A tone brightened in step with a pulse, for what is nearly out.
pub fn pulsed(tone: Tone, pulse: f64) -> Tone {
    if pulse == 0.0 {
        tone
    } else {
        tone.mixed(WHITE, 0.45 * pulse)
    }
}

/// Progress (0 to 1) that starts fast and settles.
fn ease(progress: f64) -> f64 {
    1.0 - (1.0 - progress.clamp(0.0, 1.0)).powi(3)
}

/// A breathing curve between 0 and 1: smooth, never a hard blink.
pub fn pulse(seconds: f64) -> f64 {
    const PERIOD: f64 = 1.6;
    (1.0 - (2.0 * std::f64::consts::PI * ((seconds % PERIOD) / PERIOD)).cos()) / 2.0
}

/// How long a bar takes to grow into place when the dashboard opens.
pub const REVEAL_SECONDS: f64 = 0.9;
/// How long a bar takes to glide to a new value.
pub const GLIDE_SECONDS: f64 = 0.5;

/// How much of a bar is drawn that long after the dashboard opened.
pub fn reveal(seconds: f64) -> f64 {
    if seconds <= 0.0 || seconds >= REVEAL_SECONDS {
        return 1.0;
    }
    ease(seconds / REVEAL_SECONDS)
}

/// A bar on its way to a new value: where it was, and when it set off.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Glide {
    pub from: f64,
    pub start: f64,
}

/// The value a bar shows at an instant: bars glide to a new value instead of snapping.
pub fn tween(target: f64, glide: Option<Glide>, seconds: f64) -> f64 {
    let Some(Glide { from, start }) = glide else { return target };
    let elapsed = seconds - start;
    if elapsed <= 0.0 {
        from
    } else if elapsed >= GLIDE_SECONDS {
        target
    } else {
        from + (target - from) * ease(elapsed / GLIDE_SECONDS)
    }
}

/// When a row that glides has come to rest.
pub fn settled(glide: Option<Glide>) -> f64 {
    glide.map_or(0.0, |glide| glide.start + GLIDE_SECONDS).max(REVEAL_SECONDS)
}

/// Where every bar was last told to go. Only a layout pass records here; the repaints
/// between two passes are handed the glide that pass worked out.
#[derive(Default)]
pub struct Tweens(HashMap<String, (f64, Option<Glide>)>);

impl Tweens {
    /// The glide of the bar named `key` towards `target`. A target that moved restarts the
    /// glide from what is on screen now; the same target again leaves a glide in flight.
    pub fn anchor(&mut self, key: &str, target: f64, seconds: f64) -> Option<Glide> {
        let glide = match self.0.get(key) {
            Some((before, glide)) if (before - target).abs() >= 0.05 => Some(Glide { from: tween(*before, *glide, seconds), start: seconds }),
            Some((_, Some(glide))) if seconds < glide.start + GLIDE_SECONDS => Some(*glide),
            _ => None,
        };
        if self.0.len() > 64 {
            self.0.clear();
        }
        self.0.insert(key.to_string(), (target, glide));
        glide
    }
}

/// The mascot, which blinks now and then.
pub fn cat(seconds: f64, motion: bool) -> &'static str {
    if motion && seconds % 11.0 >= 10.6 {
        "(=-.-=)"
    } else {
        "(=^.^=)"
    }
}

/// How a terminal is told a colour.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Colours {
    /// Every colour as it is.
    True,
    /// The nearest of the 240 fixed colours, for Apple's Terminal: it reads the numbers of
    /// a full colour as separate codes and corrupts both colours.
    Indexed,
}

impl Colours {
    pub fn here() -> Colours {
        if std::env::var_os("TERM_PROGRAM").is_some_and(|name| name == "Apple_Terminal") {
            Colours::Indexed
        } else {
            Colours::True
        }
    }

    /// The dashboard's background, for the cells no row is written to.
    pub fn backdrop(self) -> String {
        let mut out = String::new();
        self.code(BACKGROUND, true, &mut out);
        out
    }

    fn code(self, rgb: Rgb, background: bool, out: &mut String) {
        use std::fmt::Write;
        let layer = if background { 48 } else { 38 };
        let _ = match self {
            Colours::True => write!(out, "\x1b[{layer};2;{};{};{}m", rgb[0], rgb[1], rgb[2]),
            Colours::Indexed => write!(out, "\x1b[{layer};5;{}m", indexed(rgb)),
        };
    }
}

/// The nearest fixed colour: the closer of the colour cube's entry and the grey ramp's.
/// The first sixteen colours are never used; they belong to the user's theme.
fn indexed(rgb: Rgb) -> u32 {
    const LEVELS: [i32; 6] = [0, 95, 135, 175, 215, 255];
    let (mut cube, mut cube_error) = (0, 0);
    for value in rgb {
        let value = i32::from(value);
        let mut best = 0;
        for level in 1..LEVELS.len() {
            if (value - LEVELS[level]).abs() < (value - LEVELS[best]).abs() {
                best = level;
            }
        }
        cube = cube * 6 + best as u32;
        cube_error += (value - LEVELS[best]).pow(2);
    }
    let mean = f64::from(rgb.iter().map(|value| u32::from(*value)).sum::<u32>()) / 3.0;
    let gray = ((mean - 8.0) / 10.0).round_ties_even().clamp(0.0, 23.0) as i32;
    let gray_error: i32 = rgb.iter().map(|value| (i32::from(*value) - (8 + 10 * gray)).pow(2)).sum();
    if gray_error < cube_error {
        232 + gray as u32
    } else {
        16 + cube
    }
}

/// A row as a terminal line: each colour is named when it changes, and the line ends by
/// clearing what is right of it to the dashboard's background.
pub fn ansi(spans: &[Span], colours: Colours, out: &mut String) {
    let (mut fore, mut back) = (None, None);
    for span in spans {
        if span.text.is_empty() {
            continue;
        }
        // Blank cells show only their background.
        let tone = span.tone.rgb();
        if fore != Some(tone) && span.text.chars().any(|c| c != ' ') {
            colours.code(tone, false, out);
            fore = Some(tone);
        }
        let behind = span.background.map_or(BACKGROUND, Tone::rgb);
        if back != Some(behind) {
            colours.code(behind, true, out);
            back = Some(behind);
        }
        out.push_str(&span.text);
    }
    if back != Some(BACKGROUND) {
        colours.code(BACKGROUND, true, out);
    }
    out.push_str("\x1b[K");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shown(spans: &[Span]) -> String {
        text(spans)
    }

    #[test]
    fn what_is_left_is_coloured_between_fixed_stops() {
        assert_eq!(budget_tone(0.0), Tone::Rgb([222, 48, 65]));
        assert_eq!(budget_tone(-4.0), Tone::Rgb([222, 48, 65]));
        assert_eq!(budget_tone(10.0), Tone::Rgb([239, 65, 67]));
        assert_eq!(budget_tone(100.0), Tone::Rgb([91, 220, 135]));
        assert_eq!(budget_tone(250.0), Tone::Rgb([91, 220, 135]));
        // Half way between two stops; a half goes to the even number.
        assert_eq!(budget_tone(5.0), Tone::Rgb([230, 56, 66]));
        assert_eq!(budget_tone(70.0), Tone::Rgb([168, 217, 102]));
    }

    #[test]
    fn a_tone_moves_part_of_the_way_to_another() {
        assert_eq!(Tone::Mint.mixed(Tone::Rgb(BACKGROUND), 0.45), Tone::Rgb([91, 132, 121]));
        assert_eq!(Tone::Red.mixed(Tone::Border, 0.0), Tone::Rgb([239, 98, 104]));
        assert_eq!(Tone::Red.mixed(Tone::Border, 7.0), Tone::Rgb([65, 79, 105]));
        assert_eq!(pulsed(Tone::Red, 0.0), Tone::Red);
    }

    #[test]
    fn text_from_a_file_cannot_drive_the_terminal() {
        assert_eq!(Span::plain("a\u{1b}[2Jb\u{7}\u{9b}c").text, "a [2Jb  c");
        assert_eq!(clean("left\u{202e}right\u{200b}\u{feff}\u{ad}"), "left right   ");
        assert_eq!(clean("naïve · 日本 ●"), "naïve · 日本 ●");
    }

    #[test]
    fn text_is_measured_in_the_cells_a_terminal_gives_it() {
        assert_eq!(cells("Main · 5h █▒╌"), 13);
        assert_eq!(cells("日本語"), 6);
        assert_eq!(cells("e\u{301}"), 1);
        assert_eq!(cells("🙂"), 2);
        assert_eq!(padded("abc", 5), "abc  ");
        assert_eq!(padded("abcdef", 4), "abcd");
        // A wide character that would overhang is left out, and its cell is padded.
        assert_eq!(padded("日本語", 5), "日本 ");
        assert_eq!(padded("a\u{7}b", 0), "");
        assert_eq!(right("7%", 4), "  7%");
        assert_eq!(right("100%", 3), "100%");
    }

    #[test]
    fn a_row_is_cut_and_padded_to_the_frame() {
        let border = Border::new(6);
        let row = [Span::new("ab", Tone::Muted), Span::new("cdefgh", Tone::Mint), Span::new("i", Tone::Red)];
        let framed = border.around(&row);
        assert_eq!(shown(&framed), "│abcdef│");
        assert_eq!(framed[2], Span::new("cdef", Tone::Mint));
        assert_eq!(shown(&border.around(&[Span::plain("ab")])), "│ab    │");
        // One cell is left: the wide character ends its span and the narrow one takes the cell.
        assert_eq!(shown(&border.around(&[Span::plain("abcde"), Span::plain("日本"), Span::plain("z")])), "│abcdez│");
        let thumb = Border { width: 2, glyph: '┃', tone: Tone::Muted };
        assert_eq!(thumb.around(&[]).last(), Some(&Span::new("┃", Tone::Muted)));
    }

    #[test]
    fn a_bar_shows_what_is_usable_returning_and_unmeasured() {
        let draw = |value, gain, unknown, size| shown(&bar(value, gain, unknown, size, Tone::Mint, 1.0, -1.0));
        assert_eq!(draw(50.0, 0.0, 0.0, 20), "██████████··········");
        assert_eq!(draw(100.0, 0.0, 0.0, 12), "████████████");
        assert_eq!(draw(0.0, 0.0, 0.0, 12), "············");
        // 33% of twenty cells is six and a half, and a little that is not drawn.
        assert_eq!(draw(33.0, 0.0, 0.0, 20), "██████▌·············");
        assert_eq!(draw(25.0, 25.0, 25.0, 20), "█████▒▒▒▒▒╌╌╌╌╌·····");
        assert_eq!(draw(90.0, 50.0, 50.0, 10), "█████████▒");
        assert_eq!(draw(-5.0, -5.0, -5.0, 0), "·");
        // A bar still growing into place.
        assert_eq!(shown(&bar(50.0, 50.0, 0.0, 20, Tone::Mint, 0.5, -1.0)), "█████▒▒▒▒▒··········");
    }

    #[test]
    fn a_highlight_travels_along_what_is_returning() {
        let lit = |shimmer| {
            let spans = bar(20.0, 40.0, 0.0, 10, Tone::Mint, 1.0, shimmer);
            spans.iter().filter(|span| span.text.starts_with('▒')).map(|span| span.text.chars().count()).collect::<Vec<_>>()
        };
        assert_eq!(lit(-1.0), [4]);
        assert_eq!(lit(0.0), [1, 3]);
        assert_eq!(lit(0.5), [2, 1, 1]);
        assert_eq!(lit(0.99), [3, 1]);
        assert_eq!(lit(1.0), [4]);
        let returning = Tone::Mint.mixed(Tone::Rgb(BACKGROUND), 0.45);
        assert_eq!(bar(20.0, 40.0, 0.0, 10, Tone::Mint, 1.0, 0.0)[1].tone, returning.mixed(WHITE, 0.5));
    }

    #[test]
    fn a_bar_grows_in_and_then_glides_to_each_new_value() {
        assert_eq!((reveal(0.0), reveal(0.9), reveal(5.0)), (1.0, 1.0, 1.0));
        assert!((reveal(0.45) - 0.875).abs() < 1e-12);
        assert_eq!((pulse(0.0), pulse(0.8)), (0.0, 1.0));
        let mut tweens = Tweens::default();
        // The first sight of a bar is not a move.
        assert_eq!(tweens.anchor("a", 80.0, 2.0), None);
        assert_eq!(tween(80.0, None, 2.0), 80.0);
        // A new target sets off from what was on screen.
        let glide = tweens.anchor("a", 60.0, 3.0);
        assert_eq!(glide, Some(Glide { from: 80.0, start: 3.0 }));
        assert_eq!((tween(60.0, glide, 3.0), tween(60.0, glide, 3.5), tween(60.0, glide, 9.0)), (80.0, 60.0, 60.0));
        assert!((tween(60.0, glide, 3.25) - 62.5).abs() < 1e-12);
        assert_eq!(settled(glide), 3.5);
        assert_eq!(settled(None), 0.9);
        // The same target again leaves the glide in flight, and forgets it once it lands.
        assert_eq!(tweens.anchor("a", 60.0, 3.25), glide);
        assert_eq!(tweens.anchor("a", 60.02, 3.4), glide);
        assert_eq!(tweens.anchor("a", 60.0, 3.5), None);
        // A target that moves in flight sets off from where the bar has got to.
        let again = tweens.anchor("a", 70.0, 4.0);
        let turned = tweens.anchor("a", 90.0, 4.25);
        assert_eq!(again, Some(Glide { from: 60.0, start: 4.0 }));
        assert_eq!(turned, Some(Glide { from: tween(70.0, again, 4.25), start: 4.25 }));
    }

    #[test]
    fn the_mascot_blinks_unless_motion_is_off() {
        assert_eq!((cat(0.0, true), cat(10.6, true), cat(10.59, true), cat(21.7, true)), ("(=^.^=)", "(=-.-=)", "(=^.^=)", "(=-.-=)"));
        assert_eq!(cat(10.7, false), "(=^.^=)");
    }

    #[test]
    fn a_line_names_a_colour_only_when_it_changes() {
        let row = [Span::new("ab", Tone::Mint), Span::new("cd", Tone::Mint), Span::plain("  "), Span { background: Some(Tone::Border), ..Span::new("e", Tone::Red) }, Span::plain("")];
        let mut line = String::new();
        ansi(&row, Colours::True, &mut line);
        assert_eq!(line, "\x1b[38;2;151;222;191m\x1b[48;2;18;23;35mabcd  \x1b[38;2;239;98;104m\x1b[48;2;65;79;105me\x1b[48;2;18;23;35m\x1b[K");
        let mut blank = String::new();
        ansi(&[Span::plain("   ")], Colours::Indexed, &mut blank);
        assert_eq!(blank, "\x1b[48;5;234m   \x1b[K");
    }

    #[test]
    fn a_terminal_without_full_colour_gets_the_nearest_fixed_one() {
        assert_eq!(indexed([255, 255, 255]), 231);
        assert_eq!(indexed([0, 0, 0]), 16);
        assert_eq!(indexed(BACKGROUND), 234);
        assert_eq!(indexed([128, 128, 128]), 244);
        assert_eq!(indexed(Tone::Peach.rgb()), 209);
        assert_eq!(indexed(Tone::Cyan.rgb()), 80);
    }
}

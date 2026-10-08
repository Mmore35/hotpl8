//! The cat `hotpl8 nyan` flies across the top of the dashboard: the sprite a release ships
//! in data/nyan-frames.json (THIRD_PARTY_NOTICES.md says whose it is), its rainbow tiled
//! across the frame, and stars drifting through the open sky.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use crate::paint::{Colours, Rgb, Span, Tone, BACKGROUND};
use crate::ps::*;

/// One drawing of the animation, a colour for each pixel as `frames[frame][row][column]`.
/// The first `period` columns are one wave of the rainbow; the cat follows them.
struct Art {
    period: usize,
    frames: Vec<Vec<Vec<Rgb>>>,
}

/// The two purpose-drawn pixel grids. Scaling one to another size destroys the face.
pub struct Sprite {
    full: Art,
    compact: Art,
}

const FULL_ROWS: usize = 18;
const COMPACT_ROWS: usize = 10;

thread_local! {
    static SOURCE: RefCell<PathBuf> = RefCell::new(PathBuf::new());
    static SPRITE: RefCell<Option<Rc<Sprite>>> = const { RefCell::new(None) };
}
/// The data/nyan-frames.json this request's release ships. It is read when it is first drawn.
pub fn set_source(file: PathBuf) {
    SOURCE.with(|cell| *cell.borrow_mut() = file);
    SPRITE.with(|cell| *cell.borrow_mut() = None);
}
pub fn sprite() -> R<Rc<Sprite>> {
    if let Some(known) = SPRITE.with(|cell| cell.borrow().clone()) {
        return Ok(known);
    }
    let Some(read) = crate::json::read_file(&SOURCE.with(|cell| cell.borrow().clone()))? else {
        return unshipped();
    };
    let sprite = Rc::new(Sprite::read(&read)?);
    SPRITE.with(|cell| *cell.borrow_mut() = Some(sprite.clone()));
    Ok(sprite)
}

fn unshipped<T>() -> R<T> {
    unreadable_as("This copy of HotPl8 has no data/nyan-frames.json it can draw.")
}

impl Sprite {
    fn read(data: &V) -> R<Sprite> {
        let mut palette: Vec<(char, Rgb)> = Vec::new();
        for (key, colour) in data.g("palette")?.props()? {
            let mut letters = key.chars();
            let parts: Vec<Option<u8>> = colour.s()?.split(';').map(|part| part.parse().ok()).collect();
            match (letters.next(), letters.next(), parts.as_slice()) {
                (Some(letter), None, [Some(red), Some(green), Some(blue)]) => palette.push((letter, [*red, *green, *blue])),
                _ => return unshipped(),
            }
        }
        let art = |art: &V, rows: usize| -> R<Art> {
            let mut frames = Vec::new();
            for frame in art.g("frames")?.arr() {
                let mut pixels = Vec::new();
                for row in frame.arr() {
                    let colours: Option<Vec<Rgb>> = row.s()?.chars().map(|letter| palette.iter().find(|(known, _)| *known == letter).map(|(_, rgb)| *rgb)).collect();
                    match colours {
                        Some(colours) => pixels.push(colours),
                        None => return unshipped(),
                    }
                }
                frames.push(pixels);
            }
            let period = usize::try_from(art.g("period")?.to_int()?).unwrap_or(0);
            let width = frames.first().and_then(|frame: &Vec<Vec<Rgb>>| frame.first()).map_or(0, Vec::len);
            let regular = frames.iter().all(|frame| frame.len() == rows && frame.iter().all(|row| row.len() == width));
            if frames.is_empty() || !regular || period == 0 || period > width {
                return unshipped();
            }
            Ok(Art { period, frames })
        };
        Ok(Sprite { full: art(data, FULL_ROWS)?, compact: art(&data.g("compact")?, COMPACT_ROWS)? })
    }
}

/// How the cat is drawn in the room there is.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Scene {
    compact: bool,
    /// Two whole cells a pixel instead of half a cell: Apple's Terminal draws block glyphs
    /// with the font's leading, which leaves stripes between rows.
    cells: bool,
}

impl Scene {
    /// The scene for a frame that wide and tall with `summary` rows of overview, or none
    /// when it would leave fewer than four rows for the accounts.
    pub fn fitting(width: usize, height: usize, summary: usize, colours: Colours) -> Option<Scene> {
        let budget = height as i64 - 7 - summary as i64 - 4;
        if colours == Colours::Indexed {
            return if width >= 100 && budget >= 18 {
                Some(Scene { compact: false, cells: true })
            } else if width >= 66 && budget >= 10 {
                Some(Scene { compact: true, cells: true })
            } else {
                None
            };
        }
        if budget < 5 {
            return None;
        }
        Some(Scene { compact: !(width >= 82 && height >= 36 && budget >= 9), cells: false })
    }

    /// How many terminal rows it takes.
    pub fn rows(self) -> usize {
        let pixels = if self.compact { COMPACT_ROWS } else { FULL_ROWS };
        if self.cells {
            pixels
        } else {
            pixels / 2
        }
    }
}

/// What one terminal cell of the scene shows. Open sky has no colour of its own.
#[derive(Clone, Copy, PartialEq)]
struct Cell {
    glyph: char,
    tone: Option<Tone>,
    background: Option<Tone>,
}
const SKY: Cell = Cell { glyph: ' ', tone: None, background: None };

/// A star: the row it keeps (of nine), the column it starts from, the cells it drifts
/// left each second, and where in its twinkle it starts.
const STARS: [(usize, f64, f64, f64); 11] =
    [(0, 7.0, 4.0, 0.0), (0, 53.0, 3.0, 2.0), (1, 29.0, 3.5, 1.0), (2, 71.0, 4.5, 3.0), (3, 17.0, 3.0, 2.0), (4, 47.0, 4.0, 0.0), (5, 3.0, 3.5, 1.0), (6, 61.0, 3.0, 3.0), (7, 35.0, 4.5, 2.0), (8, 23.0, 3.5, 0.0), (8, 79.0, 4.0, 1.0)];
const TWINKLE: [Tone; 4] = [Tone::Muted, Tone::Text, Tone::Muted, Tone::Border];

/// The cat without colour or motion, for output that is not a terminal.
pub fn plain() -> Vec<Vec<Span>> {
    ["  ~~~~~~[::::] /\\_/\\", "  ~~~~~~[::::]( o.o )  hotpl8 / nyan", "         \"  \"  \" \""].iter().map(|line| vec![Span::plain(line)]).collect()
}

impl Sprite {
    /// Row `row` of the scene at that instant, for a frame `width` cells wide inside its edges.
    pub fn row(&self, scene: Scene, seconds: f64, width: usize, row: usize) -> Vec<Span> {
        let art = if scene.compact { &self.compact } else { &self.full };
        let frame = &art.frames[(seconds * 12.0).floor().max(0.0) as usize % art.frames.len()];
        let inner = width.saturating_sub(2).max(26);
        let sprite = frame[0].len() as i64;
        let pixels = if scene.cells { inner / 2 } else { inner } as i64;
        // The cat sits a fifth of the way in from the right; the wave tiles leftward from it.
        let cat = (pixels - sprite - (pixels / 5).max(3)).max(0);
        let tone = |rgb: Rgb| Tone::Rgb(rgb);
        let mut cells: Vec<Cell> = (0..inner as i64)
            .map(|x| {
                let column = if scene.cells { x / 2 } else { x } - cat;
                if column >= sprite {
                    return SKY;
                }
                let at = if column >= 0 { column } else { column.rem_euclid(art.period as i64) } as usize;
                let (upper, lower) = if scene.cells { (frame[row][at], frame[row][at]) } else { (frame[row * 2][at], frame[row * 2 + 1][at]) };
                if upper == BACKGROUND && lower == BACKGROUND {
                    SKY
                } else {
                    Cell { glyph: if scene.cells { ' ' } else { '▀' }, tone: Some(tone(upper)), background: Some(tone(lower)) }
                }
            })
            .collect();
        for (index, (star_row, column, speed, phase)) in STARS.iter().enumerate() {
            if (star_row * scene.rows() / 9).min(scene.rows() - 1) != row {
                continue;
            }
            let x = (column - seconds * speed * 3.0).floor().rem_euclid(inner as f64) as usize;
            // A star shows only through open sky, and the first of two stars keeps the cell.
            if cells[x] != SKY {
                continue;
            }
            let twinkle = TWINKLE[(seconds * 1.25 + phase).floor() as usize % 4];
            cells[x] = if scene.cells {
                Cell { glyph: ' ', tone: Some(twinkle), background: Some(twinkle) }
            } else {
                Cell { glyph: if index % 2 == 1 { '▄' } else { '▀' }, tone: Some(twinkle), background: None }
            };
        }
        let mut spans = vec![Span::plain(" ")];
        let mut start = 0;
        while start < cells.len() {
            let cell = cells[start];
            let length = cells[start..].iter().take_while(|next| **next == cell).count();
            spans.push(Span { text: cell.glyph.to_string().repeat(length), tone: cell.tone.unwrap_or(Tone::Text), background: cell.background });
            start += length;
        }
        spans
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paint::text;

    fn shipped() -> Rc<Sprite> {
        set_source(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../data/nyan-frames.json"));
        sprite().ok().unwrap()
    }

    const HALF: Scene = Scene { compact: false, cells: false };

    #[test]
    fn the_scene_is_as_large_as_the_room_allows() {
        let rows = |width, height, summary, colours| Scene::fitting(width, height, summary, colours).map(Scene::rows);
        assert_eq!(rows(108, 40, 4, Colours::True), Some(9));
        assert_eq!(rows(108, 35, 4, Colours::True), Some(5));
        assert_eq!(rows(81, 40, 4, Colours::True), Some(5));
        assert_eq!(rows(108, 36, 16, Colours::True), Some(9));
        assert_eq!(rows(108, 36, 17, Colours::True), Some(5));
        assert_eq!(rows(108, 19, 4, Colours::True), None);
        assert_eq!(rows(108, 20, 4, Colours::True), Some(5));
        assert_eq!(rows(108, 40, 4, Colours::Indexed), Some(18));
        assert_eq!(rows(99, 40, 4, Colours::Indexed), Some(10));
        assert_eq!(rows(108, 32, 4, Colours::Indexed), Some(10));
        assert_eq!(rows(65, 40, 4, Colours::Indexed), None);
        assert_eq!(rows(108, 24, 4, Colours::Indexed), None);
    }

    #[test]
    fn the_shipped_sprite_is_two_grids_of_twelve_frames() {
        let sprite = shipped();
        assert_eq!((sprite.full.frames.len(), sprite.full.frames[0].len(), sprite.full.frames[0][0].len(), sprite.full.period), (12, 18, 48, 16));
        assert_eq!((sprite.compact.frames.len(), sprite.compact.frames[0].len(), sprite.compact.frames[0][0].len(), sprite.compact.period), (12, 10, 32, 8));
    }

    #[test]
    fn a_sprite_that_cannot_be_drawn_is_refused() {
        let shipped = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../data/nyan-frames.json")).unwrap();
        let refused = |edited: String| match Sprite::read(&crate::json::parse(&edited, "").ok().unwrap()) {
            Ok(_) => "drawn".to_string(),
            Err(stop) => stop.message(),
        };
        assert_eq!(refused(shipped.clone()), "drawn");
        let why = "This copy of HotPl8 has no data/nyan-frames.json it can draw.";
        // A colour no pixel can name, a wave wider than the drawing, and a row cut short.
        assert_eq!(refused(shipped.replacen("\"18;23;35\"", "\"18;23\"", 1)), why);
        assert_eq!(refused(shipped.replacen("\"period\": 16", "\"period\": 49", 1)), why);
        assert_eq!(refused(shipped.replacen(",,,,", ",,,", 1)), why);
        assert_eq!(refused(shipped.replacen(",,,,", ",,,?", 1)), why);
    }

    #[test]
    fn every_row_fills_the_frame_and_the_rainbow_reaches_its_left_edge() {
        let sprite = shipped();
        for (scene, width) in [(HALF, 108), (Scene { compact: true, cells: false }, 60), (Scene { compact: true, cells: true }, 70), (Scene { compact: false, cells: true }, 108), (HALF, 10)] {
            for row in 0..scene.rows() {
                let spans = sprite.row(scene, 1.3, width, row);
                assert_eq!(crate::paint::cells(&text(&spans)), 1 + width.saturating_sub(2).max(26));
            }
        }
        // The wave is drawn from the first cell, in a colour of the sprite.
        let middle = sprite.row(HALF, 0.0, 108, 4);
        assert!(middle[1].text.starts_with('▀') && matches!(middle[1].tone, Tone::Rgb(_)) && middle[1].background.is_some());
        // Right of the cat is open sky.
        assert_eq!(middle.last().map(|span| (span.text.trim(), span.background)), Some(("", None)));
    }

    #[test]
    fn the_cat_runs_through_its_frames_and_the_stars_drift() {
        let sprite = shipped();
        let scene = |seconds: f64| (0..9).map(|row| sprite.row(HALF, seconds, 108, row)).collect::<Vec<_>>();
        assert!(scene(0.0) != scene(1.0 / 12.0));
        // Twelve frames a second, twelve frames: the cat is where it was a second on, the stars are not.
        assert!(scene(0.0) != scene(1.0));
        // The first star starts behind the rainbow, comes round into the open sky right of the cat
        // and moves twelve cells left a second.
        let star = |seconds: f64| {
            let row = sprite.row(HALF, seconds, 108, 0);
            let at = row.iter().position(|span| TWINKLE.contains(&span.tone) && span.background.is_none() && span.text != " ".repeat(span.text.chars().count()));
            at.map(|at| crate::paint::cells(&text(&row[..at])))
        };
        assert_eq!((star(0.0), star(1.0), star(1.5)), (None, Some(102), Some(96)));
    }
}

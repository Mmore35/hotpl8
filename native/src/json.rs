//! State files, with the number types ConvertFrom-Json gives them on each PowerShell
//! edition, and the two ways a value leaves the reader: JSON text, and the typed dump the
//! parity suite compares.
//!
//! The parser accepts strict JSON only, which is all HotPl8 writes. Where PowerShell's own
//! parsers are looser (comments, trailing commas, date text, huge numbers, repeated names)
//! the file is refused by name, with the line and column where it stops being strict JSON.

use crate::num::Dec;
use crate::ps::{desktop, printable, unreadable, unreadable_as, Props, R, V};
use std::cell::RefCell;
use std::rc::Rc;

const MAX_BYTES: usize = 1_000_000;
const MAX_DEPTH: usize = 20;
/// A question's object and the list an argument may be.
const ASKED_DEPTH: usize = 2;
/// The frames of a replay are the largest question: the file of a day's status, one a line.
pub const MAX_ASKED_BYTES: usize = 16_000_000;
/// How deep Windows PowerShell follows a message from another program.
const MAX_FOREIGN_DEPTH: usize = 100;
const FORBIDDEN_NAMES: [&str; 6] = ["psobject", "psbase", "psadapted", "psextended", "pstypenames", "__type"];

/// The file's value, or `None` when the file does not exist.
pub fn read_file(path: &std::path::Path) -> R<Option<V>> {
    let name = || path.file_name().unwrap_or(path.as_os_str()).to_string_lossy().into_owned();
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(parse_bytes(&bytes, &name())?)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // A missing directory in the middle of the path reads as "not found" too.
            Ok(None)
        }
        Err(error) => unreadable_as(format!("{} cannot be opened: {error}.", name())),
    }
}

/// `name` is what the user is told the document is, should it not be one.
pub fn parse_bytes(bytes: &[u8], name: &str) -> R<V> {
    if bytes.len() > MAX_BYTES {
        return unreadable_as(format!("{name} is larger than any file HotPl8 writes."));
    }
    // UTF-8, with or without its mark, is the one encoding HotPl8 writes.
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    let Ok(text) = std::str::from_utf8(bytes) else {
        return unreadable_as(format!("{name} is not UTF-8 text."));
    };
    parse(text, name)
}

/// A JSON document whose top level is an object.
pub fn parse(text: &str, name: &str) -> R<V> {
    let mut parser = Parser { bytes: text.as_bytes(), at: 0, foreign: false, asked: false };
    parser.document().map_err(|stop| {
        stop.described(|| {
            let before = &text[..parser.at.min(text.len())];
            let line = before.matches('\n').count() + 1;
            let column = before.rsplit('\n').next().unwrap_or("").chars().count() + 1;
            format!("{name} is not JSON as HotPl8 writes it (line {line}, column {column}).")
        })
    })
}

/// A question PowerShell asks: one object whose members are the question's arguments. An
/// argument is a document HotPl8 wrote or a list of them, so it lies that much deeper than
/// a document read from its file, and several together can be larger than any one file.
pub fn parse_asked(bytes: &[u8]) -> R<V> {
    const WHAT: &str = "The question";
    if bytes.len() > MAX_ASKED_BYTES {
        return unreadable_as(format!("{WHAT} is larger than any HotPl8 asks."));
    }
    // Windows PowerShell opens the pipe it writes a question into with the mark.
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    let Ok(text) = std::str::from_utf8(bytes) else {
        return unreadable_as(format!("{WHAT} is not UTF-8 text."));
    };
    let mut parser = Parser { bytes: text.as_bytes(), at: 0, foreign: false, asked: true };
    parser.document().map_err(|stop| stop.described(|| format!("{WHAT} is not JSON as HotPl8 writes it.")))
}

/// One message from another program, or a file another program keeps: any JSON value.
/// HotPl8 asks such a value only for members it names, so a member it has no name for
/// (none at all, one outside printable ASCII, one PowerShell keeps for itself) is passed
/// over with everything under it, and a number HotPl8 would not write is read as the
/// double nearest it. Two members of one name are refused, as PowerShell refuses them.
pub fn parse_foreign(text: &str) -> R<V> {
    let mut parser = Parser { bytes: text.as_bytes(), at: 0, foreign: true, asked: false };
    parser.blank();
    let value = parser.value(0)?;
    parser.blank();
    if parser.at != parser.bytes.len() {
        return unreadable();
    }
    Ok(value)
}

/// A line holding one JSON array of strings: how the parity suite spells a request.
pub fn strings(line: &str) -> Option<Vec<String>> {
    let mut parser = Parser { bytes: line.as_bytes(), at: 0, foreign: false, asked: false };
    parser.blank();
    if parser.peek() != Some(b'[') {
        return None;
    }
    let V::Arr(items) = parser.array(0).ok()? else { return None };
    parser.blank();
    if parser.at != parser.bytes.len() {
        return None;
    }
    items.iter().map(|item| item.as_str().map(str::to_owned)).collect()
}

struct Parser<'a> {
    bytes: &'a [u8],
    at: usize,
    /// The text is another program's, not a file HotPl8 wrote.
    foreign: bool,
    /// The text is a question: documents HotPl8 wrote, inside the object that names them.
    asked: bool,
}

impl Parser<'_> {
    fn document(&mut self) -> R<V> {
        self.blank();
        if self.peek() != Some(b'{') {
            return unreadable();
        }
        let value = self.value(0)?;
        self.blank();
        if self.at != self.bytes.len() {
            return unreadable();
        }
        Ok(value)
    }
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }
    fn blank(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\r' | b'\n')) {
            self.at += 1;
        }
    }
    #[track_caller]
    fn expect(&mut self, text: &str) -> R<()> {
        if self.bytes[self.at..].starts_with(text.as_bytes()) {
            self.at += text.len();
            Ok(())
        } else {
            unreadable()
        }
    }

    fn value(&mut self, depth: usize) -> R<V> {
        if depth > if self.foreign { MAX_FOREIGN_DEPTH } else if self.asked { MAX_DEPTH + ASKED_DEPTH } else { MAX_DEPTH } {
            return unreadable();
        }
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(V::Str(self.string()?.into())),
            Some(b't') => self.expect("true").map(|_| V::Bool(true)),
            Some(b'f') => self.expect("false").map(|_| V::Bool(false)),
            Some(b'n') => self.expect("null").map(|_| V::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => unreadable(),
        }
    }

    fn object(&mut self, depth: usize) -> R<V> {
        self.at += 1;
        let mut items: Vec<(Rc<str>, V)> = Vec::new();
        self.blank();
        if self.peek() == Some(b'}') {
            self.at += 1;
        } else {
            loop {
                self.blank();
                if self.peek() != Some(b'"') {
                    return unreadable();
                }
                let name = self.string()?;
                let lower = name.to_ascii_lowercase();
                let unnamed = name.is_empty() || !printable(&name) || FORBIDDEN_NAMES.contains(&lower.as_str());
                if unnamed && !self.foreign {
                    return unreadable();
                }
                if !unnamed && items.iter().any(|(known, _)| known.eq_ignore_ascii_case(&name)) {
                    return unreadable();
                }
                self.blank();
                self.expect(":")?;
                self.blank();
                let value = self.value(depth + 1)?;
                if !unnamed {
                    items.push((name.into(), value));
                }
                self.blank();
                match self.peek() {
                    Some(b',') => self.at += 1,
                    Some(b'}') => {
                        self.at += 1;
                        break;
                    }
                    _ => return unreadable(),
                }
            }
        }
        Ok(V::Obj(Rc::new(RefCell::new(Props { items }))))
    }

    fn array(&mut self, depth: usize) -> R<V> {
        self.at += 1;
        let mut items = Vec::new();
        self.blank();
        if self.peek() == Some(b']') {
            self.at += 1;
        } else {
            loop {
                self.blank();
                items.push(self.value(depth + 1)?);
                self.blank();
                match self.peek() {
                    Some(b',') => self.at += 1,
                    Some(b']') => {
                        self.at += 1;
                        break;
                    }
                    _ => return unreadable(),
                }
            }
        }
        Ok(V::Arr(Rc::new(items)))
    }

    fn hex4(&mut self) -> R<u32> {
        let Some(digits) = self.bytes.get(self.at..self.at + 4) else { return unreadable() };
        let Ok(text) = std::str::from_utf8(digits) else { return unreadable() };
        if !text.bytes().all(|b| b.is_ascii_hexdigit()) {
            return unreadable();
        }
        self.at += 4;
        Ok(u32::from_str_radix(text, 16).unwrap())
    }

    fn string(&mut self) -> R<String> {
        self.at += 1;
        let mut out = String::new();
        loop {
            let start = self.at;
            while !matches!(self.peek(), None | Some(b'"' | b'\\' | 0..=0x1f)) {
                self.at += 1;
            }
            // The input is valid UTF-8 and the scan stops only at ASCII bytes.
            out.push_str(std::str::from_utf8(&self.bytes[start..self.at]).unwrap());
            match self.peek() {
                Some(b'"') => {
                    self.at += 1;
                    break;
                }
                Some(b'\\') => {
                    self.at += 1;
                    let escape = self.peek();
                    self.at += 1;
                    match escape {
                        Some(b'"') => out.push('"'),
                        Some(b'\\') => out.push('\\'),
                        Some(b'/') => out.push('/'),
                        Some(b'b') => out.push('\u{8}'),
                        Some(b'f') => out.push('\u{c}'),
                        Some(b'n') => out.push('\n'),
                        Some(b'r') => out.push('\r'),
                        Some(b't') => out.push('\t'),
                        Some(b'u') => {
                            let unit = self.hex4()?;
                            let code = if (0xd800..0xdc00).contains(&unit) {
                                self.expect("\\u")?;
                                let low = self.hex4()?;
                                if !(0xdc00..0xe000).contains(&low) {
                                    return unreadable();
                                }
                                0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00)
                            } else {
                                unit
                            };
                            let Some(c) = char::from_u32(code) else { return unreadable() };
                            out.push(c);
                        }
                        _ => return unreadable(),
                    }
                }
                _ => return unreadable(),
            }
        }
        // Windows PowerShell turns "\/Date(...)\/" text into a date.
        if out.contains("/Date(") && !self.foreign {
            return unreadable();
        }
        Ok(out)
    }

    fn number(&mut self) -> R<V> {
        let start = self.at;
        let negative = self.peek() == Some(b'-');
        if negative {
            self.at += 1;
        }
        let whole_start = self.at;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.at += 1;
        }
        let whole = &self.bytes[whole_start..self.at];
        if whole.is_empty() || (whole.len() > 1 && whole[0] == b'0') {
            return unreadable();
        }
        let mut fraction: &[u8] = &[];
        if self.peek() == Some(b'.') {
            self.at += 1;
            let fraction_start = self.at;
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.at += 1;
            }
            fraction = &self.bytes[fraction_start..self.at];
            if fraction.is_empty() {
                return unreadable();
            }
        }
        // PowerShell writes a double below 0.0001 or from 1E+15 with an exponent.
        let exponent = matches!(self.peek(), Some(b'e' | b'E'));
        if exponent {
            self.at += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.at += 1;
            }
            let power = self.at;
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.at += 1;
            }
            if self.at == power {
                return unreadable();
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E' | b'.' | b'+' | b'-')) {
            return unreadable();
        }
        let token = std::str::from_utf8(&self.bytes[start..self.at]).unwrap();
        let all_zero = whole.iter().chain(fraction).all(|b| *b == b'0');
        let unwritten = whole.len() + fraction.len() > 28 || (negative && all_zero);
        if self.foreign && !exponent && (unwritten || (fraction.is_empty() && token.parse::<i64>().is_err())) {
            let Ok(value) = token.parse::<f64>() else { return unreadable() };
            return crate::ps::dbl(if all_zero { 0.0 } else { value });
        }
        if unwritten {
            return unreadable();
        }
        if exponent {
            // A double on both editions, whatever else the number holds. One too large for
            // a double is refused by Windows PowerShell and infinite in PowerShell 7, and
            // one too small for a full double is nothing HotPl8 writes.
            let Ok(value) = token.parse::<f64>() else { return unreadable() };
            if value.is_subnormal() || (value == 0.0 && !all_zero) {
                return unreadable();
            }
            return crate::ps::dbl(value);
        }
        if fraction.is_empty() {
            let Ok(value) = token.parse::<i64>() else { return unreadable() };
            return Ok(match i32::try_from(value) {
                Ok(small) if desktop() => V::I32(small),
                _ => V::I64(value),
            });
        }
        if desktop() {
            let digits: String = whole.iter().chain(fraction).map(|b| *b as char).collect();
            let Ok(mant) = digits.parse::<u128>() else { return unreadable() };
            return Ok(V::Dec(Dec { neg: negative, mant, scale: fraction.len() as u8 }));
        }
        let Ok(value) = token.parse::<f64>() else { return unreadable() };
        crate::ps::dbl(value)
    }
}

/// A number as this edition reads its text.
pub fn number(text: &str) -> R<V> {
    let mut parser = Parser { bytes: text.as_bytes(), at: 0, foreign: false, asked: false };
    let value = parser.number()?;
    if parser.at == text.len() {
        Ok(value)
    } else {
        unreadable()
    }
}

fn dump_text(text: &str, out: &mut String) {
    for unit in text.encode_utf16() {
        match unit {
            92 => out.push_str("\\\\"),
            32..=126 => out.push(unit as u8 as char),
            _ => out.push_str(&format!("\\u{unit:04x}")),
        }
    }
}

fn dump_node(value: &V, indent: usize, label: &str, out: &mut String) -> R<()> {
    let pad = " ".repeat(indent);
    out.push_str(&pad);
    dump_text(label, out);
    if !label.is_empty() {
        out.push_str(": ");
    }
    match value {
        V::Null => out.push('n'),
        V::Bool(b) => out.push_str(if *b { "b:true" } else { "b:false" }),
        V::I32(x) => out.push_str(&format!("i:{x}")),
        V::I64(x) => out.push_str(&format!("l:{x}")),
        V::Dec(x) => out.push_str(&format!("m:{}", x.text())),
        V::Dbl(x) => out.push_str(&format!("d:{:016x}", x.to_bits())),
        V::Str(text) => {
            out.push_str("s:");
            dump_text(text, out);
        }
        V::Arr(items) => {
            out.push_str("[\n");
            for item in items.iter() {
                dump_node(item, indent + 1, "", out)?;
            }
            out.push_str(&pad);
            out.push(']');
        }
        V::Obj(o) => {
            out.push_str("{\n");
            for (name, item) in o.borrow().items.iter() {
                dump_node(item, indent + 1, name, out)?;
            }
            out.push_str(&pad);
            out.push('}');
        }
        // PowerShell lists a hash table in an order of its own.
        V::Hash(_) => return unreadable(),
    }
    out.push('\n');
    Ok(())
}

/// The typed dump tests/parity/referee.ps1 writes for the same value.
pub fn dump(value: &V) -> R<String> {
    let mut out = String::new();
    dump_node(value, 0, "", &mut out)?;
    Ok(out)
}

fn write_text(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            ' '..='~' => out.push(c),
            _ => {
                let mut units = [0u16; 2];
                for unit in c.encode_utf16(&mut units) {
                    out.push_str(&format!("\\u{unit:04x}"));
                }
            }
        }
    }
    out.push('"');
}

fn write_node(value: &V, depth: usize, limit: usize, out: &mut String) -> R<()> {
    // Past its -Depth, ConvertTo-Json prints type names instead of values.
    if depth > limit {
        return unreadable();
    }
    let pad = "  ".repeat(depth + 1);
    match value {
        V::Null => out.push_str("null"),
        V::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        V::I32(x) => out.push_str(&x.to_string()),
        V::I64(x) => out.push_str(&x.to_string()),
        V::Dec(x) => out.push_str(&x.text()),
        V::Dbl(x) if x.is_finite() => out.push_str(&crate::num::double_json(*x)),
        V::Dbl(_) | V::Hash(_) => return unreadable(),
        V::Str(text) => write_text(text, out),
        V::Arr(items) if items.is_empty() => out.push_str("[]"),
        V::Arr(items) => {
            out.push_str("[\n");
            for (index, item) in items.iter().enumerate() {
                out.push_str(&pad);
                write_node(item, depth + 1, limit, out)?;
                out.push_str(if index + 1 < items.len() { ",\n" } else { "\n" });
            }
            out.push_str(&"  ".repeat(depth));
            out.push(']');
        }
        V::Obj(o) => {
            let props = o.borrow();
            if props.items.is_empty() {
                out.push_str("{}");
                return Ok(());
            }
            out.push_str("{\n");
            for (index, (name, item)) in props.items.iter().enumerate() {
                out.push_str(&pad);
                write_text(name, out);
                out.push_str(": ");
                write_node(item, depth + 1, limit, out)?;
                out.push_str(if index + 1 < props.items.len() { ",\n" } else { "\n" });
            }
            out.push_str(&"  ".repeat(depth));
            out.push('}');
        }
    }
    Ok(())
}

/// `$value | ConvertTo-Json -Depth $limit`, in the reader's own layout: the same data,
/// not the same spacing. Every character outside printable ASCII is escaped.
pub fn write(value: &V, limit: usize) -> R<String> {
    let mut out = String::new();
    write_node(value, 0, limit, &mut out)?;
    Ok(out)
}

fn compact_node(value: &V, depth: usize, limit: usize, out: &mut String) -> R<()> {
    if depth > limit {
        return unreadable();
    }
    match value {
        V::Arr(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                compact_node(item, depth + 1, limit, out)?;
            }
            out.push(']');
        }
        V::Obj(o) => {
            out.push('{');
            for (index, (name, item)) in o.borrow().items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_text(name, out);
                out.push(':');
                compact_node(item, depth + 1, limit, out)?;
            }
            out.push('}');
        }
        scalar => write_node(scalar, depth, limit, out)?,
    }
    Ok(())
}

/// `$value | ConvertTo-Json -Depth $limit -Compress`: the same data on one line.
pub fn compact(value: &V, limit: usize) -> R<String> {
    let mut out = String::new();
    compact_node(value, 0, limit, &mut out)?;
    Ok(out)
}

/// One string as JSON spells it.
pub fn text(value: &str) -> String {
    let mut out = String::new();
    write_text(value, &mut out);
    out
}

/// `$value | ConvertTo-Json -Compress`, for a flat record of text and whole numbers: one
/// line of an event log.
pub fn line(record: &[(&str, V)]) -> R<String> {
    let mut out = String::from("{");
    for (index, (name, value)) in record.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        write_text(name, &mut out);
        out.push(':');
        match value {
            V::Str(text) => write_text(text, &mut out),
            V::I32(x) => out.push_str(&x.to_string()),
            _ => return unreadable(),
        }
    }
    out.push('}');
    Ok(out)
}

/// A file the collector keeps for itself may outgrow what `status` reads: a fortnight of
/// usage samples, or a native program's whole answer.
const MAX_COLLECTED_BYTES: usize = 16_000_000;

/// Read-Hotpl8Json: the file's value, or null when there is no such file or it does not
/// hold a document HotPl8 reads. A collector starts over from nothing rather than stop.
pub fn read_or_null(path: &std::path::Path) -> V {
    let Ok(bytes) = std::fs::read(path) else { return V::Null };
    if bytes.len() > MAX_COLLECTED_BYTES {
        return V::Null;
    }
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes);
    match std::str::from_utf8(bytes) {
        Ok(text) => parse(text, "").unwrap_or(V::Null),
        Err(_) => V::Null,
    }
}

/// Whether two parsed values hold the same data with the same types.
#[cfg(test)]
pub fn same(left: &V, right: &V) -> bool {
    match (left, right) {
        (V::Null, V::Null) => true,
        (V::Bool(a), V::Bool(b)) => a == b,
        (V::I32(a), V::I32(b)) => a == b,
        (V::I64(a), V::I64(b)) => a == b,
        (V::Dec(a), V::Dec(b)) => a == b,
        (V::Dbl(a), V::Dbl(b)) => a.to_bits() == b.to_bits(),
        (V::Str(a), V::Str(b)) => a == b,
        (V::Arr(a), V::Arr(b)) => a.len() == b.len() && a.iter().zip(b.iter()).all(|(x, y)| same(x, y)),
        (V::Obj(a), V::Obj(b)) => {
            let (a, b) = (a.borrow(), b.borrow());
            a.items.len() == b.items.len() && a.items.iter().zip(b.items.iter()).all(|((k, x), (l, y))| k == l && same(x, y))
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ps::set_core;

    #[test]
    fn numbers_take_each_editions_types() {
        let text = r#"{"a":5,"b":3000000000,"c":45.0,"d":-0.5,"e":"xé\\","f":[true,null],"g":{}}"#;
        set_core(false);
        assert_eq!(dump(&parse(text, "test").ok().unwrap()).ok().unwrap(), "{\n a: i:5\n b: l:3000000000\n c: m:45.0\n d: m:-0.5\n e: s:x\\u00e9\\\\\n f: [\n  b:true\n  n\n ]\n g: {\n }\n}\n");
        set_core(true);
        assert_eq!(
            dump(&parse(text, "test").ok().unwrap()).ok().unwrap(),
            "{\n a: l:5\n b: l:3000000000\n c: d:4046800000000000\n d: d:bfe0000000000000\n e: s:x\\u00e9\\\\\n f: [\n  b:true\n  n\n ]\n g: {\n }\n}\n"
        );
    }

    #[test]
    fn anything_but_strict_json_is_refused_by_name_and_place() {
        for text in [
            "",
            "null",
            "[1]",
            r#"{"a":1,}"#,
            r#"{"a":1} x"#,
            r#"{"a":1,"A":2}"#,
            r#"{"":1}"#,
            r#"{"é":1}"#,
            r#"{"psobject":1}"#,
            r#"{"__type":"x"}"#,
            r#"{"a":"\/Date(1791000000000)\/"}"#,
            r#"{"a":"\ud800"}"#,
            r#"{"a":1e}"#,
            r#"{"a":1e+}"#,
            r#"{"a":1e3.5}"#,
            r#"{"a":1e3e3}"#,
            r#"{"a":1e400}"#,
            r#"{"a":1e-400}"#,
            r#"{"a":5E-324}"#,
            r#"{"a":-0e0}"#,
            r#"{"a":-0}"#,
            r#"{"a":-0.0}"#,
            r#"{"a":9223372036854775808}"#,
            r#"{"a":0.12345678901234567890123456789}"#,
            r#"{"a":01}"#,
            r#"{"a":'x'}"#,
            r#"{"a":1 /* c */}"#,
            "{\"a\":\"line\nbreak\"}",
        ] {
            assert!(parse(text, "test").is_err_and(|stop| !stop.thrown()), "{text}");
        }
        // A number with an exponent is a double, as PowerShell reads the ones it wrote.
        for (text, value) in [("1e3", 1000.0), ("3.8E+1", 38.0), ("1E-05", 0.00001), ("5.0000000001659828E-05", 100.0 - 99.99995), ("-1.5e2", -150.0), ("0e0", 0.0), ("2.2250738585072014E-308", f64::MIN_POSITIVE)] {
            assert!(matches!(parse(&format!("{{\"a\":{text}}}"), "test").unwrap().g("a").unwrap(), V::Dbl(read) if read == value), "{text}");
        }
        let said = |bytes: &[u8]| parse_bytes(bytes, "policy.json").err().map(|stop| stop.message());
        assert_eq!(said(b"\xef\xbb\xbf{}"), None);
        assert_eq!(said(&[0xff, 0xfe, b'{', 0, b'}', 0]).unwrap(), "policy.json is not UTF-8 text.");
        assert_eq!(said(b"{\"a\":\"\xff\"}").unwrap(), "policy.json is not UTF-8 text.");
        assert_eq!(said(b"").unwrap(), "policy.json is not JSON as HotPl8 writes it (line 1, column 1).");
        assert_eq!(said(b"{\r\n  \"a\": 1,\r\n  \"b\": 1,\r\n}").unwrap(), "policy.json is not JSON as HotPl8 writes it (line 4, column 1).");
        assert_eq!(said("{\"a\": \"\u{e9}\u{1F431}\", \"b\": -}".as_bytes()).unwrap(), "policy.json is not JSON as HotPl8 writes it (line 1, column 19).");
        assert_eq!(said(&vec![b' '; MAX_BYTES + 1]).unwrap(), "policy.json is larger than any file HotPl8 writes.");
    }

    #[test]
    fn another_programs_message_is_read_for_the_members_hotpl8_names() {
        set_core(false);
        let read = |text: &str| parse_foreign(text).ok().map(|value| compact(&value, 24).ok().unwrap());
        let message = r#"{"id":2,"result":{"projects":{"C:\\caf\u00e9":{"a":1},"":2,"psobject":3,"plain":4},"at":"\/Date(5)\/","zero":-0}}"#;
        assert_eq!(read(message).unwrap(), r#"{"id":2,"result":{"projects":{"plain":4},"at":"/Date(5)/","zero":0}}"#);
        assert_eq!(read(" 5 ").unwrap(), "5");
        assert_eq!(read("null").unwrap(), "null");
        assert_eq!(read(r#"["a",{"b":[]}]"#).unwrap(), r#"["a",{"b":[]}]"#);
        assert!(matches!(parse_foreign("18446744073709551615"), Ok(V::Dbl(value)) if value == 18446744073709551615.0));
        assert!(matches!(parse_foreign("0.12345678901234567890123456789"), Ok(V::Dbl(value)) if value == 0.123_456_789_012_345_68));
        let deep = |levels: usize| "[".repeat(levels) + &"]".repeat(levels);
        assert!(parse_foreign(&deep(MAX_FOREIGN_DEPTH)).is_ok());
        for text in ["", "{", r#"{"a":1,"A":2}"#, r#"{"a":1} {"b":2}"#, r#"{"a":1e400}"#, r#"{"a":"\ud800"}"#, &deep(MAX_FOREIGN_DEPTH + 2)] {
            assert!(parse_foreign(text).is_err_and(|stop| !stop.thrown()), "{text}");
        }
        // A state file is still held to what HotPl8 writes.
        assert!(parse(r#"{"a":18446744073709551615}"#, "test").is_err());
        assert_eq!(text("a\"b\\c\u{e9}"), r#""a\"b\\c\u00e9""#);
    }

    #[test]
    fn json_text_round_trips() {
        set_core(true);
        let value = parse(r#"{"a":[1,2.5,"x\"y",{"b":null}],"c":{},"d":[]}"#, "test").ok().unwrap();
        let text = write(&value, 24).ok().unwrap();
        assert!(same(&parse(&text, "test").ok().unwrap(), &value));
        assert!(write(&value, 1).is_err());
        assert_eq!(compact(&value, 24).ok().unwrap(), r#"{"a":[1,2.5,"x\"y",{"b":null}],"c":{},"d":[]}"#);
        assert!(compact(&value, 1).is_err());
    }

    #[test]
    fn a_question_is_one_object_two_levels_deeper_than_a_file_and_no_larger_than_any_asked() {
        set_core(false);
        let said = |written: &[u8]| parse_asked(written).err().map(|stop| stop.message());
        assert_eq!(said(br#"{"policy":{"mode":"monitor"},"now":null}"#), None);
        // Windows PowerShell opens the pipe it writes into with the mark.
        let marked = parse_asked(b"\xef\xbb\xbf{\"a\":1}").ok().unwrap();
        assert!(marked.g("a").ok().unwrap().eq_i(1).ok().unwrap());
        for written in ["", " ", "{", "[]", "7", "null", "{} x", "\u{feff}\u{feff}{}"] {
            assert_eq!(said(written.as_bytes()).as_deref(), Some("The question is not JSON as HotPl8 writes it."), "{written:?}");
        }
        assert_eq!(said(b"{\"a\":\"\xff\"}").as_deref(), Some("The question is not UTF-8 text."));
        // An argument is a document or a list of them: that much deeper than a file.
        let nested = |levels: usize| format!("{}1{}", r#"{"a":"#.repeat(levels), "}".repeat(levels));
        let deepest = |read: &dyn Fn(&str) -> bool| (1..64).take_while(|levels| read(&nested(*levels))).last().unwrap();
        let file = deepest(&|text| parse(text, "test").is_ok());
        assert!(file >= MAX_DEPTH);
        assert_eq!(deepest(&|text| parse_asked(text.as_bytes()).is_ok()), file + ASKED_DEPTH);
        assert_eq!(said(nested(file + ASKED_DEPTH + 1).as_bytes()).as_deref(), Some("The question is not JSON as HotPl8 writes it."));
        // The size is looked at before anything is read.
        let mut large = vec![b'x'; MAX_ASKED_BYTES];
        assert_eq!(said(&large).as_deref(), Some("The question is not JSON as HotPl8 writes it."));
        large.push(b'x');
        assert_eq!(said(&large).as_deref(), Some("The question is larger than any HotPl8 asks."));
    }
}

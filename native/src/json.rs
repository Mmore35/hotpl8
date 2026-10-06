//! State files as ConvertFrom-Json reads them on each PowerShell edition, and the two ways
//! a value leaves the reader: JSON text, and the typed dump the parity suite compares.
//!
//! The parser accepts strict JSON only. Wherever the two editions' parsers disagree with
//! each other or with strict JSON (comments, trailing commas, date text, huge numbers,
//! repeated names), it declines.

use crate::num::Dec;
use crate::ps::{decline, desktop, printable, Props, R, V};
use std::cell::RefCell;
use std::rc::Rc;

const MAX_BYTES: usize = 1_000_000;
const MAX_DEPTH: usize = 20;
const FORBIDDEN_NAMES: [&str; 6] = ["psobject", "psbase", "psadapted", "psextended", "pstypenames", "__type"];

/// The file's value, or `None` when the file does not exist.
#[track_caller]
pub fn read_file(path: &std::path::Path) -> R<Option<V>> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(parse_bytes(&bytes)?)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // A missing directory in the middle of the path reads as "not found" too.
            Ok(None)
        }
        Err(_) => decline(),
    }
}

#[track_caller]
pub fn parse_bytes(bytes: &[u8]) -> R<V> {
    if bytes.len() > MAX_BYTES {
        return decline();
    }
    // A UTF-16 or UTF-32 byte order mark switches the .NET reader to that encoding.
    if bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]) || bytes.starts_with(&[0, 0, 0xfe, 0xff]) {
        return decline();
    }
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    let Ok(text) = std::str::from_utf8(bytes) else { return decline() };
    parse(text)
}

/// A JSON document whose top level is an object.
#[track_caller]
pub fn parse(text: &str) -> R<V> {
    let mut parser = Parser { bytes: text.as_bytes(), at: 0 };
    parser.blank();
    if parser.peek() != Some(b'{') {
        return decline();
    }
    let value = parser.value(0)?;
    parser.blank();
    if parser.at != parser.bytes.len() {
        return decline();
    }
    Ok(value)
}

struct Parser<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Parser<'_> {
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
            decline()
        }
    }

    fn value(&mut self, depth: usize) -> R<V> {
        if depth > MAX_DEPTH {
            return decline();
        }
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(V::Str(self.string()?.into())),
            Some(b't') => self.expect("true").map(|_| V::Bool(true)),
            Some(b'f') => self.expect("false").map(|_| V::Bool(false)),
            Some(b'n') => self.expect("null").map(|_| V::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => decline(),
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
                    return decline();
                }
                let name = self.string()?;
                let lower = name.to_ascii_lowercase();
                if name.is_empty() || !printable(&name) || FORBIDDEN_NAMES.contains(&lower.as_str()) {
                    return decline();
                }
                if items.iter().any(|(known, _)| known.eq_ignore_ascii_case(&name)) {
                    return decline();
                }
                self.blank();
                self.expect(":")?;
                self.blank();
                let value = self.value(depth + 1)?;
                items.push((name.into(), value));
                self.blank();
                match self.peek() {
                    Some(b',') => self.at += 1,
                    Some(b'}') => {
                        self.at += 1;
                        break;
                    }
                    _ => return decline(),
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
                    _ => return decline(),
                }
            }
        }
        Ok(V::Arr(Rc::new(items)))
    }

    fn hex4(&mut self) -> R<u32> {
        let Some(digits) = self.bytes.get(self.at..self.at + 4) else { return decline() };
        let Ok(text) = std::str::from_utf8(digits) else { return decline() };
        if !text.bytes().all(|b| b.is_ascii_hexdigit()) {
            return decline();
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
                                    return decline();
                                }
                                0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00)
                            } else {
                                unit
                            };
                            let Some(c) = char::from_u32(code) else { return decline() };
                            out.push(c);
                        }
                        _ => return decline(),
                    }
                }
                _ => return decline(),
            }
        }
        // Windows PowerShell turns "\/Date(...)\/" text into a date.
        if out.contains("/Date(") {
            return decline();
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
            return decline();
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
                return decline();
            }
        }
        // Exponents become doubles on one edition and are spelled differently by both.
        if matches!(self.peek(), Some(b'e' | b'E' | b'.' | b'+' | b'-')) || whole.len() + fraction.len() > 28 {
            return decline();
        }
        let token = std::str::from_utf8(&self.bytes[start..self.at]).unwrap();
        let all_zero = whole.iter().chain(fraction).all(|b| *b == b'0');
        if negative && all_zero {
            return decline();
        }
        if fraction.is_empty() {
            let Ok(value) = token.parse::<i64>() else { return decline() };
            return Ok(match i32::try_from(value) {
                Ok(small) if desktop() => V::I32(small),
                _ => V::I64(value),
            });
        }
        if desktop() {
            let digits: String = whole.iter().chain(fraction).map(|b| *b as char).collect();
            let Ok(mant) = digits.parse::<u128>() else { return decline() };
            return Ok(V::Dec(Dec { neg: negative, mant, scale: fraction.len() as u8 }));
        }
        let Ok(value) = token.parse::<f64>() else { return decline() };
        crate::ps::dbl(value)
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
        V::Hash(_) => return decline(),
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
        return decline();
    }
    let pad = "  ".repeat(depth + 1);
    match value {
        V::Null => out.push_str("null"),
        V::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        V::I32(x) => out.push_str(&x.to_string()),
        V::I64(x) => out.push_str(&x.to_string()),
        V::Dec(x) => out.push_str(&x.text()),
        V::Dbl(x) if x.is_finite() => out.push_str(&format!("{x:?}")),
        V::Dbl(_) | V::Hash(_) => return decline(),
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

/// Whether two parsed values hold the same data with the same types.
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
        assert_eq!(dump(&parse(text).ok().unwrap()).ok().unwrap(), "{\n a: i:5\n b: l:3000000000\n c: m:45.0\n d: m:-0.5\n e: s:x\\u00e9\\\\\n f: [\n  b:true\n  n\n ]\n g: {\n }\n}\n");
        set_core(true);
        assert_eq!(
            dump(&parse(text).ok().unwrap()).ok().unwrap(),
            "{\n a: l:5\n b: l:3000000000\n c: d:4046800000000000\n d: d:bfe0000000000000\n e: s:x\\u00e9\\\\\n f: [\n  b:true\n  n\n ]\n g: {\n }\n}\n"
        );
    }

    #[test]
    fn anything_the_editions_read_differently_is_declined() {
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
            r#"{"a":1e3}"#,
            r#"{"a":-0}"#,
            r#"{"a":-0.0}"#,
            r#"{"a":9223372036854775808}"#,
            r#"{"a":0.12345678901234567890123456789}"#,
            r#"{"a":01}"#,
            r#"{"a":'x'}"#,
            r#"{"a":1 /* c */}"#,
            "{\"a\":\"line\nbreak\"}",
        ] {
            assert!(parse(text).is_err(), "{text}");
        }
        assert!(parse_bytes(&[0xff, 0xfe, b'{', 0, b'}', 0]).is_err());
        assert!(parse_bytes(b"\xef\xbb\xbf{}").is_ok());
        assert!(parse_bytes(b"{\"a\":\"\xff\"}").is_err());
    }

    #[test]
    fn json_text_round_trips() {
        set_core(true);
        let value = parse(r#"{"a":[1,2.5,"x\"y",{"b":null}],"c":{},"d":[]}"#).ok().unwrap();
        let text = write(&value, 24).ok().unwrap();
        assert!(same(&parse(&text).ok().unwrap(), &value));
        assert!(write(&value, 1).is_err());
    }
}

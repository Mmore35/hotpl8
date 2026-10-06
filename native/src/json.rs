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
    let mut parser = Parser { bytes: text.as_bytes(), at: 0 };
    parser.document().map_err(|stop| {
        stop.described(|| {
            let before = &text[..parser.at.min(text.len())];
            let line = before.matches('\n').count() + 1;
            let column = before.rsplit('\n').next().unwrap_or("").chars().count() + 1;
            format!("{name} is not JSON as HotPl8 writes it (line {line}, column {column}).")
        })
    })
}

/// A line holding one JSON array of strings: how the parity suite spells a request.
pub fn strings(line: &str) -> Option<Vec<String>> {
    let mut parser = Parser { bytes: line.as_bytes(), at: 0 };
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
        if depth > MAX_DEPTH {
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
                if name.is_empty() || !printable(&name) || FORBIDDEN_NAMES.contains(&lower.as_str()) {
                    return unreadable();
                }
                if items.iter().any(|(known, _)| known.eq_ignore_ascii_case(&name)) {
                    return unreadable();
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
        if out.contains("/Date(") {
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
        if matches!(self.peek(), Some(b'e' | b'E' | b'.' | b'+' | b'-')) || whole.len() + fraction.len() > 28 {
            return unreadable();
        }
        let token = std::str::from_utf8(&self.bytes[start..self.at]).unwrap();
        let all_zero = whole.iter().chain(fraction).all(|b| *b == b'0');
        if negative && all_zero {
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
    let mut parser = Parser { bytes: text.as_bytes(), at: 0 };
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
    fn json_text_round_trips() {
        set_core(true);
        let value = parse(r#"{"a":[1,2.5,"x\"y",{"b":null}],"c":{},"d":[]}"#, "test").ok().unwrap();
        let text = write(&value, 24).ok().unwrap();
        assert!(same(&parse(&text, "test").ok().unwrap(), &value));
        assert!(write(&value, 1).is_err());
    }
}

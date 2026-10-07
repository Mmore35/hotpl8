//! PowerShell's dynamic values and operators, as far as `status` and `explain` use them.
//!
//! The ported modules follow the PowerShell source line by line on top of these helpers.
//! Each helper models exactly the type combinations real state files produce and stops as
//! `unreadable` on the rest: the user is told the state cannot be shown, never shown a
//! slightly different answer.

use crate::num::{self, Dec};
use std::cell::{Cell, RefCell};
use std::cmp::Ordering;
use std::panic::Location;
use std::rc::Rc;

/// Why the reader stopped computing an answer. Boxed, so the happy path carries one word.
#[derive(Debug)]
pub struct Stop(Box<Detail>);
#[derive(Debug)]
struct Detail {
    /// A rule refused the input, as against input the reader does not read at all. A ported
    /// try/catch catches the first and never the second.
    thrown: bool,
    at: &'static Location<'static>,
    /// What the user is told. Without one, the place in the reader stands in for it.
    message: Option<String>,
    /// The state file an operating-system refusal was about, and the system's code for it.
    file: Option<(String, i32)>,
    /// Whether the system refused for want of permission rather than for any other reason.
    denied: bool,
    /// A failure PowerShell reported from a part of the collection it still runs: the kind
    /// it gave it, and the file and line it was raised at where it named them.
    reported: Option<(&'static str, Option<(String, u32)>)>,
}
pub type R<T> = Result<T, Stop>;

impl Stop {
    #[track_caller]
    fn new<T>(thrown: bool, message: Option<String>) -> R<T> {
        Err(Stop(Box::new(Detail { thrown, at: Location::caller(), message, file: None, denied: false, reported: None })))
    }
    /// The operating system refused to read, write or lock a file. A ported try/catch
    /// catches it, as it caught the .NET exception.
    #[track_caller]
    pub fn io<T>(error: &std::io::Error, path: &std::path::Path) -> R<T> {
        let name = path.file_name().unwrap_or(path.as_os_str()).to_string_lossy().into_owned();
        Err(Stop(Box::new(Detail {
            thrown: true,
            at: Location::caller(),
            message: Some(format!("{name}: {error}")),
            file: Some((name, error.raw_os_error().unwrap_or(0) & 0xffff)),
            denied: error.kind() == std::io::ErrorKind::PermissionDenied,
            reported: None,
        })))
    }
    /// A failure PowerShell caught and reported. Its kind is one of Get-Hotpl8FailureCode's
    /// and its words are kept only for the caller to compare with the few it knows.
    #[track_caller]
    pub fn reported<T>(code: &str, said: Option<String>, file: Option<(String, i32)>, source: Option<(String, u32)>) -> R<T> {
        const KINDS: [&str; 5] = ["access_denied", "state_io_failed", "invalid_cached_shape", "invalid_parameter", "unexpected_collection_error"];
        let kind = KINDS.iter().find(|kind| **kind == code).copied().unwrap_or("unexpected_collection_error");
        Err(Stop(Box::new(Detail { thrown: true, at: Location::caller(), message: said, file, denied: false, reported: Some((kind, source)) })))
    }
    /// Get-Hotpl8FailureCode: what kind of failure this is, in the words events carry.
    pub fn failure_code(&self) -> &'static str {
        if let Some((kind, _)) = &self.0.reported {
            return kind;
        }
        match (&self.0.file, self.0.denied) {
            (_, true) => "access_denied",
            (Some(_), false) => "state_io_failed",
            (None, false) => "unexpected_collection_error",
        }
    }
    /// The file and system code of an operating-system refusal.
    pub fn state_file(&self) -> Option<(&str, i32)> {
        self.0.file.as_ref().map(|(name, code)| (name.as_str(), *code))
    }
    /// Where the stop was raised, file name and line: in this program, or where PowerShell
    /// said, when it said so of a file an event may name.
    pub fn place(&self) -> Option<(&str, u32)> {
        if let Some((_, source)) = &self.0.reported {
            return source.as_ref().map(|(source, line)| (source.as_str(), *line));
        }
        let file = self.0.at.file();
        Some((file.rsplit(['/', '\\']).next().unwrap_or(file), self.0.at.line()))
    }
    /// The words a rule refused with, where it gave any: `throw 'claude_missing'`.
    pub fn said(&self) -> Option<&str> {
        if self.0.thrown { self.0.message.as_deref() } else { None }
    }
    pub fn thrown(&self) -> bool {
        self.0.thrown
    }
    /// A rule refused the input in HotPl8's own words: the refusal is part of the product,
    /// and the parity suite holds its wording to PowerShell's.
    pub fn ruled(&self) -> bool {
        self.0.thrown && self.0.message.is_some()
    }
    /// The whole of what HotPl8 prints for this stop, after its own name.
    pub fn message(&self) -> String {
        match &self.0.message {
            Some(message) => message.clone(),
            None => {
                let place = format!("{}:{}", self.0.at.file().replace('\\', "/"), self.0.at.line());
                format!("This state cannot be shown: one of its values is not one HotPl8 writes ({place}). Run hotpl8 refresh; if that changes nothing, run hotpl8 doctor.")
            }
        }
    }
    /// The same stop, said in the caller's words where it had none of its own.
    pub fn described(mut self, message: impl FnOnce() -> String) -> Stop {
        if self.0.message.is_none() {
            self.0.message = Some(message());
        }
        self
    }
}

/// Input the reader does not read: a shape HotPl8 never writes.
#[track_caller]
pub fn unreadable<T>() -> R<T> {
    Stop::new(false, None)
}
/// Input the reader does not read, said in words the user can act on.
#[track_caller]
pub fn unreadable_as<T>(message: impl Into<String>) -> R<T> {
    Stop::new(false, Some(message.into()))
}
/// A rule refuses the input, with the words HotPl8 has always used for it.
#[track_caller]
pub fn fail<T>(message: impl Into<String>) -> R<T> {
    Stop::new(true, Some(message.into()))
}
/// An operation fails on the input where the rules never expected it to.
#[track_caller]
pub fn throw<T>() -> R<T> {
    Stop::new(true, None)
}
/// try { body } catch { }: `None` when a rule refused the input.
pub fn catch<T>(body: impl FnOnce() -> R<T>) -> R<Option<T>> {
    match body() {
        Ok(value) => Ok(Some(value)),
        Err(stop) if stop.thrown() => Ok(None),
        Err(stop) => Err(stop),
    }
}

thread_local! {
    static CORE: Cell<bool> = const { Cell::new(false) };
}
/// Which PowerShell the caller is: Windows PowerShell 5.1 ("desktop") or PowerShell 7.
pub fn set_core(core: bool) {
    CORE.with(|cell| cell.set(core));
}
pub fn desktop() -> bool {
    !CORE.with(|cell| cell.get())
}

pub struct Props {
    pub items: Vec<(Rc<str>, V)>,
}
pub type O = Rc<RefCell<Props>>;

#[derive(Clone)]
pub enum V {
    Null,
    Bool(bool),
    I32(i32),
    I64(i64),
    Dec(Dec),
    Dbl(f64),
    Str(Rc<str>),
    Arr(Rc<Vec<V>>),
    /// [pscustomobject]: ordered, shared by reference.
    Obj(O),
    /// @{}: a hash table, shared by reference.
    Hash(O),
}

impl From<bool> for V {
    fn from(value: bool) -> V {
        V::Bool(value)
    }
}
impl From<i32> for V {
    fn from(value: i32) -> V {
        V::I32(value)
    }
}
impl From<i64> for V {
    fn from(value: i64) -> V {
        V::I64(value)
    }
}
impl From<&str> for V {
    fn from(value: &str) -> V {
        V::Str(value.into())
    }
}
impl From<String> for V {
    fn from(value: String) -> V {
        V::Str(value.into())
    }
}
impl From<Vec<V>> for V {
    fn from(value: Vec<V>) -> V {
        V::Arr(Rc::new(value))
    }
}
impl From<&V> for V {
    fn from(value: &V) -> V {
        value.clone()
    }
}
impl From<Option<V>> for V {
    fn from(value: Option<V>) -> V {
        value.unwrap_or(V::Null)
    }
}

/// [pscustomobject]@{...}
#[macro_export]
macro_rules! obj {
    ($($key:expr => $value:expr),* $(,)?) => {
        $crate::ps::new_obj(vec![$(($key, $crate::ps::V::from($value))),*])
    };
}
/// @{...}
#[macro_export]
macro_rules! hash {
    ($($key:expr => $value:expr),* $(,)?) => {
        $crate::ps::new_hash(vec![$(($key, $crate::ps::V::from($value))),*])
    };
}
/// 'text' + $a + $b, where the first operand is known to be a string.
#[macro_export]
macro_rules! cat {
    ($($part:expr),+ $(,)?) => {{
        let mut out = String::new();
        $($crate::ps::Text::put(&$part, &mut out)?;)+
        out
    }};
}

pub fn new_obj(items: Vec<(&str, V)>) -> V {
    V::Obj(Rc::new(RefCell::new(Props { items: items.into_iter().map(|(k, v)| (k.into(), v)).collect() })))
}
pub fn new_hash(items: Vec<(&str, V)>) -> V {
    V::Hash(Rc::new(RefCell::new(Props { items: items.into_iter().map(|(k, v)| (k.into(), v)).collect() })))
}
/// A constructed double. PowerShell would carry NaN or infinity on; the reader does not.
#[track_caller]
pub fn dbl(value: f64) -> R<V> {
    if value.is_finite() {
        Ok(V::Dbl(value))
    } else {
        unreadable()
    }
}

pub trait Text {
    fn put(&self, out: &mut String) -> R<()>;
}
impl Text for str {
    fn put(&self, out: &mut String) -> R<()> {
        out.push_str(self);
        Ok(())
    }
}
impl Text for String {
    fn put(&self, out: &mut String) -> R<()> {
        out.push_str(self);
        Ok(())
    }
}
impl Text for V {
    fn put(&self, out: &mut String) -> R<()> {
        out.push_str(&self.s()?);
        Ok(())
    }
}
impl<T: Text + ?Sized> Text for &T {
    fn put(&self, out: &mut String) -> R<()> {
        (**self).put(out)
    }
}

/// A number with its .NET type.
#[derive(Clone, Copy)]
pub enum N {
    I32(i32),
    I64(i64),
    Dec(Dec),
    Dbl(f64),
}
impl N {
    fn negative(self) -> bool {
        match self {
            N::I32(x) => x < 0,
            N::I64(x) => x < 0,
            N::Dec(x) => x.neg && !x.is_zero(),
            N::Dbl(x) => x < 0.0,
        }
    }
    fn f(self) -> f64 {
        match self {
            N::I32(x) => x as f64,
            N::I64(x) => x as f64,
            N::Dec(x) => x.to_f64(),
            N::Dbl(x) => x,
        }
    }
    #[track_caller]
    fn dec(self) -> R<Dec> {
        match self {
            N::I32(x) => Ok(Dec::from_i64(x as i64)),
            N::I64(x) => Ok(Dec::from_i64(x)),
            N::Dec(x) => Ok(x),
            // PowerShell 7 converts a double to a decimal by other rules than these.
            N::Dbl(_) if !desktop() => unreadable(),
            N::Dbl(x) => Dec::from_f64(x),
        }
    }
}

pub fn printable(text: &str) -> bool {
    text.bytes().all(|b| (0x20..=0x7e).contains(&b))
}
fn alphanumeric(text: &str) -> bool {
    text.bytes().all(|b| b.is_ascii_alphanumeric())
}
#[track_caller]
fn same_text(left: &str, right: &str, case_sensitive: bool) -> R<bool> {
    if left == right {
        return Ok(true);
    }
    if printable(left) && printable(right) {
        return Ok(!case_sensitive && left.eq_ignore_ascii_case(right));
    }
    unreadable()
}
/// Culture ordering, modelled for strings of ASCII letters and digits, for hyphens between
/// them where every culture table agrees, and for strings of one shape such as timestamps.
#[track_caller]
pub fn order_text(left: &str, right: &str) -> R<Ordering> {
    let (left, right) = (left.to_ascii_lowercase(), right.to_ascii_lowercase());
    if alphanumeric(&left) && alphanumeric(&right) {
        return Ok(left.cmp(&right));
    }
    // Two strings that differ only in which digit stands at a place are decided by the
    // first such place: whatever stands between the digits weighs the same in both.
    let shaped = |a: u8, b: u8| a == b || (a.is_ascii_digit() && b.is_ascii_digit());
    if left.len() == right.len() && printable(&left) && printable(&right) && left.bytes().zip(right.bytes()).all(|(a, b)| shaped(a, b)) {
        return Ok(left.cmp(&right));
    }
    let hyphenated = |text: &str| text.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    if !hyphenated(&left) || !hyphenated(&right) {
        return unreadable();
    }
    // Windows gives a hyphen no weight and ICU a weight below every letter and digit. Both
    // decide by the first place the strings differ when neither has a hyphen there, and
    // put a string before a longer one that starts with it.
    match left.bytes().zip(right.bytes()).find(|(a, b)| a != b) {
        Some((a, b)) if a != b'-' && b != b'-' => Ok(a.cmp(&b)),
        Some(_) => unreadable(),
        None if left.len() == right.len() => Ok(Ordering::Equal),
        None if left.trim_end_matches('-') == right.trim_end_matches('-') => unreadable(),
        None => Ok(left.len().cmp(&right.len())),
    }
}

/// A string read as a number of its own form: `None` when it is plainly not a number.
#[track_caller]
fn parse_number(text: &str) -> R<Option<N>> {
    if text.is_empty() {
        return Ok(Some(N::I32(0)));
    }
    let trimmed = text.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\r' || c == '\n');
    if trimmed.is_empty() {
        return unreadable();
    }
    let body = trimmed.strip_prefix(['+', '-']).unwrap_or(trimmed);
    let (whole, fraction) = match body.split_once('.') {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (body, None),
    };
    let digits = |part: &str| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit());
    if digits(whole) && fraction.is_none_or(digits) {
        let significant = whole.trim_start_matches('0').len() + fraction.map_or(0, str::len);
        if significant > 15 {
            return unreadable();
        }
        return Ok(Some(match fraction {
            None => {
                let value: i64 = trimmed.strip_prefix('+').unwrap_or(trimmed).parse().or_else(|_| unreadable())?;
                i32::try_from(value).map_or(N::I64(value), N::I32)
            }
            Some(_) => N::Dbl(trimmed.strip_prefix('+').unwrap_or(trimmed).parse().or_else(|_| unreadable())?),
        }));
    }
    let lower = text.to_ascii_lowercase();
    if text.is_ascii() && !text.bytes().any(|b| b.is_ascii_digit()) && !lower.contains("nan") && !lower.contains("infinity") {
        return Ok(None);
    }
    unreadable()
}

#[track_caller]
fn compare_numbers(left: N, right: N) -> R<Ordering> {
    match (left, right) {
        (N::Dec(_), _) | (_, N::Dec(_)) => {
            // An overflowing double would make PowerShell fall back to a double comparison.
            let convert = |n: N| match n.dec() {
                Err(stop) if stop.thrown() => unreadable(),
                other => other,
            };
            convert(left)?.compare(convert(right)?)
        }
        (N::Dbl(_), _) | (_, N::Dbl(_)) => left.f().partial_cmp(&right.f()).map_or_else(unreadable, Ok),
        _ => {
            let whole = |n: N| match n {
                N::I32(x) => x as i64,
                N::I64(x) => x,
                _ => 0,
            };
            Ok(whole(left).cmp(&whole(right)))
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Op {
    Add,
    Sub,
    Mul,
    Div,
}

#[track_caller]
fn arithmetic(op: Op, left: N, right: N) -> R<V> {
    match (left, right) {
        (N::Dec(_), _) | (_, N::Dec(_)) => {
            let (left, right) = (left.dec()?, right.dec()?);
            Ok(V::Dec(match op {
                Op::Add => left.add(right)?,
                Op::Sub => left.sub(right)?,
                Op::Mul => left.mul(right)?,
                Op::Div => left.div(right)?,
            }))
        }
        (N::Dbl(_), _) | (_, N::Dbl(_)) => {
            let (left, right) = (left.f(), right.f());
            dbl(match op {
                Op::Add => left + right,
                Op::Sub => left - right,
                Op::Mul => left * right,
                Op::Div => left / right,
            })
        }
        _ => {
            let both32 = matches!((left, right), (N::I32(_), N::I32(_)));
            let whole = |n: N| match n {
                N::I32(x) => x as i64,
                N::I64(x) => x,
                _ => 0,
            };
            let (a, b) = (whole(left), whole(right));
            let typed = |value: i64| if both32 { V::I32(value as i32) } else { V::I64(value) };
            let fits = |value: i64| !both32 || i32::try_from(value).is_ok();
            if op == Op::Div {
                if b == 0 {
                    return throw();
                }
                let least = if both32 { i32::MIN as i64 } else { i64::MIN };
                if (a == least && b == -1) || a % b != 0 {
                    return dbl(a as f64 / b as f64);
                }
                return Ok(typed(a / b));
            }
            let exact = match op {
                Op::Add => a.checked_add(b),
                Op::Sub => a.checked_sub(b),
                _ => a.checked_mul(b),
            };
            match exact {
                Some(value) if fits(value) => Ok(typed(value)),
                _ => dbl(match op {
                    Op::Add => a as f64 + b as f64,
                    Op::Sub => a as f64 - b as f64,
                    _ => a as f64 * b as f64,
                }),
            }
        }
    }
}

const RESERVED: [&str; 11] =
    ["count", "length", "psobject", "psbase", "psadapted", "psextended", "pstypenames", "tostring", "equals", "gethashcode", "gettype"];
const HASH_RESERVED: [&str; 18] = [
    "keys", "values", "isreadonly", "isfixedsize", "issynchronized", "syncroot", "add", "clear", "clone", "contains",
    "containskey", "containsvalue", "copyto", "getenumerator", "getobjectdata", "ondeserialization", "remove", "item",
];

impl Props {
    pub fn find(&self, name: &str) -> Option<usize> {
        self.items.iter().position(|(key, _)| key.eq_ignore_ascii_case(name))
    }
}

impl V {
    pub fn s_of(text: &str) -> V {
        V::Str(text.into())
    }
    pub fn is_null(&self) -> bool {
        matches!(self, V::Null)
    }
    pub fn n(&self) -> Option<N> {
        match self {
            V::I32(x) => Some(N::I32(*x)),
            V::I64(x) => Some(N::I64(*x)),
            V::Dec(x) => Some(N::Dec(*x)),
            V::Dbl(x) => Some(N::Dbl(*x)),
            _ => None,
        }
    }
    /// $value -is [string]
    pub fn is_str(&self) -> bool {
        matches!(self, V::Str(_))
    }
    pub fn as_str(&self) -> Option<&str> {
        match self {
            V::Str(text) => Some(text),
            _ => None,
        }
    }

    /// `$value.name` with the name written in the source.
    #[track_caller]
    pub fn g(&self, name: &str) -> R<V> {
        match self {
            V::Null => Ok(V::Null),
            V::Obj(o) => {
                let props = o.borrow();
                match props.find(name) {
                    Some(index) => Ok(props.items[index].1.clone()),
                    None if RESERVED.contains(&name.to_ascii_lowercase().as_str()) => unreadable(),
                    None => Ok(V::Null),
                }
            }
            V::Hash(o) => {
                let lower = name.to_ascii_lowercase();
                if RESERVED.contains(&lower.as_str()) || HASH_RESERVED.contains(&lower.as_str()) || !printable(name) {
                    return unreadable();
                }
                let props = o.borrow();
                if let Some((_, value)) = props.items.iter().find(|(key, _)| &**key == name) {
                    return Ok(value.clone());
                }
                // A key that matches only when case is ignored depends on the culture.
                if props.find(name).is_some() {
                    return unreadable();
                }
                Ok(V::Null)
            }
            V::Arr(_) => unreadable(),
            _ if RESERVED.contains(&name.to_ascii_lowercase().as_str()) => unreadable(),
            _ => Ok(V::Null),
        }
    }
    /// `$value.$name` with a name taken from data: a name PowerShell answers itself is not read.
    #[track_caller]
    pub fn gd(&self, name: &str) -> R<V> {
        // No object read from JSON has a member without a name, and PowerShell answers null.
        if name.is_empty() && !matches!(self, V::Hash(_)) {
            return Ok(V::Null);
        }
        let lower = name.to_ascii_lowercase();
        if RESERVED.contains(&lower.as_str()) || !printable(name) {
            return unreadable();
        }
        if matches!(self, V::Hash(_)) && HASH_RESERVED.contains(&lower.as_str()) {
            return unreadable();
        }
        self.g(name)
    }
    /// A nested member path.
    #[track_caller]
    pub fn path(&self, names: &[&str]) -> R<V> {
        let mut value = self.clone();
        for name in names {
            value = value.g(name)?;
        }
        Ok(value)
    }

    /// `$object.name = value`
    #[track_caller]
    pub fn set(&self, name: &str, value: V) -> R<()> {
        match self {
            V::Obj(o) => {
                let mut props = o.borrow_mut();
                match props.find(name) {
                    Some(index) => {
                        props.items[index].1 = value;
                        Ok(())
                    }
                    None => throw(),
                }
            }
            V::Hash(o) => {
                if !printable(name) {
                    return unreadable();
                }
                let mut props = o.borrow_mut();
                if let Some(index) = props.items.iter().position(|(key, _)| &**key == name) {
                    props.items[index].1 = value;
                } else if props.find(name).is_some() {
                    return unreadable();
                } else {
                    props.items.push((name.into(), value));
                }
                Ok(())
            }
            _ => unreadable(),
        }
    }
    /// `$object | Add-Member -NotePropertyName name -NotePropertyValue value [-Force]`
    #[track_caller]
    pub fn add_member(&self, name: &str, value: V, force: bool) -> R<()> {
        let V::Obj(o) = self else { return unreadable() };
        let mut props = o.borrow_mut();
        if let Some(index) = props.find(name) {
            if !force {
                return throw();
            }
            props.items.remove(index);
        }
        props.items.push((name.into(), value));
        Ok(())
    }
    /// `$object.PSObject.Properties.Remove(name)`: nothing happens when the member is absent.
    #[track_caller]
    pub fn remove_member(&self, name: &str) -> R<()> {
        let V::Obj(o) = self else { return unreadable() };
        let mut props = o.borrow_mut();
        if let Some(index) = props.find(name) {
            props.items.remove(index);
        }
        Ok(())
    }

    /// [bool]$value
    #[track_caller]
    pub fn t(&self) -> R<bool> {
        Ok(match self {
            V::Null => false,
            V::Bool(b) => *b,
            V::I32(x) => *x != 0,
            V::I64(x) => *x != 0,
            V::Dec(x) => !x.is_zero(),
            V::Dbl(x) => *x != 0.0,
            V::Str(text) => !text.is_empty(),
            V::Arr(items) => match items.len() {
                0 => false,
                1 => match &items[0] {
                    V::Arr(inner) if inner.is_empty() => return unreadable(),
                    V::Arr(_) => true,
                    single => single.t()?,
                },
                _ => true,
            },
            V::Obj(_) | V::Hash(_) => true,
        })
    }

    /// [string]$value
    #[track_caller]
    pub fn s(&self) -> R<String> {
        Ok(match self {
            V::Null => String::new(),
            V::Bool(true) => "True".into(),
            V::Bool(false) => "False".into(),
            V::I32(x) => x.to_string(),
            V::I64(x) => x.to_string(),
            V::Dec(x) if desktop() || x.scale == 0 => x.text(),
            V::Dec(_) => return unreadable(),
            V::Dbl(x) => num::double_text(*x),
            V::Str(text) => text.to_string(),
            V::Arr(_) | V::Obj(_) | V::Hash(_) => return unreadable(),
        })
    }
    /// [string]$value, as a value.
    #[track_caller]
    pub fn sv(&self) -> R<V> {
        Ok(V::Str(self.s()?.into()))
    }

    #[track_caller]
    fn equal(&self, other: &V, case_sensitive: bool) -> R<bool> {
        match (self, other) {
            (V::Null, _) => Ok(other.is_null()),
            (V::Arr(_), _) => unreadable(),
            (V::Obj(a), V::Obj(b)) | (V::Hash(a), V::Hash(b)) => Ok(Rc::ptr_eq(a, b)),
            (V::Obj(_) | V::Hash(_), V::Null) => Ok(false),
            (V::Obj(_) | V::Hash(_), _) => unreadable(),
            (_, V::Null) => Ok(false),
            (_, V::Arr(_) | V::Obj(_) | V::Hash(_)) => unreadable(),
            (V::Bool(a), _) => Ok(*a == other.t()?),
            (V::Str(a), _) => same_text(a, &other.s()?, case_sensitive),
            (_, V::Bool(b)) => Ok(compare_numbers(self.n().unwrap(), N::I32(*b as i32))? == Ordering::Equal),
            (_, V::Str(b)) => match parse_number(b)? {
                Some(number) => Ok(compare_numbers(self.n().unwrap(), number)? == Ordering::Equal),
                None => Ok(false),
            },
            _ => Ok(compare_numbers(self.n().unwrap(), other.n().unwrap())? == Ordering::Equal),
        }
    }
    #[track_caller]
    pub fn eq(&self, other: &V) -> R<bool> {
        self.equal(other, false)
    }
    #[track_caller]
    pub fn ne(&self, other: &V) -> R<bool> {
        Ok(!self.equal(other, false)?)
    }
    #[track_caller]
    pub fn ceq(&self, other: &V) -> R<bool> {
        self.equal(other, true)
    }
    #[track_caller]
    pub fn cne(&self, other: &V) -> R<bool> {
        Ok(!self.equal(other, true)?)
    }
    #[track_caller]
    pub fn eq_s(&self, text: &str) -> R<bool> {
        self.equal(&V::s_of(text), false)
    }
    #[track_caller]
    pub fn ne_s(&self, text: &str) -> R<bool> {
        Ok(!self.eq_s(text)?)
    }
    #[track_caller]
    pub fn ceq_s(&self, text: &str) -> R<bool> {
        self.equal(&V::s_of(text), true)
    }
    #[track_caller]
    pub fn eq_i(&self, value: i32) -> R<bool> {
        self.equal(&V::I32(value), false)
    }
    /// `$value -in 'a','b'`
    #[track_caller]
    pub fn in_s(&self, list: &[&str]) -> R<bool> {
        for item in list {
            if V::s_of(item).equal(self, false)? {
                return Ok(true);
            }
        }
        Ok(false)
    }
    /// `$value -in $list` and `$list -contains $value`: each list item is the left operand.
    #[track_caller]
    pub fn is_in(&self, list: &V) -> R<bool> {
        for item in list.arr() {
            if item.equal(self, false)? {
                return Ok(true);
            }
        }
        Ok(false)
    }
    #[track_caller]
    pub fn is_in_list(&self, list: &[V]) -> R<bool> {
        for item in list {
            if item.equal(self, false)? {
                return Ok(true);
            }
        }
        Ok(false)
    }
    #[track_caller]
    pub fn is_cin_list(&self, list: &[V]) -> R<bool> {
        for item in list {
            if item.equal(self, true)? {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// The ordering behind -lt, -le, -gt and -ge.
    #[track_caller]
    pub fn compare(&self, other: &V) -> R<Ordering> {
        match (self, other) {
            (V::Null, V::Null) => Ok(Ordering::Equal),
            (V::Null, V::Str(_) | V::Bool(_)) => Ok(Ordering::Less),
            (V::Null, _) => match other.n() {
                Some(number) => Ok(if number.negative() { Ordering::Greater } else { Ordering::Less }),
                None => unreadable(),
            },
            (V::Bool(_) | V::Str(_), V::Null) => Ok(Ordering::Greater),
            (V::Str(a), V::Str(_) | V::Bool(_) | V::I32(_) | V::I64(_) | V::Dec(_) | V::Dbl(_)) => order_text(a, &other.s()?),
            (V::I32(_) | V::I64(_) | V::Dec(_) | V::Dbl(_), _) => {
                let left = self.n().unwrap();
                match other {
                    V::Null => Ok(if left.negative() { Ordering::Less } else { Ordering::Greater }),
                    V::Bool(b) => compare_numbers(left, N::I32(*b as i32)),
                    V::Str(text) => match parse_number(text)? {
                        Some(number) => compare_numbers(left, number),
                        None => throw(),
                    },
                    _ => match other.n() {
                        Some(number) => compare_numbers(left, number),
                        None => unreadable(),
                    },
                }
            }
            _ => unreadable(),
        }
    }
    #[track_caller]
    pub fn lt(&self, other: &V) -> R<bool> {
        Ok(self.compare(other)? == Ordering::Less)
    }
    #[track_caller]
    pub fn le(&self, other: &V) -> R<bool> {
        Ok(self.compare(other)? != Ordering::Greater)
    }
    #[track_caller]
    pub fn gt(&self, other: &V) -> R<bool> {
        Ok(self.compare(other)? == Ordering::Greater)
    }
    #[track_caller]
    pub fn ge(&self, other: &V) -> R<bool> {
        Ok(self.compare(other)? != Ordering::Less)
    }
    #[track_caller]
    pub fn lt_i(&self, value: i32) -> R<bool> {
        self.lt(&V::I32(value))
    }
    #[track_caller]
    pub fn le_i(&self, value: i32) -> R<bool> {
        self.le(&V::I32(value))
    }
    #[track_caller]
    pub fn gt_i(&self, value: i32) -> R<bool> {
        self.gt(&V::I32(value))
    }
    #[track_caller]
    pub fn ge_i(&self, value: i32) -> R<bool> {
        self.ge(&V::I32(value))
    }

    /// An arithmetic operand: null counts as 0, a string as the number it spells.
    #[track_caller]
    fn operand(&self) -> R<N> {
        match self {
            V::Null => Ok(N::I32(0)),
            V::Bool(b) => Ok(N::I32(*b as i32)),
            V::Str(text) => match parse_number(text)? {
                Some(number) => Ok(number),
                None => throw(),
            },
            _ => match self.n() {
                Some(number) => Ok(number),
                None => unreadable(),
            },
        }
    }
    /// `$a + $b`
    #[track_caller]
    pub fn add(&self, other: &V) -> R<V> {
        match self {
            V::Null => match other {
                V::Arr(_) | V::Obj(_) | V::Hash(_) => unreadable(),
                _ => Ok(other.clone()),
            },
            V::Str(text) => Ok(V::Str(format!("{}{}", text, other.s()?).into())),
            V::Bool(_) | V::Arr(_) | V::Obj(_) | V::Hash(_) => unreadable(),
            _ => arithmetic(Op::Add, self.operand()?, other.operand()?),
        }
    }
    /// `$a - $b`
    #[track_caller]
    pub fn sub(&self, other: &V) -> R<V> {
        arithmetic(Op::Sub, self.operand()?, other.operand()?)
    }
    /// `$a * $b`
    #[track_caller]
    pub fn mul(&self, other: &V) -> R<V> {
        match self {
            V::Null => Ok(V::Null),
            V::Str(_) | V::Bool(_) | V::Arr(_) | V::Obj(_) | V::Hash(_) => unreadable(),
            _ => arithmetic(Op::Mul, self.operand()?, other.operand()?),
        }
    }
    /// `$a / $b`
    #[track_caller]
    pub fn div(&self, other: &V) -> R<V> {
        arithmetic(Op::Div, self.operand()?, other.operand()?)
    }
    /// `-$a`
    #[track_caller]
    pub fn neg(&self) -> R<V> {
        Ok(match self.operand()? {
            N::I32(x) => x.checked_neg().map_or_else(unreadable, |x| Ok(V::I32(x)))?,
            N::I64(x) => x.checked_neg().map_or_else(unreadable, |x| Ok(V::I64(x)))?,
            N::Dec(x) => V::Dec(x.negated()?),
            N::Dbl(x) => V::Dbl(-x),
        })
    }

    /// [double]$value
    #[track_caller]
    pub fn dbl(&self) -> R<f64> {
        match self {
            V::Arr(_) | V::Obj(_) | V::Hash(_) => throw(),
            _ => Ok(self.operand()?.f()),
        }
    }
    /// [long]$value
    #[track_caller]
    pub fn to_long(&self) -> R<i64> {
        match self {
            V::Arr(_) | V::Obj(_) | V::Hash(_) => throw(),
            _ => match self.operand()? {
                N::I32(x) => Ok(x as i64),
                N::I64(x) => Ok(x),
                N::Dec(x) => x.to_i64(),
                N::Dbl(x) => num::double_to_i64(x),
            },
        }
    }
    /// [int]$value
    #[track_caller]
    pub fn to_int(&self) -> R<i32> {
        i32::try_from(self.to_long()?).or_else(|_| throw())
    }
    /// Test-Hotpl8Number
    pub fn is_number(&self) -> bool {
        self.n().is_some()
    }

    /// `@($value)`
    pub fn arr(&self) -> Vec<V> {
        match self {
            V::Arr(items) => items.to_vec(),
            other => vec![other.clone()],
        }
    }
    /// The items a bare `foreach ($x in $value)` visits: none for null.
    pub fn each(&self) -> Vec<V> {
        match self {
            V::Null => Vec::new(),
            other => other.arr(),
        }
    }
    /// `$list[0]` for a list the code built itself: null when it is empty.
    #[track_caller]
    pub fn first(&self) -> R<V> {
        match self {
            V::Arr(items) => Ok(items.first().cloned().unwrap_or(V::Null)),
            _ => unreadable(),
        }
    }
    /// `$value.PSObject.Properties`
    #[track_caller]
    pub fn props(&self) -> R<Vec<(Rc<str>, V)>> {
        match self {
            V::Null => Ok(Vec::new()),
            V::Obj(o) => Ok(o.borrow().items.clone()),
            _ => unreadable(),
        }
    }
    /// `$value | Select-Object *`: a new object with the same members.
    #[track_caller]
    pub fn shallow(&self) -> R<V> {
        match self {
            V::Obj(o) => Ok(V::Obj(Rc::new(RefCell::new(Props { items: o.borrow().items.clone() })))),
            _ => unreadable(),
        }
    }
}

/// A list assigned from an `if` statement: `$list=if(...){@(...)}else{@(...)}`. The statement
/// unrolls its one list, so a single item is held bare. Piped, a bare item is the item it
/// was; an array held bare is a list of other items, and that reading is not modelled.
#[track_caller]
pub fn held(list: Vec<V>) -> R<Vec<V>> {
    match list.as_slice() {
        [V::Arr(_)] => unreadable(),
        _ => Ok(list),
    }
}
/// `.Count` of a list held that way. A bare `$null` counts as no item and any other bare
/// value as one, except an object, which Windows PowerShell does not count at all.
#[track_caller]
pub fn held_count(list: &[V]) -> R<usize> {
    match list {
        [V::Null] => Ok(0),
        [V::Obj(_) | V::Hash(_)] => unreadable(),
        _ => Ok(list.len()),
    }
}
/// `$list | Where-Object name`: the items whose member is truthy.
#[track_caller]
pub fn where_truthy(list: &[V], name: &str) -> R<Vec<V>> {
    let mut out = Vec::new();
    for item in list {
        if item.g(name)?.t()? {
            out.push(item.clone());
        }
    }
    Ok(out)
}
/// `$list | Where-Object { ... }`
pub fn filter(list: &[V], mut keep: impl FnMut(&V) -> R<bool>) -> R<Vec<V>> {
    let mut out = Vec::new();
    for item in list {
        if keep(item)? {
            out.push(item.clone());
        }
    }
    Ok(out)
}
/// `$list | ForEach-Object name`: array members are spread into the result.
#[track_caller]
pub fn pluck(list: &[V], name: &str) -> R<Vec<V>> {
    let mut out = Vec::new();
    for item in list {
        match item.g(name)? {
            V::Arr(items) => out.extend(items.iter().cloned()),
            value => out.push(value),
        }
    }
    Ok(out)
}
/// `($list | Select-Object -Unique).Count`
#[track_caller]
pub fn unique_count(list: &[V]) -> R<usize> {
    Ok(unique(list)?.len())
}
/// `$list | Select-Object -Unique`, for lists of strings or of one whole-number type.
#[track_caller]
pub fn unique(list: &[V]) -> R<Vec<V>> {
    let mut seen: Vec<&V> = Vec::new();
    for item in list {
        let mut known = false;
        for earlier in &seen {
            match (earlier, item) {
                (V::Str(a), V::Str(b)) => {
                    if a == b {
                        known = true;
                    } else if !printable(a) || !printable(b) || a.eq_ignore_ascii_case(b) {
                        return unreadable();
                    }
                }
                (V::I32(a), V::I32(b)) => known |= a == b,
                (V::I64(a), V::I64(b)) => known |= a == b,
                _ => return unreadable(),
            }
        }
        if !matches!(item, V::Str(_) | V::I32(_) | V::I64(_)) {
            return unreadable();
        }
        if !known {
            seen.push(item);
        }
    }
    Ok(seen.into_iter().cloned().collect())
}
/// `Sort-Object`: Windows PowerShell's sort is not stable, so a tie between items the
/// caller could tell apart has no single answer there.
pub fn sort<T: Clone>(items: &[T], mut order: impl FnMut(&T, &T) -> R<Ordering>, same: impl Fn(&T, &T) -> bool) -> R<Vec<T>> {
    let mut out: Vec<T> = Vec::with_capacity(items.len());
    for item in items {
        let mut at = out.len();
        while at > 0 {
            match order(&out[at - 1], item)? {
                Ordering::Greater => at -= 1,
                Ordering::Equal => {
                    if desktop() && !same(&out[at - 1], item) {
                        return unreadable();
                    }
                    break;
                }
                Ordering::Less => break,
            }
        }
        out.insert(at, item.clone());
    }
    Ok(out)
}
/// One `Sort-Object` key: null first, then by the operator ordering.
#[track_caller]
pub fn order_keys(left: &V, right: &V) -> R<Ordering> {
    match (left, right) {
        (V::Null, V::Null) => Ok(Ordering::Equal),
        (V::Null, _) => match right.n() {
            Some(number) if number.negative() => unreadable(),
            _ => Ok(Ordering::Less),
        },
        (_, V::Null) => match left.n() {
            Some(number) if number.negative() => unreadable(),
            _ => Ok(Ordering::Greater),
        },
        (V::Bool(a), V::Bool(b)) => Ok(a.cmp(b)),
        (V::Str(a), V::Str(b)) => order_text(a, b),
        _ => match (left.n(), right.n()) {
            (Some(a), Some(b)) => compare_numbers(a, b),
            _ => unreadable(),
        },
    }
}

/// [math]::Max / [math]::Min: the result has the first argument's type.
#[track_caller]
pub fn math_pick(first: &V, second: &V, max: bool) -> R<V> {
    let (first, second) = match (first.is_null(), second.is_null()) {
        (true, true) => return Ok(V::Dbl(0.0)),
        (true, false) => (zero_like(second)?, second.clone()),
        _ => (first.clone(), second.clone()),
    };
    let second = match (&first, &second) {
        (V::I32(_), _) => V::I32(second.to_int()?),
        (V::I64(_), _) => V::I64(second.to_long()?),
        (V::Dbl(_), _) => V::Dbl(second.dbl()?),
        (V::Dec(_), V::Null) => V::Dec(Dec::from_i64(0)),
        (V::Dec(_), V::Str(_) | V::Bool(_)) => return unreadable(),
        (V::Dec(_), _) => V::Dec(second.n().map_or_else(unreadable, |n| n.dec())?),
        _ => return unreadable(),
    };
    let order = compare_numbers(first.n().unwrap(), second.n().unwrap())?;
    Ok(if (order == Ordering::Less) == max { second } else { first })
}
#[track_caller]
fn zero_like(value: &V) -> R<V> {
    match value {
        V::I32(_) => Ok(V::I32(0)),
        V::I64(_) => Ok(V::I64(0)),
        V::Dbl(_) => Ok(V::Dbl(0.0)),
        V::Dec(_) if desktop() => Ok(V::Dec(Dec::from_i64(0))),
        _ => unreadable(),
    }
}
/// `($values | Measure-Object -Minimum).Minimum`: a double, or null.
#[track_caller]
pub fn measure_min(values: &[V]) -> R<V> {
    let mut running: Option<f64> = None;
    for (index, value) in values.iter().enumerate() {
        let next = match value {
            V::Null => None,
            _ => Some(value.n().map_or_else(unreadable, |n| Ok(n.f()))?),
        };
        running = match (running, next) {
            _ if index == 0 => next,
            (None, next) => next,
            (Some(current), None) => (current < 0.0).then_some(current),
            (Some(current), Some(next)) => Some(if next < current { next } else { current }),
        };
    }
    Ok(running.map_or(V::Null, V::Dbl))
}
/// `($values | Measure-Object -Sum).Sum`: a double, or null for no input.
#[track_caller]
pub fn measure_sum(values: &[V]) -> R<V> {
    if values.is_empty() {
        return Ok(V::Null);
    }
    let mut sum = 0.0;
    for value in values {
        match value {
            V::Null => {}
            _ => sum += value.n().map_or_else(unreadable, |n| Ok(n.f()))?,
        }
    }
    dbl(sum)
}

/// `$left -eq $right` for two strings.
#[track_caller]
pub fn text_eq(left: &str, right: &str) -> R<bool> {
    same_text(left, right, false)
}
/// `$text -match '[\x00-\x1f\x7f]'`
pub fn has_control(text: &str) -> bool {
    text.chars().any(|c| c < '\u{20}' || c == '\u{7f}')
}
/// ConvertTo-Hotpl8SafeText
pub fn safe_text(text: &str) -> String {
    text.chars().filter(|c| *c >= '\u{20}' && *c != '\u{7f}').collect()
}
/// `$text.Length`
pub fn length(text: &str) -> usize {
    text.encode_utf16().count()
}
/// [string]::IsNullOrWhiteSpace, for text whose blank characters .NET and Rust agree on.
#[track_caller]
pub fn blank(text: &str) -> R<bool> {
    let mut unsure = false;
    for c in text.chars() {
        if c.is_ascii() {
            if !(c == ' ' || ('\t'..='\r').contains(&c)) {
                return Ok(false);
            }
        } else if c.is_whitespace() || matches!(c, '\u{180e}' | '\u{200b}' | '\u{feff}') {
            unsure = true;
        } else {
            return Ok(false);
        }
    }
    if unsure {
        return unreadable();
    }
    Ok(true)
}
/// `$text -match '^[a-zA-Z0-9_-]{1,max}$'`. The pattern's `$` also matches before a final
/// line feed.
pub fn slot_name(text: &str, max: usize) -> bool {
    let body = text.strip_suffix('\n').unwrap_or(text);
    (1..=max).contains(&body.len()) && body.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A `@{}` used as a set of string keys. Its comparison ignores case by the rules of the
/// current culture, so only keys of printable ASCII are modelled, and two keys that
/// differ by case alone are not read.
#[derive(Default)]
pub struct Keys(Vec<String>);
impl Keys {
    pub fn new() -> Keys {
        Keys(Vec::new())
    }
    /// `.ContainsKey($key)`
    #[track_caller]
    pub fn contains(&self, key: &str) -> R<bool> {
        for known in &self.0 {
            if known == key {
                return Ok(true);
            }
            if !printable(known) || !printable(key) || known.eq_ignore_ascii_case(key) {
                return unreadable();
            }
        }
        Ok(false)
    }
    /// `$set[$key] = $true`
    #[track_caller]
    pub fn insert(&mut self, key: &str) -> R<()> {
        if !self.contains(key)? {
            self.0.push(key.to_string());
        }
        Ok(())
    }
}

impl V {
    /// `$value -eq $true`
    #[track_caller]
    pub fn is_true(&self) -> R<bool> {
        self.eq(&V::Bool(true))
    }
    /// `$value -eq $false`
    #[track_caller]
    pub fn is_false(&self) -> R<bool> {
        self.eq(&V::Bool(false))
    }
    /// `$value -is [bool]`
    pub fn is_bool(&self) -> bool {
        matches!(self, V::Bool(_))
    }
    /// `$value -is [pscustomobject]`, for a value read out of an object.
    pub fn is_obj(&self) -> bool {
        matches!(self, V::Obj(_))
    }
    pub fn is_arr(&self) -> bool {
        matches!(self, V::Arr(_))
    }
    /// Whether two values are the same object.
    pub fn same_ref(&self, other: &V) -> bool {
        match (self, other) {
            (V::Obj(a), V::Obj(b)) | (V::Hash(a), V::Hash(b)) => Rc::ptr_eq(a, b),
            _ => false,
        }
    }
    /// `$value.PSObject.Properties[$name]`: whether an object has the member at all.
    #[track_caller]
    pub fn has(&self, name: &str) -> R<bool> {
        match self {
            V::Null => Ok(false),
            V::Obj(o) => Ok(o.borrow().find(name).is_some()),
            _ => unreadable(),
        }
    }
    /// `-$value` as a double: `-[double]$value`.
    #[track_caller]
    pub fn neg_dbl(&self) -> R<V> {
        Ok(V::Dbl(-self.dbl()?))
    }
    /// [math]::Round($value, 1)
    #[track_caller]
    pub fn round1(&self) -> R<V> {
        match self {
            V::Null => Ok(V::Dbl(0.0)),
            V::Dbl(x) => dbl(num::round1(*x)?),
            V::I32(x) => Ok(V::Dec(Dec::from_i64(*x as i64))),
            V::I64(x) => Ok(V::Dec(Dec::from_i64(*x))),
            V::Dec(x) => Ok(V::Dec(x.round1()?)),
            _ => unreadable(),
        }
    }
    /// [math]::Floor($value)
    #[track_caller]
    pub fn floor(&self) -> R<V> {
        match self {
            V::Dbl(x) => dbl(x.floor()),
            V::I32(x) => Ok(V::Dec(Dec::from_i64(*x as i64))),
            V::I64(x) => Ok(V::Dec(Dec::from_i64(*x))),
            V::Dec(x) => Ok(V::Dec(x.floor()?)),
            _ => unreadable(),
        }
    }
    /// `'{0:N0}' -f $value` and `'{0:N1}' -f $value`. What is not a number is printed as
    /// it is; nothing prints as nothing.
    #[track_caller]
    pub fn grouped(&self, decimals: usize) -> R<String> {
        match self {
            V::Dbl(x) => Ok(num::double_grouped(*x, decimals)),
            V::Dec(x) => Ok(x.text_grouped(decimals)),
            V::I32(x) => Ok(num::whole_grouped(i64::from(*x), decimals)),
            V::I64(x) => Ok(num::whole_grouped(*x, decimals)),
            V::Null => Ok(String::new()),
            V::Str(_) => self.s(),
            _ => unreadable(),
        }
    }
    /// `'{0:0.#}' -f $value`
    #[track_caller]
    pub fn tenths(&self) -> R<String> {
        match self {
            V::Dbl(x) => Ok(num::double_tenths(*x)),
            V::Dec(x) => Ok(x.text_tenths()),
            V::I32(x) => Ok(x.to_string()),
            V::I64(x) => Ok(x.to_string()),
            _ => unreadable(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(text: &str) -> V {
        V::s_of(text)
    }
    fn text(value: R<V>) -> String {
        match value {
            Ok(V::Null) => "null".into(),
            Ok(V::I32(x)) => format!("i{x}"),
            Ok(V::I64(x)) => format!("l{x}"),
            Ok(V::Dbl(x)) => format!("d{x:?}"),
            Ok(V::Dec(x)) => format!("m{}", x.text()),
            Ok(V::Str(x)) => format!("s{x}"),
            Ok(_) => "other".into(),
            Err(stop) if stop.thrown() => "throw".into(),
            Err(_) => "unreadable".into(),
        }
    }

    #[test]
    fn arithmetic_keeps_powershell_result_types() {
        let (i, l) = (V::I32, V::I64);
        assert_eq!(text(i(7).div(&i(2))), "d3.5");
        assert_eq!(text(i(6).div(&l(2))), "l3");
        assert_eq!(text(i(100).mul(&l(3)).and_then(|v| v.div(&i(3)))), "l100");
        assert_eq!(text(i(2147483647).add(&i(1))), "d2147483648.0");
        assert_eq!(text(i(100000).mul(&i(100000))), "d10000000000.0");
        assert_eq!(text(i(100).sub(&V::Null)), "i100");
        assert_eq!(text(V::Null.add(&i(5))), "i5");
        assert_eq!(text(V::Null.sub(&i(5))), "i-5");
        assert_eq!(text(V::Null.add(&V::Null)), "null");
        assert_eq!(text(V::Null.sub(&V::Null)), "i0");
        assert_eq!(text(i(100).sub(&s("5"))), "i95");
        assert_eq!(text(i(100).sub(&s("5.5"))), "d94.5");
        assert_eq!(text(i(100).sub(&s("x"))), "throw");
        assert_eq!(text(i(100).sub(&V::Bool(true))), "i99");
        assert_eq!(text(V::Null.mul(&i(5))), "null");
        assert_eq!(text(i(5).mul(&V::Null)), "i0");
        assert_eq!(text(V::Null.div(&i(5))), "i0");
        assert_eq!(text(i(5).div(&V::Null)), "throw");
        assert_eq!(text(V::Dbl(5.0).div(&i(0))), "unreadable");
        assert_eq!(text(s("x").add(&l(45))), "sx45");
        assert_eq!(text(s("r=").add(&V::Bool(false))), "sr=False");
        assert_eq!(text(V::Null.neg()), "i0");
        assert_eq!(text(s("abc").neg()), "throw");
    }

    #[test]
    fn comparisons_follow_the_left_operand() {
        let ok = |value: R<bool>| value.ok();
        assert_eq!(ok(V::Null.lt(&V::I32(5))), Some(true));
        assert_eq!(ok(V::Null.gt(&V::I32(-1))), Some(true));
        assert_eq!(ok(V::Null.eq(&V::I32(0))), Some(false));
        assert_eq!(ok(s("").gt(&V::Null)), Some(true));
        assert_eq!(ok(V::Null.le(&V::Null)), Some(true));
        assert_eq!(ok(s("5").lt(&V::I32(10))), Some(false));
        assert_eq!(ok(s("45").eq(&V::I64(45))), Some(true));
        assert_eq!(ok(s("True").eq(&V::Bool(true))), Some(true));
        assert_eq!(ok(s("true").ceq(&V::Bool(true))), Some(false));
        assert_eq!(ok(V::I32(45).eq(&s("45.5"))), Some(false));
        assert_eq!(ok(V::I32(5).lt(&s("5.4"))), Some(true));
        assert_eq!(ok(V::I32(0).eq(&s(""))), Some(true));
        assert_eq!(ok(V::I32(1).eq(&s("01"))), Some(true));
        assert_eq!(ok(V::I32(1).eq(&s("x"))), Some(false));
        assert!(V::I32(1).lt(&s("x")).is_err_and(|stop| stop.thrown()));
        assert_eq!(ok(V::Bool(true).eq(&s("false"))), Some(true));
        assert_eq!(ok(V::I32(2).eq(&V::Bool(true))), Some(false));
        assert_eq!(ok(s("01").is_in(&V::from(vec![V::I32(1)]))), Some(true));
        assert_eq!(ok(V::I32(1).is_in(&V::from(vec![s("01")]))), Some(false));
        assert_eq!(ok(V::Null.is_in(&V::Null)), Some(true));
        assert_eq!(ok(V::I32(1).is_in(&V::Null)), Some(false));
        assert_eq!(ok(s("a").is_in(&V::from(vec![V::Null, s("a")]))), Some(true));
    }

    #[test]
    fn measure_minimum_follows_the_cmdlet() {
        let d = V::Dbl;
        assert_eq!(text(measure_min(&[d(5.0), V::Null, d(9.0)])), "d9.0");
        assert_eq!(text(measure_min(&[d(5.0), V::Null])), "null");
        assert_eq!(text(measure_min(&[d(-5.0), V::Null, d(3.0)])), "d-5.0");
        assert_eq!(text(measure_min(&[V::Null, d(5.0), d(3.0)])), "d3.0");
        assert_eq!(text(measure_min(&[])), "null");
    }

    #[test]
    fn math_pick_takes_the_first_arguments_type() {
        assert_eq!(text(math_pick(&V::I32(1), &V::Dbl(2.5), true)), "i2");
        assert_eq!(text(math_pick(&V::I32(1), &V::Dbl(3.5), true)), "i4");
        assert_eq!(text(math_pick(&V::Dbl(0.0), &V::I32(-3), true)), "d0.0");
        assert_eq!(text(math_pick(&V::I32(100), &V::Dbl(41.7), false)), "i42");
        assert_eq!(text(math_pick(&V::Null, &V::Null, false)), "d0.0");
    }

    #[test]
    fn text_is_ordered_where_every_culture_table_agrees() {
        let order = |left, right| order_text(left, right).ok();
        assert_eq!(order("claude", "Codex"), Some(Ordering::Less));
        assert_eq!(order("ABC", "abc"), Some(Ordering::Equal));
        assert_eq!(order("claude", "fictional-claude"), Some(Ordering::Less));
        assert_eq!(order("codex-two", "codex"), Some(Ordering::Greater));
        assert_eq!(order("a-b", "a-c"), Some(Ordering::Less));
        // Windows reads "ab" against "aa" here, and ICU a hyphen against a letter.
        assert_eq!(order("a-b", "aa"), None);
        assert_eq!(order("codex", "codex-"), None);
        assert_eq!(order("a b", "a"), None);
        // Timestamps of one spelling differ only in their digits.
        assert_eq!(order("2026-10-06T11:00:00.0000000+00:00", "2026-10-06T10:59:59.9999999+00:00"), Some(Ordering::Greater));
        assert_eq!(order("2026-10-06T11:00:00.0000000+00:00", "2026-10-06T11:00:00.0000000-07:00"), None);
        assert_eq!(order("2026-10-06T11:00:00Z", "2026-10-06T11:00:00.0000000+00:00"), None);
    }

    #[test]
    fn a_list_from_an_if_statement_is_held_bare_when_it_has_one_item() {
        let count = |list: &[V]| held_count(list).ok();
        assert_eq!(count(&[]), Some(0));
        assert_eq!(count(&[V::Null]), Some(0));
        assert_eq!(count(&[V::s_of("work")]), Some(1));
        assert_eq!(count(&[V::I32(0)]), Some(1));
        assert_eq!(count(&[V::Null, V::Null]), Some(2));
        assert_eq!(count(&[new_obj(vec![("Count", V::I32(5))])]), None);
        assert_eq!(count(&[new_obj(vec![]), new_obj(vec![])]), Some(2));
        let pair = V::Arr(Rc::new(vec![V::I32(1), V::I32(2)]));
        assert!(held(vec![pair.clone()]).is_err());
        assert_eq!(held(vec![pair.clone(), pair]).ok().map(|list| list.len()), Some(2));
        assert_eq!(held(vec![V::Null]).ok().map(|list| list.len()), Some(1));
    }
}

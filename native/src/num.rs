//! Numbers as the two PowerShell editions compute and print them: the 96-bit decimal
//! Windows PowerShell gives every JSON fraction, and the text forms of a double.
//! Anything outside what is modelled here stops as unreadable: no state HotPl8 writes reaches it.

use crate::ps::{unreadable, desktop, throw, R};
use std::cmp::Ordering;

pub const MAX96: u128 = (1u128 << 96) - 1;

/// System.Decimal: sign, 96-bit magnitude and a power-of-ten scale of at most 28.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Dec {
    pub neg: bool,
    pub mant: u128,
    pub scale: u8,
}

fn pow10(n: u32) -> u128 {
    10u128.pow(n)
}

/// The doubles .NET keeps in its powers-of-ten table (each literal correctly rounded).
const DOUBLE_POW10: [f64; 29] = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16,
    1e17, 1e18, 1e19, 1e20, 1e21, 1e22, 1e23, 1e24, 1e25, 1e26, 1e27, 1e28,
];

/// value / 10^digits, rounded half to even on the exact dropped part.
fn drop_digits(value: u128, digits: u32) -> u128 {
    if digits == 0 {
        return value;
    }
    let power = pow10(digits);
    let (quotient, rest) = (value / power, value % power);
    match (rest * 2).cmp(&power) {
        Ordering::Greater => quotient + 1,
        Ordering::Equal if quotient & 1 == 1 => quotient + 1,
        _ => quotient,
    }
}

impl Dec {
    pub fn from_i64(value: i64) -> Dec {
        Dec { neg: value < 0, mant: value.unsigned_abs() as u128, scale: 0 }
    }

    pub fn is_zero(&self) -> bool {
        self.mant == 0
    }

    /// A finished result. A zero that came out of a negative operand would be a negative
    /// zero, which the editions print differently; that is not read.
    #[track_caller]
    fn done(neg: bool, mant: u128, scale: u32, negative_operand: bool) -> R<Dec> {
        if mant > MAX96 || scale > 28 {
            return unreadable();
        }
        if mant == 0 {
            if negative_operand {
                return unreadable();
            }
            return Ok(Dec { neg: false, mant: 0, scale: scale as u8 });
        }
        Ok(Dec { neg, mant, scale: scale as u8 })
    }

    /// DecCalc.ScaleResult: the fewest dropped digits that bring the value under 96 bits.
    #[track_caller]
    fn scale_result(mut value: u128, mut scale: u32) -> R<(u128, u32)> {
        let mut drop = scale.saturating_sub(28);
        loop {
            if drop > 38 {
                return unreadable();
            }
            if value / pow10(drop) <= MAX96 {
                break;
            }
            drop += 1;
        }
        if drop > scale {
            return throw();
        }
        let mut rounded = drop_digits(value, drop);
        if rounded > MAX96 {
            drop += 1;
            if drop > scale {
                return throw();
            }
            rounded = drop_digits(value, drop);
        }
        value = rounded;
        scale -= drop;
        Ok((value, scale))
    }

    #[track_caller]
    pub fn mul(self, other: Dec) -> R<Dec> {
        let negative = self.neg || other.neg;
        let neg = self.neg != other.neg;
        let mut scale = self.scale as u32 + other.scale as u32;
        if self.mant < (1 << 32) && other.mant < (1 << 32) {
            let mut product = self.mant * other.mant;
            if scale > 28 {
                if scale > 47 {
                    return Dec::done(false, 0, 0, negative);
                }
                product = drop_digits(product, scale - 28);
                scale = 28;
            }
            return Dec::done(neg, product, scale, negative);
        }
        let Some(product) = self.mant.checked_mul(other.mant) else { return unreadable() };
        if product == 0 {
            return Dec::done(false, 0, 0, negative);
        }
        let (value, scale) = Dec::scale_result(product, scale)?;
        Dec::done(neg, value, scale, negative)
    }

    /// Both magnitudes at the larger of the two scales.
    #[track_caller]
    fn aligned(self, other: Dec) -> R<(u128, u128, u32)> {
        let scale = self.scale.max(other.scale) as u32;
        let left = self.mant.checked_mul(pow10(scale - self.scale as u32));
        let right = other.mant.checked_mul(pow10(scale - other.scale as u32));
        match (left, right) {
            (Some(left), Some(right)) => Ok((left, right, scale)),
            _ => unreadable(),
        }
    }

    #[track_caller]
    pub fn add(self, other: Dec) -> R<Dec> {
        let negative = self.neg || other.neg;
        let (left, right, scale) = self.aligned(other)?;
        let (neg, value) = if self.neg == other.neg {
            let Some(sum) = left.checked_add(right) else { return unreadable() };
            (self.neg, sum)
        } else if left >= right {
            (self.neg, left - right)
        } else {
            (other.neg, right - left)
        };
        if value > MAX96 {
            let (value, scale) = Dec::scale_result(value, scale)?;
            return Dec::done(neg, value, scale, negative);
        }
        Dec::done(neg, value, scale, negative)
    }

    #[track_caller]
    pub fn sub(self, other: Dec) -> R<Dec> {
        if other.is_zero() {
            return self.add(other);
        }
        self.add(Dec { neg: !other.neg, ..other })
    }

    #[track_caller]
    pub fn negated(self) -> R<Dec> {
        if self.is_zero() {
            return unreadable();
        }
        Ok(Dec { neg: !self.neg, ..self })
    }

    /// DecCalc.SearchScale: how many more digits the quotient can take.
    #[track_caller]
    fn search_scale(quotient: u128, scale: i32) -> R<u32> {
        let mut power = 0u32;
        while power < 9 && scale + (power as i32) < 28 {
            match quotient.checked_mul(pow10(power + 1)) {
                Some(next) if next <= MAX96 => power += 1,
                _ => break,
            }
        }
        if power < 9 && (power as i32) + scale < 0 {
            return throw();
        }
        Ok(power)
    }

    /// DecCalc.OverflowUnscale: give back one digit after the quotient outgrew 96 bits.
    #[track_caller]
    fn overflow_unscale(quotient: u128, scale: i32, sticky: bool) -> R<(u128, i32)> {
        let scale = scale - 1;
        if scale < 0 {
            return throw();
        }
        let (mut next, rest) = (quotient / 10, quotient % 10);
        if rest > 5 || (rest == 5 && (sticky || next & 1 == 1)) {
            next += 1;
        }
        Ok((next, scale))
    }

    /// DecCalc.VarDecDiv.
    #[track_caller]
    pub fn div(self, other: Dec) -> R<Dec> {
        if other.is_zero() {
            return throw();
        }
        let negative = self.neg || other.neg;
        let neg = self.neg != other.neg;
        let divisor = other.mant;
        let mut scale = self.scale as i32 - other.scale as i32;
        let mut quotient = self.mant / divisor;
        let mut rest = self.mant % divisor;
        let mut unscale = false;
        loop {
            if rest == 0 {
                if scale < 0 {
                    let power = 9.min(-scale) as u32;
                    scale += power as i32;
                    quotient = match quotient.checked_mul(pow10(power)) {
                        Some(next) if next <= MAX96 => next,
                        _ => return throw(),
                    };
                    continue;
                }
                break;
            }
            unscale = true;
            let power = if scale == 28 { 0 } else { Dec::search_scale(quotient, scale)? };
            if power == 0 {
                let twice = rest * 2;
                if twice > divisor || (twice == divisor && quotient & 1 == 1) {
                    quotient += 1;
                    if quotient > MAX96 {
                        (quotient, scale) = Dec::overflow_unscale(quotient, scale, true)?;
                    }
                }
                break;
            }
            scale += power as i32;
            let Some(scaled) = rest.checked_mul(pow10(power)) else { return unreadable() };
            let Some(next) = quotient.checked_mul(pow10(power)).and_then(|q| q.checked_add(scaled / divisor)) else {
                return unreadable();
            };
            quotient = next;
            rest = scaled % divisor;
            if quotient > MAX96 {
                (quotient, scale) = Dec::overflow_unscale(quotient, scale, rest != 0)?;
                break;
            }
        }
        if unscale {
            while scale > 0 && quotient != 0 && quotient % 10 == 0 {
                quotient /= 10;
                scale -= 1;
            }
        }
        if scale < 0 {
            return unreadable();
        }
        Dec::done(neg, quotient, scale as u32, negative)
    }

    #[track_caller]
    pub fn compare(self, other: Dec) -> R<Ordering> {
        if self.is_zero() && other.is_zero() {
            return Ok(Ordering::Equal);
        }
        let left_neg = self.neg && !self.is_zero();
        let right_neg = other.neg && !other.is_zero();
        if left_neg != right_neg {
            return Ok(if left_neg { Ordering::Less } else { Ordering::Greater });
        }
        let (left, right, _) = self.aligned(other)?;
        Ok(if left_neg { right.cmp(&left) } else { left.cmp(&right) })
    }

    /// [math]::Round(x, 1) for a decimal: half to even, never more than one fraction digit.
    #[track_caller]
    pub fn round1(self) -> R<Dec> {
        if self.scale <= 1 {
            return Ok(self);
        }
        Dec::done(self.neg, drop_digits(self.mant, self.scale as u32 - 1), 1, self.neg)
    }

    #[track_caller]
    pub fn floor(self) -> R<Dec> {
        let power = pow10(self.scale as u32);
        let (mut whole, rest) = (self.mant / power, self.mant % power);
        if self.neg && rest != 0 {
            whole += 1;
        }
        Dec::done(self.neg, whole, 0, self.neg)
    }

    /// [long]$decimal: half to even; out of range throws.
    #[track_caller]
    pub fn to_i64(self) -> R<i64> {
        let whole = drop_digits(self.mant, self.scale as u32);
        if self.neg {
            if whole > 1u128 << 63 {
                return throw();
            }
            return Ok((whole as i128).wrapping_neg() as i64);
        }
        if whole > i64::MAX as u128 {
            return throw();
        }
        Ok(whole as i64)
    }

    /// [double]$decimal.
    pub fn to_f64(self) -> f64 {
        let low = (self.mant & u64::MAX as u128) as u64;
        let high = (self.mant >> 64) as u32;
        let value = (low as f64 + high as f64 * 18446744073709551616.0) / DOUBLE_POW10[self.scale as usize];
        if self.neg {
            -value
        } else {
            value
        }
    }

    /// [decimal]$double (VarDecFromR8): fifteen significant digits, trailing zeros removed.
    #[track_caller]
    pub fn from_f64(input: f64) -> R<Dec> {
        if !input.is_finite() {
            return throw();
        }
        let exponent = ((input.to_bits() >> 52) & 0x7ff) as i32 - 1022;
        if exponent < -94 {
            return Dec::done(false, 0, 0, input.is_sign_negative());
        }
        if exponent > 96 {
            return throw();
        }
        let neg = input < 0.0;
        let mut value = input.abs();
        let mut power = 14 - ((exponent * 19728) >> 16);
        if power >= 0 {
            power = power.min(28);
            value *= DOUBLE_POW10[power as usize];
        } else if power != -1 || value >= 1e15 {
            value /= DOUBLE_POW10[(-power) as usize];
        } else {
            power = 0;
        }
        if value < 1e14 && power < 28 {
            value *= 10.0;
            power += 1;
        }
        let mut mant = value.round_ties_even() as u128;
        if mant == 0 {
            return Dec::done(false, 0, 0, neg);
        }
        if power < 0 {
            mant *= pow10((-power) as u32);
            return Dec::done(neg, mant, 0, neg);
        }
        let mut most = power.min(14);
        while most > 0 && mant % 10 == 0 {
            mant /= 10;
            power -= 1;
            most -= 1;
        }
        Dec::done(neg, mant, power as u32, neg)
    }

    /// The decimal's text; the scale is kept ("45.0").
    pub fn text(self) -> String {
        let digits = self.mant.to_string();
        let scale = self.scale as usize;
        let mut out = String::new();
        if self.neg && !self.is_zero() {
            out.push('-');
        }
        if scale == 0 {
            out.push_str(&digits);
        } else if digits.len() > scale {
            out.push_str(&digits[..digits.len() - scale]);
            out.push('.');
            out.push_str(&digits[digits.len() - scale..]);
        } else {
            out.push_str("0.");
            out.push_str(&"0".repeat(scale - digits.len()));
            out.push_str(&digits);
        }
        out
    }

    /// '{0:0.#}' -f $decimal: one fraction digit at most, half away from zero.
    pub fn text_tenths(self) -> String {
        let scale = self.scale as u32;
        let tenths = if scale <= 1 {
            self.mant * pow10(1 - scale)
        } else {
            let power = pow10(scale - 1);
            let (kept, rest) = (self.mant / power, self.mant % power);
            if rest * 2 >= power {
                kept + 1
            } else {
                kept
            }
        };
        tenths_text(self.neg && tenths != 0, &tenths.to_string())
    }

    /// [math]::Round(x) for a decimal: half to even.
    #[track_caller]
    pub fn round0(self) -> R<Dec> {
        Dec::done(self.neg, drop_digits(self.mant, self.scale as u32), 0, self.neg)
    }

    /// '{0:N0}' -f $decimal and '{0:N1}' -f $decimal: half away from zero.
    pub fn text_grouped(self, decimals: usize) -> String {
        let (negative, plain) = self.fixed(decimals);
        grouped(negative, &plain)
    }

    /// '{0:0}' -f $decimal: half away from zero.
    pub fn text_whole(self) -> String {
        let (negative, plain) = self.fixed(0);
        if negative {
            format!("-{plain}")
        } else {
            plain
        }
    }

    /// Rounded half away from zero to that many fraction digits: whether it is below zero
    /// and not nothing, and its plain digits.
    fn fixed(self, decimals: usize) -> (bool, String) {
        let (scale, wanted) = (self.scale as u32, decimals as u32);
        let kept = if scale <= wanted {
            self.mant * pow10(wanted - scale)
        } else {
            let power = pow10(scale - wanted);
            let (kept, rest) = (self.mant / power, self.mant % power);
            if rest * 2 >= power {
                kept + 1
            } else {
                kept
            }
        };
        let mut plain = format!("{kept:0width$}", width = decimals + 1);
        if decimals > 0 {
            plain.insert(plain.len() - decimals, '.');
        }
        (self.neg && kept != 0, plain)
    }
}

/// Digits of a whole number of tenths as "12.3", "12" or "0".
fn tenths_text(neg: bool, digits: &str) -> String {
    let (whole, tenth) = digits.split_at(digits.len() - 1);
    let mut out = String::new();
    if neg {
        out.push('-');
    }
    out.push_str(if whole.is_empty() { "0" } else { whole });
    if tenth != "0" {
        out.push('.');
        out.push_str(tenth);
    }
    out
}

/// The fifteen significant decimal digits .NET formats a double with, and the power of ten
/// of the first one.
fn fifteen_digits(value: f64) -> (Vec<u8>, i32) {
    significant_digits(value, 15)
}

/// That many significant decimal digits of a double, and the power of ten of the first
/// one. Rounding starts from the exact binary value; an exact tie goes up on Windows
/// PowerShell and to even on PowerShell 7.
fn significant_digits(value: f64, count: usize) -> (Vec<u8>, i32) {
    rounded_digits(value, count, desktop())
}

/// The same, with what an exact tie does said by the caller.
fn rounded_digits(value: f64, count: usize, tie_up: bool) -> (Vec<u8>, i32) {
    let exact = format!("{:.800e}", value.abs());
    let (mantissa, exponent) = exact.split_once('e').expect("exponent form");
    let mut exponent: i32 = exponent.parse().expect("exponent");
    let all: Vec<u8> = mantissa.bytes().filter(|b| *b != b'.').map(|b| b - b'0').collect();
    let mut digits = all[..count].to_vec();
    let tail_is_zero = all[count + 1..].iter().all(|d| *d == 0);
    let up = match all[count].cmp(&5) {
        Ordering::Greater => true,
        Ordering::Less => false,
        Ordering::Equal => !tail_is_zero || tie_up || digits[count - 1] % 2 == 1,
    };
    if up {
        let mut index = count;
        loop {
            if index == 0 {
                digits.insert(0, 1);
                digits.pop();
                exponent += 1;
                break;
            }
            index -= 1;
            if digits[index] == 9 {
                digits[index] = 0;
            } else {
                digits[index] += 1;
                break;
            }
        }
    }
    (digits, exponent)
}

/// [string]$double and string concatenation of a double: the "G15" form on both editions.
pub fn double_text(value: f64) -> String {
    if value == 0.0 {
        return if value.is_sign_negative() && !desktop() { "-0".into() } else { "0".into() };
    }
    let (digits, exponent) = fifteen_digits(value);
    general(value < 0.0, digits, exponent, 15)
}

/// .NET's "G" form of those digits: plain, or with an exponent once the first digit is
/// worth 10 to the `precision` or less than 0.0001.
fn general(negative: bool, mut digits: Vec<u8>, exponent: i32, precision: i32) -> String {
    while digits.len() > 1 && digits[digits.len() - 1] == 0 {
        digits.pop();
    }
    let text: String = digits.iter().map(|d| (b'0' + d) as char).collect();
    let mut out = String::new();
    if negative {
        out.push('-');
    }
    if exponent >= precision || exponent < -4 {
        out.push_str(&text[..1]);
        if text.len() > 1 {
            out.push('.');
            out.push_str(&text[1..]);
        }
        out.push('E');
        out.push(if exponent < 0 { '-' } else { '+' });
        out.push_str(&format!("{:02}", exponent.abs()));
    } else if exponent < 0 {
        out.push_str("0.");
        out.push_str(&"0".repeat((-exponent - 1) as usize));
        out.push_str(&text);
    } else {
        let whole = exponent as usize + 1;
        if text.len() <= whole {
            out.push_str(&text);
            out.push_str(&"0".repeat(whole - text.len()));
        } else {
            out.push_str(&text[..whole]);
            out.push('.');
            out.push_str(&text[whole..]);
        }
    }
    out
}

/// ConvertTo-Json's text for a double. Windows PowerShell writes fifteen digits where they
/// read back as the same double and seventeen where they do not; PowerShell 7 writes the
/// fewest digits that read back, and marks a whole number with ".0".
pub fn double_json(value: f64) -> String {
    if desktop() {
        if value == 0.0 {
            return "0".into();
        }
        let (digits, exponent) = fifteen_digits(value);
        let short = general(value < 0.0, digits, exponent, 15);
        if short.parse::<f64>() == Ok(value) {
            return short;
        }
        let (digits, exponent) = significant_digits(value, 17);
        return general(value < 0.0, digits, exponent, 17);
    }
    if value == 0.0 {
        return if value.is_sign_negative() { "-0.0".into() } else { "0.0".into() };
    }
    let shortest = format!("{:e}", value.abs());
    let (mantissa, exponent) = shortest.split_once('e').expect("exponent form");
    let fewest: Vec<u8> = mantissa.bytes().filter(|b| *b != b'.').map(|b| b - b'0').collect();
    // Where two texts of that length are equally near, .NET takes the even one.
    let (digits, exponent) = match significant_digits(value, fewest.len()) {
        (digits, exponent) if general(false, digits.clone(), exponent, 17).parse::<f64>() == Ok(value.abs()) => (digits, exponent),
        _ => (fewest, exponent.parse().expect("exponent")),
    };
    let mut text = general(value < 0.0, digits, exponent, 17);
    if !text.contains(['.', 'E']) {
        text.push_str(".0");
    }
    text
}

/// '{0:N0}' -f $double and '{0:N1}' -f $double, with the invariant culture's separators.
/// Windows PowerShell takes fifteen digits and rounds half away from zero; PowerShell 7
/// rounds the exact value, a half going to the even digit.
pub fn double_grouped(value: f64, decimals: usize) -> String {
    let (negative, plain) = if desktop() { fixed(value, decimals) } else { (value.is_sign_negative(), format!("{:.*}", decimals, value.abs())) };
    grouped(negative, &plain)
}

/// A double as a whole number, printed one way wherever HotPl8 runs: the fifteen digits a
/// double has always been shown with, then half away from zero. What rounds to nothing
/// is `0`, never `-0`.
pub fn double_whole(value: f64) -> String {
    let (negative, plain) = fixed(value, 0);
    if negative {
        format!("-{plain}")
    } else {
        plain
    }
}

/// A double's fifteen digits rounded half away from zero to that many fraction digits:
/// whether it is below zero and not nothing, and its plain digits.
fn fixed(value: f64, decimals: usize) -> (bool, String) {
    let (mut kept, mut up) = (Vec::new(), false);
    if value != 0.0 {
        let (digits, exponent) = rounded_digits(value, 15, true);
        // digits[i] is worth 10^(exponent - i); the last digit kept sits at `last`.
        let last = exponent + decimals as i32;
        let digit = |index: i32| if index >= 0 && (index as usize) < digits.len() { digits[index as usize] } else { 0 };
        kept = (0..=last).map(digit).collect();
        up = last >= -1 && digit(last + 1) >= 5;
    }
    if up {
        let mut index = kept.len();
        loop {
            if index == 0 {
                kept.insert(0, 1);
                break;
            }
            index -= 1;
            if kept[index] == 9 {
                kept[index] = 0;
            } else {
                kept[index] += 1;
                break;
            }
        }
    }
    while kept.len() < decimals + 1 {
        kept.insert(0, 0);
    }
    let first = kept.iter().position(|d| *d != 0).unwrap_or(kept.len()).min(kept.len() - decimals - 1);
    let mut text: String = kept[first..].iter().map(|d| (b'0' + d) as char).collect();
    if decimals > 0 {
        text.insert(text.len() - decimals, '.');
    }
    (value < 0.0 && kept.iter().any(|d| *d != 0), text)
}

/// Plain digits with a comma between every three of the whole part.
fn grouped(negative: bool, plain: &str) -> String {
    let (whole, fraction) = plain.split_at(plain.find('.').unwrap_or(plain.len()));
    let mut out = String::new();
    if negative {
        out.push('-');
    }
    for (index, digit) in whole.chars().enumerate() {
        if index > 0 && (whole.len() - index) % 3 == 0 {
            out.push(',');
        }
        out.push(digit);
    }
    out.push_str(fraction);
    out
}

/// '{0:N0}' -f $whole and '{0:N1}' -f $whole
pub fn whole_grouped(value: i64, decimals: usize) -> String {
    let mut plain = value.unsigned_abs().to_string();
    if decimals > 0 {
        plain.push('.');
        plain.push_str(&"0".repeat(decimals));
    }
    grouped(value < 0, &plain)
}

/// '{0:0.#}' -f $double: the fifteen digits, then half away from zero at one fraction digit.
pub fn double_tenths(value: f64) -> String {
    if value == 0.0 {
        return if value.is_sign_negative() && !desktop() { "-0".into() } else { "0".into() };
    }
    let (digits, exponent) = fifteen_digits(value);
    // digits[i] is worth 10^(exponent - i); the tenths digit sits at index exponent + 1.
    let last = exponent + 1;
    let mut kept: Vec<u8> = Vec::new();
    for index in 0..=last.max(-1) {
        kept.push(if (index as usize) < digits.len() { digits[index as usize] } else { 0 });
    }
    if kept.is_empty() {
        kept.push(0);
    }
    let next = last + 1;
    let up = next >= 0 && (next as usize) < digits.len() && digits[next as usize] >= 5;
    if up {
        let mut index = kept.len();
        loop {
            if index == 0 {
                kept.insert(0, 1);
                break;
            }
            index -= 1;
            if kept[index] == 9 {
                kept[index] = 0;
            } else {
                kept[index] += 1;
                break;
            }
        }
    }
    let zero = kept.iter().all(|d| *d == 0);
    let text: String = kept.iter().map(|d| (b'0' + d) as char).collect();
    let text = text.trim_start_matches('0');
    let text = if text.is_empty() { "0" } else { text };
    if zero {
        return if value < 0.0 && !desktop() { "-0".into() } else { "0".into() };
    }
    tenths_text(value < 0.0, text)
}

/// [math]::Round($double, 1): half to even on the scaled value.
#[track_caller]
pub fn round1(value: f64) -> R<f64> {
    if !value.is_finite() || value.abs() >= 1e16 {
        return unreadable();
    }
    Ok((value * 10.0).round_ties_even() / 10.0)
}

/// A double converted to a whole number the way a PowerShell cast does (half to even).
#[track_caller]
pub fn double_to_i64(value: f64) -> R<i64> {
    if !value.is_finite() {
        return throw();
    }
    let rounded = value.round_ties_even();
    if rounded < -9223372036854775808.0 || rounded >= 9223372036854775808.0 {
        return throw();
    }
    Ok(rounded as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ps::set_core;

    fn d(text: &str) -> Dec {
        let neg = text.starts_with('-');
        let body = text.trim_start_matches('-');
        let scale = body.split_once('.').map_or(0, |(_, f)| f.len());
        Dec { neg, mant: body.replace('.', "").parse().unwrap(), scale: scale as u8 }
    }
    fn t(value: R<Dec>) -> String {
        value.ok().map_or("stop".into(), Dec::text)
    }

    #[test]
    fn grouped_numbers_match_each_edition() {
        let cases: [(f64, usize); 18] = [
            (0.5, 0), (1.5, 0), (2.5, 0), (1234.5, 0), (0.25, 1), (0.35, 1), (1234.05, 1), (-0.4, 0), (99.5, 0),
            (2.675, 1), (100.0, 0), (37.0, 0), (6.95, 1), (0.049999, 1), (12345678.5, 0), (-1234.56, 1), (63.0, 0), (0.0, 1),
        ];
        let all = |core: bool| {
            set_core(core);
            cases.iter().map(|(value, decimals)| double_grouped(*value, *decimals)).collect::<Vec<_>>().join("|")
        };
        assert_eq!(all(false), "1|2|3|1,235|0.3|0.4|1,234.1|0|100|2.7|100|37|7.0|0.0|12,345,679|-1,234.6|63|0.0");
        assert_eq!(all(true), "0|2|2|1,234|0.2|0.3|1,234.0|-0|100|2.7|100|37|7.0|0.0|12,345,678|-1,234.6|63|0.0");
    }

    /// What Windows PowerShell prints for '{0:N0}' and '{0:N1}' of a decimal and a whole number.
    #[test]
    fn grouped_decimals_round_half_away_from_zero() {
        let all: Vec<String> = [("62.5", 0), ("2.5", 0), ("-0.5", 0), ("1234.25", 1), ("1234567.5", 0), ("0.04", 1), ("-0.4", 0), ("7", 1)]
            .iter()
            .map(|(value, decimals)| d(value).text_grouped(*decimals))
            .collect();
        assert_eq!(all.join("|"), "63|3|-1|1,234.3|1,234,568|0.0|0|7.0");
        assert_eq!(whole_grouped(2_147_483_648, 0), "2,147,483,648");
        assert_eq!(whole_grouped(-5, 1), "-5.0");
    }

    #[test]
    fn decimal_arithmetic_matches_dotnet() {
        assert_eq!(t(d("100").sub(d("45.50"))), "54.50");
        assert_eq!(t(d("45.50").mul(d("100"))), "4550.00");
        assert_eq!(t(d("100").div(d("3"))), "33.333333333333333333333333333");
        assert_eq!(t(d("1.50").div(d("0.5"))), "3.0");
        assert_eq!(t(d("1").div(d("8"))), "0.125");
        assert_eq!(t(d("45.5").div(d("100"))), "0.455");
        assert_eq!(t(d("100").mul(d("1.5")).and_then(|v| v.div(d("3")))), "50.0");
        assert_eq!(t(d("100").mul(d("-7.25")).and_then(|v| v.div(d("3")))), "-241.66666666666666666666666667");
        assert_eq!(t(d("1.5").mul(d("0.1"))), "0.15");
        assert_eq!(t(d("1.0").div(d("3"))), "0.3333333333333333333333333333");
        assert_eq!(t(d("1.5").mul(d("2"))), "3.0");
        assert_eq!(t(d("100").sub(d("38.0"))), "62.0");
        assert_eq!(t(d("1").div(d("0"))), "stop");
    }

    #[test]
    fn doubles_become_decimals_like_vardecfromr8() {
        assert_eq!(t(Dec::from_f64(93.66666666666666)), "93.6666666666666");
        assert_eq!(t(Dec::from_f64(0.1 + 0.2)), "0.3");
        assert_eq!(t(Dec::from_f64(1.0 / 3.0)), "0.333333333333333");
        assert_eq!(t(Dec::from_f64(123456789.123456789)), "123456789.123457");
        assert_eq!(t(Dec::from_f64(1e-10)), "0.0000000001");
        assert_eq!(t(Dec::from_f64(6.02e23)), "602000000000000000000000");
        assert_eq!(t(Dec::from_f64(1e28)), "10000000000000000000000000000");
        assert_eq!(t(Dec::from_f64(1e29)), "stop");
        assert_eq!(t(Dec::from_f64(100.0)), "100");
    }

    #[test]
    fn decimals_become_doubles() {
        set_core(false);
        let text = |s: &str| format!("{:?}", d(s).to_f64());
        assert_eq!(text("93.66666666666666666666666667"), "93.66666666666666");
        assert_eq!(text("79228162514264337593543950335"), "7.922816251426434e28");
        assert_eq!(text("0.0000000000000000000000000001"), "1.0000000000000001e-28");
        assert_eq!(text("0.1"), "0.1");
        assert_eq!(text("45.50"), "45.5");
    }

    #[test]
    fn doubles_print_with_fifteen_digits() {
        set_core(false);
        for (value, text) in [
            (93.66666666666667, "93.6666666666667"),
            (0.186, "0.186"),
            (1e15, "1E+15"),
            (1e14, "100000000000000"),
            (123456789012345.6, "123456789012346"),
            (1e-5, "1E-05"),
            (0.0001, "0.0001"),
            (0.1 + 0.2, "0.3"),
            (100.0, "100"),
            (1e20, "1E+20"),
            (f64::MAX, "1.79769313486232E+308"),
            (-2.5, "-2.5"),
            (1.0 / 3.0, "0.333333333333333"),
            (1e-7, "1E-07"),
            (123456789.123456789, "123456789.123457"),
            (1.2345678901234567e19, "1.23456789012346E+19"),
            (0.00012345678901234567, "0.000123456789012346"),
            (5e-324, "4.94065645841247E-324"),
            (1.0, "1"),
        ] {
            assert_eq!(double_text(value), text);
        }
        for (bits, general, tenths) in [
            (4663467327720880290u64, "6134.82645329661", "6134.8"),
            (4632114114075903958, "49.1503496846559", "49.2"),
            (4634534240564882568, "68.6927652965989", "68.7"),
            (4631106063410970257, "41.9877189121882", "42"),
            (4651964248897755575, "995.10465119854", "995.1"),
            (4816244402031689824, "100000000000002", "100000000000002"),
            (4823355200913801220, "281474976710656", "281474976710656"),
            (4841369599423283202, "4.5035996273705E+15", "4503599627370500"),
            (4539628424389459968, "3.0517578125E-05", "0"),
        ] {
            assert_eq!(double_text(f64::from_bits(bits)), general);
            assert_eq!(double_tenths(f64::from_bits(bits)), tenths);
        }
        assert_eq!(double_text(f64::from_bits(4816244402031689760)), "100000000000001");
        assert_eq!(double_text(f64::from_bits(4827858800541171716)), "562949953421313");
        assert_eq!(double_text(-0.0), "0");
        set_core(true);
        assert_eq!(double_text(f64::from_bits(4816244402031689760)), "100000000000000");
        assert_eq!(double_text(f64::from_bits(4827858800541171716)), "562949953421312");
        assert_eq!(double_text(-0.0), "-0");
    }

    #[test]
    fn doubles_are_spelled_as_convertto_json_spells_them() {
        // Each line: the double, Windows PowerShell 5.1's text, PowerShell 7.6's text.
        let written = [
            (0.00001, "1E-05", "1E-05"),
            (0.0001, "0.0001", "0.0001"),
            (0.00012345, "0.00012345", "0.00012345"),
            (100.0 - 99.99995, "5.0000000001659828E-05", "5.000000000165983E-05"),
            (100.0 - 99.99999999999999, "1.4210854715202004E-14", "1.4210854715202004E-14"),
            (1e15, "1E+15", "1000000000000000.0"),
            (1e16, "1E+16", "10000000000000000.0"),
            (123456789012345678.0, "1.2345678901234568E+17", "1.2345678901234568E+17"),
            (26.0, "26", "26.0"),
            (0.0, "0", "0.0"),
            (100.0 - 99.9, "0.099999999999994316", "0.09999999999999432"),
            (-73.5, "-73.5", "-73.5"),
            // Halfway between two seventeen-digit texts: up on one edition, to even on the other.
            (f64::from_bits(0x4306f95d5e502a01), "808328612152640.13", "808328612152640.1"),
        ];
        for (value, desktop_text, core_text) in written {
            set_core(false);
            assert_eq!(double_json(value), desktop_text);
            set_core(true);
            assert_eq!(double_json(value), core_text);
        }
        assert_eq!(double_tenths(-0.04), "-0");
        set_core(false);
        assert_eq!(double_tenths(-0.04), "0");
    }

    #[test]
    fn one_fraction_digit_rounds_away_from_zero() {
        set_core(false);
        for (value, text) in [
            (93.66666666666667, "93.7"),
            (6.333333333333338, "6.3"),
            (0.186, "0.2"),
            (0.05, "0.1"),
            (0.25, "0.3"),
            (0.45, "0.5"),
            (1.45, "1.5"),
            (2.675, "2.7"),
            (2.5, "2.5"),
            (99.95, "100"),
            (99.949999999999989, "100"),
            (64.45, "64.5"),
            (64.449999999999996, "64.5"),
            (0.049999999999999996, "0.1"),
            (0.94999999999999996, "1"),
            (1e14, "100000000000000"),
            (123456789012345.6, "123456789012346"),
            (999999999999999.5, "1000000000000000"),
            (9999999999999995.0, "10000000000000000"),
            (1e15, "1000000000000000"),
            (1e-5, "0"),
            (123456789.96, "123456790"),
            (1e20, "100000000000000000000"),
            (1.2345678901234567e19, "12345678901234600000"),
            (-12.35, "-12.4"),
            (1234567890123.25, "1234567890123.3"),
        ] {
            assert_eq!(double_tenths(value), text, "{value:?}");
        }
        assert_eq!(d("6.35").text_tenths(), "6.4");
        assert_eq!(d("6.25").text_tenths(), "6.3");
        assert_eq!(d("-0.04").text_tenths(), "0");
        assert_eq!(d("64.5").text_tenths(), "64.5");
        assert_eq!(d("35").text_tenths(), "35");
    }

    #[test]
    fn a_whole_number_is_printed_one_way_on_both_editions() {
        for core in [false, true] {
            crate::ps::set_core(core);
            let printed: Vec<String> = [-0.04, -0.4, -0.5, 0.5, 1.5, 2.5, 0.49999999999999994, 99.5, 99.49999999999999, 1234.5, 0.0, -0.0, 100.0].map(double_whole).to_vec();
            assert_eq!(printed, ["0", "0", "-1", "1", "2", "3", "1", "100", "100", "1235", "0", "0", "100"]);
        }
        crate::ps::set_core(false);
        assert_eq!([d("2.5").text_whole(), d("-0.4").text_whole(), d("-2.5").text_whole(), d("1234.49").text_whole()], ["3", "0", "-3", "1234"]);
        assert_eq!([t(d("2.5").round0()), t(d("3.5").round0()), t(d("2.51").round0())], ["2", "4", "3"]);
    }

    #[test]
    fn rounding_and_casts() {
        assert_eq!(round1(98.75).ok(), Some(98.8));
        assert_eq!(round1(98.85).ok(), Some(98.8));
        assert_eq!(round1(0.25).ok(), Some(0.2));
        assert_eq!(round1(64.45).ok(), Some(64.4));
        assert_eq!(double_to_i64(2.5).ok(), Some(2));
        assert_eq!(double_to_i64(3.5).ok(), Some(4));
        assert_eq!(double_to_i64(-0.5).ok(), Some(0));
        assert_eq!(d("45.5").to_i64().ok(), Some(46));
        assert_eq!(d("2.5").to_i64().ok(), Some(2));
        assert_eq!(t(d("2.45").round1()), "2.4");
        assert_eq!(t(d("7.9").floor()), "7");
    }
}

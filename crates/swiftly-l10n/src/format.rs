//! `printf`-style placeholders as Swift's `String(format:)` and `String(localized:)`
//! use them: `%@`, `%d`, `%lld`, `%.1f`, `%1$@`, `%%`.

use std::fmt::Write as _;

/// An argument for a placeholder.
#[derive(Clone, Debug, PartialEq)]
pub enum Arg {
    /// Text (`%@`, `%s`).
    Str(String),
    /// Signed whole number (`%d`, `%lld`).
    Int(i64),
    /// Unsigned whole number (`%u`).
    Uint(u64),
    /// Floating point (`%f`, `%g`).
    Float(f64),
}

impl From<&str> for Arg {
    fn from(v: &str) -> Self {
        Self::Str(v.to_owned())
    }
}
impl From<String> for Arg {
    fn from(v: String) -> Self {
        Self::Str(v)
    }
}
impl From<i32> for Arg {
    fn from(v: i32) -> Self {
        Self::Int(i64::from(v))
    }
}
impl From<i64> for Arg {
    fn from(v: i64) -> Self {
        Self::Int(v)
    }
}
impl From<u32> for Arg {
    fn from(v: u32) -> Self {
        Self::Uint(u64::from(v))
    }
}
impl From<u64> for Arg {
    fn from(v: u64) -> Self {
        Self::Uint(v)
    }
}
impl From<usize> for Arg {
    fn from(v: usize) -> Self {
        Self::Uint(v as u64)
    }
}
impl From<f64> for Arg {
    fn from(v: f64) -> Self {
        Self::Float(v)
    }
}

impl Arg {
    fn display(&self) -> String {
        match self {
            Self::Str(s) => s.clone(),
            Self::Int(i) => i.to_string(),
            Self::Uint(u) => u.to_string(),
            Self::Float(f) => f.to_string(),
        }
    }

    fn as_i128(&self) -> Option<i128> {
        match self {
            Self::Int(i) => Some(i128::from(*i)),
            Self::Uint(u) => Some(i128::from(*u)),
            Self::Float(f) if f.is_finite() => Some(*f as i128),
            _ => None,
        }
    }

    fn as_f64(&self) -> Option<f64> {
        match self {
            Self::Int(i) => Some(*i as f64),
            Self::Uint(u) => Some(*u as f64),
            Self::Float(f) => Some(*f),
            Self::Str(s) => s.trim().parse().ok(),
        }
    }
}

/// What kind of value a placeholder takes. Two translations of a key must agree on it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ArgClass {
    /// `%@`, `%s`.
    Text,
    /// `%d`, `%i`, `%u`, `%lld`, `%x`, `%p` ...
    Integer,
    /// `%f`, `%e`, `%g`.
    Float,
    /// `%c`.
    Char,
}

/// One placeholder found in a format string.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Placeholder {
    /// 1-based argument position (`%2$@` is 2; plain placeholders count up from 1).
    pub position: usize,
    /// The kind of value expected.
    pub class: ArgClass,
    /// The conversion letter (`@`, `d`, `f` ...).
    pub conversion: char,
    left: bool,
    zero: bool,
    plus: bool,
    space: bool,
    width: usize,
    precision: Option<usize>,
    raw: String,
}

/// A piece of a format string.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Token {
    /// Literal text (with `%%` already reduced to `%`).
    Literal(String),
    /// A placeholder.
    Placeholder(Placeholder),
}

fn class_of(conv: char) -> Option<ArgClass> {
    match conv {
        '@' | 's' | 'S' => Some(ArgClass::Text),
        'c' | 'C' => Some(ArgClass::Char),
        'd' | 'D' | 'i' | 'u' | 'U' | 'x' | 'X' | 'o' | 'O' | 'p' => Some(ArgClass::Integer),
        'f' | 'F' | 'e' | 'E' | 'g' | 'G' | 'a' | 'A' => Some(ArgClass::Float),
        _ => None,
    }
}

/// Splits a format string into literals and placeholders. A `%` that does not start a
/// valid placeholder stays literal.
pub fn parse(text: &str) -> Vec<Token> {
    let chars: Vec<char> = text.chars().collect();
    let mut tokens = Vec::new();
    let mut literal = String::new();
    let mut next_position = 1usize;
    let mut i = 0;
    while i < chars.len() {
        if chars[i] != '%' {
            literal.push(chars[i]);
            i += 1;
            continue;
        }
        if chars.get(i + 1) == Some(&'%') {
            literal.push('%');
            i += 2;
            continue;
        }
        let start = i;
        let mut j = i + 1;
        // Optional `n$`.
        let digits_start = j;
        while chars.get(j).is_some_and(char::is_ascii_digit) {
            j += 1;
        }
        let mut position = None;
        if j > digits_start && chars.get(j) == Some(&'$') {
            position = chars[digits_start..j]
                .iter()
                .collect::<String>()
                .parse::<usize>()
                .ok()
                .filter(|p| *p > 0);
            j += 1;
        } else {
            j = digits_start;
        }
        let (mut left, mut zero, mut plus, mut space) = (false, false, false, false);
        while let Some(&c) = chars.get(j) {
            match c {
                '-' => left = true,
                '0' => zero = true,
                '+' => plus = true,
                ' ' => space = true,
                '#' => {}
                _ => break,
            }
            j += 1;
        }
        let w_start = j;
        while chars.get(j).is_some_and(char::is_ascii_digit) {
            j += 1;
        }
        let width = chars[w_start..j]
            .iter()
            .collect::<String>()
            .parse()
            .unwrap_or(0);
        let mut precision = None;
        if chars.get(j) == Some(&'.') {
            j += 1;
            let p_start = j;
            while chars.get(j).is_some_and(char::is_ascii_digit) {
                j += 1;
            }
            precision = Some(
                chars[p_start..j]
                    .iter()
                    .collect::<String>()
                    .parse()
                    .unwrap_or(0),
            );
        }
        while chars
            .get(j)
            .is_some_and(|c| matches!(c, 'h' | 'l' | 'q' | 'L' | 'z' | 'j' | 't'))
        {
            j += 1;
        }
        let class = chars.get(j).and_then(|c| class_of(*c));
        match (chars.get(j), class) {
            (Some(&conversion), Some(class)) => {
                if !literal.is_empty() {
                    tokens.push(Token::Literal(std::mem::take(&mut literal)));
                }
                let position = position.unwrap_or_else(|| {
                    let p = next_position;
                    next_position += 1;
                    p
                });
                tokens.push(Token::Placeholder(Placeholder {
                    position,
                    class,
                    conversion,
                    left,
                    zero,
                    plus,
                    space,
                    width,
                    precision,
                    raw: chars[start..=j].iter().collect(),
                }));
                i = j + 1;
            }
            _ => {
                literal.push('%');
                i += 1;
            }
        }
    }
    if !literal.is_empty() {
        tokens.push(Token::Literal(literal));
    }
    tokens
}

/// All placeholders of a format string in order of appearance.
pub fn placeholders(text: &str) -> Vec<Placeholder> {
    parse(text)
        .into_iter()
        .filter_map(|t| match t {
            Token::Placeholder(p) => Some(p),
            Token::Literal(_) => None,
        })
        .collect()
}

/// The comparable shape of a format string: sorted `(position, class)` pairs. Two
/// translations of one key must have the same signature.
pub fn signature(text: &str) -> Vec<(usize, ArgClass)> {
    let mut sig: Vec<_> = placeholders(text)
        .iter()
        .map(|p| (p.position, p.class))
        .collect();
    sig.sort();
    sig
}

fn pad(body: String, p: &Placeholder, numeric: bool) -> String {
    let len = body.chars().count();
    if len >= p.width {
        return body;
    }
    let fill = p.width - len;
    if p.left {
        format!("{body}{}", " ".repeat(fill))
    } else if p.zero && numeric {
        let (sign, digits) = match body.strip_prefix(['-', '+', ' ']) {
            Some(rest) => (&body[..1], rest),
            None => ("", body.as_str()),
        };
        format!("{sign}{}{digits}", "0".repeat(fill))
    } else {
        format!("{}{body}", " ".repeat(fill))
    }
}

fn sign_prefix(negative: bool, p: &Placeholder) -> &'static str {
    if negative {
        "-"
    } else if p.plus {
        "+"
    } else if p.space {
        " "
    } else {
        ""
    }
}

fn render_one(p: &Placeholder, arg: &Arg) -> String {
    match p.class {
        ArgClass::Text => {
            let mut s = arg.display();
            if let Some(max) = p.precision {
                s = s.chars().take(max).collect();
            }
            pad(s, p, false)
        }
        ArgClass::Char => {
            let s = match arg {
                Arg::Str(s) => s.chars().next().map(String::from).unwrap_or_default(),
                other => other
                    .as_i128()
                    .and_then(|v| u32::try_from(v).ok())
                    .and_then(char::from_u32)
                    .map(String::from)
                    .unwrap_or_default(),
            };
            pad(s, p, false)
        }
        ArgClass::Integer => {
            let Some(v) = arg.as_i128() else {
                return pad(arg.display(), p, false);
            };
            let digits = match p.conversion {
                'x' => format!("{:x}", v as i64 as u64),
                'X' => format!("{:X}", v as i64 as u64),
                'o' | 'O' => format!("{:o}", v as i64 as u64),
                'p' => format!("0x{:x}", v as i64 as u64),
                'u' | 'U' => v.unsigned_abs().to_string(),
                _ => v.unsigned_abs().to_string(),
            };
            let signed = matches!(p.conversion, 'd' | 'D' | 'i');
            let sign = if signed { sign_prefix(v < 0, p) } else { "" };
            let digits = match p.precision {
                Some(min) if digits.len() < min => {
                    format!("{}{digits}", "0".repeat(min - digits.len()))
                }
                _ => digits,
            };
            pad(format!("{sign}{digits}"), p, true)
        }
        ArgClass::Float => {
            let Some(v) = arg.as_f64() else {
                return pad(arg.display(), p, false);
            };
            let prec = p.precision.unwrap_or(6);
            let body = match p.conversion {
                'e' => format!("{:.prec$e}", v.abs()),
                'E' => format!("{:.prec$E}", v.abs()),
                'g' | 'G' => {
                    // Shortest form, as %g trims trailing zeros.
                    let mut s = String::new();
                    let _ = write!(s, "{}", v.abs());
                    s
                }
                _ => format!("{:.prec$}", v.abs()),
            };
            pad(
                format!("{}{body}", sign_prefix(v.is_sign_negative() && v != 0.0, p)),
                p,
                true,
            )
        }
    }
}

/// Fills a format string. A placeholder whose argument is missing stays as written, so
/// a wrong call is visible instead of silently dropping text. `%%` becomes `%`.
pub fn render(text: &str, args: &[Arg]) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    for token in parse(text) {
        match token {
            Token::Literal(l) => out.push_str(&l),
            Token::Placeholder(p) => match args.get(p.position - 1) {
                Some(arg) => out.push_str(&render_one(&p, arg)),
                None => out.push_str(&p.raw),
            },
        }
    }
    out
}

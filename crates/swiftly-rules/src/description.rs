//! Port of Description.swift: server descriptions made readable (`Description.readable`),
//! `Item.description`, `Item.daysDate`, `Item.tmdbId`.
//!
//! Jellyfin passes the overview through as stored; for series from some sources it contains markup
//! (`<br>`, `<p>`, `<i>`, `&amp;`, `&#39;`). Line breaks and paragraphs become text, the rest of
//! the tags are dropped. The Swift file does this with five `NSRegularExpression` replacements;
//! the matchers here are written by hand (no regex dependency) and follow the same greedy,
//! left-to-right, non-overlapping semantics. Checked against the real Swift function by the
//! `description` oracle domain.
use crate::text::{is_cf_newline, is_cf_whitespace};
use unicode_normalization::char::canonical_combining_class;
use unicode_segmentation::UnicodeSegmentation;

/// ICU `\s` is the White_Space property (measured: it includes U+000B and U+0085).
fn icu_space(c: char) -> bool {
    c.is_whitespace()
}

/// Foundation's non-literal `replacingOccurrences(of:with:)` only accepts a match that does not
/// end inside a composed character sequence: a literal followed by a combining mark (or a joiner,
/// or an emoji skin tone) stays as it is (measured: "&lt;\u{301}", "\r\n\u{301}").
fn attaches(c: char) -> bool {
    canonical_combining_class(c) != 0
        || matches!(c, '\u{034F}' | '\u{0488}'..='\u{0489}' | '\u{200C}' | '\u{20D0}'..='\u{20FF}' | '\u{FE00}'..='\u{FE0F}' | '\u{E0100}'..='\u{E01EF}' | '\u{1F3FB}'..='\u{1F3FF}')
}

fn replace_literal(text: &str, pattern: &str, with: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(pattern) {
        let end = at + pattern.len();
        out.push_str(&rest[..at]);
        if rest[end..].chars().next().is_some_and(attaches) {
            // Not a match: keep the first character and look on after it.
            let first = rest[at..].chars().next().map_or(1, char::len_utf8);
            out.push_str(&rest[at..at + first]);
            rest = &rest[at + first..];
        } else {
            out.push_str(with);
            rest = &rest[end..];
        }
    }
    out.push_str(rest);
    out
}

fn eq_ascii(c: char, lower: char) -> bool {
    c.to_ascii_lowercase() == lower
}

/// Matches `lit` (lower case ASCII) case-insensitively at `i`; returns the index after it.
fn lit_ci(s: &[char], i: usize, lit: &str) -> Option<usize> {
    let mut j = i;
    for l in lit.chars() {
        if j < s.len() && eq_ascii(s[j], l) {
            j += 1;
        } else {
            return None;
        }
    }
    Some(j)
}

fn skip_space(s: &[char], mut i: usize) -> usize {
    while i < s.len() && icu_space(s[i]) {
        i += 1;
    }
    i
}

/// `(?i)<br\s*/?>`
fn match_br(s: &[char], i: usize) -> Option<usize> {
    if s.get(i) != Some(&'<') {
        return None;
    }
    let mut j = lit_ci(s, i + 1, "br")?;
    j = skip_space(s, j);
    if s.get(j) == Some(&'/') {
        j += 1;
    }
    (s.get(j) == Some(&'>')).then_some(j + 1)
}

/// `(?i)</(p|div|h[1-6])\s*>`
fn match_close_block(s: &[char], i: usize) -> Option<usize> {
    if s.get(i) != Some(&'<') || s.get(i + 1) != Some(&'/') {
        return None;
    }
    let j = i + 2;
    let after = if let Some(k) = lit_ci(s, j, "div") {
        k
    } else if let Some(k) = lit_ci(s, j, "p") {
        k
    } else {
        let k = lit_ci(s, j, "h")?;
        match s.get(k) {
            Some('1'..='6') => k + 1,
            _ => return None,
        }
    };
    let j = skip_space(s, after);
    (s.get(j) == Some(&'>')).then_some(j + 1)
}

/// `(?i)<li[^<>]*>`
fn match_li(s: &[char], i: usize) -> Option<usize> {
    if s.get(i) != Some(&'<') {
        return None;
    }
    let mut j = lit_ci(s, i + 1, "li")?;
    while j < s.len() && s[j] != '<' && s[j] != '>' {
        j += 1;
    }
    (s.get(j) == Some(&'>')).then_some(j + 1)
}

/// `</?[A-Za-z][^<>]*>`
fn match_tag(s: &[char], i: usize) -> Option<usize> {
    if s.get(i) != Some(&'<') {
        return None;
    }
    let mut j = i + 1;
    if s.get(j) == Some(&'/') {
        j += 1;
    }
    if !s.get(j).is_some_and(char::is_ascii_alphabetic) {
        return None;
    }
    j += 1;
    while j < s.len() && s[j] != '<' && s[j] != '>' {
        j += 1;
    }
    (s.get(j) == Some(&'>')).then_some(j + 1)
}

/// Global, left-to-right, non-overlapping replacement with a hand-written matcher.
fn replace_all(text: &str, matcher: fn(&[char], usize) -> Option<usize>, with: &str) -> String {
    let s: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < s.len() {
        match matcher(&s, i) {
            Some(end) if end > i => {
                out.push_str(with);
                i = end;
            }
            _ => {
                out.push(s[i]);
                i += 1;
            }
        }
    }
    out
}

/// `[ \t]+\n` -> `\n`
fn strip_trailing_blanks(text: &str) -> String {
    let s: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == ' ' || s[i] == '\t' {
            let mut j = i;
            while j < s.len() && (s[j] == ' ' || s[j] == '\t') {
                j += 1;
            }
            if s.get(j) == Some(&'\n') {
                out.push('\n');
                i = j + 1;
            } else {
                out.extend(&s[i..j]);
                i = j;
            }
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    out
}

/// `\n{3,}` -> `\n\n`
fn squeeze_blank_lines(text: &str) -> String {
    let s: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == '\n' {
            let mut j = i;
            while j < s.len() && s[j] == '\n' {
                j += 1;
            }
            if j - i >= 3 {
                out.push_str("\n\n");
            } else {
                out.extend(&s[i..j]);
            }
            i = j;
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    out
}

/// `&#(x?)([0-9A-Fa-f]{1,6});`: a value that is no scalar (surrogates, above U+10FFFF, or a
/// decimal number with hex letters) keeps its text.
fn numeric_entities(text: &str) -> String {
    let s: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == '&' && s.get(i + 1) == Some(&'#') {
            let mut j = i + 2;
            let hex = s.get(j) == Some(&'x');
            if hex {
                j += 1;
            }
            let start = j;
            while j < s.len() && j - start < 6 && s[j].is_ascii_hexdigit() {
                j += 1;
            }
            if j > start && s.get(j) == Some(&';') {
                let digits: String = s[start..j].iter().collect();
                let value = u32::from_str_radix(&digits, if hex { 16 } else { 10 })
                    .ok()
                    .and_then(char::from_u32);
                match value {
                    Some(ch) => out.push(ch),
                    None => out.extend(&s[i..=j]),
                }
                i = j + 1;
                continue;
            }
        }
        out.push(s[i]);
        i += 1;
    }
    out
}

/// `&amp;` last: otherwise `&amp;lt;` would be decoded twice.
fn character_resolve(text: &str) -> String {
    let mut s = text.to_owned();
    for (mark, symbol) in [
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&#39;", "'"),
        ("&nbsp;", " "),
    ] {
        s = replace_literal(&s, mark, symbol);
    }
    s = numeric_entities(&s);
    replace_literal(&s, "&amp;", "&")
}

/// `Description.readable`.
pub fn readable(raw: &str) -> String {
    let mut s = replace_literal(raw, "\r\n", "\n");
    s = replace_all(&s, match_br, "\n");
    s = replace_all(&s, match_close_block, "\n\n");
    s = replace_all(&s, match_li, "\n• ");
    s = replace_all(&s, match_tag, "");
    s = character_resolve(&s);
    for blank in ['\u{00A0}', '\u{202F}', '\u{2007}'] {
        s = replace_literal(&s, &blank.to_string(), " ");
    }
    s = strip_trailing_blanks(&s);
    s = squeeze_blank_lines(&s);
    // U+FEFF is not whitespace for Swift's `.whitespacesAndNewlines` (measured), unlike `is_cf_whitespace`.
    s.trim_matches(|c| c != '\u{FEFF}' && (is_cf_whitespace(c) || is_cf_newline(c)))
        .to_owned()
}

/// `Item.description`: `None` if nothing is left after cleaning (or there is no overview).
pub fn description(overview: Option<&str>) -> Option<String> {
    let text = readable(overview?);
    (!text.is_empty()).then_some(text)
}

/// Swift `Int(String)`: optional sign and ASCII digits, nothing else; overflow gives `None`.
fn swift_int(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// `Item.daysDate`: `(year, month, day)` from the first ten characters of `PremiereDate`,
/// without any validation of the ranges (as in Swift). Counts and cuts by characters
/// (grapheme clusters), like Swift's `String`.
pub fn days_date(premiere: Option<&str>) -> Option<(i64, i64, i64)> {
    let raw = premiere?;
    let graphemes: Vec<&str> = raw.graphemes(true).collect();
    if graphemes.len() < 10 {
        return None;
    }
    let mut parts: Vec<i64> = Vec::new();
    let mut field = String::new();
    let flush = |field: &mut String, parts: &mut Vec<i64>| {
        if !field.is_empty() {
            if let Some(n) = swift_int(field) {
                parts.push(n);
            }
            field.clear();
        }
    };
    for g in &graphemes[..10] {
        if *g == "-" {
            flush(&mut field, &mut parts);
        } else {
            field.push_str(g);
        }
    }
    flush(&mut field, &mut parts);
    (parts.len() == 3).then(|| (parts[0], parts[1], parts[2]))
}

/// `Item.tmdbId`: the `Tmdb` provider id as a number.
pub fn tmdb_id(tmdb: Option<&str>) -> Option<i64> {
    swift_int(tmdb?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn breaks_paragraphs_and_lists() {
        assert_eq!(readable("a<br>b<BR \t/>c"), "a\nb\nc");
        assert_eq!(readable("<p>one</p><p>two</p>"), "one\n\ntwo");
        assert_eq!(
            readable("<ul><li>x</li><LI class=a>y</li></ul>"),
            "• x\n• y"
        );
    }

    #[test]
    fn only_real_tags_go() {
        assert_eq!(readable("5 < 6 and 7 > 3"), "5 < 6 and 7 > 3");
        assert_eq!(readable("<i>x</i> <3"), "x <3");
    }

    #[test]
    fn entities_resolve_once() {
        assert_eq!(readable("a &amp;lt; b &lt; c"), "a &lt; b < c");
        assert_eq!(readable("&#8211;&#x2013;&#39;&nbsp;"), "\u{2013}\u{2013}'");
        assert_eq!(
            readable("&#xD800;&#1a;&#x110000;"),
            "&#xD800;&#1a;&#x110000;"
        );
    }

    #[test]
    fn blanks_and_blank_lines() {
        assert_eq!(readable("a \t \n\n\n\n b\u{00A0}c  "), "a\n\n b c");
        assert_eq!(description(Some("<br>")), None);
        assert_eq!(description(None), None);
    }

    #[test]
    fn days_and_tmdb() {
        assert_eq!(
            days_date(Some("2020-05-17T00:00:00.0000000Z")),
            Some((2020, 5, 17))
        );
        assert_eq!(days_date(Some("2020-05-1")), None);
        assert_eq!(days_date(Some("2020-ab-17x")), None);
        assert_eq!(tmdb_id(Some("+603")), Some(603));
        assert_eq!(tmdb_id(Some("6 03")), None);
    }
}

//! Byte counts in words (`DownloadRules.size`, `sizeLocale`).
//!
//! Swift uses `ByteCountFormatStyle(.file)`: thousands steps (not powers of two), like Finder and
//! the iOS settings. The decimal separator is the only locale-dependent part here; unit names
//! stay Latin. Foundation's exact digit rules are approximated: at most three significant digits
//! (two decimals under 10, one under 100, none from 100), none for bytes and KB, trailing zeros
//! dropped.

/// The locale used for the *size* text: "18,6 GB", not "18,6 ГБ". Russian, Ukrainian and
/// Belarusian use German formatting (same decimal comma, Latin units); every other locale stays.
pub fn size_locale(identifier: &str) -> String {
    let prefix: String = identifier.chars().take(2).collect();
    if ["ru", "uk", "be"].contains(&prefix.as_str()) {
        "de_DE".to_owned()
    } else {
        identifier.to_owned()
    }
}

/// "18,6 GB" with `decimal_separator` "," or "18.6 GB" with ".".
pub fn size(bytes: i64, decimal_separator: &str) -> String {
    let bytes = bytes.max(0);
    if bytes < 1000 {
        return format!("{bytes} bytes");
    }
    const UNITS: [&str; 6] = ["kB", "MB", "GB", "TB", "PB", "EB"];
    let mut value = bytes as f64 / 1000.0;
    let mut unit = 0;
    while value >= 999.5 && unit + 1 < UNITS.len() {
        value /= 1000.0;
        unit += 1;
    }
    let decimals = if unit == 0 {
        0
    } else if value < 9.995 {
        2
    } else if value < 99.95 {
        1
    } else {
        0
    };
    format!(
        "{} {}",
        trimmed(value, decimals, decimal_separator),
        UNITS[unit]
    )
}

/// `value` with `decimals` fraction digits, trailing zeros dropped.
fn trimmed(value: f64, decimals: usize, separator: &str) -> String {
    let text = format!("{value:.decimals$}");
    let text = if text.contains('.') {
        text.trim_end_matches('0').trim_end_matches('.').to_owned()
    } else {
        text
    };
    text.replace('.', separator)
}

/// Round the shortest decimal text of `value` to `decimals` digits, ties to even (what the
/// Foundation number formatter does: 0.005 gives "0.00", 0.015 gives "0.02").
fn round_half_even(value: f64, decimals: usize) -> String {
    let text = format!("{value}");
    let (whole, fraction) = text.split_once('.').unwrap_or((text.as_str(), ""));
    if fraction.len() <= decimals {
        return format!("{whole}.{fraction:0<decimals$}")
            .trim_end_matches('.')
            .to_owned();
    }
    let mut digits: Vec<u8> = whole
        .bytes()
        .chain(fraction.bytes().take(decimals))
        .collect();
    let rest = &fraction.as_bytes()[decimals..];
    let last_odd = digits.last().is_some_and(|d| (d - b'0') % 2 == 1);
    let up = match rest[0] {
        b'6'..=b'9' => true,
        b'5' => rest[1..].iter().any(|d| *d != b'0') || last_odd,
        _ => false,
    };
    if up {
        let mut i = digits.len();
        loop {
            if i == 0 {
                digits.insert(0, b'1');
                break;
            }
            i -= 1;
            if digits[i] == b'9' {
                digits[i] = b'0';
            } else {
                digits[i] += 1;
                break;
            }
        }
    }
    let split = digits.len() - decimals;
    let (w, f) = digits.split_at(split);
    let (w, f) = (String::from_utf8_lossy(w), String::from_utf8_lossy(f));
    if decimals == 0 {
        w.into_owned()
    } else {
        format!("{w}.{f}")
    }
}

/// A fixed number of fraction digits (no trimming), with the given separator: used by the
/// progress text, where both numbers keep their width.
pub fn fixed(value: f64, decimals: usize, separator: &str) -> String {
    // Swift's `.number` groups thousands with the sign the decimal separator does not use
    // (found by the downloads oracle: a loaded figure past 999 read "50000000" instead of
    // "50.000.000").
    let plain = round_half_even(value, decimals);
    let (whole, fraction) = plain
        .split_once('.')
        .map_or((plain.as_str(), None), |(w, f)| (w, Some(f)));
    let group = if separator == "," { "." } else { "," };
    let mut grouped = String::new();
    for (i, digit) in whole.chars().enumerate() {
        if i > 0 && (whole.len() - i) % 3 == 0 && digit.is_ascii_digit() {
            grouped.push_str(group);
        }
        grouped.push(digit);
    }
    match fraction {
        Some(f) => format!("{grouped}{separator}{f}"),
        None => grouped,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn size_in_gb() {
        // 18.6 GB in steps of a thousand, not 17.3 GiB.
        let text = size(18_600_000_000, ".");
        assert!(text.contains("18"));
        assert!(text.to_uppercase().contains("GB"));
        assert_eq!(text, "18.6 GB");
        assert_eq!(size(845_000_000, ","), "845 MB");
        assert_eq!(size(1_100_000_000, ","), "1,1 GB");
        assert_eq!(size(1_000_000_000, ","), "1 GB");
    }

    #[test]
    fn russian_keeps_latin_unit_and_comma() {
        assert_eq!(size_locale("ru_RU"), "de_DE");
        assert_eq!(size_locale("uk"), "de_DE");
        assert_eq!(size_locale("en_US"), "en_US");
        let text = size(18_600_000_000, ",");
        assert!(text.contains("18,6"));
        assert!(text.contains("GB"));
    }
}

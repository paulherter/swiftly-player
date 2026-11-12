//! Port of WholeNumber.swift (`Int(capped:)`), the helper several rules use.

/// `Int(capped: value)`: NaN becomes 0, out-of-range values clamp, otherwise truncation
/// toward zero. Swift's `Int` is 64-bit, so the result is `i64`.
///
/// Swift: `WholeNumber.swift:12-17`. (`Double(Int.max)` is 2^63, so `>=` also catches the
/// value just below the clamp; Rust's saturating `as` gives the same results.)
pub fn capped(value: f64) -> i64 {
    if value.is_nan() {
        0
    } else if value >= i64::MAX as f64 {
        i64::MAX
    } else if value <= i64::MIN as f64 {
        i64::MIN
    } else {
        value as i64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_and_truncates() {
        assert_eq!(capped(f64::NAN), 0);
        assert_eq!(capped(f64::INFINITY), i64::MAX);
        assert_eq!(capped(f64::NEG_INFINITY), i64::MIN);
        assert_eq!(capped(-2.9), -2);
        assert_eq!(capped(2.9), 2);
    }
}

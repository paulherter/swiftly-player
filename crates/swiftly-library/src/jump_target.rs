//! `JumpTarget` (Swift `JumpTarget.swift`): a position that converts to whole milliseconds safely.

/// Roughly eleven days; the limit only exists so the conversion to milliseconds never
/// overflows (:15).
pub const UPPER_LIMIT: f64 = 1_000_000.0;

/// The value between zero and [`UPPER_LIMIT`], or `None` if it is not a finite number (:17-20).
pub fn seconds(value: f64) -> Option<f64> {
    value.is_finite().then(|| value.clamp(0.0, UPPER_LIMIT))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_number_is_no_target() {
        assert_eq!(seconds(f64::NAN), None);
        assert_eq!(seconds(f64::INFINITY), None);
        assert_eq!(seconds(f64::NEG_INFINITY), None);
    }
    #[test]
    fn becomes_limited() {
        assert_eq!(seconds(-3.0), Some(0.0));
        assert_eq!(seconds(125.5), Some(125.5));
        assert_eq!(seconds(1e300), Some(UPPER_LIMIT));
    }
    #[test]
    fn milliseconds_never_overflow() {
        let ms = (seconds(f64::MAX).unwrap_or(0.0) * 1000.0) as i64;
        assert_eq!(i32::try_from(ms).unwrap_or(i32::MAX), 1_000_000_000);
    }
}

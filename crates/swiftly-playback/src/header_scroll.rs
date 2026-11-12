//! Port of `HeaderScrollDistance.swift` (JellyfinKit): how far the finger has pulled a list
//! under a collapsing header.
//!
//! The sum of inset and raw offset is the scroll distance. Measured: inset 130.8 with
//! offset -130.3 gives 0.5; inset 115.0 with offset -114.7 gives 0.3. An intermediate state
//! (offset zero reported once with the inset already set) is skipped, otherwise the whole
//! header height would be computed and the row would collapse and reopen for a frame.

/// The distance, or `None` if the report is the intermediate state.
pub fn distance(margin: f64, offset: f64) -> Option<f64> {
    if offset.abs() < 1.0 && margin > 1.0 {
        return None;
    }
    Some(offset + margin)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Values taken from measurements.
    #[test]
    fn sum_is_distance() {
        assert!((distance(130.8, -130.3).unwrap_or(f64::NAN) - 0.5).abs() < 0.001);
        assert!((distance(115.0, -114.7).unwrap_or(f64::NAN) - 0.3).abs() < 0.001);
        assert_eq!(distance(115.0, 85.0), Some(200.0));
    }

    #[test]
    fn intermediate_is_skipped() {
        assert_eq!(distance(130.8, 0.0), None);
        assert_eq!(distance(130.8, 0.4), None);
    }

    #[test]
    fn without_edge_counts_as_null() {
        assert_eq!(distance(0.0, 0.0), Some(0.0));
    }
}

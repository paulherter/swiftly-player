//! Port of NotchesSnap.swift.
//!
//! While scrubbing, the slider snaps to section boundaries, measured in points, not seconds.

/// How close the finger must be to the notch, in points.
pub const SNAP_RANGE: f64 = 8.0;

/// The notch the slider should rest on, or `None` if none is close enough; with two, the
/// nearer one (the first of equals). `value` is the position under the finger in seconds,
/// `until` the runtime, `marks` the section boundaries, `width` the bar width in points.
/// (`NotchesSnap.swift:19-29`)
pub fn notch(value: f64, until: f64, marks: &[f64], width: f64) -> Option<f64> {
    if !(until > 0.0 && width > 0.0 && value.is_finite()) {
        return None;
    }
    let per_point = until / width;
    let range = SNAP_RANGE * per_point;
    marks
        .iter()
        .copied()
        .filter(|m| *m > 0.0 && *m < until)
        .map(|m| (m, (m - value).abs()))
        .filter(|(_, distance)| *distance <= range)
        // `Iterator::min_by` returns the first minimum, like Swift's `min(by:)`.
        .min_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
        .map(|(m, _)| m)
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2700 s on 270 points: one point is ten seconds, the snap range 80 s.
    #[test]
    fn close_enough_snaps() {
        assert_eq!(notch(150.0, 2700.0, &[90.0, 2500.0], 270.0), Some(90.0));
    }

    #[test]
    fn wide_distance_stays_free() {
        assert_eq!(notch(400.0, 2700.0, &[90.0, 2500.0], 270.0), None);
    }

    #[test]
    fn closer_one_wins() {
        assert_eq!(notch(100.0, 2700.0, &[60.0, 110.0], 270.0), Some(110.0));
    }

    #[test]
    fn edges_count_not() {
        assert_eq!(notch(5.0, 2700.0, &[0.0, 2700.0], 270.0), None);
    }

    #[test]
    fn without_width_no_snap() {
        assert_eq!(notch(90.0, 2700.0, &[90.0], 0.0), None);
    }
}

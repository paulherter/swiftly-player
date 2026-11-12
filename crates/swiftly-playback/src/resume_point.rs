//! Port of `ResumePoint.swift` and `JumpTarget.swift` (JellyfinKit).
//!
//! Section 1: from which second playback resumes, or not at all. Section 2: a jump target
//! that can safely be converted to whole milliseconds.

// ---------------------------------------------------------------------------
// ResumePoint.swift
// ---------------------------------------------------------------------------

/// Below this resuming is not worth it; someone who watched half a minute wants to start
/// over (ResumePoint.swift:21).
pub const AT_LEAST: f64 = 60.0;

/// Within this distance of the end the title counts as watched. Deliberately a fixed
/// distance, not a fraction (ResumePoint.swift:28).
pub const END_SPACING: f64 = 60.0;

/// The second to resume at, or `None` for "from the start" (ResumePoint.swift:36).
///
/// `position` is the remembered position in seconds. `runtime` is the runtime in seconds,
/// or `None` if the server gives none; without a runtime only the lower bound applies.
/// A runtime of zero or less counts as absent.
pub fn since(position: Option<f64>, runtime: Option<f64>) -> Option<f64> {
    let position = position.filter(|p| *p > AT_LEAST)?;
    if let Some(runtime) = runtime
        && runtime > 0.0
        && position >= runtime - END_SPACING
    {
        return None;
    }
    Some(position)
}

// ---------------------------------------------------------------------------
// JumpTarget.swift
// ---------------------------------------------------------------------------

/// Roughly eleven days. No title is that long; the limit only exists so the conversion to
/// milliseconds never overflows (JumpTarget.swift:15).
pub const UPPER_LIMIT: f64 = 1_000_000.0;

/// The value between zero and [`UPPER_LIMIT`], or `None` if it is not a number
/// (JumpTarget.swift:18).
pub fn seconds(value: f64) -> Option<f64> {
    if !value.is_finite() {
        return None;
    }
    Some(value.clamp(0.0, UPPER_LIMIT))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ResumePointTests.swift

    #[test]
    fn under_minute_from_front() {
        assert_eq!(since(Some(30.0), Some(3600.0)), None);
        assert_eq!(since(Some(60.0), Some(3600.0)), None);
        assert_eq!(since(Some(61.0), Some(3600.0)), Some(61.0));
    }

    /// The case: episode played through, the end remembered.
    #[test]
    fn at_end_from_front() {
        assert_eq!(since(Some(3707.0), Some(3707.0)), None);
        assert_eq!(since(Some(3660.0), Some(3707.0)), None);
        assert_eq!(since(Some(3646.0), Some(3707.0)), Some(3646.0));
    }

    #[test]
    fn over_runtime_to_out() {
        assert_eq!(since(Some(4000.0), Some(3707.0)), None);
    }

    /// Without a runtime only the lower bound remains.
    #[test]
    fn without_runtime_only_under_limit() {
        assert_eq!(since(Some(3707.0), None), Some(3707.0));
        assert_eq!(since(Some(30.0), None), None);
        assert_eq!(since(Some(3707.0), Some(0.0)), Some(3707.0));
    }

    #[test]
    fn without_position_not() {
        assert_eq!(since(None, Some(3600.0)), None);
    }

    // JumpTargetTests.swift

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
    fn milliseconds_over_run_never() {
        // Exactly the conversion the player does afterwards.
        let secs = seconds(f64::MAX).unwrap_or(0.0);
        let ms = (secs * 1000.0) as i64;
        let clamped = ms.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32;
        assert_eq!(clamped, 1_000_000_000);
    }
}

//! `Refresh` (Swift `Refresh.swift:36,43`): when the home page has to reload its rows.
//! Time is plain `f64` seconds on any consistent clock (Swift `Date`).

/// How long the rows count as fresh after loading, in seconds (:36).
pub const DEADLINE: f64 = 30.0;

/// Is a reload due because the app returns to the foreground? `recent` is when last loaded,
/// `None` if never (:43-47).
pub fn due_return(recent: Option<f64>, now: f64) -> bool {
    due_return_with(recent, now, DEADLINE)
}

/// As [`due_return`] with an own deadline.
pub fn due_return_with(recent: Option<f64>, now: f64, deadline: f64) -> bool {
    match recent {
        None => true,
        Some(r) => now - r >= deadline,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: f64 = 1_000_000.0;

    #[test]
    fn never_loaded() {
        assert!(due_return(None, NOW));
    }
    #[test]
    fn short_distance() {
        assert!(!due_return(Some(NOW - 5.0), NOW));
    }
    #[test]
    fn exactly_on_the_edge() {
        assert!(due_return(Some(NOW - DEADLINE), NOW));
    }
    #[test]
    fn device_switch() {
        assert!(due_return(Some(NOW - 90.0), NOW));
    }
    #[test]
    fn own_deadline() {
        assert!(!due_return_with(Some(NOW - 60.0), NOW, 120.0));
        assert!(due_return_with(Some(NOW - 60.0), NOW, 10.0));
    }
}

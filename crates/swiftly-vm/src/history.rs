//! Back/forward history behind the two arrows and Ctrl+[ / Ctrl+] (`NavArrows.swift`).
//!
//! `P` is a place (section, page stack, subpage); the host decides what it holds and compares
//! places with `==`. The struct only keeps the two lists and the pending target.

/// How the last move came about (`Push`): a back move feeds the forward list, a deeper move
/// clears it, and `Without` is not recorded at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bearing {
    /// Not a user move (redraws, reloads).
    Without,
    /// Back to an earlier place.
    Back,
    /// Deeper or sideways: a new place.
    Deeper,
}

/// The history of places.
#[derive(Debug, Clone, PartialEq)]
pub struct NavHistory<P: PartialEq + Clone> {
    history: Vec<P>,
    future: Vec<P>,
    now: Option<P>,
    pending: Option<P>,
}

impl<P: PartialEq + Clone> Default for NavHistory<P> {
    fn default() -> Self {
        Self {
            history: Vec::new(),
            future: Vec::new(),
            now: None,
            pending: None,
        }
    }
}

impl<P: PartialEq + Clone> NavHistory<P> {
    /// An empty history.
    pub fn new() -> Self {
        Self::default()
    }

    /// Notes a move to `now` (`navNote`). `start` is the place assumed before the first move.
    pub fn note(&mut self, bearing: Bearing, now: &P, start: &P) {
        if bearing == Bearing::Without {
            return;
        }
        let old = self.now.clone().unwrap_or_else(|| start.clone());
        if let Some(wanted) = &self.pending {
            // A restore is under way: its arrival is not a new place.
            if wanted == now {
                self.pending = None;
                self.now = Some(now.clone());
            }
            return;
        }
        if *now == old {
            return;
        }
        if bearing == Bearing::Back {
            self.future.push(old);
            while self.history.last() == Some(now) {
                self.history.pop();
            }
        } else {
            self.history.push(old);
            self.future.clear();
        }
        self.now = Some(now.clone());
    }

    /// Is there an earlier place that differs from `now` (`navCanBack`)?
    pub fn can_back(&self, now: &P) -> bool {
        self.history.iter().any(|p| p != now)
    }

    /// Is there a later place that differs from `now` (`navCanForward`)?
    pub fn can_forward(&self, now: &P) -> bool {
        self.future.iter().any(|p| p != now)
    }

    /// One step back (`navBackStep`): the place to restore, or `None`. Places equal to `now`
    /// are skipped. The host restores it, then calls [`Self::restored`].
    pub fn back_step(&mut self, now: &P) -> Option<P> {
        while let Some(place) = self.history.pop() {
            if place == *now {
                continue;
            }
            self.future.push(now.clone());
            self.pending = Some(place.clone());
            return Some(place);
        }
        None
    }

    /// One step forward (`navForwardStep`).
    pub fn forward_step(&mut self, now: &P) -> Option<P> {
        while let Some(place) = self.future.pop() {
            if place == *now {
                continue;
            }
            self.history.push(now.clone());
            self.pending = Some(place.clone());
            return Some(place);
        }
        None
    }

    /// The host is at `place` after a restore (`navRestore`'s last line): no further move will
    /// announce it.
    pub fn restored(&mut self, place: &P, now: &P) {
        if now == place {
            self.now = Some(place.clone());
            self.pending = None;
        }
    }

    /// Forgets everything (`navReset`).
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// The restore target still waiting for its arrival.
    pub fn pending(&self) -> Option<&P> {
        self.pending.as_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Bearing::*;

    fn go(h: &mut NavHistory<&'static str>, bearing: Bearing, to: &'static str) {
        h.note(bearing, &to, &"start");
    }

    #[test]
    fn deeper_moves_build_the_history_and_clear_the_future() {
        let mut h = NavHistory::new();
        go(&mut h, Deeper, "A");
        go(&mut h, Deeper, "B");
        assert!(h.can_back(&"B") && !h.can_forward(&"B"));
        let place = h.back_step(&"B");
        assert_eq!(place, Some("A"));
        h.restored(&"A", &"A");
        assert!(h.can_forward(&"A"));
        go(&mut h, Deeper, "C");
        assert!(!h.can_forward(&"C"), "a new place drops the future");
    }

    #[test]
    fn back_then_forward_walks_the_same_places() {
        let mut h = NavHistory::new();
        for p in ["A", "B", "C"] {
            go(&mut h, Deeper, p);
        }
        assert_eq!(h.back_step(&"C"), Some("B"));
        h.restored(&"B", &"B");
        assert_eq!(h.back_step(&"B"), Some("A"));
        h.restored(&"A", &"A");
        assert_eq!(h.forward_step(&"A"), Some("B"));
        h.restored(&"B", &"B");
        assert_eq!(h.forward_step(&"B"), Some("C"));
        assert_eq!(h.forward_step(&"C"), None);
    }

    #[test]
    fn places_equal_to_the_current_one_are_skipped() {
        let mut h = NavHistory::new();
        go(&mut h, Deeper, "A");
        go(&mut h, Deeper, "B");
        h.history.push("B");
        assert_eq!(h.back_step(&"B"), Some("A"));
    }

    #[test]
    fn the_arrival_of_a_restore_is_not_a_new_place() {
        let mut h = NavHistory::new();
        go(&mut h, Deeper, "A");
        go(&mut h, Deeper, "B");
        let before = h.clone();
        assert_eq!(h.back_step(&"B"), Some("A"));
        go(&mut h, Back, "A");
        assert!(h.pending().is_none());
        assert_eq!(h.history, before.history[..before.history.len() - 1]);
    }

    #[test]
    fn moves_without_bearing_and_empty_history_do_nothing() {
        let mut h: NavHistory<&str> = NavHistory::new();
        go(&mut h, Without, "A");
        assert!(!h.can_back(&"A"));
        assert_eq!(h.back_step(&"A"), None);
        assert_eq!(h.forward_step(&"A"), None);
        go(&mut h, Deeper, "A");
        h.reset();
        assert_eq!(h, NavHistory::new());
    }
}

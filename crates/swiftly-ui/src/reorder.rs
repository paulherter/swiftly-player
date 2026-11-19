//! Reordering a vertical list of equal-height rows by dragging one (the iPhone list reorder).
//!
//! The list is one `zstack` of keyed rows, each at the offset `slot * pitch`. While a row is held it follows the pointer
//! 1:1 (an instant offset), the others make room with the catalogue spring `RowReorder`, and on release the row settles
//! into its slot with the same spring. The order itself is written by the screen (one core call) when the row is let go;
//! until the spring has rested the rows keep their old slots, so nothing jumps when the new order arrives.
//!
//! [`Reorder`] is the whole state machine (idle, dragging, settling); the maths are plain functions so they are tested
//! without a screen. A screen feeds it the pan events of the rows (`Node::on_pan`) and asks [`Reorder::placement`] for
//! the offset of every row.

use crate::anim::Motion;
use crate::ui::Phase;
use swiftly_motion::catalogue::Id;

/// Milliseconds a released row takes to settle before the new order is shown (the spring rests well inside it).
pub const SETTLE_MS: f64 = 450.0;
/// Scale of the lifted row.
pub const LIFT_SCALE: f32 = 1.02;

/// The motion of rows that make room, of the settling row and of the lift.
pub fn spring() -> Motion {
    Motion::of(Id::RowReorder)
}

/// How far the held row may travel from slot `from` (`ty` is the pointer's vertical movement): it stays inside the list.
pub fn clamp_travel(from: usize, ty: f32, pitch: f32, n: usize) -> f32 {
    let up = -(from as f32) * pitch;
    let down = n.saturating_sub(1).saturating_sub(from) as f32 * pitch;
    ty.clamp(up, down.max(up))
}

/// The slot the held row would drop into: its centre is nearest to that slot's centre.
pub fn target_slot(from: usize, ty: f32, pitch: f32, n: usize) -> usize {
    if n == 0 || pitch <= 0.0 {
        return from;
    }
    let slots = from as f32 + clamp_travel(from, ty, pitch, n) / pitch;
    (slots.round().max(0.0) as usize).min(n - 1)
}

/// How many slots row `i` moves when the held row `from` is over slot `to`: the rows between make room.
pub fn shift_slots(i: usize, from: usize, to: usize) -> i32 {
    if i == from {
        0
    } else if from < to && i > from && i <= to {
        -1
    } else if to < from && i >= to && i < from {
        1
    } else {
        0
    }
}

/// The order of `n` rows after moving row `from` to slot `to`: `result[slot]` is the old index.
pub fn moved_order(n: usize, from: usize, to: usize) -> Vec<usize> {
    let mut order: Vec<usize> = (0..n).collect();
    if from < n && to < n {
        let r = order.remove(from);
        order.insert(to, r);
    }
    order
}

/// Where one row stands relative to its list slot.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Placement {
    /// Offset in points below the slot's own place.
    pub dy: f32,
    /// The row is held or settling: drawn on top.
    pub on_top: bool,
    /// The lifted look (scale, shadow): while it is held.
    pub lifted: bool,
    /// The offset follows the pointer at once (no spring).
    pub live: bool,
}

impl Placement {
    /// The motion to give the offset.
    pub fn motion(&self) -> Motion {
        if self.live { Motion::Instant } else { spring() }
    }
}

/// The state of a reorder.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum Reorder {
    /// Nothing is held.
    #[default]
    Idle,
    /// Row `from` is held and has moved `ty` points.
    Dragging {
        /// The slot it was picked up from.
        from: usize,
        /// The pointer's vertical movement since the press.
        ty: f32,
    },
    /// Row `from` was let go over slot `to` and settles until `until` (ms).
    Settling {
        /// The slot it was picked up from.
        from: usize,
        /// The slot it lands in.
        to: usize,
        /// When the settle ends.
        until: f64,
    },
}

impl Reorder {
    /// Feeds one pan event of row `row` (of `n`, `pitch` points apart) at `now` ms. Returns `(from, to)` when the row
    /// was let go over another slot: the screen writes that order now (the rows keep their slots until [`Reorder::tick`]
    /// says the settle is over).
    pub fn pan(
        &mut self,
        row: usize,
        phase: Phase,
        ty: f32,
        pitch: f32,
        n: usize,
        now: f64,
    ) -> Option<(usize, usize)> {
        match (*self, phase) {
            (Reorder::Idle, Phase::Began) if row < n => {
                *self = Reorder::Dragging {
                    from: row,
                    ty: clamp_travel(row, ty, pitch, n),
                };
                None
            }
            (Reorder::Dragging { from, .. }, Phase::Changed | Phase::Began) if from == row => {
                *self = Reorder::Dragging {
                    from,
                    ty: clamp_travel(from, ty, pitch, n),
                };
                None
            }
            (Reorder::Dragging { from, .. }, Phase::Ended) if from == row => {
                let to = target_slot(from, ty, pitch, n);
                *self = Reorder::Settling {
                    from,
                    to,
                    until: now + SETTLE_MS,
                };
                (to != from).then_some((from, to))
            }
            (Reorder::Dragging { from, .. }, Phase::Cancelled) if from == row => {
                *self = Reorder::Settling {
                    from,
                    to: from,
                    until: now + SETTLE_MS,
                };
                None
            }
            _ => None,
        }
    }

    /// Ends the settle when its time is up. True when the state changed (the screen shows the stored order again).
    pub fn tick(&mut self, now: f64) -> bool {
        if let Reorder::Settling { until, .. } = *self
            && now >= until
        {
            *self = Reorder::Idle;
            return true;
        }
        false
    }

    /// Whether a row is held or settling (the screen shows its own copy of the order, not the stored one).
    pub fn is_active(&self) -> bool {
        *self != Reorder::Idle
    }

    /// The slot the held row is over now (while held or settling).
    pub fn over(&self, pitch: f32, n: usize) -> Option<usize> {
        match *self {
            Reorder::Idle => None,
            Reorder::Dragging { from, ty } => Some(target_slot(from, ty, pitch, n)),
            Reorder::Settling { to, .. } => Some(to),
        }
    }

    /// The placement of the row in slot `i` of `n`.
    pub fn placement(&self, i: usize, pitch: f32, n: usize) -> Placement {
        let rest = Placement {
            dy: 0.0,
            on_top: false,
            lifted: false,
            live: false,
        };
        match *self {
            Reorder::Idle => rest,
            Reorder::Dragging { from, ty } => {
                if i == from {
                    Placement {
                        dy: clamp_travel(from, ty, pitch, n),
                        on_top: true,
                        lifted: true,
                        live: true,
                    }
                } else {
                    let to = target_slot(from, ty, pitch, n);
                    Placement {
                        dy: shift_slots(i, from, to) as f32 * pitch,
                        ..rest
                    }
                }
            }
            Reorder::Settling { from, to, .. } => {
                if i == from {
                    Placement {
                        dy: (to as f32 - from as f32) * pitch,
                        on_top: true,
                        ..rest
                    }
                } else {
                    Placement {
                        dy: shift_slots(i, from, to) as f32 * pitch,
                        ..rest
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const P: f32 = 45.0;

    #[test]
    fn travel_stays_inside_the_list() {
        assert_eq!(clamp_travel(2, -500.0, P, 6), -90.0);
        assert_eq!(clamp_travel(2, 500.0, P, 6), 135.0);
        assert_eq!(clamp_travel(2, 10.0, P, 6), 10.0);
        assert_eq!(clamp_travel(0, 20.0, P, 1), 0.0);
    }

    #[test]
    fn target_slot_rounds_to_the_nearest_centre() {
        assert_eq!(target_slot(3, 0.0, P, 6), 3);
        assert_eq!(target_slot(3, -22.0, P, 6), 3);
        assert_eq!(target_slot(3, -23.0, P, 6), 2);
        assert_eq!(target_slot(3, -90.0, P, 6), 1);
        assert_eq!(target_slot(3, -900.0, P, 6), 0);
        assert_eq!(target_slot(3, 900.0, P, 6), 5);
        assert_eq!(target_slot(0, 0.0, P, 0), 0);
    }

    #[test]
    fn rows_between_make_room() {
        // Row 3 dragged up to slot 1: rows 1 and 2 step down, the rest stay.
        let s: Vec<i32> = (0..6).map(|i| shift_slots(i, 3, 1)).collect();
        assert_eq!(s, [0, 1, 1, 0, 0, 0]);
        // Row 1 dragged down to slot 3: rows 2 and 3 step up.
        let s: Vec<i32> = (0..6).map(|i| shift_slots(i, 1, 3)).collect();
        assert_eq!(s, [0, 0, -1, -1, 0, 0]);
        assert!((0..6).all(|i| shift_slots(i, 2, 2) == 0));
    }

    #[test]
    fn shifts_agree_with_the_new_order() {
        for from in 0..5 {
            for to in 0..5 {
                let order = moved_order(5, from, to);
                for i in 0..5 {
                    let slot = order.iter().position(|&o| o == i).unwrap() as i32;
                    let expected = if i == from {
                        to as i32 - i as i32
                    } else {
                        shift_slots(i, from, to)
                    };
                    assert_eq!(slot - i as i32, expected, "from {from} to {to} row {i}");
                }
            }
        }
    }

    #[test]
    fn drag_and_drop_two_places_up() {
        let mut r = Reorder::default();
        assert_eq!(r.pan(4, Phase::Began, -10.0, P, 6, 0.0), None);
        assert_eq!(r.pan(4, Phase::Changed, -60.0, P, 6, 16.0), None);
        let p = r.placement(4, P, 6);
        assert!(p.lifted && p.live && p.on_top);
        assert_eq!(p.dy, -60.0, "the held row follows the pointer 1:1");
        assert_eq!(r.placement(3, P, 6).dy, P, "the row it passes makes room");
        assert_eq!(r.placement(2, P, 6).dy, 0.0);
        assert_eq!(r.pan(4, Phase::Changed, -88.0, P, 6, 32.0), None);
        assert_eq!(r.placement(2, P, 6).dy, P);
        assert_eq!(r.pan(4, Phase::Ended, -88.0, P, 6, 48.0), Some((4, 2)));
        let held = r.placement(4, P, 6);
        assert_eq!(held.dy, -90.0, "it settles into the slot");
        assert!(!held.live && !held.lifted);
        assert!(!r.tick(100.0));
        assert!(r.is_active());
        assert!(r.tick(48.0 + SETTLE_MS));
        assert_eq!(r, Reorder::Idle);
    }

    #[test]
    fn a_short_drag_snaps_back_and_writes_nothing() {
        let mut r = Reorder::default();
        r.pan(1, Phase::Began, 8.0, P, 4, 0.0);
        assert_eq!(r.pan(1, Phase::Ended, 8.0, P, 4, 10.0), None);
        assert_eq!(r.placement(1, P, 4).dy, 0.0);
    }

    #[test]
    fn cancel_and_foreign_events_are_harmless() {
        let mut r = Reorder::default();
        assert_eq!(r.pan(2, Phase::Changed, 30.0, P, 4, 0.0), None);
        assert_eq!(r, Reorder::Idle);
        r.pan(2, Phase::Began, 12.0, P, 4, 0.0);
        assert_eq!(
            r.pan(3, Phase::Changed, 90.0, P, 4, 5.0),
            None,
            "another row's pan is ignored"
        );
        r.pan(2, Phase::Cancelled, 0.0, P, 4, 9.0);
        assert!(matches!(r, Reorder::Settling { from: 2, to: 2, .. }));
        r.pan(0, Phase::Began, 12.0, P, 4, 10.0);
        assert!(
            matches!(r, Reorder::Settling { .. }),
            "no new pick-up while settling"
        );
    }
}

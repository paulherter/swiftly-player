//! One order for every row of the home page that the user can place: the fixed rows
//! (`StartRail` raw values), the library rows and the collection rows (`library:<id>`). New in the
//! Rust core (PR 54 idea). The old per-kind settings (`startReihen`, `startBibliotheken`) stay as
//! they are; this list sits on top and is stored under `startReihenfolge` (per server).
//!
//! The editor is ONE enum, every move in [`OrderEditor::transition`]. UI per state: `Idle` = the
//! plain list, `Editing` = drag handles with the working copy, `Saved` = the list to store (the
//! host writes it, then goes `Idle`).

use std::collections::HashSet;

use crate::start_libraries::StartLibrary;
use crate::start_rails::StartRail;

/// The id of a library or collection row (the rail id the home page uses).
pub fn library_row_id(library: &StartLibrary) -> String {
    format!("library:{}", library.id)
}

/// Rules for the combined list.
pub struct StartOrder;

impl StartOrder {
    /// The effective list: stored ids first (unknown ones, rows that do not exist, and repeats
    /// dropped), then every missing fixed row in basic order, then every missing library or
    /// collection in the chosen order. Without a stored list this is the old default: fixed rows,
    /// then libraries.
    pub fn applicable(
        stored: &[String],
        disconnected: bool,
        libraries: &[StartLibrary],
    ) -> Vec<String> {
        let mut all: Vec<String> = StartRail::ALL
            .into_iter()
            .filter(|r| r.fits(disconnected))
            .map(|r| r.raw_value().to_owned())
            .collect();
        all.extend(libraries.iter().map(library_row_id));
        let valid: HashSet<&str> = all.iter().map(String::as_str).collect();
        let mut seen = HashSet::new();
        let mut out: Vec<String> = stored
            .iter()
            .filter(|s| valid.contains(s.as_str()) && seen.insert(s.as_str()))
            .cloned()
            .collect();
        let have: HashSet<String> = out.iter().cloned().collect();
        out.extend(all.into_iter().filter(|a| !have.contains(a)));
        out
    }

    /// Moves the row at `from` to position `to` (both clamped). Out of range `from`: unchanged.
    pub fn moved(list: &[String], from: usize, to: usize) -> Vec<String> {
        let mut out = list.to_vec();
        if from >= out.len() {
            return out;
        }
        let row = out.remove(from);
        out.insert(to.min(out.len()), row);
        out
    }

    /// The position of a rail id in the effective order; ids outside it (genre rows) sort last.
    pub fn rank(order: &[String], rail_id: &str) -> usize {
        order
            .iter()
            .position(|o| o == rail_id)
            .unwrap_or(usize::MAX)
    }
}

/// The editor of the order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OrderEditor {
    /// Not editing.
    Idle,
    /// Editing a working copy.
    Editing(Vec<String>),
    /// Confirmed: this is the list to store.
    Saved(Vec<String>),
}

/// What can happen to an [`OrderEditor`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OrderEvent {
    /// Open the editor on the effective list.
    Begin(Vec<String>),
    /// Drag a row.
    Move {
        /// Where it was.
        from: usize,
        /// Where it goes.
        to: usize,
    },
    /// Confirm.
    Commit,
    /// Throw the working copy away.
    Cancel,
    /// The host stored the saved list.
    Stored,
}

/// An event that does not fit the state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OrderRefused;

impl OrderEditor {
    /// The only place the state changes.
    ///
    /// # Errors
    /// [`OrderRefused`] for an event the state cannot take; the state stays.
    pub fn transition(self, event: OrderEvent) -> Result<Self, OrderRefused> {
        Ok(match (self, event) {
            (Self::Idle, OrderEvent::Begin(list)) => Self::Editing(list),
            (Self::Editing(list), OrderEvent::Move { from, to }) => {
                Self::Editing(StartOrder::moved(&list, from, to))
            }
            (Self::Editing(list), OrderEvent::Commit) => Self::Saved(list),
            (Self::Editing(_), OrderEvent::Cancel) => Self::Idle,
            (Self::Saved(_), OrderEvent::Stored) => Self::Idle,
            _ => return Err(OrderRefused),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(x: &[&str]) -> Vec<String> {
        x.iter().map(|s| (*s).to_owned()).collect()
    }
    fn libs() -> Vec<StartLibrary> {
        vec![
            StartLibrary::new("L1", "Filme", false),
            StartLibrary::new("C1", "Marvel", true),
        ]
    }

    #[test]
    fn default_is_fixed_rows_then_libraries() {
        let o = StartOrder::applicable(&[], false, &libs());
        assert_eq!(
            o,
            v(&[
                "weiterschauen",
                "naechsteFolge",
                "neuzugaenge",
                "library:L1",
                "library:C1"
            ])
        );
        let split = StartOrder::applicable(&[], true, &[]);
        assert_eq!(
            split,
            v(&["weiterschauen", "naechsteFolge", "neueFilme", "neueSerien"])
        );
    }

    #[test]
    fn stored_order_mixes_kinds_and_heals() {
        let stored = v(&[
            "library:C1",
            "neuzugaenge",
            "library:gone",
            "neueFilme",
            "library:C1",
            "weiterschauen",
        ]);
        let o = StartOrder::applicable(&stored, false, &libs());
        // gone/unknown/not-fitting/repeat dropped; missing appended (fixed first, then libraries).
        assert_eq!(
            o,
            v(&[
                "library:C1",
                "neuzugaenge",
                "weiterschauen",
                "naechsteFolge",
                "library:L1"
            ])
        );
    }

    #[test]
    fn move_and_rank() {
        let l = v(&["a", "b", "c"]);
        assert_eq!(StartOrder::moved(&l, 0, 2), v(&["b", "c", "a"]));
        assert_eq!(StartOrder::moved(&l, 2, 0), v(&["c", "a", "b"]));
        assert_eq!(StartOrder::moved(&l, 1, 99), v(&["a", "c", "b"]));
        assert_eq!(StartOrder::moved(&l, 9, 0), l);
        assert_eq!(StartOrder::rank(&l, "b"), 1);
        assert_eq!(StartOrder::rank(&l, "genre:Drama"), usize::MAX);
    }

    #[test]
    fn editor_transition_table() {
        use OrderEditor as E;
        use OrderEvent as V;
        let l = v(&["a", "b"]);
        assert_eq!(
            E::Idle.transition(V::Begin(l.clone())),
            Ok(E::Editing(l.clone()))
        );
        assert_eq!(
            E::Editing(l.clone()).transition(V::Move { from: 0, to: 1 }),
            Ok(E::Editing(v(&["b", "a"])))
        );
        assert_eq!(
            E::Editing(l.clone()).transition(V::Commit),
            Ok(E::Saved(l.clone()))
        );
        assert_eq!(E::Editing(l.clone()).transition(V::Cancel), Ok(E::Idle));
        assert_eq!(E::Saved(l.clone()).transition(V::Stored), Ok(E::Idle));
        // Illegal.
        assert_eq!(E::Idle.transition(V::Commit), Err(OrderRefused));
        assert_eq!(
            E::Idle.transition(V::Move { from: 0, to: 1 }),
            Err(OrderRefused)
        );
        assert_eq!(E::Idle.transition(V::Stored), Err(OrderRefused));
        assert_eq!(
            E::Editing(l.clone()).transition(V::Begin(l.clone())),
            Err(OrderRefused)
        );
        assert_eq!(
            E::Editing(l.clone()).transition(V::Stored),
            Err(OrderRefused)
        );
        assert_eq!(E::Saved(l.clone()).transition(V::Cancel), Err(OrderRefused));
        assert_eq!(
            E::Saved(l.clone()).transition(V::Move { from: 0, to: 1 }),
            Err(OrderRefused)
        );
    }
}

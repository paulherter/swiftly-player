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

/// The id of the Seerr "ist da" section (the arrival banner and the manager's line).
pub const SEERR_ARRIVAL_ROW: &str = "seerr:arrival";
/// The id of the Seerr "Meine Anfragen" section (the rail of what was asked for).
pub const SEERR_REQUESTS_ROW: &str = "seerr:requests";
/// The Seerr sections in their basic order. They are rows of the combined list only while Seerr is connected.
pub const SEERR_ROWS: [&str; 2] = [SEERR_ARRIVAL_ROW, SEERR_REQUESTS_ROW];

/// Whether a row id is a Seerr section.
pub fn is_seerr_row(id: &str) -> bool {
    SEERR_ROWS.contains(&id)
}

/// Whether a Seerr section is on while the user never touched its switch: the "ist da" banner is, the rail of
/// requests is not (the page stays as quiet as it was without Seerr).
pub fn seerr_row_default_on(id: &str) -> bool {
    id == SEERR_ARRIVAL_ROW
}

/// Which kind of device draws the Start page; the Seerr sections it shows differ (see [`SeerrSection::on_start`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum HomeForm {
    /// iPhone, iPad, Android phone and tablet.
    #[default]
    Handheld,
    /// macOS, Windows, Linux.
    Desktop,
    /// Apple TV, Android TV.
    Tv,
}

/// A Seerr section of the Start page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SeerrSection {
    /// "<Titel> ist da" (with the manager's line).
    Arrival,
    /// "Meine Anfragen".
    Requests,
}

impl SeerrSection {
    /// The id in the combined order.
    pub fn id(self) -> &'static str {
        match self {
            Self::Arrival => SEERR_ARRIVAL_ROW,
            Self::Requests => SEERR_REQUESTS_ROW,
        }
    }

    /// The section of an id in the combined order.
    pub fn from_id(id: &str) -> Option<Self> {
        [Self::Arrival, Self::Requests]
            .into_iter()
            .find(|s| s.id() == id)
    }

    /// The name in the settings list; German, because German is the catalog key.
    pub fn lists_name(self) -> &'static str {
        match self {
            Self::Arrival => "Anfrage ist da",
            Self::Requests => "Meine Anfragen",
        }
    }

    /// Whether the section belongs on the Start page of `form` at all (whatever its switch says). Handhelds show both.
    /// The desktop drops "Meine Anfragen" (far too big there; it stays reachable through the profile entry) and keeps
    /// the "ist da" banner. A TV shows neither: its Start page is for browsing and playing.
    pub fn on_start(self, form: HomeForm) -> bool {
        match form {
            HomeForm::Handheld => true,
            HomeForm::Desktop => self == Self::Arrival,
            HomeForm::Tv => false,
        }
    }

    /// The setting that switches it (a bool key, the same name on every platform).
    pub fn switch_key(self) -> &'static str {
        match self {
            Self::Arrival => "seerrArrivalHint",
            Self::Requests => "seerrRequestsRail",
        }
    }
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
        Self::applicable_with_seerr(stored, disconnected, libraries, false)
    }

    /// [`Self::applicable`] with the two Seerr sections (`seerr:arrival`, `seerr:requests`) when Seerr is connected.
    /// Without Seerr they are not rows at all. A Seerr section that is not stored yet goes to the top, in basic
    /// order, where the block used to stand above the rows.
    pub fn applicable_with_seerr(
        stored: &[String],
        disconnected: bool,
        libraries: &[StartLibrary],
        seerr: bool,
    ) -> Vec<String> {
        Self::applicable_for(stored, disconnected, libraries, seerr, HomeForm::Handheld)
    }

    /// [`Self::applicable_with_seerr`] for a device form: only the Seerr sections that [`SeerrSection::on_start`]
    /// allows there are rows (a stored id of another one is dropped like any row that does not exist).
    pub fn applicable_for(
        stored: &[String],
        disconnected: bool,
        libraries: &[StartLibrary],
        seerr: bool,
        form: HomeForm,
    ) -> Vec<String> {
        let mut all: Vec<String> = StartRail::ALL
            .into_iter()
            .filter(|r| r.fits(disconnected))
            .map(|r| r.raw_value().to_owned())
            .collect();
        all.extend(libraries.iter().map(library_row_id));
        if seerr {
            all.extend(
                SEERR_ROWS
                    .iter()
                    .filter(|id| SeerrSection::from_id(id).is_some_and(|s| s.on_start(form)))
                    .map(|s| (*s).to_owned()),
            );
        }
        let valid: HashSet<&str> = all.iter().map(String::as_str).collect();
        let mut seen = HashSet::new();
        let mut out: Vec<String> = stored
            .iter()
            .filter(|s| valid.contains(s.as_str()) && seen.insert(s.as_str()))
            .cloned()
            .collect();
        let have: HashSet<String> = out.iter().cloned().collect();
        let (new_seerr, rest): (Vec<String>, Vec<String>) = all
            .into_iter()
            .filter(|a| !have.contains(a))
            .partition(|a| is_seerr_row(a));
        out.extend(rest);
        out.splice(0..0, new_seerr);
        out
    }

    /// The one-time carry-over of the old per-kind order: while no combined order is stored (`stored` empty), the
    /// fixed rows of the old `startReihen` list (known raw values, repeats dropped, their order kept) become the
    /// start of it. `Some(list)` is what the host stores once under `startReihenfolge`; `None` when an order is
    /// stored already or there is nothing old to carry. The healing in [`Self::applicable_with_seerr`] adds every
    /// row that is missing, so the carried list never needs to be complete.
    pub fn carried_over(stored: &[String], old_fixed: &[String]) -> Option<Vec<String>> {
        if !stored.is_empty() {
            return None;
        }
        let mut seen = HashSet::new();
        let carried: Vec<String> = old_fixed
            .iter()
            .filter(|r| StartRail::from_raw(r).is_some() && seen.insert(r.as_str()))
            .cloned()
            .collect();
        (!carried.is_empty()).then_some(carried)
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

    /// Where the Seerr sections stand among the rails a host draws: for each Seerr row of the effective `order` (the
    /// one with Seerr rows, see [`Self::applicable_with_seerr`]) the number of `rail_ids` (in display order) that come
    /// before it, i.e. the index to insert the section at. Rails outside the order (genre rows) come last, so a section
    /// never lands behind them. Hosts that draw their rails from a list (desktop, TV) place the sections with this
    /// instead of putting the block on top.
    pub fn seerr_places(order: &[String], rail_ids: &[&str]) -> Vec<(SeerrSection, usize)> {
        order
            .iter()
            .enumerate()
            .filter_map(|(at, id)| {
                let section = SeerrSection::from_id(id)?;
                let before = rail_ids
                    .iter()
                    .filter(|r| Self::rank(order, r) < at)
                    .count();
                Some((section, before))
            })
            .collect()
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
    #[test]
    fn seerr_sections_stand_at_their_place_among_the_rails() {
        let order = v(&[
            "continueWatching",
            "seerr:requests",
            "newMovies",
            "seerr:arrival",
        ]);
        let rails = ["continueWatching", "newMovies", "genre:Action"];
        assert_eq!(
            StartOrder::seerr_places(&order, &rails),
            vec![(SeerrSection::Requests, 1), (SeerrSection::Arrival, 2)]
        );
        // On top and with nothing else shown: index 0, never behind the genre rows.
        let top = v(&["seerr:arrival", "newMovies"]);
        assert_eq!(
            StartOrder::seerr_places(&top, &["genre:Action"]),
            vec![(SeerrSection::Arrival, 0)]
        );
    }

    fn libs() -> Vec<StartLibrary> {
        vec![
            StartLibrary::new("L1", "Filme", false),
            StartLibrary::new("C1", "Marvel", true),
        ]
    }

    #[test]
    fn old_fixed_order_is_carried_over_once() {
        // Nothing stored: the old order (unknown values and repeats dropped) is carried.
        let old = v(&["neuzugaenge", "bogus", "weiterschauen", "neuzugaenge"]);
        let carried = StartOrder::carried_over(&[], &old).unwrap();
        assert_eq!(carried, v(&["neuzugaenge", "weiterschauen"]));
        // The effective list then keeps that order and heals the rest in basic order, libraries last.
        let o = StartOrder::applicable(&carried, false, &libs());
        assert_eq!(
            o,
            v(&[
                "neuzugaenge",
                "weiterschauen",
                "naechsteFolge",
                "library:L1",
                "library:C1"
            ])
        );
        // Once stored, nothing is carried again (the new order wins, even over a changed old list).
        assert_eq!(StartOrder::carried_over(&carried, &old), None);
        // Nothing old: nothing to carry.
        assert_eq!(StartOrder::carried_over(&[], &[]), None);
        assert_eq!(StartOrder::carried_over(&[], &v(&["bogus"])), None);
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
    fn seerr_sections_are_rows_only_with_seerr_and_new_ones_go_to_the_top() {
        // Without Seerr nothing changes, and a stored Seerr id is dropped like any row that does not exist.
        let stored = v(&["seerr:requests", "neuzugaenge"]);
        let without = StartOrder::applicable(&stored, false, &[]);
        assert_eq!(
            without,
            v(&["neuzugaenge", "weiterschauen", "naechsteFolge"])
        );
        // With Seerr, never stored: both on top in basic order, then the old default.
        let fresh = StartOrder::applicable_with_seerr(&[], false, &libs(), true);
        assert_eq!(
            fresh,
            v(&[
                "seerr:arrival",
                "seerr:requests",
                "weiterschauen",
                "naechsteFolge",
                "neuzugaenge",
                "library:L1",
                "library:C1"
            ])
        );
        // A stored place is kept; only the missing section comes on top.
        let kept = StartOrder::applicable_with_seerr(&stored, false, &[], true);
        assert_eq!(
            kept,
            v(&[
                "seerr:arrival",
                "seerr:requests",
                "neuzugaenge",
                "weiterschauen",
                "naechsteFolge"
            ])
        );
        let moved = v(&["weiterschauen", "seerr:requests", "seerr:arrival"]);
        let healed = StartOrder::applicable_with_seerr(&moved, false, &[], true);
        assert_eq!(
            &healed[..3],
            ["weiterschauen", "seerr:requests", "seerr:arrival"]
        );
        assert!(seerr_row_default_on(SEERR_ARRIVAL_ROW));
        assert!(!seerr_row_default_on(SEERR_REQUESTS_ROW));
    }

    #[test]
    fn seerr_sections_follow_the_device_form() {
        let all = ["seerr:arrival", "seerr:requests"];
        let stored = v(&["seerr:requests", "neuzugaenge", "seerr:arrival"]);
        let rows = |form| {
            StartOrder::applicable_for(&stored, false, &[], true, form)
                .into_iter()
                .filter(|r| all.contains(&r.as_str()))
                .collect::<Vec<_>>()
        };
        // Handheld: both, as stored. Desktop: only the banner. TV: none, even when stored or new.
        assert_eq!(
            rows(HomeForm::Handheld),
            v(&["seerr:requests", "seerr:arrival"])
        );
        assert_eq!(rows(HomeForm::Desktop), v(&["seerr:arrival"]));
        assert!(rows(HomeForm::Tv).is_empty());
        // Never stored: the same sections, still on top.
        let fresh = StartOrder::applicable_for(&[], false, &[], true, HomeForm::Desktop);
        assert_eq!(fresh[0], "seerr:arrival");
        assert!(!fresh.contains(&"seerr:requests".to_owned()));
        assert_eq!(
            StartOrder::applicable_for(&[], false, &[], true, HomeForm::Tv),
            StartOrder::applicable(&[], false, &[])
        );
        // The old call is the handheld one.
        assert_eq!(
            StartOrder::applicable_with_seerr(&stored, false, &[], true),
            StartOrder::applicable_for(&stored, false, &[], true, HomeForm::Handheld)
        );
        assert!(SeerrSection::Requests.on_start(HomeForm::Handheld));
        assert!(!SeerrSection::Requests.on_start(HomeForm::Desktop));
        assert!(SeerrSection::Arrival.on_start(HomeForm::Desktop));
        assert!(!SeerrSection::Arrival.on_start(HomeForm::Tv));
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

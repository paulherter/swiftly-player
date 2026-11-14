//! The tile menu of Swift (`Shared/TileMenu.swift`, Mac: `macOS/TileMenuMac.swift`) as the list of entries a long press
//! or right click opens, for Home, Library and the rails of the Detail page. The sheet itself is `browse::sheet`.

use crate::browse::SheetRow;
use crate::home::Form;
use swiftly_vm::{Badge, MenuContext, Tile};

/// One entry of the menu.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Entry {
    /// "Abspielen" / "Fortsetzen".
    Play,
    /// Mac: "Von vorn".
    FromStart,
    /// "Zur Übersicht" (Continue Watching only).
    Overview,
    /// Mac: "Merken" / "Nicht mehr merken".
    Remember,
    /// "Als gesehen markieren".
    Watched,
    /// "Als ungesehen markieren".
    Unwatched,
    /// "Laden" (touch).
    Load,
    /// "Abspielen auf …", a submenu of the devices in reach.
    PlayOn,
    /// "Gemeinsam schauen".
    Together,
    /// Mac: "Zur Serie" (episodes).
    ToSeries,
    /// Mac: "Info".
    Info,
    /// "Aus Weiterschauen entfernen".
    Remove,
}

/// What the menu needs besides the tile.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cx {
    /// The host's facts (download button, devices, SyncPlay, Continue Watching).
    pub host: MenuContext,
    /// The watchlist is switched on (`watchlistShown`, Mac).
    pub watchlist_shown: bool,
    /// The title is on the watchlist.
    pub favourite: bool,
}

fn kind(tile: Option<&Tile>) -> Option<&str> {
    tile.and_then(|t| t.facts.kind.as_deref())
}

/// `TileMenu.carries`: movies, series and episodes (an unknown kind counts as one).
pub fn carries(tile: Option<&Tile>) -> bool {
    kind(tile).is_none_or(|k| {
        ["movie", "series", "episode"]
            .iter()
            .any(|x| k.eq_ignore_ascii_case(x))
    })
}

fn is_series(tile: Option<&Tile>) -> bool {
    kind(tile).is_some_and(|k| k.eq_ignore_ascii_case("series"))
}

fn begun(tile: Option<&Tile>) -> bool {
    tile.is_some_and(|t| t.progress.is_some_and(|p| p > 0.0))
}

/// The entries in Swift order for `form`: touch and tv share the list (tv has no "Laden"), the Mac adds "Von vorn",
/// "Merken", "Zur Serie" and "Info" and has no "Laden" (its confirmation hangs at the page's download button).
pub fn entries(form: Form, cx: &Cx, tile: Option<&Tile>) -> Vec<Entry> {
    if !carries(tile) {
        return Vec::new();
    }
    let (series, begun) = (is_series(tile), begun(tile));
    let watched = tile.is_some_and(|t| t.badges.contains(&Badge::Watched));
    let mac = form == Form::Desktop;
    let player = cx.host.in_player;
    let mut v = Vec::new();
    if !player {
        v.push(Entry::Play);
        if mac && !series && begun {
            v.push(Entry::FromStart);
        }
    }
    if cx.host.continue_watching {
        v.push(Entry::Overview);
    }
    if mac && !player && cx.watchlist_shown {
        v.push(Entry::Remember);
    }
    if series || !watched {
        v.push(Entry::Watched);
    }
    if series || watched || begun {
        v.push(Entry::Unwatched);
    }
    if form == Form::Touch && !series && !player && cx.host.download_button && !cx.host.on_device {
        v.push(Entry::Load);
    }
    if !series && !player && !cx.host.play_on.is_empty() {
        v.push(Entry::PlayOn);
    }
    if !series && !player && cx.host.together {
        v.push(Entry::Together);
    }
    if mac && !player {
        if kind(tile).is_some_and(|k| k.eq_ignore_ascii_case("episode"))
            && tile.is_some_and(|t| t.facts.series_id.is_some())
        {
            v.push(Entry::ToSeries);
        }
        v.push(Entry::Info);
    }
    if cx.host.continue_watching {
        v.push(Entry::Remove);
    }
    v
}

/// The symbol in front of one entry on the Mac (`TileMenuMac.swift:59-140`): play, back to the start, info circle,
/// bookmark (filled when kept), check circle, crossed eye, TV, two people, minus circle.
pub fn icon(e: &Entry, cx: &Cx) -> &'static str {
    match e {
        Entry::Play => "play.fill",
        Entry::FromStart => "arrow-counter-clockwise",
        Entry::Overview | Entry::Info => "info",
        Entry::Remember if cx.favourite => "bookmark-simple.fill",
        Entry::Remember => "bookmark-simple",
        Entry::Watched => "check-circle",
        Entry::Unwatched => "eye-slash",
        Entry::Load => "arrow-circle-down",
        Entry::PlayOn | Entry::ToSeries => "television",
        Entry::Together => "users",
        Entry::Remove => "minus-circle",
    }
}

/// The symbol of an entry of a title page's More menu (`DetailView.coreMenu` / `seriesMenu`: tv, gobackward,
/// arrow.counterclockwise.circle, person.2, arrow.clockwise, film, forward.end.alt, shuffle, checkmark.circle, the
/// download arrow; the ellipsis for the rest).
pub fn more_icon(kind: &swiftly_vm::MenuKind) -> &'static str {
    use swiftly_vm::MenuKind as K;
    match kind {
        K::PlayOn { .. } => "television",
        K::PlayFromStart | K::PlayEpisodeFromStart => "arrow-counter-clockwise",
        K::ResetProgress => "clock-counter-clockwise",
        K::Together => "users",
        K::RefreshMetadata => "arrow-clockwise",
        K::Trailer => "film-strip",
        K::NextEpisode => "skip-forward",
        K::Shuffle => "shuffle",
        K::MarkSeasonWatched { .. } | K::MarkWatched => "check-circle",
        K::MarkUnwatched => "eye-slash",
        K::Download => "arrow-circle-down",
        K::Play => "play.fill",
        K::Overview => "info",
        K::RemoveFromContinue => "minus-circle",
    }
}

/// The wording of one entry (Swift catalog keys).
pub fn label(e: &Entry, cx: &Cx, tile: Option<&Tile>) -> &'static str {
    match e {
        Entry::Play if !is_series(tile) && begun(tile) => "Fortsetzen",
        Entry::Play => "Abspielen",
        Entry::FromStart => "Von vorn",
        Entry::Overview => "Zur Übersicht",
        Entry::Remember if cx.favourite => "Nicht mehr merken",
        Entry::Remember => "Merken",
        Entry::Watched => "Als gesehen markieren",
        Entry::Unwatched => "Als ungesehen markieren",
        Entry::Load => "Laden",
        Entry::PlayOn => "Abspielen auf \u{2026}",
        Entry::Together => "Gemeinsam schauen",
        Entry::ToSeries => "Zur Serie",
        Entry::Info => "Info",
        Entry::Remove => "Aus Weiterschauen entfernen",
    }
}

/// The sheet rows of the menu.
pub fn rows(form: Form, cx: &Cx, tile: Option<&Tile>) -> Vec<SheetRow> {
    entries(form, cx, tile)
        .iter()
        .map(|e| SheetRow {
            label: label(e, cx, tile).into(),
            selected: false,
        })
        .collect()
}

/// The rows of the "Abspielen auf …" submenu: the device names.
pub fn device_rows(cx: &Cx) -> Vec<SheetRow> {
    cx.host
        .play_on
        .iter()
        .map(|(_, name)| SheetRow {
            label: name.clone(),
            selected: false,
        })
        .collect()
}

/// The menu context of the demo host: a TV in reach, SyncPlay allowed, downloads on.
pub fn demo_cx(continue_watching: bool) -> Cx {
    Cx {
        host: MenuContext {
            download_button: true,
            on_device: false,
            play_on: vec![("tv-1".into(), "Wohnzimmer".into())],
            together: true,
            continue_watching,
            in_player: false,
        },
        watchlist_shown: true,
        favourite: false,
    }
}

/// The menu context of a tile on a title page: the real one when the app is signed in (the watchlist setting, the
/// tile's own favourite mark, the devices in reach and watching together), the demo host's otherwise.
pub fn context_for(tile: Option<&Tile>) -> Cx {
    let Some(w) = crate::live::current() else {
        return demo_cx(false);
    };
    Cx {
        host: live_host(&w, false),
        watchlist_shown: w.watchlist_shown(),
        favourite: tile.is_some_and(|t| t.badges.contains(&Badge::Favorite)),
    }
}

/// The devices in reach and whether watching together is open to this account, from the hub of the signed-in app. The
/// More menus of the title pages send it to their view models (the Mac's `DetailCore.send(options:)`).
pub(crate) fn live_host(w: &crate::live::Wiring, continue_watching: bool) -> MenuContext {
    let (play_on, together) = w
        .together()
        .map_or((Vec::new(), false), |h| (h.play_targets(), h.may_create()));
    MenuContext {
        play_on,
        together,
        continue_watching,
        ..MenuContext::default()
    }
}

/// The menu context of a tile on Home or in a library: the real one when the app is signed in, the demo host's
/// otherwise. `continue_watching`: the tile sits in the "Weiterschauen" rail.
pub fn rail_cx(continue_watching: bool, favourite: bool) -> Cx {
    let Some(w) = crate::live::current() else {
        let mut c = demo_cx(continue_watching);
        c.favourite = favourite;
        return c;
    };
    Cx {
        host: live_host(&w, continue_watching),
        watchlist_shown: w.watchlist_shown(),
        favourite,
    }
}

/// What the host does after a pick of the tile menu on a title page (`TileMenuMac`).
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// Start this title (`controls.launch`): from the resume point (`since` < 0) or from the start.
    Play(crate::live_play::PlayRequest),
    /// Open the page of this tile (`navigator.openIt(.title)`; an episode leads to its series).
    Open,
    /// The server write was sent; the lists around reload.
    Wrote,
    /// Nothing to do here.
    Nothing,
}

/// Carries out one entry for `tile`. The writes are the core's: a `DetailVm` over the tile sends the same
/// `SetWatched` / `SetWatchlist` the Mac's `model.setWatched` / `setWatchlist` run; the view model is kept in `keep`
/// until the write has gone out.
pub fn run(
    e: &Entry,
    tile: &Tile,
    cx: &Cx,
    keep: &mut Vec<swiftly_vm::DetailVm<crate::net::AppTransport>>,
) -> Outcome {
    let play = |since: f64| {
        Outcome::Play(crate::live_play::PlayRequest {
            item_id: tile.id.clone(),
            since,
            source_id: None,
        })
    };
    let write = |keep: &mut Vec<_>, intent: swiftly_vm::DetailIntent| {
        let Some(w) = crate::live::current() else {
            return Outcome::Nothing;
        };
        if let Ok(vm) = swiftly_vm::DetailVm::new(
            std::sync::Arc::clone(&w.core.net),
            w.core.host(),
            w.stand_in(&tile.id, &tile.title),
            Some(w.account.clone()),
        ) {
            vm.send(intent);
            keep.push(vm);
            crate::desk::note_list_change();
            Outcome::Wrote
        } else {
            Outcome::Nothing
        }
    };
    match e {
        // A series has no single file: its page decides the next episode.
        Entry::Play if is_series(Some(tile)) => Outcome::Open,
        Entry::Play => play(-1.0),
        Entry::FromStart => play(0.0),
        Entry::Info | Entry::ToSeries | Entry::Overview => Outcome::Open,
        Entry::Watched => write(keep, swiftly_vm::DetailIntent::SetWatched { on: true }),
        Entry::Unwatched => write(keep, swiftly_vm::DetailIntent::SetWatched { on: false }),
        Entry::Remember => write(
            keep,
            swiftly_vm::DetailIntent::SetWatchlist { on: !cx.favourite },
        ),
        Entry::Load | Entry::PlayOn | Entry::Together | Entry::Remove => Outcome::Nothing,
    }
}

/// The popover rows of the tile menu at the pointer: the entries of [`entries`], `tmenu:{i}` as their actions.
pub fn pop_items(form: Form, cx: &Cx, tile: Option<&Tile>) -> Vec<swiftly_ui::popover::MenuEntry> {
    let entries = entries(form, cx, tile);
    match tile {
        // The rows with the Mac's shortcuts (Return, Cmd-D, Cmd-Shift-G, Cmd-I), as the Home and Library menus have them.
        Some(t) => crate::desk::tile_rows(&entries, t, cx, "tmenu:"),
        None => entries
            .iter()
            .enumerate()
            .map(|(i, e)| {
                swiftly_ui::popover::MenuEntry::Item(
                    swiftly_ui::popover::MenuItem::new(
                        swiftly_ui::Action::from(format!("tmenu:{i}").as_str()),
                        label(e, cx, tile),
                    )
                    .icon(icon(e, cx)),
                )
            })
            .collect(),
    }
}

#[cfg(test)]
mod round2_tests {
    use super::*;
    use swiftly_ui::popover::MenuEntry;

    #[test]
    fn the_menu_of_a_title_page_rail_carries_the_macs_shortcuts() {
        let tile = Tile {
            id: "m1".into(),
            title: "Nordlicht".into(),
            subtitle: None,
            progress: None,
            image: None,
            badges: Vec::new(),
            remaining: None,
            facts: swiftly_vm::TileFacts {
                kind: Some("Movie".into()),
                ..swiftly_vm::TileFacts::default()
            },
        };
        let rows = pop_items(Form::Desktop, &demo_cx(false), Some(&tile));
        let shortcut_of = |label: &str| {
            rows.iter().find_map(|r| match r {
                MenuEntry::Item(i) if i.label == label => Some(i.shortcut.clone()),
                _ => None,
            })
        };
        assert_eq!(shortcut_of("Abspielen"), Some(Some("\u{21B5}".to_owned())));
        assert_eq!(shortcut_of("Info"), Some(Some(crate::desk::hint("I"))));
        assert_eq!(
            shortcut_of("Als gesehen markieren"),
            Some(Some(crate::desk::hint_shift("G")))
        );
    }

    fn tile_for_test() -> Tile {
        Tile {
            id: "m1".into(),
            title: "Nordlicht".into(),
            subtitle: None,
            progress: Some(0.4),
            image: None,
            badges: Vec::new(),
            remaining: None,
            facts: swiftly_vm::TileFacts {
                kind: Some("Movie".into()),
                ..swiftly_vm::TileFacts::default()
            },
        }
    }

    #[test]
    fn every_tile_menu_row_and_more_menu_entry_carries_a_symbol_that_exists() {
        use swiftly_vm::MenuKind as K;
        let mut cx = demo_cx(true);
        cx.watchlist_shown = true;
        for favourite in [false, true] {
            cx.favourite = favourite;
            for e in [
                Entry::Play,
                Entry::FromStart,
                Entry::Overview,
                Entry::Remember,
                Entry::Watched,
                Entry::Unwatched,
                Entry::Load,
                Entry::PlayOn,
                Entry::Together,
                Entry::ToSeries,
                Entry::Info,
                Entry::Remove,
            ] {
                assert!(
                    swiftly_ui::icons::path_data(icon(&e, &cx)).is_some(),
                    "{e:?} has no drawn symbol"
                );
            }
        }
        cx.favourite = true;
        assert_eq!(icon(&Entry::Remember, &cx), "bookmark-simple.fill");
        for k in [
            K::Play,
            K::PlayFromStart,
            K::Overview,
            K::MarkWatched,
            K::MarkUnwatched,
            K::Download,
            K::PlayOn {
                id: String::new(),
                name: String::new(),
            },
            K::Together,
            K::RemoveFromContinue,
            K::ResetProgress,
            K::RefreshMetadata,
            K::PlayEpisodeFromStart,
            K::NextEpisode,
            K::Shuffle,
            K::MarkSeasonWatched {
                name: String::new(),
            },
            K::Trailer,
        ] {
            assert!(
                swiftly_ui::icons::path_data(more_icon(&k)).is_some(),
                "{k:?} has no drawn symbol"
            );
        }
        let rows = pop_items(Form::Desktop, &cx, Some(&tile_for_test()));
        assert!(!rows.is_empty());
        for r in rows {
            if let swiftly_ui::popover::MenuEntry::Item(i) = r {
                assert!(i.icon.is_some(), "{} has no symbol", i.label);
            }
        }
    }
}

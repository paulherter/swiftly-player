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

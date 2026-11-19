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
/// "Merken", "Zur Serie" and "Info". The Mac has no "Laden" here (its confirmation hangs at the page's download
/// button); Windows and Linux have no such button on a tile, so their menu carries "Laden" like the touch one: for a
/// film or an episode (not a series), when the download button is offered at all, and not for a title that is on the
/// device already or queued.
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
    if form != Form::Tv
        && !series
        && !player
        && cx.host.download_button
        && !cx.host.on_device
        && !tile.is_some_and(|t| crate::live::current().is_some_and(|w| w.on_device(&t.id)))
    {
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
    rows_of(&entries(form, cx, tile), cx, tile)
}

/// The sheet rows of a list of entries that was computed once (a sheet that is open carries out the very entries it
/// shows).
pub fn rows_of(entries: &[Entry], cx: &Cx, tile: Option<&Tile>) -> Vec<SheetRow> {
    entries
        .iter()
        .map(|e| SheetRow {
            label: label(e, cx, tile).into(),
            selected: false,
        })
        .collect()
}

/// What a Home request "Remember:<id>:<on|off>" asks for as the menu context's `favourite`: `off` is what the row
/// "Nicht mehr merken" sends (the title is on the watchlist), `on` what "Merken" sends. A request without the flag falls
/// back to the tile as it is now.
pub fn favourite_of_request(flag: Option<&str>, tile: &Tile) -> bool {
    match flag {
        Some("off") => true,
        Some("on") => false,
        _ => tile.badges.contains(&Badge::Favorite),
    }
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
    // The right is asked once; until the answer is here an unknown right counts as allowed (`DownloadPermission`).
    w.ask_download_right();
    MenuContext {
        play_on,
        together,
        continue_watching,
        download_button: w.download_button(),
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

/// Drops the view models of the writes that have finished (the list holds the ones in flight, nothing else).
pub fn prune(keep: &mut Vec<swiftly_vm::DetailVm<crate::net::AppTransport>>) {
    keep.retain(swiftly_vm::DetailVm::busy);
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
        // The writes that have been answered no longer need their view model: only the ones in flight stay.
        prune(keep);
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

#[cfg(test)]
mod download_entry_tests {
    use super::*;

    fn tile(kind: &str) -> Tile {
        Tile {
            id: "t1".into(),
            title: "Titel".into(),
            subtitle: None,
            progress: None,
            image: None,
            badges: Vec::new(),
            remaining: None,
            facts: swiftly_vm::TileFacts {
                kind: Some(kind.into()),
                ..swiftly_vm::TileFacts::default()
            },
        }
    }

    fn has_load(form: Form, cx: &Cx, kind: &str) -> bool {
        entries(form, cx, Some(&tile(kind))).contains(&Entry::Load)
    }

    #[test]
    fn the_right_click_menu_offers_laden_for_films_and_episodes_that_can_be_downloaded() {
        let cx = demo_cx(false);
        assert!(has_load(Form::Desktop, &cx, "Movie"));
        assert!(has_load(Form::Desktop, &cx, "Episode"));
        // A series has no single file; the tv menu never had the entry.
        assert!(!has_load(Form::Desktop, &cx, "Series"));
        assert!(!has_load(Form::Tv, &cx, "Movie"));
        // No download button (switch off or the account may not download), a copy on the device or queued, the player.
        let mut off = demo_cx(false);
        off.host.download_button = false;
        assert!(!has_load(Form::Desktop, &off, "Movie"));
        let mut on_device = demo_cx(false);
        on_device.host.on_device = true;
        assert!(!has_load(Form::Desktop, &on_device, "Movie"));
        let mut player = demo_cx(false);
        player.host.in_player = true;
        assert!(!has_load(Form::Desktop, &player, "Movie"));
    }

    #[test]
    fn a_picked_laden_reaches_the_suite_once_in_order() {
        let _ = crate::desk::take_download_requests();
        crate::desk::request_download("a");
        crate::desk::request_download("b");
        assert_eq!(crate::desk::take_download_requests(), ["a", "b"]);
        assert!(crate::desk::take_download_requests().is_empty());
    }
}

#[cfg(test)]
mod writers_tests {
    use super::*;
    use swiftly_vm::{DetailIntent, DetailVm};

    fn writer(server: swiftly_net::MockTransport) -> DetailVm<crate::net::AppTransport> {
        let item = serde_json::from_value(serde_json::json!({
            "Id": "m1", "Name": "Nordlicht", "Type": "Movie"
        }))
        .unwrap();
        DetailVm::new(
            std::sync::Arc::new(crate::net::AppTransport::Mock(server)),
            crate::home_data::scripted_host(),
            item,
            Some(crate::home_data::account()),
        )
        .unwrap()
    }

    #[test]
    fn the_writers_list_shrinks_once_the_requests_have_finished() {
        let mut keep = Vec::new();
        for _ in 0..5 {
            let vm = writer(swiftly_net::MockTransport::new());
            vm.send(DetailIntent::SetWatched { on: true });
            keep.push(vm);
        }
        assert_eq!(keep.len(), 5);
        let began = std::time::Instant::now();
        while keep.iter().any(DetailVm::busy) && began.elapsed().as_secs() < 10 {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        prune(&mut keep);
        assert!(keep.is_empty(), "the answered writes are dropped");
    }

    #[test]
    fn a_write_still_in_flight_is_kept() {
        // The server never answers in time for this check: the request is held by a transport that blocks.
        struct Stuck(std::sync::Arc<(std::sync::Mutex<bool>, std::sync::Condvar)>);
        impl crate::net::HostHttp for Stuck {
            fn send(
                &self,
                _request: swiftly_net::HttpRequest,
            ) -> Result<swiftly_net::HttpResponse, swiftly_net::ErrorKind> {
                let (open, bell) = &*self.0;
                let mut open = open.lock().unwrap();
                while !*open {
                    open = bell.wait(open).unwrap();
                }
                Ok(swiftly_net::HttpResponse::new(200, "{}"))
            }
        }
        let gate = std::sync::Arc::new((std::sync::Mutex::new(false), std::sync::Condvar::new()));
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .build()
            .unwrap();
        let transport = crate::net::AppTransport::Host(
            std::sync::Arc::new(Stuck(std::sync::Arc::clone(&gate))),
            runtime.handle().clone(),
        );
        let item = serde_json::from_value(serde_json::json!({
            "Id": "m1", "Name": "Nordlicht", "Type": "Movie"
        }))
        .unwrap();
        let vm = DetailVm::new(
            std::sync::Arc::new(transport),
            crate::home_data::scripted_host(),
            item,
            Some(crate::home_data::account()),
        )
        .unwrap();
        vm.send(DetailIntent::SetWatched { on: true });
        let mut keep = vec![vm];
        std::thread::sleep(std::time::Duration::from_millis(100));
        prune(&mut keep);
        assert_eq!(keep.len(), 1, "a request in flight keeps its view model");
        *gate.0.lock().unwrap() = true;
        gate.1.notify_all();
        let began = std::time::Instant::now();
        while keep.iter().any(DetailVm::busy) && began.elapsed().as_secs() < 10 {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        prune(&mut keep);
        assert!(keep.is_empty());
        runtime.shutdown_background();
    }

    #[test]
    fn the_remember_flag_is_what_the_row_said() {
        let mut tile = Tile {
            id: "m1".into(),
            title: "Nordlicht".into(),
            subtitle: None,
            progress: None,
            image: None,
            badges: vec![Badge::Favorite],
            remaining: None,
            facts: swiftly_vm::TileFacts::default(),
        };
        // The row said "Merken" while the title was not on the list; the title was put on it meanwhile: still "on".
        assert!(!favourite_of_request(Some("on"), &tile));
        assert!(favourite_of_request(Some("off"), &tile));
        assert!(favourite_of_request(None, &tile));
        tile.badges.clear();
        assert!(!favourite_of_request(None, &tile));
    }
}

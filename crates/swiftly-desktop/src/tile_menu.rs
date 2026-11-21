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
    /// Mac: "Problem melden" (what Seerr adds for an account that may report; the core decides who sees it).
    Report,
    /// Mac: "Vom Server löschen" (Seerr, for an account that manages requests and a device without the delete lock).
    Delete,
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
    if mac && !player && crate::desk::report_offered() {
        v.push(Entry::Report);
    }
    if mac && !player && crate::desk::delete_offered() {
        v.push(Entry::Delete);
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
        Entry::Report => "warning",
        Entry::Delete => "trash",
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
        Entry::Play if !is_series(tile) && begun(tile) => swiftly_l10n::tr("Fortsetzen"),
        Entry::Play => swiftly_l10n::tr("Abspielen"),
        Entry::FromStart => swiftly_l10n::tr("Von vorn"),
        Entry::Overview => swiftly_l10n::tr("Zur Übersicht"),
        Entry::Remember if cx.favourite => swiftly_l10n::tr("Nicht mehr merken"),
        Entry::Remember => swiftly_l10n::tr("Merken"),
        Entry::Watched => swiftly_l10n::tr("Als gesehen markieren"),
        Entry::Unwatched => swiftly_l10n::tr("Als ungesehen markieren"),
        Entry::Load => swiftly_l10n::tr("Laden"),
        Entry::PlayOn => swiftly_l10n::tr("Abspielen auf \u{2026}"),
        Entry::Together => swiftly_l10n::tr("Gemeinsam schauen"),
        Entry::Report => swiftly_l10n::tr("Problem melden"),
        Entry::Delete => swiftly_l10n::tr("Vom Server löschen"),
        Entry::ToSeries => swiftly_l10n::tr("Zur Serie"),
        Entry::Info => swiftly_l10n::tr("Info"),
        Entry::Remove => swiftly_l10n::tr("Aus Weiterschauen entfernen"),
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
        // The suite reads the title's place and opens the report sheet over the page.
        Entry::Report => {
            crate::desk::request_report(&tile.id, None);
            Outcome::Nothing
        }
        // The suite reads the title and opens the confirm sheet over the page.
        Entry::Delete => {
            crate::desk::request_delete(&tile.id, false);
            Outcome::Nothing
        }
        Entry::Load | Entry::PlayOn | Entry::Together | Entry::Remove => Outcome::Nothing,
    }
}

/// The entry a shortcut command of an open tile menu stands for (the Mac's `keyboardShortcut` on its rows: Cmd+D,
/// Cmd+Shift+G, Cmd+I; Ctrl instead of Cmd on Windows and Linux).
pub fn shortcut_entry(command: &str) -> Option<Entry> {
    match command {
        "tile.remember" => Some(Entry::Remember),
        "tile.watched" => Some(Entry::Watched),
        "tile.info" => Some(Entry::Info),
        _ => None,
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

    pub(super) fn tile_for_test() -> Tile {
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

    #[test]
    fn the_report_entry_comes_only_where_seerr_offers_it_and_only_on_the_desktop_form() {
        let tile = super::round2_tests::tile_for_test();
        let cx = demo_cx(false);
        crate::desk::set_report_offered(false);
        assert!(!entries(Form::Desktop, &cx, Some(&tile)).contains(&Entry::Report));
        crate::desk::set_report_offered(true);
        let with = entries(Form::Desktop, &cx, Some(&tile));
        assert!(with.contains(&Entry::Report));
        assert!(!entries(Form::Touch, &cx, Some(&tile)).contains(&Entry::Report));
        assert_eq!(label(&Entry::Report, &cx, Some(&tile)), "Problem melden");
        // Picking it asks the suite to open the sheet for the tile's title, without a position.
        let mut keep = Vec::new();
        assert_eq!(run(&Entry::Report, &tile, &cx, &mut keep), Outcome::Nothing);
        assert_eq!(
            crate::desk::take_report_requests(),
            vec![("m1".to_owned(), None)]
        );
        crate::desk::set_report_offered(false);
    }

    #[test]
    fn the_delete_entry_comes_only_where_the_core_offers_it_and_picks_ask_the_suite() {
        let tile = super::round2_tests::tile_for_test();
        let cx = demo_cx(false);
        crate::desk::set_delete_offered(false);
        assert!(!entries(Form::Desktop, &cx, Some(&tile)).contains(&Entry::Delete));
        crate::desk::set_delete_offered(true);
        assert!(entries(Form::Desktop, &cx, Some(&tile)).contains(&Entry::Delete));
        assert!(!entries(Form::Touch, &cx, Some(&tile)).contains(&Entry::Delete));
        assert_eq!(
            label(&Entry::Delete, &cx, Some(&tile)),
            "Vom Server löschen"
        );
        assert_eq!(icon(&Entry::Delete, &cx), "trash");
        // A tile menu does not send the page back; the sheet is the only thing that opens.
        let mut keep = Vec::new();
        assert_eq!(run(&Entry::Delete, &tile, &cx, &mut keep), Outcome::Nothing);
        assert_eq!(
            crate::desk::take_delete_requests(),
            vec![("m1".to_owned(), false)]
        );
        crate::desk::set_delete_offered(false);
    }
}

/// One rule per entry, against `TileMenuMac.swift`: the entries, their order and their conditions on the desktop form.
#[cfg(test)]
mod mac_rule_tests {
    use super::*;

    fn tile(kind: &str, progress: Option<f32>, watched: bool, series_id: Option<&str>) -> Tile {
        Tile {
            id: "t1".into(),
            title: "Titel".into(),
            subtitle: None,
            progress,
            image: None,
            badges: if watched {
                vec![Badge::Watched]
            } else {
                Vec::new()
            },
            remaining: None,
            facts: swiftly_vm::TileFacts {
                kind: Some(kind.into()),
                series_id: series_id.map(Into::into),
                ..swiftly_vm::TileFacts::default()
            },
        }
    }

    /// The entries without the two that depend on a process-wide Seerr flag other tests set.
    fn list(cx: &Cx, t: &Tile) -> Vec<Entry> {
        entries(Form::Desktop, cx, Some(t))
            .into_iter()
            .filter(|e| !matches!(e, Entry::Report | Entry::Delete))
            .collect()
    }

    fn cx(cw: bool) -> Cx {
        let mut c = demo_cx(cw);
        c.host.download_button = false;
        c
    }

    #[test]
    fn a_film_in_weiterschauen_has_the_macs_entries_in_the_macs_order() {
        let t = tile("Movie", Some(0.4), false, None);
        assert_eq!(
            list(&cx(true), &t),
            vec![
                Entry::Play,
                Entry::FromStart,
                Entry::Overview,
                Entry::Remember,
                Entry::Watched,
                Entry::Unwatched,
                Entry::PlayOn,
                Entry::Together,
                Entry::Info,
                Entry::Remove,
            ]
        );
        assert_eq!(label(&Entry::Play, &cx(true), Some(&t)), "Fortsetzen");
    }

    #[test]
    fn overview_and_remove_come_only_from_the_weiterschauen_rail() {
        let t = tile("Movie", None, false, None);
        let rail = list(&cx(false), &t);
        assert!(!rail.contains(&Entry::Overview) && !rail.contains(&Entry::Remove));
        let cw = list(&cx(true), &t);
        assert!(cw.contains(&Entry::Overview) && cw.last() == Some(&Entry::Remove));
        // "Zur Übersicht" sits right after the play entries, "Aus Weiterschauen entfernen" is last.
        let at = |e: Entry| cw.iter().position(|x| *x == e).unwrap();
        assert_eq!(at(Entry::Overview), at(Entry::Play) + 1);
    }

    #[test]
    fn from_start_needs_a_begun_title_that_is_no_series() {
        assert!(!list(&cx(false), &tile("Movie", None, false, None)).contains(&Entry::FromStart));
        assert!(
            list(&cx(false), &tile("Episode", Some(0.2), false, Some("s")))
                .contains(&Entry::FromStart)
        );
        assert!(
            !list(&cx(false), &tile("Series", Some(0.2), false, None)).contains(&Entry::FromStart)
        );
    }

    #[test]
    fn watched_and_unwatched_are_offered_only_where_they_have_an_effect() {
        let fresh = list(&cx(false), &tile("Movie", None, false, None));
        assert!(fresh.contains(&Entry::Watched) && !fresh.contains(&Entry::Unwatched));
        let seen = list(&cx(false), &tile("Movie", None, true, None));
        assert!(!seen.contains(&Entry::Watched) && seen.contains(&Entry::Unwatched));
        // Begun counts as unwatched-able, a series carries both.
        let begun = list(&cx(false), &tile("Movie", Some(0.3), false, None));
        assert!(begun.contains(&Entry::Watched) && begun.contains(&Entry::Unwatched));
        let series = list(&cx(false), &tile("Series", None, true, None));
        assert!(series.contains(&Entry::Watched) && series.contains(&Entry::Unwatched));
    }

    #[test]
    fn remember_needs_the_watchlist_and_flips_its_wording() {
        let t = tile("Movie", None, false, None);
        let mut c = cx(false);
        assert!(list(&c, &t).contains(&Entry::Remember));
        assert_eq!(label(&Entry::Remember, &c, Some(&t)), "Merken");
        c.favourite = true;
        assert_eq!(label(&Entry::Remember, &c, Some(&t)), "Nicht mehr merken");
        c.watchlist_shown = false;
        assert!(!list(&c, &t).contains(&Entry::Remember));
    }

    #[test]
    fn play_on_needs_a_device_in_reach_and_no_series() {
        let t = tile("Movie", None, false, None);
        let mut c = cx(false);
        assert!(list(&c, &t).contains(&Entry::PlayOn));
        assert!(!list(&c, &tile("Series", None, false, None)).contains(&Entry::PlayOn));
        c.host.play_on.clear();
        assert!(!list(&c, &t).contains(&Entry::PlayOn));
    }

    #[test]
    fn watch_together_needs_the_right_and_no_series() {
        let t = tile("Episode", None, false, Some("s"));
        let mut c = cx(false);
        assert!(list(&c, &t).contains(&Entry::Together));
        assert!(!list(&c, &tile("Series", None, false, None)).contains(&Entry::Together));
        c.host.together = false;
        assert!(!list(&c, &t).contains(&Entry::Together));
    }

    #[test]
    fn to_series_is_for_an_episode_with_a_series_and_comes_before_info() {
        let ep = list(&cx(false), &tile("Episode", None, false, Some("s")));
        let at = |e: Entry| ep.iter().position(|x| *x == e).unwrap();
        assert_eq!(at(Entry::ToSeries) + 1, at(Entry::Info));
        assert!(!list(&cx(false), &tile("Episode", None, false, None)).contains(&Entry::ToSeries));
        assert!(
            !list(&cx(false), &tile("Movie", None, false, Some("s"))).contains(&Entry::ToSeries)
        );
        assert!(!list(&cx(false), &tile("Series", None, false, None)).contains(&Entry::ToSeries));
    }

    #[test]
    fn the_player_menu_has_only_the_watched_entries() {
        let mut c = cx(false);
        c.host.in_player = true;
        let t = tile("Episode", Some(0.5), false, Some("s"));
        assert_eq!(list(&c, &t), vec![Entry::Watched, Entry::Unwatched]);
    }

    #[test]
    fn other_kinds_get_no_menu() {
        assert!(
            entries(
                Form::Desktop,
                &cx(false),
                Some(&tile("Person", None, false, None))
            )
            .is_empty()
        );
    }

    #[test]
    fn the_picks_navigate_remove_or_hand_off() {
        let t = tile("Episode", None, false, Some("s"));
        let c = cx(true);
        let mut keep = Vec::new();
        // "Zur Serie", "Zur Übersicht" and "Info" open the page (an episode leads to its series).
        for e in [Entry::ToSeries, Entry::Overview, Entry::Info] {
            assert_eq!(run(&e, &t, &c, &mut keep), Outcome::Open);
        }
        // "Abspielen" starts from the resume point.
        assert!(matches!(run(&Entry::Play, &t, &c, &mut keep), Outcome::Play(r) if r.since < 0.0));
    }

    #[test]
    fn the_shortcuts_are_the_macs_with_ctrl() {
        let t = tile("Movie", Some(0.3), false, None);
        let c = cx(true);
        let rows = crate::desk::tile_rows(&list(&c, &t), &t, &c, "x");
        let shortcut = |label: &str| {
            rows.iter().find_map(|r| match r {
                swiftly_ui::popover::MenuEntry::Item(i) if i.label == label => {
                    Some(i.shortcut.clone())
                }
                _ => None,
            })
        };
        assert!(shortcut("Fortsetzen").flatten().is_some());
        assert!(shortcut("Merken").flatten().is_some());
        assert!(shortcut("Als gesehen markieren").flatten().is_some());
        assert!(shortcut("Info").flatten().is_some());
        assert_eq!(shortcut("Zur Übersicht"), Some(None));
    }

    #[test]
    fn the_shortcut_commands_stand_for_the_macs_rows() {
        assert_eq!(shortcut_entry("tile.remember"), Some(Entry::Remember));
        assert_eq!(shortcut_entry("tile.watched"), Some(Entry::Watched));
        assert_eq!(shortcut_entry("tile.info"), Some(Entry::Info));
        assert_eq!(shortcut_entry("cmd.back"), None);
    }

    #[test]
    fn a_shortcut_chooses_its_row_of_the_open_menu_once() {
        use swiftly_layout::Point;
        let t = tile("Movie", None, false, None);
        let c = cx(false);
        let mut menu = crate::desk::TileMenu::default();
        // Closed: nothing happens.
        assert_eq!(menu.pick_entry(&Entry::Info), None);
        assert!(menu.open(&t, &c, Point::new(10.0, 10.0), false));
        let want = entries(Form::Desktop, &c, Some(&t))
            .iter()
            .position(|e| *e == Entry::Info)
            .unwrap();
        assert_eq!(
            menu.pick_entry(&Entry::Info),
            Some(crate::desk::Pick::Row("t1".into(), want))
        );
        // The pick closed it; a second press does nothing.
        assert!(!menu.is_open());
        assert_eq!(menu.pick_entry(&Entry::Info), None);
        // A row the menu does not have: no pick, the menu stays.
        assert!(menu.open(&t, &c, Point::new(10.0, 10.0), false));
        assert_eq!(menu.pick_entry(&Entry::Remove), None);
        assert!(menu.is_open());
    }
}

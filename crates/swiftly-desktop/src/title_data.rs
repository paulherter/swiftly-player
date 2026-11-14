//! The scripted servers behind `--demo detail` and `--demo series`: a `MockTransport` that answers the title requests
//! from generated Jellyfin JSON, with a `DetailVm` / `SeriesVm` over it. No network is touched.

use crate::home_data::{Scenario, account};
use futures_executor::ThreadPool;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_l10n::Locale;
use swiftly_library::MemoryStore;
use swiftly_model::Item;
use swiftly_net::{ErrorKind, MockTransport};
use swiftly_vm::{
    Clock, DetailIntent, DetailOptions, DetailVm, EpisodesStatus, Host, SeriesIntent, SeriesSpec,
    SeriesVm, Spawner,
};

struct Pool(ThreadPool);

impl Spawner for Pool {
    fn spawn(&self, task: Pin<Box<dyn Future<Output = ()> + Send>>) {
        self.0.spawn_ok(task);
    }
}

struct FixedClock;

impl Clock for FixedClock {
    fn now(&self) -> f64 {
        1000.0
    }
}

fn host() -> Host {
    let pool = ThreadPool::builder().pool_size(2).create();
    Host {
        spawner: Arc::new(Pool(pool.unwrap_or_else(|e| panic!("thread pool: {e}")))),
        clock: Arc::new(FixedClock),
        store: Arc::new(MemoryStore::new()),
        locale: Locale::parse("de"),
        device_name: "Demo".into(),
        client_version: "0.0.0".into(),
        cache: None,
    }
}

const OVERVIEW: &str = "Als im Hafen von Nordlicht ein altes Schiff ohne Besatzung anlegt, beginnt für die Lotsin Mara eine Suche, die sie weiter von zu Hause wegführt, als sie wollte. Je mehr sie über die Ladung erfährt, desto weniger weiß sie, wem sie trauen kann.";

fn people() -> String {
    let names = [
        ("Mara Brandt", "Lotsin"),
        ("Jonas Keller", "Kapitän"),
        ("Ilse Vogel", "Hafenmeisterin"),
        ("Tom Albers", "Zöllner"),
        ("Nina Sommer", "Reporterin"),
        ("Paul Rath", "Matrose"),
        ("Eva Lund", "Ärztin"),
    ];
    let mut all: Vec<String> = names
        .iter()
        .enumerate()
        .map(|(i, (n, r))| {
            format!(r#"{{"Id":"p{i}","Name":"{n}","Type":"Actor","Role":"{r}","PrimaryImageTag":"t{i}"}}"#)
        })
        .collect();
    all.push(r#"{"Id":"d1","Name":"Anna Weiß","Type":"Director"}"#.into());
    all.join(",")
}

fn film_for(sources: bool, id: &str, name: &str) -> String {
    let media = if sources {
        r#","MediaSources":[{"Id":"s4k","Name":"4K","Container":"mkv","Size":8400000000,"SupportsDirectPlay":true,"SupportsDirectStream":true,"MediaStreams":[{"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"BitRate":24000000,"RealFrameRate":24.0,"VideoRange":"HDR","Index":0},{"Type":"Audio","Codec":"eac3","Channels":6,"Language":"deu","Index":1,"DisplayTitle":"Deutsch - EAC3 - 5.1"},{"Type":"Audio","Codec":"aac","Channels":2,"Language":"eng","Index":2,"DisplayTitle":"English - AAC - Stereo"},{"Type":"Subtitle","Codec":"subrip","Language":"deu","Index":3}]},{"Id":"s1080","Name":"1080p","Container":"mp4","Size":3100000000,"SupportsDirectPlay":true,"MediaStreams":[]}]"#
    } else {
        ""
    };
    format!(
        r#"{{"Id":"{id}","Name":"{name}","Type":"Movie","ProductionYear":2021,"RunTimeTicks":54000000000,"Genres":["Drama","Krimi"],"Overview":"{OVERVIEW}","CommunityRating":7.5,"OfficialRating":"12","ImageTags":{{"Primary":"p"}},"BackdropImageTags":["b"],"People":[{}],"UserData":{{"PlaybackPositionTicks":19200000000,"PlayedPercentage":35.5,"Played":false,"IsFavorite":false}}{media}}}"#,
        people()
    )
}

fn movie(i: usize) -> String {
    let names = [
        "Sommerregen",
        "Die Brücke",
        "Stilles Wasser",
        "Letzte Ausfahrt",
        "Papierschiffe",
        "Winterlicht",
        "Fremde Küste",
        "Nachtzug",
    ];
    format!(
        r#"{{"Id":"o{i}","Name":"{}","Type":"Movie","ProductionYear":{},"RunTimeTicks":54000000000,"ImageTags":{{"Primary":"p{i}"}},"UserData":{{"Played":false}}}}"#,
        names[i % names.len()],
        2012 + i
    )
}

fn list(items: &[String]) -> String {
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{}}}"#,
        items.join(","),
        items.len()
    )
}

fn detail_transport(s: Scenario, id: &str, name: &str) -> MockTransport {
    let own = format!("/Items/{id}");
    if s == Scenario::Offline {
        return [
            own.as_str(),
            "/Similar",
            "/SpecialFeatures",
            "PlaybackInfo",
            "/Items",
        ]
        .iter()
        .fold(MockTransport::new(), |m, p| {
            m.route_error(p, ErrorKind::Network { code: -1009 })
        });
    }
    let similar: Vec<String> = if s == Scenario::Empty {
        vec![]
    } else {
        (0..8).map(movie).collect()
    };
    let similar = if s == Scenario::Worst {
        vec![crate::browse::worstify(&similar.join(","))]
    } else {
        similar
    };
    let plan = r#"{"PlaySessionId":"x","MediaSources":[{"Id":"s4k","Name":"4K","Container":"mkv","SupportsDirectPlay":true,"SupportsDirectStream":true,"MediaStreams":[{"Type":"Video","Codec":"hevc","Index":0}]}]}"#;
    MockTransport::new()
        .route(&own, 200, &film_for(true, id, name))
        .route("/Similar", 200, &list(&similar))
        .route("/SpecialFeatures", 200, "[{\"Id\":\"x1\",\"Name\":\"Making of\",\"Type\":\"Video\",\"RunTimeTicks\":9000000000},{\"Id\":\"x2\",\"Name\":\"Geschnittene Szenen\",\"Type\":\"Video\",\"RunTimeTicks\":6000000000}]")
        .route("PlaybackInfo", 200, plan)
        .route("/Items", 200, &list(&[]))
}

/// The list entry the detail page is opened with (no sources: Play is gray until the fresh title is here).
pub fn detail_entry() -> Item {
    detail_entry_for("m1", "Nordlicht")
}

/// The list entry of the tapped tile: the scripted title under its id and name.
pub fn detail_entry_for(id: &str, name: &str) -> Item {
    serde_json::from_str(&film_for(false, id, name)).unwrap_or_else(|e| panic!("entry: {e}"))
}

/// What the Mac tells the film page (`DetailCore.send(options:)`): the settings, the account's right, what a browser
/// can open. No devices are in reach and watching together is not offered on the desktop yet, so the core leaves
/// those menu entries out.
pub fn live_detail_options(w: &crate::live::Wiring) -> DetailOptions {
    DetailOptions {
        watchers_shown: w.watchers_shown(),
        download_button: w.download_button(),
        can_open_web: true,
        // The devices in reach and watching together: the More menu offers "Abspielen auf ..." and "Gemeinsam schauen".
        menu: swiftly_vm::MenuContext {
            download_button: w.download_button(),
            ..crate::tile_menu::live_host(w, false)
        },
        ..DetailOptions::default()
    }
}

/// What the Mac tells the series page (`SeriesCore.send(options:)`).
pub fn live_series_options(w: &crate::live::Wiring) -> swiftly_vm::SeriesOptions {
    let host = crate::tile_menu::live_host(w, false);
    swiftly_vm::SeriesOptions {
        download_button: w.download_button(),
        can_open_web: true,
        watchers_shown: w.watchers_shown(),
        together: host.together,
        play_on: host.play_on,
        ..swiftly_vm::SeriesOptions::default()
    }
}

/// A `DetailVm` over the scripted server. Loaded when this returns, except for `Loading` (not asked).
///
/// # Panics
/// If the view model cannot be built or does not settle within ten seconds.
pub fn detail_vm(s: Scenario) -> DetailVm<crate::net::AppTransport> {
    detail_vm_for(s, "m1", "Nordlicht")
}

/// A `DetailVm` for the tapped tile (`id`, `name`) over the scripted server.
///
/// # Panics
/// As `detail_vm`.
pub fn detail_vm_for(s: Scenario, id: &str, name: &str) -> DetailVm<crate::net::AppTransport> {
    if let Some(w) = crate::live::current() {
        let vm = DetailVm::new(
            Arc::clone(&w.core.net),
            w.core.host(),
            w.stand_in(id, name),
            Some(w.account.clone()),
        )
        .unwrap_or_else(|e| panic!("detail vm: {e:?}"));
        w.ask_download_right();
        vm.send(DetailIntent::Options(Box::new(live_detail_options(&w))));
        vm.send(DetailIntent::Load);
        return vm;
    }
    let vm = DetailVm::new(
        Arc::new(crate::net::AppTransport::Mock(detail_transport(
            s, id, name,
        ))),
        host(),
        detail_entry_for(id, name),
        Some(account()),
    )
    .unwrap_or_else(|e| panic!("detail vm: {e:?}"));
    vm.send(DetailIntent::Options(Box::new(DetailOptions {
        watchers_shown: false,
        download_button: true,
        can_open_web: true,
        ..DetailOptions::default()
    })));
    if s != Scenario::Loading {
        vm.send(DetailIntent::Load);
        let t = Instant::now();
        while !vm.bottom().ready {
            assert!(
                t.elapsed() < Duration::from_secs(10),
                "detail vm did not settle"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    vm
}

fn season(n: usize) -> String {
    format!(
        r#"{{"Id":"se{n}","Name":"Staffel {n}","Type":"Season","IndexNumber":{n},"SeriesId":"ser"}}"#
    )
}

fn episode(n: usize) -> String {
    let user = match n {
        1 | 2 => r#""UserData":{"Played":true}"#.to_owned(),
        3 => r#""UserData":{"PlaybackPositionTicks":9000000000,"PlayedPercentage":42.0,"Played":false}"#.to_owned(),
        _ => r#""UserData":{"Played":false}"#.to_owned(),
    };
    let names = [
        "Ankunft",
        "Das Schiff",
        "Ladung",
        "Nebel",
        "Verrat",
        "Gezeiten",
        "Landgang",
        "Der letzte Hafen",
    ];
    format!(
        r#"{{"Id":"e{n}","Name":"{}","Type":"Episode","IndexNumber":{n},"ParentIndexNumber":1,"SeasonId":"se1","SeriesId":"ser","Overview":"Mara folgt einer Spur, die im Nebel endet.","RunTimeTicks":27000000000,"ImageTags":{{"Primary":"p{n}"}},{user}}}"#,
        names[(n - 1) % names.len()]
    )
}

fn series_transport(s: Scenario) -> MockTransport {
    if s == Scenario::Offline {
        return [
            "Seasons",
            "Episodes",
            "Shows/NextUp",
            "/Items/ser",
            "/Similar",
            "/SpecialFeatures",
        ]
        .iter()
        .fold(MockTransport::new(), |m, p| {
            m.route_error(p, ErrorKind::Network { code: -1009 })
        });
    }
    let seasons: Vec<String> = (1..=3).map(season).collect();
    let eps: Vec<String> = if s == Scenario::Empty {
        vec![]
    } else {
        (1..=8).map(episode).collect()
    };
    let next = vec![episode(3)];
    let ser = format!(
        r#"{{"Id":"ser","Name":"Nordlicht","Type":"Series","ProductionYear":2021,"Genres":["Drama","Krimi"],"Overview":"{OVERVIEW}","CommunityRating":8.1,"OfficialRating":"12","ChildCount":3,"ImageTags":{{"Primary":"p"}},"BackdropImageTags":["b"],"People":[{}],"UserData":{{"UnplayedItemCount":6,"Played":false,"IsFavorite":true}}}}"#,
        people()
    );
    let similar: Vec<String> = (0..6).map(movie).collect();
    let (ser, similar) = if s == Scenario::Worst {
        (
            ser.replace("Nordlicht", crate::browse::worst_title(0)),
            vec![crate::browse::worstify(&similar.join(","))],
        )
    } else {
        (ser, similar)
    };
    MockTransport::new()
        .route("/Items/ser", 200, &ser)
        .route("Shows/NextUp", 200, &list(&next))
        .route("Shows/ser/Seasons", 200, &list(&seasons))
        .route("Shows/ser/Episodes", 200, &list(&eps))
        .route("/Similar", 200, &list(&similar))
        .route("/SpecialFeatures", 200, "[]")
        .route("/Items", 200, &list(&[]))
}

/// The series list entry.
pub fn series_entry() -> Item {
    serde_json::from_str(r#"{"Id":"ser","Name":"Nordlicht","Type":"Series","ProductionYear":2021,"ImageTags":{"Primary":"p"},"UserData":{"UnplayedItemCount":6,"Played":false,"IsFavorite":true}}"#)
        .unwrap_or_else(|e| panic!("entry: {e}"))
}

/// A `SeriesVm` over the scripted server (loaded when this returns, except for `Loading`).
///
/// # Panics
/// If the view model cannot be built or does not settle within ten seconds.
pub fn series_vm(s: Scenario) -> SeriesVm<crate::net::AppTransport> {
    if let Some(w) = crate::live::current() {
        let (id, name) = w.last_title.borrow().clone();
        let vm = SeriesVm::new(
            Arc::clone(&w.core.net),
            w.core.host(),
            w.stand_in(&id, &name),
            w.next_spec.borrow().clone(),
            Some(w.account.clone()),
        )
        .unwrap_or_else(|e| panic!("series vm: {e:?}"));
        w.ask_download_right();
        vm.send(SeriesIntent::Options(live_series_options(&w)));
        vm.send(SeriesIntent::Load);
        return vm;
    }
    let vm = SeriesVm::new(
        Arc::new(crate::net::AppTransport::Mock(series_transport(s))),
        host(),
        series_entry(),
        SeriesSpec::default(),
        Some(account()),
    )
    .unwrap_or_else(|e| panic!("series vm: {e:?}"));
    if s != Scenario::Loading {
        vm.send(SeriesIntent::Load);
        let t = Instant::now();
        while vm.episodes().status == EpisodesStatus::Loading || !vm.button().label_ready {
            assert!(
                t.elapsed() < Duration::from_secs(10),
                "series vm did not settle"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    vm
}

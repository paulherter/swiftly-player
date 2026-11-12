//! The scripted server behind `--demo home`: a `MockTransport` that answers the start page requests from generated
//! Jellyfin JSON, and a `HomeVm` over it. No network is touched.

use futures_executor::ThreadPool;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_jellyfin::ServerKind;
use swiftly_l10n::Locale;
use swiftly_library::MemoryStore;
use swiftly_net::{ErrorKind, MockTransport};
use swiftly_vm::{AccountRef, Clock, HomeIntent, HomePrefs, HomeVm, Host, Spawner, Status};

/// The address the offline state names.
pub const SERVER: &str = "tv.example.test";

/// What the scripted server does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scenario {
    /// Answers with the catalogue (the view model has loaded when it is handed out).
    Ready,
    /// Not asked yet: the status stays `Loading`.
    Loading,
    /// Every request fails: the status ends as `Offline` with no rails.
    Offline,
    /// The server answers with nothing: ready and empty.
    Empty,
    /// Worst-case names and missing posters (`break-ui`).
    Worst,
}

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

const TITLES: [&str; 14] = [
    "Nordlicht",
    "Sommerregen",
    "Die Brücke",
    "Der Weg zurück",
    "Stilles Wasser",
    "Letzte Ausfahrt",
    "Papierschiffe",
    "Das andere Ufer",
    "Winterlicht",
    "Halbe Wahrheit",
    "Ein ruhiger Ort",
    "Fremde Küste",
    "Goldener Herbst",
    "Nachtzug",
];

fn movie(i: usize, resume: bool) -> String {
    let name = TITLES[i % TITLES.len()];
    let user = match i % 5 {
        1 => r#""UserData":{"Played":true,"IsFavorite":true}"#.to_owned(),
        2 => r#""UserData":{"Played":true}"#.to_owned(),
        _ if resume => format!(
            r#""UserData":{{"PlaybackPositionTicks":{},"PlayedPercentage":{}.0,"Played":false}}"#,
            (i as u64 + 2) * 3_000_000_000_u64,
            20 + (i * 13) % 60
        ),
        _ => r#""UserData":{"Played":false}"#.to_owned(),
    };
    format!(
        r#"{{"Id":"m{i}","Name":"{name}","Type":"Movie","ProductionYear":{},"RunTimeTicks":54000000000,"ImageTags":{{"Primary":"p-m{i}"}},"BackdropImageTags":["b-m{i}"],{user}}}"#,
        2015 + i % 10
    )
}

fn episode(i: usize) -> String {
    format!(
        r#"{{"Id":"e{i}","Name":"Folge {i}","Type":"Episode","SeriesId":"s{i}","SeriesName":"{}","ParentIndexNumber":{},"IndexNumber":{},"RunTimeTicks":27000000000,"ImageTags":{{"Primary":"p-e{i}"}},"BackdropImageTags":["b-e{i}"],"UserData":{{"PlaybackPositionTicks":{},"PlayedPercentage":{}.0,"Played":false}}}}"#,
        TITLES[(i + 5) % TITLES.len()],
        1 + i % 3,
        2 + i,
        (i as u64 + 1) * 2_000_000_000_u64,
        15 + (i * 17) % 70
    )
}

fn series(i: usize) -> String {
    format!(
        r#"{{"Id":"s{i}","Name":"{}","Type":"Series","ProductionYear":{},"ChildCount":3,"ImageTags":{{"Primary":"p-s{i}"}},"UserData":{{"UnplayedItemCount":{},"Played":false}}}}"#,
        TITLES[(i + 7) % TITLES.len()],
        2018 + i % 6,
        1 + i % 9
    )
}

fn list(items: &[String]) -> String {
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{}}}"#,
        items.join(","),
        items.len()
    )
}

fn transport(scenario: Scenario) -> MockTransport {
    let views = r#"{"Items":[{"Id":"lib-movies","Name":"Filme","Type":"CollectionFolder","CollectionType":"movies"},{"Id":"lib-shows","Name":"Serien","Type":"CollectionFolder","CollectionType":"tvshows"}],"TotalRecordCount":2}"#;
    match scenario {
        Scenario::Offline => ["UserViews", "UserItems/Resume", "Shows/NextUp", "/Items"]
            .iter()
            .fold(MockTransport::new(), |m, p| {
                m.route_error(p, ErrorKind::Network { code: -1009 })
            }),
        Scenario::Empty => MockTransport::new()
            .route("UserViews", 200, views)
            .route("UserItems/Resume", 200, &list(&[]))
            .route("Shows/NextUp", 200, &list(&[]))
            .route("/Items", 200, &list(&[])),
        _ => {
            let worst = scenario == Scenario::Worst;
            let w = |j: String| {
                if worst {
                    crate::browse::worstify(&j)
                } else {
                    j
                }
            };
            let resume: Vec<String> = (0..2)
                .map(|i| movie(3 + i * 5, true))
                .chain((0..3).map(|i| episode(i + 1)))
                .chain((0..3).map(|i| movie(i * 4 + 4, true)))
                .collect();
            let next: Vec<String> = (4..9).map(episode).collect();
            let recent: Vec<String> = (0..14)
                .map(|i| {
                    if i % 4 == 3 {
                        series(i)
                    } else {
                        movie(i, false)
                    }
                })
                .collect();
            MockTransport::new()
                .route("UserViews", 200, views)
                .route("UserItems/Resume", 200, &w(list(&resume)))
                .route("Shows/NextUp", 200, &w(list(&next)))
                .route("/Items", 200, &w(list(&recent)))
        }
    }
}

/// The account the demo signs in with.
pub fn account() -> AccountRef {
    AccountRef {
        base_url: format!("https://{SERVER}"),
        user_id: "demo-user".into(),
        token: "DEMO".into(),
        server_kind: ServerKind::Jellyfin,
        device_id: "demo-device".into(),
        plex_machine_id: None,
        plex_account_token: None,
    }
}

/// A `HomeVm` over the scripted server. For every scenario but `Loading` the load has finished when this returns
/// (`Ready`: confirmed by the server, `Offline`: failed).
///
/// # Panics
/// If the view model cannot be built or does not settle within ten seconds.
pub fn home_vm(scenario: Scenario) -> HomeVm<crate::net::AppTransport> {
    if let Some(w) = crate::live::current() {
        let vm = HomeVm::new(
            Arc::clone(&w.core.net),
            w.core.host(),
            live_prefs(&w),
            Some(w.account.clone()),
        )
        .unwrap_or_else(|e| panic!("home vm: {e:?}"));
        vm.set_start_libraries(live_libraries(&w));
        return vm;
    }
    let pool = ThreadPool::builder().pool_size(2).create();
    let host = Host {
        spawner: Arc::new(Pool(pool.unwrap_or_else(|e| panic!("thread pool: {e}")))),
        clock: Arc::new(FixedClock),
        store: Arc::new(MemoryStore::new()),
        locale: Locale::parse("de"),
        device_name: "Demo".into(),
        client_version: "0.0.0".into(),
        cache: None,
    };
    let vm = HomeVm::new(
        Arc::new(crate::net::AppTransport::Mock(transport(scenario))),
        host,
        HomePrefs::default(),
        Some(account()),
    )
    .unwrap_or_else(|e| panic!("home vm: {e:?}"));
    if scenario != Scenario::Loading {
        vm.send(HomeIntent::Load);
        wait_settled(&vm);
    }
    vm
}

/// Polls until the load of the vm has ended (ready, or offline).
pub fn wait_settled(vm: &HomeVm<crate::net::AppTransport>) {
    let started = Instant::now();
    loop {
        let s = vm.status();
        if matches!(s.status, Status::Ready | Status::Offline) && !s.preview && !s.refreshing {
            return;
        }
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "home vm did not settle: {s:?}"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// The Start page settings of the stored account: genre chips and the chosen genres.
fn live_prefs(w: &crate::live::Wiring) -> HomePrefs {
    use swiftly_settings::{KeyValueStore, Value};
    let store = &w.core.settings;
    let chips = matches!(store.get("genreChips"), Some(Value::Bool(true)));
    let genres = match store.get("startGenres") {
        Some(Value::StrList(g)) => g,
        _ => Vec::new(),
    };
    HomePrefs {
        genre_chips: chips,
        start_genres: genres,
        ..HomePrefs::default()
    }
}

/// The chosen libraries and collections of this server (`startBibliotheken` is stored per server as `<key>|<server>`).
fn live_libraries(w: &crate::live::Wiring) -> Vec<swiftly_library::start_libraries::StartLibrary> {
    use swiftly_settings::{KeyValueStore, Value, key::server_key};
    // Per server: the address for Jellyfin and Emby, `plex:<machine id>` for Plex (a Plex address can change).
    let suffix = w.core.active_entry().map_or_else(
        || w.account.base_url.clone(),
        |e| e.suffix.trim_start_matches('|').to_owned(),
    );
    let chosen = match w
        .core
        .settings
        .get(&server_key("startBibliotheken", &suffix))
    {
        Some(Value::Data(d)) => Some(d),
        _ => None,
    };
    swiftly_library::start_libraries::StartLibraries::read(chosen.as_deref())
}

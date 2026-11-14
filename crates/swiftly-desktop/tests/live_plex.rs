//! A stored Plex account in the live app: the core picks the Plex client from the account's kind, so Home, a library
//! page, the library list and the play plan load from a scripted Plex server (no Jellyfin request goes out).

use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_accounts::{Account, AccountBundle, ServerBundles, save_bundles};
use swiftly_desktop::home_data::{self, Scenario};
use swiftly_desktop::live::{self, Core, Wiring};
use swiftly_desktop::live_play::PlayRequest;
use swiftly_jellyfin::ServerKind;
use swiftly_library::{ShelfSource, library_filter::Sorting};
use swiftly_net::MockTransport;
use swiftly_vm::{HomeIntent, LibraryIntent, LibrarySpec, LibraryStatus, LibraryVm, RailKind};

const SECTIONS: &str = include_str!("../../swiftly-plex/tests/fixtures/sections.json");
const PAGE: &str = include_str!("../../swiftly-plex/tests/fixtures/page.json");
const MOVIE: &str = include_str!("../../swiftly-plex/tests/fixtures/movie.json");

/// A Plex server that answers the start page, the library list, a library page and one movie.
fn plex() -> MockTransport {
    MockTransport::new()
        .route("/hubs/continueWatching/items", 200, PAGE)
        .route("/library/onDeck", 200, PAGE)
        .route("/library/sections", 200, SECTIONS)
        .route("/recentlyAdded", 200, PAGE)
        .route("/all", 200, PAGE)
        .route("/library/metadata/1", 200, MOVIE)
}

#[allow(clippy::expect_used)]
fn stored_plex_account() -> Account {
    let mut a = Account::new(swiftly_jellyfin::Session {
        access_token: "SERVER-TOKEN".into(),
        user_id: "u1".into(),
        user_name: "Anna".into(),
        server_url: "https://plex.example.test".into(),
        kind: ServerKind::Plex,
    });
    a.plex = Some(
        serde_json::from_value(serde_json::json!({ "machineIdentifier": "machine-1", "serverName": "Home", "accountToken": "ACCOUNT-TOKEN" })).expect("plex block"),
    );
    a
}

fn seen(core: &Core) -> Vec<swiftly_net::HttpRequest> {
    match &*core.net {
        swiftly_desktop::net::AppTransport::Mock(m) => m.requests(),
        _ => Vec::new(),
    }
}

fn wait<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let t = Instant::now();
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(
            t.elapsed() < Duration::from_secs(10),
            "{what} did not happen"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_stored_plex_account_loads_home_library_and_plan() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir = std::env::temp_dir().join(format!("swiftly-live-plex-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let me = std::env::current_exe().expect("exe");
        let out = std::process::Command::new(me)
            .args([
                "--exact",
                "a_stored_plex_account_loads_home_library_and_plan",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .expect("child");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            out.status.success(),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let mock = plex();
    let core = Arc::new(Core::open_with(Some(mock)).expect("core"));
    save_bundles(
        &*core.secrets,
        &ServerBundles::new(
            vec![(ServerKind::Plex, AccountBundle::new(stored_plex_account()))],
            ServerKind::Plex,
        ),
    );
    let account = core.account().expect("stored account");
    assert_eq!(account.server_kind, ServerKind::Plex);
    assert_eq!(account.token, "SERVER-TOKEN");
    assert_eq!(
        core.active_entry().map(|e| e.suffix),
        Some("|plex:machine-1".to_owned())
    );

    let cx = swiftly_ui::Cx::deterministic();
    let device = swiftly_images::Device::Mac;
    let loader = swiftly_images::ImageLoader::new(Arc::clone(&core.net), None, device);
    let hub = swiftly_desktop::hub::ImageHub::new(Box::new(loader), &cx, 1.0, device);
    let w = Rc::new(Wiring::new(Arc::clone(&core), account.clone(), hub));
    live::install(Some(Rc::clone(&w)));

    // Home: the rails come from the Plex hubs; the broken entry without a key is dropped.
    let home = home_data::home_vm(Scenario::Ready);
    home.send(HomeIntent::Load);
    home_data::wait_settled(&home);
    let rails = home.rails();
    let resume = rails.rails.first().expect("a rail");
    assert_eq!(resume.kind, RailKind::ContinueWatching);
    assert_eq!(
        resume
            .tiles
            .iter()
            .map(|t| t.title.as_str())
            .collect::<Vec<_>>(),
        ["One", "Two"]
    );
    assert!(
        seen(&core)
            .iter()
            .all(|r| !r.url.path().contains("/UserItems/") && !r.url.path().contains("/UserViews")),
        "no Jellyfin request"
    );

    // Library: a page of tiles, as the Movies tab builds it.
    let lib = LibraryVm::new(
        Arc::clone(&core.net),
        core.host(),
        Arc::clone(&core.kv),
        LibrarySpec {
            source: ShelfSource::new(Some("1"), Some("movies"), false, &[]),
            genre: None,
            remember_name: None,
        },
        Some(account.clone()),
    )
    .expect("library vm");
    lib.send(LibraryIntent::SetSorting {
        sorting: Sorting::Latest,
    });
    wait("library page", || {
        (lib.status().status == LibraryStatus::Ready).then_some(())
    });
    assert_eq!(
        lib.grid()
            .tiles
            .iter()
            .map(|t| t.title.as_str())
            .collect::<Vec<_>>(),
        ["One", "Two"]
    );

    // The libraries of the account (chips of the Library tabs) through the same facade.
    let server = core.server_for(&account).expect("plex client");
    assert_eq!(server.kind(), ServerKind::Plex);
    let (tx, rx) = std::sync::mpsc::channel();
    core.spawn(async move {
        let _ = tx.send(
            swiftly_desktop::live_server::views_and_shares(&server)
                .await
                .map(|(v, _)| v.into_iter().map(|i| i.name).collect::<Vec<_>>()),
        );
    });
    let names = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("answer")
        .expect("libraries");
    assert!(
        names.iter().any(|n| n == "Filme") && names.iter().any(|n| n == "Serien"),
        "{names:?}"
    );

    // Playback: the Plex plan with a direct file address that carries the server token.
    let prepared = core
        .prepare_play(
            &account,
            PlayRequest {
                item_id: "1".into(),
                since: 0.0,
                source_id: None,
            },
        )
        .0
        .recv_timeout(Duration::from_secs(10))
        .expect("plan answer");
    assert!(prepared.is_ok(), "plan: {:?}", prepared.err());
    live::install(None);
}

/// The season sheet of a Plex series reads its seasons and episodes through the core's server path: Plex `children`
/// requests, no Jellyfin `Shows/...` call.
#[test]
#[allow(clippy::expect_used)]
fn the_season_sheet_of_a_plex_series_reads_plex_children() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir =
            std::env::temp_dir().join(format!("swiftly-live-plex-seasons-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let me = std::env::current_exe().expect("exe");
        let out = std::process::Command::new(me)
            .args([
                "--exact",
                "the_season_sheet_of_a_plex_series_reads_plex_children",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .expect("child");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            out.status.success(),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let seasons = r#"{"MediaContainer":{"Metadata":[{"ratingKey":"31","type":"season","title":"Season 1","index":1,"parentRatingKey":"3","leafCount":2}]}}"#;
    let mock = plex()
        .route("/library/metadata/3/children", 200, seasons)
        .route("/library/metadata/31/children", 200, PAGE);
    let core = Arc::new(Core::open_with(Some(mock)).expect("core"));
    save_bundles(
        &*core.secrets,
        &ServerBundles::new(
            vec![(ServerKind::Plex, AccountBundle::new(stored_plex_account()))],
            ServerKind::Plex,
        ),
    );
    let account = core.account().expect("stored account");
    let mut read =
        swiftly_desktop::live_downloads::season_read(&core, &account, "3", "Test Show", None)
            .expect("read");
    wait("season sheet", || read.poll(false, &[]).open.map(|_| ()));
    let paths: Vec<String> = seen(&core).iter().map(|r| r.url.to_string()).collect();
    assert!(
        paths
            .iter()
            .any(|u| u.contains("/library/metadata/3/children")),
        "{paths:?}"
    );
    assert!(paths.iter().all(|u| !u.contains("/Shows/")), "{paths:?}");
}

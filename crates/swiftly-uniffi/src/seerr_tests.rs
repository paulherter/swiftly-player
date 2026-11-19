//! The Seerr screens end to end over a fake server that answers with the shapes of the fixture
//! (`xtask/src/fixture_seerr.rs`): Küstenwache (tv 7777, tmdb) with Staffel 2 in the library, 3
//! downloading, 4 waiting, 5 free; films with every state; a stateful request / quota / delete.

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use swiftly_vm::{
    BadgeKind, DeletePhase, ListLoad, PrimaryKind, RequestPill, SheetPhase, StepState, TitleLoad,
};

use crate::seerr::{SeerrConnection, SeerrModel};
use crate::seerr_admin_screen::SeerrAdminScreen;
use crate::seerr_lists_screen::{
    LibraryFailure, SeerrHub, SeerrLibrary, SeerrListsScreen, SeerrMenuKind,
};
use crate::seerr_title_screen::{SeerrRequestResult, SeerrTitleScreen};
use crate::transport::{
    CoreTransport, HttpClient, HttpFailure, NetMethod, NetRequest, NetResponse,
};

const USER: i64 = 32 | 262_144 | 524_288 | 4_194_304 | 2_097_152;
const ADMIN: i64 = 2;

struct World {
    perms: AtomicI64,
    tv_used: AtomicI64,
    requested5: AtomicBool,
    post_status: AtomicI64,
    post_message: &'static str,
    offline: AtomicBool,
    /// The connection drops right after a request was deleted (the next read finds Seerr out).
    cut_after_delete: AtomicBool,
    /// Every answer comes this many milliseconds late (a Seerr far away).
    latency_ms: AtomicU64,
    log: Mutex<Vec<String>>,
}

impl World {
    fn new(perms: i64) -> Arc<Self> {
        Arc::new(Self {
            perms: AtomicI64::new(perms),
            tv_used: AtomicI64::new(2),
            requested5: AtomicBool::new(false),
            post_status: AtomicI64::new(0),
            post_message: "",
            offline: AtomicBool::new(false),
            cut_after_delete: AtomicBool::new(false),
            latency_ms: AtomicU64::new(0),
            log: Mutex::new(Vec::new()),
        })
    }
    fn calls(&self, needle: &str) -> usize {
        self.log
            .lock()
            .unwrap()
            .iter()
            .filter(|l| l.contains(needle))
            .count()
    }
    fn tv(&self) -> String {
        let extra = if self.requested5.load(Ordering::SeqCst) {
            r#",{"id":42,"status":1,"is4k":false,"requestedBy":{"id":2,"displayName":"demo"},"seasons":[{"seasonNumber":5,"status":1}]}"#
        } else {
            ""
        };
        let s5 = if self.requested5.load(Ordering::SeqCst) {
            r#",{"seasonNumber":5,"status":2}"#
        } else {
            ""
        };
        format!(
            r#"{{"id":7777,"name":"Küstenwache","firstAirDate":"2010-05-01","posterPath":"/k.jpg","genres":[{{"name":"Krimi"}}],
            "seasons":[{{"seasonNumber":1,"episodeCount":10,"airDate":"2010-05-01"}},{{"seasonNumber":2,"episodeCount":12,"airDate":"2011-05-01"}},
              {{"seasonNumber":3,"episodeCount":8,"airDate":"2012-05-01"}},{{"seasonNumber":4,"episodeCount":8,"airDate":"2013-05-01"}},
              {{"seasonNumber":5,"episodeCount":6,"airDate":"2014-05-01"}}],
            "mediaInfo":{{"id":9,"tmdbId":7777,"mediaType":"tv","status":4,"status4k":1,
              "requests":[{{"id":41,"status":1,"is4k":false,"requestedBy":{{"id":5,"displayName":"Lena"}},"seasons":[{{"seasonNumber":4,"status":1}}]}}{extra}],
              "seasons":[{{"seasonNumber":2,"status":5}},{{"seasonNumber":3,"status":3}},{{"seasonNumber":4,"status":2}}{s5}],
              "downloadStatus":[{{"size":1000,"sizeLeft":380,"status":"downloading","episode":{{"seasonNumber":3,"episodeNumber":1}}}}]}}}}"#
        )
    }
}

fn movie(id: i64, title: &str, date: &str, media: &str) -> String {
    format!(
        r#"{{"id":{id},"mediaType":"movie","title":"{title}","releaseDate":"{date}","posterPath":"/p{id}.jpg"{}}}"#,
        if media.is_empty() {
            String::new()
        } else {
            format!(r#","mediaInfo":{media}"#)
        }
    )
}

#[async_trait::async_trait]
impl HttpClient for World {
    async fn send(&self, r: NetRequest) -> Result<NetResponse, HttpFailure> {
        let url = r.url.split("/api/v1/").nth(1).unwrap_or("").to_string();
        let path = url.split('?').next().unwrap_or("").to_string();
        let method = format!("{:?}", r.method).to_uppercase();
        self.log.lock().unwrap().push(format!(
            "{method} {url} {}",
            r.body
                .as_ref()
                .map(|b| String::from_utf8_lossy(b).to_string())
                .unwrap_or_default()
        ));
        if self.offline.load(Ordering::SeqCst) && path != "auth/me" {
            return Ok(NetResponse {
                status: 503,
                headers: vec![],
                body: b"{}".to_vec(),
                url: None,
            });
        }
        let late = self.latency_ms.load(Ordering::SeqCst);
        if late > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(late)).await;
        }
        let used = self.tv_used.load(Ordering::SeqCst);
        let left = (3 - used).max(0);
        let (status, body): (u16, String) = match (r.method, path.as_str()) {
            (NetMethod::Get, "auth/me") => (
                200,
                format!(
                    r#"{{"id":2,"displayName":"demo","permissions":{}}}"#,
                    self.perms.load(Ordering::SeqCst)
                ),
            ),
            (NetMethod::Get, "user/2/quota") => (
                200,
                format!(
                    r#"{{"movie":{{"days":7,"limit":3,"used":1,"remaining":2,"restricted":false}},"tv":{{"days":7,"limit":3,"used":{used},"remaining":{left},"restricted":{}}}}}"#,
                    left == 0
                ),
            ),
            (NetMethod::Get, "settings/public") => {
                (200, r#"{"partialRequestsEnabled":true}"#.into())
            }
            (NetMethod::Get, "settings/discover") => (200, "[]".into()),
            (NetMethod::Get, "service/sonarr") => (
                200,
                r#"[{"id":0,"name":"sonarr","isDefault":true,"is4k":false,"activeProfileId":4,"activeDirectory":"/media"}]"#.into(),
            ),
            (NetMethod::Get, "service/sonarr/0") => (
                200,
                r#"{"server":{"id":0,"name":"sonarr","isDefault":true,"activeProfileId":4,"activeDirectory":"/media"},"profiles":[{"id":4,"name":"HD-1080p"}],"rootFolders":[{"path":"/media"}],"tags":[]}"#.into(),
            ),
            (NetMethod::Get, "tv/7777") => (200, self.tv()),
            (NetMethod::Get, p) if p.ends_with("/recommendations") || p.ends_with("/similar") => (
                200,
                format!(
                    r#"{{"results":[{}]}}"#,
                    movie(
                        2001,
                        "Nordstern",
                        "2024-01-01",
                        r#"{"id":20,"status":3,"downloadStatus":[{"size":100,"sizeLeft":38}]}"#
                    )
                ),
            ),
            (NetMethod::Post, "request") => {
                let forced = self.post_status.load(Ordering::SeqCst);
                if forced != 0 {
                    (
                        forced as u16,
                        format!(r#"{{"message":"{}"}}"#, self.post_message),
                    )
                } else {
                    self.requested5.store(true, Ordering::SeqCst);
                    self.tv_used.store(3, Ordering::SeqCst);
                    (
                        201,
                        r#"{"id":42,"status":1,"seasons":[{"seasonNumber":5,"status":1}]}"#.into(),
                    )
                }
            }
            (NetMethod::Get, "request") => (
                200,
                String::from(
                    r#"{"pageInfo":{"pages":1,"pageSize":50,"results":4,"page":1},"results":[
                    {"id":50,"status":1,"mediaType":"movie","is4k":false,"requestedBy":{"id":2,"displayName":"demo"},"media":{"id":20,"tmdbId":2002,"mediaType":"movie","status":2}},
                    {"id":51,"status":2,"mediaType":"movie","is4k":false,"requestedBy":{"id":2,"displayName":"demo"},"media":{"id":21,"tmdbId":2001,"mediaType":"movie","status":3,"downloadStatus":[{"size":100,"sizeLeft":38}]}},
                    {"id":52,"status":3,"mediaType":"movie","is4k":false,"requestedBy":{"id":2,"displayName":"demo"},"media":{"id":22,"tmdbId":2003,"mediaType":"movie","status":1}},
                    {"id":53,"status":5,"mediaType":"movie","is4k":false,"requestedBy":{"id":2,"displayName":"demo"},"media":{"id":23,"tmdbId":2008,"mediaType":"movie","status":5}}]}"#,
                ),
            ),
            (NetMethod::Delete, p) if p.starts_with("request/") => {
                if self.cut_after_delete.load(Ordering::SeqCst) {
                    self.offline.store(true, Ordering::SeqCst);
                }
                (204, String::new())
            }
            (NetMethod::Post, p) if p.starts_with("request/") => {
                (200, r#"{"id":50,"status":2}"#.into())
            }
            (NetMethod::Get, "request/count") => (200, r#"{"pending":3,"total":9}"#.into()),
            (NetMethod::Get, "issue/count") => (200, r#"{"open":1,"closed":0,"total":1}"#.into()),
            (NetMethod::Get, "issue") => (200, r#"{"pageInfo":{"results":0},"results":[]}"#.into()),
            (NetMethod::Delete, p) if p.starts_with("media/") => (204, String::new()),
            (NetMethod::Get, "search") => (
                200,
                format!(
                    r#"{{"page":1,"totalPages":1,"totalResults":4,"results":[{},{},{},{{"id":77,"mediaType":"person","name":"Nora Nord","profilePath":"/n.jpg"}}]}}"#,
                    movie(2002, "Nordlicht", "2024-03-01", r#"{"id":24,"status":2}"#),
                    movie(2005, "Nordwind", "2020-01-01", r#"{"id":25,"status":6}"#),
                    movie(1001, "Nordsee", "2019-01-01", r#"{"id":26,"status":5}"#),
                ),
            ),
            (NetMethod::Get, p) if p.starts_with("discover/") => (
                200,
                format!(
                    r#"{{"page":1,"totalPages":1,"results":[{}]}}"#,
                    movie(2004, "Bald", "2999-11-28", "")
                ),
            ),
            (NetMethod::Get, p) if p.starts_with("movie/") => {
                let id: i64 = p[6..].parse().unwrap_or(0);
                (
                    200,
                    format!(
                        r#"{{"id":{id},"title":"Film {id}","releaseDate":"2024-01-01","posterPath":"/p{id}.jpg"}}"#
                    ),
                )
            }
            _ => (404, "{}".into()),
        };
        Ok(NetResponse {
            status,
            headers: vec![],
            body: body.into_bytes(),
            url: None,
        })
    }
}

fn hub_for(world: &Arc<World>, library: Option<Arc<dyn SeerrLibrary>>) -> Arc<SeerrHub> {
    let transport = CoreTransport::new(Arc::clone(world) as Arc<dyn HttpClient>);
    let connection = SeerrConnection {
        address: "https://seerr.test".into(),
        cookie: "connect.sid=x".into(),
        headers: Vec::new(),
    };
    SeerrHub::new(
        Some(SeerrModel::build(transport, connection, None)),
        "de".into(),
        library,
    )
}

#[tokio::test]
async fn season_picker_request_sheet_and_quota() {
    let world = World::new(USER);
    let hub = hub_for(&world, None);
    let screen = SeerrTitleScreen::new(Arc::clone(&hub), "tv".into(), 7777);
    screen.set_library_seasons(vec![2]);
    let page = screen.load().await.unwrap();
    assert_eq!(page.load, TitleLoad::Content);
    // The world lists no episodes: the export answers "none" for any pick (the rule itself is tested in the vm).
    assert_eq!(screen.episode_season(Some(2)), None);
    let rows = screen.season_picker();
    let words: Vec<(i64, &str, bool)> = rows
        .iter()
        .map(|r| (r.number, r.badge.word.as_str(), r.missing))
        .collect();
    assert_eq!(
        words,
        [
            (1, "+", true),
            (2, "da", false),
            (3, "62 %", true),
            (4, "wartet", true),
            (5, "+", true)
        ]
    );
    assert!(rows[1].on_server && !rows[1].selectable);
    assert_eq!(rows[3].waiting_request, Some(41));
    // Tap the grey Staffel 5: the sheet is open at once with the row ticked.
    let sheet = screen.open_sheet(Some(5));
    assert_eq!(sheet.phase, SheetPhase::Editing);
    assert_eq!(
        sheet
            .rows
            .iter()
            .filter(|r| r.selected)
            .map(|r| r.number)
            .collect::<Vec<_>>(),
        [5]
    );
    assert_eq!(sheet.primary.text, "Staffel 5 anfragen");
    assert_eq!(
        sheet.quota_line.as_deref(),
        Some("Noch 1 von 3 Staffeln frei diese Woche")
    );
    assert!(
        sheet.four_k.is_none() && sheet.quality.is_none(),
        "a user sees no 4K or quality rows"
    );
    let sheet = screen.load_sheet().await.unwrap();
    assert_eq!(
        sheet.quota_line.as_deref(),
        Some("Noch 1 von 3 Staffeln frei diese Woche")
    );
    // Two seasons are more than the one that is left: the button locks.
    let two = screen.toggle(1);
    assert_eq!(two.primary.kind, PrimaryKind::Locked);
    assert!(two.quota_warning);
    let one = screen.toggle(1);
    assert_eq!(one.primary.kind, PrimaryKind::Request);
    let result = screen.confirm().await.unwrap();
    assert_eq!(
        result,
        SeerrRequestResult::Requested {
            auto_approved: false
        }
    );
    assert_eq!(world.calls("POST request "), 1);
    assert!(
        world
            .log
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains(r#""seasons":[5]"#))
    );
    // The page reads again: Staffel 5 waits, the quota is used up.
    let page = screen.info();
    assert_eq!(page.seasons[4].badge.word, "wartet");
    let sheet = screen.open_sheet(Some(1));
    assert_eq!(
        sheet.primary.kind,
        PrimaryKind::Locked,
        "no further request at quota 0"
    );
    assert_eq!(
        sheet.quota_line.as_deref(),
        Some("Nichts mehr frei diese Woche")
    );
    assert!(sheet.quota_warning);
    // A locked button sends nothing.
    assert_eq!(screen.confirm().await.unwrap(), SeerrRequestResult::NotSent);
    assert_eq!(world.calls("POST request "), 1);
}

#[tokio::test]
async fn a_server_refusal_stays_in_the_sheet_and_a_duplicate_refreshes() {
    let mut w = World::new(USER);
    Arc::get_mut(&mut w).unwrap().post_message = "TV Request Quota exceeded.";
    w.post_status.store(403, Ordering::SeqCst);
    let hub = hub_for(&w, None);
    let screen = SeerrTitleScreen::new(hub, "tv".into(), 7777);
    screen.load().await.unwrap();
    screen.open_sheet(Some(5));
    match screen.confirm().await.unwrap() {
        SeerrRequestResult::Failed { message } => {
            assert_eq!(
                message, "Dein Serien-Limit für diese Woche ist erreicht.",
                "the quota in German, not 'Sitzung ungültig'"
            );
        }
        other => panic!("{other:?}"),
    }
    let sheet = screen.info().sheet;
    assert_eq!(sheet.phase, SheetPhase::Failed);
    assert_eq!(
        sheet.error.as_deref(),
        Some("Dein Serien-Limit für diese Woche ist erreicht.")
    );
    // 409: somebody asked before. No error, the page reads again and shows the request.
    w.post_status.store(409, Ordering::SeqCst);
    w.requested5.store(true, Ordering::SeqCst);
    assert_eq!(screen.confirm().await.unwrap(), SeerrRequestResult::Exists);
    assert_eq!(screen.info().sheet.phase, SheetPhase::Closed);
    assert_eq!(screen.info().seasons[4].badge.kind, BadgeKind::Waits);
}

#[tokio::test]
async fn an_admin_sheet_without_the_service_still_works_and_a_film_has_no_rows() {
    let world = World::new(ADMIN);
    let hub = hub_for(&world, None);
    let screen = SeerrTitleScreen::new(Arc::clone(&hub), "tv".into(), 7777);
    screen.load().await.unwrap();
    assert!(hub.info().is_admin);
    let sheet = screen.open_sheet(None);
    // Admin: only the first season that can be asked for (1; season 5 could be too) is ticked, no quota line
    // is needed for an admin.
    let ticked: Vec<_> = sheet
        .rows
        .iter()
        .filter(|r| r.selected)
        .map(|r| r.number)
        .collect();
    assert_eq!(ticked, [1]);
    assert_eq!(sheet.primary.text, "Staffel 1 anfragen");
}

/// The request sheet of an administrator opens with its quality and folder values already in: the page's
/// read fetched them, `open_sheet` does not wait for a second answer (a value that arrives while the card
/// slides up does not ride along with it).
#[tokio::test]
async fn an_admin_sheet_opens_with_its_values_from_the_pages_own_read() {
    let hub = hub_for(&World::new(ADMIN), None);
    let screen = SeerrTitleScreen::new(Arc::clone(&hub), "tv".into(), 7777);
    screen.load().await.unwrap();
    let sheet = screen.open_sheet(None);
    let quality = sheet.quality.expect("the quality row stands");
    let folder = sheet.folder.expect("the folder row stands");
    assert_eq!(quality.value, "HD-1080p", "value there at the first frame");
    assert_eq!(folder.value, "/media");
}

#[tokio::test]
async fn without_seerr_nothing_shows() {
    let hub = SeerrHub::new(None, "de".into(), None);
    assert!(!hub.available());
    assert_eq!(hub.info().state, swiftly_vm::HubState::Unavailable);
    assert!(hub.info().profile_rows.is_empty());
    let title = SeerrTitleScreen::new(Arc::clone(&hub), "tv".into(), 7777);
    assert_eq!(title.load().await.unwrap().load, TitleLoad::Unavailable);
    let lists = SeerrListsScreen::new(Arc::clone(&hub));
    assert!(!lists.load_home(vec![], true, true).await.unwrap().show);
    assert!(lists.load_discover().await.unwrap().rails.is_empty());
    assert!(lists.similar("tv".into(), 7777).await.unwrap().is_empty());
    assert!(SeerrAdminScreen::new(hub).tabs().is_empty());
}

#[tokio::test]
async fn search_discover_and_my_requests() {
    let world = World::new(USER);
    let hub = hub_for(&world, None);
    let lists = SeerrListsScreen::new(Arc::clone(&hub));
    let found = lists.search("nord".into()).await.unwrap();
    assert_eq!(found.block_title, "Noch nicht auf deinem Server");
    let movies = &found.groups[0];
    let words: Vec<&str> = movies
        .tiles
        .iter()
        .map(|t| t.badge.as_ref().unwrap().word.as_str())
        .collect();
    assert_eq!(
        words,
        ["wartet", "gesperrt"],
        "the title on the server does not appear twice"
    );
    assert_eq!(found.groups.len(), 2, "films, people");
    // Offline: a retry after the server is back shows the block.
    world.offline.store(true, Ordering::SeqCst);
    let off = lists.search("__off".into()).await.unwrap();
    assert_eq!(off.load, ListLoad::Offline);
    assert_eq!(off.error.as_deref(), Some("Seerr antwortet gerade nicht."));
    world.offline.store(false, Ordering::SeqCst);
    assert_eq!(
        lists.search("nord".into()).await.unwrap().load,
        ListLoad::Content
    );
    let rails = lists.load_discover().await.unwrap();
    assert_eq!(rails.rails[0].title, "Im Trend");
    assert_eq!(
        rails.rails[0].tiles[0].badge.as_ref().unwrap().word,
        "28. Nov."
    );
    // My requests: words per state, pills with counts, withdraw removes only the own waiting row.
    let mine = lists.load_requests().await.unwrap();
    let lines: Vec<&str> = mine.rows.iter().map(|r| r.badge.line.as_str()).collect();
    assert_eq!(
        lines,
        [
            "Wartet auf Freigabe",
            "Wird geholt · 62 %",
            "Abgelehnt",
            "Auf deinem Server"
        ]
    );
    assert_eq!(mine.rows[0].title, "Film 2002");
    assert!(mine.rows[0].can_withdraw && !mine.rows[1].can_withdraw);
    assert!(!mine.rows[0].can_approve, "a user cannot approve");
    let counts: Vec<(RequestPill, i64)> = mine.pills.iter().map(|p| (p.pill, p.count)).collect();
    assert_eq!(counts[0], (RequestPill::All, 4));
    assert_eq!(counts[1], (RequestPill::Open, 1));
    assert_eq!(
        mine.quota_summary.as_deref(),
        Some("Noch frei diese Woche: 2 Filme, 1 Staffel")
    );
    let after = lists.withdraw(50).await.unwrap();
    assert_eq!(after.rows.len(), 3);
    assert_eq!(world.calls("DELETE request/50"), 1);
    assert_eq!(hub.info().profile_rows[0].title, "Meine Anfragen");
}

struct Library {
    items: Mutex<Vec<(String, i64)>>,
    refresh_fails: AtomicBool,
}

#[async_trait::async_trait]
impl SeerrLibrary for Library {
    async fn find(&self, art: String, tmdb: i64) -> Result<Option<String>, LibraryFailure> {
        Ok(self
            .items
            .lock()
            .unwrap()
            .iter()
            .find(|(a, t)| *a == art && *t == tmdb)
            .map(|(_, t)| format!("lib{t}")))
    }
    async fn refresh(&self) -> Result<(), LibraryFailure> {
        if self.refresh_fails.load(Ordering::SeqCst) {
            return Err(LibraryFailure::Other {
                message: "500".into(),
            });
        }
        self.items.lock().unwrap().clear();
        Ok(())
    }
}

#[tokio::test]
async fn the_home_block_finds_an_arrival_and_remembers_the_x() {
    let world = World::new(USER);
    let library = Arc::new(Library {
        items: Mutex::new(vec![("movie".into(), 2008)]),
        refresh_fails: AtomicBool::new(false),
    });
    let hub = hub_for(&world, Some(library));
    let lists = SeerrListsScreen::new(hub);
    let home = lists.load_home(vec![], true, true).await.unwrap();
    assert!(home.show);
    let arrival = home.arrival.expect("arrival");
    assert_eq!(
        (arrival.request_id, arrival.library_id.as_str()),
        (53, "lib2008")
    );
    assert_eq!(arrival.line, "Film 2008 ist da");
    // The "Angefragt" rail: downloading first, then waiting.
    let words: Vec<&str> = home
        .rail
        .iter()
        .map(|t| t.badge.as_ref().unwrap().word.as_str())
        .collect();
    assert_eq!(words, ["62 %", "wartet"]);
    assert_eq!(lists.dismiss_arrival(53), vec![53]);
    assert!(
        lists
            .load_home(vec![53], true, true)
            .await
            .unwrap()
            .arrival
            .is_none(),
        "hidden after relaunch"
    );
    assert!(
        lists
            .load_home(vec![], false, true)
            .await
            .unwrap()
            .arrival
            .is_none(),
        "setting off"
    );
}

#[tokio::test]
async fn admin_queue_actions_and_delete_flow_resumes_at_the_failed_step() {
    let world = World::new(ADMIN);
    let library = Arc::new(Library {
        items: Mutex::new(vec![("tv".into(), 7777)]),
        refresh_fails: AtomicBool::new(true),
    });
    let hub = hub_for(&world, Some(Arc::clone(&library) as Arc<dyn SeerrLibrary>));
    let admin = SeerrAdminScreen::new(Arc::clone(&hub));
    hub.refresh().await.unwrap();
    assert_eq!(admin.tabs().len(), 2);
    assert_eq!(
        hub.info().admin_line.as_deref(),
        Some("3 Anfragen · 1 Problem")
    );
    let queue = admin.load_requests().await.unwrap();
    assert!(queue.rows[0].can_approve && queue.rows[0].can_decline);
    let after = admin.approve(50).await.unwrap();
    assert_eq!(world.calls("POST request/50/approve"), 1);
    let row = after.rows.iter().find(|r| r.id == 50).unwrap();
    assert!(!row.can_approve, "the row left the waiting state");
    // Delete: files, Seerr, then the Jellyfin step fails, retry resumes there only.
    let prep = admin
        .delete_prepare(
            "tv".into(),
            7777,
            "Küstenwache".into(),
            Some("12 GB".into()),
            None,
        )
        .await
        .unwrap()
        .expect("prepared");
    assert_eq!(prep.phase, DeletePhase::Confirm);
    let failed = admin.delete_run(vec![false]).await.unwrap();
    assert_eq!(failed.phase, DeletePhase::Failed);
    assert_eq!(failed.headline.as_deref(), Some("Ein Schritt hängt"));
    assert_eq!(failed.error.as_deref(), Some("Jellyfin antwortet nicht."));
    let states: Vec<StepState> = failed.steps.iter().map(|s| s.state).collect();
    assert_eq!(
        states,
        [
            StepState::Done,
            StepState::Done,
            StepState::Failed,
            StepState::Pending
        ]
    );
    library.refresh_fails.store(false, Ordering::SeqCst);
    let done = admin.delete_retry().await.unwrap();
    assert_eq!(done.phase, DeletePhase::Done);
    assert_eq!(
        world.calls("DELETE media/9/file"),
        1,
        "no second file delete"
    );
    assert_eq!(world.calls("DELETE media/9 "), 1);
}

#[tokio::test]
async fn the_title_menu_offers_report_and_delete_by_rights() {
    // Without a connection: nothing.
    let none = SeerrHub::new(None, "de".into(), None);
    assert!(none.title_menu().is_empty());
    // A user may report (when the account has the right) and never delete.
    let user = hub_for(&World::new(USER), None);
    user.refresh().await.unwrap();
    let kinds: Vec<SeerrMenuKind> = user.title_menu().iter().map(|e| e.kind).collect();
    assert!(!kinds.contains(&SeerrMenuKind::DeleteFromServer));
    assert_eq!(
        kinds.contains(&SeerrMenuKind::ReportProblem),
        user.info().can_create_issues
    );
    // An administrator gets both, in the core's words.
    let admin = hub_for(&World::new(ADMIN), None);
    admin.refresh().await.unwrap();
    let menu = admin.title_menu();
    let words: Vec<&str> = menu.iter().map(|e| e.text.as_str()).collect();
    assert_eq!(words, ["Problem melden", "Vom Server löschen"]);
}

/// The Start page's gate for the Seerr block: a profile that remembers nothing waits for the first answer, at most
/// `HOME_BUDGET_SECONDS`; a profile that remembers a shape (or "nothing") never waits.
#[tokio::test(start_paused = true)]
async fn the_home_gate_waits_for_the_first_answer_within_its_budget_and_not_longer() {
    use swiftly_vm::{SeerrHomeShape, SeerrHomeState};
    // The answer comes in time (Seerr is not usable here, so the read is over at once): the gate returns with it.
    let hub = SeerrHub::new(None, "de".into(), None);
    let lists = SeerrListsScreen::new(Arc::clone(&hub));
    assert!(lists.begin_home(String::new()).holds_page);
    let (gate, load) = tokio::join!(lists.gate_home(), lists.load_home(vec![], true, true));
    let gate = gate.unwrap();
    let _ = load.unwrap();
    assert!((gate.state, gate.holds_page) == (SeerrHomeState::Hidden, false));
    assert_eq!(gate.memory, "-");

    // Nothing answers: the budget ends the wait, the page shows with the first guess reserved...
    let lists = SeerrListsScreen::new(Arc::clone(&hub));
    assert!(lists.begin_home(String::new()).holds_page);
    let started = tokio::time::Instant::now();
    let gate = lists.gate_home().await.unwrap();
    assert_eq!(
        started.elapsed(),
        std::time::Duration::from_secs_f64(swiftly_vm::HOME_BUDGET_SECONDS)
    );
    assert!((gate.state, gate.holds_page) == (SeerrHomeState::Pending, false));
    assert_eq!(gate.shape, SeerrHomeShape::FIRST_GUESS);
    // ...and the late answer (Seerr has nothing) closes the room.
    let late = lists.load_home(vec![], true, true).await.unwrap();
    assert_eq!(late.state, SeerrHomeState::Hidden);

    // A remembered profile does not wait at all.
    let lists = SeerrListsScreen::new(hub);
    assert!(!lists.begin_home("lr".into()).holds_page);
    let started = tokio::time::Instant::now();
    let gate = lists.gate_home().await.unwrap();
    assert_eq!(started.elapsed(), std::time::Duration::ZERO);
    assert_eq!(gate.state, SeerrHomeState::Pending);
}

/// A Seerr that answers late (a remote one, 150 ms per request) is still ready within a second: the hub read is
/// a handful of requests, not a wait that ends at a transport timeout. Both the Start page's first read and the
/// profile's own read run at once, as they do in the app.
#[tokio::test]
async fn a_seerr_that_answers_150_ms_late_is_ready_within_a_second() {
    let world = World::new(USER);
    world.latency_ms.store(150, Ordering::SeqCst);
    let hub = hub_for(&world, None);
    let started = std::time::Instant::now();
    let (a, b) = tokio::join!(hub.refresh(), hub.refresh());
    a.unwrap();
    b.unwrap();
    assert!(
        hub.available(),
        "the hub is not ready after {:?}",
        started.elapsed()
    );
    assert!(
        started.elapsed() < std::time::Duration::from_secs(1),
        "the hub read took {:?}",
        started.elapsed()
    );
    // The Start block's own read comes out the same.
    let lists = SeerrListsScreen::new(Arc::clone(&hub));
    let home = lists.load_home(vec![], true, true).await.unwrap();
    assert!(home.show, "the block stays hidden: {:?}", home.state);
    assert!(started.elapsed() < std::time::Duration::from_secs(2));
}

// ---- the stash: the last answers paint first, the live read replaces them

fn stashed_hub(world: &Arc<World>, cache: &swiftly_vm::ViewCache) -> Arc<SeerrHub> {
    let transport = CoreTransport::new(Arc::clone(world) as Arc<dyn HttpClient>);
    let connection = SeerrConnection {
        address: "https://seerr.test".into(),
        cookie: "connect.sid=x".into(),
        headers: Vec::new(),
    };
    let stash = swiftly_vm::SeerrStash::for_connection(
        cache.clone(),
        &connection.address,
        &connection.cookie,
    );
    SeerrHub::new(
        Some(SeerrModel::build_stashed(
            transport,
            connection,
            None,
            Some(stash),
            None,
        )),
        "de".into(),
        None,
    )
}

fn memory_cache() -> swiftly_vm::ViewCache {
    swiftly_vm::ViewCache::new(
        swiftly_cache::EntityCache::in_memory(swiftly_cache::CacheConfig::default()).unwrap(),
    )
}

/// The second start of the app: the Start block, the discover rails and the admin page are there from the stash
/// without one call to Seerr, and the live read after them takes the few rounds of the parallel read.
#[tokio::test]
async fn the_last_answers_paint_before_seerr_answers_and_the_live_read_is_four_rounds() {
    let cache = memory_cache();
    // First start: nothing stored, nothing to paint.
    let world = World::new(ADMIN);
    world.latency_ms.store(150, Ordering::SeqCst);
    let lists = SeerrListsScreen::new(stashed_hub(&world, &cache));
    assert!(
        lists
            .restore_home(vec![], true, true)
            .await
            .unwrap()
            .is_none()
    );
    assert!(lists.restore_discover().await.unwrap().is_none());
    let first = lists.load_home(vec![], true, true).await.unwrap();
    assert!(first.show);
    lists.load_discover().await.unwrap();
    SeerrAdminScreen::new(stashed_hub(&world, &cache))
        .load_all()
        .await
        .unwrap();

    // Second start: a new hub, a Seerr 150 ms away.
    let world = World::new(ADMIN);
    world.latency_ms.store(150, Ordering::SeqCst);
    let hub = stashed_hub(&world, &cache);
    let lists = SeerrListsScreen::new(Arc::clone(&hub));
    let t = std::time::Instant::now();
    let home = lists
        .restore_home(vec![], true, true)
        .await
        .unwrap()
        .expect("home from the stash");
    let rails = lists
        .restore_discover()
        .await
        .unwrap()
        .expect("rails from the stash");
    let admin = SeerrAdminScreen::new(Arc::clone(&hub));
    let page = admin
        .restore_all()
        .await
        .unwrap()
        .expect("admin page from the stash");
    assert!(
        t.elapsed() < std::time::Duration::from_millis(100),
        "{:?}",
        t.elapsed()
    );
    assert_eq!(world.calls(""), 0, "the stash read went to Seerr");
    assert!(home.show && !rails.rails.is_empty() && page.queue.is_some());
    assert_eq!(home.rail.len(), first.rail.len());
    // The live hub was not touched by the stale pass: it still has to read the account.
    assert!(!hub.available());

    let t = std::time::Instant::now();
    let live = lists.load_home(vec![], true, true).await.unwrap();
    assert!(live.show);
    let took = t.elapsed();
    // me+settings, quota, counts+requests, titles: four rounds (it was six).
    assert!(
        took < std::time::Duration::from_millis(4 * 150 + 120),
        "home took {took:?}"
    );
    let t = std::time::Instant::now();
    admin.load_all().await.unwrap();
    assert!(
        t.elapsed() < std::time::Duration::from_millis(3 * 150 + 120),
        "admin took {:?}",
        t.elapsed()
    );
}

/// Two screens asking for the account at once read it once, and a read does not wait for the counts.
#[tokio::test]
async fn the_account_is_read_once_for_every_screen_that_asks() {
    let world = World::new(USER);
    world.latency_ms.store(100, Ordering::SeqCst);
    let hub = stashed_hub(&world, &memory_cache());
    let t = std::time::Instant::now();
    let (a, b, c) = tokio::join!(hub.core.ensure(), hub.core.ensure(), hub.core.ensure());
    assert!(a && b && c);
    assert_eq!(world.calls("auth/me"), 1);
    assert_eq!(
        world.calls("request?"),
        0,
        "the counts are not part of the account read"
    );
    assert!(
        t.elapsed() < std::time::Duration::from_millis(2 * 100 + 80),
        "{:?}",
        t.elapsed()
    );
}

/// A stash that lacks one answer (cleared, or an older version) paints nothing instead of half a page.
#[tokio::test]
async fn an_incomplete_stash_paints_nothing() {
    let cache = memory_cache();
    let world = World::new(USER);
    let lists = SeerrListsScreen::new(stashed_hub(&world, &cache));
    lists.load_home(vec![], true, true).await.unwrap();
    let other = swiftly_vm::SeerrStash::for_connection(
        cache.clone(),
        "https://seerr.test",
        "connect.sid=x",
    );
    // Remove one answer the home read needs by overwriting its scope's entry with nothing is not possible; a different
    // connection (another session) has its own, empty stash.
    let lonely = {
        let transport = CoreTransport::new(Arc::clone(&world) as Arc<dyn HttpClient>);
        let connection = SeerrConnection {
            address: "https://seerr.test".into(),
            cookie: "connect.sid=other".into(),
            headers: Vec::new(),
        };
        let stash = swiftly_vm::SeerrStash::for_connection(
            cache.clone(),
            &connection.address,
            &connection.cookie,
        );
        SeerrHub::new(
            Some(SeerrModel::build_stashed(
                transport,
                connection,
                None,
                Some(stash),
                None,
            )),
            "de".into(),
            None,
        )
    };
    assert!(other.get("auth/me").is_some());
    assert!(
        SeerrListsScreen::new(lonely)
            .restore_home(vec![], true, true)
            .await
            .unwrap()
            .is_none()
    );
}

/// "Meine Anfragen" on the second start: the list is there from the stash without one call to Seerr, the filter pills
/// work on the stored rows, the live read replaces it, and a withdrawn request does not come back from the stash.
#[tokio::test]
async fn my_requests_paint_from_the_stash_before_seerr_answers() {
    let cache = memory_cache();
    // First start: nothing stored, nothing painted, the screen stays untouched.
    let world = World::new(USER);
    world.latency_ms.store(150, Ordering::SeqCst);
    let first = SeerrListsScreen::new(stashed_hub(&world, &cache));
    assert!(first.restore_requests().await.unwrap().is_none());
    assert_eq!(first.requests().load, ListLoad::Idle);
    let live = first.load_requests().await.unwrap();
    assert_eq!(live.load, ListLoad::Content);
    let all = live.rows.len();
    assert!(all >= 4, "the fake server lists several requests");

    // Second start: a new hub over a Seerr 150 ms away.
    let world = World::new(USER);
    world.latency_ms.store(150, Ordering::SeqCst);
    let hub = stashed_hub(&world, &cache);
    let second = SeerrListsScreen::new(Arc::clone(&hub));
    let t = std::time::Instant::now();
    let stored = second
        .restore_requests()
        .await
        .unwrap()
        .expect("the list from the stash");
    assert!(
        t.elapsed() < std::time::Duration::from_millis(100),
        "{:?}",
        t.elapsed()
    );
    assert_eq!(world.calls(""), 0, "the stash paint went to Seerr");
    assert_eq!(stored.rows.len(), all);
    assert!(
        stored.rows.iter().all(|r| !r.title.is_empty()),
        "titles from the stash too"
    );
    // The filter works on the stored rows, still without a call.
    let open = second.select_pill(RequestPill::Open);
    assert!(!open.rows.is_empty() && open.rows.len() < all);
    assert_eq!(world.calls(""), 0);
    // A list that is on screen is not painted over.
    assert!(second.restore_requests().await.unwrap().is_none());

    // The live read replaces it (the account is read live, too) and keeps the pill.
    let live = second.load_requests().await.unwrap();
    assert_eq!(live.load, ListLoad::Content);
    assert_eq!(live.rows.len(), open.rows.len());
    assert_eq!(world.calls("auth/me"), 1);
    assert!(world.calls("GET request?") >= 1, "the live read asks Seerr");

    // Withdrawing a waiting request, with Seerr gone right after (nothing re-reads the list): the stored answers must
    // not bring the request back.
    world.cut_after_delete.store(true, Ordering::SeqCst);
    let waiting = open.rows[0].id;
    let after = second.withdraw(waiting).await.unwrap();
    assert!(after.rows.iter().all(|r| r.id != waiting));
    let world = World::new(USER);
    let third = SeerrListsScreen::new(stashed_hub(&world, &cache));
    let stored = third
        .restore_requests()
        .await
        .unwrap()
        .expect("still a list");
    assert_eq!(world.calls(""), 0);
    assert_eq!(stored.rows.len(), all - 1);
    assert!(
        third
            .select_pill(RequestPill::All)
            .rows
            .iter()
            .all(|r| r.id != waiting),
        "a withdrawn request came back from the stash"
    );
}

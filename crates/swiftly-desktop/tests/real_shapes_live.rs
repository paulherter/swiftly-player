//! The real app (`Suite::new_live`) against `cargo xtask fixture-server --real-shapes`, over the real network: each
//! point C1..C11 of the desktop acceptance is asserted on the page tree. Needs `target/debug/xtask`
//! (`cargo build -p xtask`); without it the tests say so and pass. Every test runs in a child process with a
//! temporary `SWIFTLY_CONFIG_DIR` (file secrets), so a running app's single-instance check and config are never
//! touched.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_desktop::deep_link::DeepLink;
use swiftly_desktop::live::Core;
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::a11y::A11yNode;
use swiftly_ui::{Cx, Env, Idiom};

/// The fixture server binary: built on the spot when `target/debug/xtask` is missing (a workspace test run does not
/// build it), so the live tests start their own fixture; when it cannot be built the test says so and passes.
fn fixture_binary() -> Option<PathBuf> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let xtask = root.join("target/debug/xtask");
    if !xtask.exists() {
        let cargo = std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
        let built = Command::new(cargo)
            .args(["build", "-q", "-p", "xtask"])
            .current_dir(&root)
            .status()
            .is_ok_and(|s| s.success());
        if !built || !xtask.exists() {
            println!("skipped: the fixture server (xtask) could not be built");
            return None;
        }
    }
    Some(xtask)
}

struct Fixture {
    child: Child,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Runs `test` again in a child process with its own config directory; `true` in the child that must do the work.
fn isolated(test: &str) -> bool {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_some() {
        return true;
    }
    let dir = std::env::temp_dir().join(format!("swiftly-real-{test}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let out = Command::new(std::env::current_exe().expect("exe"))
        .args(["--exact", test, "--nocapture", "--test-threads=1"])
        .env("SWIFTLY_CONFIG_DIR", &dir)
        .output()
        .expect("child");
    let _ = std::fs::remove_dir_all(&dir);
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    println!("{text}");
    assert!(out.status.success(), "{text}");
    false
}

/// Signed-in live app over the real-shapes fixture; `None` (with a note) when `xtask` is not built.
struct App {
    port: u16,
    _fx: Fixture,
    suite: Suite,
    core: Arc<Core>,
    clock: Instant,
}

impl App {
    fn start() -> Option<App> {
        let xtask = fixture_binary()?;
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .expect("port")
            .local_addr()
            .expect("addr")
            .port();
        let child = Command::new(&xtask)
            .args([
                "fixture-server",
                "--port",
                &port.to_string(),
                "--real-shapes",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("fixture");
        let fx = Fixture { child };
        // Until the fixture accepts connections (a busy machine needs more than a fixed pause).
        let ready = Instant::now();
        while std::net::TcpStream::connect(("127.0.0.1", port)).is_err()
            && ready.elapsed() < Duration::from_secs(30)
        {
            std::thread::sleep(Duration::from_millis(100));
        }
        let addr = format!("http://127.0.0.1:{port}");
        let core = Arc::new(Core::open().expect("core"));
        let backend = core.sign_in_backend();
        let wait = Duration::from_secs(30);
        backend
            .connect(&addr)
            .0
            .recv_timeout(wait)
            .expect("connect")
            .expect("address");
        backend
            .password("demo", "demo")
            .0
            .recv_timeout(wait)
            .expect("password")
            .expect("sign-in");
        let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
        let suite = Suite::new_live(env, Cx::new(), Arc::clone(&core));
        Some(App {
            port,
            _fx: fx,
            suite,
            core,
            clock: Instant::now(),
        })
    }

    fn now(&self) -> f64 {
        self.clock.elapsed().as_secs_f64() * 1000.0
    }

    /// Frames for `secs` of wall time.
    fn run(&mut self, secs: f64) {
        let until = self.clock.elapsed().as_secs_f64() + secs;
        while self.clock.elapsed().as_secs_f64() < until {
            let now = self.now();
            let _ = self.suite.frame(now);
            std::thread::sleep(Duration::from_millis(8));
        }
    }

    /// The request targets the fixture has seen so far (`GET /fixture/seen`).
    fn seen(&self) -> Vec<String> {
        use std::io::{Read, Write};
        let mut c = std::net::TcpStream::connect(("127.0.0.1", self.port)).expect("fixture");
        let _ = write!(
            c,
            "GET /fixture/seen HTTP/1.0\r\nHost: x\r\nConnection: close\r\n\r\n"
        );
        let mut out = String::new();
        let _ = c.read_to_string(&mut out);
        let body = out.rsplit("\r\n\r\n").next().unwrap_or_default();
        body.trim_matches(|c| c == '[' || c == ']' || c == '\n')
            .split("\",\"")
            .map(|l| l.trim_matches('"').to_owned())
            .collect()
    }

    /// Every label and value on the screen, in reading order.
    fn texts(&self) -> Vec<String> {
        fn walk(n: &A11yNode, out: &mut Vec<String>) {
            if !n.label.is_empty() {
                out.push(n.label.clone());
            }
            if let Some(v) = &n.value {
                out.push(v.clone());
            }
            for c in &n.children {
                walk(c, out);
            }
        }
        let mut out = Vec::new();
        for n in &self.suite.a11y_nodes().1 {
            walk(n, &mut out);
        }
        out
    }

    /// Like `texts`, with what the pushed page says (its reading list is not part of the window's yet).
    fn page_texts(&mut self) -> Vec<String> {
        fn walk(n: &A11yNode, out: &mut Vec<String>) {
            if !n.label.is_empty() {
                out.push(n.label.clone());
            }
            if let Some(v) = &n.value {
                out.push(v.clone());
            }
            for c in &n.children {
                walk(c, out);
            }
        }
        let mut out = Vec::new();
        for n in &self.suite.page_a11y_nodes() {
            walk(n, &mut out);
        }
        out
    }
}

#[test]
fn c4_a_season_opens_the_item_page_like_the_mac() {
    if !isolated("c4_a_season_opens_the_item_page_like_the_mac") {
        return;
    }
    let Some(mut app) = App::start() else { return };
    app.run(3.0);
    let now = app.now();
    app.suite.open_link(DeepLink::Title("rse1".into()), now);
    app.run(4.0);
    assert!(app.suite.title_open(), "a title page is open");
    assert!(
        !app.suite.title_is_series(),
        "the season has its own item page, not the series page"
    );
    let texts = app.texts();
    assert!(texts.iter().any(|t| t == "Staffel 2"), "{texts:?}");
    assert!(texts.iter().any(|t| t == "Abspielen"), "{texts:?}");
    assert!(
        !texts.iter().any(|t| t == "TBA"),
        "no placeholder text: {texts:?}"
    );
}

#[test]
fn c6_the_profile_picture_is_asked_for_at_480_through_the_hub() {
    if !isolated("c6_the_profile_picture_is_asked_for_at_480_through_the_hub") {
        return;
    }
    let Some(mut app) = App::start() else { return };
    app.run(5.0);
    let seen = app.seen();
    assert!(
        seen.iter().any(|l| l.contains("/Users/u1/Images/Primary")
            && l.contains("fillWidth=480")
            && l.contains("fillHeight=480")),
        "no 480 px user picture request: {seen:?}"
    );
    let _ = &app.core;
}

#[test]
fn c11_resting_on_a_tile_fetches_its_title_ahead() {
    if !isolated("c11_resting_on_a_tile_fetches_its_title_ahead") {
        return;
    }
    let Some(mut app) = App::start() else { return };
    app.run(5.0);
    let item_reads = |app: &App| {
        app.seen()
            .iter()
            .filter(|l| {
                (l.starts_with("/Items/") || l.starts_with("/Users/u1/Items/"))
                    && !l.contains("/Images/")
                    && !l.contains("Latest")
                    && !l.contains("Resume")
            })
            .count()
    };
    let before = item_reads(&app);
    let (w, h) = (1280.0_f32, 800.0_f32);
    let mut grew = false;
    'scan: for yi in 0..12 {
        for xi in 0..12 {
            let (x, y) = (w * (0.30 + 0.05 * xi as f32), h * (0.20 + 0.05 * yi as f32));
            let now = app.now();
            app.suite.pointer_move(x, y, now);
            app.run(0.3);
            if item_reads(&app) > before {
                grew = true;
                break 'scan;
            }
        }
    }
    assert!(
        grew,
        "no title was fetched ahead while the pointer rested: {:?}",
        app.seen()
    );
}

/// Clicks the control `key` of the page in front (window points).
fn click_page(app: &mut App, key: &str) {
    let f = app
        .suite
        .page_frame_of(key)
        .unwrap_or_else(|| panic!("no {key}"));
    let now = app.now();
    app.suite.touch_down(f[0] + 6.0, f[1] + 6.0, now);
    app.suite.touch_up(f[0] + 6.0, f[1] + 6.0, now + 40.0);
    app.run(0.4);
}

fn press(app: &mut App, key: swiftly_ui::NavKey) {
    let now = app.now();
    let _ = app.suite.nav_key(key, true, now);
    app.run(0.2);
}

#[test]
fn collection_page_has_filter_and_sort_pills_that_reload_its_shelf() {
    if !isolated("collection_page_has_filter_and_sort_pills_that_reload_its_shelf") {
        return;
    }
    let Some(mut app) = App::start() else { return };
    app.run(3.0);
    let now = app.now();
    app.suite.goto_tab(1, now);
    app.run(4.0);
    let now = app.now();
    assert!(app.suite.open_card("collection:rc1", now));
    app.run(4.0);
    let texts = app.page_texts();
    for want in ["Alle", "Jahr", "Nordlicht, 2015", "Die Brücke, 2017"] {
        assert!(texts.iter().any(|t| t == want), "{want}: {texts:?}");
    }
    let seen = app.seen();
    assert!(
        seen.iter()
            .any(|l| l.contains("ParentId=rc1") && l.contains("Ascending")),
        "the collection is read as a shelf, by year ascending: {seen:?}"
    );
    // The filter pill: Alle, Angefangen, Merkliste (the first arrow lands on the checked row, then two steps).
    click_page(&mut app, "pill:filter");
    use swiftly_ui::{Dir, NavKey};
    press(&mut app, NavKey::Arrow(Dir::Down));
    press(&mut app, NavKey::Arrow(Dir::Down));
    press(&mut app, NavKey::Arrow(Dir::Down));
    press(&mut app, NavKey::Enter);
    app.run(3.0);
    let texts = app.page_texts();
    assert!(texts.iter().any(|t| t == "Merkliste"), "{texts:?}");
    assert!(
        app.seen()
            .iter()
            .any(|l| l.contains("ParentId=rc1") && l.contains("IsFavorite")),
        "the filter reloads the shelf"
    );
    // Nothing on the watchlist: the Mac's narrowed empty state, with its way out.
    assert!(texts.iter().any(|t| t == "Nichts gefunden"), "{texts:?}");
    assert!(
        texts.iter().any(|t| t == "Filter zurücksetzen"),
        "{texts:?}"
    );
    click_page(&mut app, "reset-filter");
    app.run(3.0);
    let texts = app.page_texts();
    assert!(texts.iter().any(|t| t == "Alle"), "{texts:?}");
    assert!(!texts.iter().any(|t| t == "Nichts gefunden"), "{texts:?}");
    // The sort pill: Name.
    click_page(&mut app, "pill:sort");
    for _ in 0..4 {
        press(&mut app, NavKey::Arrow(Dir::Up));
    }
    press(&mut app, NavKey::Enter);
    app.run(3.0);
    assert!(
        app.seen().iter().any(|l| l.contains("ParentId=rc1")
            && l.contains("SortName")
            && !l.contains("ProductionYear")),
        "the sort pill reloads the shelf by name"
    );
}

#[test]
fn collections_without_a_picture_get_a_mosaic_of_their_first_posters() {
    if !isolated("collections_without_a_picture_get_a_mosaic_of_their_first_posters") {
        return;
    }
    let Some(mut app) = App::start() else { return };
    app.run(3.0);
    let now = app.now();
    app.suite.goto_tab(1, now);
    app.run(5.0);
    assert_eq!(
        app.suite.movies().mosaic_counts(),
        [
            ("collection:rc2".to_owned(), 2),
            ("collection:rc3".to_owned(), 4)
        ],
        "rc1 has its own picture, rc2 two titles, rc3 four"
    );
    let seen = app.seen();
    assert!(
        seen.iter()
            .any(|l| l.contains("ParentId=rc3") && l.contains("Limit=4")),
        "{seen:?}"
    );
}

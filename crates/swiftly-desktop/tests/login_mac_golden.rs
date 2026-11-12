//! Frame goldens and behaviour tests of the desktop (Mac) sign-in flow: the kind picker, the Jellyfin and Emby pages,
//! Quick Connect, the Plex steps and the account list. `UPDATE_GOLDENS=1 cargo test --test login_mac_golden` rewrites them.
//! The four `login_desktop_*` goldens are shared with `forms_golden.rs` (same scenes, same names).

use std::path::PathBuf;
use swiftly_desktop::login_mac::PlexStep;
use swiftly_desktop::login_screen::{LoginScreen, Start, Step};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom, NavKey};

const FRAME_MS: f64 = 1000.0 / 60.0;
mod common;

fn env() -> Env {
    Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop)
}

fn check(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "golden {name}: size"
    );
    let (max, share) = img.diff(&golden);
    assert!(
        common::golden_ok(max, share),
        "golden {name} differs by {max} ({:.4} % of the pixels)",
        share * 100.0
    );
}

macro_rules! shoot {
    ($s:expr, $now:expr, $at:expr) => {{
        while *$now + FRAME_MS < $at {
            *$now += FRAME_MS;
            let _ = $s.frame(*$now);
        }
        *$now = $at;
        let _ = $s.frame($at);
        let (list, _) = $s.frame($at);
        $s.render_software(&list)
    }};
}

fn screen(start: Start) -> LoginScreen {
    LoginScreen::new(env(), Cx::deterministic(), start)
}

#[test]
fn shared_login_desktop_goldens() {
    let mut l = screen(Start::Address);
    let mut now = 0.0;
    check("login_desktop_initial", &shoot!(l, &mut now, 400.0));
    l.type_text("jellyfin.example.org");
    l.submit();
    l.type_text("paul");
    assert_eq!(l.step(), Step::Credentials);
    check("login_desktop_credentials", &shoot!(l, &mut now, 600.0));
    let mut q = screen(Start::Address);
    let mut now = 0.0;
    q.type_text("x.example.org");
    q.submit();
    q.nav_key(NavKey::Tab, true, 1.0);
    q.nav_key(NavKey::Tab, true, 5.0);
    q.quick_for_tests();
    check("login_desktop_quick", &shoot!(q, &mut now, 500.0));
    let mut a = screen(Start::Accounts);
    let mut now = 0.0;
    check("login_desktop_accounts", &shoot!(a, &mut now, 400.0));
}

#[test]
fn kind_picker_first_start_and_add() {
    let mut k = screen(Start::Kind);
    let mut now = 0.0;
    check("login_mac_kind", &shoot!(k, &mut now, 400.0));
    let mut a = screen(Start::AddKind);
    let mut now = 0.0;
    check("login_mac_kind_add", &shoot!(a, &mut now, 400.0));
    // Esc: the first start stays, "Server hinzufügen" closes.
    assert!(k.back(0.0) && k.is_open());
    a.back(0.0);
    assert!(!a.is_open());
}

#[test]
fn jellyfin_address_advanced_and_found() {
    let mut l = screen(Start::Kind);
    l.press("kind:0");
    assert_eq!(l.step(), Step::Address);
    l.press("adv:toggle");
    l.press("adv:add");
    l.type_text("CF-Access");
    let mut now = 0.0;
    check("login_mac_address_advanced", &shoot!(l, &mut now, 400.0));
    // Back goes to the picker, a tap on a found server fills the address and connects.
    l.back(0.0);
    assert_eq!(l.step(), Step::Kind);
    l.press("kind:0");
    l.press("found:0");
    assert_eq!(l.step(), Step::Credentials);
}

#[test]
fn quick_connect_skeleton_copy_and_expiry() {
    let mut l = screen(Start::Address);
    l.type_text("x.example.org");
    l.submit();
    l.quick_for_tests();
    let mut now = 0.0;
    let _ = l.frame(now);
    l.press("copy");
    assert_eq!(l.take_copy().as_deref(), Some("482915"));
    check("login_mac_quick_copied", &shoot!(l, &mut now, 400.0));
    l.skip_wait(400);
    let _ = l.frame(now + 1000.0);
    assert_eq!(
        l.error(),
        Some("Der Code ist abgelaufen. Hol dir einen neuen.")
    );
    l.press("password");
    assert_eq!(l.step(), Step::Credentials);
}

#[test]
fn emby_flow() {
    let mut l = screen(Start::Kind);
    l.press("kind:2");
    assert_eq!(l.step(), Step::EmbyAddress);
    let mut now = 0.0;
    check("login_mac_emby_address", &shoot!(l, &mut now, 300.0));
    l.type_text("emby.example.org");
    l.submit();
    assert_eq!(l.step(), Step::EmbyCredentials);
    check("login_mac_emby_loading", &shoot!(l, &mut now, 400.0));
    let _ = shoot!(l, &mut now, 1500.0);
    l.press("user:1");
    check("login_mac_emby_users", &shoot!(l, &mut now, 1600.0));
    l.type_text("geheim");
    l.submit();
    assert_eq!(l.signed_in(), Some("Mama"));
}

#[test]
fn emby_unreachable_shows_the_disturb_hint() {
    let mut l = screen(Start::Kind);
    l.press("kind:2");
    l.type_text("offline.example");
    l.submit();
    assert_eq!(l.step(), Step::EmbyAddress);
    assert!(l.error().is_some());
    let mut now = 0.0;
    check("login_mac_emby_disturb", &shoot!(l, &mut now, 300.0));
}

#[test]
fn plex_flow_steps() {
    let mut l = screen(Start::Kind);
    l.press("kind:1");
    assert_eq!(l.step(), Step::Plex);
    let mut now = 0.0;
    check("login_mac_plex_start", &shoot!(l, &mut now, 300.0));
    l.press("plexstart");
    check("login_mac_plex_opening", &shoot!(l, &mut now, 500.0));
    assert_eq!(l.plex_step(), PlexStep::Opening);
    let _ = shoot!(l, &mut now, 1400.0);
    assert_eq!(l.plex_step(), PlexStep::Waiting);
    check("login_mac_plex_waiting", &shoot!(l, &mut now, 1500.0));
    let _ = shoot!(l, &mut now, 4400.0);
    assert_eq!(l.plex_step(), PlexStep::Loading);
    check("login_mac_plex_loading", &shoot!(l, &mut now, 4450.0));
    let _ = shoot!(l, &mut now, 5200.0);
    assert_eq!(l.plex_step(), PlexStep::Profiles);
    check("login_mac_plex_profiles", &shoot!(l, &mut now, 5250.0));
    l.press("profile:1");
    assert_eq!(l.plex_step(), PlexStep::Pin);
    l.type_text("1111");
    check("login_mac_plex_pin_wrong", &shoot!(l, &mut now, 5500.0));
    l.type_text("1234");
    assert_eq!(l.plex_step(), PlexStep::Servers);
    check("login_mac_plex_servers", &shoot!(l, &mut now, 5800.0));
    l.press("server:0");
    assert_eq!(l.signed_in(), Some("Wohnzimmer"));
}

#[test]
fn plex_back_walks_one_step() {
    let mut l = screen(Start::Kind);
    l.press("kind:1");
    l.press("profile:1");
    assert_eq!(l.plex_step(), PlexStep::Pin);
    l.back(0.0);
    assert_eq!(l.plex_step(), PlexStep::Profiles);
    l.back(0.0);
    assert_eq!(l.plex_step(), PlexStep::Start);
    l.back(0.0);
    assert_eq!(l.step(), Step::Kind);
}

#[test]
fn kind_card_busy_mark_pair() {
    // The preparing card breathes (catalogue `Pulse`, 0.9 s per leg): full opacity at the start, dimmest 900 ms later;
    // clearing the mark brings it back with `Float`.
    let mut l = screen(Start::Kind);
    let mut now = 0.0;
    let _ = shoot!(l, &mut now, 500.0);
    l.set_kind_busy(Some(0));
    let start = now;
    check(
        "login_mac_kind_busy_start",
        &shoot!(l, &mut now, start + 20.0),
    );
    check(
        "login_mac_kind_busy_dim",
        &shoot!(l, &mut now, start + 900.0),
    );
    l.set_kind_busy(None);
    let at = now + 300.0;
    check("login_mac_kind_busy_cleared", &shoot!(l, &mut now, at));
}

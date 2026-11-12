//! The sign-in screen over a scripted backend (the real clients are tested in `signin_flows`): Emby address and users,
//! the Plex steps with the browser hand-off, the "Server ist abgetaucht" line for Jellyfin, and hover.

use std::rc::Rc;
use std::sync::mpsc::channel;
use swiftly_desktop::login_mac::PlexStep;
use swiftly_desktop::login_screen::{LoginScreen, Pending, SignInBackend, Step};
use swiftly_desktop::signin_flows::{EmbyFound, JELLYFIN_DOWN, PlexEvent};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn done<T>(v: T) -> Pending<T> {
    let (tx, rx) = Pending::channel();
    let _ = tx.send(v);
    rx
}

struct Fake {
    jellyfin_up: bool,
}

impl SignInBackend for Fake {
    fn connect(&self, _t: &str) -> Pending<Result<String, String>> {
        done(if self.jellyfin_up {
            Ok("https://jf.test".into())
        } else {
            Err(JELLYFIN_DOWN.into())
        })
    }
    fn password(&self, user: &str, _p: &str) -> Pending<Result<String, String>> {
        done(Ok(user.to_owned()))
    }
    fn quick_start(&self) -> Pending<Result<String, String>> {
        done(Ok("123456".into()))
    }
    fn quick_poll(&self) -> Pending<Result<Option<String>, String>> {
        done(Ok(None))
    }
    fn emby_connect(&self, _t: &str) -> Pending<Result<EmbyFound, String>> {
        done(Ok(EmbyFound {
            address: "https://emby.test".into(),
            name: "Emby Zuhause".into(),
            version: "4.8.8.0".into(),
        }))
    }
    fn emby_users(&self) -> Pending<Vec<String>> {
        done(vec!["Paul".into(), "Mama".into()])
    }
    fn plex_begin(&self) -> Option<std::sync::mpsc::Receiver<PlexEvent>> {
        let (tx, rx) = channel();
        tx.send(PlexEvent::Open(
            "https://app.plex.tv/auth#?code=K7QM".into(),
        ))
        .ok()?;
        tx.send(PlexEvent::Profiles(vec![
            ("Paul".into(), false),
            ("Mama".into(), true),
        ]))
        .ok()?;
        Some(rx)
    }
    fn plex_pick(&self, _i: usize, pin: &str) -> Pending<Result<Vec<(String, String)>, String>> {
        if pin == "0000" {
            done(Err("Die PIN des Profils stimmt nicht.".into()))
        } else {
            done(Ok(vec![(
                "Wohnzimmer".into(),
                "Zuhause · Plex Media Server".into(),
            )]))
        }
    }
    fn plex_finish(&self, _i: usize) -> Pending<Result<String, String>> {
        done(Ok("Paul".into()))
    }
}

fn screen(up: bool) -> LoginScreen {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    LoginScreen::live(env, Cx::deterministic(), Rc::new(Fake { jellyfin_up: up }))
}

fn run(l: &mut LoginScreen, ms: f64) {
    let mut now = 0.0;
    while now < ms {
        now += 50.0;
        let _ = l.frame(now);
    }
}

#[test]
fn emby_flow_shows_the_server_and_the_users() {
    let mut l = screen(true);
    l.press("kind:2");
    assert_eq!(l.step(), Step::EmbyAddress);
    l.type_text("emby.test");
    l.submit();
    run(&mut l, 300.0);
    assert_eq!(l.step(), Step::EmbyCredentials);
    l.press("user:1");
    l.submit();
    run(&mut l, 600.0);
    assert_eq!(l.signed_in(), Some("Mama"));
}

#[test]
fn plex_flow_hands_the_page_to_the_shell_and_signs_in() {
    let mut l = screen(true);
    l.press("kind:1");
    assert_eq!(l.step(), Step::Plex);
    l.press("plexstart");
    run(&mut l, 300.0);
    assert_eq!(
        l.take_open().as_deref(),
        Some("https://app.plex.tv/auth#?code=K7QM")
    );
    assert!(l.take_open().is_none());
    assert_eq!(l.plex_step(), PlexStep::Profiles);
    l.press("profile:1");
    assert_eq!(l.plex_step(), PlexStep::Pin);
    l.type_text("0000");
    run(&mut l, 200.0);
    assert_eq!(l.plex_step(), PlexStep::Pin);
    l.type_text("1234");
    run(&mut l, 200.0);
    assert_eq!(l.plex_step(), PlexStep::Servers);
    l.press("server:0");
    run(&mut l, 300.0);
    assert_eq!(l.signed_in(), Some("Paul"));
}

#[test]
fn a_silent_jellyfin_keeps_its_line_and_hover_is_routed() {
    let mut l = screen(false);
    l.press("kind:0");
    l.type_text("weg.test");
    l.submit();
    run(&mut l, 300.0);
    assert_eq!(l.error(), Some(JELLYFIN_DOWN));
    l.pointer_move(100.0, 100.0, 400.0);
    l.pointer_leave(450.0);
}

#[test]
fn tab_moves_to_the_password_and_select_all_replaces_the_text() {
    let mut l = screen(true);
    l.press("kind:0");
    l.type_text("jelly.test");
    l.submit();
    run(&mut l, 300.0);
    assert_eq!(l.step(), Step::Credentials);
    l.type_text("demo");
    assert!(l.tab_field(false), "Tab must have a next field");
    l.type_text("geheim");
    assert_eq!(
        l.field_text(),
        "geheim",
        "the password field takes the typing, not the user field"
    );
    // Shift+Tab goes back; Tab wraps round.
    assert!(l.tab_field(true));
    assert_eq!(l.field_text(), "demo");
    assert!(l.tab_field(false) && l.tab_field(false));
    assert_eq!(l.field_text(), "demo");
    // Ctrl+A selects the whole field; the next typing replaces it; a caret key ends the selection; Backspace clears it.
    l.select_all();
    assert!(l.is_selected());
    l.type_text("neu");
    assert_eq!((l.is_selected(), l.field_text().as_str()), (false, "neu"));
    l.select_all();
    l.deselect();
    l.type_text("er");
    assert_eq!(l.field_text(), "neuer");
    l.select_all();
    l.backspace();
    assert_eq!(l.field_text(), "");
    // An empty field has nothing to select.
    l.select_all();
    assert!(!l.is_selected());
}

#[test]
fn sign_in_fields_move_the_caret_select_and_use_the_clipboard_and_a_password_stays_inside() {
    use swiftly_text::{EditKey, MemoryClipboard, Mods, TextInputEvent as E};
    let mut l = screen(true);
    l.set_clipboard(Box::new(MemoryClipboard::default()));
    l.press("kind:0");
    l.type_text("jelly.test");
    l.submit();
    run(&mut l, 300.0);
    assert_eq!(l.step(), Step::Credentials);
    // Caret keys: Home, a word jump, typing in the middle, Delete.
    l.type_text("max mustermann");
    l.edit(&E::Key(EditKey::Home, Mods::NONE));
    l.edit(&E::Key(EditKey::Right, Mods::WORD));
    l.type_text("!");
    assert_eq!(l.field_text(), "max! mustermann");
    l.edit(&E::Key(EditKey::Delete, Mods::NONE));
    assert_eq!(l.field_text(), "max!mustermann");
    // Selection by Shift+End, copy, paste at the end.
    l.edit(&E::Key(EditKey::Home, Mods::NONE));
    l.edit(&E::Key(EditKey::Right, Mods::SHIFT_WORD));
    l.edit(&E::Copy);
    l.edit(&E::Key(EditKey::End, Mods::NONE));
    l.edit(&E::Paste);
    assert_eq!(l.field_text(), "max!mustermannmax");
    // Mouse: the pointer's index places the caret and extends the selection.
    l.edit(&E::SetCaret {
        index: 0,
        extend: false,
    });
    l.edit(&E::SetCaret {
        index: 3,
        extend: true,
    });
    l.edit(&E::Cut);
    assert_eq!(l.field_text(), "!mustermannmax");
    // The password: a paste goes in, copy and cut do nothing, the clipboard keeps the user name's text.
    assert!(l.tab_field(false));
    l.edit(&E::Paste);
    assert_eq!(l.field_text(), "max");
    l.edit(&E::SelectAll);
    l.edit(&E::Copy);
    l.edit(&E::Cut);
    assert_eq!(l.field_text(), "max", "a password cannot be cut out");
    assert!(l.tab_field(true));
    l.edit(&E::SelectAll);
    l.edit(&E::Paste);
    assert_eq!(
        l.field_text(),
        "max",
        "the clipboard never got the password (it still holds the earlier copy)"
    );
}

//! The sign-in screen over a scripted backend (the real clients are tested in `signin_flows`): Emby address and users,
//! the Plex steps with the browser hand-off, the "Server ist abgetaucht" line for Jellyfin, and hover.

use std::rc::Rc;
use std::sync::mpsc::channel;
use swiftly_desktop::login_mac::PlexStep;
use swiftly_desktop::login_screen::{LoginScreen, Pending, SignInBackend, Step};
use swiftly_desktop::signin_flows::{EmbyFound, JELLYFIN_DOWN, PlexEvent, QuickAnswer};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

thread_local! {
    /// A test that holds the "Quick Connect on?" answer back, and the sender it is answered with later.
    static HOLD_OFFER: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static HELD_OFFER: std::cell::RefCell<Option<std::sync::mpsc::Sender<bool>>> = const { std::cell::RefCell::new(None) };
}

fn done<T>(v: T) -> Pending<T> {
    let (tx, rx) = Pending::channel();
    let _ = tx.send(v);
    rx
}

struct Fake {
    jellyfin_up: bool,
    /// Whether the server has Quick Connect on.
    offers: bool,
    /// The answers of the next Quick Connect polls (the last one repeats).
    polls: std::cell::RefCell<Vec<QuickAnswer>>,
    /// The Plex profiles the account has.
    profiles: Vec<(String, bool)>,
    /// The Plex servers the account lists (name, line).
    servers: Vec<(String, String)>,
    /// Connecting to a Plex server fails.
    finish_fails: bool,
    /// The Plex worker ends with this instead of the profiles.
    plex_ends: Option<PlexEvent>,
    /// The codes the Quick Connect share was asked with; "000000" is refused.
    shared: std::cell::RefCell<Vec<String>>,
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
    fn quick_poll(&self) -> Pending<QuickAnswer> {
        let mut p = self.polls.borrow_mut();
        done(if p.len() > 1 {
            p.remove(0)
        } else {
            p.first().cloned().unwrap_or(QuickAnswer::Waiting)
        })
    }
    fn quick_offered(&self) -> Pending<bool> {
        if HOLD_OFFER.get() {
            let (tx, rx) = Pending::channel();
            HELD_OFFER.with(|h| *h.borrow_mut() = Some(tx));
            return rx;
        }
        done(self.offers)
    }
    fn quick_share(&self, code: &str) -> Pending<Result<(), String>> {
        self.shared.borrow_mut().push(code.to_owned());
        done(if code == "000000" {
            Err("Der Code ist abgelaufen oder falsch.".into())
        } else {
            Ok(())
        })
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
        if let Some(end) = self.plex_ends.clone() {
            tx.send(end).ok()?;
            return Some(rx);
        }
        tx.send(PlexEvent::Account("viewer@plex.test".into())).ok()?;
        tx.send(PlexEvent::Profiles(self.profiles.clone())).ok()?;
        Some(rx)
    }
    fn plex_pick(&self, _i: usize, pin: &str) -> Pending<Result<Vec<(String, String)>, String>> {
        if pin == "0000" {
            done(Err("Die PIN des Profils stimmt nicht.".into()))
        } else {
            done(Ok(self.servers.clone()))
        }
    }
    fn plex_finish(&self, _i: usize) -> Pending<Result<String, String>> {
        done(if self.finish_fails {
            Err("Plex ist gerade nicht erreichbar.".into())
        } else {
            Ok("Paul".into())
        })
    }
}

fn screen(up: bool) -> LoginScreen {
    screen_with(up, true, vec![])
}

fn plex_fake() -> Fake {
    Fake {
        jellyfin_up: true,
        offers: true,
        polls: std::cell::RefCell::new(vec![]),
        profiles: vec![("Paul".into(), false), ("Mama".into(), true)],
        servers: vec![("Wohnzimmer".into(), "Dein Server · im WLAN".into())],
        finish_fails: false,
        plex_ends: None,
        shared: Default::default(),
    }
}

fn screen_with(up: bool, offers: bool, polls: Vec<QuickAnswer>) -> LoginScreen {
    let fake = Fake {
        jellyfin_up: up,
        offers,
        polls: std::cell::RefCell::new(polls),
        profiles: vec![("Paul".into(), false), ("Mama".into(), true)],
        servers: vec![("Wohnzimmer".into(), "Dein Server · im WLAN".into())],
        finish_fails: false,
        plex_ends: None,
        shared: Default::default(),
    };
    screen_of(fake)
}

fn screen_of(fake: Fake) -> LoginScreen {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    LoginScreen::live(env, Cx::deterministic(), Rc::new(fake))
}

/// To the Jellyfin sign-in page (kind card, address, check).
fn to_sign_in(l: &mut LoginScreen) {
    l.press("kind:0");
    l.type_text("jf.test");
    l.submit();
    run(l, 300.0);
    assert_eq!(l.step(), Step::Credentials);
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

#[test]
fn the_quick_connect_button_shows_only_when_the_server_offers_it() {
    let mut off = screen_with(true, false, vec![]);
    to_sign_in(&mut off);
    assert!(
        off.frame_of("quick").is_none(),
        "no dead Quick Connect button"
    );
    let mut on = screen_with(true, true, vec![]);
    to_sign_in(&mut on);
    assert!(on.frame_of("quick").is_some());
}

#[test]
fn one_failed_poll_does_not_end_the_quick_connect_wait() {
    let polls = vec![
        QuickAnswer::Failed,
        QuickAnswer::Waiting,
        QuickAnswer::SignedIn("Paul".into()),
    ];
    let mut l = screen_with(true, true, polls);
    to_sign_in(&mut l);
    l.press("quick");
    // A poll every two seconds: the first fails, the second waits, the third approves.
    run(&mut l, 7000.0);
    assert!(l.error().is_none(), "{:?}", l.error());
    assert_eq!(l.signed_in(), Some("Paul"));
}

#[test]
fn an_expired_code_stays_visible_at_zero_and_leaving_halts_the_wait() {
    let mut l = screen_with(true, true, vec![]);
    to_sign_in(&mut l);
    l.press("quick");
    run(&mut l, 300.0);
    assert!(l.seconds_left() > 290);
    l.skip_wait(301);
    run(&mut l, 300.0);
    assert_eq!(l.seconds_left(), 0);
    assert!(
        l.frame_of("copy").is_some(),
        "the Mac keeps the code on screen at 0:00"
    );
    l.press("password");
    assert_eq!(l.step(), Step::Credentials);
}

#[test]
fn escape_goes_back_while_a_field_has_the_cursor() {
    let mut l = screen(true);
    to_sign_in(&mut l);
    assert!(l.wants_text());
    let _ = l.nav_key(swiftly_ui::NavKey::Escape, true, 1000.0);
    assert_eq!(l.step(), Step::Address);
}

/// The Plex page after "Mit Plex anmelden" was pressed.
fn plex_started(fake: Fake) -> LoginScreen {
    let mut l = screen_of(fake);
    l.press("kind:1");
    l.press("plexstart");
    run(&mut l, 300.0);
    let _ = l.take_open();
    l
}

#[test]
fn seite_noch_mal_oeffnen_opens_the_same_page_again() {
    let mut fake = plex_fake();
    fake.plex_ends = Some(PlexEvent::Open(
        "https://app.plex.tv/auth#?code=K7QM".into(),
    ));
    let mut l = screen_of(fake);
    l.press("kind:1");
    l.press("plexstart");
    run(&mut l, 300.0);
    assert!(l.take_open().is_some());
    l.press("plexreopen");
    assert_eq!(
        l.take_open().as_deref(),
        Some("https://app.plex.tv/auth#?code=K7QM")
    );
}

#[test]
fn one_plex_profile_goes_straight_to_the_servers_and_back_leaves() {
    let mut fake = plex_fake();
    fake.profiles = vec![("Paul".into(), false)];
    let mut l = plex_started(fake);
    run(&mut l, 300.0);
    assert_eq!(
        l.plex_step(),
        PlexStep::Servers,
        "no chooser for one profile"
    );
    assert!(l.back(0.0));
    assert_eq!(
        l.step(),
        Step::Kind,
        "back from the servers leaves the Plex page"
    );
}

#[test]
fn an_account_without_a_server_can_search_again_or_switch_account() {
    let mut fake = plex_fake();
    fake.profiles = vec![("Paul".into(), false)];
    fake.servers = vec![];
    let mut l = plex_started(fake);
    run(&mut l, 300.0);
    assert_eq!(l.plex_step(), PlexStep::Servers);
    assert!(l.frame_of("plexreload").is_some(), "Noch mal suchen");
    assert!(l.frame_of("plexother").is_some(), "Anderes Plex-Konto");
    l.press("plexother");
    assert_eq!(l.plex_step(), PlexStep::Start);
}

#[test]
fn a_server_that_does_not_answer_stays_in_the_list() {
    let mut fake = plex_fake();
    fake.profiles = vec![("Paul".into(), false)];
    fake.finish_fails = true;
    let mut l = plex_started(fake);
    run(&mut l, 300.0);
    l.press("server:0");
    run(&mut l, 300.0);
    assert_eq!(
        l.plex_step(),
        PlexStep::Servers,
        "the list stays, not the failed page"
    );
    assert!(l.frame_of("server:0").is_some(), "tap for a new try");
    assert!(l.signed_in().is_none());
}

#[test]
fn an_expired_plex_code_gets_its_own_page_with_a_new_code() {
    let mut fake = plex_fake();
    fake.plex_ends = Some(PlexEvent::Expired);
    let mut l = plex_started(fake);
    run(&mut l, 300.0);
    assert_eq!(l.plex_step(), PlexStep::Failed);
    assert!(l.frame_of("plexagain").is_some(), "Neuen Code holen");
}

#[test]
fn the_fourth_pin_digit_sends_the_pin_without_return() {
    let mut l = plex_started(plex_fake());
    run(&mut l, 300.0);
    l.press("profile:1");
    assert_eq!(l.plex_step(), PlexStep::Pin);
    l.type_text("1234");
    run(&mut l, 300.0);
    assert_eq!(l.plex_step(), PlexStep::Servers);
}

fn share_page(fake: Fake) -> LoginScreen {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    LoginScreen::share(env, Cx::deterministic(), Rc::new(fake))
}

#[test]
fn the_quick_connect_share_page_approves_a_code_and_closes_after_two_seconds() {
    let mut l = share_page(plex_fake());
    assert_eq!(l.step(), Step::Share);
    assert!(l.wants_text());
    l.type_text("123");
    run(&mut l, 100.0);
    l.press("share");
    run(&mut l, 200.0);
    assert!(l.is_open(), "under four characters nothing is sent");
    l.type_text("456");
    l.press("share");
    run(&mut l, 500.0);
    assert!(l.is_open(), "the message stands for a moment");
    let mut now = 500.0;
    while now < 3000.0 {
        now += 50.0;
        let _ = l.frame(now);
    }
    assert!(!l.is_open(), "back after two seconds");
}

#[test]
fn a_refused_share_code_shows_the_sentence_and_stays() {
    let mut l = share_page(plex_fake());
    l.type_text("000000");
    l.press("share");
    run(&mut l, 2600.0);
    assert!(l.is_open());
    assert!(l.frame_of("share").is_some());
}

/// The answer to "is Quick Connect on?" arrives on its own, some time after the credentials page opened: while it is
/// on its way the window keeps asking for frames, or the button waited for a key press or a mouse move to appear.
#[test]
fn the_quick_connect_answer_wakes_the_window() {
    HOLD_OFFER.set(true);
    let mut l = screen_with(true, true, Vec::new());
    l.press("kind:0");
    l.type_text("jf.test");
    l.submit();
    run(&mut l, 400.0);
    assert_eq!(l.step(), Step::Credentials);
    let _ = l.frame(500.0);
    assert!(
        l.pending(),
        "no frame is asked for while the answer is on its way"
    );
    HELD_OFFER.with(|h| h.borrow().as_ref().unwrap().send(true).unwrap());
    HOLD_OFFER.set(false);
    let _ = l.frame(550.0);
    let _ = l.frame(600.0);
    assert!(
        !l.pending(),
        "the page keeps asking for frames after the answer"
    );
}

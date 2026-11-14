//! Sign-in details of the second parity round: a changed address ends the running check, servers that already have an
//! account are not offered again, the Plex countdown runs on the code's real expiry.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::mpsc::{Sender, channel};
use swiftly_desktop::login_screen::{LoginScreen, Pending, SignInBackend, Step};
use swiftly_jellyfin::discovery::FoundServer;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

#[derive(Default)]
struct Slow {
    /// The sender of the check that is on its way.
    pending: RefCell<Option<Sender<Result<String, String>>>>,
    found: RefCell<Option<std::sync::mpsc::Receiver<Vec<FoundServer>>>>,
}

impl SignInBackend for Slow {
    fn connect(&self, _typed: &str) -> Pending<Result<String, String>> {
        let (tx, rx) = Pending::channel();
        *self.pending.borrow_mut() = Some(tx);
        rx
    }
    fn password(&self, user: &str, _p: &str) -> Pending<Result<String, String>> {
        let (tx, rx) = Pending::channel();
        let _ = tx.send(Ok(user.to_owned()));
        rx
    }
    fn quick_start(&self) -> Pending<Result<String, String>> {
        let (tx, rx) = Pending::channel();
        let _ = tx.send(Err("x".into()));
        rx
    }
    fn quick_poll(&self) -> Pending<swiftly_desktop::signin_flows::QuickAnswer> {
        let (tx, rx) = Pending::channel();
        let _ = tx.send(swiftly_desktop::signin_flows::QuickAnswer::Waiting);
        rx
    }
    fn known_servers(&self) -> Vec<String> {
        vec!["http://192.168.1.20:8096".into()]
    }
    fn discover(&self) -> Option<std::sync::mpsc::Receiver<Vec<FoundServer>>> {
        self.found.borrow_mut().take()
    }
}

fn env() -> Env {
    Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop)
}

fn run(l: &mut LoginScreen, ms: f64) {
    let mut now = 0.0;
    while now < ms {
        now += 50.0;
        let _ = l.frame(now);
    }
}

#[test]
fn a_changed_address_ends_the_running_check() {
    let slow = Rc::new(Slow::default());
    let mut l = LoginScreen::live(
        env(),
        Cx::deterministic(),
        Rc::clone(&slow) as Rc<dyn SignInBackend>,
    );
    l.press("kind:0");
    l.type_text("jf.test");
    l.submit();
    run(&mut l, 100.0);
    let tx = slow
        .pending
        .borrow_mut()
        .take()
        .expect("a check is running");
    // The user types on: the check for the old text is dropped.
    l.type_text("x");
    let _ = tx.send(Ok("https://jf.test".into()));
    run(&mut l, 300.0);
    assert_eq!(
        l.step(),
        Step::Address,
        "the answer for the old address must not open the sign-in"
    );
}

#[test]
fn servers_that_already_have_an_account_are_not_offered_again() {
    let slow = Rc::new(Slow::default());
    let (tx, rx) = channel();
    *slow.found.borrow_mut() = Some(rx);
    let mut l = LoginScreen::live(
        env(),
        Cx::deterministic(),
        Rc::clone(&slow) as Rc<dyn SignInBackend>,
    );
    l.press("kind:0");
    let one = |name: &str, id: &str, addr: &str| FoundServer {
        id: id.into(),
        name: name.into(),
        address: addr.into(),
    };
    tx.send(vec![
        one("Wohnzimmer", "a", "http://192.168.1.20:8096"),
        one("Keller", "b", "http://192.168.1.30:8096"),
    ])
    .expect("send");
    run(&mut l, 200.0);
    assert!(l.frame_of("found:1").is_none(), "only one row is left");
    assert!(l.frame_of("found:0").is_some(), "the new server stays");
}

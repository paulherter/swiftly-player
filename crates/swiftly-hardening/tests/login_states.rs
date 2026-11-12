//! Login view-model equality: the Rust `LoginVm` (plus the Plex and Emby page models and the Quick
//! Connect wait) must walk the same states and show the same texts as the Swift app. No UI.
//!
//! Swift sources (the truth): `Sources/Shared/RootView.swift` (address page `linkUp`, `LoginView`),
//! `AppModel.swift` (`connectStart`, `addressChanged`, `connect(to:)`, `connectionError`, `login`),
//! `LoginModel.swift` (`signInWithQuickConnect`), `QuickConnectModel.swift`, `QuickConnectLogin.swift`,
//! `QuickConnectWait.swift` (package), `SignInModels.swift`, `AppModel+Servers.swift` (`PlexRun`, Emby).
//!
//! TRANSITION TABLE  (id: Swift behaviour -> asserted on Rust)
//!
//! Address step
//!  A1  Connect button disabled while the field is empty or a check runs -> `can_connect`
//!  A2  empty field: nothing happens, no message (`guard !address.isEmpty`)  -> no effect, no error
//!  A3  unreadable address: "Die Adresse konnte nicht gelesen werden.", no network -> error text
//!  A4  check starts: working, error cleared -> `CheckAddress`, `working`
//!  A5  second Connect while checking is ignored (`guard ongoing == nil`)
//!  A6  editing the address discards the running check, a late answer changes nothing
//!  A7  success: phase Credentials, name = serverName ?? host ?? "Server", version ?? "?", remembered
//!  A8  no scheme typed: https first; if it fails and `fallbackPaysOff`, http once (and vice versa)
//!  A9  DNS / timeout / offline codes never trigger the second attempt (`fallbackPaysOff`)
//!  A10 a scheme typed: no second attempt
//!  A11 both fail: the FIRST attempt's reason is shown (`realReason`)
//!  A12 offline on a home-network address: the local-network permission hint
//!  A13 found server tapped: field filled and connect starts (`address = ...; linkUp()`)
//!  A14 "Zuletzt verbunden" tapped: field filled and connect starts
//!  A15 found list hides the server in the field and the last one
//! Password step
//!  P1  Sign-in disabled while working or user empty -> `can_sign_in`
//!  P2  sign in: working, error cleared, `Authenticate`
//!  P3  success: `Done(session)`, working off
//!  P4  failure (wrong password 401, two-factor, network): readable text, working off, fields kept
//!  P5  one public user is picked by the host; tapping a user fills the field (`user = person.name`)
//!  P6  Back: password -> address
//! Quick Connect
//!  Q1  button only when the server offers it (and not while working)
//!  Q2  start: page opens, working, countdown 300 s, error cleared
//!  Q3  code arrives: shown, working off
//!  Q4  start fails: readable text, back to the password step
//!  Q5  wait ticks: countdown follows `rest` (rounded up), "m:ss"
//!  Q6  `opened` poll answers change nothing
//!  Q7  released: sign in with that code, working; a second `released` signs nobody in again
//!  Q8  sign-in after release fails: text, back to the password step, code gone
//!  Q9  expired (404): "Der Code ist abgelaufen. Hol dir einen neuen.", countdown 0, code gone
//!  Q10 deadline with last poll failed: "Der Server hat nicht geantwortet."; else the expired text
//!  Q11 network errors during the wait never end it (polls keep going on the clock)
//!  Q12 poll timing: asks at the first tick after `poll` seconds, immediately after a long background gap
//!  Q13 "Neuen Code holen": new start, old code dropped, countdown 300, error cleared; refused while
//!      the approved code signs in
//!  Q14 Back/cancel from the page: code gone, wait over, no effect
//! Plex (`PlexRun`, `PlexSignInModel`)
//!  X1  start -> Opening -> Waiting(prompt); title "Mit Plex anmelden" then Plex kind name
//!  X2  countdown beat keeps the prompt; a beat with 0 s hides it (deliberate: Swift shows 0)
//!  X3  poll: expiry on the clock ends it, 404/410 ends at once, 5 failures in a row end it, a good beat resets
//!  X4  five failed beats with a network error: plex.tv unreachable (Swift `fail`), else readable text
//!  X5  profiles (Plex Home), protected profile -> pin step, wrong PIN stays, unprotected refusal ends
//!  X6  servers list, empty = empty state (noServer), pick server: connecting, unreachable row, one at a time
//!  X7  back: pin/servers -> profiles only if there were several, else leave
//!  X8  other account resets everything to the first page
//! Emby (`EmbySignInModel`, `embyCheck`)
//!  E1  address step -> sign-in step with name and version; one user is preselected
//!  E2  back from sign-in: address step and the sign-in error is cleared; from address: leave
//!  E3  problem texts: not Emby (named / unnamed), bad address, login page; "Mit Jellyfin weiter" only for Jellyfin
//!
//! Deliberate improvements over Swift (the user only sees better):
//!  - the user name is trimmed and a blank one disables the button (Swift sends it raw)
//!  - the last server stores the full address with port; Swift stores the bare host
//!  - editing the address clears a stale error even without a running check (Swift keeps it)
//!  - an expired / failed Quick Connect returns to the password step with the message visible
//!    (Swift keeps the dead code on screen and hides the message behind it)
//!  - an empty server name falls back to the host (Swift would show an empty title)
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_jellyfin::{
    EmbyProblem, LoginCode, QuickConnectDeadline, QuickConnectState, QuickConnectWait, ServerKind,
    Session, WaitEvent,
};
use swiftly_l10n::error_text::readable_error;
use swiftly_l10n::{Locale, Translator};
use swiftly_model::PublicSystemInfo;
use swiftly_net::ErrorKind;
use swiftly_plex::PlexError;
use swiftly_settings::MemoryStore;
use swiftly_vm::plex_sign_in::{
    Back, EmbySignInModel, EmbyStep, EmbyUserChoice, Placeholder, PlexAnswer, PlexPoll,
    PlexProfileChoice, PlexServerChoice, PlexSignInModel, PlexSignInProblem, PlexStep, PollNext,
    PollResult, emby_problem_text, offers_jellyfin,
};
use swiftly_vm::{LoginEffect, LoginIntent, LoginPart, LoginScreen, LoginVm, ServerReminder};

fn tr() -> Translator {
    Translator::new(Locale::parse("de"))
}

fn vm() -> LoginVm<MemoryStore> {
    LoginVm::new(MemoryStore::new(), Locale::parse("de"))
}

fn info(name: Option<&str>, version: Option<&str>) -> PublicSystemInfo {
    PublicSystemInfo {
        server_name: name.map(Into::into),
        version: version.map(Into::into),
        id: None,
        product_name: None,
    }
}

fn session() -> Session {
    Session {
        access_token: "t".into(),
        user_id: "u".into(),
        user_name: "Anna".into(),
        server_url: "http://192.168.1.5:8096".into(),
        kind: ServerKind::Jellyfin,
    }
}

fn code(c: &str) -> LoginCode {
    LoginCode {
        code: c.into(),
        confidential: format!("secret-{c}"),
    }
}

/// The scripted host for the address check: answers the first effect of a list.
fn check_of(effects: Vec<LoginEffect>) -> (swiftly_jellyfin::CheckMark, String) {
    match effects.into_iter().next() {
        Some(LoginEffect::CheckAddress { mark, url }) => (mark, url),
        other => panic!("no address check: {other:?}"),
    }
}

fn type_address(vm: &mut LoginVm<MemoryStore>, text: &str) {
    vm.handle(LoginIntent::EditAddress(text.into()));
}

/// Connects to `192.168.1.5:8096` and answers the check: the screen is the password step.
fn to_credentials(vm: &mut LoginVm<MemoryStore>) {
    type_address(vm, "192.168.1.5:8096");
    let (mark, url) = check_of(vm.handle(LoginIntent::Connect));
    assert_eq!(url, "http://192.168.1.5:8096");
    vm.handle(LoginIntent::AddressChecked {
        mark,
        result: Ok(info(Some("Wohnzimmer"), Some("10.9.0"))),
    });
}

/// The Quick Connect page with `123 456` shown.
fn to_quick(vm: &mut LoginVm<MemoryStore>) {
    to_credentials(vm);
    vm.handle(LoginIntent::QuickConnectOffered(true));
    assert_eq!(
        vm.handle(LoginIntent::UseQuickConnect),
        vec![LoginEffect::StartQuickConnect]
    );
    vm.handle(LoginIntent::QuickConnectStarted(Ok(code("123456"))));
}

fn p(vm: &LoginVm<MemoryStore>) -> &LoginPart {
    vm.part()
}

// ---------------------------------------------------------------- address step

#[test]
fn a1_a2_a3_connect_button_and_unusable_addresses() {
    let mut vm = vm();
    assert!(!p(&vm).can_connect, "A1 empty field: button disabled");
    assert!(vm.handle(LoginIntent::Connect).is_empty());
    assert!(
        p(&vm).error.is_none() && !p(&vm).working,
        "A2 empty field: nothing happens, nothing said"
    );
    type_address(&mut vm, "   ");
    assert!(
        p(&vm).can_connect,
        "A1 the button follows `isEmpty`, not a trimmed text"
    );
    assert!(vm.handle(LoginIntent::Connect).is_empty());
    assert_eq!(
        p(&vm).error.as_deref(),
        Some("Die Adresse konnte nicht gelesen werden."),
        "A3"
    );
    assert!(!p(&vm).working);
}

#[test]
fn a4_a5_a6_a7_check_lifecycle() {
    let mut vm = vm();
    type_address(&mut vm, "a.example.de");
    let (old, url) = check_of(vm.handle(LoginIntent::Connect));
    assert_eq!(url, "https://a.example.de", "A4");
    assert!(
        p(&vm).working && p(&vm).error.is_none() && !p(&vm).can_connect,
        "A4/A1 busy"
    );
    assert!(
        vm.handle(LoginIntent::Connect).is_empty(),
        "A5 second press ignored"
    );
    type_address(&mut vm, "b.example.de");
    assert!(!p(&vm).working, "A6 editing ends the check");
    vm.handle(LoginIntent::AddressChecked {
        mark: old,
        result: Ok(info(Some("A"), Some("1"))),
    });
    assert_eq!(
        p(&vm).screen,
        LoginScreen::Address,
        "A6 late answer ignored"
    );
    assert!(vm.last_server().is_none());

    // A7: name / version fallbacks and what is remembered.
    let mut vm = self::vm();
    type_address(&mut vm, "192.168.1.5:8096");
    let (mark, _) = check_of(vm.handle(LoginIntent::Connect));
    vm.handle(LoginIntent::AddressChecked {
        mark,
        result: Ok(info(None, None)),
    });
    assert_eq!(p(&vm).screen, LoginScreen::Credentials);
    assert_eq!(
        p(&vm).server_name.as_deref(),
        Some("192.168.1.5"),
        "A7 name falls back to the host"
    );
    assert_eq!(
        vm.last_server().unwrap().version,
        "?",
        "A7 version falls back to ?"
    );
    assert!(!p(&vm).working && p(&vm).error.is_none());
    let mut vm = self::vm();
    to_credentials(&mut vm);
    assert_eq!(p(&vm).server_name.as_deref(), Some("Wohnzimmer"));
    assert_eq!(
        vm.last_server().unwrap(),
        ServerReminder {
            address: "http://192.168.1.5:8096".into(),
            name: "Wohnzimmer".into(),
            version: "10.9.0".into()
        }
    );
}

#[test]
fn a8_to_a11_second_scheme_rules() {
    let refused = ErrorKind::Network { code: -1004 };
    // A8: https first, then http once; both failing shows the first reason (A11).
    let mut vm = vm();
    type_address(&mut vm, "tv.example.de");
    let (m1, u1) = check_of(vm.handle(LoginIntent::Connect));
    assert_eq!(u1, "https://tv.example.de");
    let (m2, u2) = check_of(vm.handle(LoginIntent::AddressChecked {
        mark: m1,
        result: Err(refused.clone()),
    }));
    assert_eq!(u2, "http://tv.example.de", "A8");
    assert!(p(&vm).working, "A8 still checking");
    let second = ErrorKind::Http {
        status: 502,
        body: None,
    };
    assert!(
        vm.handle(LoginIntent::AddressChecked {
            mark: m2,
            result: Err(second)
        })
        .is_empty()
    );
    assert_eq!(
        p(&vm).error,
        Some(readable_error(&tr(), &refused)),
        "A11 first reason"
    );
    assert!(!p(&vm).working);

    // A9: names that do not resolve, timeouts and offline never pay off.
    for code in [-1003, -1006, -1001, -999, -1009] {
        let mut vm = self::vm();
        type_address(&mut vm, "tv.example.de");
        let (m, _) = check_of(vm.handle(LoginIntent::Connect));
        let next = vm.handle(LoginIntent::AddressChecked {
            mark: m,
            result: Err(ErrorKind::Network { code }),
        });
        assert!(next.is_empty(), "A9 code {code}");
        assert!(p(&vm).error.is_some() && !p(&vm).working);
    }
    // ... while a certificate failure does (everything else pays off).
    let mut vm = self::vm();
    type_address(&mut vm, "tv.example.de");
    let (m, _) = check_of(vm.handle(LoginIntent::Connect));
    let cert = ErrorKind::Certificate(swiftly_net::CertificateReason::NotTrusted);
    assert_eq!(
        vm.handle(LoginIntent::AddressChecked {
            mark: m,
            result: Err(cert)
        })
        .len(),
        1,
        "A8 certificate pays off"
    );

    // A10: a typed scheme is final.
    let mut vm = self::vm();
    type_address(&mut vm, "https://tv.example.de");
    let (m, u) = check_of(vm.handle(LoginIntent::Connect));
    assert_eq!(u, "https://tv.example.de");
    assert!(
        vm.handle(LoginIntent::AddressChecked {
            mark: m,
            result: Err(refused.clone())
        })
        .is_empty(),
        "A10"
    );
    assert_eq!(p(&vm).error, Some(readable_error(&tr(), &refused)));
    // A retry after a failure starts clean again (second attempt allowed once more).
    type_address(&mut vm, "tv.example.de");
    let (m, _) = check_of(vm.handle(LoginIntent::Connect));
    assert_eq!(
        vm.handle(LoginIntent::AddressChecked {
            mark: m,
            result: Err(refused)
        })
        .len(),
        1
    );
}

#[test]
fn a12_offline_on_the_home_network_points_at_the_permission() {
    let hint = tr().t("Der Server war nicht erreichbar. Hat Swiftly die Erlaubnis, Geräte im heimischen Netz zu suchen? Sie steht in den Systemeinstellungen unter „Swiftly · Lokales Netzwerk\".");
    let mut vm = vm();
    type_address(&mut vm, "http://192.168.1.5:8096");
    let (m, _) = check_of(vm.handle(LoginIntent::Connect));
    vm.handle(LoginIntent::AddressChecked {
        mark: m,
        result: Err(ErrorKind::Network { code: -1009 }),
    });
    assert_eq!(
        p(&vm).error.as_deref(),
        Some(hint.as_str()),
        "A12 home network"
    );
    let mut vm = self::vm();
    type_address(&mut vm, "https://tv.example.de");
    let (m, _) = check_of(vm.handle(LoginIntent::Connect));
    vm.handle(LoginIntent::AddressChecked {
        mark: m,
        result: Err(ErrorKind::Network { code: -1009 }),
    });
    assert_eq!(
        p(&vm).error,
        Some(readable_error(&tr(), &ErrorKind::Network { code: -1009 })),
        "A12 outside: plain text"
    );
    assert_ne!(p(&vm).error.as_deref(), Some(hint.as_str()));
}

#[test]
fn a13_a14_a15_found_and_last_servers_connect_at_once() {
    use swiftly_jellyfin::discovery::FoundServer;
    let mut vm = vm();
    let a = FoundServer {
        id: "1".into(),
        name: "Büro".into(),
        address: "http://10.0.0.2:8096".into(),
    };
    let b = FoundServer {
        id: "2".into(),
        name: "Wohnzimmer".into(),
        address: "http://192.168.1.5:8096".into(),
    };
    vm.handle(LoginIntent::Discovered(vec![b, a]));
    assert_eq!(p(&vm).found.len(), 2);
    type_address(&mut vm, "192.168.1.5:8096");
    assert_eq!(
        p(&vm)
            .found
            .iter()
            .map(|s| s.id.as_str())
            .collect::<Vec<_>>(),
        ["1"],
        "A15 the one in the field is hidden"
    );
    let (_, url) = check_of(vm.handle(LoginIntent::PickServer("1".into())));
    assert_eq!(
        (p(&vm).address.as_str(), url.as_str()),
        ("http://10.0.0.2:8096", "http://10.0.0.2:8096"),
        "A13"
    );
    assert!(p(&vm).working);

    let mut vm = self::vm();
    vm.remember_server("http://192.168.1.5:8096", "Wohnzimmer", "10.9.0");
    let (_, url) = check_of(vm.handle(LoginIntent::UseLast));
    assert_eq!(url, "http://192.168.1.5:8096", "A14");
    // A15: with the last server in the field, it is not listed twice.
    let a = FoundServer {
        id: "9".into(),
        name: "Wohnzimmer".into(),
        address: "http://192.168.1.5:8096".into(),
    };
    vm.handle(LoginIntent::Discovered(vec![a]));
    assert!(p(&vm).found.is_empty());
}

// ---------------------------------------------------------------- password step

#[test]
fn p1_to_p6_password_step() {
    let mut vm = vm();
    to_credentials(&mut vm);
    assert!(!p(&vm).can_sign_in, "P1 no user");
    assert!(vm.handle(LoginIntent::SignIn).is_empty());
    vm.handle(LoginIntent::PickUser("Anna".into()));
    assert_eq!(p(&vm).user, "Anna", "P5");
    assert!(p(&vm).can_sign_in, "P1");
    vm.handle(LoginIntent::EditPassword("geheim".into()));
    assert_eq!(
        vm.handle(LoginIntent::SignIn),
        vec![LoginEffect::Authenticate {
            url: "http://192.168.1.5:8096".into(),
            user: "Anna".into(),
            password: "geheim".into()
        }],
        "P2"
    );
    assert!(
        p(&vm).working && !p(&vm).can_sign_in && p(&vm).error.is_none(),
        "P1/P2 busy"
    );
    assert!(
        vm.handle(LoginIntent::SignIn).is_empty(),
        "no double sign-in"
    );

    // P4: wrong password, two-factor, network: readable text, fields kept.
    for e in [
        ErrorKind::Http {
            status: 401,
            body: None,
        },
        ErrorKind::TwoFactor,
        ErrorKind::Network { code: -1009 },
    ] {
        let mut v = self::vm();
        to_credentials(&mut v);
        v.handle(LoginIntent::EditUser("Anna".into()));
        v.handle(LoginIntent::EditPassword("x".into()));
        v.handle(LoginIntent::SignIn);
        assert!(v.handle(LoginIntent::SignedIn(Err(e.clone()))).is_empty());
        assert_eq!(p(&v).error, Some(readable_error(&tr(), &e)), "P4 {e:?}");
        assert!(p(&v).error.as_deref().is_some_and(|t| !t.is_empty()));
        assert!(!p(&v).working && p(&v).can_sign_in);
        assert_eq!(
            (p(&v).user.as_str(), p(&v).password.as_str(), p(&v).screen),
            ("Anna", "x", LoginScreen::Credentials)
        );
        v.handle(LoginIntent::EditPassword("xy".into()));
        assert!(p(&v).error.is_none(), "typing clears the message");
    }

    // P3: success.
    assert_eq!(
        vm.handle(LoginIntent::SignedIn(Ok(session()))),
        vec![LoginEffect::Done(session())]
    );
    assert!(!p(&vm).working);

    // P6: back to the address step; the field keeps the address.
    let mut vm = self::vm();
    to_credentials(&mut vm);
    vm.handle(LoginIntent::Back);
    assert_eq!(
        (p(&vm).screen, p(&vm).address.as_str()),
        (LoginScreen::Address, "http://192.168.1.5:8096")
    );
    assert!(p(&vm).server_name.is_none());
}

// ---------------------------------------------------------------- Quick Connect

#[test]
fn q1_to_q4_start() {
    let mut vm = vm();
    to_credentials(&mut vm);
    assert!(
        vm.handle(LoginIntent::UseQuickConnect).is_empty(),
        "Q1 not offered"
    );
    vm.handle(LoginIntent::QuickConnectOffered(true));
    assert_eq!(
        vm.handle(LoginIntent::UseQuickConnect),
        vec![LoginEffect::StartQuickConnect]
    );
    assert_eq!(
        (p(&vm).screen, p(&vm).working, p(&vm).quick_seconds_left),
        (LoginScreen::QuickConnect, true, 300),
        "Q2"
    );
    assert_eq!(QuickConnectDeadline::SECONDS, 300);
    assert!(p(&vm).quick_code.is_none() && p(&vm).error.is_none());
    vm.handle(LoginIntent::QuickConnectStarted(Ok(code("123456"))));
    assert_eq!(
        (p(&vm).quick_code.as_deref(), p(&vm).working),
        (Some("123456"), false),
        "Q3"
    );

    // Q4: the start fails.
    let mut vm = self::vm();
    to_credentials(&mut vm);
    vm.handle(LoginIntent::QuickConnectOffered(true));
    vm.handle(LoginIntent::UseQuickConnect);
    let e = ErrorKind::Transport(swiftly_net::TransportReason::QuickConnectDisabled);
    vm.handle(LoginIntent::QuickConnectStarted(Err(e.clone())));
    assert_eq!(
        (p(&vm).screen, p(&vm).working),
        (LoginScreen::Credentials, false),
        "Q4"
    );
    assert_eq!(p(&vm).error, Some(readable_error(&tr(), &e)));
    assert!(p(&vm).quick_code.is_none());
}

/// The scripted host of the wait: the pure state machine on explicit clock values, its events
/// turned into intents exactly like `QuickConnectModel.wait` does. `answers` is what each asked
/// poll returns. Returns the effects of every intent.
struct Host {
    wait: QuickConnectWait,
    answers: Vec<QuickConnectState>,
    asked: usize,
}

impl Host {
    fn start(vm: &mut LoginVm<MemoryStore>, now: f64, answers: Vec<QuickConnectState>) -> Self {
        let wait = QuickConnectWait::start(now);
        let first = wait.first(now);
        Self::feed(vm, first);
        Self {
            wait,
            answers,
            asked: 0,
        }
    }

    fn feed(vm: &mut LoginVm<MemoryStore>, event: WaitEvent) -> Vec<LoginEffect> {
        match event {
            WaitEvent::Rest(s) => vm.handle(LoginIntent::QuickConnectRest(s)),
            WaitEvent::Released => {
                vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Released))
            }
            WaitEvent::End(last) => vm.handle(LoginIntent::QuickConnectState(
                if last == QuickConnectState::Failed {
                    QuickConnectState::Failed
                } else {
                    QuickConnectState::Expired
                },
            )),
        }
    }

    /// One clock tick at `now`; asks the scripted server if the wait says so.
    fn tick(&mut self, vm: &mut LoginVm<MemoryStore>, now: f64) -> (bool, Vec<LoginEffect>) {
        let step = self.wait.tick(now);
        let mut effects = Vec::new();
        if let Some(e) = step.event {
            effects.extend(Self::feed(vm, e));
        }
        if step.ask {
            let state = self
                .answers
                .get(self.asked)
                .copied()
                .unwrap_or(QuickConnectState::Opened);
            self.asked += 1;
            if let Some(e) = self.wait.answer(state) {
                effects.extend(Self::feed(vm, e));
            }
        }
        (step.ask, effects)
    }
}

#[test]
fn q5_q6_q12_countdown_and_poll_timing() {
    let mut vm = vm();
    to_quick(&mut vm);
    let mut host = Host::start(&mut vm, 1000.0, vec![]);
    assert_eq!(p(&vm).quick_seconds_left, 300);
    assert_eq!(swiftly_vm::quick_countdown(300), "5:00");
    // Tick every second: asks at 2 s, 4 s ... (`pollInterval`), never at the odd seconds.
    let (ask, _) = host.tick(&mut vm, 1001.0);
    assert!(!ask);
    assert_eq!(p(&vm).quick_seconds_left, 299, "Q5");
    let (ask, effects) = host.tick(&mut vm, 1002.0);
    assert!(
        ask && effects.is_empty(),
        "Q12 asks after 2 s, Q6 `opened` changes nothing"
    );
    assert_eq!(
        swiftly_vm::quick_countdown(p(&vm).quick_seconds_left),
        "4:58"
    );
    assert!(!host.tick(&mut vm, 1003.0).0);
    // Back from the browser after a long gap: the first tick asks at once and the countdown is right.
    let (ask, _) = host.tick(&mut vm, 1100.5);
    assert!(ask, "Q12 immediately after returning");
    assert_eq!(p(&vm).quick_seconds_left, 200, "rounded up: 199.5 -> 200");
    assert_eq!(
        (p(&vm).screen, p(&vm).working),
        (LoginScreen::QuickConnect, false),
        "Q6 still waiting"
    );
}

#[test]
fn q7_q8_released_signs_in_once() {
    let mut vm = vm();
    to_quick(&mut vm);
    let mut host = Host::start(
        &mut vm,
        0.0,
        vec![QuickConnectState::Opened, QuickConnectState::Released],
    );
    host.tick(&mut vm, 1.0);
    host.tick(&mut vm, 2.0);
    let (_, effects) = host.tick(&mut vm, 4.0);
    assert_eq!(
        effects,
        vec![LoginEffect::SignInWithQuickConnect(code("123456"))],
        "Q7"
    );
    assert!(p(&vm).working);
    assert!(
        host.wait.is_finished(),
        "the wait is over after the approval"
    );
    // A late duplicate from a racing poll signs nobody in twice.
    assert!(
        vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Released))
            .is_empty(),
        "Q7"
    );
    assert_eq!(
        vm.handle(LoginIntent::SignedIn(Ok(session()))),
        vec![LoginEffect::Done(session())]
    );

    // Q8: the sign-in after the approval fails.
    let mut vm = self::vm();
    to_quick(&mut vm);
    vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Released));
    let e = ErrorKind::Http {
        status: 401,
        body: None,
    };
    vm.handle(LoginIntent::SignedIn(Err(e.clone())));
    assert_eq!(
        (p(&vm).screen, p(&vm).working, p(&vm).quick_code.clone()),
        (LoginScreen::Credentials, false, None),
        "Q8"
    );
    assert_eq!(p(&vm).error, Some(readable_error(&tr(), &e)));
}

#[test]
fn q9_q10_q11_expiry_and_deadline() {
    let expired = "Der Code ist abgelaufen. Hol dir einen neuen.";
    let silent = "Der Server hat nicht geantwortet.";
    // Q9: the server forgot the code.
    let mut vm = vm();
    to_quick(&mut vm);
    let mut host = Host::start(&mut vm, 0.0, vec![QuickConnectState::Expired]);
    host.tick(&mut vm, 1.0);
    host.tick(&mut vm, 2.0);
    assert_eq!(p(&vm).error.as_deref(), Some(expired), "Q9");
    assert_eq!(
        (
            p(&vm).screen,
            p(&vm).quick_seconds_left,
            p(&vm).quick_code.clone(),
            p(&vm).working
        ),
        (LoginScreen::Credentials, 0, None, false)
    );

    // Q11 + Q10: every poll fails (network down) for the whole time: the wait runs to the deadline,
    // then says the server did not answer.
    let mut vm = self::vm();
    to_quick(&mut vm);
    let mut host = Host::start(&mut vm, 0.0, vec![QuickConnectState::Failed; 400]);
    for s in 1..300 {
        host.tick(&mut vm, f64::from(s));
        assert_eq!(
            p(&vm).screen,
            LoginScreen::QuickConnect,
            "Q11 a failed poll does not end the wait (t={s})"
        );
    }
    assert_eq!(p(&vm).quick_seconds_left, 1);
    host.tick(&mut vm, 300.0);
    assert_eq!(p(&vm).error.as_deref(), Some(silent), "Q10");
    assert_eq!(
        (p(&vm).screen, p(&vm).quick_seconds_left),
        (LoginScreen::Credentials, 0)
    );
    assert!(host.wait.is_finished());

    // Q10: the last poll was fine: the code simply ran out.
    let mut vm = self::vm();
    to_quick(&mut vm);
    let mut host = Host::start(
        &mut vm,
        0.0,
        vec![QuickConnectState::Failed, QuickConnectState::Opened],
    );
    for s in 1..=300 {
        host.tick(&mut vm, f64::from(s));
    }
    assert_eq!(
        p(&vm).error.as_deref(),
        Some(expired),
        "Q10 last answer not failed"
    );

    // A short wait with other timing (as the package tests do) behaves the same.
    let mut w = QuickConnectWait::with(0.0, 4.0, 2.0);
    assert!(w.tick(1.0).event.is_some() && !w.tick(1.5).ask);
    assert!(w.tick(2.0).ask);
    assert_eq!(
        w.tick(4.0).event,
        Some(WaitEvent::End(QuickConnectState::Expired))
    );
}

#[test]
fn q13_q14_new_code_and_cancel() {
    let mut vm = vm();
    to_quick(&mut vm);
    let mut host = Host::start(&mut vm, 0.0, vec![]);
    host.tick(&mut vm, 1.0);
    host.tick(&mut vm, 2.0);
    assert!(p(&vm).quick_seconds_left < 300);
    assert_eq!(
        vm.handle(LoginIntent::NewCode),
        vec![LoginEffect::StartQuickConnect],
        "Q13"
    );
    assert_eq!(
        (
            p(&vm).quick_code.clone(),
            p(&vm).quick_seconds_left,
            p(&vm).working,
            p(&vm).screen
        ),
        (None, 300, true, LoginScreen::QuickConnect)
    );
    // A stale answer of the old wait signs nobody in while the new code is on its way.
    assert!(
        vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Released))
            .is_empty(),
        "Q13 stale release"
    );
    vm.handle(LoginIntent::QuickConnectStarted(Ok(code("654321"))));
    assert_eq!(p(&vm).quick_code.as_deref(), Some("654321"));
    assert_eq!(
        vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Released)),
        vec![LoginEffect::SignInWithQuickConnect(code("654321"))]
    );
    assert!(
        vm.handle(LoginIntent::NewCode).is_empty(),
        "Q13 refused while the approved code signs in"
    );

    // Retry after an expired code: back on the password step, the button starts again.
    let mut vm = self::vm();
    to_quick(&mut vm);
    vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Expired));
    assert_eq!(
        vm.handle(LoginIntent::UseQuickConnect),
        vec![LoginEffect::StartQuickConnect],
        "retry"
    );
    assert!(p(&vm).error.is_none());
    assert_eq!(p(&vm).quick_seconds_left, 300);
    // NewCode off the page does nothing.
    let mut vm = self::vm();
    to_credentials(&mut vm);
    assert!(vm.handle(LoginIntent::NewCode).is_empty());

    // Q14: cancel (Back) ends everything; later events are ignored.
    let mut vm = self::vm();
    to_quick(&mut vm);
    assert!(vm.handle(LoginIntent::Back).is_empty());
    assert_eq!(
        (p(&vm).screen, p(&vm).quick_code.clone(), p(&vm).working),
        (LoginScreen::Credentials, None, false),
        "Q14"
    );
    assert!(
        vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Released))
            .is_empty()
    );
    assert!(
        vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Expired))
            .is_empty()
    );
    assert!(p(&vm).error.is_none());
}

// ---------------------------------------------------------------- Plex

fn profile(id: &str, protected: bool) -> PlexProfileChoice {
    PlexProfileChoice {
        id: id.into(),
        name: id.into(),
        image: None,
        protected,
    }
}

fn server(id: &str) -> PlexServerChoice {
    PlexServerChoice {
        id: id.into(),
        name: id.into(),
        shared_by: None,
        local: true,
        online: true,
    }
}

#[test]
fn x1_x2_start_waiting_and_title() {
    let tr = tr();
    let mut m = PlexSignInModel::new();
    assert_eq!(
        (m.step.clone(), m.page_title(&tr)),
        (PlexStep::Start, "Mit Plex anmelden".to_string())
    );
    m.start();
    assert_eq!(
        (m.step.clone(), m.page_title(&tr)),
        (PlexStep::Opening, "Mit Plex anmelden".to_string()),
        "X1"
    );
    let applied = m.apply(PlexAnswer::Waiting {
        url: Some("https://app.plex.tv/auth".into()),
        code: Some("AB12".into()),
        seconds_left: 900,
    });
    assert!(!applied.done && !applied.waiting_ended);
    let PlexStep::Waiting(prompt) = &m.step else {
        panic!("not waiting")
    };
    assert_eq!(
        (
            prompt.url.as_str(),
            prompt.code.as_deref(),
            prompt.seconds_left
        ),
        ("https://app.plex.tv/auth", Some("AB12"), Some(900))
    );
    assert_eq!(m.page_title(&tr), "Plex (Beta)", "kind name while waiting");
    m.apply(PlexAnswer::Waiting {
        url: None,
        code: None,
        seconds_left: 899,
    });
    let PlexStep::Waiting(prompt) = &m.step else {
        panic!()
    };
    assert_eq!(
        (prompt.seconds_left, prompt.code.as_deref()),
        (Some(899), Some("AB12")),
        "X2 a beat keeps the prompt"
    );
    m.apply(PlexAnswer::Waiting {
        url: None,
        code: None,
        seconds_left: 0,
    });
    let PlexStep::Waiting(prompt) = &m.step else {
        panic!()
    };
    assert_eq!(
        prompt.seconds_left,
        Some(899),
        "X2 a zero beat does not hide a running countdown"
    );
    let applied = m.apply(PlexAnswer::Profiles {
        account: Some("Anna".into()),
        profiles: vec![profile("a", false), profile("b", true)],
    });
    assert!(applied.waiting_ended, "the browser window did its job");
    assert_eq!(m.page_title(&tr), "Anna");
    assert!(m.apply(PlexAnswer::Done).done);
}

#[test]
fn x3_x4_poll_rules() {
    let tr = tr();
    let readable = || "lesbar".to_string();
    // Expiry on the clock, before the request counts.
    let mut poll = PlexPoll::new();
    assert_eq!(
        poll.beat(10.0, 10.0, PollResult::Token("t".into()), readable),
        PollNext::End(PlexSignInProblem::Expired),
        "X3 clock first"
    );
    // 404/410 ends at once.
    assert_eq!(
        PlexPoll::new().beat(1.0, 10.0, PollResult::Failed { expired: true }, readable),
        PollNext::End(PlexSignInProblem::Expired)
    );
    // Token wins.
    assert_eq!(
        PlexPoll::new().beat(1.0, 10.0, PollResult::Token("t".into()), readable),
        PollNext::SignedIn("t".into())
    );
    // Four failures keep going, a good beat resets, five in a row end it.
    let mut poll = PlexPoll::new();
    for _ in 0..4 {
        assert_eq!(
            poll.beat(1.0, 10.0, PollResult::Failed { expired: false }, readable),
            PollNext::Again
        );
    }
    assert_eq!(
        poll.beat(1.0, 10.0, PollResult::Waiting, readable),
        PollNext::Again
    );
    for _ in 0..4 {
        assert_eq!(
            poll.beat(1.0, 10.0, PollResult::Failed { expired: false }, readable),
            PollNext::Again,
            "X3 reset"
        );
    }
    assert_eq!(
        poll.beat(1.0, 10.0, PollResult::Failed { expired: false }, readable),
        PollNext::End(PlexSignInProblem::Other("lesbar".into()))
    );
    // X4: with the error kind the end matches `PlexRun.fail`.
    let net = PlexError::Request(ErrorKind::Network { code: -1009 });
    let mut poll = PlexPoll::new();
    for _ in 0..4 {
        assert_eq!(poll.beat_error(1.0, 10.0, &net, readable), PollNext::Again);
    }
    assert_eq!(
        poll.beat_error(1.0, 10.0, &net, readable),
        PollNext::End(PlexSignInProblem::PlexUnreachable),
        "X4"
    );
    let other = PlexError::Request(ErrorKind::Http {
        status: 500,
        body: None,
    });
    let mut poll = PlexPoll::new();
    for _ in 0..4 {
        poll.beat_error(1.0, 10.0, &other, readable);
    }
    assert_eq!(
        poll.beat_error(1.0, 10.0, &other, readable),
        PollNext::End(PlexSignInProblem::Other("lesbar".into()))
    );
    assert_eq!(
        PlexPoll::new().beat_error(1.0, 10.0, &PlexError::PinExpired, readable),
        PollNext::End(PlexSignInProblem::Expired)
    );
    // The sentences of the failed page.
    assert_eq!(
        PlexSignInProblem::Expired.texts(&tr).0,
        "Die Anmeldung ist abgelaufen"
    );
    assert_eq!(
        PlexSignInProblem::PlexUnreachable.texts(&tr).0,
        "plex.tv antwortet nicht"
    );
    assert_eq!(
        PlexSignInProblem::Other("x".into()).texts(&tr),
        ("Anmeldung hat nicht geklappt".to_string(), "x".to_string())
    );
    // `fail` maps like PlexRun.fail: noServer is the empty server list.
    let mut m = PlexSignInModel::new();
    m.fail(&PlexError::NoServer, || unreachable!());
    assert_eq!(m.step, PlexStep::Servers(vec![]));
    m.fail(&PlexError::PinExpired, || unreachable!());
    assert_eq!(m.step, PlexStep::Failed(PlexSignInProblem::Expired));
}

#[test]
fn x5_x6_x7_x8_profiles_pin_servers_back_and_other_account() {
    let mut m = PlexSignInModel::new();
    let people = vec![profile("a", false), profile("b", true)];
    m.apply(PlexAnswer::Profiles {
        account: Some("Anna".into()),
        profiles: people.clone(),
    });
    assert_eq!(m.step, PlexStep::Profiles(people.clone()));
    // X5: protected -> PIN page; wrong PIN stays; busy check refuses a second submit.
    assert!(!m.pick_profile(&people[1]));
    assert_eq!(m.step, PlexStep::Pin(people[1].clone()));
    assert!(m.submit_pin() && !m.submit_pin() && m.pin_checking);
    m.pin_checked(true, true, || unreachable!());
    assert!(m.pin_wrong && !m.pin_checking && matches!(m.step, PlexStep::Pin(_)));
    assert!(
        m.submit_pin() && !m.pin_wrong,
        "a new try clears the red line"
    );
    // X7: back from the PIN to the profiles (several), a refused unprotected profile ends the flow.
    assert_eq!(m.go_back(), Back::Stepped);
    assert_eq!(m.step, PlexStep::Profiles(people.clone()));
    assert!(m.pick_profile(&people[0]));
    assert_eq!(m.step, PlexStep::Loading(Placeholder::Servers));
    m.pin_checked(true, false, || "abgelehnt".into());
    assert_eq!(
        m.step,
        PlexStep::Failed(PlexSignInProblem::Other("abgelehnt".into()))
    );
    // X6: servers.
    m.apply(PlexAnswer::Servers {
        account: Some("Anna".into()),
        profile: Some("a".into()),
        servers: vec![server("s1"), server("s2")],
    });
    assert_eq!(m.profile.as_deref(), Some("a"));
    assert!(
        m.pick_server("s1") && !m.pick_server("s2"),
        "X6 one at a time"
    );
    assert_eq!(m.connecting.as_deref(), Some("s1"));
    m.server_connected("s1", false);
    assert!(
        m.unreachable.contains("s1") && m.connecting.is_none(),
        "X6 the row is marked"
    );
    assert!(
        m.pick_server("s1") && !m.unreachable.contains("s1"),
        "X6 retry clears the mark"
    );
    m.apply(PlexAnswer::Servers {
        account: None,
        profile: None,
        servers: vec![],
    });
    assert!(m.unreachable.is_empty(), "X6 reload clears the marks");
    assert_eq!(m.step, PlexStep::Servers(vec![]));
    assert_eq!(
        m.go_back(),
        Back::Stepped,
        "X7 servers -> profiles when there were several"
    );
    // Single profile: the arrow leaves the page.
    let mut single = PlexSignInModel::new();
    single.apply(PlexAnswer::Profiles {
        account: None,
        profiles: vec![profile("a", false)],
    });
    single.apply(PlexAnswer::Servers {
        account: None,
        profile: None,
        servers: vec![server("s")],
    });
    assert_eq!(single.go_back(), Back::Leave, "X7");
    // X8: other account.
    m.other_account();
    assert_eq!(m, PlexSignInModel::new());
}

// ---------------------------------------------------------------- Emby

#[test]
fn e1_e2_e3_emby_page() {
    let tr = tr();
    let mut m = EmbySignInModel::new();
    assert_eq!(m.step, EmbyStep::Address);
    assert!(!m.go_back(), "E2 from the address: leave");
    let one = EmbyUserChoice {
        id: "1".into(),
        name: "Anna".into(),
        image: None,
    };
    m.checking = true;
    m.checked("http://emby.local:8096", "Emby Büro", "4.8", vec![one]);
    assert_eq!(
        m.step,
        EmbyStep::SignIn {
            server_name: "Emby Büro".into(),
            version: "4.8".into()
        },
        "E1"
    );
    assert_eq!(
        (m.user.as_str(), m.checking, m.users.as_ref().map(Vec::len)),
        ("Anna", false, Some(1)),
        "E1 one user preselected"
    );
    m.sign_in_error = Some("falsch".into());
    assert!(m.go_back(), "E2");
    assert_eq!(
        (m.step.clone(), m.sign_in_error.clone()),
        (EmbyStep::Address, None)
    );
    // Two users: nothing preselected.
    let mut two = EmbySignInModel::new();
    two.checked(
        "a",
        "n",
        "v",
        vec![
            EmbyUserChoice {
                id: "1".into(),
                name: "A".into(),
                image: None,
            },
            EmbyUserChoice {
                id: "2".into(),
                name: "B".into(),
                image: None,
            },
        ],
    );
    assert!(two.user.is_empty());
    // E3: problem texts.
    let jelly = EmbyProblem::NotEmby {
        found: Some("Jellyfin".into()),
    };
    assert_eq!(
        emby_problem_text(&tr, &jelly).as_deref(),
        Some("Unter der Adresse läuft Jellyfin, kein Emby.")
    );
    assert_eq!(
        emby_problem_text(&tr, &EmbyProblem::NotEmby { found: None }).as_deref(),
        Some("Unter der Adresse antwortet etwas, aber kein Emby.")
    );
    assert_eq!(
        emby_problem_text(&tr, &EmbyProblem::BadAddress).as_deref(),
        Some("Die Adresse konnte nicht gelesen werden.")
    );
    assert!(emby_problem_text(&tr, &EmbyProblem::LoginPage).is_some());
    assert!(
        emby_problem_text(
            &tr,
            &EmbyProblem::Unreachable {
                address: "x".into()
            }
        )
        .is_none()
    );
    assert!(offers_jellyfin(&jelly, true) && !offers_jellyfin(&jelly, false));
    assert!(!offers_jellyfin(
        &EmbyProblem::NotEmby { found: None },
        true
    ));
}

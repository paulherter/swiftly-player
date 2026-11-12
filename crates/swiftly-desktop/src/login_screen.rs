//! The sign-in flow of the shared Rust UI: server address, user and password, the Quick Connect code screen with its
//! countdown, the account switcher and the error lines. The steps follow `ServerOnboardingView`, `QuickConnectLogin`
//! and `QuickConnectModel`; the server is scripted (no network). Differences from the Swift screens are noted in the code.

use crate::browse::{self, wide};
use crate::forms::{self, Fm, Trail};
use crate::home::{ins, tabular_text, text};
use crate::login_mac::{self, Kind, Mac, PinState, PlexStep};
use crate::signin_flows::{self, EmbyFound, PlexEvent};
use std::rc::Rc;
use swiftly_design::tokens::colour;
use swiftly_jellyfin::QuickConnectDeadline;
use swiftly_jellyfin::discovery::FoundServer;
use swiftly_layout::{Align, Alignment};
use swiftly_text::{TextEditor, TextInputEvent};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node, Ui};

/// Where the flow starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Start {
    /// The server address (add a server).
    Address,
    /// The account list (switch account).
    Accounts,
    /// The kind picker of the first start (desktop).
    Kind,
    /// The kind picker of "Server hinzufügen" (desktop).
    AddKind,
}

/// The step in front.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// Server address entry.
    Address,
    /// The server answered: user name and password.
    Credentials,
    /// The Quick Connect code and the wait.
    Quick,
    /// The account list.
    Accounts,
    /// The kind picker (desktop).
    Kind,
    /// The Emby address (desktop).
    EmbyAddress,
    /// The Emby user and password (desktop).
    EmbyCredentials,
    /// The Plex steps (desktop, `Mac::plex`).
    Plex,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Field {
    Address,
    User,
    Password,
    HName(usize),
    HValue(usize),
    Pin,
}

/// The code the scripted server hands out.
pub const CODE: &str = "482915";

#[derive(Clone, PartialEq)]
pub(crate) struct Parts {
    pub(crate) step: Step,
    pub(crate) field: Field,
    pub(crate) mac: Mac,
    pub(crate) address: String,
    pub(crate) user: String,
    pub(crate) password: String,
    pub(crate) checking: bool,
    pub(crate) code: String,
    pub(crate) error: Option<String>,
    pub(crate) left: u64,
    pub(crate) accounts: Vec<(String, String)>,
    pub(crate) active: usize,
    /// The shared editor's display of the field that has the keyboard: caret, selection, composition (a password is
    /// bullets).
    pub(crate) edit: Option<swiftly_text::Display>,
}

impl Parts {
    /// What field `f` shows: its text, and the composition when it is the field that has the keyboard.
    pub(crate) fn shown(&self, f: Field) -> String {
        let value = match f {
            Field::Address => &self.address,
            Field::User => &self.user,
            Field::Password => &self.password,
            Field::HName(i) => self.mac.headers.get(i).map_or(&self.address, |h| &h.0),
            Field::HValue(i) => self.mac.headers.get(i).map_or(&self.address, |h| &h.1),
            Field::Pin => &self.mac.pin,
        };
        value.clone()
    }
}

pub(crate) struct Ctx {
    pub(crate) icons: Icons,
}

fn st(size: f32, weight: u16) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

fn dot(size: f32) -> Node {
    Node::rect(color(colour::MARK_ACCENT), size / 2.0).frame(
        Some(size),
        Some(size),
        Alignment::CENTER,
    )
}

fn code_fields(cx: &Cx, f: &Fm, code: &str) -> Node {
    let tv = f.form == crate::home::Form::Tv;
    let chars: Vec<char> = code.chars().collect();
    let mut cells = Vec::new();
    for (i, c) in chars.iter().enumerate() {
        if i == chars.len() / 2 && !tv {
            cells.push(Node::fixed(6.0, 1.0));
        }
        // tvOS `CodeFields`: 92 bold in 120 x 160 on `raised`, corner 16, spacing 20 (read across the room).
        let cell = if tv {
            text(
                cx,
                &c.to_string(),
                st(92.0, 700),
                colour::FONT,
                Some(1),
                swiftly_text::Align::Center,
            )
            .frame(Some(120.0), Some(160.0), Alignment::CENTER)
            .background(Node::rect(color(colour::RAISED), 16.0), Alignment::CENTER)
        } else {
            text(
                cx,
                &c.to_string(),
                st(28.0, 600),
                colour::FONT,
                Some(1),
                swiftly_text::Align::Center,
            )
            .frame(Some(46.0), Some(60.0), Alignment::CENTER)
            .background(
                Node::rect(
                    color(colour::AREA),
                    if f.form == crate::home::Form::Touch {
                        10.0
                    } else {
                        12.0
                    },
                ),
                Alignment::CENTER,
            )
        };
        cells.push(cell);
    }
    let row = wide(
        Node::hstack(Align::Center, Some(if tv { 20.0 } else { 8.0 }), cells),
        Alignment::CENTER,
    );
    if tv {
        row
    } else {
        row.padding(ins(34.0, 0.0, 0.0, 0.0))
    }
}

fn quick_body(cx: &Cx, f: &Fm, p: &Parts) -> Vec<Node> {
    let mut b = vec![
        text(
            cx,
            "Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.",
            st(15.0, 400),
            colour::FONT_QUIET,
            Some(4),
            swiftly_text::Align::Start,
        )
        .padding(ins(10.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(e) = &p.error {
        b.push(
            wide(
                text(
                    cx,
                    e,
                    st(15.0, 400),
                    colour::ERROR,
                    Some(3),
                    swiftly_text::Align::Center,
                ),
                Alignment::CENTER,
            )
            .padding(ins(40.0, 0.0, 0.0, 0.0)),
        );
    } else {
        b.push(code_fields(cx, f, &p.code));
        b.push(
            wide(
                Node::hstack(
                    Align::Center,
                    Some(9.0),
                    vec![
                        dot(8.0),
                        tabular_text(
                            cx,
                            &format!(
                                "Warte auf Freigabe \u{00B7} noch {}:{:02}",
                                p.left / 60,
                                p.left % 60
                            ),
                            st(13.0, 400),
                            colour::FONT_QUIET,
                            Some(1),
                            swiftly_text::Align::Start,
                        ),
                    ],
                ),
                Alignment::CENTER,
            )
            .padding(ins(22.0, 0.0, 0.0, 0.0)),
        );
    }
    let step = |n: u8, s: &str| {
        Node::hstack(
            Align::Start,
            Some(12.0),
            vec![
                text(
                    cx,
                    &n.to_string(),
                    st(13.0, 400),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                    swiftly_text::Align::Start,
                )
                .frame(Some(20.0), None, Alignment::LEADING),
                text(
                    cx,
                    s,
                    st(13.0, 400),
                    colour::FONT_QUIET,
                    Some(3),
                    swiftly_text::Align::Start,
                ),
            ],
        )
        .padding(ins(10.0, 0.0, 0.0, 0.0))
    };
    b.push(
        Node::vstack(
            Align::Start,
            Some(0.0),
            vec![
                wide(
                    Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::CENTER),
                    Alignment::CENTER,
                )
                .padding(ins(0.0, 0.0, 14.0, 0.0)),
                text(
                    cx,
                    "So gehts",
                    swiftly_design::TextStyle {
                        tracking: -0.2,
                        ..st(22.0, 700)
                    },
                    colour::FONT,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                step(1, "Jellyfin im Browser öffnen und anmelden"),
                step(2, "Oben rechts aufs Profil, dann Quick Connect"),
                step(3, "Code eingeben, dann geht es hier von selbst weiter"),
            ],
        )
        .padding(ins(38.0, 0.0, 0.0, 0.0)),
    );
    // `safeAreaInset(edge: .bottom)`: the button stays pinned (see `pinned_new_code`); room below the guide for it.
    b.push(Node::fixed(1.0, 52.0 + 24.0));
    b
}

/// "Neuen Code holen" pinned at the bottom of the touch and desktop page: padding 24 below, the form column wide.
fn pinned_new_code(cx: &Cx, f: &Fm, env: &Env, ctx: &Ctx) -> Node {
    let b = forms::button(
        cx,
        &ctx.icons,
        f,
        "newcode",
        "Neuen Code holen",
        None,
        false,
        false,
        true,
    );
    let col = wide(b, Alignment::CENTER)
        .padding(ins(0.0, f.edge, 0.0, f.edge))
        .frame(
            Some((f.col + 2.0 * f.edge).min(env.size.w)),
            None,
            Alignment::CENTER,
        );
    wide(col, Alignment::CENTER).padding(ins(0.0, 0.0, 24.0 + env.safe.bottom, 0.0))
}

fn address_body(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Vec<Node> {
    let mark = ctx
        .icons
        .node("hard-drives", 22.0, true, color(colour::FONT))
        .frame(Some(44.0), Some(44.0), Alignment::CENTER)
        .background(Node::rect(color(colour::AREA), 22.0), Alignment::CENTER);
    let mut b = vec![
        wide(mark, Alignment::LEADING).padding(ins(8.0, 0.0, 0.0, 0.0)),
        wide(
            text(
                cx,
                "Wo steht dein Jellyfin-Server?",
                st(15.0, 400),
                colour::FONT_QUIET,
                Some(2),
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        )
        .padding(ins(14.0, 0.0, 0.0, 0.0)),
        forms::input_ex(
            cx,
            &ctx.icons,
            f,
            "field:addr",
            "globe",
            if f.form == crate::home::Form::Tv {
                "tv.beispiel.de"
            } else {
                "jellyfin.beispiel.de"
            },
            &p.shown(Field::Address),
            false,
            p.field == Field::Address,
            p.edit.as_ref(),
        )
        .padding(ins(24.0, 0.0, 0.0, 0.0)),
        forms::note(
            cx,
            f,
            if f.form == crate::home::Form::Tv {
                "https:// kannst du weglassen."
            } else {
                "https:// kannst du weglassen. Du bleibst auch beim anderen Server angemeldet."
            },
            false,
            false,
        )
        .padding(ins(10.0, 2.0, 0.0, 0.0)),
        forms::button(
            cx,
            &ctx.icons,
            f,
            "connect",
            if p.checking {
                "Verbinden…"
            } else {
                "Verbinden"
            },
            None,
            true,
            false,
            !p.checking && !p.address.is_empty(),
        )
        .padding(ins(20.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(e) = &p.error {
        b.push(forms::note(cx, f, e, true, true).padding(ins(12.0, 0.0, 0.0, 0.0)));
    }
    b
}

fn credentials_body(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Vec<Node> {
    let mut b = vec![
        Node::hstack(
            Align::Center,
            Some(8.0),
            vec![
                dot(7.0),
                text(
                    cx,
                    "Verbunden \u{00B7} Jellyfin 10.10.3",
                    st(12.0, 400),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
            ],
        )
        .padding(ins(8.0, 0.0, 0.0, 0.0)),
        forms::input_ex(
            cx,
            &ctx.icons,
            f,
            "field:user",
            "user",
            "Benutzername",
            &p.shown(Field::User),
            false,
            p.field == Field::User,
            p.edit.as_ref(),
        )
        .padding(ins(28.0, 0.0, 0.0, 0.0)),
        forms::input_ex(
            cx,
            &ctx.icons,
            f,
            "field:pass",
            "lock",
            "Passwort",
            &p.shown(Field::Password),
            true,
            p.field == Field::Password,
            p.edit.as_ref(),
        )
        .padding(ins(10.0, 0.0, 0.0, 0.0)),
        forms::button(
            cx,
            &ctx.icons,
            f,
            "signin",
            if p.checking {
                "Anmelden…"
            } else {
                "Anmelden"
            },
            None,
            true,
            false,
            !p.checking && !p.user.is_empty(),
        )
        .padding(ins(20.0, 0.0, 0.0, 0.0)),
        Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                wide(
                    Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::CENTER),
                    Alignment::CENTER,
                ),
                text(
                    cx,
                    "oder",
                    st(12.0, 400),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                    swiftly_text::Align::Center,
                ),
                wide(
                    Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::CENTER),
                    Alignment::CENTER,
                ),
            ],
        )
        .padding(ins(16.0, 0.0, 0.0, 0.0)),
        forms::button(
            cx,
            &ctx.icons,
            f,
            "quick",
            "Mit Quick Connect anmelden",
            Some("television"),
            false,
            true,
            true,
        )
        .padding(ins(10.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(e) = &p.error {
        b.push(forms::note(cx, f, e, true, true).padding(ins(12.0, 0.0, 0.0, 0.0)));
    }
    b
}

fn accounts_body(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Vec<Node> {
    let rows = p
        .accounts
        .iter()
        .enumerate()
        .map(|(i, (name, server))| {
            forms::row(
                cx,
                &ctx.icons,
                f,
                &format!("acct:{i}"),
                "user",
                name,
                Some(server),
                if i == p.active {
                    Trail::Check
                } else {
                    Trail::None
                },
                true,
            )
        })
        .collect();
    // Per-row sign-out: one row per account under the list (the list row itself switches).
    let outs = p
        .accounts
        .iter()
        .enumerate()
        .map(|(i, (name, _))| {
            forms::row(
                cx,
                &ctx.icons,
                f,
                &format!("out:{i}"),
                "sign-out",
                &format!("{name} abmelden"),
                None,
                Trail::None,
                true,
            )
        })
        .collect();
    vec![
        forms::setting_group(cx, f, "Konten", 18.0, rows),
        forms::setting_group(cx, f, "Abmelden", 18.0, outs),
        forms::button(
            cx,
            &ctx.icons,
            f,
            "add",
            "Server hinzufügen",
            Some("plug"),
            false,
            false,
            true,
        )
        .padding(ins(24.0, 0.0, 0.0, 0.0)),
    ]
}

/// A centred tv column on `reason` (`tvOS/QuickConnectView.swift`: no header, the title in the page, buttons in a row).
fn tv_page(rows: Vec<Node>) -> Node {
    let col = Node::vstack(Align::Center, Some(0.0), rows);
    crate::home::fill_frame(col, Alignment::CENTER)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
}

fn tv_title(cx: &Cx, s: &str) -> Node {
    text(
        cx,
        s,
        swiftly_design::TextStyle {
            tracking: 0.0,
            ..st(56.0, 700)
        },
        colour::FONT,
        Some(1),
        swiftly_text::Align::Center,
    )
}

/// tvOS Quick Connect: title, sentence 30 wide 1100, the code, "Läuft ab in m:ss", the guide 900 wide, three buttons.
fn tv_quick(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Node {
    let mut rows = vec![
        tv_title(cx, "Quick Connect"),
        text(
            cx,
            "Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.",
            st(30.0, 400),
            colour::FONT_QUIET,
            Some(3),
            swiftly_text::Align::Center,
        )
        .frame(Some(1100.0), None, Alignment::CENTER)
        .padding(ins(16.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(e) = &p.error {
        rows.push(
            text(
                cx,
                e,
                st(30.0, 400),
                colour::ERROR,
                Some(3),
                swiftly_text::Align::Center,
            )
            .frame(Some(1100.0), None, Alignment::CENTER)
            .padding(ins(56.0, 0.0, 0.0, 0.0)),
        );
    } else {
        rows.push(code_fields(cx, f, &p.code).padding(ins(56.0, 0.0, 0.0, 0.0)));
        rows.push(
            tabular_text(
                cx,
                &format!("Läuft ab in {}:{:02}", p.left / 60, p.left % 60),
                st(24.0, 400),
                colour::FONT_VERY_QUIET,
                Some(1),
                swiftly_text::Align::Center,
            )
            .padding(ins(28.0, 0.0, 0.0, 0.0)),
        );
    }
    let step = |n: u8, s: &str| {
        Node::hstack(
            Align::Start,
            Some(20.0),
            vec![
                text(
                    cx,
                    &n.to_string(),
                    st(26.0, 500),
                    colour::FONT_VERY_QUIET,
                    Some(1),
                    swiftly_text::Align::Start,
                )
                .frame(Some(32.0), None, Alignment::LEADING),
                text(
                    cx,
                    s,
                    st(26.0, 500),
                    colour::FONT_QUIET,
                    Some(2),
                    swiftly_text::Align::Start,
                ),
            ],
        )
    };
    rows.push(
        Node::vstack(
            Align::Start,
            Some(14.0),
            vec![
                text(
                    cx,
                    "So gehts",
                    swiftly_design::TextStyle {
                        tracking: -0.2,
                        ..st(34.0, 700)
                    },
                    colour::FONT,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                step(1, "Jellyfin im Browser öffnen und anmelden"),
                step(2, "Oben rechts aufs Profil, dann Quick Connect"),
                step(3, "Code eingeben, dann geht es hier von selbst weiter"),
            ],
        )
        .frame(Some(900.0), None, Alignment::LEADING)
        .padding(ins(56.0, 0.0, 0.0, 0.0)),
    );
    rows.push(
        Node::hstack(
            Align::Center,
            Some(24.0),
            vec![
                forms::button(
                    cx,
                    &ctx.icons,
                    f,
                    "newcode",
                    "Neuer Code",
                    None,
                    false,
                    false,
                    true,
                )
                .frame(Some(300.0), None, Alignment::CENTER),
                forms::button(
                    cx,
                    &ctx.icons,
                    f,
                    "password",
                    "Lieber Name und Passwort",
                    None,
                    false,
                    false,
                    true,
                )
                .frame(Some(560.0), None, Alignment::CENTER),
                forms::button(
                    cx, &ctx.icons, f, "back", "Zurück", None, false, false, true,
                )
                .frame(Some(260.0), None, Alignment::CENTER),
            ],
        )
        .padding(ins(52.0, 0.0, 0.0, 0.0)),
    );
    tv_page(rows)
}

/// tvOS user name and password ("Anmelden", placeholder "Kennwort", "Lieber Quick Connect").
fn tv_password(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Node {
    let mut rows = vec![
        tv_title(cx, "Anmelden"),
        Node::vstack(
            Align::Start,
            Some(20.0),
            vec![
                forms::input_ex(
                    cx,
                    &ctx.icons,
                    f,
                    "field:user",
                    "user",
                    "Benutzername",
                    &p.shown(Field::User),
                    false,
                    p.field == Field::User,
                    p.edit.as_ref(),
                ),
                forms::input_ex(
                    cx,
                    &ctx.icons,
                    f,
                    "field:pass",
                    "lock",
                    "Kennwort",
                    &p.shown(Field::Password),
                    true,
                    p.field == Field::Password,
                    p.edit.as_ref(),
                ),
            ],
        )
        .frame(Some(760.0), None, Alignment::CENTER)
        .padding(ins(56.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(e) = &p.error {
        rows.push(
            text(
                cx,
                e,
                st(30.0, 400),
                colour::ERROR,
                Some(3),
                swiftly_text::Align::Center,
            )
            .frame(Some(1100.0), None, Alignment::CENTER)
            .padding(ins(28.0, 0.0, 0.0, 0.0)),
        );
    }
    rows.push(
        Node::hstack(
            Align::Center,
            Some(24.0),
            vec![
                forms::button(
                    cx,
                    &ctx.icons,
                    f,
                    "signin",
                    if p.checking {
                        "Anmelden…"
                    } else {
                        "Anmelden"
                    },
                    None,
                    true,
                    false,
                    !p.checking && !p.user.is_empty(),
                )
                .frame(Some(300.0), None, Alignment::CENTER),
                forms::button(
                    cx,
                    &ctx.icons,
                    f,
                    "quick",
                    "Lieber Quick Connect",
                    None,
                    false,
                    false,
                    true,
                )
                .frame(Some(460.0), None, Alignment::CENTER),
            ],
        )
        .padding(ins(52.0, 0.0, 0.0, 0.0)),
    );
    tv_page(rows)
}

fn view(p: &Parts, env: &Env, cx: &Cx, ctx: &Rc<Ctx>) -> Node {
    if crate::home::Form::of(env.idiom) == crate::home::Form::Tv {
        let f = forms::fm(env);
        match p.step {
            Step::Quick => return tv_quick(cx, &f, p, ctx),
            Step::Credentials => return tv_password(cx, &f, p, ctx),
            _ => {}
        }
    }
    let f = Fm {
        col: forms::fm(env).col.min(if p.step == Step::Accounts {
            560.0
        } else {
            420.0
        }),
        ..forms::fm(env)
    };
    if f.form == crate::home::Form::Desktop {
        return login_mac::view(p, env, cx, ctx, &f, || {
            forms::page(
                cx,
                &ctx.icons,
                env,
                &f,
                "Profil wechseln",
                None,
                accounts_body(cx, &f, p, ctx),
                None,
            )
        });
    }
    let (title, body) = match p.step {
        Step::Address => ("Server hinzufügen", address_body(cx, &f, p, ctx)),
        Step::Credentials => ("demo.swiftly.test", credentials_body(cx, &f, p, ctx)),
        Step::Quick => ("Quick Connect", quick_body(cx, &f, p)),
        Step::Accounts => ("Konto wechseln", accounts_body(cx, &f, p, ctx)),
        Step::Kind | Step::EmbyAddress | Step::EmbyCredentials | Step::Plex => {
            ("Server hinzufügen", address_body(cx, &f, p, ctx))
        }
    };
    let pinned = (p.step == Step::Quick).then(|| pinned_new_code(cx, &f, env, ctx));
    forms::page(cx, &ctx.icons, env, &f, title, None, body, pinned)
}

/// The sign-in flow and account switcher.
pub struct LoginScreen {
    /// Every text field of the flow: one editor each, the keyboard in one of them (the shared field model).
    book: crate::field_book::FieldBook<Field>,
    cx: Cx,
    /// The mouse button is down in a field: moving selects.
    dragging: bool,
    ui: Ui<Parts>,
    p: Parts,
    quick_since: Option<f64>,
    closed: bool,
    signed_in: Option<String>,
    switched: Option<usize>,
    sign_out: Option<usize>,
    add_server: bool,
    /// The real server behind the flow (`None`: the scripted one of the demo).
    backend: Option<Rc<dyn SignInBackend>>,
    waiting: Option<Wait>,
    /// When the last Quick Connect poll was sent.
    last_poll: f64,
    /// The text the user asked to copy (the shell puts it on the clipboard).
    copy: Option<String>,
    /// When the current Plex step or Emby load began.
    stage_since: Option<f64>,
    /// Servers found by the broadcast (live only).
    found_rx: Option<std::sync::mpsc::Receiver<Vec<FoundServer>>>,
    /// The full address behind each row of `Mac::found`.
    found_full: Vec<String>,
    /// The Emby user list while it loads.
    users_rx: Option<Pending<Vec<String>>>,
    /// The Plex worker's messages.
    plex_rx: Option<std::sync::mpsc::Receiver<PlexEvent>>,
    /// When the Plex wait began.
    plex_since: Option<f64>,
    /// A page the shell should open in the browser.
    open: Option<String>,
}

/// A result that arrives from a worker thread.
pub struct Pending<T>(pub std::sync::mpsc::Receiver<T>);

impl<T> Pending<T> {
    /// A pending value and the sender that fills it.
    pub fn channel() -> (std::sync::mpsc::Sender<T>, Pending<T>) {
        let (tx, rx) = std::sync::mpsc::channel();
        (tx, Pending(rx))
    }
}

/// What the sign-in flow needs from a real server. Every call returns at once; the answer arrives in the `Pending`.
pub trait SignInBackend {
    /// Checks the typed address (scheme guess, `http` fallback, 8 s deadline). Answer: the address that works.
    fn connect(&self, typed: &str) -> Pending<Result<String, String>>;
    /// User name and password. Answer: the signed-in user name.
    fn password(&self, user: &str, password: &str) -> Pending<Result<String, String>>;
    /// Starts Quick Connect. Answer: the six-digit code.
    fn quick_start(&self) -> Pending<Result<String, String>>;
    /// Asks whether the code was approved. Answer: `Some(user)` once signed in; an `Err` ends the wait.
    fn quick_poll(&self) -> Pending<Result<Option<String>, String>>;
    /// Hands the typed "Erweitert" headers over before the next address check; the transport sends them to that server.
    fn set_headers(&self, _headers: &[(String, String)]) {}
    /// Servers found on the local network, round by round (all found so far). `None`: no discovery.
    fn discover(&self) -> Option<std::sync::mpsc::Receiver<Vec<FoundServer>>> {
        None
    }
    /// Checks the typed Emby address.
    fn emby_connect(&self, _typed: &str) -> Pending<Result<EmbyFound, String>> {
        let (tx, rx) = Pending::channel();
        let _ = tx.send(Err(signin_flows::EMBY_DOWN.to_owned()));
        rx
    }
    /// The user names of the Emby server ("Wer schaut?").
    fn emby_users(&self) -> Pending<Vec<String>> {
        let (tx, rx) = Pending::channel();
        let _ = tx.send(Vec::new());
        rx
    }
    /// Starts the Plex sign-in. The worker sends the page to open, then the profiles, or a failure.
    fn plex_begin(&self) -> Option<std::sync::mpsc::Receiver<PlexEvent>> {
        None
    }
    /// Picks a Plex profile (`pin` empty for none) and lists the servers: (name, detail).
    fn plex_pick(
        &self,
        _index: usize,
        _pin: &str,
    ) -> Pending<Result<Vec<(String, String)>, String>> {
        let (tx, rx) = Pending::channel();
        let _ = tx.send(Err("Das hat nicht geklappt.".to_owned()));
        rx
    }
    /// Picks a Plex server and stores the account. Answer: the profile name.
    fn plex_finish(&self, _index: usize) -> Pending<Result<String, String>> {
        let (tx, rx) = Pending::channel();
        let _ = tx.send(Err("Das hat nicht geklappt.".to_owned()));
        rx
    }
}

enum Wait {
    Connect(Pending<Result<String, String>>),
    Password(Pending<Result<String, String>>),
    QuickStart(Pending<Result<String, String>>),
    QuickPoll(Pending<Result<Option<String>, String>>),
    EmbyConnect(Pending<Result<EmbyFound, String>>),
    PlexPick(Pending<Result<Vec<(String, String)>, String>>),
    PlexFinish(Pending<Result<String, String>>),
}

impl LoginScreen {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// The flow over a real server, starting at the address.
    pub fn live(env: Env, cx: Cx, backend: Rc<dyn SignInBackend>) -> LoginScreen {
        let desktop = crate::home::Form::of(env.idiom) == crate::home::Form::Desktop;
        let mut s = LoginScreen::new(env, cx, if desktop { Start::Kind } else { Start::Address });
        s.p.mac.available = [true; 3];
        s.found_rx = backend.discover();
        s.p.mac.version.clear();
        s.p.mac.found.clear();
        s.p.mac.users = None;
        s.p.mac.server_name.clear();
        s.p.accounts.clear();
        s.p.code = String::new();
        s.backend = Some(backend);
        s.sync();
        s
    }

    /// The flow as "Server hinzufügen" (the picker with its header; no change on touch and tv).
    #[must_use]
    pub fn into_add(mut self) -> LoginScreen {
        self.p.mac.add = true;
        self.sync();
        self
    }

    /// The account list over the stored accounts of the real app (`accounts`: name and server, `active` the one in use).
    pub fn with_accounts(
        env: Env,
        cx: Cx,
        accounts: Vec<(String, String)>,
        active: usize,
    ) -> LoginScreen {
        let mut s = LoginScreen::new(env, cx, Start::Accounts);
        s.p.accounts = accounts;
        s.p.active = active;
        s.sync();
        s
    }

    /// Takes the answer of a worker thread, if it has come.
    fn poll_wait(&mut self) {
        use std::sync::mpsc::TryRecvError::{Disconnected, Empty};
        let Some(w) = self.waiting.take() else { return };
        macro_rules! take {
            ($rx:expr, $w:ident) => {
                match $rx.0.try_recv() {
                    Ok(v) => v,
                    Err(Empty) => {
                        self.waiting = Some(Wait::$w($rx));
                        return;
                    }
                    Err(Disconnected) => {
                        self.p.checking = false;
                        self.p.error = Some("Die Verbindung ist abgebrochen.".into());
                        self.sync();
                        return;
                    }
                }
            };
        }
        match w {
            Wait::Connect(rx) => match take!(rx, Connect) {
                Ok(addr) => {
                    self.p.mac.server_name = addr
                        .trim_start_matches("https://")
                        .trim_start_matches("http://")
                        .trim_end_matches('/')
                        .to_owned();
                    self.p.address = addr;
                    self.p.checking = false;
                    self.p.error = None;
                    self.p.step = Step::Credentials;
                    self.p.field = Field::User;
                }
                Err(e) => {
                    self.p.checking = false;
                    self.p.error = Some(e);
                }
            },
            Wait::Password(rx) => match take!(rx, Password) {
                Ok(user) => {
                    self.p.checking = false;
                    self.signed_in = Some(user);
                    self.closed = true;
                }
                Err(e) => {
                    self.p.checking = false;
                    self.p.error = Some(e);
                }
            },
            Wait::QuickStart(rx) => match take!(rx, QuickStart) {
                Ok(code) => {
                    self.p.code = code;
                    self.quick_since = None;
                    self.last_poll = f64::NEG_INFINITY;
                }
                Err(e) => self.p.error = Some(e),
            },
            Wait::EmbyConnect(rx) => match take!(rx, EmbyConnect) {
                Ok(f) => {
                    self.p.checking = false;
                    self.p.error = None;
                    self.p.address = f.address;
                    self.p.mac.kind = Kind::Emby;
                    self.p.mac.server_name = f.name;
                    self.p.mac.version = f.version;
                    self.p.mac.users = None;
                    self.p.step = Step::EmbyCredentials;
                    self.p.field = Field::User;
                    self.users_rx = self.backend.as_ref().map(|b| b.emby_users());
                }
                Err(e) => {
                    self.p.checking = false;
                    self.p.error = Some(e);
                }
            },
            Wait::PlexPick(rx) => match take!(rx, PlexPick) {
                Ok(servers) => {
                    self.p.mac.servers = servers;
                    self.p.mac.plex = PlexStep::Servers;
                    self.p.mac.pin.clear();
                    self.p.mac.pin_state = PinState::Idle;
                }
                Err(e)
                    if e == swiftly_plex::PlexError::ProfilePinWrong
                        .text_key()
                        .unwrap_or_default() =>
                {
                    self.p.mac.pin.clear();
                    self.p.mac.pin_state = PinState::Wrong;
                }
                Err(e) => {
                    self.p.mac.plex = PlexStep::Failed;
                    self.p.error = Some(e);
                }
            },
            Wait::PlexFinish(rx) => match take!(rx, PlexFinish) {
                Ok(name) => {
                    self.signed_in = Some(name);
                    self.closed = true;
                }
                Err(e) => {
                    self.p.mac.plex = PlexStep::Failed;
                    self.p.error = Some(e);
                }
            },
            Wait::QuickPoll(rx) => match take!(rx, QuickPoll) {
                Ok(Some(user)) => {
                    self.signed_in = Some(user);
                    self.closed = true;
                }
                Ok(None) => {}
                Err(e) => self.p.error = Some(e),
            },
        }
        self.sync();
    }

    /// Asks for the Quick Connect approval every two seconds while the code is shown.
    fn poll_quick(&mut self, now: f64) {
        let Some(b) = self.backend.clone() else {
            return;
        };
        if self.p.step == Step::Quick
            && self.waiting.is_none()
            && !self.p.code.is_empty()
            && self.p.error.is_none()
            && now - self.last_poll >= QuickConnectDeadline::TICK as f64 * 1000.0
        {
            self.last_poll = now;
            self.waiting = Some(Wait::QuickPoll(b.quick_poll()));
        }
    }
}

impl LoginScreen {
    /// The flow for `env`, starting at `start`.
    pub fn new(env: Env, cx: Cx, start: Start) -> LoginScreen {
        let p = Parts {
            step: match start {
                Start::Address => Step::Address,
                Start::Accounts => Step::Accounts,
                Start::Kind | Start::AddKind
                    if crate::home::Form::of(env.idiom) == crate::home::Form::Desktop =>
                {
                    Step::Kind
                }
                Start::Kind | Start::AddKind => Step::Address,
            },
            field: Field::Address,
            mac: Mac {
                add: start == Start::AddKind,
                ..Mac::new()
            },
            address: String::new(),
            user: String::new(),
            password: String::new(),
            checking: false,
            code: CODE.to_owned(),
            error: None,
            left: QuickConnectDeadline::SECONDS,
            accounts: vec![
                ("Paul".into(), browse::SERVER.into()),
                ("Mama".into(), browse::SERVER.into()),
                ("Paul".into(), "kino.zuhause.example".into()),
            ],
            active: 0,
            edit: None,
        };
        let text_cx = cx.clone();
        let ctx = Rc::new(Ctx {
            icons: Icons::new(&cx, env.scale),
        });
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &ctx),
            p.clone(),
            env,
            cx,
        );
        LoginScreen {
            ui,
            p,
            quick_since: None,
            closed: false,
            signed_in: None,
            switched: None,
            sign_out: None,
            add_server: false,
            backend: None,
            waiting: None,
            last_poll: f64::NEG_INFINITY,
            copy: None,
            stage_since: None,
            found_rx: None,
            found_full: Vec::new(),
            users_rx: None,
            plex_rx: None,
            plex_since: None,
            open: None,
            book: crate::field_book::FieldBook::new(),
            cx: text_cx,
            dragging: false,
        }
    }

    /// Whether a worker is running or the Quick Connect wait is on (the app keeps drawing frames).
    pub fn pending(&self) -> bool {
        self.backend.is_some()
            && (self.waiting.is_some()
                || self.p.step == Step::Quick
                || self.plex_rx.is_some()
                || self.users_rx.is_some()
                || (self.found_rx.is_some() && self.p.step == Step::Address))
    }

    /// The step in front.
    pub fn step(&self) -> Step {
        self.p.step
    }
    /// The error line, if any.
    pub fn error(&self) -> Option<&str> {
        self.p.error.as_deref()
    }
    /// The user that signed in (the flow is done).
    pub fn signed_in(&self) -> Option<&str> {
        self.signed_in.as_deref()
    }
    /// The account picked in the list.
    pub fn switched(&self) -> Option<usize> {
        self.switched
    }
    /// The account row whose "abmelden" was tapped (taken once).
    pub fn take_sign_out(&mut self) -> Option<usize> {
        self.sign_out.take()
    }
    /// The host has taken the picked account.
    pub fn clear_switched(&mut self) {
        self.switched = None;
    }
    /// Whether "Server hinzufügen" was tapped in the account list.
    pub fn add_server(&mut self) -> bool {
        std::mem::take(&mut self.add_server)
    }
    /// Seconds left of the Quick Connect code.
    pub fn seconds_left(&self) -> u64 {
        self.p.left
    }
    /// Whether typed text goes into a field.
    pub fn wants_text(&self) -> bool {
        matches!(
            self.p.step,
            Step::Address | Step::Credentials | Step::EmbyAddress | Step::EmbyCredentials
        ) || (self.p.step == Step::Plex && self.p.mac.plex == PlexStep::Pin)
    }
    /// The text of the field that has the keyboard.
    fn field_mut(&mut self) -> &mut String {
        match self.p.field {
            Field::Address => &mut self.p.address,
            Field::User => &mut self.p.user,
            Field::Password => &mut self.p.password,
            Field::HName(i) => {
                let n = self.p.mac.headers.len();
                &mut self.p.mac.headers[i.min(n.saturating_sub(1))].0
            }
            Field::HValue(i) => {
                let n = self.p.mac.headers.len();
                &mut self.p.mac.headers[i.min(n.saturating_sub(1))].1
            }
            Field::Pin => &mut self.p.mac.pin,
        }
    }
    /// The composition of the input method (empty ends it).
    pub fn set_preedit(&mut self, text: &str) {
        self.edit(&TextInputEvent::Preedit {
            text: text.to_owned(),
            cursor: Some((text.len(), text.len())),
        });
    }
    /// What the input method needs: whether it may open, whether the field is a password, and the caret's rectangle
    /// in window points (the candidate window sits there).
    pub fn ime_state(&self) -> crate::ime::ImeState {
        let area = match self.ui.frame_of(swiftly_ui::field::CONTENT_KEY) {
            Some([x, y, _, h]) => {
                // The candidate window sits at the caret (inside the composition while one is open).
                let caret = self.book.state(self.p.field).and_then(|s| {
                    let d = s.editor.display();
                    let size = self.field_size();
                    let layout = self.cx.text.borrow_mut().layout(
                        &d.text,
                        &swiftly_text::TextStyle::new(size, 400),
                        None,
                        None,
                        swiftly_text::Align::Start,
                    );
                    d.caret
                        .or(d.preedit.as_ref().map(|r| r.end))
                        .or(Some(d.text.len()))
                        .map(|c| layout.caret_rect(c, 1.5).x)
                });
                Some([x + caret.unwrap_or(0.0), y, 1.5, h])
            }
            None => self.ui.frame_of(crate::forms::CARET_KEY),
        };
        crate::ime::ImeState {
            allowed: self.wants_text(),
            password: matches!(
                self.p.field,
                Field::Password | Field::Pin | Field::HValue(_)
            ),
            area,
        }
    }
    /// Type size of the focused field in this idiom (the Mac layout's rows are 14, television 28, the rest 15).
    fn field_size(&self) -> f32 {
        match crate::home::Form::of(self.ui.env().idiom) {
            crate::home::Form::Tv => 28.0,
            crate::home::Form::Desktop => login_mac::FIELD_SIZE,
            crate::home::Form::Touch => 15.0,
        }
    }
    /// Typed text.
    pub fn type_text(&mut self, s: &str) {
        self.edit(&TextInputEvent::Text(s.to_owned()));
    }
    /// Backspace.
    pub fn backspace(&mut self) {
        self.edit(&TextInputEvent::Key(
            swiftly_text::EditKey::Backspace,
            swiftly_text::Mods::NONE,
        ));
    }
    /// Ctrl+A: selects the whole text of the field that has the keyboard.
    pub fn select_all(&mut self) {
        self.edit(&TextInputEvent::SelectAll);
    }
    /// Uses another clipboard than the system's (tests).
    pub fn set_clipboard(&mut self, clip: Box<dyn swiftly_text::Clipboard>) {
        self.book.set_clipboard(clip);
    }
    /// Makes sure the editor of `f` exists (password fields mask and never give text away, the PIN takes four digits).
    fn ensure_field(&mut self, f: Field) {
        self.book.ensure(f, || match f {
            Field::Password | Field::HValue(_) => TextEditor::single_line().password(),
            Field::Pin => TextEditor::single_line().max_len(4),
            _ => TextEditor::single_line(),
        });
    }
    /// Gives the keyboard to the field the form says has it and loads its text into the editor.
    fn bind_editor(&mut self) {
        let f = self.p.field;
        self.ensure_field(f);
        self.book.focus(f, 0.0);
        let text = self.field_mut().clone();
        self.book.set_text(f, &text);
    }
    /// One text-input event for the field in front (typing, caret keys, selection, clipboard, undo, composition). The
    /// editor is the single state machine; the form's strings follow it. Returns whether a field took it.
    pub fn edit(&mut self, ev: &TextInputEvent) -> bool {
        if !self.wants_text() {
            return false;
        }
        self.bind_editor();
        let f = self.p.field;
        let Some(out) = self.book.apply(ev, 0.0) else {
            return false;
        };
        let text = self.book.text(f).to_owned();
        *self.field_mut() = text;
        if out.text_changed {
            self.p.error = None;
            self.p.mac.pin_state = PinState::Idle;
            if self.p.step == Step::Plex && self.p.field == Field::Pin {
                self.check_pin();
            }
        }
        if out.submitted {
            self.submit();
        }
        self.sync();
        true
    }
    /// The mouse went down at `(x, y)` (page coordinates): the field under it gets the keyboard and the caret goes where
    /// the pointer is (a double click selects the word).
    pub fn pointer_press(&mut self, x: f32, y: f32, shift: bool) {
        if !self.wants_text() {
            return;
        }
        for (key, f) in [
            ("field:addr", Field::Address),
            ("field:user", Field::User),
            ("field:pass", Field::Password),
        ] {
            let Some([fx, fy, fw, fh]) = self.ui.frame_of(key) else {
                continue;
            };
            if x < fx || x > fx + fw || y < fy || y > fy + fh {
                continue;
            }
            self.p.field = f;
            self.bind_editor();
            self.dragging = true;
            self.place_caret(f, x, shift);
            return;
        }
    }
    /// The mouse moved with the button down: the selection follows.
    pub fn pointer_drag(&mut self, x: f32, _y: f32) {
        if self.dragging && self.wants_text() {
            let f = self.p.field;
            self.place_caret(f, x, true);
        }
    }
    /// The mouse button went up.
    pub fn pointer_release(&mut self) {
        self.dragging = false;
    }
    fn place_caret(&mut self, f: Field, x: f32, extend: bool) {
        let Some(state) = self.book.state(f) else {
            return;
        };
        let d = state.editor.display();
        let Some([tx, ..]) = self.ui.frame_of(swiftly_ui::field::CONTENT_KEY) else {
            return;
        };
        let size = self.field_size();
        let style = swiftly_text::TextStyle::new(size, 400);
        let layout = self.cx.text.borrow_mut().layout(
            &d.text,
            &style,
            None,
            None,
            swiftly_text::Align::Start,
        );
        let shown = layout.hit_test(x - tx, 0.0);
        let index = crate::field_book::committed_index(
            state.editor.text(),
            state.editor.is_password(),
            shown,
        );
        let _ = self
            .book
            .apply(&TextInputEvent::SetCaret { index, extend }, 0.0);
        self.sync();
    }
    /// The editor's display for the field in front, for drawing.
    fn current_display(&mut self) -> Option<swiftly_text::Display> {
        if !self.wants_text() {
            return None;
        }
        self.bind_editor();
        self.book.state(self.p.field).map(|s| s.editor.display())
    }
    /// A caret key without the editor in the way (tests of the old selection model).
    pub fn deselect(&mut self) {
        self.edit(&TextInputEvent::Key(
            swiftly_text::EditKey::Right,
            swiftly_text::Mods::NONE,
        ));
    }
    /// Whether the whole text of the field in front is selected (tests).
    pub fn is_selected(&self) -> bool {
        let Some(state) = self.book.state(self.p.field) else {
            return false;
        };
        !state.editor.text().is_empty()
            && state.editor.selection() == (0..state.editor.text().len())
    }
    /// The text of the field in front (tests).
    pub fn field_text(&mut self) -> String {
        self.field_mut().clone()
    }
    /// Tab and Shift+Tab: the keyboard goes to the next (previous) field of the step, in reading order. Returns whether
    /// there was another field to go to.
    pub fn tab_field(&mut self, reverse: bool) -> bool {
        if !self.wants_text() {
            return false;
        }
        let order: &[Field] = match self.p.step {
            Step::Credentials | Step::EmbyCredentials => &[Field::User, Field::Password],
            _ => return false,
        };
        let at = order.iter().position(|f| *f == self.p.field).unwrap_or(0);
        let next = if reverse {
            (at + order.len() - 1) % order.len()
        } else {
            (at + 1) % order.len()
        };
        self.p.field = order[next];
        self.bind_editor();
        self.sync();
        true
    }
    /// Return: the primary button of the step.
    pub fn submit(&mut self) {
        match self.p.step {
            Step::Address | Step::EmbyAddress => self.connect(),
            Step::Credentials | Step::EmbyCredentials => self.sign_in(),
            Step::Plex if self.p.mac.plex == PlexStep::Pin => self.check_pin(),
            _ => {}
        }
    }

    fn connect(&mut self) {
        if self.p.address.is_empty() {
            return;
        }
        if let Some(b) = self.backend.clone() {
            if self.waiting.is_none() {
                self.p.checking = true;
                self.p.error = None;
                b.set_headers(&self.p.mac.headers);
                self.waiting = Some(if self.p.step == Step::EmbyAddress {
                    Wait::EmbyConnect(b.emby_connect(&self.p.address))
                } else {
                    Wait::Connect(b.connect(&self.p.address))
                });
            }
            return;
        }
        let emby = self.p.step == Step::EmbyAddress;
        if self.p.address.contains("offline") {
            self.p.error = Some(if emby {
                signin_flows::EMBY_DOWN.into()
            } else {
                signin_flows::JELLYFIN_DOWN.into()
            });
        } else {
            self.p.error = None;
            self.p.field = Field::User;
            if emby {
                self.p.step = Step::EmbyCredentials;
                self.p.mac.kind = Kind::Emby;
                self.p.mac.server_name = "Emby Zuhause".into();
                self.p.mac.version = "4.8.8.0".into();
                self.p.mac.users = None;
                self.stage_since = None;
            } else {
                self.p.step = Step::Credentials;
            }
        }
    }

    fn sign_in(&mut self) {
        if self.p.user.is_empty() {
            return;
        }
        if let Some(b) = self.backend.clone() {
            if self.waiting.is_none() {
                self.p.checking = true;
                self.p.error = None;
                self.waiting = Some(Wait::Password(b.password(&self.p.user, &self.p.password)));
            }
            return;
        }
        if self.p.password == "falsch" {
            self.p.error = Some("Benutzername oder Passwort stimmt nicht.".into());
        } else {
            self.signed_in = Some(self.p.user.clone());
            self.closed = true;
        }
    }

    fn start_quick(&mut self) {
        if let Some(b) = self.backend.clone() {
            self.p.code = String::new();
            self.waiting = Some(Wait::QuickStart(b.quick_start()));
        }
    }

    fn sync(&mut self) {
        self.p.edit = self.current_display();
        self.ui.set_parts(self.p.clone());
    }

    fn clock(&mut self, now: f64) {
        self.tick(now);
    }

    fn go_back(&mut self) -> bool {
        match self.p.step {
            Step::Quick => {
                self.p.step = Step::Credentials;
                self.p.error = None;
                self.quick_since = None;
                true
            }
            Step::Credentials => {
                self.p.step = Step::Address;
                self.p.field = Field::Address;
                self.p.error = None;
                true
            }
            Step::Address if self.p.mac.via_picker => {
                self.p.step = Step::Kind;
                self.p.error = None;
                true
            }
            Step::EmbyCredentials => {
                self.p.step = Step::EmbyAddress;
                self.p.field = Field::Address;
                self.p.error = None;
                true
            }
            Step::EmbyAddress => {
                self.p.step = Step::Kind;
                self.p.error = None;
                true
            }
            Step::Plex => {
                self.stage_since = None;
                if matches!(
                    self.p.mac.plex,
                    PlexStep::Start
                        | PlexStep::Opening
                        | PlexStep::Waiting
                        | PlexStep::Loading
                        | PlexStep::Failed
                ) {
                    self.plex_rx = None;
                    self.plex_since = None;
                }
                self.p.error = None;
                self.p.mac.plex = match self.p.mac.plex {
                    PlexStep::Start => {
                        self.p.step = Step::Kind;
                        PlexStep::Start
                    }
                    PlexStep::Pin => PlexStep::Profiles,
                    _ => PlexStep::Start,
                };
                true
            }
            // The first start has nowhere to go back to; "Server hinzufügen" closes.
            Step::Kind => !self.p.mac.add,
            _ => false,
        }
    }

    /// The scripted waits of the Emby user list and the Plex steps (the demo has no server).
    fn mac_tick(&mut self, now: f64) {
        if self.backend.is_some() {
            self.live_tick(now);
            return;
        }
        match self.p.step {
            Step::EmbyCredentials if self.p.mac.users.is_none() => {
                let since = *self.stage_since.get_or_insert(now);
                if now - since >= 600.0 {
                    self.p.mac.users = Some(vec!["Paul".into(), "Mama".into(), "Gast".into()]);
                    self.sync();
                }
            }
            Step::Plex => {
                let since = *self.stage_since.get_or_insert(now);
                let el = (now - since).max(0.0);
                match self.p.mac.plex {
                    PlexStep::Opening if el >= 800.0 => {
                        self.p.mac.plex = PlexStep::Waiting;
                        self.p.mac.plex_left = 300;
                        self.p.code = "K7QM".into();
                        self.stage_since = None;
                    }
                    PlexStep::Waiting => {
                        self.p.mac.plex_left = 300u64.saturating_sub((el / 1000.0) as u64);
                        if el >= 3000.0 {
                            self.p.mac.plex = PlexStep::Loading;
                            self.stage_since = None;
                        }
                    }
                    PlexStep::Loading if el >= 800.0 => {
                        self.p.mac.plex = PlexStep::Profiles;
                        self.stage_since = None;
                    }
                    _ => {}
                }
                self.sync();
            }
            _ => {}
        }
    }

    /// The messages of the workers of the real flows: servers found, Emby users, the Plex steps.
    fn live_tick(&mut self, now: f64) {
        if let Some(rx) = &self.found_rx {
            let mut latest = None;
            while let Ok(list) = rx.try_recv() {
                latest = Some(list);
            }
            if let Some(list) = latest {
                self.p.mac.found = list
                    .iter()
                    .map(|f| (f.name.clone(), f.short_address()))
                    .collect();
                self.found_full = list.into_iter().map(|f| f.address).collect();
            }
        }
        if let Some(rx) = &self.users_rx
            && let Ok(users) = rx.0.try_recv()
        {
            self.p.mac.users = Some(users);
            self.users_rx = None;
        }
        let mut events = Vec::new();
        if let Some(rx) = &self.plex_rx {
            while let Ok(ev) = rx.try_recv() {
                events.push(ev);
            }
        }
        for ev in events {
            match ev {
                PlexEvent::Open(url) => {
                    self.open = Some(url);
                    self.p.mac.plex = PlexStep::Waiting;
                    self.plex_since = None;
                }
                PlexEvent::Profiles(list) => {
                    self.p.mac.profiles = list;
                    self.p.mac.plex = PlexStep::Profiles;
                    self.plex_rx = None;
                }
                PlexEvent::Failed(text) => {
                    self.p.mac.plex = PlexStep::Failed;
                    self.p.error = Some(text);
                    self.plex_rx = None;
                }
            }
        }
        if self.p.mac.plex == PlexStep::Waiting && self.p.step == Step::Plex {
            let since = *self.plex_since.get_or_insert(now);
            self.p.mac.plex_left = 300u64.saturating_sub(((now - since).max(0.0) / 1000.0) as u64);
        }
        self.sync();
    }

    /// Sends the profile (and its PIN) to plex.tv and lists the servers.
    fn plex_pick(&mut self, pin: &str) {
        let Some(b) = self.backend.clone() else {
            return;
        };
        if self.waiting.is_none() {
            self.p.mac.pin_state = if pin.is_empty() {
                PinState::Idle
            } else {
                PinState::Checking
            };
            if pin.is_empty() {
                self.p.mac.plex = PlexStep::Loading;
            }
            self.waiting = Some(Wait::PlexPick(b.plex_pick(self.p.mac.profile, pin)));
        }
    }

    /// The PIN of a protected Plex profile (the demo knows 1234).
    fn check_pin(&mut self) {
        if self.p.mac.pin.chars().count() < 4 {
            return;
        }
        if self.backend.is_some() {
            let pin = self.p.mac.pin.clone();
            self.plex_pick(&pin);
            return;
        }
        if self.p.mac.pin == "1234" {
            self.p.mac.pin_state = PinState::Idle;
            self.p.mac.plex = PlexStep::Servers;
        } else {
            self.p.mac.pin_state = PinState::Wrong;
        }
        self.p.mac.pin.clear();
    }

    fn pick_kind(&mut self, i: usize) {
        if !self.p.mac.available.get(i).copied().unwrap_or(false) {
            return;
        }
        self.p.error = None;
        self.stage_since = None;
        match Kind::ORDER[i] {
            Kind::Jellyfin => {
                self.p.step = Step::Address;
                self.p.mac.via_picker = true;
                self.p.field = Field::Address;
            }
            Kind::Emby => {
                self.p.step = Step::EmbyAddress;
                self.p.mac.kind = Kind::Emby;
                self.p.mac.via_picker = true;
                self.p.field = Field::Address;
            }
            Kind::Plex => {
                self.p.step = Step::Plex;
                self.p.mac.plex = PlexStep::Start;
            }
        }
        // The address field has the keyboard on arrival (the Mac: `inputField = .address`): bind its editor now, not
        // only with the next frame or the first key.
        if self.wants_text() {
            self.dragging = false;
            self.sync();
        }
    }

    /// The frame `(x, y, w, h)` of the control with `key`, in the page's own coordinates (tests).
    #[doc(hidden)]
    pub fn frame_of(&self, key: &str) -> Option<[f32; 4]> {
        self.ui.frame_of(key)
    }

    /// The text typed into the address field and whether that field has the keyboard (tests).
    #[doc(hidden)]
    pub fn address_state(&self) -> (String, bool) {
        (
            self.p.address.clone(),
            self.p.field == Field::Address && self.p.edit.is_some(),
        )
    }

    /// The page the shell should open in the browser (the Plex sign-in).
    pub fn take_open(&mut self) -> Option<String> {
        self.open.take()
    }

    /// The pointer moved with no button held (hover).
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.pointer_move(x, y, now);
    }

    /// The pointer left the window.
    pub fn pointer_leave(&mut self, now: f64) {
        self.ui.pointer_leave(now);
    }

    /// The text the user asked to copy (the Quick Connect code); the shell puts it on the clipboard.
    pub fn take_copy(&mut self) -> Option<String> {
        self.copy.take()
    }

    /// Presses the control with `key` as a tap does (tests, goldens).
    #[doc(hidden)]
    pub fn press(&mut self, key: &str) {
        self.tapped(&Action::from(key));
        self.sync();
    }

    /// The Plex step in front.
    pub fn plex_step(&self) -> PlexStep {
        self.p.mac.plex
    }

    /// Advances the countdown; the wait ends with an error text when the code runs out.
    fn tick(&mut self, now: f64) {
        self.poll_wait();
        self.poll_quick(now);
        self.mac_tick(now);
        if self.p.step != Step::Quick {
            return;
        }
        let since = *self.quick_since.get_or_insert(now);
        let gone = ((now - since) / 1000.0).max(0.0) as u64;
        self.p.left = QuickConnectDeadline::SECONDS.saturating_sub(gone);
        if self.p.left == 0 {
            self.p.error = Some("Der Code ist abgelaufen. Hol dir einen neuen.".into());
        }
    }

    /// Opens the Quick Connect step as the button does (tests, goldens).
    #[doc(hidden)]
    pub fn quick_for_tests(&mut self) {
        self.tapped(&Action::from("quick"));
    }

    /// Marks a kind card as preparing ("Einen Moment …", its mark breathes); `None` clears it.
    pub fn set_kind_busy(&mut self, kind: Option<usize>) {
        self.p.mac.busy = kind;
        self.sync();
    }

    /// Lets the wait run `seconds` further (tests, goldens).
    pub fn skip_wait(&mut self, seconds: u64) {
        if let Some(s) = self.quick_since.as_mut() {
            *s -= seconds as f64 * 1000.0;
        }
    }

    /// The taps whose key ends in a number: kind cards, found servers, headers, profiles, servers, users.
    fn tapped_numbered(&mut self, a: &Action) {
        for i in 0..8 {
            let is = |s: &str| *a == Action::from(format!("{s}:{i}").as_str());
            if is("kind") {
                self.pick_kind(i);
            } else if is("adv:del") {
                if i < self.p.mac.headers.len() {
                    self.p.mac.headers.remove(i);
                    self.p.field = Field::Address;
                }
            } else if is("found") {
                if let Some(full) = self
                    .found_full
                    .get(i)
                    .cloned()
                    .or_else(|| self.p.mac.found.get(i).map(|f| f.1.clone()))
                {
                    self.p.address = full;
                    self.connect();
                }
            } else if is("profile") {
                if let Some((_, protected)) = self.p.mac.profiles.get(i).cloned() {
                    self.p.mac.profile = i;
                    self.p.mac.pin.clear();
                    self.p.mac.pin_state = PinState::Idle;
                    self.p.mac.plex = if protected {
                        PlexStep::Pin
                    } else {
                        PlexStep::Servers
                    };
                    self.p.field = Field::Pin;
                    if !protected && self.backend.is_some() {
                        self.plex_pick("");
                    }
                }
            } else if is("server") {
                if let Some(b) = self.backend.clone() {
                    if self.waiting.is_none() && i < self.p.mac.servers.len() {
                        self.p.mac.plex = PlexStep::Loading;
                        self.waiting = Some(Wait::PlexFinish(b.plex_finish(i)));
                    }
                } else if let Some((name, _)) = self.p.mac.servers.get(i) {
                    self.signed_in = Some(name.clone());
                    self.closed = true;
                }
            } else if is("user")
                && let Some(u) = self.p.mac.users.as_ref().and_then(|l| l.get(i)).cloned()
            {
                self.p.user = u;
                self.p.field = Field::Password;
            }
        }
    }

    fn tapped(&mut self, a: &Action) {
        let is = |s: &str| *a == Action::from(s);
        if is("back") {
            self.back(0.0);
        } else if is("field:addr") {
            self.p.field = Field::Address;
        } else if is("field:user") {
            self.p.field = Field::User;
        } else if is("field:pass") {
            self.p.field = Field::Password;
        } else if is("connect") {
            self.connect();
        } else if is("signin") {
            self.sign_in();
        } else if is("quick") {
            self.p.step = Step::Quick;
            self.p.error = None;
            self.p.left = QuickConnectDeadline::SECONDS;
            self.quick_since = None;
            self.start_quick();
        } else if is("password") {
            self.p.step = Step::Credentials;
            self.p.error = None;
        } else if is("newcode") {
            self.p.error = None;
            self.p.left = QuickConnectDeadline::SECONDS;
            self.quick_since = None;
            self.start_quick();
        } else if is("add") {
            self.add_server = true;
        } else if is("adv:toggle") {
            self.p.mac.advanced = !self.p.mac.advanced;
        } else if is("adv:add") {
            self.p.mac.headers.push((String::new(), String::new()));
            self.p.field = Field::HName(self.p.mac.headers.len() - 1);
        } else if is("retry") {
            self.connect();
        } else if is("copy") {
            self.copy = Some(self.p.code.clone());
            self.p.mac.copied = true;
        } else if is("plexstart") {
            self.p.mac.plex = PlexStep::Opening;
            self.stage_since = None;
            self.p.error = None;
            self.plex_since = None;
            self.plex_rx = self.backend.as_ref().and_then(|b| b.plex_begin());
        } else if is("plexagain") {
            self.p.mac.plex = PlexStep::Start;
        } else {
            self.tapped_numbered(a);
        }
        for i in 0..self.p.accounts.len() {
            if is(&format!("out:{i}")) {
                self.sign_out = Some(i);
            }
            if is(&format!("acct:{i}")) {
                self.p.active = i;
                self.switched = Some(i);
                self.closed = true;
            }
        }
    }

    crate::form_io!();
}

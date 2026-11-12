//! The desktop (Mac) look of the sign-in flow: the kind picker, the Jellyfin address and sign-in pages, the Quick Connect
//! code, the Emby and Plex steps. Sizes and texts follow `MacKindPicker`, `RootView` (ServerView, SignInView, InputRow),
//! `MacAdvanced`, `MacEmbySignIn`, `MacPlexSignIn` and `QuickConnectCode`; the touch and tv forms keep `login_screen`.
//! Own widgets live here (`forms.rs` belongs to the settings screens): the 38 high `InputRow` with its stroke, the 48 high
//! primary and the outline button.

use crate::browse::wide;
use crate::forms::{self, Fm};
use crate::home::{fill_frame, ins, rgba, tabular_text, text};
use crate::login_screen::{Ctx, Field, Parts, Step};
use swiftly_design::tokens::colour;
use swiftly_layout::{Align, Alignment};
use swiftly_render::Color;
use swiftly_ui::components::{color, focus_id};
use swiftly_ui::icons::Icons;
use swiftly_ui::{Cx, Env, FocusLook, Motion, Node};

/// The three kinds of server (`ServerKind.pickerOrder`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Kind {
    /// Jellyfin.
    #[default]
    Jellyfin,
    /// Plex.
    Plex,
    /// Emby.
    Emby,
}

impl Kind {
    /// The picker order.
    pub const ORDER: [Kind; 3] = [Kind::Jellyfin, Kind::Plex, Kind::Emby];

    /// `ServerKind.shownName`.
    pub fn shown(self) -> &'static str {
        match self {
            Kind::Jellyfin => "Jellyfin",
            Kind::Plex => "Plex (Beta)",
            Kind::Emby => "Emby (Beta)",
        }
    }

    /// `ServerKind.pitch`.
    pub fn pitch(self) -> &'static str {
        match self {
            Kind::Jellyfin => {
                "Adresse rein und anmelden, oder per Quick Connect ganz ohne Passwort."
            }
            Kind::Plex => "Einmal bei Plex anmelden, die App findet deine Server.",
            Kind::Emby => "Adresse von deinem Server rein, dann Name und Passwort.",
        }
    }

    /// `ServerKind.tint`: Jellyfin blue, Plex amber, Emby green.
    fn tint(self) -> Color {
        match self {
            Kind::Jellyfin => Color::new(0.0, 0.64, 0.86, 1.0),
            Kind::Plex => Color::new(0.90, 0.63, 0.05, 1.0),
            Kind::Emby => Color::new(0.32, 0.71, 0.29, 1.0),
        }
    }
}

/// The Plex steps (`PlexSignInModel.Step`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum PlexStep {
    /// The intro with "Mit Plex anmelden".
    #[default]
    Start,
    /// The browser is being opened.
    Opening,
    /// Waiting for the confirmation on plex.tv.
    Waiting,
    /// The profiles are loading.
    Loading,
    /// Who watches.
    Profiles,
    /// The PIN of a protected profile.
    Pin,
    /// The servers of the account.
    Servers,
    /// The flow failed.
    Failed,
}

/// Where the PIN check stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum PinState {
    /// Nothing sent.
    #[default]
    Idle,
    /// The PIN is being checked.
    Checking,
    /// The PIN did not fit.
    Wrong,
}

/// What the desktop flow needs besides the shared parts.
#[derive(Clone, PartialEq)]
pub struct Mac {
    /// The kind the flow is for.
    pub kind: Kind,
    /// Reached through the picker (the arrow goes back to it).
    pub via_picker: bool,
    /// "Server hinzufügen" (with a header) instead of the first start.
    pub add: bool,
    /// Which cards can be chosen.
    pub available: [bool; 3],
    /// The card that is being prepared.
    pub busy: Option<usize>,
    /// The "Erweitert" headers (name, value).
    pub headers: Vec<(String, String)>,
    /// Whether the headers editor is open.
    pub advanced: bool,
    /// Servers found in the network (name, address).
    pub found: Vec<(String, String)>,
    /// The version the server reported.
    pub version: String,
    /// The name the server reported.
    pub server_name: String,
    /// The users the server lists (`None`: still loading).
    pub users: Option<Vec<String>>,
    /// The Plex step.
    pub plex: PlexStep,
    /// Plex profiles (name, protected).
    pub profiles: Vec<(String, bool)>,
    /// The profile that was picked.
    pub profile: usize,
    /// The typed PIN.
    pub pin: String,
    /// The PIN check.
    pub pin_state: PinState,
    /// Seconds left while waiting for Plex.
    pub plex_left: u64,
    /// Plex servers (name, detail).
    pub servers: Vec<(String, String)>,
    /// Whether the code was just copied.
    pub copied: bool,
}

impl Mac {
    /// The scripted state of the demo.
    pub fn new() -> Mac {
        Mac {
            kind: Kind::Jellyfin,
            via_picker: false,
            add: false,
            available: [true; 3],
            busy: None,
            headers: Vec::new(),
            advanced: false,
            found: vec![("Wohnzimmer".into(), "192.168.1.20:8096".into())],
            version: "10.10.3".into(),
            server_name: "demo.swiftly.test".into(),
            users: None,
            plex: PlexStep::Start,
            profiles: vec![("Paul".into(), false), ("Mama".into(), true)],
            profile: 0,
            pin: String::new(),
            pin_state: PinState::Idle,
            plex_left: 300,
            servers: vec![
                ("Wohnzimmer".into(), "Zuhause · Plex Media Server".into()),
                ("Kino".into(), "Geteilt von Oma".into()),
            ],
            copied: false,
        }
    }
}

impl Default for Mac {
    fn default() -> Mac {
        Mac::new()
    }
}

fn st(size: f32, weight: u16) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

fn t(
    cx: &Cx,
    s: &str,
    size: f32,
    weight: u16,
    c: swiftly_design::Colour,
    lines: usize,
    align: swiftly_text::Align,
) -> Node {
    text(cx, s, st(size, weight), c, Some(lines), align)
}

/// `t` with tabular figures, for countdowns.
fn tt(
    cx: &Cx,
    s: &str,
    size: f32,
    weight: u16,
    c: swiftly_design::Colour,
    lines: usize,
    align: swiftly_text::Align,
) -> Node {
    tabular_text(cx, s, st(size, weight), c, Some(lines), align)
}

fn left(n: Node) -> Node {
    wide(n, Alignment::LEADING)
}

/// Type size of the text in an `InputRow`.
pub const FIELD_SIZE: f32 = 14.0;

/// `InputRow`: 38 high, 12 inside, corner 12 on the area colour, a stroke of 1 that becomes 2 while it has the keyboard.
#[allow(clippy::too_many_arguments)]
pub fn input_row(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    symbol: &str,
    placeholder: &str,
    value: &str,
    secret: bool,
    focused: bool,
    edit: Option<&swiftly_text::Display>,
) -> Node {
    let w = if focused { 2.0 } else { 1.0 };
    let mut row = vec![
        icons
            .node(symbol, 17.0, false, color(colour::FONT_VERY_QUIET))
            .frame(Some(20.0), None, Alignment::CENTER),
    ];
    if let (true, Some(d)) = (focused, edit) {
        // The shared field: caret, selection and composition come from the editor (keyed `field.text`).
        let look = swiftly_ui::field::FieldLook {
            style: swiftly_text::TextStyle::new(FIELD_SIZE, 400),
            text: color(colour::FONT),
            placeholder: color(colour::FONT_VERY_QUIET),
            caret: color(colour::MARK_ACCENT),
            selection: rgba(colour::MARK_ACCENT, 0.35),
            caret_height: Some(18.0),
        };
        let view = swiftly_ui::field::FieldView {
            display: d.clone(),
            placeholder: placeholder.to_owned(),
            focused: true,
            caret_on: true,
            touch: false,
            loupe: None,
        };
        row.push(swiftly_ui::field::field_content(cx, &view, &look));
    } else if value.is_empty() {
        row.push(t(
            cx,
            placeholder,
            FIELD_SIZE,
            400,
            colour::FONT_VERY_QUIET,
            1,
            swiftly_text::Align::Start,
        ));
    } else {
        let shown = if secret {
            "\u{2022}".repeat(value.chars().count())
        } else {
            value.to_owned()
        };
        row.push(t(
            cx,
            &shown,
            FIELD_SIZE,
            400,
            colour::FONT,
            1,
            swiftly_text::Align::Start,
        ));
    }
    row.push(Node::spacer());
    let inner = Node::hstack(Align::Center, Some(9.0), row)
        .padding(ins(0.0, 12.0, 0.0, 12.0))
        .frame(None, Some(38.0 - 2.0 * w), Alignment::LEADING);
    let n = wide(inner, Alignment::LEADING)
        .background(Node::rect(color(colour::AREA), 12.0 - w), Alignment::CENTER)
        .padding(ins(w, w, w, w))
        .background(Node::rect(color(colour::MARGIN), 12.0), Alignment::CENTER);
    forms::tappable(n, f, key, 12.0)
}

/// `PrimaryButton`: 48 high, white, the label (17 semibold) in the ground colour and an arrow; `enabled == false` dims it to 0.4.
pub fn primary(cx: &Cx, icons: &Icons, f: &Fm, key: &str, label: &str, enabled: bool) -> Node {
    // `PrimaryButton(symbol: "arrow.right")`: the arrow stands before the label, both in the 17 semibold of `categoryLarge`.
    let parts = vec![
        icons
            .node("arrow-right", 17.0, true, color(colour::REASON))
            .a11y_hidden(),
        t(
            cx,
            label,
            17.0,
            600,
            colour::REASON,
            1,
            swiftly_text::Align::Center,
        ),
    ];
    let n = wide(
        Node::hstack(Align::Center, Some(9.0), parts).frame(None, Some(48.0), Alignment::CENTER),
        Alignment::CENTER,
    )
    .background(Node::rect(color(colour::FONT), 10.0), Alignment::CENTER)
    .opacity(if enabled { 1.0 } else { 0.4 }, Motion::Instant);
    if enabled {
        forms::tappable(n, f, key, 10.0)
    } else {
        n.key(key)
    }
}

/// `OutlineButton` (`ProfileView.swift`): despite the name a fill, not a border: the area colour, corner 10, 48 high,
/// the symbol and the label (15 medium) in the accent.
pub fn outline(cx: &Cx, icons: &Icons, f: &Fm, key: &str, label: &str, symbol: &str) -> Node {
    let parts = vec![
        icons.node(symbol, 16.0, true, color(colour::MARK_ACCENT)),
        t(
            cx,
            label,
            15.0,
            500,
            colour::MARK_ACCENT,
            1,
            swiftly_text::Align::Center,
        ),
    ];
    let inner =
        Node::hstack(Align::Center, Some(9.0), parts).frame(None, Some(48.0), Alignment::CENTER);
    let n = wide(inner, Alignment::CENTER)
        .background(Node::rect(color(colour::AREA), 10.0), Alignment::CENTER);
    forms::tappable(n, f, key, 10.0)
}

fn kind_mark(icons: &Icons, kind: Kind, size: f32, grey: bool) -> Node {
    let c = if grey {
        color(colour::FONT_VERY_QUIET)
    } else {
        kind.tint()
    };
    icons
        .node("hard-drives", size, true, c)
        .frame(Some(44.0), Some(44.0), Alignment::CENTER)
}

fn hair() -> Node {
    wide(
        Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::CENTER),
        Alignment::CENTER,
    )
}

fn dot7() -> Node {
    Node::rect(color(colour::MARK_ACCENT), 3.5).frame(Some(7.0), Some(7.0), Alignment::CENTER)
}

fn warn(cx: &Cx, s: &str) -> Node {
    wide(
        t(
            cx,
            s,
            13.0,
            400,
            colour::ERROR,
            3,
            swiftly_text::Align::Center,
        ),
        Alignment::CENTER,
    )
    .padding(ins(12.0, 0.0, 0.0, 0.0))
}

fn skeleton(w: f32, h: f32, r: f32) -> Node {
    Node::rect(color(colour::AREA), r).frame(Some(w), Some(h), Alignment::CENTER)
}

/// The busy mark breathes between full opacity and this (`KindCard`: 1 to 0.45).
const BUSY_LOW: f32 = 0.45;

/// The one place for the curve of the busy mark, both from the catalogue: `Pulse` (`easeInOut(0.9)` back and forth while
/// preparing, off under Reduce Motion), `Float` (`easeOut(0.12)`) when it comes back to rest.
fn busy_motion(preparing: bool) -> Motion {
    if preparing {
        swiftly_ui::feel::pulse()
    } else {
        swiftly_ui::feel::hover()
    }
}

/// One card of the kind picker (`KindCard`).
fn kind_card(cx: &Cx, icons: &Icons, m: &Mac, i: usize) -> Node {
    let kind = Kind::ORDER[i];
    let open = m.available[i];
    let preparing = m.busy == Some(i);
    let (name_c, line_c) = if open {
        (colour::FONT, colour::FONT_QUIET)
    } else {
        (colour::FONT_VERY_QUIET, colour::FONT_VERY_QUIET)
    };
    let line = if preparing {
        "Einen Moment\u{2026}"
    } else if open {
        kind.pitch()
    } else {
        "Kommt mit einem der n\u{00E4}chsten Updates."
    };
    let mark = kind_mark(icons, kind, 34.0, !open).opacity(
        if preparing { BUSY_LOW } else { 1.0 },
        busy_motion(preparing),
    );
    let words = Node::vstack(
        Align::Start,
        Some(3.0),
        vec![
            left(t(
                cx,
                kind.shown(),
                15.0,
                600,
                name_c,
                1,
                swiftly_text::Align::Start,
            )),
            left(t(
                cx,
                line,
                14.0,
                400,
                line_c,
                3,
                swiftly_text::Align::Start,
            )),
        ],
    );
    let mut parts = vec![mark, wide(words, Alignment::LEADING)];
    if open {
        parts.push(icons.node("caret-right", 13.0, true, color(colour::FONT_VERY_QUIET)));
    }
    let card = wide(
        Node::hstack(Align::Center, Some(14.0), parts).padding(ins(16.0, 12.0, 16.0, 16.0)),
        Alignment::LEADING,
    )
    .background(
        Node::rect(color(colour::GROUPS_AREA), 14.0),
        Alignment::CENTER,
    );
    let key = format!("kind:{i}");
    if open && m.busy.is_none() {
        card.hover_surface(color(colour::PRESSED_AREA), 14.0)
            .key(key.as_str())
            .on_tap(swiftly_ui::Action::from(key.as_str()))
            .focusable(focus_id(key.as_str()), Some(FocusLook::tile(14.0)))
    } else {
        card.key(key.as_str())
    }
}

/// The picker: first start (wordmark, question, cards) or the "Server hinzufügen" page.
fn kind_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, p: &Parts) -> Node {
    let cards = Node::vstack(
        Align::Start,
        Some(10.0),
        (0..3).map(|i| kind_card(cx, icons, &p.mac, i)).collect(),
    );
    if p.mac.add {
        let body = vec![
            left(t(
                cx,
                "Du bleibst bei allen angemeldet und wechselst auf der Profilseite zwischen ihnen.",
                14.0,
                400,
                colour::FONT_QUIET,
                4,
                swiftly_text::Align::Start,
            ))
            .padding(ins(14.0, 0.0, 0.0, 0.0)),
            cards.padding(ins(26.0, 0.0, 0.0, 0.0)),
        ];
        return forms::page(
            cx,
            icons,
            env,
            f,
            "Server hinzuf\u{00FC}gen",
            None,
            body,
            None,
        );
    }
    let col = Node::vstack(
        Align::Center,
        Some(0.0),
        vec![
            // `MacKindPicker.swift:35`: `Wordmark(height: 44)`, the mark, not set type.
            icons.wordmark(44.0, color(colour::FONT), color(colour::MARK_ACCENT)),
            text(
                cx,
                "Was l\u{00E4}uft bei dir?",
                swiftly_design::TextStyle {
                    tracking: -0.4,
                    ..st(28.0, 700)
                },
                colour::FONT,
                Some(1),
                swiftly_text::Align::Center,
            )
            .padding(ins(40.0, 0.0, 0.0, 0.0)),
            t(
                cx,
                "Weitere Server kannst du sp\u{00E4}ter dazunehmen, auch gemischt.",
                14.0,
                400,
                colour::FONT_QUIET,
                2,
                swiftly_text::Align::Center,
            )
            .padding(ins(8.0, 0.0, 0.0, 0.0)),
            cards
                .frame(Some(420.0), None, Alignment::TOP)
                .padding(ins(28.0, 0.0, 0.0, 0.0)),
        ],
    );
    fill_frame(col, Alignment::CENTER)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
}

/// `MacAdvanced`: the "Erweitert" line and, when open, the header rows.
fn advanced(cx: &Cx, icons: &Icons, f: &Fm, p: &Parts) -> Node {
    let m = &p.mac;
    let head = forms::tappable(
        Node::hstack(
            Align::Center,
            Some(6.0),
            vec![
                t(
                    cx,
                    "Erweitert",
                    13.0,
                    400,
                    colour::FONT_QUIET,
                    1,
                    swiftly_text::Align::Start,
                ),
                icons.node("caret-right", 10.0, true, color(colour::FONT_QUIET)),
            ],
        )
        .frame(None, Some(24.0), Alignment::LEADING),
        f,
        "adv:toggle",
        6.0,
    );
    let mut b = vec![left(head)];
    if m.advanced {
        b.push(left(t(cx, "F\u{00FC}r einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse.", 13.0, 400, colour::FONT_VERY_QUIET, 4, swiftly_text::Align::Start)));
        for (i, (name, value)) in m.headers.iter().enumerate() {
            let remove = forms::tappable(
                t(
                    cx,
                    "\u{2212}",
                    18.0,
                    400,
                    colour::FONT_VERY_QUIET,
                    1,
                    swiftly_text::Align::Center,
                )
                .frame(Some(28.0), Some(28.0), Alignment::CENTER),
                f,
                &format!("adv:del:{i}"),
                14.0,
            );
            let row = Node::hstack(
                Align::Center,
                Some(8.0),
                vec![
                    input_row(
                        cx,
                        icons,
                        f,
                        &format!("field:hn{i}"),
                        "key",
                        "Header-Name",
                        name,
                        false,
                        p.field == Field::HName(i),
                        p.edit.as_ref(),
                    )
                    .frame(Some(168.0), None, Alignment::CENTER),
                    input_row(
                        cx,
                        icons,
                        f,
                        &format!("field:hv{i}"),
                        "lock",
                        "Wert",
                        value,
                        true,
                        p.field == Field::HValue(i),
                        p.edit.as_ref(),
                    )
                    .frame(Some(168.0), None, Alignment::CENTER),
                    remove,
                ],
            );
            b.push(row);
        }
        b.push(left(forms::tappable(
            Node::hstack(
                Align::Center,
                Some(6.0),
                vec![
                    icons.node("plus", 12.0, true, color(colour::FONT_QUIET)),
                    t(
                        cx,
                        "Header hinzuf\u{00FC}gen",
                        13.0,
                        400,
                        colour::FONT_QUIET,
                        1,
                        swiftly_text::Align::Start,
                    ),
                ],
            )
            .frame(None, Some(24.0), Alignment::LEADING),
            f,
            "adv:add",
            6.0,
        )));
    }
    Node::vstack(Align::Start, Some(10.0), b)
}

/// `FoundServersSection`: nothing while nothing answered.
fn found(cx: &Cx, icons: &Icons, f: &Fm, p: &Parts) -> Option<Node> {
    if p.mac.found.is_empty() {
        return None;
    }
    let mut b = vec![
        left(t(
            cx,
            "Im Netzwerk gefunden",
            13.0,
            600,
            colour::FONT_VERY_QUIET,
            1,
            swiftly_text::Align::Start,
        ))
        .padding(ins(0.0, 0.0, 8.0, 0.0)),
        hair(),
    ];
    for (i, (name, addr)) in p.mac.found.iter().enumerate() {
        let words = Node::vstack(
            Align::Start,
            Some(2.0),
            vec![
                left(t(
                    cx,
                    name,
                    15.0,
                    600,
                    colour::FONT,
                    1,
                    swiftly_text::Align::Start,
                )),
                left(t(
                    cx,
                    addr,
                    12.0,
                    400,
                    colour::FONT_VERY_QUIET,
                    1,
                    swiftly_text::Align::Start,
                )),
            ],
        );
        let row = Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                dot7(),
                words.frame(None, None, Alignment::LEADING),
                Node::spacer(),
                icons.node("caret-right", 13.0, true, color(colour::FONT)),
            ],
        )
        .padding(ins(14.0, 0.0, 14.0, 0.0));
        b.push(
            forms::tappable(wide(row, Alignment::LEADING), f, &format!("found:{i}"), 0.0)
                .hover_surface(color(colour::PRESSED_AREA), 8.0),
        );
        b.push(hair());
    }
    Some(Node::vstack(Align::Start, Some(0.0), b).padding(ins(32.0, 0.0, 0.0, 0.0)))
}

/// The server address page for Jellyfin and Emby (`ServerView`, `MacEmbySignIn.addressStep`).
fn address_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, p: &Parts, emby: bool) -> Node {
    let empty = p.address.trim().is_empty();
    let mut b = Vec::new();
    if emby {
        b.push(left(kind_mark(icons, Kind::Emby, 34.0, false)).padding(ins(22.0, 0.0, 0.0, 0.0)));
        b.push(
            left(t(
                cx,
                "Wo steht dein Emby-Server?",
                14.0,
                400,
                colour::FONT_QUIET,
                2,
                swiftly_text::Align::Start,
            ))
            .padding(ins(18.0, 0.0, 0.0, 0.0)),
        );
        b.push(
            input_row(
                cx,
                icons,
                f,
                "field:addr",
                "globe",
                "emby.beispiel.de",
                &p.shown(Field::Address),
                false,
                p.field == Field::Address,
                p.edit.as_ref(),
            )
            .padding(ins(14.0, 0.0, 0.0, 0.0)),
        );
        b.push(
            left(t(
                cx,
                "https:// kannst du weglassen.",
                12.0,
                400,
                colour::FONT_VERY_QUIET,
                2,
                swiftly_text::Align::Start,
            ))
            .padding(ins(9.0, 2.0, 0.0, 0.0)),
        );
        b.push(advanced(cx, icons, f, p).padding(ins(8.0, 0.0, 0.0, 0.0)));
        b.push(
            primary(
                cx,
                icons,
                f,
                "connect",
                if p.checking {
                    "Verbinden\u{2026}"
                } else {
                    "Verbinden"
                },
                !empty && !p.checking,
            )
            .padding(ins(22.0, 0.0, 0.0, 0.0)),
        );
        if let Some(e) = &p.error {
            if e == crate::signin_flows::EMBY_DOWN {
                b.push(disturb(cx, icons, f, &p.address, e));
            } else {
                b.push(warn(cx, e));
            }
        }
    } else {
        b.push(
            left(t(
                cx,
                "Wo steht dein Jellyfin-Server?",
                14.0,
                400,
                colour::FONT_QUIET,
                2,
                swiftly_text::Align::Start,
            ))
            .padding(ins(4.0, 0.0, 0.0, 0.0)),
        );
        b.push(
            input_row(
                cx,
                icons,
                f,
                "field:addr",
                "globe",
                "tv.beispiel.de",
                &p.shown(Field::Address),
                false,
                p.field == Field::Address,
                p.edit.as_ref(),
            )
            .padding(ins(24.0, 0.0, 0.0, 0.0)),
        );
        b.push(advanced(cx, icons, f, p).padding(ins(10.0, 0.0, 0.0, 0.0)));
        if let Some(e) = &p.error {
            // `DisturbHint` for a silent server, the plain warning line for every other failure.
            if e == crate::signin_flows::JELLYFIN_DOWN {
                b.push(disturb(cx, icons, f, &p.address, e));
            } else {
                b.push(warn(cx, e));
            }
        }
        b.push(
            primary(
                cx,
                icons,
                f,
                "connect",
                if p.checking {
                    "Verbinden\u{2026}"
                } else {
                    "Verbinden"
                },
                !empty && !p.checking,
            )
            .padding(ins(24.0, 0.0, 0.0, 0.0)),
        );
        if let Some(n) = found(cx, icons, f, p) {
            b.push(n);
        }
    }
    let title = if emby {
        "Emby (Beta)"
    } else {
        "Mit Jellyfin anmelden"
    };
    forms::page(cx, icons, env, f, title, None, b, None)
}

/// `DisturbHint`: "Server ist abgetaucht" with the address and a retry.
fn disturb(cx: &Cx, icons: &Icons, f: &Fm, address: &str, _error: &str) -> Node {
    let b = vec![
        t(
            cx,
            "Server ist abgetaucht",
            17.0,
            600,
            colour::FONT,
            1,
            swiftly_text::Align::Center,
        ),
        t(
            cx,
            &format!(
                "{address} antwortet nicht. L\u{00E4}uft er noch, oder h\u{00E4}ngt das WLAN?"
            ),
            13.0,
            400,
            colour::FONT_QUIET,
            3,
            swiftly_text::Align::Center,
        )
        .padding(ins(6.0, 0.0, 0.0, 0.0)),
        outline(cx, icons, f, "retry", "Erneut versuchen", "arrow-up-right")
            .padding(ins(14.0, 0.0, 0.0, 0.0)),
    ];
    Node::vstack(Align::Center, Some(0.0), b).padding(ins(22.0, 0.0, 0.0, 0.0))
}

fn header_block(cx: &Cx, version_line: &str, name: &str, dot: bool) -> Node {
    let top = if dot {
        Node::hstack(
            Align::Center,
            Some(8.0),
            vec![
                dot7(),
                t(
                    cx,
                    version_line,
                    12.0,
                    400,
                    colour::FONT_VERY_QUIET,
                    1,
                    swiftly_text::Align::Start,
                ),
            ],
        )
    } else {
        t(
            cx,
            version_line,
            13.0,
            400,
            colour::FONT_VERY_QUIET,
            1,
            swiftly_text::Align::Center,
        )
    };
    Node::vstack(
        Align::Start,
        Some(6.0),
        vec![
            top,
            left(t(
                cx,
                name,
                26.0,
                700,
                colour::FONT,
                2,
                swiftly_text::Align::Start,
            )),
        ],
    )
}

/// A round character with the name below (`AccountCharacter`), `selected` ringed in the accent.
fn character(cx: &Cx, f: &Fm, key: &str, name: &str, selected: bool) -> Node {
    let initial: String = name
        .chars()
        .next()
        .map(|c| c.to_uppercase().collect())
        .unwrap_or_default();
    let ring = if selected {
        color(colour::MARK_ACCENT)
    } else {
        color(colour::LINE)
    };
    let face = t(
        cx,
        &initial,
        24.0,
        700,
        colour::FONT,
        1,
        swiftly_text::Align::Center,
    )
    .frame(Some(56.0), Some(56.0), Alignment::CENTER)
    .background(Node::rect(color(colour::RAISED), 28.0), Alignment::CENTER)
    .padding(ins(2.0, 2.0, 2.0, 2.0))
    .background(Node::rect(ring, 30.0), Alignment::CENTER);
    let n = Node::vstack(
        Align::Center,
        Some(8.0),
        vec![
            face,
            t(
                cx,
                name,
                12.0,
                400,
                colour::FONT_QUIET,
                1,
                swiftly_text::Align::Center,
            ),
        ],
    )
    .padding(ins(6.0, 6.0, 6.0, 6.0));
    forms::tappable(n, f, key, 14.0).hover_surface(color(colour::PRESSED_AREA), 14.0)
}

/// `Wer schaut?` with a skeleton while the users load.
fn who(cx: &Cx, f: &Fm, users: &Option<Vec<String>>, picked: &str, key: &str) -> Option<Node> {
    let title = left(t(
        cx,
        "Wer schaut?",
        13.0,
        600,
        colour::FONT_VERY_QUIET,
        1,
        swiftly_text::Align::Start,
    ));
    let row = match users {
        None => Node::hstack(
            Align::Start,
            Some(16.0),
            (0..3)
                .map(|_| {
                    Node::vstack(
                        Align::Center,
                        Some(8.0),
                        vec![skeleton(60.0, 60.0, 30.0), skeleton(48.0, 10.0, 3.0)],
                    )
                })
                .collect(),
        ),
        Some(list) if list.is_empty() => return None,
        Some(list) => Node::hstack(
            Align::Start,
            Some(8.0),
            list.iter()
                .enumerate()
                .map(|(i, n)| character(cx, f, &format!("{key}:{i}"), n, n == picked))
                .collect(),
        ),
    };
    Some(
        Node::vstack(Align::Start, Some(12.0), vec![title, left(row)])
            .padding(ins(22.0, 0.0, 0.0, 0.0)),
    )
}

fn credentials_fields(cx: &Cx, icons: &Icons, f: &Fm, p: &Parts, top: f32) -> Vec<Node> {
    vec![
        input_row(
            cx,
            icons,
            f,
            "field:user",
            "user",
            "Benutzername",
            &p.shown(Field::User),
            false,
            p.field == Field::User,
            p.edit.as_ref(),
        )
        .padding(ins(top, 0.0, 0.0, 0.0)),
        input_row(
            cx,
            icons,
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
    ]
}

/// `SignInView`: the server, user name and password, the "oder" divider and the Quick Connect button.
fn credentials_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, p: &Parts) -> Node {
    let m = &p.mac;
    let mut b = vec![
        left(t(
            cx,
            &m.server_name,
            26.0,
            700,
            colour::FONT,
            2,
            swiftly_text::Align::Start,
        ))
        .padding(ins(10.0, 0.0, 0.0, 0.0)),
        left(t(
            cx,
            &if m.version.is_empty() {
                "Jellyfin".to_owned()
            } else {
                format!("Jellyfin {}", m.version)
            },
            13.0,
            400,
            colour::FONT_VERY_QUIET,
            1,
            swiftly_text::Align::Start,
        ))
        .padding(ins(4.0, 0.0, 0.0, 0.0)),
    ];
    b.extend(credentials_fields(cx, icons, f, p, 28.0));
    if let Some(e) = &p.error {
        b.push(warn(cx, e));
    }
    b.push(
        primary(
            cx,
            icons,
            f,
            "signin",
            if p.checking {
                "Anmelden\u{2026}"
            } else {
                "Anmelden"
            },
            !p.user.is_empty() && !p.checking,
        )
        .padding(ins(24.0, 0.0, 0.0, 0.0)),
    );
    b.push(
        Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                hair(),
                t(
                    cx,
                    "oder",
                    12.0,
                    400,
                    colour::FONT_VERY_QUIET,
                    1,
                    swiftly_text::Align::Center,
                ),
                hair(),
            ],
        )
        .padding(ins(18.0, 0.0, 0.0, 0.0)),
    );
    b.push(
        outline(
            cx,
            icons,
            f,
            "quick",
            "Mit Quick Connect anmelden",
            "television",
        )
        .padding(ins(18.0, 0.0, 0.0, 0.0)),
    );
    if !m.add {
        return signin_centred(cx, icons, f, p);
    }
    forms::page(cx, icons, env, f, "Server hinzuf\u{00FC}gen", None, b, None)
}

/// `SignInView` as the window shows it after the address: the wordmark, the server (28 bold, tracking -0.6) and its
/// version, the fields, "Anmelden", "oder" and Quick Connect, all centred in the window with no page header.
fn signin_centred(cx: &Cx, icons: &Icons, f: &Fm, p: &Parts) -> Node {
    let m = &p.mac;
    let title = swiftly_design::TextStyle {
        tracking: -0.6,
        ..st(28.0, 700)
    };
    let version = if m.version.is_empty() {
        "Jellyfin".to_owned()
    } else {
        format!("Jellyfin {}", m.version)
    };
    let mut b = vec![
        icons.wordmark(44.0, color(colour::FONT), color(colour::MARK_ACCENT)),
        text(
            cx,
            &m.server_name,
            title,
            colour::FONT,
            Some(2),
            swiftly_text::Align::Center,
        )
        .padding(ins(34.0, 0.0, 0.0, 0.0)),
        t(
            cx,
            &version,
            12.0,
            400,
            colour::FONT_VERY_QUIET,
            1,
            swiftly_text::Align::Center,
        )
        .padding(ins(4.0, 0.0, 0.0, 0.0)),
    ];
    b.extend(credentials_fields(cx, icons, f, p, 28.0));
    if let Some(e) = &p.error {
        b.push(warn(cx, e));
    }
    b.push(
        primary(
            cx,
            icons,
            f,
            "signin",
            if p.checking {
                "Anmelden\u{2026}"
            } else {
                "Anmelden"
            },
            !p.user.is_empty() && !p.checking,
        )
        .padding(ins(24.0, 0.0, 0.0, 0.0)),
    );
    b.push(
        Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                hair(),
                t(
                    cx,
                    "oder",
                    12.0,
                    400,
                    colour::FONT_VERY_QUIET,
                    1,
                    swiftly_text::Align::Center,
                ),
                hair(),
            ],
        )
        .padding(ins(18.0, 0.0, 0.0, 0.0)),
    );
    b.push(
        outline(
            cx,
            icons,
            f,
            "quick",
            "Mit Quick Connect anmelden",
            "television",
        )
        .padding(ins(18.0, 0.0, 0.0, 0.0)),
    );
    // The fields and buttons are `formWidth` (420) wide; the heading lines centre over them.
    let col = Node::vstack(Align::Center, Some(0.0), b).frame(Some(f.col), None, Alignment::TOP);
    fill_frame(col, Alignment::CENTER)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
}

/// `QuickConnectCode` inside the window: hint, the code in one copyable box, the countdown, the way back.
fn quick_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, p: &Parts) -> Node {
    let mut b = vec![
        left(t(cx, &p.mac.server_name, 26.0, 700, colour::FONT, 2, swiftly_text::Align::Start)).padding(ins(10.0, 0.0, 0.0, 0.0)),
        left(t(cx, "Gib diesen Code in Jellyfin auf einem Ger\u{00E4}t ein, an dem du schon angemeldet bist.", 13.0, 400, colour::FONT_QUIET, 4, swiftly_text::Align::Start)).padding(ins(26.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(e) = &p.error {
        b.push(
            left(t(
                cx,
                e,
                13.0,
                400,
                colour::ERROR,
                3,
                swiftly_text::Align::Start,
            ))
            .padding(ins(26.0, 0.0, 0.0, 0.0)),
        );
    } else if p.code.is_empty() {
        b.push(left(skeleton(240.0, 64.0, 12.0)).padding(ins(26.0, 0.0, 0.0, 0.0)));
    } else {
        let code = t(
            cx,
            &p.code,
            28.0,
            700,
            colour::FONT,
            1,
            swiftly_text::Align::Center,
        )
        .frame(None, None, Alignment::CENTER);
        let boxed = wide(code.padding(ins(18.0, 0.0, 18.0, 0.0)), Alignment::CENTER)
            .background(Node::rect(color(colour::AREA), 12.0), Alignment::CENTER);
        b.push(forms::tappable(boxed, f, "copy", 12.0).padding(ins(14.0, 0.0, 0.0, 0.0)));
        let line = if p.mac.copied {
            "Code kopiert".to_owned()
        } else {
            format!("L\u{00E4}uft ab in {}:{:02}", p.left / 60, p.left % 60)
        };
        b.push(
            left(tt(
                cx,
                &line,
                13.0,
                400,
                colour::FONT_VERY_QUIET,
                1,
                swiftly_text::Align::Start,
            ))
            .padding(ins(14.0, 0.0, 0.0, 0.0)),
        );
    }
    b.push(
        outline(cx, icons, f, "password", "Lieber Name und Passwort", "user")
            .padding(ins(22.0, 0.0, 0.0, 0.0)),
    );
    forms::page(
        cx,
        icons,
        env,
        f,
        if p.mac.add {
            "Server hinzuf\u{00FC}gen"
        } else {
            "Mit Jellyfin anmelden"
        },
        None,
        b,
        None,
    )
}

/// `MacEmbySignIn.signInStep`.
fn emby_creds_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, p: &Parts) -> Node {
    let m = &p.mac;
    let mut b = vec![
        header_block(
            cx,
            &format!("Verbunden \u{00B7} Emby {}", m.version),
            &m.server_name,
            true,
        )
        .padding(ins(22.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(n) = who(cx, f, &m.users, &p.user, "user") {
        b.push(n);
    }
    let mut form = credentials_fields(cx, icons, f, p, 0.0);
    form.push(
        primary(
            cx,
            icons,
            f,
            "signin",
            if p.checking {
                "Anmelden\u{2026}"
            } else {
                "Anmelden"
            },
            !p.user.is_empty() && !p.checking,
        )
        .padding(ins(10.0, 0.0, 0.0, 0.0)),
    );
    if let Some(e) = &p.error {
        form.push(warn(cx, e));
    }
    b.push(Node::vstack(Align::Start, Some(0.0), form).padding(ins(26.0, 0.0, 0.0, 0.0)));
    forms::page(cx, icons, env, f, "Emby (Beta)", None, b, None)
}

fn step_line(cx: &Cx, n: u8, s: &str) -> Node {
    Node::hstack(
        Align::Start,
        Some(12.0),
        vec![
            t(
                cx,
                &n.to_string(),
                12.0,
                400,
                colour::FONT_VERY_QUIET,
                1,
                swiftly_text::Align::Start,
            )
            .frame(Some(20.0), None, Alignment::LEADING),
            t(
                cx,
                s,
                14.0,
                400,
                colour::FONT_QUIET,
                3,
                swiftly_text::Align::Start,
            ),
        ],
    )
    .padding(ins(12.0, 0.0, 0.0, 0.0))
}

fn plex_intro(cx: &Cx, icons: &Icons, f: &Fm, opening: bool) -> Vec<Node> {
    vec![
        left(kind_mark(icons, Kind::Plex, 34.0, false)).padding(ins(22.0, 0.0, 0.0, 0.0)),
        left(t(cx, "Die Anmeldung l\u{00E4}uft auf der Seite von Plex. Dein Passwort bekommt Swiftly Player nie zu sehen.", 14.0, 400, colour::FONT_QUIET, 4, swiftly_text::Align::Start)).padding(ins(18.0, 0.0, 0.0, 0.0)),
        primary(cx, icons, f, "plexstart", if opening { "Wird ge\u{00F6}ffnet\u{2026}" } else { "Mit Plex anmelden" }, !opening).padding(ins(24.0, 0.0, 0.0, 0.0)),
        Node::vstack(
            Align::Start,
            Some(0.0),
            vec![
                hair(),
                left(t(cx, "So gehts", 15.0, 600, colour::FONT_QUIET, 1, swiftly_text::Align::Start)).padding(ins(18.0, 0.0, 0.0, 0.0)),
                step_line(cx, 1, "Die Seite von Plex geht hier in der App auf"),
                step_line(cx, 2, "Dort anmelden, dann schlie\u{00DF}t sie sich von selbst"),
                step_line(cx, 3, "Server aussuchen, fertig"),
            ],
        )
        .padding(ins(30.0, 0.0, 0.0, 0.0)),
    ]
}

fn plex_waiting(cx: &Cx, icons: &Icons, f: &Fm, p: &Parts) -> Vec<Node> {
    let l = p.mac.plex_left;
    vec![
        left(kind_mark(icons, Kind::Plex, 34.0, false).opacity(0.6, Motion::Instant))
            .padding(ins(22.0, 0.0, 0.0, 0.0)),
        left(t(
            cx,
            "Melde dich auf der Seite von Plex an. Danach gehts hier von selbst weiter.",
            14.0,
            400,
            colour::FONT_QUIET,
            4,
            swiftly_text::Align::Start,
        ))
        .padding(ins(18.0, 0.0, 0.0, 0.0)),
        left(t(
            cx,
            "Kein Fenster zu sehen? Auf plex.tv/link geht es auch, mit diesem Code.",
            13.0,
            400,
            colour::FONT_VERY_QUIET,
            3,
            swiftly_text::Align::Start,
        ))
        .padding(ins(30.0, 0.0, 0.0, 0.0)),
        left(t(
            cx,
            &p.code,
            28.0,
            700,
            colour::FONT,
            1,
            swiftly_text::Align::Start,
        ))
        .padding(ins(12.0, 0.0, 0.0, 0.0)),
        Node::hstack(
            Align::Center,
            Some(9.0),
            vec![
                Node::rect(color(colour::MARK_ACCENT), 4.0).frame(
                    Some(8.0),
                    Some(8.0),
                    Alignment::CENTER,
                ),
                tt(
                    cx,
                    &format!("Warte auf Plex \u{00B7} noch {}:{:02}", l / 60, l % 60),
                    13.0,
                    400,
                    colour::FONT_QUIET,
                    1,
                    swiftly_text::Align::Start,
                ),
            ],
        )
        .padding(ins(22.0, 0.0, 0.0, 0.0)),
        outline(
            cx,
            icons,
            f,
            "plexreopen",
            "Seite noch mal \u{00F6}ffnen",
            "arrow-up-right",
        )
        .padding(ins(22.0, 0.0, 0.0, 0.0)),
    ]
}

fn plex_loading() -> Vec<Node> {
    let faces = Node::hstack(
        Align::Start,
        Some(16.0),
        (0..3)
            .map(|_| {
                Node::vstack(
                    Align::Center,
                    Some(8.0),
                    vec![skeleton(60.0, 60.0, 30.0), skeleton(48.0, 10.0, 3.0)],
                )
            })
            .collect(),
    );
    vec![
        left(faces).padding(ins(22.0, 0.0, 0.0, 0.0)),
        left(skeleton(420.0, 64.0, 14.0)).padding(ins(22.0, 0.0, 0.0, 0.0)),
    ]
}

fn plex_profiles(cx: &Cx, f: &Fm, p: &Parts) -> Vec<Node> {
    let faces = Node::hstack(
        Align::Start,
        Some(8.0),
        p.mac
            .profiles
            .iter()
            .enumerate()
            .map(|(i, (n, _))| character(cx, f, &format!("profile:{i}"), n, false))
            .collect(),
    );
    vec![
        left(faces).padding(ins(22.0, 0.0, 0.0, 0.0)),
        left(t(
            cx,
            "Jedes Profil hat seinen eigenen Fortschritt.",
            13.0,
            400,
            colour::FONT_VERY_QUIET,
            2,
            swiftly_text::Align::Start,
        ))
        .padding(ins(10.0, 0.0, 0.0, 0.0)),
    ]
}

fn plex_pin(cx: &Cx, icons: &Icons, f: &Fm, p: &Parts) -> Vec<Node> {
    let name = p
        .mac
        .profiles
        .get(p.mac.profile)
        .map_or("", |x| x.0.as_str());
    let (line, c) = match p.mac.pin_state {
        PinState::Checking => (Some("Wird gepr\u{00FC}ft\u{2026}"), colour::FONT_QUIET),
        PinState::Wrong => (
            Some("Die PIN passt nicht. Versuchs noch mal."),
            colour::ERROR,
        ),
        PinState::Idle => (None, colour::FONT_QUIET),
    };
    let mut b = vec![
        left(character(cx, f, "noop", name, true)).padding(ins(22.0, 0.0, 0.0, 0.0)),
        left(t(
            cx,
            "Dieses Profil hat eine PIN. Gib sie hier ein.",
            14.0,
            400,
            colour::FONT_QUIET,
            2,
            swiftly_text::Align::Start,
        ))
        .padding(ins(20.0, 0.0, 0.0, 0.0)),
        input_row(
            cx,
            icons,
            f,
            "field:pin",
            "lock",
            "PIN",
            &p.mac.pin,
            true,
            p.field == Field::Pin,
            p.edit.as_ref(),
        )
        .padding(ins(16.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(l) = line {
        b.push(
            left(t(cx, l, 13.0, 400, c, 2, swiftly_text::Align::Start))
                .padding(ins(14.0, 0.0, 0.0, 0.0)),
        );
    }
    b
}

fn plex_servers(cx: &Cx, icons: &Icons, f: &Fm, p: &Parts) -> Vec<Node> {
    let name = p
        .mac
        .profiles
        .get(p.mac.profile)
        .map_or("", |x| x.0.as_str());
    let mut b = vec![
        left(t(
            cx,
            &format!("Als {name}"),
            13.0,
            600,
            colour::FONT_VERY_QUIET,
            1,
            swiftly_text::Align::Start,
        ))
        .padding(ins(22.0, 0.0, 8.0, 0.0)),
        hair(),
    ];
    for (i, (n, d)) in p.mac.servers.iter().enumerate() {
        let words = Node::vstack(
            Align::Start,
            Some(2.0),
            vec![
                left(t(
                    cx,
                    n,
                    15.0,
                    600,
                    colour::FONT,
                    1,
                    swiftly_text::Align::Start,
                )),
                left(t(
                    cx,
                    d,
                    12.0,
                    400,
                    colour::FONT_VERY_QUIET,
                    1,
                    swiftly_text::Align::Start,
                )),
            ],
        );
        let row = Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                dot7(),
                words.frame(None, None, Alignment::LEADING),
                Node::spacer(),
                icons.node("caret-right", 13.0, true, color(colour::FONT)),
            ],
        )
        .padding(ins(14.0, 0.0, 14.0, 0.0));
        b.push(
            forms::tappable(
                wide(row, Alignment::LEADING),
                f,
                &format!("server:{i}"),
                0.0,
            )
            .hover_surface(color(colour::PRESSED_AREA), 8.0),
        );
        b.push(hair());
    }
    b
}

fn plex_failed(cx: &Cx, icons: &Icons, f: &Fm, p: &Parts) -> Vec<Node> {
    let e = p
        .error
        .clone()
        .unwrap_or_else(|| "Die Anmeldung bei Plex hat nicht geklappt.".into());
    vec![
        left(t(
            cx,
            &e,
            14.0,
            400,
            colour::ERROR,
            4,
            swiftly_text::Align::Start,
        ))
        .padding(ins(22.0, 0.0, 0.0, 0.0)),
        outline(
            cx,
            icons,
            f,
            "plexagain",
            "Noch mal versuchen",
            "arrow-up-right",
        )
        .padding(ins(22.0, 0.0, 0.0, 0.0)),
    ]
}

fn plex_page(cx: &Cx, icons: &Icons, env: &Env, f: &Fm, p: &Parts) -> Node {
    let (title, body) = match p.mac.plex {
        PlexStep::Start => ("Mit Plex anmelden", plex_intro(cx, icons, f, false)),
        PlexStep::Opening => ("Mit Plex anmelden", plex_intro(cx, icons, f, true)),
        PlexStep::Waiting => ("Plex (Beta)", plex_waiting(cx, icons, f, p)),
        PlexStep::Failed => ("Plex (Beta)", plex_failed(cx, icons, f, p)),
        PlexStep::Loading => ("Plex", plex_loading()),
        PlexStep::Profiles => ("Plex", plex_profiles(cx, f, p)),
        PlexStep::Pin => ("Plex", plex_pin(cx, icons, f, p)),
        PlexStep::Servers => ("Plex", plex_servers(cx, icons, f, p)),
    };
    forms::page(cx, icons, env, f, title, None, body, None)
}

/// The desktop picture of step `p.step`.
pub(crate) fn view(
    p: &Parts,
    env: &Env,
    cx: &Cx,
    ctx: &Ctx,
    f: &Fm,
    accounts: impl FnOnce() -> Node,
) -> Node {
    let icons = &ctx.icons;
    match p.step {
        Step::Kind => kind_page(cx, icons, env, f, p),
        Step::Address => address_page(cx, icons, env, f, p, false),
        Step::EmbyAddress => address_page(cx, icons, env, f, p, true),
        Step::Credentials => credentials_page(cx, icons, env, f, p),
        Step::EmbyCredentials => emby_creds_page(cx, icons, env, f, p),
        Step::Quick => quick_page(cx, icons, env, f, p),
        Step::Plex => plex_page(cx, icons, env, f, p),
        Step::Accounts => accounts(),
    }
}

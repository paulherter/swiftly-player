//! "Was ist neu" after an update (`WhatsNewSheet.swift`): one card over a scrim in the middle of the window, a version
//! line, the title, three to five lines (symbol, headline, optional detail) and one button. The file, the rules for when
//! it is due and the texts are the core's (`swiftly_l10n::whats_new`); this is only the presentation.
//!
//! The same sheet carries the gift steps of `GiftFlow` (`GiftSheet`): the offer "Ein Look für dich", the short claim
//! animation (a ring runs out and the look's tile lands, transform and opacity only) and, when the file has a gift, the
//! gift card with "Hol ihn dir" on the "Was ist neu" card. Which step shows and the stage changes are the core's
//! (`swiftly_support::gift_flow`); this file draws and reports the taps.

use crate::browse::wide;
use crate::home::{fill_frame, ins, rgba, text};
use swiftly_design::TextStyle;
use swiftly_design::tokens_generated::{color, desktop as dtok};
use swiftly_l10n::whats_new::WhatsNewEntry;
use swiftly_layout::{Align, Alignment};
use swiftly_render::{Color, DrawList};
use swiftly_support::look::Look;
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node, Paint, Ui, UiEvent};

/// The card's width in points.
const CARD_W: f32 = 440.0;

/// One line as drawn: the Lucide asset, the headline and the optional second line, in the UI language.
#[derive(Clone, PartialEq)]
struct Line {
    asset: &'static str,
    title: String,
    detail: Option<String>,
}

/// The step the card is on.
#[derive(Clone, Copy, PartialEq, Default)]
enum Step {
    /// "Was ist neu".
    #[default]
    News,
    /// "Ein Look für dich".
    Offer,
    /// The look is picked up: the short animation.
    Claiming,
}

/// What the main button of "Was ist neu" does (`WhatsNewSheet.primary`).
#[derive(Clone, Copy, PartialEq, Default)]
enum Primary {
    #[default]
    Close,
    /// Picks the card's gift up.
    Grab,
    /// Opens the looks panel.
    OpenLooks,
}

/// What the card draws; empty while it is closed.
#[derive(Clone, PartialEq, Default)]
struct Parts {
    open: bool,
    step: Step,
    version: String,
    title: String,
    lines: Vec<Line>,
    /// The gift the step is about (the card's gift, the offer, the claimed look).
    gift: Option<Look>,
    primary: Primary,
    /// The label of the main button, a catalogue key.
    primary_label: &'static str,
    /// Reduce Motion: no ring, the tile is simply there.
    still: bool,
}

/// What a tap on the sheet asked of the host besides closing it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SheetTap {
    /// "Hol ihn dir": pick this gift up.
    Grab(Look),
    /// "Look ausprobieren": open the looks panel.
    OpenLooks,
    /// A tap on the claim animation: straight to its end.
    Skip,
}

/// The height of the offer and of the claim step, so the card does not jump between them (`offerHeight`).
const GIFT_H: f32 = 400.0;

/// The Lucide asset for an SF Symbol name of a shipped file (`IconMap.swift`); `sparkle` for one this app does not know.
fn asset(symbol: &str) -> &'static str {
    match symbol {
        "paintpalette" => "palette",
        "app" => "app-window",
        "arrow.uturn.backward" => "arrow-u-up-left",
        "gift" => "gift",
        "plus.circle" => "plus-circle",
        "play.rectangle" => "monitor-play",
        "line.3.horizontal.decrease" => "funnel",
        "trash" => "trash",
        _ => "sparkle",
    }
}

fn st(size: f32, weight: u16) -> TextStyle {
    TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

fn row(cx: &Cx, icons: &Icons, l: &Line) -> Node {
    let mut texts = vec![wide(
        text(
            cx,
            &l.title,
            st(15.0, 600),
            color::TEXT_PRIMARY,
            Some(2),
            swiftly_text::Align::Start,
        ),
        Alignment::LEADING,
    )];
    if let Some(d) = &l.detail {
        texts.push(wide(
            text(
                cx,
                d,
                st(13.0, 400),
                color::TEXT_TERTIARY,
                Some(3),
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        ));
    }
    let label = match &l.detail {
        Some(d) => format!("{}. {d}", l.title),
        None => l.title.clone(),
    };
    Node::hstack(
        Align::Center,
        Some(14.0),
        vec![
            icons
                .node(l.asset, 19.0, true, color(color::TEXT_PRIMARY))
                .frame(Some(28.0), Some(28.0), Alignment::CENTER)
                .a11y_hidden(),
            wide(
                Node::vstack(Align::Start, Some(3.0), texts),
                Alignment::LEADING,
            ),
        ],
    )
    .a11y(swiftly_ui::a11y::A11yNode::new(
        "",
        swiftly_ui::a11y::Role::Text,
        label,
    ))
}

/// A look's tile and name on a card row, the gift of "Was ist neu".
fn gift_card(cx: &Cx, look: &Look) -> Node {
    let name = swiftly_l10n::t(look.name_key);
    let note = swiftly_l10n::t("Geschenk, bleibt für immer in deiner Sammlung");
    let line = |s: &str, size: f32, weight: u16, c, lines| {
        wide(
            text(
                cx,
                s,
                st(size, weight),
                c,
                Some(lines),
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        )
    };
    Node::hstack(
        Align::Center,
        Some(14.0),
        vec![
            crate::looks_panel::tile(look, 44.0),
            wide(
                Node::vstack(
                    Align::Start,
                    Some(2.0),
                    vec![
                        line(&name, 15.0, 600, color::TEXT_PRIMARY, 1),
                        line(&note, 13.0, 400, color::TEXT_TERTIARY, 2),
                    ],
                ),
                Alignment::LEADING,
            ),
        ],
    )
    .padding(ins(14.0, 14.0, 14.0, 14.0))
    .background(
        Node::rect(color(color::SURFACE_CONTROL), 12.0),
        Alignment::CENTER,
    )
    .a11y(swiftly_ui::a11y::A11yNode::new(
        "",
        swiftly_ui::a11y::Role::Text,
        format!("{name}. {note}"),
    ))
}

/// A wide button: the light one is the main button, the quiet one "Nicht jetzt".
fn button(cx: &Cx, label: &str, key: &'static str, main: bool) -> Node {
    wide(
        text(
            cx,
            label,
            st(17.0, 600),
            if main {
                color::SURFACE_BASE
            } else {
                color::TEXT_PRIMARY
            },
            Some(1),
            swiftly_text::Align::Center,
        ),
        Alignment::CENTER,
    )
    .frame(None, Some(48.0), Alignment::CENTER)
    .background(
        Node::rect(
            color(if main {
                color::TEXT_PRIMARY
            } else {
                color::SURFACE_CONTROL
            }),
            10.0,
        ),
        Alignment::CENTER,
    )
    .hover_surface(
        if main {
            Color::new(0.0, 0.0, 0.0, 0.12)
        } else {
            Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA)
        },
        10.0,
    )
    .a11y(swiftly_ui::a11y::A11yNode::new(
        "",
        swiftly_ui::a11y::Role::Button,
        label,
    ))
    .key(key)
    .on_tap(Action::from(key))
}

/// The X in the corner of a card.
fn x_button(icons: &Icons) -> Node {
    icons
        .node("x", 12.0, true, color(color::TEXT_SECONDARY))
        .frame(Some(28.0), Some(28.0), Alignment::CENTER)
        .hover_surface(
            Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
            8.0,
        )
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Button,
            swiftly_l10n::t("Schließen"),
        ))
        .key("wn:x")
        .on_tap(Action::from("wn:x"))
}

/// The card on its scrim, in the middle of the window.
fn on_scrim(card: Node, env: &Env) -> Node {
    let card = card
        .background(
            Node::rect(color(color::SURFACE_RAISED), 16.0).paint(Paint::Stroke {
                color: color(color::SURFACE_FOCUS),
                width: 1.0,
                radius: dtok::RADIUS_BUTTON,
            }),
            Alignment::CENTER,
        )
        .appear_from(0.97, 0.0)
        .exit_to(0.97, 0.0)
        .opacity(1.0, swiftly_ui::feel::leap())
        .key("wn:card");
    let scrim = Node::rect(rgba(color::SURFACE_BASE, 0.62), 0.0)
        .opacity(1.0, swiftly_ui::feel::leap())
        .key("wn:scrim");
    Node::zstack(
        Alignment::CENTER,
        vec![
            fill_frame(scrim, Alignment::CENTER),
            fill_frame(card, Alignment::CENTER),
        ],
    )
    .frame(Some(env.size.w), Some(env.size.h), Alignment::CENTER)
    .key("wn:panel")
}

/// "Ein Look für dich" (`GiftOffer`): the look's tile, thanks, the promise, "Hol ihn dir" and "Nicht jetzt".
fn offer(p: &Parts, env: &Env, cx: &Cx, icons: &Icons) -> Node {
    let Some(look) = p.gift else {
        return fill_frame(Node::spacer(), Alignment::CENTER);
    };
    let title = swiftly_l10n::t("Ein Look für dich 🎃");
    let thanks = swiftly_l10n::t_args(
        "Danke, dass du Swiftly benutzt. %@ ist ein Geschenk an alle.",
        &[swiftly_l10n::Arg::Str(swiftly_l10n::t(look.name_key))],
    );
    let promise = swiftly_l10n::t("Bleibt für immer in deiner Sammlung.");
    let line = |s: &str, size: f32, weight: u16, c, lines| {
        wide(
            text(
                cx,
                s,
                st(size, weight),
                c,
                Some(lines),
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        )
    };
    let inner = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            wide(crate::looks_panel::tile(&look, 76.0), Alignment::LEADING),
            line(&title, 24.0, 600, color::TEXT_PRIMARY, 2)
                .a11y(swiftly_ui::a11y::A11yNode::new(
                    "",
                    swiftly_ui::a11y::Role::Heading,
                    &title,
                ))
                .padding(ins(20.0, 0.0, 0.0, 0.0)),
            line(&thanks, 15.0, 400, color::TEXT_SECONDARY, 4).padding(ins(8.0, 0.0, 0.0, 0.0)),
            line(&promise, 13.0, 400, color::TEXT_TERTIARY, 2).padding(ins(6.0, 0.0, 0.0, 0.0)),
            Node::spacer(),
            button(cx, &swiftly_l10n::t("Hol ihn dir"), "wn:grab", true),
            button(cx, &swiftly_l10n::t("Nicht jetzt"), "wn:later", false)
                .padding(ins(10.0, 0.0, 0.0, 0.0)),
        ],
    )
    .padding(ins(36.0, 28.0, 28.0, 28.0))
    .frame(Some(CARD_W), Some(GIFT_H), Alignment::TOP_LEADING);
    on_scrim(
        Node::zstack(
            Alignment::TOP_TRAILING,
            vec![inner, x_button(icons).padding(ins(26.0, 28.0, 0.0, 0.0))],
        ),
        env,
    )
}

/// The pick-up (`GiftClaiming`): a thin ring runs out in the look's accent while its tile lands, 0.9 s; transform and
/// opacity only. A tap goes straight to the end.
fn claiming(p: &Parts, env: &Env) -> Node {
    let Some(look) = p.gift else {
        return fill_frame(Node::spacer(), Alignment::CENTER);
    };
    let ring_motion = swiftly_ui::Motion::of(swiftly_motion::catalogue::Id::SupportRing);
    let accent = look.accent.main;
    let ring = Node::spacer()
        .frame(Some(120.0), Some(120.0), Alignment::CENTER)
        .background(
            Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 60.0).paint(Paint::Stroke {
                color: Color::new(
                    accent.red() as f32,
                    accent.green() as f32,
                    accent.blue() as f32,
                    1.0,
                ),
                width: 1.5,
                radius: 60.0,
            }),
            Alignment::CENTER,
        )
        .scaled(1.9, ring_motion)
        .opacity(0.0, ring_motion)
        .appear_from(0.8, 0.8)
        .key("wn:ring");
    let tile = crate::looks_panel::tile(&look, 114.0)
        .scaled(1.0, swiftly_ui::feel::land())
        .appear_from(0.67, 0.0)
        .key("wn:tile");
    let name = swiftly_l10n::t_args(
        "%@ gehört dir.",
        &[swiftly_l10n::Arg::Str(swiftly_l10n::t(look.name_key))],
    );
    let body = Node::zstack(
        Alignment::CENTER,
        if p.still {
            vec![tile]
        } else {
            vec![ring, tile]
        },
    )
    .frame(Some(CARD_W), Some(GIFT_H), Alignment::CENTER)
    .key("wn:skip")
    .on_tap(Action::from("wn:skip"))
    .a11y(swiftly_ui::a11y::A11yNode::new(
        "",
        swiftly_ui::a11y::Role::Button,
        name,
    ));
    on_scrim(body, env)
}

fn view(p: &Parts, env: &Env, cx: &Cx, icons: &Icons) -> Node {
    if !p.open {
        return fill_frame(
            Node::vstack(Align::Start, Some(0.0), vec![]),
            Alignment::CENTER,
        );
    }
    match p.step {
        Step::Offer => return offer(p, env, cx, icons),
        Step::Claiming => return claiming(p, env),
        Step::News => {}
    }
    let version = swiftly_l10n::t_args(
        "Neu in Version %@",
        &[swiftly_l10n::Arg::Str(p.version.clone())],
    );
    let head = Node::hstack(
        Align::Start,
        Some(8.0),
        vec![
            wide(
                text(
                    cx,
                    &version,
                    st(13.0, 600),
                    color::TEXT_TERTIARY,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                Alignment::LEADING,
            ),
            x_button(icons),
        ],
    );
    let title = wide(
        text(
            cx,
            &p.title,
            st(28.0, 700),
            color::TEXT_PRIMARY,
            Some(3),
            swiftly_text::Align::Start,
        ),
        Alignment::LEADING,
    )
    .a11y(swiftly_ui::a11y::A11yNode::new(
        "",
        swiftly_ui::a11y::Role::Heading,
        &p.title,
    ));
    let rows = Node::vstack(
        Align::Start,
        Some(20.0),
        p.lines.iter().map(|l| row(cx, icons, l)).collect(),
    );
    let mut parts = vec![
        head,
        title.padding(ins(6.0, 0.0, 0.0, 0.0)),
        rows.padding(ins(26.0, 0.0, 0.0, 0.0)),
    ];
    if let Some(look) = &p.gift {
        parts.push(gift_card(cx, look).padding(ins(24.0, 0.0, 0.0, 0.0)));
    }
    parts.push(
        button(cx, &swiftly_l10n::t(p.primary_label), "wn:ok", true)
            .padding(ins(28.0, 0.0, 0.0, 0.0)),
    );
    if p.gift.is_some() {
        parts.push(
            button(cx, &swiftly_l10n::t("Nicht jetzt"), "wn:later", false)
                .padding(ins(10.0, 0.0, 0.0, 0.0)),
        );
    }
    on_scrim(
        Node::vstack(Align::Start, Some(0.0), parts)
            .padding(ins(26.0, 28.0, 28.0, 28.0))
            .frame(Some(CARD_W), None, Alignment::TOP_LEADING),
        env,
    )
}

/// The sheet: open or closed, it takes every click and key while it is open.
pub struct WhatsNewSheet {
    ui: Ui<Parts>,
    parts: Parts,
    closed: bool,
    tap: Option<SheetTap>,
}

impl WhatsNewSheet {
    /// A closed sheet for a window of `env`.
    pub fn new(env: Env, cx: Cx) -> WhatsNewSheet {
        let icons = Icons::new(&cx, env.scale);
        let parts = Parts::default();
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &icons),
            parts.clone(),
            env,
            cx,
        );
        WhatsNewSheet {
            ui,
            parts,
            closed: false,
            tap: None,
        }
    }

    /// A new window size.
    pub fn set_env(&mut self, env: Env) {
        self.parts.still = env.reduce_motion;
        self.ui.set_env(env);
    }

    /// Whether the sheet is up (it takes every click and key).
    pub fn open(&self) -> bool {
        self.parts.open
    }

    /// Shows `entry` in `language` (`de`, `en`, `ru`: the files carry German and English only). `gift` is the look the
    /// card can still hand out (the core says so: in its window, not owned yet).
    pub fn show(&mut self, entry: &WhatsNewEntry, language: &str, gift: Option<Look>) {
        // Without the gift (window over, or picked up already) "Hol ihn dir" has nothing to do (`primaryTitle`).
        let label = if gift.is_none() && entry.primary.label == "grab" {
            "continue"
        } else {
            entry.primary.label.as_str()
        };
        let (primary_label, primary) = match label {
            "grab" => ("Hol ihn dir", Primary::Grab),
            "try" if entry.primary.action == "open:looks" => ("Ausprobieren", Primary::OpenLooks),
            "tryLook" if entry.primary.action == "open:looks" => {
                ("Look ausprobieren", Primary::OpenLooks)
            }
            "try" => ("Ausprobieren", Primary::Close),
            "tryLook" => ("Look ausprobieren", Primary::Close),
            _ => ("Verstanden", Primary::Close),
        };
        let primary = if primary == Primary::Grab && !entry.primary.action.starts_with("applyLook:")
        {
            Primary::Close
        } else {
            primary
        };
        self.parts = Parts {
            open: true,
            step: Step::News,
            version: entry.version.clone(),
            title: entry.title.localized(language).to_owned(),
            lines: entry
                .items
                .iter()
                .map(|i| Line {
                    asset: asset(&i.symbol),
                    title: i.title.localized(language).to_owned(),
                    detail: i.detail.as_ref().map(|d| d.localized(language).to_owned()),
                })
                .collect(),
            gift,
            primary,
            primary_label,
            still: self.parts.still,
        };
        self.closed = false;
        self.ui.set_parts(self.parts.clone());
    }

    /// Shows the offer "Ein Look für dich" (`GiftOffer`).
    pub fn show_offer(&mut self, look: Look) {
        self.show_step(Step::Offer, look);
    }

    /// Shows the pick-up animation (`GiftClaiming`).
    pub fn show_claiming(&mut self, look: Look) {
        self.show_step(Step::Claiming, look);
    }

    fn show_step(&mut self, step: Step, look: Look) {
        self.parts = Parts {
            open: true,
            step,
            gift: Some(look),
            still: self.parts.still,
            ..Parts::default()
        };
        self.closed = false;
        self.ui.set_parts(self.parts.clone());
    }

    /// Closes the sheet (Escape, X, "Verstanden" or "Nicht jetzt").
    pub fn close(&mut self) {
        if self.parts.open {
            self.parts.open = false;
            self.closed = true;
            self.ui.set_parts(self.parts.clone());
        }
    }

    /// Whether the sheet was closed since the last call (once).
    pub fn take_closed(&mut self) -> bool {
        std::mem::take(&mut self.closed)
    }

    /// What a tap asked of the host besides closing (once).
    pub fn take_tap(&mut self) -> Option<SheetTap> {
        self.tap.take()
    }

    /// Return on the sheet: the main button.
    pub fn enter(&mut self) {
        match self.parts.step {
            Step::News => self.main_button(),
            Step::Offer => {
                if let Some(look) = self.parts.gift {
                    self.tap = Some(SheetTap::Grab(look));
                }
            }
            Step::Claiming => self.tap = Some(SheetTap::Skip),
        }
    }

    fn main_button(&mut self) {
        match (self.parts.primary, self.parts.gift) {
            (Primary::Grab, Some(look)) => self.tap = Some(SheetTap::Grab(look)),
            (Primary::OpenLooks, _) => {
                self.tap = Some(SheetTap::OpenLooks);
                self.close();
            }
            _ => self.close(),
        }
    }

    fn drain(&mut self) {
        for ev in self.ui.take_events() {
            let UiEvent::Tap(a) = ev else { continue };
            if a == Action::from("wn:x") || a == Action::from("wn:later") {
                self.close();
            } else if a == Action::from("wn:ok") {
                self.main_button();
            } else if a == Action::from("wn:grab") {
                if let Some(look) = self.parts.gift {
                    self.tap = Some(SheetTap::Grab(look));
                }
            } else if a == Action::from("wn:skip") {
                self.tap = Some(SheetTap::Skip);
            }
        }
    }

    /// A press.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_down(x, y, now);
        self.drain();
    }

    /// The pointer moves while pressed.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_move(x, y, now);
        self.ui.pointer_move(x, y, now);
    }

    /// The press ends.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_up(x, y, now);
        self.drain();
    }

    /// The pointer moves without a button.
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.pointer_move(x, y, now);
    }

    /// One frame; the second value asks for another.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        let list = self.ui.frame(now);
        self.drain();
        (list, self.ui.needs_frame())
    }

    /// The accessibility nodes of the open sheet.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }
}

#[cfg(test)]
mod tests {
    use super::asset;

    /// Every symbol the shipped files use draws its own icon, not the `sparkle` fallback.
    #[test]
    fn shipped_symbols_have_their_own_icon() {
        for version in ["1.0.8", "1.1.0"] {
            let entry = swiftly_l10n::whats_new::bundled(version).expect("file ships");
            for item in &entry.items {
                let name = asset(&item.symbol);
                assert!(
                    name != "sparkle" || item.symbol.starts_with("sparkle"),
                    "{version}: no icon for {}",
                    item.symbol
                );
                assert!(
                    swiftly_ui::icons::path_data(name).is_some(),
                    "{version}: icon {name} is not in the set"
                );
            }
        }
    }
}

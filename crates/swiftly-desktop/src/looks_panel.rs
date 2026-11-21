//! The looks panel over the real Start page (`LooksPanel`, `Sources/Shared/LookGiftSheet.swift:601-800`) and the preview
//! bar (`LookPreviewBar`): one row of looks, the glow, the season switch, "App-Icon zum Look" and the accent, then
//! "Verwenden". A look this person may wear is stored at once; any other one (a supporter look) is only tried on: the page
//! under the panel takes its glow, nothing is stored, and the preview bar takes the panel's place.
//!
//! What may be worn, what the preview does and what is stored is the core's `LookStore`; this file only draws it and maps
//! taps to its calls. The supporter state is read from the key keeper's `SupportStore`.

use std::sync::Arc;

use swiftly_design::tokens_generated::color;
use swiftly_layout::{Align, Alignment};
use swiftly_render::{Color, DrawList, LinearGradient};
use swiftly_settings::JsonFileStore;
use swiftly_support::look::{Look, LookAccent, LookColor, LookGlow, LookSelection};
use swiftly_support::look_store::LookStore;
use swiftly_support::season::LookSeason;
use swiftly_support::support::SupportStore;
use swiftly_support::time::Calendar;
use swiftly_ui::components::color;
use swiftly_ui::{Action, Cx, Env, Node, Paint, Ui};

use crate::detail_screen::{look as style_of, txt, weight, wide};
use crate::home::{fill_frame, ins};
use crate::support_card::Shared;

/// What a tap on the panel or the bar meant.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LookTap {
    /// "Verwenden", the X or Esc: the panel closes.
    Close,
    /// "Unterstützer werden" / "Freischalten": the supporter page opens.
    Support,
    /// Something inside the panel changed (the page under it recolours).
    Changed,
}

/// The glow strengths in the order of the control.
const GLOWS: [(LookGlow, &str); 3] = [
    (LookGlow::Off, "Aus"),
    (LookGlow::Soft, "Sanft"),
    (LookGlow::Bright, "Hell"),
];

/// Everything the view draws.
#[derive(Clone, PartialEq)]
struct Parts {
    open: bool,
    selection: LookSelection,
    wearable: bool,
    supporter: bool,
    previewing: bool,
    /// Every look of the row and whether it is locked for this person.
    looks: Vec<(Look, bool)>,
    effects: bool,
    /// The last day of the season window the shown look is in, as "2 Nov".
    season_end: Option<String>,
}

/// The panel and the bar over the page.
pub struct LooksPanel {
    store: LookStore<Shared>,
    settings: Arc<JsonFileStore>,
    ui: Ui<Parts>,
    open: bool,
}

fn rgb(c: LookColor, a: f32) -> Color {
    Color::new(c.red() as f32, c.green() as f32, c.blue() as f32, a)
}

/// The look's icon as a tile: its page colour with the play mark in its gradient.
pub(crate) fn tile(look: &Look, size: f32) -> Node {
    let mark = look.logo_gradient;
    let (first, last) = (
        mark.first().copied().unwrap_or(look.accent.main),
        mark.last().copied().unwrap_or(look.accent.main),
    );
    let inner = Node::spacer()
        .frame(Some(size * 0.46), Some(size * 0.46), Alignment::CENTER)
        .paint(Paint::Linear {
            gradient: LinearGradient::horizontal(rgb(first, 1.0), rgb(last, 1.0)),
            radius: size * 0.23,
        });
    inner
        .frame(Some(size), Some(size), Alignment::CENTER)
        .background(
            Node::rect(rgb(look.background, 1.0), size * 0.24),
            Alignment::CENTER,
        )
        .background(
            Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), size * 0.24).paint(Paint::Stroke {
                color: color(color::SURFACE_FOCUS),
                width: 1.0,
                radius: size * 0.24,
            }),
            Alignment::CENTER,
        )
}

/// "2. Nov." for the last day of a season: the core's one day-and-month reader (catalogue month names), in the UI language.
pub(crate) fn season_end(season: &LookSeason, now: f64, calendar: Calendar) -> String {
    let _ = (now, calendar);
    let month = season.to.month.clamp(1, 12);
    let t = swiftly_l10n::Translator::new(swiftly_l10n::current_locale());
    swiftly_vm::short_date(&t, &format!("2026-{month:02}-{:02}", season.to.day))
}

/// The clock of the season windows. `SWIFTLY_LOOK_DATE` (unix seconds) stands in for it in the proof runs, like the
/// Mac's `-lookDate`.
pub(crate) fn now_seconds() -> f64 {
    if let Some(t) = std::env::var("SWIFTLY_LOOK_DATE")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
    {
        return t;
    }
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn tappable(n: Node, key: &str) -> Node {
    n.key(key).on_tap(Action::from(key))
}

fn view(p: &Parts, env: &Env, cx: &Cx, icons: &swiftly_ui::icons::Icons) -> Node {
    if !p.open {
        return fill_frame(Node::spacer(), Alignment::BOTTOM);
    }
    let lk = style_of(env);
    let t = |s: &str, size: f32, w: u16, c: swiftly_design::types::Colour| {
        txt(cx, s, weight(lk.body, size, w), c, Some(1))
    };
    let look = p.selection.look();
    let palette = p.selection.palette();
    let button = |title: &str, key: &str, w: f32| {
        tappable(
            t(title, 16.0, 600, color::SURFACE_BASE)
                .frame(Some(w), Some(44.0), Alignment::CENTER)
                .background(
                    Node::rect(color(color::TEXT_PRIMARY), 22.0),
                    Alignment::CENTER,
                )
                .hover_surface(Color::new(0.0, 0.0, 0.0, 0.12), 22.0),
            key,
        )
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Button,
            title,
        ))
    };
    let card = |inner: Node, w: f32, key: &str| {
        inner
            .frame(Some(w), None, Alignment::TOP_LEADING)
            .background(
                Node::rect(color(color::SURFACE_RAISED), 20.0).paint(Paint::Stroke {
                    color: color(color::SURFACE_FOCUS),
                    width: 1.0,
                    radius: 20.0,
                }),
                Alignment::CENTER,
            )
            .key(key)
            .appear_from(0.97, 0.0)
            .exit_to(0.97, 0.0)
    };

    // The preview bar: icon, name, "Vorschau", chevrons and "Freischalten".
    if p.previewing {
        let chevron = |name: &str, key: &str, label: &str| {
            tappable(
                icons
                    .node(name, 14.0, true, color(color::TEXT_SECONDARY))
                    .frame(Some(32.0), Some(44.0), Alignment::CENTER)
                    .hover_surface(
                        Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
                        8.0,
                    )
                    .a11y(swiftly_ui::a11y::A11yNode::new(
                        "",
                        swiftly_ui::a11y::Role::Button,
                        label,
                    )),
                key,
            )
        };
        let row = Node::hstack(
            Align::Center,
            Some(8.0),
            vec![
                chevron("caret-left", "look-prev", swiftly_l10n::tr("Voriger Look")),
                tile(&look, 40.0),
                Node::vstack(
                    Align::Start,
                    Some(0.0),
                    vec![
                        t(look.name_key, 15.0, 600, color::TEXT_PRIMARY),
                        t(
                            swiftly_l10n::tr("Vorschau"),
                            12.0,
                            400,
                            color::TEXT_TERTIARY,
                        ),
                    ],
                )
                .frame(Some(150.0), None, Alignment::LEADING),
                chevron(
                    "caret-right",
                    "look-next",
                    swiftly_l10n::tr("Nächster Look"),
                ),
                button(swiftly_l10n::tr("Freischalten"), "look-support", 120.0),
            ],
        )
        .padding(ins(8.0, 10.0, 8.0, 12.0));
        let bar = row
            .background(
                Node::rect(color(color::SURFACE_RAISED), 32.0),
                Alignment::CENTER,
            )
            .background(
                Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 32.0).paint(Paint::Stroke {
                    color: color(color::SURFACE_FOCUS),
                    width: 1.0,
                    radius: 32.0,
                }),
                Alignment::CENTER,
            )
            .key("look-bar")
            .appear_from(0.97, 0.0)
            .exit_to(0.97, 0.0);
        return fill_frame(bar.padding(ins(0.0, 0.0, 28.0, 0.0)), Alignment::BOTTOM);
    }

    let heading = Node::hstack(
        Align::Center,
        Some(8.0),
        vec![
            wide(
                t(
                    swiftly_l10n::tr("Wähl deinen Look"),
                    22.0,
                    700,
                    color::TEXT_PRIMARY,
                ),
                Alignment::LEADING,
            ),
            tappable(
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
                        swiftly_l10n::tr("Schlie\u{00DF}en"),
                    )),
                "look-close",
            ),
        ],
    );
    let note = if p.wearable {
        t("", 13.0, 400, color::TEXT_TERTIARY)
    } else {
        Node::hstack(
            Align::Center,
            Some(6.0),
            vec![
                icons.node("lock", 12.0, true, color(color::TEXT_TERTIARY)),
                t(
                    swiftly_l10n::tr("Nur für Unterstützer"),
                    13.0,
                    400,
                    color::TEXT_TERTIARY,
                ),
            ],
        )
    }
    .frame(None, Some(17.0), Alignment::LEADING);

    // One column per look: its tile, a ring when chosen, a lock when not allowed, its name.
    let row: Vec<Node> = p
        .looks
        .iter()
        .map(|(item, locked)| {
            let chosen = *item == look;
            let ring = Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 14.0).paint(Paint::Stroke {
                color: color(color::TEXT_PRIMARY),
                width: 2.0,
                radius: 14.0,
            });
            let mut face = tile(item, 48.0);
            if chosen {
                face =
                    face.background(ring.padding(ins(-4.0, -4.0, -4.0, -4.0)), Alignment::CENTER);
            }
            face = face.padding(ins(5.0, 5.0, 5.0, 5.0));
            if *locked {
                face = face.opacity(0.45, swiftly_ui::feel::leap());
            }
            let mut kids = vec![face];
            if *locked {
                kids[0] = kids[0].clone().background(
                    icons
                        .node("lock", 10.0, true, color(color::TEXT_PRIMARY))
                        .frame(Some(20.0), Some(20.0), Alignment::BOTTOM_TRAILING),
                    Alignment::BOTTOM_TRAILING,
                );
            }
            kids.push(t(
                item.name_key,
                12.0,
                if chosen { 600 } else { 400 },
                if chosen {
                    color::TEXT_PRIMARY
                } else {
                    color::TEXT_SECONDARY
                },
            ));
            tappable(
                Node::vstack(Align::Center, Some(6.0), kids).frame(
                    Some(58.0),
                    None,
                    Alignment::TOP,
                ),
                &format!("look:{}", item.id),
            )
            .a11y(swiftly_ui::a11y::A11yNode::new(
                "",
                swiftly_ui::a11y::Role::Button,
                item.name_key,
            ))
        })
        .collect();
    let strip = Node::hstack(Align::Start, Some(6.0), row).padding(ins(10.0, 0.0, 4.0, 0.0));

    // The settings under the row: the same rows, greyed while the look is only tried on.
    let line = |title: &str, trail: Node, enabled: bool| {
        Node::hstack(
            Align::Center,
            Some(12.0),
            vec![
                wide(t(title, 15.0, 600, color::TEXT_PRIMARY), Alignment::LEADING),
                trail,
            ],
        )
        .padding(ins(0.0, 16.0, 0.0, 16.0))
        .frame(None, Some(52.0), Alignment::LEADING)
        .opacity(if enabled { 1.0 } else { 0.45 }, swiftly_ui::feel::leap())
    };
    let divider = || {
        Node::rect(color(color::BORDER_HAIRLINE), 0.0)
            .frame(None, Some(1.0), Alignment::CENTER)
            .padding(ins(0.0, 16.0, 0.0, 0.0))
    };
    let mut rows: Vec<Node> = Vec::new();
    if let Some(end) = &p.season_end {
        let _ = end;
        rows.push(line(
            swiftly_l10n::tr("Fledermäuse und Spinnennetz"),
            tappable(crate::forms::toggle_switch(p.effects), "look-effects"),
            true,
        ));
        rows.push(divider());
    }
    let glow_pills: Vec<Node> = GLOWS
        .iter()
        .enumerate()
        .map(|(i, (g, name))| {
            let name = swiftly_l10n::tr(name);
            let on = palette.glow == *g;
            tappable(
                t(
                    name,
                    13.0,
                    if on { 600 } else { 400 },
                    if on {
                        color::SURFACE_BASE
                    } else {
                        color::TEXT_SECONDARY
                    },
                )
                .frame(Some(56.0), Some(28.0), Alignment::CENTER)
                .background(
                    Node::rect(
                        if on {
                            color(color::TEXT_PRIMARY)
                        } else {
                            Color::new(0.0, 0.0, 0.0, 0.0)
                        },
                        14.0,
                    ),
                    Alignment::CENTER,
                ),
                &format!("look-glow:{i}"),
            )
            .a11y(swiftly_ui::a11y::A11yNode::new(
                "",
                swiftly_ui::a11y::Role::Button,
                name,
            ))
        })
        .collect();
    rows.push(line(
        swiftly_l10n::tr("Startseiten-Schein"),
        Node::hstack(Align::Center, Some(2.0), glow_pills)
            .padding(ins(2.0, 2.0, 2.0, 2.0))
            .background(
                Node::rect(color(color::SURFACE_CONTROL), 16.0),
                Alignment::CENTER,
            ),
        p.wearable,
    ));
    rows.push(divider());
    let has_icon = look.icon_name.is_some();
    rows.push(line(
        swiftly_l10n::tr("App-Icon zum Look"),
        tappable(
            crate::forms::toggle_switch(has_icon && p.selection.uses_look_icon != Some(false)),
            "look-icon",
        ),
        p.wearable && has_icon,
    ));
    rows.push(divider());
    let accent_trail = if p.supporter {
        Node::hstack(
            Align::Center,
            Some(8.0),
            LookAccent::ALL
                .iter()
                .map(|a| {
                    let on = palette.accent.id == a.id;
                    tappable(
                        Node::spacer()
                            .frame(Some(20.0), Some(20.0), Alignment::CENTER)
                            .background(Node::rect(rgb(a.main, 1.0), 10.0), Alignment::CENTER)
                            .padding(ins(3.0, 3.0, 3.0, 3.0))
                            .background(
                                Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 13.0).paint(
                                    Paint::Stroke {
                                        color: if on {
                                            color(color::TEXT_PRIMARY)
                                        } else {
                                            Color::new(0.0, 0.0, 0.0, 0.0)
                                        },
                                        width: 2.0,
                                        radius: 13.0,
                                    },
                                ),
                                Alignment::CENTER,
                            ),
                        &format!("look-accent:{}", a.id),
                    )
                })
                .collect(),
        )
    } else {
        tappable(
            t(
                swiftly_l10n::tr("Unterstützer werden"),
                13.0,
                600,
                color::TEXT_PRIMARY,
            )
            .frame(Some(160.0), Some(32.0), Alignment::CENTER)
            .background(
                Node::rect(color(color::SURFACE_CONTROL), 16.0),
                Alignment::CENTER,
            )
            .hover_surface(
                Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
                16.0,
            ),
            "look-support",
        )
    };
    rows.push(line(
        swiftly_l10n::tr("Akzentfarbe"),
        accent_trail,
        p.wearable || !p.supporter,
    ));
    let settings = Node::vstack(Align::Start, Some(0.0), rows).background(
        Node::rect(color(color::SURFACE_CONTROL), 14.0),
        Alignment::CENTER,
    );
    let action = if p.wearable {
        button(swiftly_l10n::tr("Verwenden"), "look-use", 552.0)
    } else {
        button(
            swiftly_l10n::tr("Unterstützer werden"),
            "look-support",
            552.0,
        )
    };
    let body = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            heading,
            note.padding(ins(4.0, 0.0, 0.0, 0.0)),
            strip.padding(ins(8.0, 0.0, 0.0, 0.0)),
            settings
                .opacity(
                    if p.wearable { 1.0 } else { 0.42 },
                    swiftly_ui::feel::leap(),
                )
                .padding(ins(14.0, 0.0, 0.0, 0.0)),
            action.padding(ins(16.0, 0.0, 0.0, 0.0)),
        ],
    )
    .padding(ins(20.0, 24.0, 20.0, 24.0));
    fill_frame(
        card(body, 600.0, "look-panel").padding(ins(0.0, 0.0, 28.0, 0.0)),
        Alignment::BOTTOM,
    )
}

impl LooksPanel {
    /// A panel over the settings file `settings`, for a content area of `env`.
    pub fn new(settings: Arc<JsonFileStore>, env: Env, cx: Cx) -> LooksPanel {
        let store = LookStore::load(Shared(Arc::clone(&settings)));
        let icons = swiftly_ui::icons::Icons::new(&cx, env.scale);
        let mut panel = LooksPanel {
            ui: Ui::new(
                move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &icons),
                Parts {
                    open: false,
                    selection: LookSelection::original(),
                    wearable: true,
                    supporter: false,
                    previewing: false,
                    looks: Vec::new(),
                    effects: true,
                    season_end: None,
                },
                env,
                cx,
            ),
            store,
            settings,
            open: false,
        };
        panel.sync();
        panel
    }

    /// A new content size.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }

    /// The panel or its bar is up.
    pub fn is_open(&self) -> bool {
        self.open
    }

    /// The glow of what the page under the panel shows now (the saved look, or the one being tried on).
    pub fn glow(&self) -> crate::look_glow::Glow {
        crate::look_glow::glow_of(&self.store)
    }

    /// Hands the page under the panel the glow and the accent of what shows now (the saved look or the one tried on).
    pub fn theme(&self) {
        crate::look_glow::apply(&self.store);
    }

    /// Reads the supporter state (the key keeper's `SupportStore`) and the store again, then redraws.
    fn sync(&mut self) {
        let supporter = SupportStore::new(Shared(Arc::clone(&self.settings)))
            .status()
            .is_supporter();
        let _ = self.store.set_supporter(supporter);
        let (now, calendar) = (now_seconds(), Calendar::UTC);
        let selection = self.store.selection();
        let looks = self
            .store
            .picker_looks(now, calendar)
            .into_iter()
            .map(|l| {
                let allowed = self.store.state().may_wear(&LookSelection::of(l.id))
                    || (l.is_gift && !self.store.state().owned().contains(l.id));
                (l, !allowed)
            })
            .collect();
        let season_end = selection
            .look()
            .availability
            .filter(|s| s.is_active(now, calendar))
            .map(|s| season_end(&s, now, calendar));
        let parts = Parts {
            open: self.open,
            wearable: self.store.state().may_wear(&selection),
            supporter,
            previewing: self.store.state().is_previewing(),
            looks,
            effects: self.store.effects_on(),
            season_end,
            selection,
        };
        self.ui.set_parts(parts);
    }

    /// Opens the panel on the saved look (`GiftFlow.openLooks`).
    pub fn open(&mut self) {
        self.store = LookStore::load(Shared(Arc::clone(&self.settings)));
        self.open = true;
        self.sync();
    }

    /// Closes it; a look only tried on is dropped.
    pub fn close(&mut self) {
        let _ = self.store.end_preview();
        self.open = false;
        self.sync();
    }

    /// The look `step` places along the picker, round the end; gifts not picked up are skipped (`LookPreviewBar.move`).
    fn step(&mut self, step: i64) {
        let (now, calendar) = (now_seconds(), Calendar::UTC);
        let looks: Vec<Look> = self
            .store
            .picker_looks(now, calendar)
            .into_iter()
            .filter(|l| !(l.is_gift && !self.store.state().owned().contains(l.id)))
            .collect();
        let current = self.store.selection().look();
        let Some(i) = looks.iter().position(|l| *l == current) else {
            return;
        };
        if looks.len() < 2 {
            return;
        }
        let n = looks.len() as i64;
        let next = looks[((i as i64 + step).rem_euclid(n)) as usize];
        self.apply(self.store.selection().switching(&next));
    }

    /// Live: what may be worn is stored, anything else is a preview (`LooksPanel.apply`).
    fn apply(&mut self, next: LookSelection) {
        if self.store.state().may_wear(&next) {
            let _ = self.store.end_preview();
            let _ = self.store.choose(next);
        } else {
            if !self.store.state().is_previewing() {
                let _ = self.store.begin_preview();
            }
            let _ = self.store.try_on(next);
        }
    }

    /// Runs a tap on `key`; what the host has to do next, if anything.
    pub fn tap(&mut self, key: &str) -> Option<LookTap> {
        let selection = self.store.selection();
        let look = selection.look();
        let out = if let Some(id) = key.strip_prefix("look:") {
            let item = Look::with_id(id);
            if item == look {
                return None;
            }
            // A gift not picked up yet: picking it here picks it up.
            if item.is_gift && !self.store.state().owned().contains(item.id) {
                let _ = self.store.claim(&item);
            } else {
                self.apply(selection.switching(&item));
            }
            Some(LookTap::Changed)
        } else if let Some(i) = key
            .strip_prefix("look-glow:")
            .and_then(|s| s.parse::<usize>().ok())
        {
            let mut next = selection;
            let glow = GLOWS.get(i)?.0;
            next.glow = (glow != look.default_glow).then_some(glow);
            self.apply(next);
            Some(LookTap::Changed)
        } else if let Some(id) = key.strip_prefix("look-accent:") {
            let accent = LookAccent::with_id(id)?;
            let mut next = selection;
            next.accent_id = (accent != look.accent).then(|| accent.id.to_owned());
            self.apply(next);
            Some(LookTap::Changed)
        } else {
            match key {
                "look-effects" => {
                    let _ = self.store.set_effects_on(!self.store.effects_on());
                    Some(LookTap::Changed)
                }
                "look-icon" if look.icon_name.is_some() => {
                    let mut next = selection.clone();
                    next.uses_look_icon = if selection.uses_look_icon == Some(false) {
                        None
                    } else {
                        Some(false)
                    };
                    self.apply(next);
                    Some(LookTap::Changed)
                }
                "look-prev" => {
                    self.step(-1);
                    Some(LookTap::Changed)
                }
                "look-next" => {
                    self.step(1);
                    Some(LookTap::Changed)
                }
                "look-support" => Some(LookTap::Support),
                "look-use" | "look-close" => {
                    self.close();
                    return Some(LookTap::Close);
                }
                _ => None,
            }
        };
        self.sync();
        out
    }

    /// The key of what lies at `(x, y)` (content points), if the panel or bar is open.
    pub fn hit(&self, x: f32, y: f32) -> Option<String> {
        if !self.open {
            return None;
        }
        let inside = |f: [f32; 4]| x >= f[0] && x <= f[0] + f[2] && y >= f[1] && y <= f[1] + f[3];
        let mut best: Option<(String, f32)> = None;
        for look in Look::ALL {
            let key = format!("look:{}", look.id);
            if self.ui.frame_of(key.as_str()).is_some_and(inside) {
                best = Some((key, 0.0));
            }
        }
        if let Some((k, _)) = best {
            return Some(k);
        }
        let mut keys: Vec<String> = [
            "look-close",
            "look-use",
            "look-support",
            "look-prev",
            "look-next",
            "look-effects",
            "look-icon",
        ]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
        keys.extend((0..GLOWS.len()).map(|i| format!("look-glow:{i}")));
        keys.extend(
            LookAccent::ALL
                .iter()
                .map(|a| format!("look-accent:{}", a.id)),
        );
        keys.into_iter()
            .find(|k| self.ui.frame_of(k.as_str()).is_some_and(inside))
    }

    /// Whether `(x, y)` is on the panel or the bar (it swallows the click).
    pub fn hits(&self, x: f32, y: f32) -> bool {
        self.open
            && ["look-panel", "look-bar"].iter().any(|k| {
                self.ui
                    .frame_of(*k)
                    .is_some_and(|f| x >= f[0] && x <= f[0] + f[2] && y >= f[1] && y <= f[1] + f[3])
            })
    }

    /// The reading list of the panel or the bar, in content points (the host shifts it past the sidebar).
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        if self.open {
            self.ui.a11y_nodes()
        } else {
            Vec::new()
        }
    }

    /// The panel over the page at `now`, and whether it still wants frames.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        let list = self.ui.frame(now);
        (list, self.ui.needs_frame())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_layout::Size as Sz;
    use swiftly_ui::Idiom;

    fn panel(name: &str) -> (LooksPanel, crate::testdir::TestDir) {
        let dir = crate::testdir::TestDir::new(&format!("swiftly-looks-{name}"));
        let settings = Arc::new(JsonFileStore::open(dir.join("s.json")).expect("store"));
        let env = Env::new(Sz::new(1000.0, 800.0), 2.0, Idiom::Desktop);
        (LooksPanel::new(settings, env, Cx::default()), dir)
    }

    #[test]
    fn a_look_a_non_supporter_may_not_wear_is_only_tried_on() {
        let (mut p, _dir) = panel("preview");
        p.open();
        let _ = p.frame(0.0);
        let before = p.glow();
        let locked = Look::ALL
            .iter()
            .find(|l| !l.is_gift && **l != Look::ORIGINAL)
            .expect("a supporter look");
        assert_eq!(
            p.tap(&format!("look:{}", locked.id)),
            Some(LookTap::Changed)
        );
        assert!(
            p.store.state().is_previewing(),
            "the bar takes the panel's place"
        );
        assert_ne!(
            p.store.selection().look(),
            Look::ORIGINAL,
            "the page shows it"
        );
        // Nothing stored: a fresh load still has the original.
        let fresh = LookStore::load(Shared(Arc::clone(&p.settings)));
        assert_eq!(fresh.selection().look(), Look::ORIGINAL);
        // Closing drops the preview and brings the original glow back.
        assert_eq!(p.tap("look-close"), Some(LookTap::Close));
        assert!(!p.is_open());
        assert_eq!(p.glow(), before);
    }

    #[test]
    fn the_preview_bar_steps_round_the_row() {
        let (mut p, _dir) = panel("step");
        p.open();
        p.tap("look-next");
        let first = p.store.selection().look();
        assert_ne!(first, Look::ORIGINAL);
        p.tap("look-prev");
        assert_eq!(p.store.selection().look(), Look::ORIGINAL);
        p.tap("look-prev");
        assert_ne!(p.store.selection().look(), Look::ORIGINAL, "round the end");
    }

    #[test]
    fn the_glow_choice_of_the_original_is_stored_and_can_be_taken_back() {
        let (mut p, _dir) = panel("glow");
        p.open();
        p.tap("look-glow:2");
        assert_eq!(p.glow().strength, 320);
        let fresh = LookStore::load(Shared(Arc::clone(&p.settings)));
        assert_eq!(fresh.selection().palette().glow, LookGlow::Bright);
        p.tap("look-glow:0");
        assert!(!p.glow().visible());
    }

    #[test]
    fn every_control_is_hit_at_its_centre() {
        let (mut p, _dir) = panel("hit");
        p.open();
        let _ = p.frame(0.0);
        let _ = p.frame(1000.0);
        let mut keys: Vec<String> = ["look-close", "look-use", "look-effects", "look-icon"]
            .iter()
            .map(|s| (*s).to_owned())
            .collect();
        keys.extend((0..GLOWS.len()).map(|i| format!("look-glow:{i}")));
        keys.extend(Look::ALL.iter().map(|l| format!("look:{}", l.id)));
        for key in keys {
            let Some(f) = p.ui.frame_of(key.as_str()) else {
                eprintln!("no frame for {key}");
                continue;
            };
            eprintln!("{key}: {f:?}");
            assert_eq!(
                p.hit(f[0] + f[2] / 2.0, f[1] + f[3] / 2.0).as_deref(),
                Some(key.as_str()),
                "{key}"
            );
        }
        let nodes = p.a11y_nodes();
        let labels: Vec<&str> = nodes.iter().map(|n| n.label.as_str()).collect();
        for want in ["Aus", "Sanft", "Hell", "Verwenden", "Schlie\u{00DF}en"] {
            assert!(labels.contains(&want), "{want} in {labels:?}");
        }
    }
}

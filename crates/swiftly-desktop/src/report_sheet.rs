//! "Problem melden" (the Mac's `ReportIssueSheet`): one card over a scrim in the middle of the window with the four
//! kinds, a few words and "Melden", then "Gemeldet. Danke." The state, the rules (a few words are needed, one send,
//! a late answer is ignored), the place and every text are the core's (`swiftly_vm::SeerrReportFlow`); this is only
//! the presentation plus the keyboard of the one text field.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use crate::browse::wide;
use crate::home::{fill_frame, ins, rgba, text};
use crate::seerr_desk::Desk;
use swiftly_design::TextStyle;
use swiftly_design::tokens_generated::{color, desktop as dtok};
use swiftly_layout::{Align, Alignment};
use swiftly_render::{Color, DrawList};
use swiftly_seerr::issues::IssueKind;
use swiftly_ui::components::color;
use swiftly_ui::field::{FieldLook, FieldState, FieldView};
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node, Paint, Ui, UiEvent};
use swiftly_vm::{ReportInfo, ReportPhase, SeerrPlace, SeerrReportFlow};

type Flow = SeerrReportFlow<crate::seerr_link::Shared, swiftly_seerr::NoCookies>;

/// The card's width in points.
pub(crate) const CARD_W: f32 = 440.0;

pub(crate) fn held<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What the card draws; compared by value so the view re-runs only when something changed (the blink included).
#[derive(Clone, PartialEq)]
struct Parts {
    info: Option<ReportInfo>,
    field: Option<FieldView>,
}

pub(crate) fn st(size: f32, weight: u16) -> TextStyle {
    TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

const KINDS: [IssueKind; 4] = [
    IssueKind::Video,
    IssueKind::Audio,
    IssueKind::Subtitles,
    IssueKind::Other,
];

pub(crate) fn rule() -> Node {
    wide(
        Node::rect(color(color::SURFACE_FOCUS), 0.0).frame(None, Some(1.0), Alignment::CENTER),
        Alignment::CENTER,
    )
}

pub(crate) fn button(cx: &Cx, label: &str, key: &str, tone: swiftly_design::Colour) -> Node {
    wide(
        text(
            cx,
            label,
            st(15.0, 600),
            tone,
            Some(1),
            swiftly_text::Align::Center,
        ),
        Alignment::CENTER,
    )
    .frame(None, Some(48.0), Alignment::CENTER)
    .hover_surface(
        Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
        0.0,
    )
    .a11y(swiftly_ui::a11y::A11yNode::new(
        "",
        swiftly_ui::a11y::Role::Button,
        label,
    ))
    .key(key)
    .on_tap(Action::from(key))
}

fn view(p: &Parts, env: &Env, cx: &Cx, icons: &Icons) -> Node {
    let (Some(info), Some(fv)) = (&p.info, &p.field) else {
        return fill_frame(
            Node::vstack(Align::Start, Some(0.0), vec![]),
            Alignment::CENTER,
        );
    };
    let accent = crate::look_glow::accent();
    let mut kids: Vec<Node> = vec![
        wide(
            text(
                cx,
                &info.heading,
                st(13.0, 600),
                color::TEXT_TERTIARY,
                Some(1),
                swiftly_text::Align::Start,
            ),
            Alignment::LEADING,
        )
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Heading,
            &info.heading,
        ))
        .padding(ins(0.0, 24.0, 8.0, 24.0)),
        {
            let mut lines = vec![wide(
                text(
                    cx,
                    &info.title,
                    st(15.0, 600),
                    color::TEXT_PRIMARY,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                Alignment::LEADING,
            )];
            if let Some(l) = &info.line {
                lines.push(wide(
                    text(
                        cx,
                        l,
                        st(13.0, 400),
                        color::TEXT_SECONDARY,
                        Some(1),
                        swiftly_text::Align::Start,
                    ),
                    Alignment::LEADING,
                ));
            }
            Node::vstack(Align::Start, Some(2.0), lines).padding(ins(0.0, 24.0, 10.0, 24.0))
        },
    ];
    if info.phase == ReportPhase::Sent {
        kids.push(
            Node::hstack(
                Align::Center,
                Some(10.0),
                vec![
                    icons
                        .node("check-circle", 18.0, true, color(accent))
                        .a11y_hidden(),
                    wide(
                        text(
                            cx,
                            &info.sent_text,
                            st(15.0, 400),
                            color::TEXT_PRIMARY,
                            Some(2),
                            swiftly_text::Align::Start,
                        ),
                        Alignment::LEADING,
                    ),
                ],
            )
            .padding(ins(0.0, 24.0, 0.0, 24.0))
            .frame(None, Some(48.0), Alignment::LEADING)
            .a11y(swiftly_ui::a11y::A11yNode::new(
                "report-sent",
                swiftly_ui::a11y::Role::Text,
                &info.sent_text,
            )),
        );
        kids.push(rule());
        kids.push(button(cx, &info.done_text, "rp:done", accent));
    } else {
        for (i, row) in info.kinds.iter().enumerate() {
            let mut cells = vec![wide(
                text(
                    cx,
                    &row.text,
                    st(15.0, 400),
                    color::TEXT_PRIMARY,
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                Alignment::LEADING,
            )];
            if row.selected {
                cells.push(icons.node("check", 14.0, true, color(accent)).a11y_hidden());
            }
            let key = format!("rp:kind:{i}");
            kids.push(
                Node::hstack(Align::Center, Some(8.0), cells)
                    .padding(ins(0.0, 24.0, 0.0, 24.0))
                    .frame(None, Some(46.0), Alignment::LEADING)
                    .hover_surface(
                        Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
                        0.0,
                    )
                    .a11y(swiftly_ui::a11y::A11yNode::new(
                        format!("report-kind-{i}"),
                        swiftly_ui::a11y::Role::Button,
                        &row.text,
                    ))
                    .key(key.as_str())
                    .on_tap(Action::from(key.as_str())),
            );
        }
        let look = FieldLook {
            style: swiftly_text::TextStyle::from(st(15.0, 400)),
            text: color(color::TEXT_PRIMARY),
            placeholder: color(color::TEXT_TERTIARY),
            caret: color(accent),
            selection: color(accent).with_alpha(0.30),
            caret_height: Some(18.0),
        };
        kids.push(
            Node::hstack(
                Align::Center,
                Some(0.0),
                vec![
                    swiftly_ui::field::field_content(cx, fv, &look),
                    Node::spacer(),
                ],
            )
            .padding(ins(11.0, 14.0, 11.0, 14.0))
            .background(
                Node::rect(color(color::SURFACE_CONTROL), 12.0),
                Alignment::CENTER,
            )
            .key("rp:field")
            .on_tap(Action::from("rp:field"))
            .a11y(swiftly_ui::a11y::A11yNode::new(
                "report-message",
                swiftly_ui::a11y::Role::TextField,
                &info.placeholder,
            ))
            .padding(ins(10.0, 24.0, 10.0, 24.0)),
        );
        if let ReportPhase::Failed(why) = &info.phase {
            kids.push(
                wide(
                    text(
                        cx,
                        why,
                        st(13.0, 400),
                        color::STATE_WARNING,
                        Some(4),
                        swiftly_text::Align::Start,
                    ),
                    Alignment::LEADING,
                )
                .padding(ins(0.0, 24.0, 10.0, 24.0))
                .a11y(swiftly_ui::a11y::A11yNode::new(
                    "report-error",
                    swiftly_ui::a11y::Role::Text,
                    why,
                )),
            );
        }
        kids.push(rule());
        let tone = if info.can_send {
            accent
        } else {
            color::TEXT_TERTIARY
        };
        kids.push(button(cx, &info.send_label, "rp:send", tone));
        kids.push(rule());
        kids.push(button(
            cx,
            &info.cancel_text,
            "rp:cancel",
            color::TEXT_SECONDARY,
        ));
    }
    let card = Node::vstack(Align::Start, Some(0.0), kids)
        .padding(ins(22.0, 0.0, 0.0, 0.0))
        .frame(Some(CARD_W), None, Alignment::TOP_LEADING)
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
        .key("rp:card");
    let scrim = Node::rect(rgba(color::SURFACE_BASE, 0.62), 0.0)
        .opacity(1.0, swiftly_ui::feel::leap())
        .key("rp:scrim");
    Node::zstack(
        Alignment::CENTER,
        vec![
            fill_frame(scrim, Alignment::CENTER),
            fill_frame(card, Alignment::CENTER),
        ],
    )
    .frame(Some(env.size.w), Some(env.size.h), Alignment::CENTER)
    .key("rp:panel")
}

/// A report on its way to being opened: the place is read from the server on the network runtime.
type Pending = Arc<Mutex<Option<Option<SeerrPlace>>>>;

/// The sheet: closed or open, it takes every click and key while it is open.
pub struct ReportSheet {
    ui: Ui<Parts>,
    flow: Option<Arc<Flow>>,
    desk: Option<Desk>,
    field: FieldState,
    parts: Parts,
    pending: Option<Pending>,
    now: f64,
}

impl ReportSheet {
    /// A closed sheet for a window of `env`.
    pub fn new(env: Env, cx: Cx) -> ReportSheet {
        let icons = Icons::new(&cx, env.scale);
        let parts = Parts {
            info: None,
            field: None,
        };
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &icons),
            parts.clone(),
            env,
            cx,
        );
        ReportSheet {
            ui,
            flow: None,
            desk: None,
            field: FieldState::new(swiftly_text::TextEditor::single_line()),
            parts,
            pending: None,
            now: 0.0,
        }
    }

    /// A new window size.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }

    /// Whether the sheet is up (it takes every click and key).
    pub fn open(&self) -> bool {
        self.parts.info.is_some()
    }

    /// Whether a place is being read for a report that is about to open.
    pub fn opening(&self) -> bool {
        self.pending.is_some()
    }

    /// The sheet's field has the keyboard.
    pub fn wants_text(&self) -> bool {
        self.open() && self.field.focused && self.phase_editable()
    }

    fn phase_editable(&self) -> bool {
        self.flow.as_ref().is_some_and(|f| {
            matches!(
                f.info().phase,
                ReportPhase::Editing | ReportPhase::Failed(_)
            )
        })
    }

    /// Reads the place of library item `item_id` (the player's position for a film or an episode) and opens the sheet on
    /// it when it has a TMDB id. The read runs on the network runtime; [`ReportSheet::poll`] picks the answer up.
    pub fn begin(
        &mut self,
        desk: &Desk,
        core: &Arc<crate::live::Core>,
        account: &swiftly_vm::AccountRef,
        item_id: &str,
        seconds: Option<f64>,
    ) {
        if self.open() || self.pending.is_some() {
            return;
        }
        let Ok(client) = core.client_for(account) else {
            return;
        };
        let slot: Pending = Arc::new(Mutex::new(None));
        let out = Arc::clone(&slot);
        let id = item_id.to_owned();
        self.desk = Some(desk.clone());
        desk.run(async move {
            let place = swiftly_vm::place_of_item(&client, &id, seconds).await;
            *held(&out) = Some(place);
        });
        self.pending = Some(slot);
    }

    /// Opens the sheet when the place came in (once per request); call every frame.
    pub fn poll(&mut self, now: f64) {
        self.now = now;
        let Some(slot) = &self.pending else { return };
        let Some(place) = held(slot).take() else {
            return;
        };
        self.pending = None;
        let (Some(desk), Some(place)) = (self.desk.clone(), place) else {
            return;
        };
        let flow = Flow::new(Arc::clone(desk.admin()), swiftly_l10n::current_locale());
        flow.start(place);
        self.field = FieldState::new(swiftly_text::TextEditor::single_line());
        // The words are the one thing to do: the field has the keyboard at once.
        self.field.set_focused(true, now);
        self.flow = Some(flow);
        self.sync();
    }

    /// Closes the sheet (Escape, "Abbrechen", "Fertig").
    pub fn close(&mut self) {
        if let Some(flow) = self.flow.take() {
            flow.close();
        }
        self.field.set_focused(false, self.now);
        self.parts = Parts {
            info: None,
            field: None,
        };
        self.ui.set_parts(self.parts.clone());
    }

    /// Pulls the core's state and the field into what is drawn.
    fn sync(&mut self) {
        let Some(flow) = &self.flow else { return };
        let info = flow.info();
        let placeholder = info.placeholder.clone();
        let parts = Parts {
            field: Some(self.field.view(&placeholder, false, self.now)),
            info: Some(info),
        };
        if parts != self.parts {
            self.parts = parts;
            self.ui.set_parts(self.parts.clone());
        }
    }

    fn send(&mut self) {
        let (Some(flow), Some(desk)) = (self.flow.clone(), self.desk.clone()) else {
            return;
        };
        if !flow.info().can_send {
            return;
        }
        self.field.set_focused(false, self.now);
        // `send` marks the phase at once (`Sending`), so the next sync draws "Wird gemeldet …".
        desk.run(async move {
            let _ = flow.send().await;
        });
    }

    fn drain(&mut self) {
        for ev in self.ui.take_events() {
            let UiEvent::Tap(a) = ev else { continue };
            let is = |s: &str| a == Action::from(s);
            if is("rp:cancel") || is("rp:done") {
                self.close();
                return;
            }
            if is("rp:send") {
                self.send();
            } else if is("rp:field") {
                self.field.set_focused(true, self.now);
            } else if let Some(flow) = &self.flow {
                for (i, kind) in KINDS.into_iter().enumerate() {
                    if is(&format!("rp:kind:{i}")) {
                        flow.set_kind(kind);
                    }
                }
            }
        }
        self.sync();
    }

    /// A press.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.now = now;
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
        self.now = now;
        self.ui.touch_up(x, y, now);
        self.drain();
    }

    /// The pointer moves without a button.
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.pointer_move(x, y, now);
    }

    /// Escape: the sheet goes (a send on its way finishes without it).
    pub fn escape(&mut self) {
        self.close();
    }

    /// Return: sends when the kinds and words allow, closes once it is sent.
    pub fn enter(&mut self) {
        let sent = self
            .flow
            .as_ref()
            .is_some_and(|f| f.info().phase == ReportPhase::Sent);
        if sent {
            self.close();
        } else {
            self.send();
            self.sync();
        }
    }

    /// One text-input event for the field; returns whether it took it. Return sends.
    pub fn text_event(&mut self, ev: &swiftly_text::TextInputEvent) -> bool {
        if !self.wants_text() {
            return false;
        }
        let mut clip = crate::field_book::SystemClipboard;
        let out = self.field.apply(ev, &mut clip, self.now);
        if let Some(flow) = &self.flow {
            flow.set_message(self.field.editor.text());
        }
        if out.submitted {
            self.send();
        }
        self.sync();
        true
    }

    /// One frame; the second value asks for another (a blinking caret, a send on its way, an animation).
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.now = now;
        self.sync();
        let list = self.ui.frame(now);
        self.drain();
        let busy = self.field.focused
            || self.pending.is_some()
            || self
                .flow
                .as_ref()
                .is_some_and(|f| f.info().phase == ReportPhase::Sending);
        (list, busy || self.ui.needs_frame())
    }

    /// The accessibility nodes of the open sheet.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// The kind chosen and the words written (tests).
    #[doc(hidden)]
    pub fn state(&self) -> Option<ReportInfo> {
        self.flow.as_ref().map(|f| f.info())
    }
}

//! "Vom Server löschen" (the Mac's `DeleteFlowSheet`): one card over a scrim like "Problem melden". Confirm lists the
//! versions to delete (tick, size) with "Löschen"; then the core's steps (files, Seerr, library, check) each with its
//! state; a step that hangs says why and "Nochmal versuchen" resumes there. The state, the steps, the rules (one
//! version at least, the device's delete lock, resume at the failed step) and every text of the flow are the core's
//! (`swiftly_vm::SeerrDeleteScreen`); this is the presentation plus the click and key routing.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::browse::wide;
use crate::home::{fill_frame, ins, rgba, text};
use crate::player_glyphs::Glyphs;
use crate::report_sheet::{CARD_W, button, held, rule, st};
use crate::seerr_desk::Desk;
use swiftly_design::tokens_generated::{color, desktop as dtok};
use swiftly_layout::{Align, Alignment};
use swiftly_render::{Color, DrawList};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node, Paint, Ui, UiEvent};
use swiftly_vm::{DeleteLibrary, DeletePhase, SeerrDeleteInfo, SeerrDeleteScreen, StepState};

type Screen = SeerrDeleteScreen<crate::seerr_link::Shared, swiftly_seerr::NoCookies>;

/// One turn of the loader in milliseconds (the Mac's `Components.swift:104`), 12 steps.
const TURN_MS: f64 = 700.0;

/// What the card draws; compared by value so the view re-runs only when something changed.
#[derive(Clone, PartialEq)]
struct Parts {
    info: Option<SeerrDeleteInfo>,
    /// The loader's step (0..12) while a step runs.
    tick: u8,
}

fn view(p: &Parts, env: &Env, cx: &Cx, icons: &Icons, glyphs: &Glyphs) -> Node {
    let Some(info) = &p.info else {
        return fill_frame(
            Node::vstack(Align::Start, Some(0.0), vec![]),
            Alignment::CENTER,
        );
    };
    let accent = crate::look_glow::accent();
    let line = |s: &str, style, tone, lines| {
        wide(
            text(cx, s, style, tone, Some(lines), swiftly_text::Align::Start),
            Alignment::LEADING,
        )
    };
    let heading = if info.phase == DeletePhase::Confirm {
        swiftly_l10n::t("Vom Server löschen")
    } else {
        info.headline.clone().unwrap_or_else(|| info.title.clone())
    };
    let mut kids: Vec<Node> = vec![
        line(&heading, st(13.0, 600), color::TEXT_TERTIARY, 1)
            .a11y(swiftly_ui::a11y::A11yNode::new(
                "",
                swiftly_ui::a11y::Role::Heading,
                &heading,
            ))
            .padding(ins(0.0, 24.0, 8.0, 24.0)),
    ];
    if info.phase == DeletePhase::Confirm {
        kids.push(
            line(&info.title, st(15.0, 600), color::TEXT_PRIMARY, 2)
                .padding(ins(0.0, 24.0, 0.0, 24.0)),
        );
        kids.push(
            line(
                &swiftly_l10n::t("Die Dateien werden gelöscht. Das lässt sich nicht zurücknehmen."),
                st(13.0, 400),
                color::TEXT_SECONDARY,
                3,
            )
            .padding(ins(4.0, 24.0, 10.0, 24.0)),
        );
        for v in &info.versions {
            let key = format!("dl:ver:{}", u8::from(v.is4k));
            let mut cells = vec![
                icons
                    .node(
                        if v.chosen {
                            "check-square.fill"
                        } else {
                            "square"
                        },
                        17.0,
                        true,
                        color(if v.chosen {
                            accent
                        } else {
                            color::TEXT_TERTIARY
                        }),
                    )
                    .a11y_hidden(),
                line(&v.label, st(15.0, 400), color::TEXT_PRIMARY, 1),
            ];
            if let Some(size) = &v.size {
                cells.push(text(
                    cx,
                    size,
                    st(13.0, 400),
                    color::TEXT_TERTIARY,
                    Some(1),
                    swiftly_text::Align::End,
                ));
            }
            kids.push(
                Node::hstack(Align::Center, Some(10.0), cells)
                    .padding(ins(0.0, 24.0, 0.0, 24.0))
                    .frame(None, Some(50.0), Alignment::LEADING)
                    .hover_surface(
                        Color::new(1.0, 1.0, 1.0, swiftly_ui::feel::HOVER_SURFACE_ALPHA),
                        0.0,
                    )
                    .a11y(swiftly_ui::a11y::A11yNode::new(
                        format!("delete-version-{}", v.label),
                        swiftly_ui::a11y::Role::Button,
                        &v.label,
                    ))
                    .key(key.as_str())
                    .on_tap(Action::from(key.as_str())),
            );
        }
        kids.push(rule());
        let any = info.versions.iter().any(|v| v.chosen);
        let (tone, key) = if any {
            (color::STATE_WARNING, "dl:run")
        } else {
            (color::TEXT_TERTIARY, "dl:none")
        };
        kids.push(button(cx, &swiftly_l10n::t("Löschen"), key, tone));
        kids.push(rule());
        kids.push(button(
            cx,
            &swiftly_l10n::t("Abbrechen"),
            "dl:close",
            color::TEXT_SECONDARY,
        ));
    } else {
        for (i, step) in info.steps.iter().enumerate() {
            let mark = match step.state {
                StepState::Done => icons.node("check-circle.fill", 19.0, true, color(accent)),
                StepState::Running => glyphs.arc(p.tick, 19.0, color(accent)),
                StepState::Failed => {
                    icons.node("warning.fill", 18.0, true, color(color::STATE_WARNING))
                }
                StepState::Pending => icons.node("circle", 17.0, true, color(color::TEXT_TERTIARY)),
            };
            let tone = if step.state == StepState::Pending {
                color::TEXT_TERTIARY
            } else {
                color::TEXT_PRIMARY
            };
            let word = match step.state {
                StepState::Done => "done",
                StepState::Running => "running",
                StepState::Failed => "failed",
                StepState::Pending => "pending",
            };
            kids.push(
                Node::hstack(
                    Align::Center,
                    Some(12.0),
                    vec![
                        mark.frame(Some(22.0), Some(22.0), Alignment::CENTER)
                            .a11y_hidden(),
                        line(&step.label, st(15.0, 400), tone, 1),
                    ],
                )
                .padding(ins(0.0, 24.0, 0.0, 24.0))
                .frame(None, Some(46.0), Alignment::LEADING)
                .a11y(swiftly_ui::a11y::A11yNode::new(
                    format!("delete-step-{i}-{word}"),
                    swiftly_ui::a11y::Role::Text,
                    &step.label,
                )),
            );
        }
        if let Some(error) = &info.error {
            kids.push(
                line(error, st(13.0, 400), color::STATE_WARNING, 4)
                    .padding(ins(10.0, 24.0, 10.0, 24.0))
                    .a11y(swiftly_ui::a11y::A11yNode::new(
                        "delete-error",
                        swiftly_ui::a11y::Role::Text,
                        error,
                    )),
            );
        }
        if info.phase != DeletePhase::Running {
            kids.push(rule());
            if info.can_retry {
                kids.push(button(
                    cx,
                    &swiftly_l10n::t("Nochmal versuchen"),
                    "dl:retry",
                    accent,
                ));
                kids.push(rule());
            }
            kids.push(button(
                cx,
                &swiftly_l10n::t("Schließen"),
                "dl:close",
                color::TEXT_SECONDARY,
            ));
        }
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
        .key("dl:card");
    let scrim = Node::rect(rgba(color::SURFACE_BASE, 0.62), 0.0)
        .opacity(1.0, swiftly_ui::feel::leap())
        .key("dl:scrim");
    Node::zstack(
        Alignment::CENTER,
        vec![
            fill_frame(scrim, Alignment::CENTER),
            fill_frame(card, Alignment::CENTER),
        ],
    )
    .frame(Some(env.size.w), Some(env.size.h), Alignment::CENTER)
    .key("dl:panel")
}

/// What reading the title for the sheet found.
enum Prepared {
    /// The title has no TMDB id (or cannot be read).
    NoTmdb,
    /// Seerr does not know it (or this account / device may not delete).
    Unknown,
    /// The sheet is ready.
    Ready(Arc<Screen>),
}

type Pending = Arc<Mutex<Option<Prepared>>>;

/// The host's media server for the steps "Jellyfin liest neu ein" and "Prüfen": this account's library.
fn library_of(
    core: &Arc<crate::live::Core>,
    account: &swiftly_vm::AccountRef,
) -> Option<DeleteLibrary> {
    let client = Arc::new(core.client_for(account).ok()?);
    let (a, b) = (Arc::clone(&client), client);
    Some(DeleteLibrary {
        find: Arc::new(move |art: String, tmdb: i64| {
            let c = Arc::clone(&a);
            Box::pin(async move {
                let kind = if art == "tv" { "Series" } else { "Movie" };
                c.item_id_by_tmdb(tmdb, kind).await.ok().flatten()
            })
        }),
        refresh: Arc::new(move || {
            let c = Arc::clone(&b);
            Box::pin(async move { c.scan_libraries().await.is_ok() })
        }),
        pause: Arc::new(|d: Duration| Box::pin(tokio::time::sleep(d))),
    })
}

/// The sheet: closed or open, it takes every click and key while it is open.
pub struct DeleteSheet {
    ui: Ui<Parts>,
    screen: Option<Arc<Screen>>,
    desk: Option<Desk>,
    parts: Parts,
    pending: Option<Pending>,
    /// The title page behind goes back when the sheet closes after "done" (the Mac's `finished`).
    back_when_done: bool,
    /// Set when the sheet was closed on a finished delete that asked for the page to go back.
    went: bool,
    now: f64,
    notes: Vec<String>,
}

impl DeleteSheet {
    /// A closed sheet for a window of `env`.
    pub fn new(env: Env, cx: Cx) -> DeleteSheet {
        let icons = Icons::new(&cx, env.scale);
        let glyphs = Glyphs::new(&cx, env.scale);
        let parts = Parts {
            info: None,
            tick: 0,
        };
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &icons, &glyphs),
            parts.clone(),
            env,
            cx,
        );
        DeleteSheet {
            ui,
            screen: None,
            desk: None,
            parts,
            pending: None,
            back_when_done: false,
            went: false,
            now: 0.0,
            notes: Vec::new(),
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

    /// Whether the title is being read for a sheet that is about to open.
    pub fn opening(&self) -> bool {
        self.pending.is_some()
    }

    /// Reads library item `item_id` (its TMDB id and file size, then the versions Seerr knows) and opens the confirm
    /// sheet on it. `back` says the title page behind goes back once the delete is done.
    pub fn begin(
        &mut self,
        desk: &Desk,
        core: &Arc<crate::live::Core>,
        account: &swiftly_vm::AccountRef,
        item_id: &str,
        back: bool,
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
        let language = swiftly_l10n::current_locale().language().to_owned();
        let screen = SeerrDeleteScreen::new(Arc::clone(desk.hub()), library_of(core, account));
        self.desk = Some(desk.clone());
        self.back_when_done = back;
        desk.run(async move {
            let found = swiftly_vm::delete_place_of_item(&client, &id, &language).await;
            let answer = match found {
                None => Prepared::NoTmdb,
                Some((place, size)) => {
                    match screen
                        .prepare(place.art, place.tmdb, place.title, size, None)
                        .await
                    {
                        Some(_) => Prepared::Ready(screen),
                        None => Prepared::Unknown,
                    }
                }
            };
            *held(&out) = Some(answer);
        });
        self.pending = Some(slot);
    }

    /// Opens the sheet when the answer came in (once per request); call every frame.
    pub fn poll(&mut self, now: f64) {
        self.now = now;
        let Some(slot) = &self.pending else { return };
        let Some(answer) = held(slot).take() else {
            return;
        };
        self.pending = None;
        match answer {
            Prepared::NoTmdb => self
                .notes
                .push(swiftly_l10n::t("Dieser Titel hat keine TMDB-Nummer.")),
            Prepared::Unknown => self
                .notes
                .push(swiftly_l10n::t("Seerr kennt diesen Titel nicht.")),
            Prepared::Ready(screen) => {
                self.screen = Some(screen);
                self.sync();
            }
        }
    }

    /// A line for the strip at the bottom (the title could not start a delete), once.
    pub fn take_notes(&mut self) -> Vec<String> {
        std::mem::take(&mut self.notes)
    }

    /// The title page behind should go back (the delete is done and the sheet was closed), once.
    pub fn take_went(&mut self) -> bool {
        std::mem::take(&mut self.went)
    }

    /// Closes the sheet (Escape, "Abbrechen", "Schließen"); after a finished delete the page behind goes back.
    pub fn close(&mut self) {
        let done = self
            .screen
            .as_ref()
            .is_some_and(|s| s.info().phase == DeletePhase::Done);
        if let Some(screen) = self.screen.take() {
            screen.close();
        }
        self.went = done && self.back_when_done;
        if done {
            // The title left the library: Start, Library and the lists refetch the next time they are in front.
            crate::desk::note_list_change();
        }
        self.parts = Parts {
            info: None,
            tick: 0,
        };
        self.ui.set_parts(self.parts.clone());
    }

    fn running(&self) -> bool {
        self.parts
            .info
            .as_ref()
            .is_some_and(|i| i.phase == DeletePhase::Running)
    }

    /// Pulls the core's state into what is drawn.
    fn sync(&mut self) {
        let Some(screen) = &self.screen else { return };
        let info = screen.info();
        let tick = if info.phase == DeletePhase::Running {
            ((self.now / (TURN_MS / 12.0)) as u64 % 12) as u8
        } else {
            0
        };
        let parts = Parts {
            info: Some(info),
            tick,
        };
        if parts != self.parts {
            self.parts = parts;
            self.ui.set_parts(self.parts.clone());
        }
    }

    fn run(&mut self) {
        let (Some(screen), Some(desk)) = (self.screen.clone(), self.desk.clone()) else {
            return;
        };
        desk.run(async move {
            let _ = screen.run_chosen().await;
        });
        // The flow marks its first step at once, so the next sync draws the steps.
    }

    fn retry(&mut self) {
        let (Some(screen), Some(desk)) = (self.screen.clone(), self.desk.clone()) else {
            return;
        };
        desk.run(async move {
            let _ = screen.retry().await;
        });
    }

    fn drain(&mut self) {
        for ev in self.ui.take_events() {
            let UiEvent::Tap(a) = ev else { continue };
            let is = |s: &str| a == Action::from(s);
            // While the steps run the sheet cannot be left: the delete is under way.
            if is("dl:close") && !self.running() {
                self.close();
                return;
            }
            if is("dl:run") {
                self.run();
            } else if is("dl:retry") {
                self.retry();
            } else if let Some(screen) = &self.screen {
                for is4k in [false, true] {
                    if is(&format!("dl:ver:{}", u8::from(is4k))) {
                        screen.toggle(is4k);
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

    /// Escape: the confirm sheet goes, so does a finished or failed one; a delete under way stays.
    pub fn escape(&mut self) {
        if !self.running() {
            self.close();
        }
    }

    /// Return: "Löschen" is not the default (nothing is deleted by an accidental key); on a finished sheet it closes.
    pub fn enter(&mut self) {
        let done = self
            .parts
            .info
            .as_ref()
            .is_some_and(|i| i.phase == DeletePhase::Done);
        if done {
            self.close();
        }
    }

    /// One frame; the second value asks for another (the loader, a step under way, an animation).
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.now = now;
        self.sync();
        let list = self.ui.frame(now);
        self.drain();
        (
            list,
            self.running() || self.pending.is_some() || self.ui.needs_frame(),
        )
    }

    /// The accessibility nodes of the open sheet.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// The sheet's state (tests).
    #[doc(hidden)]
    pub fn state(&self) -> Option<SeerrDeleteInfo> {
        self.screen.as_ref().map(|s| s.info())
    }
}

//! The profile hub and the Settings page of the shared Rust UI, drawn from `SettingsVm` sections and rows (switch,
//! choice, info, link, dimmed rows) with the confirm question for turning Downloads off. Differences from the Swift
//! screens are noted in the code.

use crate::browse::{self, SheetRow};
use crate::effects::{self, Effect};
use crate::forms::{self, Fm, Trail};
use crate::home::{Form, ins, text};
use crate::home_choices::{HomeChoices, Offer, ScriptedChoices};
use crate::seerr_link::{ScriptedSeerr, SeerrConn, SeerrLink};
use crate::server_check::{CheckState, ScriptedCheck, ServerCheck};
use crate::settings_pages::{self, HeaderView, SeerrView, SubView};
use crate::update_check::{UpdateCheck, UpdateState};
use std::rc::Rc;
use std::sync::Arc;
use swiftly_design::tokens::colour;
use swiftly_jellyfin::{OwnHeader, OwnHeaders};
use swiftly_l10n::Locale;
use swiftly_layout::{Align, Alignment};
use swiftly_library::StartRail;
use swiftly_library::start_libraries::StartLibrary;
use swiftly_motion::catalogue::Id;
use swiftly_settings::{KeyValueStore, MemoryStore, StoreError, Value};
use swiftly_support::licenses::LicenseData;
use swiftly_support::subtitle::{Colour as SubColour, Outline, Position, Size, SubtitleLook};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node, Ui};
use swiftly_vm::{
    Capabilities, Confirm, Platform, RowControl, SectionsPart, SettingsContext, SettingsIntent,
    SettingsStatusPart, SettingsVm,
};

/// Where a row of the profile hub leads, to be pushed by the app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dest {
    /// The Downloads page.
    Downloads,
    /// The account list (switcher).
    Accounts,
    /// The server address flow.
    AddServer,
    /// Approve the code another device shows (`QuickConnectView`).
    QuickShare,
    /// The Support Swiftly sheet (`SupportModel.open`).
    Support,
    /// Sign the active account out (live app only).
    SignOut,
}

/// The in-memory settings store of the demo.
#[derive(Clone)]
pub struct Mem(Arc<dyn KeyValueStore>);

impl Mem {
    /// The store of the real app (`settings.json`).
    pub fn shared(store: Arc<dyn KeyValueStore>) -> Mem {
        Mem(store)
    }
}
impl KeyValueStore for Mem {
    fn get(&self, key: &str) -> Option<Value> {
        self.0.get(key)
    }
    fn set(&self, key: &str, value: Value) -> Result<(), StoreError> {
        self.0.set(key, value)
    }
    fn remove(&self, key: &str) -> Result<(), StoreError> {
        self.0.remove(key)
    }
    fn keys(&self) -> Vec<String> {
        self.0.keys()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Page {
    Profile,
    /// "Wiedergabe" (`PlaybackSettingsView`).
    Playback,
    /// "Darstellung" (`AppearanceView`).
    Presentation,
    /// "Allgemein" (`SettingsView`).
    Settings,
    /// "Untertitel" (`MacSubtitleLook`), below Wiedergabe.
    SubtitleLook,
    /// "Seerr" (`SeerrSettingsView`), below Allgemein.
    Seerr,
    /// "Open-Source-Lizenzen", below the hub.
    Licences,
    /// One component of the licence list (index into the data).
    Licence(usize),
    /// "Quelltext und Angebot".
    Offering,
    /// "Bibliothek hinzufügen", below Darstellung.
    LibrarySelection,
    /// "Genre hinzufügen", below Darstellung.
    GenreSelection,
}

impl Page {
    /// The page Back leads to.
    fn parent(self) -> Page {
        match self {
            Page::SubtitleLook => Page::Playback,
            Page::Seerr => Page::Settings,
            Page::Licence(_) | Page::Offering => Page::Licences,
            Page::LibrarySelection | Page::GenreSelection => Page::Presentation,
            _ => Page::Profile,
        }
    }
}

impl Page {
    /// The page a section belongs to, by its German heading.
    fn of(title_key: &str) -> Page {
        match title_key {
            "Qualität" | "Sprache" | "Ablauf" | "Im Player" | "Verhalten" => Page::Playback,
            "Filme und Serien" | "Allgemein" | "Startseite" | "Neuzugänge" | "Genres"
            | "Profil" => Page::Presentation,
            _ => Page::Settings,
        }
    }
}

/// The `choice` value that stands for the open "Abmelden" question.
const SIGN_OUT_ASK: &str = "@sign-out";

#[derive(Clone, PartialEq)]
struct Parts {
    sections: Arc<SectionsPart>,
    status: Arc<SettingsStatusPart>,
    page: Page,
    choice: Option<String>,
    user: String,
    server: String,
    /// Every signed-in account: name, server line, active (empty: only the current one is known).
    accounts: Vec<(String, String, bool)>,
    /// The picture address of each account, parallel to `accounts` (`userImageURL(for:)`).
    pics: Vec<Option<String>>,
    /// Changes when a picture arrives or fades (`ImageHub::stamp`).
    pictures: u64,
    stored: (usize, String),
    live: bool,
    quick_connect: bool,
    sub: SubView,
    seerr: SeerrView,
    own: HeaderView,
    update: UpdateState,
    /// The Home rows and the chosen genres.
    home: swiftly_vm::home_rows::HomeView,
    /// What the server offers on "Bibliothek hinzufügen" / "Genre hinzufügen".
    libs_pick: settings_pages::PickView,
    genres_pick: settings_pages::PickView,
    /// Desktop toolbar strength of the page's scroll offset (`forms::bar_for`).
    header: u8,
}

struct Ctx {
    hub: crate::hub::HubSlot,
    icons: Icons,
    licences: Option<LicenseData>,
}

/// The symbol of a row (`ChoiceRow(symbol:)` / `ValueRow(symbol:)` in `PlaybackSettingsView`, `AppearanceView`,
/// `SettingsView`, mapped through `IconMap.swift`).
fn symbol(f: &Fm, key: &str) -> &'static str {
    match key {
        "immerDirectPlay" => "play.fill",
        // The Mac row (`PlaybackSettingsView.swift:68`) draws a bar chart, the iPhone and the tv the speedometer.
        "bitratenGrenze" if f.form == Form::Desktop => "chart-bar",
        "bitratenGrenze" => "gauge",
        "pufferstufe" => "gauge",
        "bildrateAnpassen" => "clock",
        "tonSprache" => "speaker-high",
        "utSprache" => "subtitles",
        "utAuto" => "text-align-left",
        "utAussehen" => "text-aa",
        "naechsteAuto" => "skip-forward.fill",
        "introAbspannAuto" => "fast-forward.fill",
        "zurueckSek" => "arrow-counter-clockwise",
        "vorSek" => "arrow-clockwise",
        "querformatFest" => "copy",
        "technikschild" => "waveform-magnifying-glass",
        "endzeitImPlayer" => "clock",
        "fortschritt" => "chart-bar.fill",
        "merklisteAn" => "bookmark-simple",
        "gesehenVonAn" => "eye",
        "alphabetAn" => "text-abc",
        "titelAlsLogo" => "text-t",
        "neuGetrennt" => "columns",
        "genreChips" => "rows",
        "downloadsAn" => "arrow-circle-down",
        "nurUeberWLAN" => "wifi-high",
        "naechsteFolgeLaden" => "queue",
        "downloadsSpeicher" => "hard-drive",
        "eigeneHeader" => "key",
        "seerr" => "magnifying-glass-sparkle",
        "serverInfo" => "hard-drives",
        "verbindungPruefen" => "wifi-high",
        "discordAnzeigen" => "chat-circle-text",
        "einstellungenSync" => "arrows-clockwise",
        _ => "gear",
    }
}

fn settings_body(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Vec<Node> {
    let mut body = settings_groups(cx, f, p, ctx);
    if p.page == Page::Settings {
        // `SupportSettingsGroup`: always reachable, below the device settings, before the version line. The tv row
        // (`TVSupportEntryRow`) names that everything stays free.
        let under = if f.form == Form::Tv {
            "Mit einem Kaffee Danke sagen. Alles bleibt für alle kostenlos."
        } else {
            "Mit einem Kaffee Danke sagen"
        };
        let heart = forms::row_kb(
            cx,
            &ctx.icons,
            f,
            "go:support",
            "heart.fill",
            "Swiftly unterstützen",
            Some(under),
            Trail::Chevron,
            true,
        );
        let (title, under, trail) = match &p.update {
            UpdateState::Idle => (
                "Nach Updates suchen".to_owned(),
                Some("Swiftly fragt bei GitHub, ob es eine neuere Version gibt".to_owned()),
                Trail::None,
            ),
            UpdateState::Checking => ("Wird gesucht …".to_owned(), None, Trail::None),
            UpdateState::UpToDate => (
                "Swiftly ist aktuell".to_owned(),
                Some(env!("CARGO_PKG_VERSION").to_owned()),
                Trail::None,
            ),
            UpdateState::Available { version, headline } => (
                format!("Swiftly {version} ist da"),
                Some(
                    headline
                        .clone()
                        .unwrap_or_else(|| "Auf GitHub nachlesen".to_owned()),
                ),
                Trail::External,
            ),
            UpdateState::Failed => (
                "Hat nicht geklappt".to_owned(),
                Some("GitHub antwortet nicht.".to_owned()),
                Trail::None,
            ),
        };
        let update = forms::row_kb(
            cx,
            &ctx.icons,
            f,
            "go:update",
            "arrow-circle-down",
            &title,
            under.as_deref(),
            trail,
            true,
        );
        // Linux updates through the package source (`swiftly-install.sh`), so only Windows gets the row.
        let rows = if cfg!(windows) {
            vec![update, heart]
        } else {
            vec![heart]
        };
        body.push(forms::setting_group(cx, f, "Swiftly", 28.0, rows));
        body.push(
            text(
                cx,
                &format!("Swiftly {}", env!("CARGO_PKG_VERSION")),
                small(12.0, 400),
                colour::FONT_VERY_QUIET,
                Some(1),
                swiftly_text::Align::Start,
            )
            .padding(ins(28.0, 0.0, 40.0, 0.0)),
        );
    }
    body
}

fn settings_groups(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Vec<Node> {
    p.sections
        .sections
        .iter()
        .filter(|s| Page::of(s.title_key) == p.page)
        .enumerate()
        .map(|(i, s)| {
            let rows = s
                .rows
                .iter()
                .map(|r| {
                    let trail = match &r.control {
                        RowControl::Switch { on } => Trail::Switch(*on),
                        RowControl::Choice { shown, .. } => Trail::ValueChevron(shown.clone()),
                        RowControl::Info { value } => Trail::Value(value.clone()),
                        RowControl::Link { value } => {
                            value.clone().map_or(Trail::Chevron, Trail::ValueChevron)
                        }
                    };
                    let enabled = r.enabled && !matches!(r.control, RowControl::Info { .. });
                    let base = forms::row_kb(
                        cx,
                        &ctx.icons,
                        f,
                        &format!("row:{}", r.key),
                        symbol(f, r.key),
                        &r.title,
                        r.under.as_deref(),
                        trail,
                        enabled,
                    );
                    if r.key == "eigeneHeader" {
                        let editor =
                            settings_pages::header_editor(cx, &ctx.icons, f, "oh", &p.own, true)
                                .padding(ins(8.0, 16.0, 12.0, 16.0));
                        Node::vstack(Align::Start, Some(0.0), vec![base, editor])
                    } else {
                        base
                    }
                })
                .collect();
            forms::setting_group(cx, f, &s.title, if i == 0 { 22.0 } else { 28.0 }, rows)
        })
        .collect()
}

fn platform_of(env: Env) -> Platform {
    match Form::of(env.idiom) {
        Form::Touch => Platform::Phone,
        Form::Desktop => Platform::Desktop,
        Form::Tv => Platform::Tv,
    }
}

fn small(size: f32, weight: u16) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    }
}

/// The picture address of the account in use (`userImageURL()`): the active row's, else the only one known.
fn active_picture(p: &Parts) -> Option<&str> {
    pick_active(&p.accounts, &p.pics)
}

fn pick_active<'a>(
    accounts: &[(String, String, bool)],
    pics: &'a [Option<String>],
) -> Option<&'a str> {
    let i = accounts.iter().position(|a| a.2).unwrap_or(0);
    pics.get(i).and_then(|a| a.as_deref())
}

fn profile_body(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Vec<Node> {
    let symbol = || {
        ctx.icons
            .node("user.fill", 30.0, false, color(colour::FONT_QUIET))
    };
    let avatar = crate::hub::avatar_node(&ctx.hub, active_picture(p), 64.0, symbol)
        .frame(Some(64.0), Some(64.0), Alignment::CENTER)
        .background(Node::rect(color(colour::AREA), 32.0), Alignment::CENTER);
    let who = Node::hstack(
        Align::Center,
        Some(16.0),
        vec![
            avatar,
            Node::vstack(
                Align::Start,
                Some(3.0),
                vec![
                    text(
                        cx,
                        &p.user,
                        swiftly_design::TextStyle {
                            tracking: -0.2,
                            ..small(22.0, 700)
                        },
                        colour::FONT,
                        Some(1),
                        swiftly_text::Align::Start,
                    ),
                    text(
                        cx,
                        &p.server,
                        small(13.0, 400),
                        colour::FONT_VERY_QUIET,
                        Some(1),
                        swiftly_text::Align::Start,
                    ),
                ],
            ),
        ],
    )
    .padding(ins(14.0, 0.0, 4.0, 0.0));
    let r = |key: &str, sym: &str, title: &str, under: &str, trail: Trail| {
        forms::row_kb(cx, &ctx.icons, f, key, sym, title, Some(under), trail, true)
    };
    let mut out = vec![
        browse::wide(who, Alignment::LEADING),
        forms::setting_group(
            cx,
            f,
            "",
            18.0,
            vec![
                r(
                    "go:accounts",
                    "users",
                    "Konto wechseln",
                    "Andere Profile und Server",
                    Trail::Chevron,
                ),
                r(
                    "go:server",
                    "plug",
                    "Server hinzufügen",
                    "Du bleibst auch beim anderen angemeldet",
                    Trail::Chevron,
                ),
            ],
        ),
        forms::setting_group(
            cx,
            f,
            "",
            18.0,
            vec![
                r(
                    "go:playback",
                    "play",
                    "Wiedergabe",
                    "Qualität, Sprache, Player",
                    Trail::Chevron,
                ),
                r(
                    "go:presentation",
                    "squares-four",
                    "Darstellung",
                    "Startseite, Reihen, Genres",
                    Trail::Chevron,
                ),
                r(
                    "go:settings",
                    "gear",
                    "Allgemein",
                    "Downloads, Server, Sync",
                    Trail::Chevron,
                ),
                r(
                    "go:downloads",
                    "arrow-circle-down",
                    "Downloads",
                    &swiftly_l10n::plural("%lld Titel auf diesem Gerät", p.stored.0 as i64, &[]),
                    Trail::ValueChevron(p.stored.1.clone()),
                ),
            ],
        ),
        text(
            cx,
            &format!("Swiftly {}", env!("CARGO_PKG_VERSION")),
            small(12.0, 400),
            colour::FONT_VERY_QUIET,
            Some(1),
            swiftly_text::Align::Start,
        )
        .padding(ins(28.0, 0.0, 0.0, 0.0)),
    ];
    // Swift (ProfileView.swift:125): the last row of the account group, no second line, no chevron; it asks first.
    if p.live
        && let Some(account_group) = out.get_mut(1)
    {
        let signout = forms::row_kb(
            cx,
            &ctx.icons,
            f,
            "go:signout",
            "sign-out",
            "Abmelden",
            None,
            Trail::None,
            true,
        );
        *account_group = forms::setting_group(
            cx,
            f,
            "",
            18.0,
            vec![
                r(
                    "go:accounts",
                    "users",
                    "Konto wechseln",
                    "Andere Profile und Server",
                    Trail::Chevron,
                ),
                r(
                    "go:server",
                    "plug",
                    "Server hinzufügen",
                    "Du bleibst auch beim anderen angemeldet",
                    Trail::Chevron,
                ),
                signout,
            ],
        );
    }
    out
}

/// The pages that are not a list of `SettingsVm` rows.
fn pages_view(p: &Parts, env: &Env, cx: &Cx, ctx: &Ctx, f: &Fm) -> Option<Node> {
    let icons = &ctx.icons;
    Some(match p.page {
        Page::SubtitleLook => settings_pages::subtitle_page(cx, icons, env, f, &p.sub),
        Page::Seerr => settings_pages::seerr_page(cx, icons, env, f, &p.seerr),
        // The inventory is missing in this build: say so, with where to find it (`LicensesView.Missing`).
        Page::Licences | Page::Licence(_) | Page::Offering if ctx.licences.is_none() => {
            settings_pages::licences_missing_page(cx, icons, env, f)
        }
        Page::Licences => settings_pages::licences_page(
            cx,
            icons,
            env,
            f,
            ctx.licences.as_ref()?,
            effects::platform_name().to_lowercase().as_str(),
        ),
        Page::Licence(i) => settings_pages::licence_detail(
            cx,
            icons,
            env,
            f,
            ctx.licences.as_ref()?.components.get(i)?,
        ),
        Page::Offering => settings_pages::offering_page(cx, icons, env, f, ctx.licences.as_ref()?),
        Page::LibrarySelection => {
            settings_pages::pick_page(cx, icons, env, f, "Bibliothek hinzufügen", &p.libs_pick)
        }
        Page::GenreSelection => {
            settings_pages::pick_page(cx, icons, env, f, "Genre hinzufügen", &p.genres_pick)
        }
        _ => return None,
    })
}

fn view(p: &Parts, env: &Env, cx: &Cx, ctx: &Rc<Ctx>) -> Node {
    crate::hub::HubSlotExt::begin_build(&ctx.hub);
    let f = forms::fm(env);
    forms::set_bar(p.header);
    if let Some(n) = pages_view(p, env, cx, ctx, &f) {
        return n;
    }
    if f.form == Form::Desktop {
        return desktop_view(p, env, cx, ctx, &f);
    }
    let m = browse::metrics(env);
    let overlay = if p.status.confirm == Some(Confirm::DisableDownloads) {
        Some(browse::sheet(
            cx,
            &ctx.icons,
            &m,
            &format!(
                "{} \u{00B7} {}",
                swiftly_l10n::plural("%lld Titel bleiben auf dem Gerät", p.stored.0 as i64, &[]),
                p.stored.1
            ),
            &[
                SheetRow {
                    label: "Behalten".into(),
                    selected: false,
                },
                SheetRow {
                    label: "Alles entfernen".into(),
                    selected: false,
                },
            ],
            "pick.k.",
            false,
        ))
    } else if p.choice.as_deref() == Some(SIGN_OUT_ASK) {
        Some(browse::sheet(
            cx,
            &ctx.icons,
            &m,
            &format!("Von {} abmelden?", p.user),
            &[SheetRow {
                label: "Abmelden".into(),
                selected: false,
            }],
            "pick.o.",
            false,
        ))
    } else if let Some(key) = &p.choice {
        p.sections
            .sections
            .iter()
            .flat_map(|s| &s.rows)
            .find(|r| r.key == key)
            .and_then(|r| match &r.control {
                RowControl::Choice {
                    selected, options, ..
                } => Some(browse::sheet(
                    cx,
                    &ctx.icons,
                    &m,
                    &r.title,
                    &options
                        .iter()
                        .map(|o| SheetRow {
                            label: o.label.clone(),
                            selected: &o.value == selected,
                        })
                        .collect::<Vec<_>>(),
                    "pick.c.",
                    true,
                )),
                _ => None,
            })
    } else {
        None
    };
    let (title, body) = match p.page {
        Page::Profile => ("Profil", profile_body(cx, &f, p, ctx)),
        Page::Playback => ("Wiedergabe", settings_body(cx, &f, p, ctx)),
        Page::Presentation => ("Darstellung", settings_body(cx, &f, p, ctx)),
        _ => ("Allgemein", settings_body(cx, &f, p, ctx)),
    };
    forms::page(cx, &ctx.icons, env, &f, title, None, body, overlay)
}

const VERSION_ROW: &str = concat!("Swiftly Player ", env!("CARGO_PKG_VERSION"), " (Build 1)");
/// The player the desktop app ships (the Mac line names VLCKit): libmpv on Linux and Windows.
const PLAYER_LINE: &str = "libmpv";

fn hover_white() -> swiftly_render::Color {
    crate::home::rgba(colour::FONT, swiftly_ui::feel::HOVER_SURFACE_ALPHA)
}

/// `ValueList` (`SettingRows.swift:291-348`): the entries of an open choice row under it, on the area colour, padding
/// v 4 and left 48, entries 32 high (15 pt: the chosen one in font colour with the check, the others quiet).
fn value_list(cx: &Cx, f: &Fm, icons: &Icons, control: &RowControl) -> Node {
    let RowControl::Choice {
        selected, options, ..
    } = control
    else {
        return Node::fixed(0.0, 0.0);
    };
    let entries: Vec<Node> = options
        .iter()
        .enumerate()
        .map(|(i, o)| {
            let on = &o.value == selected;
            let mut parts = vec![
                text(
                    cx,
                    &o.label,
                    small(15.0, 400),
                    if on { colour::FONT } else { colour::FONT_QUIET },
                    Some(1),
                    swiftly_text::Align::Start,
                ),
                Node::spacer(),
            ];
            if on {
                // `ValueSelectionRow` (SettingRows.swift): selected means white, not accent; 14 wide mark.
                parts.push(icons.node("check", 15.0, true, color(colour::FONT)).frame(
                    Some(14.0),
                    None,
                    Alignment::CENTER,
                ));
            }
            // List inset 48 plus the row's own 12 on both sides; the row is `Theme.rowHeight` high, square.
            let row = Node::hstack(Align::Center, Some(8.0), parts)
                .padding(ins(0.0, 60.0, 0.0, 12.0))
                .frame(None, Some(f.row.0), Alignment::LEADING);
            let key = format!("pick.c.{i}");
            forms::tappable_kb(browse::wide(row, Alignment::LEADING), f, &key, 0.0)
                .hover_surface(hover_white(), 0.0)
        })
        .collect();
    browse::wide(
        Node::vstack(Align::Start, Some(0.0), entries).padding(ins(4.0, 0.0, 4.0, 0.0)),
        Alignment::LEADING,
    )
    .background(Node::rect(color(colour::AREA), 0.0), Alignment::CENTER)
    .appear_from(1.0, 0.0)
    .exit_to(1.0, 0.0)
    .opacity(1.0, swiftly_ui::feel::leap())
}

/// The groups of the sections named in `titles`, in that order, as one column of the Mac page.
fn desk_groups(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx, titles: &[&str]) -> Vec<Node> {
    let mut out = Vec::new();
    for t in titles {
        let Some(s) = p.sections.sections.iter().find(|s| s.title_key == *t) else {
            continue;
        };
        let rows = s
            .rows
            .iter()
            .map(|r| {
                // `SettingsView.swift` (macOS): "Seerr" shows its value without an arrow, "Verbindung prüfen" the sync
                // mark (or "Moment…" while it runs and then no action); "Eigene Header" has the arrow.
                let trail = match (&r.control, r.key) {
                    (RowControl::Switch { on }, _) => Trail::Switch(*on),
                    (RowControl::Choice { shown, .. }, _) => Trail::ValueChevron(shown.clone()),
                    (RowControl::Info { value }, _) => Trail::Value(value.clone()),
                    (RowControl::Link { value }, "seerr") => {
                        value.clone().map_or(Trail::None, Trail::Value)
                    }
                    (RowControl::Link { value }, "verbindungPruefen") => value
                        .clone()
                        .map_or(Trail::Icon("arrows-clockwise"), Trail::Value),
                    // "Eigene Header" is the arrow only (`arrow: true`), whatever the count.
                    (RowControl::Link { .. }, "eigeneHeader") => Trail::Chevron,
                    (RowControl::Link { value }, _) => {
                        value.clone().map_or(Trail::Chevron, Trail::ValueChevron)
                    }
                };
                let check = r.key == "verbindungPruefen";
                let act = !matches!(r.control, RowControl::Info { .. }) && (r.enabled || !check);
                let base = forms::row_kb_ex(
                    cx,
                    &ctx.icons,
                    f,
                    &format!("row:{}", r.key),
                    symbol(f, r.key),
                    &r.title,
                    r.under.as_deref(),
                    trail,
                    r.enabled || check,
                    act,
                );
                if matches!(r.control, RowControl::Choice { .. })
                    && p.choice.as_deref() == Some(r.key)
                {
                    Node::vstack(
                        Align::Start,
                        Some(0.0),
                        vec![base, value_list(cx, f, &ctx.icons, &r.control)],
                    )
                } else if r.key == "eigeneHeader" && p.own.open {
                    // Closed, the row stands alone (`headersOpen` in `SettingsView.swift`).
                    let editor =
                        settings_pages::header_editor(cx, &ctx.icons, f, "oh", &p.own, true)
                            .padding(ins(0.0, 16.0, 12.0, 16.0));
                    Node::vstack(Align::Start, Some(0.0), vec![base, editor])
                } else {
                    base
                }
            })
            .collect();
        // `Theme.separatorInsetCard` (52) on Playback and Appearance, `GroupLine` (54) on Allgemein.
        let inset = if matches!(p.page, Page::Playback | Page::Presentation) {
            52.0
        } else {
            54.0
        };
        out.push(forms::setting_group_at(
            cx,
            f,
            &s.title,
            if out.is_empty() { 20.0 } else { 28.0 },
            rows,
            inset,
        ));
    }
    out
}

/// "Bibliothek hinzufügen": what the server has and is not a Home row yet.
fn libs_pick_view(
    offer: &Offer<StartLibrary>,
    chosen: &[swiftly_vm::home_rows::HomeRowEntry],
) -> settings_pages::PickView {
    use swiftly_vm::home_rows::HomeRowKind;
    let taken = |id: &str| {
        chosen.iter().any(|r| {
            matches!(&r.kind, HomeRowKind::Library { id: c, .. }
                if c.eq_ignore_ascii_case(id))
        })
    };
    let (total, offer) = match offer {
        Offer::Ready(all) => (
            all.len(),
            Offer::Ready(
                all.iter()
                    .filter(|l| !taken(&l.id))
                    .map(|l| (l.id.clone(), l.name.clone(), l.collection))
                    .collect(),
            ),
        ),
        Offer::Idle => (0, Offer::Idle),
        Offer::Loading => (0, Offer::Loading),
        Offer::Failed => (0, Offer::Failed),
    };
    settings_pages::PickView {
        offer,
        none: "Auf deinem Server gibt es keine Bibliotheken.",
        all_chosen: "Alle Bibliotheken und Sammlungen stehen schon auf der Startseite.",
        total,
        libraries: true,
    }
}

/// "Genre hinzufügen": the server's genres that are not chosen yet.
fn genres_pick_view(offer: &Offer<String>, chosen: &[String]) -> settings_pages::PickView {
    let (total, offer) = match offer {
        Offer::Ready(all) => (
            all.len(),
            Offer::Ready(
                all.iter()
                    .filter(|g| !chosen.contains(g))
                    .map(|g| (g.clone(), g.clone(), false))
                    .collect(),
            ),
        ),
        Offer::Idle => (0, Offer::Idle),
        Offer::Loading => (0, Offer::Loading),
        Offer::Failed => (0, Offer::Failed),
    };
    settings_pages::PickView {
        offer,
        none: "Auf deinem Server sind keine Genres hinterlegt.",
        all_chosen: "Alle Genres stehen schon auf der Startseite.",
        total,
        libraries: false,
    }
}

/// The icon of a fixed Home row (`StartRail.symbol`).
fn rail_symbol(rail: StartRail) -> &'static str {
    match rail {
        StartRail::ContinueWatching => "play-circle",
        StartRail::NextEpisode => "skip-forward.fill",
        StartRail::NewMovies => "film-strip",
        StartRail::NewSeries => "television",
        StartRail::NewArrivals => "sparkle",
    }
}

/// The two move controls of row `i` of `n`: key and whether there is a neighbour.
fn move_keys(prefix: &str, i: usize, n: usize) -> [(String, bool); 2] {
    [
        (format!("{prefix}.up.{i}"), i > 0),
        (format!("{prefix}.dn.{i}"), i + 1 < n),
    ]
}

/// The group "Startseite" (`AppearanceView.rails`): every row in the stored order, then "Bibliothek hinzufügen".
fn home_group(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Node {
    use swiftly_vm::home_rows::HomeRowKind;
    let n = p.home.rows.len();
    let mut rows: Vec<Node> = Vec::new();
    for (i, r) in p.home.rows.iter().enumerate() {
        if i > 0 {
            rows.push(forms::separator_line_at(52.0));
        }
        let (symbol, title, switch, remove) = match &r.kind {
            HomeRowKind::Fixed { rail, on } => {
                (rail_symbol(*rail), rail.lists_name(), Some(*on), None)
            }
            HomeRowKind::Library {
                name, collection, ..
            } => (
                if *collection { "stack" } else { "rows" },
                name.as_str(),
                None,
                Some(format!("home.x.{i}")),
            ),
        };
        rows.push(forms::home_row(
            cx,
            &ctx.icons,
            f,
            &forms::HomeRowSpec {
                key: &format!("home.sw.{i}"),
                symbol,
                title,
                switch,
                remove,
                moves: Some(move_keys("home", i, n)),
            },
        ));
    }
    rows.push(forms::separator_line_at(52.0));
    rows.push(forms::row_kb(
        cx,
        &ctx.icons,
        f,
        "home.add",
        "plus",
        "Bibliothek hinzufügen",
        None,
        Trail::Chevron,
        true,
    ));
    forms::setting_group_at(cx, f, "Startseite", 28.0, rows, 52.0)
}

/// The group "Genres" (`AppearanceView.genres`): the two forms as check rows, the chosen genres, "Genre hinzufügen".
fn genres_group(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Node {
    let mut rows: Vec<Node> = Vec::new();
    let form = p
        .sections
        .sections
        .iter()
        .flat_map(|s| &s.rows)
        .find(|r| r.key == "genreChips");
    if let Some(RowControl::Choice {
        selected, options, ..
    }) = form.map(|r| &r.control)
    {
        for (i, o) in options.iter().enumerate() {
            if i > 0 {
                rows.push(forms::separator_line_at(52.0));
            }
            rows.push(forms::row_kb(
                cx,
                &ctx.icons,
                f,
                &format!("genre.form.{i}"),
                if o.value == "chips" {
                    "capsule"
                } else {
                    "rows"
                },
                &o.label,
                None,
                if *selected == o.value {
                    Trail::Check
                } else {
                    Trail::None
                },
                true,
            ));
        }
    }
    let n = p.home.genres.len();
    for (i, g) in p.home.genres.iter().enumerate() {
        rows.push(forms::separator_line_at(52.0));
        rows.push(forms::home_row(
            cx,
            &ctx.icons,
            f,
            &forms::HomeRowSpec {
                key: &format!("genre.row.{i}"),
                symbol: "tag",
                title: g,
                switch: None,
                remove: Some(format!("genre.x.{i}")),
                moves: Some(move_keys("genre", i, n)),
            },
        ));
    }
    rows.push(forms::separator_line_at(52.0));
    rows.push(forms::row_kb(
        cx,
        &ctx.icons,
        f,
        "genre.add",
        "plus",
        "Genre hinzufügen",
        None,
        Trail::Chevron,
        true,
    ));
    forms::setting_group_at(cx, f, "Genres", 20.0, rows, 52.0)
}

fn version_line(cx: &Cx, s: &str, top: f32) -> Node {
    text(
        cx,
        s,
        small(12.0, 400),
        colour::FONT_VERY_QUIET,
        Some(1),
        swiftly_text::Align::Start,
    )
    .padding(ins(top, 0.0, 0.0, 0.0))
}

/// `AccountCard`, the support card and the navigation group (`ProfileView.swift:587-775`, `:102-124`).
/// A group without a title, `top` below the one above (the title's gap is only there with a title).
fn gapped(cx: &Cx, f: &Fm, top: f32, rows: Vec<Node>) -> Node {
    forms::setting_group(cx, f, "", 0.0, rows).padding(ins(top, 0.0, 0.0, 0.0))
}

fn profile_left(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Vec<Node> {
    // One row per account, the active one ticked; the plus row follows (the Mac's account card).
    let rows: Vec<(String, String, bool)> = if p.accounts.is_empty() {
        vec![(p.user.clone(), p.server.clone(), true)]
    } else {
        p.accounts.clone()
    };
    let who: Vec<Node> = rows
        .iter()
        .enumerate()
        .map(|(i, (name, server, active))| {
            let initial = name
                .chars()
                .next()
                .map(|c| c.to_uppercase().to_string())
                .unwrap_or_default();
            let letter = || {
                text(
                    cx,
                    &initial,
                    small(15.0, 600),
                    colour::FONT,
                    Some(1),
                    swiftly_text::Align::Center,
                )
            };
            let picture = p.pics.get(i).and_then(|a| a.as_deref());
            let avatar = crate::hub::avatar_node(&ctx.hub, picture, 40.0, letter)
                .frame(Some(40.0), Some(40.0), Alignment::CENTER)
                .background(Node::rect(color(colour::AREA), 20.0), Alignment::CENTER);
            let mut kids = vec![
                avatar,
                Node::vstack(
                    Align::Start,
                    Some(2.0),
                    vec![
                        text(
                            cx,
                            name,
                            small(15.0, 600),
                            colour::FONT,
                            Some(1),
                            swiftly_text::Align::Start,
                        ),
                        text(
                            cx,
                            server,
                            small(12.0, 400),
                            colour::FONT_VERY_QUIET,
                            Some(1),
                            swiftly_text::Align::Start,
                        ),
                    ],
                )
                .layout_priority(1.0),
                Node::spacer(),
            ];
            if *active {
                kids.push(
                    ctx.icons
                        .node("check", 16.0, false, color(colour::MARK_ACCENT)),
                );
            }
            let row =
                Node::hstack(Align::Center, Some(12.0), kids).padding(ins(10.0, 16.0, 10.0, 16.0));
            forms::tappable_kb(
                browse::wide(row, Alignment::LEADING),
                f,
                &format!("go:acct:{i}"),
                12.0,
            )
            .hover_surface(hover_white(), 12.0)
        })
        .collect();
    let add = forms::row_kb(
        cx,
        &ctx.icons,
        f,
        "go:server",
        "plus",
        "Konto hinzufügen",
        None,
        Trail::None,
        true,
    );
    let r = |key: &str, sym: &str, title: &str, under: &str, trail: Trail| {
        forms::row_kb(cx, &ctx.icons, f, key, sym, title, Some(under), trail, true)
    };
    vec![
        gapped(
            cx,
            f,
            0.0,
            who.into_iter().chain(std::iter::once(add)).collect(),
        ),
        gapped(
            cx,
            f,
            16.0,
            vec![r(
                "go:support",
                "heart",
                "Swiftly unterstützen",
                "Mit einem Kaffee Danke sagen",
                Trail::Chevron,
            )],
        ),
        gapped(
            cx,
            f,
            18.0,
            vec![
                r(
                    "go:playback",
                    "play",
                    "Wiedergabe",
                    "Qualität, Sprache, Player",
                    Trail::Chevron,
                ),
                r(
                    "go:presentation",
                    "text-aa",
                    "Darstellung",
                    "Startseite, Reihen, Genres",
                    Trail::Chevron,
                ),
                r(
                    "go:settings",
                    "gear",
                    "Allgemein",
                    "Downloads, Server, Sync",
                    Trail::Chevron,
                ),
            ],
        ),
    ]
}

/// The account group and the links group (`ProfileView.swift:136-181`).
fn profile_right(cx: &Cx, f: &Fm, p: &Parts, ctx: &Ctx) -> Vec<Node> {
    let r = |key: &str, sym: &str, title: &str, under: Option<&str>, trail: Trail| {
        forms::row_kb(cx, &ctx.icons, f, key, sym, title, under, trail, true)
    };
    let mut account = vec![r(
        "go:server",
        "plug",
        "Server hinzufügen",
        Some("Jellyfin, Emby oder Plex, auch gemischt"),
        Trail::Chevron,
    )];
    if p.quick_connect {
        account.push(r(
            "go:quick",
            "monitor-play",
            "Quick Connect",
            Some("Code vom Fernseher eingeben"),
            Trail::Chevron,
        ));
    }
    account.push(r("go:signout", "sign-out", "Abmelden", None, Trail::None));
    vec![
        gapped(cx, f, 0.0, account),
        gapped(
            cx,
            f,
            18.0,
            vec![
                // No "Swiftly bewerten" here: the rating link is an App Store review page and Linux and Windows have no
                // store (tvOS shows it as a code for the phone; the desktop has nothing to open).
                r(
                    "link:discord",
                    "users",
                    "Discord beitreten",
                    None,
                    Trail::External,
                ),
                r(
                    "link:bug",
                    "warning",
                    "Fehler melden",
                    None,
                    Trail::External,
                ),
                r(
                    "link:log",
                    "text-align-left",
                    "Protokoll teilen",
                    None,
                    Trail::None,
                ),
                r(
                    "go:licenses",
                    "stack",
                    "Open-Source-Lizenzen",
                    None,
                    Trail::Chevron,
                ),
            ],
        ),
    ]
}

/// The question before Downloads go off (`SettingsView.swift:121-143`): "Behalten", "Alles entfernen" (destructive),
/// "Abbrechen", centred over a dimmed page.
fn confirm_dialog(cx: &Cx, p: &Parts, window_h: f32) -> Node {
    // From above the window edge to the card's place: half the window plus the card's half height.
    let slide = window_h / 2.0 + 130.0;
    let button = |i: usize, label: &str, c: swiftly_design::types::Colour| {
        let t = text(
            cx,
            label,
            small(14.0, 500),
            c,
            Some(1),
            swiftly_text::Align::Center,
        );
        let key = format!("pick.k.{i}");
        browse::wide(
            t.frame(None, Some(34.0), Alignment::CENTER),
            Alignment::CENTER,
        )
        .background(Node::rect(color(colour::AREA), 8.0), Alignment::CENTER)
        .key(key.as_str())
        .on_tap(Action::from(key.as_str()))
        .hover_surface(hover_white(), 8.0)
    };
    let card = Node::vstack(
        Align::Center,
        Some(8.0),
        vec![
            text(
                cx,
                "Downloads ausschalten?",
                small(15.0, 700),
                colour::FONT,
                Some(2),
                swiftly_text::Align::Center,
            ),
            text(
                cx,
                &format!(
                    "{} \u{00B7} {}",
                    swiftly_l10n::plural(
                        "%lld Titel bleiben auf dem Gerät",
                        p.stored.0 as i64,
                        &[]
                    ),
                    p.stored.1
                ),
                small(13.0, 400),
                colour::FONT_QUIET,
                Some(3),
                swiftly_text::Align::Center,
            )
            .padding(ins(0.0, 0.0, 6.0, 0.0)),
            button(0, "Behalten", colour::FONT),
            button(1, "Alles entfernen", colour::ERROR),
            button(2, "Abbrechen", colour::FONT),
        ],
    )
    .padding(ins(20.0, 20.0, 20.0, 20.0))
    .frame(Some(320.0), None, Alignment::CENTER)
    .background(Node::rect(color(colour::RAISED), 14.0), Alignment::CENTER)
    // An AppKit sheet slides down from the top edge of the window and back up (`SheetNative`, 0.2 s easeInOut); it stays opaque.
    .appear_offset(0.0, -slide)
    .exit_to(1.0, 1.0)
    .exit_offset(0.0, -slide)
    .offset(0.0, 0.0, swiftly_ui::feel::of(Id::SheetNative));
    let dim = Node::rect(crate::home::rgba(colour::REASON, 0.5), 0.0)
        .appear_from(1.0, 0.0)
        .exit_to(1.0, 0.0)
        .opacity(1.0, swiftly_ui::feel::of(Id::SheetNative))
        .key("sheet.close")
        .on_tap(Action::from("sheet.close"));
    crate::home::fill_frame(dim, Alignment::CENTER).overlay(card, Alignment::CENTER)
}

fn desktop_view(p: &Parts, env: &Env, cx: &Cx, ctx: &Rc<Ctx>, f: &Fm) -> Node {
    let overlay = (p.status.confirm == Some(Confirm::DisableDownloads))
        .then(|| confirm_dialog(cx, p, env.size.h));
    let (title, gap, cols, columns, footer) = match p.page {
        Page::Profile => (
            "Profil",
            18.0,
            forms::Cols::Fixed,
            vec![profile_left(cx, f, p, ctx), profile_right(cx, f, p, ctx)],
            vec![version_line(cx, VERSION_ROW, 26.0)],
        ),
        Page::Playback => (
            "Wiedergabe",
            0.0,
            forms::Cols::Equal,
            vec![
                desk_groups(cx, f, p, ctx, &["Qualität", "Sprache"]),
                desk_groups(cx, f, p, ctx, &["Ablauf", "Im Player", "Verhalten"]),
            ],
            vec![],
        ),
        Page::Presentation => (
            "Darstellung",
            0.0,
            forms::Cols::Equal,
            {
                let mut left = desk_groups(cx, f, p, ctx, &["Filme und Serien", "Allgemein"]);
                left.push(home_group(cx, f, p, ctx));
                left.push(forms::note(
                    cx,
                    f,
                    "Zum Umsortieren die Pfeile an der Zeile benutzen, oder mit Alt und Pfeil auf eine Zeile.",
                    false,
                    false,
                ));
                left.extend(desk_groups(cx, f, p, ctx, &["Neuzugänge"]));
                vec![left, vec![genres_group(cx, f, p, ctx)]]
            },
            vec![],
        ),
        _ => {
            let mut left = desk_groups(cx, f, p, ctx, &["Offline"]);
            let heart = forms::row_kb(
                cx,
                &ctx.icons,
                f,
                "go:support",
                "heart.fill",
                "Swiftly unterstützen",
                Some("Mit einem Kaffee Danke sagen"),
                Trail::None,
                true,
            )
            // `MacSupportSettingsGroup`: the row has no chevron and sits in 16 pt of padding of its own.
            .padding(ins(16.0, 16.0, 16.0, 16.0));
            // `MacSupportSettingsGroup().padding(.top, 6)` under the group's own 20 pt title gap.
            left.push(forms::setting_group(cx, f, "Swiftly", 26.0, vec![heart]));
            let right = desk_groups(cx, f, p, ctx, &["Server und Dienste", "Synchronisierung"]);
            (
                "Allgemein",
                0.0,
                forms::Cols::Fixed,
                vec![left, right],
                vec![version_line(
                    cx,
                    &format!("{VERSION_ROW} \u{00B7} {PLAYER_LINE}"),
                    26.0,
                )],
            )
        }
    };
    forms::settings_page(
        cx, &ctx.icons, env, f, title, gap, cols, columns, footer, overlay,
    )
}

/// Rows of a header editor and the rows last saved.
#[derive(Clone, Default)]
struct Editor {
    open: bool,
    rows: Vec<(String, String)>,
    saved: Vec<(String, String)>,
}

/// What a tap in a header editor asks of the screen.
enum Tap {
    Focus(usize, bool),
    Save,
}

fn clean(rows: &[(String, String)]) -> Vec<(String, String)> {
    let h: Vec<OwnHeader> = rows.iter().map(|(n, v)| OwnHeader::new(n, v)).collect();
    OwnHeaders::cleaned(&h)
        .into_iter()
        .map(|h| (h.name, h.value))
        .collect()
}

impl Editor {
    fn with(rows: Vec<(String, String)>) -> Editor {
        Editor {
            open: !rows.is_empty(),
            saved: rows.clone(),
            rows,
        }
    }
    fn view(
        &self,
        focus: Option<(usize, bool)>,
        edit: Option<&swiftly_text::Display>,
    ) -> HeaderView {
        HeaderView {
            open: self.open,
            rows: self.rows.clone(),
            focus,
            save: clean(&self.rows) != clean(&self.saved),
            edit: edit.filter(|_| focus.is_some()).cloned(),
        }
    }
    fn tap(&mut self, prefix: &str, is: &dyn Fn(&str) -> bool) -> Option<Tap> {
        if is(&format!("{prefix}.toggle")) {
            self.open = !self.open;
        } else if is(&format!("{prefix}.add")) {
            self.rows.push((String::new(), String::new()));
            return Some(Tap::Focus(self.rows.len() - 1, false));
        } else if is(&format!("{prefix}.save")) {
            return Some(Tap::Save);
        }
        for i in 0..self.rows.len() {
            if is(&format!("{prefix}.del.{i}")) {
                self.rows.remove(i);
                return None;
            }
            if is(&format!("{prefix}.name.{i}")) {
                return Some(Tap::Focus(i, false));
            }
            if is(&format!("{prefix}.val.{i}")) {
                return Some(Tap::Focus(i, true));
            }
        }
        None
    }
}

/// The field that has the keyboard.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Focus {
    Seerr(usize),
    Own(usize, bool),
    SeerrHeader(usize, bool),
}

/// The profile hub and the Settings page: a UI over a `SettingsVm`.
pub struct SettingsScreen {
    ui: Ui<Parts>,
    vm: SettingsVm<Mem>,
    page: Page,
    choice: Option<String>,
    dest: Option<Dest>,
    links: Vec<String>,
    closed: bool,
    stored: (usize, String),
    who: (String, String),
    accounts: Vec<(String, String, bool)>,
    pics: Vec<Option<String>>,
    hub: crate::hub::HubSlot,
    picked: Option<usize>,
    live: bool,
    quick_connect: bool,
    desktop: bool,
    plex: bool,
    store: Mem,
    context: SettingsContext,
    look: SubtitleLook,
    undo: Option<(SubtitleLook, f64)>,
    now: f64,
    link: Box<dyn SeerrLink>,
    conn: SeerrConn,
    fields: [String; 3],
    seerr_headers: Editor,
    check: Box<dyn ServerCheck>,
    seen_check: CheckState,
    update: UpdateCheck,
    seen_update: UpdateState,
    own: Editor,
    own_base: Option<swiftly_net::Url>,
    focus: Option<Focus>,
    /// The editors of the text fields (one model for every field of the app).
    book: crate::field_book::FieldBook<Focus>,
    cx: Cx,
    effects: Vec<Effect>,
    licences: Option<Rc<LicenseData>>,
    /// The effects the settings core handed out and the host has not run yet.
    fx: Arc<std::sync::Mutex<Vec<swiftly_vm::SettingsEffect>>>,
    /// The download engine the effects and the counters belong to (the live app only).
    downloads: Option<swiftly_vm::DownloadsVm<crate::downloads_screen::Dyn>>,
    /// The server's libraries and genres for the two "hinzufügen" pages.
    choices: Box<dyn HomeChoices>,
    seen_offers: (Offer<StartLibrary>, Offer<String>),
}

impl SettingsScreen {
    /// The frame `(x, y, w, h)` of the control with `key`, in the page's own coordinates (tests).
    #[doc(hidden)]
    pub fn frame_of(&self, key: &str) -> Option<[f32; 4]> {
        self.ui.frame_of(key)
    }

    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// The profile hub for `env` over an in-memory store with three downloads on the device. `settings` starts on
    /// the Settings page (tests, goldens).
    pub fn new(env: Env, cx: Cx, settings: bool) -> SettingsScreen {
        let stored = (3_usize, "4,2 GB".to_owned());
        let context = SettingsContext {
            platform: platform_of(env),
            capabilities: Capabilities::ALL,
            server: "demo".into(),
            watchers_plugin: true,
            stored_downloads: stored.0,
            stored_bytes: 4_200_000_000,
            subtitle_look_summary: "Standard".into(),
            ..SettingsContext::default()
        };
        let store = Mem(Arc::new(MemoryStore::new()));
        let check = Box::new(ScriptedCheck::new("demo.swiftly.test", "10.10.3"));
        Self::build(
            env,
            cx,
            settings,
            store,
            context,
            ("Paul".into(), browse::SERVER.into()),
            stored,
            false,
            true,
            None,
            check,
        )
    }

    /// The hub for the real app: `settings.json` as the store, the rows of the active account's kind of server.
    pub fn live(env: Env, cx: Cx, core: &crate::live::Core, settings: bool) -> SettingsScreen {
        let entry = core.active_entry();
        let kind = entry
            .as_ref()
            .map_or(swiftly_jellyfin::ServerKind::Jellyfin, |e| e.kind);
        let context = SettingsContext {
            platform: platform_of(env),
            capabilities: crate::live_accounts::capabilities_of(kind),
            server: entry.as_ref().map(|e| e.suffix.clone()).unwrap_or_default(),
            subtitle_look_summary: "Standard".into(),
            ..SettingsContext::default()
        };
        let base = entry
            .as_ref()
            .and_then(|e| swiftly_net::Url::parse(&e.server).ok());
        let who = entry.map_or((String::new(), String::new()), |e| (e.name, e.server));
        let store = Mem::shared(Arc::<swiftly_settings::JsonFileStore>::clone(
            &core.settings,
        ));
        // The real check is set by `with_check`; until then the line says "Server" and "?".
        let mut s = Self::build(
            env,
            cx,
            settings,
            store,
            context,
            who,
            (0, "0 MB".to_owned()),
            true,
            kind == swiftly_jellyfin::ServerKind::Jellyfin,
            base,
            Box::new(ScriptedCheck::unknown()),
        );
        s.plex = kind == swiftly_jellyfin::ServerKind::Plex;
        s
    }

    /// Connects the screen to the download engine: the effects of the settings core (pause everything, delete every
    /// download, Wi-Fi only, next episode) reach it, and the counters of the rows are the real ones (the Mac's
    /// `SettingsRowsFeed.facts()`).
    #[must_use]
    pub fn with_downloads(
        mut self,
        vm: swiftly_vm::DownloadsVm<crate::downloads_screen::Dyn>,
    ) -> SettingsScreen {
        self.downloads = Some(vm);
        self.feed_counters();
        self.sync();
        self
    }

    /// The server's lists for "Bibliothek hinzufügen" and "Genre hinzufügen".
    #[must_use]
    pub fn with_choices(mut self, choices: Box<dyn HomeChoices>) -> SettingsScreen {
        self.choices = choices;
        self.sync();
        self
    }

    /// Hands the queued effects of the settings core to the engine.
    fn run_effects(&mut self) {
        let queued = std::mem::take(
            &mut *self
                .fx
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        );
        if queued.is_empty() {
            return;
        }
        if let Some(vm) = &self.downloads {
            for e in &queued {
                crate::settings_run::apply_effect(vm, &self.store, e);
            }
        }
        if queued
            .iter()
            .any(|e| matches!(e, swiftly_vm::SettingsEffect::DeleteDownloads))
        {
            self.feed_counters();
        }
    }

    /// Takes the stored count and size from the engine into the rows and the dialog text.
    fn feed_counters(&mut self) {
        let Some(vm) = &self.downloads else {
            return;
        };
        let part = vm.storage();
        let count = part.count as usize;
        if self.stored == (count, part.size.clone()) && self.context.stored_bytes == part.bytes {
            return;
        }
        self.stored = (count, part.size.clone());
        self.context.stored_downloads = count;
        self.context.stored_bytes = part.bytes;
        let _ = self
            .vm
            .send(SettingsIntent::Context(Box::new(self.context.clone())));
    }

    /// Replaces the scripted Seerr of the demo with the real one.
    #[must_use]
    pub fn with_seerr(mut self, link: Box<dyn SeerrLink>) -> SettingsScreen {
        self.conn = link.state();
        self.context.seerr_connected = self.conn.connected;
        let _ = self
            .vm
            .send(SettingsIntent::Context(Box::new(self.context.clone())));
        self.link = link;
        self
    }

    /// Replaces the scripted server check of the demo with the real one.
    #[must_use]
    pub fn with_check(mut self, check: Box<dyn ServerCheck>) -> SettingsScreen {
        self.check = check;
        self.refresh_check();
        self
    }

    #[allow(clippy::too_many_arguments)]
    fn build(
        env: Env,
        cx: Cx,
        settings: bool,
        store: Mem,
        mut context: SettingsContext,
        who: (String, String),
        stored: (usize, String),
        live: bool,
        quick_connect: bool,
        own_base: Option<swiftly_net::Url>,
        check: Box<dyn ServerCheck>,
    ) -> SettingsScreen {
        // The server line, the check and Discord are the desktop shell's rows (see `SettingsContext::server_rows`).
        context.server_rows = Form::of(env.idiom) == Form::Desktop;
        let seen_check = check.state();
        context.server_name = seen_check.name.clone();
        context.server_version = seen_check.version.clone();
        context.checking = seen_check.running;
        context.check_result = seen_check.result.clone();
        let stored_look = match store.get("utAussehen") {
            Some(Value::Data(d)) => Some(d),
            _ => None,
        };
        let look = SubtitleLook::read(stored_look.as_deref());
        context.subtitle_look_summary = look.entry_value().into();
        let fx: Arc<std::sync::Mutex<Vec<swiftly_vm::SettingsEffect>>> = Arc::default();
        let sink = Arc::clone(&fx);
        let vm = SettingsVm::new(
            store.clone(),
            Locale::parse("de"),
            context.clone(),
            move |e| {
                sink.lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .push(e);
            },
        );
        let page = if settings {
            Page::Settings
        } else {
            Page::Profile
        };
        let parts = Parts {
            sections: vm.sections(),
            status: vm.status(),
            page,
            choice: None,
            user: who.0.clone(),
            server: who.1.clone(),
            accounts: Vec::new(),
            pics: Vec::new(),
            pictures: 0,
            stored: stored.clone(),
            live,
            quick_connect,
            sub: SubView {
                look,
                undo: false,
                adjustable: true,
            },
            seerr: SeerrView {
                conn: SeerrConn::default(),
                fields: Default::default(),
                focus: None,
                edit: None,
                headers: HeaderView::default(),
            },
            own: HeaderView::default(),
            update: UpdateState::Idle,
            home: vm.home(),
            libs_pick: libs_pick_view(&Offer::Idle, &[]),
            genres_pick: genres_pick_view(&Offer::Idle, &[]),
            header: 0,
        };
        let licences = settings_pages::licence_data();
        let hub: crate::hub::HubSlot = crate::hub::HubSlot::default();
        let ctx = Rc::new(Ctx {
            hub: Rc::clone(&hub),
            icons: Icons::new(&cx, env.scale),
            licences: licences.clone(),
        });
        let text_cx = cx.clone();
        let ui = Ui::new(
            move |p: &Parts, env: &Env, cx: &Cx| view(p, env, cx, &ctx),
            parts,
            env,
            cx,
        );
        let own = own_base
            .as_ref()
            .map(|b| {
                OwnHeaders::registered(b)
                    .into_iter()
                    .map(|h| (h.name, h.value))
                    .collect::<Vec<_>>()
            })
            .map_or_else(Editor::default, Editor::with);
        let mut s = SettingsScreen {
            ui,
            vm,
            page,
            choice: None,
            dest: None,
            links: Vec::new(),
            closed: false,
            stored,
            who,
            accounts: Vec::new(),
            pics: Vec::new(),
            hub: Rc::clone(&hub),
            picked: None,
            live,
            quick_connect,
            desktop: Form::of(env.idiom) == Form::Desktop,
            plex: false,
            store,
            context,
            look,
            undo: None,
            now: 0.0,
            link: Box::new(ScriptedSeerr::default()),
            conn: SeerrConn::default(),
            fields: Default::default(),
            seerr_headers: Editor::default(),
            check,
            seen_check,
            update: UpdateCheck::default(),
            seen_update: UpdateState::Idle,
            own,
            own_base,
            focus: None,
            book: crate::field_book::FieldBook::new(),
            cx: text_cx,
            effects: Vec::new(),
            licences: licences.map(Rc::new),
            fx,
            downloads: None,
            choices: Box::new(ScriptedChoices::new(Vec::new(), Vec::new())),
            seen_offers: (Offer::Idle, Offer::Idle),
        };
        s.sync();
        s
    }

    /// The view model.
    pub fn vm(&self) -> &SettingsVm<Mem> {
        &self.vm
    }
    /// Whether the Settings page (not the hub) is in front.
    pub fn on_settings(&self) -> bool {
        self.page != Page::Profile
    }
    /// Opens a settings page by name: `playback`, `presentation`, `general`, `subtitles`, `seerr` or `licences`
    /// (tests, goldens).
    pub fn open_page(&mut self, name: &str) {
        self.page = match name {
            "playback" => Page::Playback,
            "presentation" => Page::Presentation,
            "subtitles" => Page::SubtitleLook,
            "seerr" => {
                self.open_seerr();
                Page::Seerr
            }
            "licences" => Page::Licences,
            _ => Page::Settings,
        };
    }
    /// Whether a sheet (choice list or confirm question) is open.
    pub fn sheet_open(&self) -> bool {
        self.choice.is_some() || self.vm.status().confirm.is_some()
    }
    /// Link rows tapped so far (keys).
    pub fn links(&self) -> &[String] {
        &self.links
    }
    /// The account rows of the profile card (the Mac lists every account, then a plus row).
    pub fn set_accounts(&mut self, accounts: Vec<(String, String, bool)>) {
        self.accounts = accounts;
    }
    /// The picture address of each account row, in the order of [`Self::set_accounts`] (the Mac's `userImageURL(for:)`).
    pub fn set_pictures(&mut self, pics: Vec<Option<String>>) {
        self.pics = pics;
    }
    /// Shows the real pictures of the accounts through `hub` (without it only the initials show).
    #[must_use]
    pub fn with_images(self, hub: Rc<crate::hub::ImageHub>) -> Self {
        crate::hub::HubSlotExt::attach(&self.hub, hub);
        self
    }
    /// The account row tapped, once.
    pub fn take_picked(&mut self) -> Option<usize> {
        self.picked.take()
    }
    /// The destination a hub row asked for, once.
    pub fn take_dest(&mut self) -> Option<Dest> {
        self.dest.take()
    }
    /// What the screen asked the host to do outside the window (open an address, share the log), once.
    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }
    /// The subtitle look as set on the page.
    pub fn subtitle_look(&self) -> SubtitleLook {
        self.look
    }
    /// Opens the choice list of a row (tests, goldens).
    pub fn show_choice(&mut self, key: &str) {
        self.choice = Some(key.to_owned());
    }
    /// Whether typed text goes into a field.
    pub fn wants_text(&self) -> bool {
        self.focus.is_some()
    }
    /// Scroll offsets of all scroll views in tree order (tests, measuring).
    pub fn scroll_offsets(&self) -> Vec<f64> {
        self.ui.scroll_offsets()
    }

    /// The pointer moved over the window (hover surfaces of the rows).
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.pointer_move(x, y, now);
        self.drain();
    }
    /// The pointer left the window.
    pub fn pointer_leave(&mut self, now: f64) {
        self.ui.pointer_leave(now);
        self.drain();
    }

    fn field_mut(&mut self) -> Option<&mut String> {
        fn pick(rows: &mut [(String, String)], r: usize, value: bool) -> Option<&mut String> {
            rows.get_mut(r)
                .map(|x| if value { &mut x.1 } else { &mut x.0 })
        }
        match self.focus? {
            Focus::Seerr(i) => self.fields.get_mut(i),
            Focus::Own(r, v) => pick(&mut self.own.rows, r, v),
            Focus::SeerrHeader(r, v) => pick(&mut self.seerr_headers.rows, r, v),
        }
    }
    /// Makes the editor of the focused field exist, gives it the keyboard and loads the field's text.
    fn bind_editor(&mut self) {
        let Some(f) = self.focus else {
            self.book.blur(0.0);
            return;
        };
        self.book.ensure(f, || match f {
            Focus::Seerr(2) | Focus::Own(_, true) | Focus::SeerrHeader(_, true) => {
                swiftly_text::TextEditor::single_line().password()
            }
            _ => swiftly_text::TextEditor::single_line(),
        });
        self.book.focus(f, 0.0);
        let text = self.field_mut().cloned().unwrap_or_default();
        self.book.set_text(f, &text);
    }
    /// One text-input event for the focused field (typing, caret keys, selection, clipboard, undo, composition). The
    /// editor is the single state machine; the field's string follows it. Returns whether a field took it.
    pub fn edit(&mut self, ev: &swiftly_text::TextInputEvent) -> bool {
        if self.focus.is_none() {
            return false;
        }
        self.bind_editor();
        let Some(out) = self.book.apply(ev, 0.0) else {
            return false;
        };
        if let Some(f) = self.focus {
            let text = self.book.text(f).to_owned();
            if let Some(field) = self.field_mut() {
                *field = text;
            }
        }
        if out.submitted {
            self.submit();
        }
        self.sync();
        true
    }
    /// Uses another clipboard than the system's (tests).
    pub fn set_clipboard(&mut self, clip: Box<dyn swiftly_text::Clipboard>) {
        self.book.set_clipboard(clip);
    }
    /// Typed text.
    pub fn type_text(&mut self, s: &str) {
        self.edit(&swiftly_text::TextInputEvent::Text(s.to_owned()));
    }
    /// Backspace.
    pub fn backspace(&mut self) {
        self.edit(&swiftly_text::TextInputEvent::Key(
            swiftly_text::EditKey::Backspace,
            swiftly_text::Mods::NONE,
        ));
    }
    /// The composition of the input method (empty ends it).
    pub fn set_preedit(&mut self, text: &str) {
        self.edit(&swiftly_text::TextInputEvent::Preedit {
            text: text.to_owned(),
            cursor: Some((text.len(), text.len())),
        });
    }
    /// Return: in the password field of Seerr it connects.
    pub fn submit(&mut self) {
        if self.focus == Some(Focus::Seerr(2)) {
            self.connect();
        }
    }
    /// Type size of the text in a field of this idiom.
    fn field_size(&self) -> f32 {
        if Form::of(self.ui.env().idiom) == Form::Tv {
            28.0
        } else {
            15.0
        }
    }
    /// What the input method needs: open over a field, password purpose, the caret's rectangle (the composition's end
    /// while one is open).
    pub fn ime_state(&self) -> crate::ime::ImeState {
        let area = self
            .ui
            .frame_of(swiftly_ui::field::CONTENT_KEY)
            .map(|[x, y, _, h]| {
                let caret = self.focus.and_then(|f| self.book.state(f)).map(|s| {
                    let d = s.editor.display();
                    let layout = self.cx.text.borrow_mut().layout(
                        &d.text,
                        &swiftly_text::TextStyle::new(self.field_size(), 400),
                        None,
                        None,
                        swiftly_text::Align::Start,
                    );
                    layout
                        .caret_rect(
                            d.caret
                                .or(d.preedit.as_ref().map(|r| r.end))
                                .unwrap_or(d.text.len()),
                            1.5,
                        )
                        .x
                });
                [x + caret.unwrap_or(0.0), y, 1.5, h]
            });
        let password = matches!(
            self.focus,
            Some(Focus::Seerr(2) | Focus::Own(_, true) | Focus::SeerrHeader(_, true))
        );
        crate::ime::ImeState {
            allowed: self.wants_text(),
            password,
            area,
        }
    }

    fn connect(&mut self) {
        if self.fields.iter().any(String::is_empty) || self.conn.busy {
            return;
        }
        let headers = clean(&self.seerr_headers.rows);
        self.link
            .connect(&self.fields[0], &self.fields[1], &self.fields[2], headers);
        self.refresh_conn();
    }

    fn set_look(&mut self, look: SubtitleLook) {
        if look == self.look {
            return;
        }
        self.look = look;
        crate::store::set_logged(&self.store, "utAussehen", Value::Data(look.encoded()));
        self.context.subtitle_look_summary = look.entry_value().into();
        let _ = self
            .vm
            .send(SettingsIntent::Context(Box::new(self.context.clone())));
    }

    fn save_own_headers(&mut self) {
        let rows = clean(&self.own.rows);
        if let Some(base) = &self.own_base {
            let list: Vec<OwnHeader> = rows.iter().map(|(n, v)| OwnHeader::new(n, v)).collect();
            OwnHeaders::set_down(&list, base);
        }
        self.own.saved = rows;
    }

    fn sync(&mut self) {
        self.run_effects();
        self.bind_editor();
        let edit = self
            .focus
            .and_then(|f| self.book.state(f))
            .map(|s| s.editor.display());
        let hf = |f: Option<Focus>, own: bool| match f {
            Some(Focus::Own(r, v)) if own => Some((r, v)),
            Some(Focus::SeerrHeader(r, v)) if !own => Some((r, v)),
            _ => None,
        };
        self.ui.set_parts(Parts {
            sections: self.vm.sections(),
            status: self.vm.status(),
            page: self.page,
            choice: self.choice.clone(),
            user: self.who.0.clone(),
            server: self.who.1.clone(),
            accounts: self.accounts.clone(),
            pics: self.pics.clone(),
            pictures: crate::hub::HubSlotExt::stamp(&self.hub),
            stored: self.stored.clone(),
            live: self.live,
            quick_connect: self.quick_connect,
            sub: SubView {
                look: self.look,
                undo: self.undo.is_some(),
                adjustable: !self.plex,
            },
            seerr: SeerrView {
                conn: self.conn.clone(),
                fields: self.fields.clone(),
                focus: match self.focus {
                    Some(Focus::Seerr(i)) => Some(i),
                    _ => None,
                },
                edit: edit
                    .clone()
                    .filter(|_| matches!(self.focus, Some(Focus::Seerr(_)))),
                headers: self
                    .seerr_headers
                    .view(hf(self.focus, false), edit.as_ref()),
            },
            own: self.own.view(hf(self.focus, true), edit.as_ref()),
            update: self.seen_update.clone(),
            home: self.vm.home(),
            libs_pick: libs_pick_view(&self.choices.libraries(), &self.vm.home().rows),
            genres_pick: genres_pick_view(&self.choices.genres(), &self.vm.home().genres),
            header: forms::bar_for(
                self.ui.env(),
                self.ui.scroll_offsets().first().copied().unwrap_or(0.0),
            ),
        });
    }

    fn go_back(&mut self) -> bool {
        self.focus = None;
        if self.vm.status().confirm.is_some() {
            let _ = self.vm.send(SettingsIntent::CancelConfirm);
            true
        } else if self.choice.take().is_some() {
            true
        } else if self.page != Page::Profile {
            self.page = self.page.parent();
            true
        } else {
            false
        }
    }

    /// The Home rows, the genres and the two "hinzufügen" pages of the Appearance page.
    fn tapped_home(&mut self, a: &Action) {
        use swiftly_vm::HomeEdit;
        use swiftly_vm::home_rows::HomeRowKind;
        let is = |s: &str| *a == Action::from(s);
        let home = self.vm.home();
        let mut edit: Option<HomeEdit> = None;
        for (i, r) in home.rows.iter().enumerate() {
            if is(&format!("home.sw.{i}")) {
                if let HomeRowKind::Fixed { rail, on } = &r.kind {
                    let _ = self.vm.send(SettingsIntent::SetSwitch {
                        key: format!("startRow.{}", rail.raw_value()),
                        on: !on,
                    });
                }
            } else if is(&format!("home.x.{i}"))
                && let HomeRowKind::Library { id, .. } = &r.kind
            {
                edit = Some(HomeEdit::RemoveLibrary(id.clone()));
            } else if is(&format!("home.up.{i}")) {
                edit = Some(HomeEdit::Shift {
                    id: r.id.clone(),
                    delta: -1,
                });
            } else if is(&format!("home.dn.{i}")) {
                edit = Some(HomeEdit::Shift {
                    id: r.id.clone(),
                    delta: 1,
                });
            }
        }
        for (i, g) in home.genres.iter().enumerate() {
            if is(&format!("genre.x.{i}")) {
                edit = Some(HomeEdit::RemoveGenre(g.clone()));
            } else if is(&format!("genre.up.{i}")) && i > 0 {
                edit = Some(HomeEdit::DropGenre {
                    source: g.clone(),
                    onto: home.genres[i - 1].clone(),
                });
            } else if is(&format!("genre.dn.{i}")) && i + 1 < home.genres.len() {
                edit = Some(HomeEdit::DropGenre {
                    source: g.clone(),
                    onto: home.genres[i + 1].clone(),
                });
            }
        }
        for (i, value) in ["rails", "chips"].iter().enumerate() {
            if is(&format!("genre.form.{i}")) {
                let _ = self.vm.send(SettingsIntent::SetChoice {
                    key: "genreChips".to_owned(),
                    value: (*value).to_owned(),
                });
            }
        }
        if is("home.add") && self.page == Page::Presentation {
            self.choices.load_libraries();
            self.page = Page::LibrarySelection;
        } else if is("genre.add") && self.page == Page::Presentation {
            self.choices.load_genres();
            self.page = Page::GenreSelection;
        } else if is("pick.retry") {
            match self.page {
                Page::LibrarySelection => self.choices.load_libraries(),
                Page::GenreSelection => self.choices.load_genres(),
                _ => {}
            }
        }
        // A click on an entry adds it and goes back.
        match self.page {
            Page::LibrarySelection => {
                if let Some(pick) = (0..64).find(|i| is(&format!("pick.add.{i}")))
                    && let Offer::Ready(list) = &self.libs_view().offer
                    && let Some((id, name, collection)) = list.get(pick)
                {
                    edit = Some(HomeEdit::AddLibrary(StartLibrary::new(
                        id,
                        name,
                        *collection,
                    )));
                    self.page = Page::Presentation;
                }
            }
            Page::GenreSelection => {
                if let Some(pick) = (0..4096).find(|i| is(&format!("pick.add.{i}")))
                    && let Offer::Ready(list) = &self.genres_view().offer
                    && let Some((name, _, _)) = list.get(pick)
                {
                    edit = Some(HomeEdit::AddGenre(name.clone()));
                    self.page = Page::Presentation;
                }
            }
            _ => {}
        }
        if let Some(e) = edit {
            let _ = self.vm.send(SettingsIntent::Home(e));
        }
    }

    /// The Seerr page opens: the user name is the session's (`user = model.session?.userName`) and the stored session
    /// is looked up (`seerr.lookUp()`).
    fn open_seerr(&mut self) {
        self.page = Page::Seerr;
        if self.fields[1].is_empty() {
            self.fields[1] = self.who.0.clone();
        }
        self.link.look_up();
    }

    fn libs_view(&self) -> settings_pages::PickView {
        libs_pick_view(&self.choices.libraries(), &self.vm.home().rows)
    }

    fn genres_view(&self) -> settings_pages::PickView {
        genres_pick_view(&self.choices.genres(), &self.vm.home().genres)
    }

    fn tapped_pages(&mut self, a: &Action) {
        let is = |s: &str| *a == Action::from(s);
        let is_dyn: &dyn Fn(&str) -> bool = &is;
        if self.page == Page::SubtitleLook {
            let mut look = self.look;
            for (i, v) in Size::ALL.iter().enumerate() {
                if is(&format!("sub.size.{i}")) {
                    look.size = *v;
                }
            }
            for (i, v) in SubColour::ALL.iter().enumerate() {
                if is(&format!("sub.colour.{i}")) {
                    look.colour = *v;
                }
            }
            for (i, v) in Outline::ALL.iter().enumerate() {
                if is(&format!("sub.outline.{i}")) {
                    look.outline = *v;
                }
            }
            for (i, v) in [Position::Bottom, Position::Raised].iter().enumerate() {
                if is(&format!("sub.position.{i}")) {
                    look.position = *v;
                }
            }
            if is("sub.shadow") {
                look.shadow = !look.shadow;
            }
            if is("sub.background") {
                look.background = !look.background;
            }
            if is("sub.file") && !self.plex {
                look.keep_file_style = !look.keep_file_style;
            }
            if is("sub.reset") && !look.is_standard() {
                // No question: it can be undone for four seconds.
                self.undo = Some((look, self.now + 4000.0));
                look = SubtitleLook::STANDARD;
            }
            if is("sub.undo")
                && let Some((before, _)) = self.undo.take()
            {
                look = before;
            }
            self.set_look(look);
        }
        if self.page == Page::Seerr {
            for i in 0..3 {
                if is(&format!("seerr.f{i}")) {
                    self.focus = Some(Focus::Seerr(i));
                }
            }
            if is("seerr.go") {
                self.connect();
            }
            if is("seerr.off") {
                self.link.disconnect();
                self.refresh_conn();
                self.fields[0].clear();
                self.fields[2].clear();
            }
            if let Some(Tap::Focus(r, v)) = self.seerr_headers.tap("sh", is_dyn) {
                self.focus = Some(Focus::SeerrHeader(r, v));
            }
        }
        if matches!(self.page, Page::Settings) {
            match self.own.tap("oh", is_dyn) {
                Some(Tap::Focus(r, v)) => self.focus = Some(Focus::Own(r, v)),
                Some(Tap::Save) => self.save_own_headers(),
                None => {}
            }
        }
        if let Some(data) = self.licences.clone() {
            match self.page {
                Page::Licences => {
                    if is("lic.offer") {
                        self.page = Page::Offering;
                    }
                    for i in 0..data.components.len() {
                        if is(&format!("lic.{i}")) {
                            self.page = Page::Licence(i);
                        }
                    }
                }
                Page::Licence(i) if is("lic.src") => {
                    if let Some(c) = data.components.get(i) {
                        self.effects.push(Effect::OpenUrl(c.source.clone()));
                    }
                }
                _ => {}
            }
        }
    }

    fn tapped(&mut self, a: &Action) {
        let is = |s: &str| *a == Action::from(s);
        self.focus = None;
        if is("back") {
            self.back(0.0);
        } else if is("sheet.close") {
            self.go_back();
        } else if is("go:update") {
            match self.seen_update.clone() {
                UpdateState::Available { .. } => self.effects.push(Effect::OpenUrl(
                    crate::update_check::release_link().to_owned(),
                )),
                UpdateState::Checking => {}
                _ => {
                    self.update.start();
                    self.seen_update = self.update.state();
                    self.sync();
                }
            }
        } else if is("go:playback") {
            self.page = Page::Playback;
        } else if is("go:presentation") {
            self.page = Page::Presentation;
        } else if is("go:settings") {
            self.page = Page::Settings;
        } else if is("go:downloads") {
            self.dest = Some(Dest::Downloads);
        } else if is("go:accounts") {
            self.dest = Some(Dest::Accounts);
        } else if let Some(i) = (0..self.accounts.len()).find(|i| is(&format!("go:acct:{i}"))) {
            self.picked = Some(i);
        } else if is("go:server") {
            self.dest = Some(Dest::AddServer);
        } else if is("go:support") && self.desktop {
            // No store on desktop: the old Linux and Windows apps sent the tap to the supporter page of the website.
            self.effects
                .push(Effect::OpenUrl(effects::SUPPORT_URL.to_owned()));
        } else if is("go:support") {
            self.dest = Some(Dest::Support);
        } else if is("go:quick") {
            self.dest = Some(Dest::QuickShare);
        } else if is("go:licenses") {
            self.links.push("licenses".to_owned());
            self.page = Page::Licences;
        } else if let Some(k) = ["discord", "bug", "log"]
            .iter()
            .find(|k| is(&format!("link:{k}")))
        {
            self.links.push((*k).to_owned());
            self.effects.push(match *k {
                "discord" => Effect::OpenUrl(effects::DISCORD_URL.to_owned()),
                "bug" => Effect::OpenUrl(effects::error_report_url(
                    &format!("Swiftly Player {}", env!("CARGO_PKG_VERSION")),
                    effects::platform_name(),
                )),
                _ => Effect::ShareLog,
            });
        } else if is("go:signout") && self.desktop {
            // Swift (`ProfileView.swift:155`): the row signs out at once; the sheet question stays on touch and tv.
            self.dest = Some(Dest::SignOut);
        } else if is("go:signout") {
            self.choice = Some(SIGN_OUT_ASK.to_owned());
        } else if is("pick.o.0") && self.choice.as_deref() == Some(SIGN_OUT_ASK) {
            self.choice = None;
            self.dest = Some(Dest::SignOut);
        }
        self.tapped_pages(a);
        self.tapped_home(a);
        let sections = self.vm.sections();
        for r in sections.sections.iter().flat_map(|s| &s.rows) {
            if !is(&format!("row:{}", r.key)) {
                continue;
            }
            match &r.control {
                RowControl::Switch { on } => {
                    let _ = self.vm.send(SettingsIntent::SetSwitch {
                        key: r.key.to_owned(),
                        on: !on,
                    });
                }
                RowControl::Choice { .. } => {
                    self.choice = if self.choice.as_deref() == Some(r.key) {
                        None
                    } else {
                        Some(r.key.to_owned())
                    }
                }
                RowControl::Link { .. } => match r.key {
                    "utAussehen" => self.page = Page::SubtitleLook,
                    "seerr" => self.open_seerr(),
                    "eigeneHeader" => self.own.open = !self.own.open,
                    // Not while it runs: the row has no action then (`examine ? nil : { check() }`).
                    "verbindungPruefen" => {
                        if r.enabled {
                            self.check.start(self.now);
                        }
                    }
                    _ => self.links.push(r.key.to_owned()),
                },
                RowControl::Info { .. } => {}
            }
        }
        if let Some(key) = self.choice.clone()
            && let Some(RowControl::Choice { options, .. }) = sections
                .sections
                .iter()
                .flat_map(|s| &s.rows)
                .find(|r| r.key == key)
                .map(|r| &r.control)
        {
            for (i, o) in options.iter().enumerate() {
                if is(&format!("pick.c.{i}")) {
                    let _ = self.vm.send(SettingsIntent::SetChoice {
                        key: key.clone(),
                        value: o.value.clone(),
                    });
                    self.choice = None;
                }
            }
        }
        if self.vm.status().confirm.is_some() {
            for (i, delete) in [(0, false), (1, true)] {
                if is(&format!("pick.k.{i}")) {
                    let _ = self
                        .vm
                        .send(SettingsIntent::ConfirmDisableDownloads { delete });
                }
            }
            if is("pick.k.2") {
                let _ = self.vm.send(SettingsIntent::CancelConfirm);
            }
        }
    }

    fn clock(&mut self, now: f64) {
        self.now = now;
        if self.undo.is_some_and(|(_, until)| now >= until) {
            self.undo = None;
        }
        self.refresh_conn();
        let offers = (self.choices.libraries(), self.choices.genres());
        if offers != self.seen_offers {
            self.seen_offers = offers;
            self.sync();
        }
        self.check.tick(now);
        self.refresh_check();
        let u = self.update.state();
        if u != self.seen_update {
            self.seen_update = u;
            self.sync();
        }
    }

    /// Reads the check; a new answer goes into the rows of "Server und Dienste".
    fn refresh_check(&mut self) {
        let state = self.check.state();
        if state != self.seen_check {
            self.context.server_name = state.name.clone();
            self.context.server_version = state.version.clone();
            self.context.checking = state.running;
            self.context.check_result = state.result.clone();
            let _ = self
                .vm
                .send(SettingsIntent::Context(Box::new(self.context.clone())));
            self.seen_check = state;
        }
    }

    /// Reads the connection; a new session shows in the Seerr row and drops the typed password.
    fn refresh_conn(&mut self) {
        let conn = self.link.state();
        if conn != self.conn {
            if conn.connected != self.conn.connected {
                self.context.seerr_connected = conn.connected;
                let _ = self
                    .vm
                    .send(SettingsIntent::Context(Box::new(self.context.clone())));
                if conn.connected {
                    self.fields[2].clear();
                }
            }
            self.conn = conn;
        }
    }

    /// Escape goes back unless typed text is being edited.
    fn escape_backs(&self) -> bool {
        !self.wants_text()
    }

    crate::form_io!();
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_layout::Size as Sz;
    use swiftly_ui::Idiom;

    fn desktop() -> Env {
        Env::new(Sz::new(1280.0, 800.0), 2.0, Idiom::Desktop)
    }
    fn tap(s: &mut SettingsScreen, key: &str) {
        s.tapped(&Action::from(key));
        let _ = s.frame(100.0);
    }

    #[test]
    fn server_check_shows_the_server_runs_and_answers() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), true);
        let rows = |s: &SettingsScreen| {
            let secs = s.vm().sections();
            let sec = secs
                .sections
                .iter()
                .find(|x| x.title_key == "Server und Dienste")
                .unwrap()
                .clone();
            sec.rows
        };
        let r = rows(&s);
        assert_eq!(r[0].title, "demo.swiftly.test");
        assert_eq!(
            r[0].control,
            RowControl::Info {
                value: "10.10.3".into()
            }
        );
        // The desktop has no presence client, so the Discord switch is not offered.
        assert!(r.iter().all(|x| x.key != "discordAnzeigen"));
        s.now = 1000.0;
        tap(&mut s, "row:verbindungPruefen");
        let r = rows(&s);
        assert_eq!(
            r[1].control,
            RowControl::Link {
                value: Some("Moment…".into())
            }
        );
        let _ = s.frame(2000.0);
        s.clock(2000.0);
        let r = rows(&s);
        assert_eq!(r[1].under.as_deref(), Some("Erreichbar — Jellyfin 10.10.3"));
        assert_eq!(r[1].control, RowControl::Link { value: None });
        // Not on the phone: those rows are the desktop shell's.
        let t = SettingsScreen::new(
            Env::new(Sz::new(390.0, 800.0), 3.0, Idiom::Phone),
            Cx::deterministic(),
            true,
        );
        assert!(
            t.vm()
                .sections()
                .sections
                .iter()
                .flat_map(|x| &x.rows)
                .all(|x| x.key != "serverInfo" && x.key != "discordAnzeigen")
        );
    }

    #[test]
    fn the_update_row_opens_the_release_page_only_when_one_is_found() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), true);
        s.update = UpdateCheck::with_state(UpdateState::Available {
            version: "9.9.9".into(),
            headline: None,
        });
        s.clock(1.0);
        assert_eq!(
            s.seen_update,
            UpdateState::Available {
                version: "9.9.9".into(),
                headline: None
            }
        );
        tap(&mut s, "go:update");
        assert_eq!(
            s.take_effects(),
            vec![Effect::OpenUrl(crate::update_check::release_link().into())]
        );
        // While a check runs the row does nothing.
        s.update = UpdateCheck::with_state(UpdateState::Checking);
        s.clock(2.0);
        tap(&mut s, "go:update");
        assert!(s.take_effects().is_empty());
    }

    #[test]
    fn the_support_row_opens_the_supporter_page_in_the_browser_on_desktop() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), false);
        tap(&mut s, "go:support");
        assert!(
            !s.sheet_open(),
            "no thank-you sheet: there is nothing to thank for yet"
        );
        assert!(s.take_dest().is_none());
        assert_eq!(
            s.take_effects(),
            vec![Effect::OpenUrl(
                "https://swiftlyplayer.com/supporter".into()
            )]
        );
    }

    #[test]
    fn the_profile_picture_is_the_active_accounts_and_missing_ones_stay_none() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), false);
        s.set_accounts(vec![
            ("Anna".into(), "Jellyfin \u{b7} a".into(), false),
            ("Paul".into(), "Jellyfin \u{b7} b".into(), true),
        ]);
        s.set_pictures(vec![None, Some("https://b/Users/p/Images/Primary".into())]);
        assert_eq!(
            pick_active(&s.accounts, &s.pics),
            Some("https://b/Users/p/Images/Primary")
        );
        s.set_pictures(vec![Some("x".into()), None]);
        assert_eq!(pick_active(&s.accounts, &s.pics), None);
    }

    #[test]
    fn hub_link_rows_emit_effects_and_licences_open_the_page() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), false);
        assert!(
            !s.a11y_nodes().iter().any(|n| n.label == "Swiftly bewerten"),
            "no store, no rating row on the desktop"
        );
        tap(&mut s, "link:discord");
        tap(&mut s, "link:bug");
        tap(&mut s, "link:log");
        let e = s.take_effects();
        assert_eq!(e[0], Effect::OpenUrl(effects::DISCORD_URL.into()));
        assert!(
            matches!(&e[1], Effect::OpenUrl(u) if u.starts_with("https://github.com/paulherter/swiftly-player/issues/new?body="))
        );
        assert_eq!(e[2], Effect::ShareLog);
        assert!(s.take_effects().is_empty(), "read once");
        tap(&mut s, "go:licenses");
        assert_eq!(s.page, Page::Licences);
        tap(&mut s, "lic.offer");
        assert_eq!(s.page, Page::Offering);
        s.back(0.0);
        assert_eq!(s.page, Page::Licences);
        tap(&mut s, "lic.0");
        assert_eq!(s.page, Page::Licence(0));
        tap(&mut s, "lic.src");
        assert!(matches!(s.take_effects().first(), Some(Effect::OpenUrl(_))));
    }

    #[test]
    fn subtitle_look_is_stored_summarised_reset_and_undone() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), false);
        s.open_page("subtitles");
        tap(&mut s, "sub.shadow");
        tap(&mut s, "sub.size.2");
        assert!(s.look.shadow && s.look.size == Size::Large);
        let stored = match s.store.get("utAussehen") {
            Some(Value::Data(d)) => SubtitleLook::read(Some(&d)),
            _ => panic!("look not stored"),
        };
        assert_eq!(stored, s.look);
        let summary = |s: &SettingsScreen| {
            s.vm()
                .sections()
                .sections
                .iter()
                .flat_map(|x| &x.rows)
                .find(|r| r.key == "utAussehen")
                .map(|r| format!("{:?}", r.control))
        };
        assert!(summary(&s).is_some_and(|c| c.contains("Eigenes")));
        let before = s.look;
        tap(&mut s, "sub.reset");
        assert!(s.look.is_standard() && s.undo.is_some());
        tap(&mut s, "sub.undo");
        assert_eq!(s.look, before);
        tap(&mut s, "sub.reset");
        let _ = s.frame(100.0 + 4001.0);
        assert!(s.undo.is_none(), "the strip goes after four seconds");
    }

    #[test]
    fn home_rows_move_switch_and_take_libraries_and_genres() {
        use swiftly_vm::home_rows::HomeRowKind;
        let lib = StartLibrary::new("L1", "Kino", false);
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), false).with_choices(
            Box::new(ScriptedChoices::new(
                vec![lib.clone(), StartLibrary::new("C1", "Marvel", true)],
                vec!["Drama".to_owned(), "Horror".to_owned()],
            )),
        );
        s.page = Page::Presentation;
        s.sync();
        let first = s.vm.home().rows[0].id.clone();
        // The first fixed row switches off and on again; the shown order stays.
        tap(&mut s, "home.sw.0");
        assert!(matches!(
            s.vm.home().rows[0].kind,
            HomeRowKind::Fixed { on: false, .. }
        ));
        tap(&mut s, "home.sw.0");
        // "Bibliothek hinzufügen" opens the page, a tap adds the library at the end and goes back.
        tap(&mut s, "home.add");
        assert_eq!(s.page, Page::LibrarySelection);
        tap(&mut s, "pick.add.0");
        assert_eq!(s.page, Page::Presentation);
        let rows = s.vm.home().rows;
        assert_eq!(rows.last().map(|r| r.id.as_str()), Some("library:L1"));
        // It moves up with the arrow and goes away with the cross; the fixed row stays first.
        let last = rows.len() - 1;
        tap(&mut s, &format!("home.up.{last}"));
        assert_eq!(s.vm.home().rows[last - 1].id, "library:L1");
        assert_eq!(s.vm.home().rows[0].id, first);
        tap(&mut s, &format!("home.x.{}", last - 1));
        assert!(s.vm.home().rows.iter().all(|r| r.id != "library:L1"));
        // Genres: add, reorder, remove, and the form check row.
        tap(&mut s, "genre.add");
        assert_eq!(s.page, Page::GenreSelection);
        tap(&mut s, "pick.add.1");
        tap(&mut s, "genre.add");
        tap(&mut s, "pick.add.0");
        assert_eq!(s.vm.home().genres, ["Horror", "Drama"]);
        tap(&mut s, "genre.dn.0");
        assert_eq!(s.vm.home().genres, ["Drama", "Horror"]);
        tap(&mut s, "genre.x.0");
        assert_eq!(s.vm.home().genres, ["Horror"]);
        tap(&mut s, "genre.form.1");
        assert_eq!(
            s.store.get("genreChips"),
            Some(Value::Bool(true)),
            "the chips form is stored"
        );
    }

    #[test]
    fn the_subtitle_look_icons_exist_in_the_icon_set() {
        for name in [
            "text-aa",
            "palette",
            "textbox",
            "copy",
            "square",
            "align-bottom-simple",
            "file-text",
            "arrow-counter-clockwise",
        ] {
            assert!(swiftly_ui::icons::path_data(name).is_some(), "{name}");
        }
    }

    #[test]
    fn the_home_icons_exist_in_the_icon_set() {
        for name in [
            "play-circle",
            "skip-forward.fill",
            "film-strip",
            "television",
            "sparkle",
            "stack",
            "rows",
            "tag",
            "capsule",
            "plus",
            "x",
            "caret-up",
            "caret-down",
            "arrows-clockwise",
        ] {
            assert!(swiftly_ui::icons::path_data(name).is_some(), "{name}");
        }
    }

    #[test]
    fn the_seerr_page_prefills_the_user_and_return_in_the_password_field_connects() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), true);
        let user = s.who.0.clone();
        assert!(!user.is_empty());
        assert!(s.fields[1].is_empty());
        tap(&mut s, "row:seerr");
        assert_eq!(s.fields[1], user, "the session's user name is the default");
        tap(&mut s, "seerr.f0");
        s.type_text("seerr.example.de");
        tap(&mut s, "seerr.f2");
        s.type_text("geheim");
        s.submit();
        assert!(s.conn.connected, "Return in the password field connects");
    }

    #[test]
    fn seerr_form_connects_with_all_three_fields_and_disconnects() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), true);
        tap(&mut s, "row:seerr");
        assert_eq!(s.page, Page::Seerr);
        for (i, text) in ["seerr.example.de", "paul", "geheim"].iter().enumerate() {
            tap(&mut s, &format!("seerr.f{i}"));
            assert!(s.wants_text());
            s.type_text(text);
        }
        s.backspace();
        s.type_text("m");
        tap(&mut s, "seerr.go");
        assert!(s.conn.connected, "{:?}", s.conn);
        assert!(s.fields[2].is_empty(), "the password is not kept");
        tap(&mut s, "seerr.off");
        assert!(!s.conn.connected);
    }

    #[test]
    fn header_editor_adds_edits_and_saves() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), true);
        tap(&mut s, "row:eigeneHeader");
        assert!(s.own.open);
        tap(&mut s, "oh.add");
        s.type_text("X-Test");
        tap(&mut s, "oh.val.0");
        s.type_text("1");
        assert_eq!(s.own.rows, vec![("X-Test".to_owned(), "1".to_owned())]);
        assert!(s.own.view(None, None).save);
        tap(&mut s, "oh.save");
        assert!(!s.own.view(None, None).save);
        tap(&mut s, "oh.del.0");
        assert!(s.own.rows.is_empty());
    }

    #[test]
    fn pointer_move_lights_a_row_and_leave_clears_it() {
        let mut s = SettingsScreen::new(desktop(), Cx::deterministic(), true);
        let still = |s: &mut SettingsScreen, at: f64| {
            let _ = s.frame(at);
            let (l, _) = s.frame(at + 400.0);
            s.render_software(&l)
        };
        let base = still(&mut s, 100.0);
        let mut lit = false;
        for y in (120..420).step_by(12) {
            s.pointer_move(200.0, y as f32, 600.0);
            if base.diff(&still(&mut s, 700.0)).0 > 0 {
                lit = true;
                break;
            }
        }
        assert!(lit, "hovering a row draws its surface");
        s.pointer_leave(1500.0);
        assert_eq!(
            base.diff(&still(&mut s, 1600.0)).0,
            0,
            "leaving clears the hover"
        );
    }

    fn with_engine() -> (
        SettingsScreen,
        swiftly_vm::DownloadsVm<crate::downloads_screen::Dyn>,
    ) {
        use crate::downloads_screen::{DownloadsScreen, Scenario};
        let vm = DownloadsScreen::new(desktop(), Cx::deterministic(), Scenario::Mixed)
            .vm()
            .clone();
        let mut s =
            SettingsScreen::new(desktop(), Cx::deterministic(), true).with_downloads(vm.clone());
        let _ = s.frame(100.0);
        (s, vm)
    }

    #[test]
    fn the_counters_are_the_engines_and_alles_entfernen_deletes_every_download() {
        let (mut s, vm) = with_engine();
        let stored = vm.storage();
        assert!(stored.count > 0, "the demo list has finished titles");
        assert_eq!(s.stored, (stored.count as usize, stored.size.clone()));
        assert_eq!(s.context.stored_downloads, stored.count as usize);
        tap(&mut s, "row:downloadsAn"); // off until enabled: this switches it on
        assert!(s.vm.status().confirm.is_none());
        tap(&mut s, "row:downloadsAn");
        assert!(s.vm.status().confirm.is_some(), "the question comes first");
        assert!(!vm.list().rows.is_empty(), "asking deletes nothing");
        tap(&mut s, "pick.k.1");
        assert!(
            vm.list().rows.is_empty(),
            "Alles entfernen removes every download"
        );
        assert_eq!(s.stored.0, 0);
    }

    #[test]
    fn switching_downloads_off_pauses_the_running_ones_and_keeps_the_files() {
        let (mut s, vm) = with_engine();
        let running = |vm: &swiftly_vm::DownloadsVm<_>| vm.storage().active;
        tap(&mut s, "row:downloadsAn"); // on
        let before = running(&vm);
        assert!(before > 0, "the demo has a running title");
        tap(&mut s, "row:downloadsAn");
        assert!(s.vm.status().confirm.is_some());
        tap(&mut s, "pick.k.0");
        assert!(!vm.list().rows.is_empty(), "Behalten keeps what is stored");
        assert!(running(&vm) <= before);
        assert_eq!(running(&vm), 0, "nothing keeps loading");
    }

    #[test]
    fn wifi_only_and_next_episode_reach_the_engine() {
        let (mut s, vm) = with_engine();
        tap(&mut s, "row:downloadsAn"); // on: the Wi-Fi row appears
        let was = vm.storage().only_over_wlan;
        tap(&mut s, "row:nurUeberWLAN");
        assert_ne!(vm.storage().only_over_wlan, was);
        tap(&mut s, "row:nurUeberWLAN");
        assert_eq!(vm.storage().only_over_wlan, was);
    }
}

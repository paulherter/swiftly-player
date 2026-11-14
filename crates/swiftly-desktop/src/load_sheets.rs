//! The two download sheets of the Mac app, hosted by the Downloads page: the add popover (`LoadPanel`, 320 wide) for a
//! film or a handful of titles and the season sheet (`MacLoadSelection`, 420 wide) for a series. The rules stay in
//! `swiftly-downloads` (`LoadSelection`, `DownloadRules`); this file holds the sheet state and the drawing.
//!
//! Other screens do not reach into the sheets. Their download button builds a [`LoadRequest`] and hands it to
//! `DownloadsScreen::request_load`.

use crate::browse::wide;
use crate::downloads_screen::Dyn;
use crate::forms::{self, Fm};
use crate::home::{ins, rgba};
use crate::load_panel::{
    LoadSpec, mac_load_panel, mac_pick, mono, plain, raised_card, scrim, scrim_at, sheet_button,
};
use std::collections::HashMap;
use swiftly_design::tokens::colour;
use swiftly_downloads::item::{audio_streams, first_source};
use swiftly_downloads::load_selection::SeasonRight;
use swiftly_downloads::{
    Art, AudioStream, CheckboxState, DownloadAudioChoice, DownloadAudioOption, DownloadItem,
    DownloadRules, DownloadState, FootSpace, LoadSelection,
};
use swiftly_layout::{Align, Alignment, Axis, Rect, Size};
use swiftly_model::Item;
use swiftly_rules::download_audio::{language_options, track_options};
use swiftly_rules::download_quality::DownloadQuality;
use swiftly_ui::a11y::{A11yNode, Role};
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::popover::{Anchor, MenuEntry, MenuItem};
use swiftly_ui::{Action, Cx, Env, Node, Paint, PressStyle, feel};
use swiftly_vm::{DownloadsIntent, DownloadsVm};

/// What a download button asks the Downloads page for.
#[derive(Clone, Debug)]
pub enum LoadRequest {
    /// The add popover for these titles (a film, or the episodes already chosen). `quality_select` is true when the
    /// server may convert, so the quality can be picked.
    Add {
        /// The bare title; the sheet's header makes "{title} laden".
        title: String,
        /// The titles, in the original quality.
        items: Vec<DownloadItem>,
        /// Image addresses to fetch along (id to address).
        images: HashMap<String, String>,
        /// Offer smaller versions.
        quality_select: bool,
        /// The audio tracks of each title (same order as `items`; empty = no choice of sound).
        streams: Vec<Vec<AudioStream>>,
        /// The button the popover hangs under (window points); `None` centres it.
        anchor: Option<Rect>,
    },
    /// The season sheet of a series. `episodes` holds the seasons that are already read (key: season id); the rest
    /// arrives through `DownloadsScreen::season_loaded`.
    Season {
        /// The account the downloads belong to.
        account: String,
        /// The series.
        series: Box<Item>,
        /// The seasons in display order.
        seasons: Vec<Item>,
        /// Episodes of the seasons read so far.
        episodes: HashMap<String, Vec<Item>>,
        /// Offer smaller versions.
        quality_select: bool,
        /// The button the sheet grows out of (window points); `None` centres it.
        anchor: Option<Rect>,
    },
}

/// The open sheet.
#[derive(Clone)]
pub(crate) enum Sheet {
    Add(Box<AddSheet>),
    Season(Box<SeasonSheet>),
}

/// The rules of the track names and the preselected track: the shared core ones (what the Mac uses).
pub(crate) type TrackNames = swiftly_vm::TrackNames;

fn menu_of<T>(
    list: &[T],
    prefix: &str,
    text: impl Fn(&T) -> String,
    on: impl Fn(&T) -> bool,
) -> Vec<MenuEntry> {
    list.iter()
        .enumerate()
        .map(|(i, t)| {
            MenuEntry::Item(
                MenuItem::new(Action::from(format!("{prefix}{i}").as_str()), text(t))
                    .checked(on(t)),
            )
        })
        .collect()
}

fn sound_label(options: &[DownloadAudioOption], choice: &DownloadAudioChoice) -> String {
    options
        .iter()
        .find(|o| &o.choice == choice)
        .or(options.first())
        .map(|o| o.label.clone())
        .unwrap_or_default()
}

impl Sheet {
    /// Where the sheet hangs (the button that opened it).
    pub fn anchor(&self) -> Option<Rect> {
        match self {
            Sheet::Add(a) => a.anchor,
            Sheet::Season(s) => s.anchor,
        }
    }

    /// The menu a picker button of the sheet opens (`load.quality`, `load.sound`, `sel.quality`, `sel.sound`).
    pub fn menu(&self, key: &str) -> Option<Vec<MenuEntry>> {
        match (self, key) {
            (Sheet::Add(a), "load.quality") if a.pick => Some(menu_of(
                &a.offered,
                "load.q:",
                |q| label(*q),
                |q| *q == a.quality,
            )),
            (Sheet::Add(a), "load.sound") if a.sound_pick() => Some(menu_of(
                &a.audio_opts,
                "load.a:",
                |o| o.label.clone(),
                |o| o.choice == a.audio,
            )),
            (Sheet::Season(s), "sel.quality") => {
                let offered = s.sel.offered(s.select_quality);
                (offered.len() > 1)
                    .then(|| menu_of(&offered, "sel.q:", |q| label(*q), |q| *q == s.sel.quality))
            }
            (Sheet::Season(s), "sel.sound") => {
                let rules = TrackNames::german();
                let (options, chosen) = (s.sel.audio_options(&rules), s.sel.audio(&rules, ""));
                s.sel.audio_offered(&rules).then(|| {
                    menu_of(
                        &options,
                        "sel.a:",
                        |o| o.label.clone(),
                        |o| o.choice == chosen,
                    )
                })
            }
            _ => None,
        }
    }

    /// The keys that open a picker menu.
    pub const TRIGGERS: [&'static str; 4] =
        ["load.quality", "load.sound", "sel.quality", "sel.sound"];

    /// Every key the open sheet can report (the screen matches a tapped action against them).
    pub fn keys(&self) -> Vec<String> {
        match self {
            Sheet::Add(a) => {
                let mut v: Vec<String> = [
                    "load.quality",
                    "load.sound",
                    "load.go",
                    "load.queue",
                    "load.cell",
                    "load.clean",
                ]
                .map(str::to_owned)
                .to_vec();
                v.extend((0..a.offered.len()).map(|i| format!("load.q:{i}")));
                v.extend((0..a.audio_opts.len()).map(|i| format!("load.a:{i}")));
                v
            }
            Sheet::Season(s) => {
                let mut v: Vec<String> = [
                    "sel.all",
                    "sel.onlyun",
                    "sel.quality",
                    "sel.sound",
                    "sel.retry",
                    "sel.go",
                ]
                .map(str::to_owned)
                .to_vec();
                v.extend((0..s.sel.offered(s.select_quality).len()).map(|i| format!("sel.q:{i}")));
                v.extend(
                    (0..s.sel.audio_options(&TrackNames::german()).len())
                        .map(|i| format!("sel.a:{i}")),
                );
                for season in &s.seasons {
                    v.push(format!("sel.box:{}", season.id));
                    v.push(format!("sel.open:{}", season.id));
                }
                v.extend(
                    s.sel
                        .all_episodes()
                        .iter()
                        .map(|e| format!("sel.ep:{}", e.id)),
                );
                v
            }
        }
    }
}

fn label(q: DownloadQuality) -> String {
    match (q.name(), q.addition(",")) {
        (Some(n), Some(a)) => format!("{n} \u{00B7} {a}"),
        (Some(n), None) => n.to_owned(),
        _ => "Original".to_owned(),
    }
}

fn next_quality(offered: &[DownloadQuality], now: DownloadQuality) -> DownloadQuality {
    let at = offered.iter().position(|q| *q == now).map_or(0, |i| i + 1);
    offered
        .get(at % offered.len().max(1))
        .copied()
        .unwrap_or(DownloadQuality::Original)
}

fn size_of(e: &Item) -> i64 {
    e.media_sources
        .as_deref()
        .and_then(<[_]>::first)
        .and_then(|s| s.size)
        .unwrap_or(0)
}

// ---- the add popover -------------------------------------------------------------------------------------------------

#[derive(Clone)]
pub(crate) struct AddSheet {
    base: Vec<DownloadItem>,
    images: HashMap<String, String>,
    quality: DownloadQuality,
    offered: Vec<DownloadQuality>,
    pub pick: bool,
    pub spec: LoadSpec,
    clean: Vec<String>,
    streams: Vec<Vec<AudioStream>>,
    audio_opts: Vec<DownloadAudioOption>,
    audio: DownloadAudioChoice,
    pub anchor: Option<Rect>,
}

impl AddSheet {
    pub fn new(
        title: String,
        items: Vec<DownloadItem>,
        images: HashMap<String, String>,
        select: bool,
        mut streams: Vec<Vec<AudioStream>>,
        anchor: Option<Rect>,
    ) -> AddSheet {
        streams.resize(items.len(), Vec::new());
        // A film chooses one track, several titles choose a language that the files share.
        let rules = TrackNames::german();
        let audio_opts = match streams.as_slice() {
            [one] => track_options(&rules, one),
            many => language_options(&rules, many),
        };
        let files: Vec<(i64, Option<i64>)> =
            items.iter().map(|i| (i.bytes, i.runtime_ticks)).collect();
        let offered = DownloadQuality::offered(select, DownloadQuality::source_bitrate_of(&files));
        let pick = select && offered.len() > 1;
        let spec = LoadSpec {
            title,
            bytes: 0,
            converted: false,
            recomputed: false,
            can_clean: false,
            quality: None,
            sound: None,
            free: 0,
            free_after: 0,
            dispensable: 0,
            no_wlan: false,
        };
        AddSheet {
            base: items,
            images,
            quality: DownloadQuality::Original,
            offered,
            pick,
            spec,
            clean: Vec::new(),
            streams,
            audio_opts,
            audio: DownloadAudioChoice::All,
            anchor,
        }
    }

    /// Whether the sound is a choice (all tracks and at least two more).
    pub fn sound_pick(&self) -> bool {
        self.audio_opts.len() > 2
    }

    fn version(&self) -> Vec<DownloadItem> {
        let rules = TrackNames::german();
        self.base
            .iter()
            .zip(&self.streams)
            .map(|(i, streams)| {
                let i = if self.pick {
                    i.in_quality(self.quality)
                } else {
                    i.clone()
                };
                i.with_audio(&rules, &self.audio, streams)
            })
            .collect()
    }

    /// Recomputes the numbers from the manager's space rules.
    pub fn refresh(&mut self, vm: &DownloadsVm<Dyn>, no_wlan: bool) {
        let v = self.version();
        let bytes: i64 = v.iter().map(|i| i.bytes).sum();
        let inq = vm.inquiry(bytes);
        let first = v.first();
        let shown = first.and_then(|i| i.quality).filter(|q| !q.is_original());
        let container = first
            .and_then(|i| i.container.as_deref())
            .map(str::to_uppercase);
        let quality = if self.pick {
            Some(label(self.quality))
        } else {
            let parts: Vec<String> = shown.map(label).into_iter().chain(container).collect();
            (!parts.is_empty()).then(|| parts.join(" \u{00B7} "))
        };
        self.spec.bytes = bytes;
        self.spec.converted = v.iter().any(DownloadItem::streamed);
        self.spec.recomputed = v.iter().any(DownloadItem::converted);
        self.spec.can_clean = inq.suffices_to_clean_up() && !inq.dispensable.is_empty();
        self.spec.quality = quality;
        self.spec.sound = self
            .sound_pick()
            .then(|| sound_label(&self.audio_opts, &self.audio));
        self.spec.free = inq.free_after + bytes;
        self.spec.free_after = inq.free_after;
        self.spec.dispensable = inq.dispensable_bytes;
        self.spec.no_wlan = no_wlan;
        self.clean = inq.dispensable.iter().map(|d| d.id.clone()).collect();
    }

    /// A key of the sheet. `Some(true)` closes the sheet.
    pub fn act(&mut self, key: &str, vm: &DownloadsVm<Dyn>) -> Option<bool> {
        match key {
            "load.quality" => {
                self.quality = next_quality(&self.offered, self.quality);
                Some(false)
            }
            "load.go" | "load.queue" | "load.cell" => {
                self.start(vm);
                Some(true)
            }
            _ if key.starts_with("load.q:") => {
                let i = key.trim_start_matches("load.q:").parse::<usize>().ok()?;
                self.quality = *self.offered.get(i)?;
                Some(false)
            }
            _ if key.starts_with("load.a:") => {
                let i = key.trim_start_matches("load.a:").parse::<usize>().ok()?;
                self.audio = self.audio_opts.get(i)?.choice.clone();
                Some(false)
            }
            "load.clean" => {
                let _ = vm.send(DownloadsIntent::Delete(self.clean.clone()));
                self.start(vm);
                Some(true)
            }
            _ => None,
        }
    }

    fn start(&self, vm: &DownloadsVm<Dyn>) {
        let _ = vm.send(DownloadsIntent::Start {
            items: self.version(),
            images: self.images.clone(),
            check_space: true,
        });
    }
}

// ---- the season sheet ------------------------------------------------------------------------------------------------

#[derive(Clone)]
pub(crate) struct SeasonSheet {
    pub sel: LoadSelection,
    series: Item,
    seasons: Vec<Item>,
    account: String,
    open: Option<String>,
    free: i64,
    stored: HashMap<String, DownloadState>,
    select_quality: bool,
    pub anchor: Option<Rect>,
}

impl SeasonSheet {
    pub fn new(
        account: String,
        series: Item,
        seasons: Vec<Item>,
        episodes: HashMap<String, Vec<Item>>,
        select_quality: bool,
        anchor: Option<Rect>,
    ) -> SeasonSheet {
        let ids = seasons.iter().map(|s| s.id.clone()).collect();
        let mut sel = LoadSelection::new(ids, episodes);
        if sel.batches().is_empty() {
            sel.finish_load();
        }
        SeasonSheet {
            sel,
            series,
            seasons,
            account,
            open: None,
            free: 0,
            stored: HashMap::new(),
            select_quality,
            anchor,
        }
    }

    /// Reads which episodes are already in the list and the free space.
    pub fn refresh(&mut self, vm: &DownloadsVm<Dyn>) {
        self.stored = vm.entries().into_iter().map(|d| (d.id, d.state)).collect();
        self.sel.set_present(self.stored.keys().cloned());
        self.free = vm.inquiry(0).free_after;
    }

    fn episodes_of(&self, season: &str) -> Vec<Item> {
        self.sel.episodes.get(season).cloned().unwrap_or_default()
    }

    /// The titles the selection yields, in the chosen quality.
    pub fn items(&self, now: f64) -> Vec<DownloadItem> {
        let rules = TrackNames::german();
        let choice = self.sel.audio(&rules, "");
        self.sel
            .selected_episodes()
            .iter()
            .map(|e| {
                let src = e.media_sources.as_deref().and_then(<[_]>::first);
                let mut d = DownloadItem::new(
                    e.id.clone(),
                    self.account.clone(),
                    Art::Episode,
                    e.name.clone(),
                    size_of(e),
                    now,
                );
                d.series = Some(self.series.name.clone());
                d.series_identifier = Some(self.series.id.clone());
                d.season = e.parent_index_number;
                d.episode = e.index_number;
                d.runtime_ticks = e.run_time_ticks;
                d.container = src.and_then(|s| s.container.clone());
                d.source = src.and_then(|s| s.id.clone());
                d.in_quality(self.sel.quality).with_audio(
                    &rules,
                    &choice,
                    &audio_streams(first_source(e)),
                )
            })
            .collect()
    }

    /// A key of the sheet. `Some(true)` closes the sheet.
    pub fn act(&mut self, key: &str, vm: &DownloadsVm<Dyn>, now: f64) -> Option<bool> {
        let k = key.strip_prefix("sel.")?;
        if k == "all" {
            let all: Vec<Item> = self.sel.all_episodes().into_iter().cloned().collect();
            let refs: Vec<&Item> = all.iter().collect();
            self.sel.toggle(&refs);
        } else if k == "onlyun" {
            self.sel.only_unwatched = !self.sel.only_unwatched;
            self.sel.new_compute();
        } else if let Some(id) = k.strip_prefix("box:") {
            let list = self.episodes_of(id);
            let refs: Vec<&Item> = list.iter().collect();
            let vis = self.sel.visible(&refs);
            self.sel.toggle(&vis);
        } else if let Some(id) = k.strip_prefix("open:") {
            self.open = if self.open.as_deref() == Some(id) {
                None
            } else {
                Some(id.to_owned())
            };
        } else if let Some(id) = k.strip_prefix("ep:") {
            let all: Vec<Item> = self.sel.all_episodes().into_iter().cloned().collect();
            let one: Vec<&Item> = all.iter().filter(|e| e.id == id).collect();
            self.sel.toggle(&one);
        } else if k == "quality" {
            let offered = self.sel.offered(self.select_quality);
            self.sel.quality = next_quality(&offered, self.sel.quality);
        } else if let Some(i) = k.strip_prefix("q:").and_then(|i| i.parse::<usize>().ok()) {
            if let Some(q) = self.sel.offered(self.select_quality).get(i) {
                self.sel.quality = *q;
            }
        } else if let Some(i) = k.strip_prefix("a:").and_then(|i| i.parse::<usize>().ok()) {
            if let Some(o) = self.sel.audio_options(&TrackNames::german()).get(i) {
                self.sel.audio_chosen = Some(o.choice.clone());
            }
        } else if k == "retry" {
            self.sel.begin_load();
        } else if k == "go" {
            let items = self.items(now);
            if !items.is_empty() {
                let _ = vm.send(DownloadsIntent::Start {
                    items,
                    images: HashMap::new(),
                    check_space: true,
                });
            }
            return Some(true);
        } else {
            return None;
        }
        self.sel.reset_quality_if_gone(self.select_quality);
        Some(false)
    }

    /// The height the cards would have; the scroll area is as tall as that, between 58 and 360.
    fn content_h(&self) -> f32 {
        let series = 58.0 + 1.0 + 64.0;
        let mut seasons = 0.0;
        for (i, s) in self.seasons.iter().enumerate() {
            seasons += 58.0 + if i + 1 < self.seasons.len() { 1.0 } else { 0.0 };
            if self.open.as_deref() == Some(s.id.as_str()) {
                let list = self.episodes_of(&s.id);
                let refs: Vec<&Item> = list.iter().collect();
                seasons += self.sel.visible(&refs).len() as f32 * 53.0;
            }
        }
        series + seasons + 12.0 + 12.0
    }
}

fn numbers(count: usize, bytes: i64) -> String {
    let n = if count == 1 {
        "1 Folge".to_owned()
    } else {
        format!("{count} Folgen")
    };
    format!("{n} \u{00B7} {}", DownloadRules::size(bytes, ","))
}

fn line() -> Node {
    wide(
        Node::rect(color(colour::MARGIN), 0.0).frame(None, Some(1.0), Alignment::CENTER),
        Alignment::CENTER,
    )
}

/// The 22 pt box of a row: empty ring, accent disc with a minus (some) or a check (all), or the quiet check (already there).
fn box_image(icons: &Icons, k: CheckboxState) -> Node {
    let disc = |glyph: &str, pt: f32| {
        Node::rect(color(colour::MARK_ACCENT), 11.0)
            .frame(Some(22.0), Some(22.0), Alignment::CENTER)
            .overlay(
                icons.node(glyph, pt, false, color(colour::REASON)),
                Alignment::CENTER,
            )
    };
    let n = match k {
        CheckboxState::Empty => Node::rect(rgba(colour::FONT, 0.0), 11.0).paint(Paint::Stroke {
            color: color(colour::FONT_VERY_QUIET),
            width: 1.6,
            radius: 11.0,
        }),
        CheckboxState::Part => disc("minus", 12.0),
        CheckboxState::Full => disc("check", 11.0),
        CheckboxState::Present => icons.node("check", 15.0, false, color(colour::FONT_VERY_QUIET)),
    };
    n.frame(Some(22.0), Some(22.0), Alignment::CENTER)
        .opacity(1.0, feel::toggle())
}

#[allow(clippy::too_many_arguments)]
fn row(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    box_key: &str,
    open_key: &str,
    k: CheckboxState,
    title: &str,
    right: &str,
    small: bool,
    inset: f32,
    expanded: Option<bool>,
    quiet: bool,
) -> Node {
    let hit = box_image(icons, k);
    let value = match k {
        CheckboxState::Part => "teilweise",
        CheckboxState::Present => "geladen",
        _ => "",
    };
    let bx = if k == CheckboxState::Present {
        hit.a11y(A11yNode::new("", Role::Button, "Ausw\u{00E4}hlen").with_value(value))
    } else {
        forms::tappable(hit, f, box_key, 18.0)
            .press_style(PressStyle::Button)
            .a11y(
                A11yNode::new("", Role::Button, "Ausw\u{00E4}hlen")
                    .with_value(value)
                    .with_selected(k == CheckboxState::Full),
            )
    };
    let c = if k == CheckboxState::Present || quiet {
        colour::FONT_QUIET
    } else {
        colour::FONT
    };
    let mut parts = vec![
        plain(
            cx,
            title,
            if small { 14.0 } else { 15.0 },
            if small { 500 } else { 600 },
            c,
        ),
        Node::spacer(),
        mono(cx, right, 12.0, colour::FONT_VERY_QUIET),
    ];
    if let Some(open) = expanded {
        parts.push(
            icons
                .node(
                    if open { "caret-down" } else { "caret-right" },
                    13.0,
                    true,
                    color(colour::FONT_VERY_QUIET),
                )
                .a11y_hidden(),
        );
    }
    let main = forms::tappable(
        wide(
            Node::hstack(Align::Center, Some(10.0), parts),
            Alignment::LEADING,
        ),
        f,
        open_key,
        10.0,
    )
    .press_style(PressStyle::Row)
    .a11y(A11yNode::new("", Role::Button, title).with_value(right.to_owned()));
    // The episode row is 52 high, the season row one step above with 58.
    Node::hstack(Align::Center, Some(13.0), vec![bx, main])
        .padding(ins(0.0, inset, 0.0, 16.0))
        .flex_frame(swiftly_layout::FlexFrame {
            min_h: Some(if small { 52.0 } else { 58.0 }),
            align: Some(Alignment::LEADING),
            ..swiftly_layout::FlexFrame::default()
        })
}

fn series_right(s: &SeasonSheet) -> String {
    let all: Vec<&Item> = s.sel.all_episodes();
    if s.sel.loads {
        return "wird gelesen \u{2026}".to_owned();
    }
    if s.sel.state_all() == CheckboxState::Present {
        return "alles da".to_owned();
    }
    if !all.is_empty() && s.sel.visible(&all).is_empty() {
        return "alles gesehen".to_owned();
    }
    numbers(s.sel.takeable(&all).len(), s.sel.bytes_from(&all))
}

fn series_card(cx: &Cx, icons: &Icons, f: &Fm, s: &SeasonSheet) -> Node {
    let all: Vec<&Item> = s.sel.all_episodes();
    let k = s.sel.checkbox_state(&all, !s.sel.loads);
    let first = row(
        cx,
        icons,
        f,
        "sel.all",
        "sel.all",
        k,
        "Ganze Serie",
        &series_right(s),
        false,
        16.0,
        None,
        false,
    );
    let on = s.sel.only_unwatched;
    let switch = Node::hstack(
        Align::Center,
        Some(13.0),
        vec![
            plain(cx, "Nur ungesehene", 15.0, 600, colour::FONT),
            Node::spacer(),
            forms::toggle_switch_mac(on),
        ],
    );
    let switch = forms::tappable(wide(switch, Alignment::LEADING), f, "sel.onlyun", 10.0)
        .press_style(PressStyle::Row)
        .a11y(A11yNode::new("", Role::Switch, "Nur ungesehene").with_selected(on));
    let note = crate::home::text(
        cx,
        "Entscheidet, was ein Haken ausw\u{00E4}hlt.",
        swiftly_design::TextStyle {
            size: 12.0,
            weight: 400,
            tracking: 0.0,
            uppercase: false,
        },
        colour::FONT_VERY_QUIET,
        None,
        swiftly_text::Align::Start,
    );
    let toggle = Node::vstack(
        Align::Start,
        Some(3.0),
        vec![switch, wide(note, Alignment::LEADING)],
    )
    .padding(ins(12.0, 16.0, 12.0, 16.0));
    cardify(vec![first, line(), wide(toggle, Alignment::LEADING)])
}

fn cardify(rows: Vec<Node>) -> Node {
    wide(
        Node::vstack(Align::Start, Some(0.0), rows),
        Alignment::LEADING,
    )
    .background(Node::rect(color(colour::AREA), 14.0), Alignment::CENTER)
    .padding(ins(0.0, 16.0, 0.0, 16.0))
}

fn season_card(cx: &Cx, icons: &Icons, f: &Fm, s: &SeasonSheet) -> Node {
    let mut rows = Vec::new();
    for (nr, season) in s.seasons.iter().enumerate() {
        let list = s.episodes_of(&season.id);
        let refs: Vec<&Item> = list.iter().collect();
        let own = s.sel.visible(&refs);
        let k = s.sel.checkbox_state(&refs, true);
        let right =
            match s
                .sel
                .season_right(s.sel.episodes.get(&season.id).map(Vec::as_slice), &own, k)
            {
                SeasonRight::Reading => "wird gelesen \u{2026}".to_owned(),
                SeasonRight::Dash => "\u{2014}".to_owned(),
                SeasonRight::NoEpisodes => "Keine Folgen".to_owned(),
                SeasonRight::AllWatched => "alles gesehen".to_owned(),
                SeasonRight::AllThere => "alles da".to_owned(),
                SeasonRight::Count(n) => format!("{n} Folgen"),
            };
        let open = s.open.as_deref() == Some(season.id.as_str());
        rows.push(row(
            cx,
            icons,
            f,
            &format!("sel.box:{}", season.id),
            &format!("sel.open:{}", season.id),
            k,
            &season.name,
            &right,
            false,
            16.0,
            Some(open),
            false,
        ));
        if open {
            for e in &own {
                let stored = s.stored.get(&e.id);
                let state = if stored.is_some() {
                    CheckboxState::Present
                } else if s.sel.selected.contains(&e.id) {
                    CheckboxState::Full
                } else {
                    CheckboxState::Empty
                };
                let watched = e.user_data.as_ref().and_then(|d| d.played).unwrap_or(false);
                let size = DownloadRules::size(size_of(e), ",");
                let right = match stored {
                    Some(DownloadState::Done) => "geladen".to_owned(),
                    Some(DownloadState::Loads) => "l\u{00E4}dt".to_owned(),
                    Some(_) => "wartet".to_owned(),
                    None if watched => format!("gesehen \u{00B7} {size}"),
                    None => size,
                };
                let key = format!("sel.ep:{}", e.id);
                rows.push(line());
                // The episode rows come in with the leap curve (the height of the card does not animate in this engine).
                rows.push(
                    row(
                        cx, icons, f, &key, &key, state, &e.name, &right, true, 38.0, None, watched,
                    )
                    .appear_from(1.0, 0.0)
                    .opacity(1.0, feel::leap()),
                );
            }
        }
        if nr + 1 < s.seasons.len() {
            rows.push(line());
        }
    }
    cardify(rows)
}

fn footer(cx: &Cx, icons: &Icons, f: &Fm, s: &SeasonSheet) -> Node {
    let n = s.sel.selected.len();
    let bytes = s.sel.bytes();
    let left = if n == 0 {
        "Nichts gew\u{00E4}hlt".to_owned()
    } else {
        numbers(n, bytes)
    };
    let space = match s.sel.foot_space(s.free) {
        FootSpace::Free(rest) => mono(
            cx,
            &format!("Danach {} frei", DownloadRules::size(rest, ",")),
            12.0,
            colour::FONT_VERY_QUIET,
        ),
        FootSpace::Few(missing) => Node::hstack(
            Align::Center,
            Some(5.0),
            vec![
                icons
                    .node("info", 12.0, true, color(colour::ORIGINAL_WARNING))
                    .a11y_hidden(),
                mono(
                    cx,
                    &format!("{} zu wenig", DownloadRules::size(missing, ",")),
                    12.0,
                    colour::ORIGINAL_WARNING,
                ),
            ],
        ),
    };
    let head = Node::hstack(
        Align::Center,
        Some(10.0),
        vec![
            mono(cx, &left, 14.0, colour::FONT).frame(None, None, Alignment::LEADING),
            Node::spacer(),
            space,
        ],
    )
    .padding(ins(0.0, 16.0, 0.0, 16.0));
    let offered = s.sel.offered(s.select_quality);
    let quality = if offered.len() > 1 {
        mac_pick(
            cx,
            icons,
            "sparkle",
            "Qualit\u{00E4}t",
            &label(s.sel.quality),
            "sel.quality",
        )
    } else {
        wide(
            Node::hstack(
                Align::Center,
                Some(10.0),
                vec![
                    plain(cx, "Qualit\u{00E4}t", 15.0, 400, colour::FONT),
                    Node::spacer(),
                    mono(cx, &label(s.sel.quality), 15.0, colour::FONT_QUIET),
                ],
            )
            .padding(ins(5.0, 16.0, 5.0, 16.0)),
            Alignment::LEADING,
        )
    };
    let rules = TrackNames::german();
    let sound = s.sel.audio_offered(&rules).then(|| {
        mac_pick(
            cx,
            icons,
            "speaker-high",
            "Ton",
            &sound_label(&s.sel.audio_options(&rules), &s.sel.audio(&rules, "")),
            "sel.sound",
        )
    });
    let go = if n == 0 {
        "Laden".to_owned()
    } else if n == 1 {
        "1 Folge laden".to_owned()
    } else {
        format!("{n} Folgen laden")
    };
    let button =
        sheet_button(cx, icons, f, "sel.go", &go, n > 0).padding(ins(0.0, 16.0, 0.0, 16.0));
    let mut col = vec![line(), head, quality];
    col.extend(sound);
    col.push(button);
    Node::vstack(Align::Start, Some(10.0), col).padding(ins(4.0, 0.0, 12.0, 0.0))
}

fn season_content(cx: &Cx, icons: &Icons, env: &Env, s: &SeasonSheet) -> Node {
    let f = forms::fm(env);
    let title = wide(
        plain(cx, &s.series.name, 17.0, 600, colour::FONT).padding(ins(14.0, 16.0, 10.0, 16.0)),
        Alignment::LEADING,
    );
    let mut col = vec![title];
    if s.sel.disrupted && s.sel.all_episodes().is_empty() {
        let hint = crate::home::text(
            cx,
            "Der Server hat nicht geantwortet.",
            swiftly_design::TextStyle {
                size: 15.0,
                weight: 400,
                tracking: 0.0,
                uppercase: false,
            },
            colour::FONT_QUIET,
            None,
            swiftly_text::Align::Start,
        );
        col.push(wide(hint, Alignment::LEADING).padding(ins(0.0, 16.0, 10.0, 16.0)));
        col.push(
            sheet_button(cx, icons, &f, "sel.retry", "Erneut versuchen", true)
                .padding(ins(0.0, 16.0, 16.0, 16.0)),
        );
    } else {
        let body = Node::vstack(
            Align::Start,
            Some(12.0),
            vec![series_card(cx, icons, &f, s), season_card(cx, icons, &f, s)],
        )
        .padding(ins(0.0, 0.0, 12.0, 0.0));
        let h = s.content_h().clamp(58.0, 360.0);
        // The card grows and shrinks with the rows (`withAnimation(Theme.leap) { contentHeight = new }`).
        col.push(
            Node::scroll(Axis::Vertical, None, body)
                .key("season-scroll")
                .animated_frame(None, Some(h), Alignment::TOP_LEADING, feel::leap()),
        );
        col.push(footer(cx, icons, &f, s));
    }
    Node::vstack(Align::Start, Some(0.0), col)
}

/// The node of an open sheet: the dim scrim with the card in the middle, or, with an anchor, the card growing out of the
/// button's corner (`Leap`, scale 0.94) on a clear catcher. The card heights are estimates (the engine cannot measure a
/// child before layout); they only decide whether the card flips above the button.
pub(crate) fn sheet_node(cx: &Cx, icons: &Icons, env: &Env, s: &Sheet) -> Node {
    let (card, w, h) = match s {
        Sheet::Add(a) => (
            mac_load_panel(cx, icons, env, &a.spec, a.pick, a.sound_pick()),
            320.0,
            340.0,
        ),
        Sheet::Season(x) => (
            raised_card(season_content(cx, icons, env, x), 420.0, &x.series.name),
            420.0,
            235.0 + x.content_h().clamp(58.0, 360.0),
        ),
    };
    match s.anchor() {
        Some(r) => scrim_at(
            card,
            swiftly_ui::popover::place(
                Anchor::Button(r),
                Size::new(w, h),
                Rect::new(0.0, 0.0, env.size.w, env.size.h),
            ),
            env,
        ),
        None => scrim(card),
    }
}

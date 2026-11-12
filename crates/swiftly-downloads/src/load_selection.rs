//! The pure logic behind the series download sheet (`Sources/Shared/LoadSelection.swift`): what
//! a check selects, which qualities and audio choices are offered, the footer numbers, and how
//! the seasons are fetched. The view and the wording stay in the shells.

use std::collections::{HashMap, HashSet};

use swiftly_model::Item;
use swiftly_rules::download_audio::{
    self as audio, AudioTrackRules, DownloadAudioChoice, DownloadAudioOption,
};
use swiftly_rules::download_quality::DownloadQuality;

use crate::item::{audio_streams, first_source};
use crate::rules::{DownloadRules, FootSpace};

/// How many seasons are fetched at once (the server does not get seven requests at a time).
pub const SEASON_BATCH: usize = 3;

/// Four states: the three of the selection, and `Present` for what is already on the device and
/// can no longer be selected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckboxState {
    /// Nothing selected.
    Empty,
    /// Some selected.
    Part,
    /// All selectable selected.
    Full,
    /// Everything is already on the device.
    Present,
}

/// What the right side of a season row says (the wording is the shell's).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeasonRight {
    /// The season is still being read.
    Reading,
    /// Could not be read.
    Dash,
    /// The season has no episodes.
    NoEpisodes,
    /// Everything is watched ("Unwatched only" excluded it all).
    AllWatched,
    /// Everything is on the device.
    AllThere,
    /// This many episodes would still be taken.
    Count(usize),
}

/// The selection sheet's state.
#[derive(Debug, Clone)]
pub struct LoadSelection {
    /// Season ids in display order.
    pub seasons: Vec<String>,
    /// The episodes the series page already has, usually the selected season.
    pub preloaded: HashMap<String, Vec<Item>>,
    /// Episodes per season, as far as read.
    pub episodes: HashMap<String, Vec<Item>>,
    /// Selected episode ids.
    pub selected: HashSet<String>,
    /// Only unwatched episodes can be taken.
    pub only_unwatched: bool,
    /// Original, until someone picks something else.
    pub quality: DownloadQuality,
    /// `None` until someone picks: then the audio language from the settings applies.
    pub audio_chosen: Option<DownloadAudioChoice>,
    /// Still reading seasons.
    pub loads: bool,
    /// A season request failed: the selection must not stand empty without a note.
    pub disrupted: bool,
    /// Ids already in the download list (`model.downloads.entries(for:) != nil`).
    present: HashSet<String>,
}

impl LoadSelection {
    /// A fresh sheet.
    pub fn new(seasons: Vec<String>, preloaded: HashMap<String, Vec<Item>>) -> Self {
        Self {
            seasons,
            episodes: preloaded.clone(),
            preloaded,
            selected: HashSet::new(),
            only_unwatched: false,
            quality: DownloadQuality::Original,
            audio_chosen: None,
            loads: true,
            disrupted: false,
            present: HashSet::new(),
        }
    }

    /// Tell the sheet which ids are already in the download list.
    pub fn set_present(&mut self, ids: impl IntoIterator<Item = String>) {
        self.present = ids.into_iter().collect();
    }

    /// Whether the episode is already on the device.
    pub fn is_present(&self, id: &str) -> bool {
        self.present.contains(id)
    }

    /// Every episode read so far, in season order.
    pub fn all_episodes(&self) -> Vec<&Item> {
        self.seasons
            .iter()
            .filter_map(|s| self.episodes.get(s))
            .flatten()
            .collect()
    }

    fn watched(episode: &Item) -> bool {
        episode
            .user_data
            .as_ref()
            .and_then(|d| d.played)
            .unwrap_or(false)
    }

    /// What a check selects: without the toggle everything; with it only what is unwatched; what
    /// is already on the device never.
    pub fn takeable<'a>(&self, list: &[&'a Item]) -> Vec<&'a Item> {
        list.iter()
            .copied()
            .filter(|e| {
                !self.present.contains(&e.id) && (!self.only_unwatched || !Self::watched(e))
            })
            .collect()
    }

    /// With "Unwatched only", watched episodes are not there at all.
    pub fn visible<'a>(&self, list: &[&'a Item]) -> Vec<&'a Item> {
        list.iter()
            .copied()
            .filter(|e| !self.only_unwatched || !Self::watched(e))
            .collect()
    }

    /// The selected episodes in series order.
    pub fn selected_episodes(&self) -> Vec<&Item> {
        self.all_episodes()
            .into_iter()
            .filter(|e| self.selected.contains(&e.id))
            .collect()
    }

    fn size_of(episode: &Item) -> i64 {
        first_source(episode).and_then(|s| s.size).unwrap_or(0)
    }

    /// The footer calculates in the chosen quality.
    pub fn bytes(&self) -> i64 {
        self.bytes_in(self.quality)
    }

    /// Size of the selection in `q`: the real size for the original, otherwise the estimate.
    pub fn bytes_in(&self, q: DownloadQuality) -> i64 {
        self.selected_episodes()
            .iter()
            .map(|e| q.estimated_bytes(Self::size_of(e), e.run_time_ticks))
            .sum()
    }

    /// Which levels are offered: based on the best file in the selection, or the whole series
    /// while nothing is selected.
    pub fn offered(&self, selectable: bool) -> Vec<DownloadQuality> {
        let selected = self.selected_episodes();
        let base = if selected.is_empty() {
            self.all_episodes()
        } else {
            selected
        };
        let files: Vec<(i64, Option<i64>)> = base
            .iter()
            .map(|e| (Self::size_of(e), e.run_time_ticks))
            .collect();
        DownloadQuality::offered(selectable, DownloadQuality::source_bitrate_of(&files))
    }

    /// If the chosen level disappears because the selection got smaller, Original applies
    /// again, never a level that is no longer offered.
    pub fn reset_quality_if_gone(&mut self, selectable: bool) {
        if !self.offered(selectable).contains(&self.quality) {
            self.quality = DownloadQuality::Original;
        }
    }

    fn selected_streams(&self) -> Vec<Vec<swiftly_rules::download_audio::AudioStream>> {
        self.selected_episodes()
            .iter()
            .map(|e| audio_streams(first_source(e)))
            .collect()
    }

    /// Audio as languages, because the same language sits at a different index in every file.
    pub fn audio_options(&self, rules: &dyn AudioTrackRules) -> Vec<DownloadAudioOption> {
        audio::language_options(rules, &self.selected_streams())
    }

    /// Only offered when the selected files hold more than one language.
    pub fn audio_offered(&self, rules: &dyn AudioTrackRules) -> bool {
        audio::offered_for_selection(rules, &self.selected_streams())
    }

    /// The chosen language, or the one from the settings, or all tracks; never one the
    /// selection does not hold.
    pub fn audio(
        &self,
        rules: &dyn AudioTrackRules,
        preferred_language: &str,
    ) -> DownloadAudioChoice {
        let wished = self
            .audio_chosen
            .clone()
            .unwrap_or_else(|| DownloadAudioChoice::Language(preferred_language.to_owned()));
        if self.audio_offered(rules) && self.audio_options(rules).iter().any(|o| o.choice == wished)
        {
            wished
        } else {
            DownloadAudioChoice::All
        }
    }

    /// The footer's right side: free afterwards, or what is missing.
    pub fn foot_space(&self, free: i64) -> FootSpace {
        DownloadRules::foot_space(self.bytes(), free)
    }

    /// Right side of a season row: what a check there would still take. "All there" only when
    /// true.
    pub fn season_right(
        &self,
        all: Option<&[Item]>,
        visible: &[&Item],
        box_state: CheckboxState,
    ) -> SeasonRight {
        let Some(all) = all else {
            return if self.loads {
                SeasonRight::Reading
            } else {
                SeasonRight::Dash
            };
        };
        if all.is_empty() {
            return SeasonRight::NoEpisodes;
        }
        if visible.is_empty() {
            return SeasonRight::AllWatched;
        }
        if box_state == CheckboxState::Present {
            return SeasonRight::AllThere;
        }
        let free = self.takeable(visible);
        if free.is_empty() {
            SeasonRight::AllThere
        } else {
            SeasonRight::Count(free.len())
        }
    }

    /// The box of a group of episodes. While not every season is read the series is not
    /// "present" (`present_counts: false`).
    pub fn checkbox_state(&self, all: &[&Item], present_counts: bool) -> CheckboxState {
        let list = self.visible(all);
        if present_counts && !list.is_empty() && list.iter().all(|e| self.present.contains(&e.id)) {
            return CheckboxState::Present;
        }
        let free = self.takeable(&list);
        if free.is_empty() {
            return CheckboxState::Empty;
        }
        let on = free
            .iter()
            .filter(|e| self.selected.contains(&e.id))
            .count();
        if on == 0 {
            CheckboxState::Empty
        } else if on == free.len() {
            CheckboxState::Full
        } else {
            CheckboxState::Part
        }
    }

    /// The box of the whole series.
    pub fn state_all(&self) -> CheckboxState {
        self.checkbox_state(&self.all_episodes(), !self.loads)
    }

    /// Tap on a box: select what is free, or deselect it if it was all selected.
    pub fn toggle(&mut self, list: &[&Item]) {
        let free = self.takeable(list);
        if free.is_empty() {
            return;
        }
        let all_on = free.iter().all(|e| self.selected.contains(&e.id));
        let ids: Vec<String> = free.iter().map(|e| e.id.clone()).collect();
        for id in ids {
            if all_on {
                self.selected.remove(&id);
            } else {
                self.selected.insert(id);
            }
        }
    }

    /// After the toggle or a refresh: everything that can no longer be taken drops out.
    pub fn new_compute(&mut self) {
        let all = self.all_episodes();
        let allowed: HashSet<String> = self.takeable(&all).iter().map(|e| e.id.clone()).collect();
        self.selected.retain(|id| allowed.contains(id));
    }

    /// Size of what a check on `list` would still take.
    pub fn bytes_from(&self, list: &[&Item]) -> i64 {
        self.takeable(list).iter().map(|e| Self::size_of(e)).sum()
    }

    // MARK: Fetching the seasons

    /// Start reading: back to the preloaded seasons.
    pub fn begin_load(&mut self) {
        self.loads = true;
        self.disrupted = false;
        self.episodes = self.preloaded.clone();
    }

    /// The seasons still to fetch, in batches of [`SEASON_BATCH`] (at most three at once; with
    /// 20 seasons it used to be 20 round trips in a row).
    pub fn batches(&self) -> Vec<Vec<String>> {
        let open: Vec<String> = self
            .seasons
            .iter()
            .filter(|s| !self.episodes.contains_key(*s))
            .cloned()
            .collect();
        open.chunks(SEASON_BATCH).map(<[String]>::to_vec).collect()
    }

    /// One season's answer. `None` means failed, `Some(empty)` means empty: failed requests are
    /// not remembered, otherwise the empty list would later stand as fact.
    pub fn record_season(&mut self, season: &str, list: Option<Vec<Item>>) {
        match list {
            Some(list) => {
                self.episodes.insert(season.to_owned(), list);
            }
            None => self.disrupted = true,
        }
    }

    /// Reading is over: what was downloaded since the last open is no longer selectable.
    pub fn finish_load(&mut self) {
        self.loads = false;
        self.new_compute();
    }
}

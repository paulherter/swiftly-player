//! The series download sheet's state (`swiftly_downloads::load_selection::LoadSelection`):
//! checkbox tree, qualities, audio choice, footer verdict, the season fetch plan. The host draws
//! `LoadSheetState` and sends taps; the wording of the counts stays in the host. All calls are
//! plain (no I/O): the host fetches seasons itself and hands them to `record_season`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use swiftly_downloads::load_selection::{CheckboxState, LoadSelection, SeasonRight};
use swiftly_downloads::rules::FootSpace;
use swiftly_model::Item;
use swiftly_rules::download_audio::DownloadAudioChoice;
use swiftly_rules::download_quality::DownloadQuality;

use crate::downloads::TrackNames;
use crate::error::CoreError;

/// A season's episodes, the server's `Items` array as JSON.
#[derive(uniffi::Record, Clone, Debug)]
pub struct LoadSeasonEpisodes {
    pub season_id: String,
    pub episodes_json: String,
}

/// State of a check box.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoadCheck {
    Empty,
    Part,
    Full,
    /// Everything is on the device already.
    Present,
}

/// What a season row says on its right.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoadSeasonRight {
    Reading,
    Dash,
    NoEpisodes,
    AllWatched,
    AllThere,
    /// This many episodes would still be taken.
    Count {
        count: u32,
    },
}

/// The audio choice: all tracks, one stream index or one language key.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum LoadAudio {
    All,
    Track { index: i64 },
    Language { key: String },
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct LoadAudioOption {
    pub choice: LoadAudio,
    pub label: String,
}

/// What the footer says about space.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoadFoot {
    /// This much stays free.
    Free { bytes: i64 },
    /// This much is missing, reserve included.
    Few { bytes: i64 },
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct LoadEpisodeRow {
    pub id: String,
    pub title: String,
    pub season: Option<i64>,
    pub episode: Option<i64>,
    pub watched: bool,
    pub present: bool,
    pub selected: bool,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct LoadSeasonRow {
    pub season_id: String,
    pub check: LoadCheck,
    pub right: LoadSeasonRight,
    /// The episodes shown (the "unwatched only" switch applied).
    pub episodes: Vec<LoadEpisodeRow>,
}

/// Everything the sheet draws.
#[derive(uniffi::Record, Clone, Debug)]
pub struct LoadSheetState {
    pub all: LoadCheck,
    pub seasons: Vec<LoadSeasonRow>,
    pub selected_ids: Vec<String>,
    pub only_unwatched: bool,
    /// Raw values of the offered qualities (`original`, ...).
    pub qualities: Vec<String>,
    pub quality: String,
    pub audio_offered: bool,
    pub audio_options: Vec<LoadAudioOption>,
    pub audio: LoadAudio,
    /// Bytes of the selection in the chosen quality.
    pub bytes: i64,
    pub foot: LoadFoot,
    pub loads: bool,
    pub disrupted: bool,
}

fn parse(json: &str) -> Result<Vec<Item>, CoreError> {
    serde_json::from_str(json).map_err(|e| CoreError::Failed {
        message: e.to_string(),
    })
}

fn check(s: CheckboxState) -> LoadCheck {
    match s {
        CheckboxState::Empty => LoadCheck::Empty,
        CheckboxState::Part => LoadCheck::Part,
        CheckboxState::Full => LoadCheck::Full,
        CheckboxState::Present => LoadCheck::Present,
    }
}

fn audio_out(c: DownloadAudioChoice) -> LoadAudio {
    match c {
        DownloadAudioChoice::All => LoadAudio::All,
        DownloadAudioChoice::Track(index) => LoadAudio::Track { index },
        DownloadAudioChoice::Language(key) => LoadAudio::Language { key },
    }
}

fn audio_in(c: LoadAudio) -> DownloadAudioChoice {
    match c {
        LoadAudio::All => DownloadAudioChoice::All,
        LoadAudio::Track { index } => DownloadAudioChoice::Track(index),
        LoadAudio::Language { key } => DownloadAudioChoice::Language(key),
    }
}

/// The series download sheet.
#[derive(uniffi::Object)]
pub struct LoadSelectionModel {
    sel: Mutex<LoadSelection>,
    rules: TrackNames,
    audio_language: String,
    /// The quality picker is offered (a choice, not only the original).
    select_quality: bool,
}

impl LoadSelectionModel {
    fn lock(&self) -> MutexGuard<'_, LoadSelection> {
        self.sel.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[uniffi::export]
impl LoadSelectionModel {
    /// `season_ids` in display order; `preloaded` holds the episodes the page already has.
    /// `audio_language` is the settings' language key, `select_quality` whether the picker
    /// offers transcoded qualities.
    #[uniffi::constructor]
    pub fn new(
        season_ids: Vec<String>,
        preloaded: Vec<LoadSeasonEpisodes>,
        locale: String,
        audio_language: String,
        select_quality: bool,
    ) -> Result<Arc<Self>, CoreError> {
        let mut map = HashMap::new();
        for p in preloaded {
            map.insert(p.season_id, parse(&p.episodes_json)?);
        }
        let mut sel = LoadSelection::new(season_ids, map);
        if sel.batches().is_empty() {
            sel.finish_load();
        }
        Ok(Arc::new(Self {
            sel: Mutex::new(sel),
            rules: TrackNames::new(&locale),
            audio_language,
            select_quality,
        }))
    }

    /// Episode ids already on the device (cannot be selected).
    pub fn set_present(&self, ids: Vec<String>) {
        let mut s = self.lock();
        s.set_present(ids);
        s.new_compute();
    }
    pub fn set_only_unwatched(&self, on: bool) {
        let mut s = self.lock();
        s.only_unwatched = on;
        s.new_compute();
    }
    /// A raw quality value; one the sheet does not know is ignored.
    pub fn set_quality(&self, raw: String) {
        if let Some(q) = DownloadQuality::from_raw_value(&raw) {
            self.lock().quality = q;
        }
    }
    pub fn set_audio(&self, choice: LoadAudio) {
        self.lock().audio_chosen = Some(audio_in(choice));
    }
    /// Tap on a season's box (an unread season does nothing).
    pub fn toggle_season(&self, season_id: String) {
        let mut s = self.lock();
        let list: Vec<Item> = s.episodes.get(&season_id).cloned().unwrap_or_default();
        let refs: Vec<&Item> = list.iter().collect();
        let vis: Vec<&Item> = s.visible(&refs).into_iter().collect();
        s.toggle(&vis);
    }
    /// Tap on the box of the whole series.
    pub fn toggle_all(&self) {
        let mut s = self.lock();
        let all: Vec<Item> = s.all_episodes().into_iter().cloned().collect();
        let refs: Vec<&Item> = all.iter().collect();
        let vis: Vec<&Item> = s.visible(&refs).into_iter().collect();
        s.toggle(&vis);
    }
    /// Tap on one episode.
    pub fn toggle_episode(&self, episode_id: String) {
        let mut s = self.lock();
        let list: Vec<Item> = s
            .all_episodes()
            .into_iter()
            .filter(|e| e.id == episode_id)
            .cloned()
            .collect();
        let refs: Vec<&Item> = list.iter().collect();
        s.toggle(&refs);
    }
    /// Starts reading: the batches of season ids to fetch (three at a time).
    pub fn begin_load(&self) -> Vec<Vec<String>> {
        let mut s = self.lock();
        s.begin_load();
        s.batches()
    }
    /// One season arrived; `None` when its request failed.
    pub fn record_season(
        &self,
        season_id: String,
        episodes_json: Option<String>,
    ) -> Result<(), CoreError> {
        let list = match episodes_json {
            Some(j) => Some(parse(&j)?),
            None => None,
        };
        self.lock().record_season(&season_id, list);
        Ok(())
    }
    /// All batches are done.
    pub fn finish_load(&self) {
        self.lock().finish_load();
    }
    /// The sheet as it is drawn. `free` is the free space on the device; the quality is reset
    /// first when the selection no longer offers it.
    pub fn state(&self, free: i64) -> LoadSheetState {
        let mut s = self.lock();
        s.reset_quality_if_gone(self.select_quality);
        let all = s.all_episodes();
        let seasons = s
            .seasons
            .iter()
            .map(|id| {
                let own: Vec<&Item> = s
                    .episodes
                    .get(id)
                    .map(|l| l.iter().collect())
                    .unwrap_or_default();
                let vis = s.visible(&own);
                let k = s.checkbox_state(&own, true);
                let right = match s.season_right(s.episodes.get(id).map(Vec::as_slice), &vis, k) {
                    SeasonRight::Reading => LoadSeasonRight::Reading,
                    SeasonRight::Dash => LoadSeasonRight::Dash,
                    SeasonRight::NoEpisodes => LoadSeasonRight::NoEpisodes,
                    SeasonRight::AllWatched => LoadSeasonRight::AllWatched,
                    SeasonRight::AllThere => LoadSeasonRight::AllThere,
                    SeasonRight::Count(n) => LoadSeasonRight::Count { count: n as u32 },
                };
                let episodes = vis
                    .iter()
                    .map(|e| LoadEpisodeRow {
                        id: e.id.clone(),
                        title: e.name.clone(),
                        season: e.parent_index_number,
                        episode: e.index_number,
                        watched: e.user_data.as_ref().and_then(|d| d.played).unwrap_or(false),
                        present: s.is_present(&e.id),
                        selected: s.selected.contains(&e.id),
                    })
                    .collect();
                LoadSeasonRow {
                    season_id: id.clone(),
                    check: check(k),
                    right,
                    episodes,
                }
            })
            .collect();
        let all_state = check(s.checkbox_state(&all, !s.loads));
        let mut selected_ids: Vec<String> =
            s.selected_episodes().iter().map(|e| e.id.clone()).collect();
        selected_ids.sort();
        LoadSheetState {
            all: all_state,
            seasons,
            selected_ids,
            only_unwatched: s.only_unwatched,
            qualities: s
                .offered(self.select_quality)
                .iter()
                .map(|q| q.raw_value().to_owned())
                .collect(),
            quality: s.quality.raw_value().to_owned(),
            audio_offered: s.audio_offered(&self.rules),
            audio_options: s
                .audio_options(&self.rules)
                .into_iter()
                .map(|o| LoadAudioOption {
                    choice: audio_out(o.choice),
                    label: o.label,
                })
                .collect(),
            audio: audio_out(s.audio(&self.rules, &self.audio_language)),
            bytes: s.bytes(),
            foot: match s.foot_space(free) {
                FootSpace::Free(bytes) => LoadFoot::Free { bytes },
                FootSpace::Few(bytes) => LoadFoot::Few { bytes },
            },
            loads: s.loads,
            disrupted: s.disrupted,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S1: &str = r#"[{"Id":"e1","Name":"One","IndexNumber":1,"ParentIndexNumber":1,"MediaSources":[{"Id":"m","Size":1000}]},
        {"Id":"e2","Name":"Two","IndexNumber":2,"ParentIndexNumber":1,"UserData":{"Played":true},"MediaSources":[{"Id":"m","Size":2000}]}]"#;

    fn model() -> Arc<LoadSelectionModel> {
        LoadSelectionModel::new(
            vec!["s1".into(), "s2".into()],
            vec![LoadSeasonEpisodes {
                season_id: "s1".into(),
                episodes_json: S1.into(),
            }],
            "en".into(),
            "".into(),
            false,
        )
        .unwrap()
    }

    #[test]
    fn tree_selects_and_fetch_plan() {
        let m = model();
        assert_eq!(m.begin_load(), vec![vec!["s2".to_string()]]);
        assert_eq!(m.state(0).seasons[1].right, LoadSeasonRight::Reading);
        m.record_season("s2".into(), Some("[]".into())).unwrap();
        m.finish_load();
        let st = m.state(10_000_000_000);
        assert_eq!(st.seasons[1].right, LoadSeasonRight::NoEpisodes);
        assert_eq!(st.all, LoadCheck::Empty);
        m.toggle_season("s1".into());
        let st = m.state(10_000_000_000);
        assert_eq!(st.selected_ids, vec!["e1", "e2"]);
        assert_eq!(st.all, LoadCheck::Full);
        assert_eq!(st.bytes, 3000);
        assert!(matches!(st.foot, LoadFoot::Free { .. }));
        m.set_only_unwatched(true);
        assert_eq!(m.state(10_000_000_000).selected_ids, vec!["e1"]);
        m.set_present(vec!["e1".into()]);
        assert!(m.state(0).selected_ids.is_empty());
        assert!(m.state(0).seasons[0].episodes[0].present);
    }

    #[test]
    fn failed_season_and_bad_json() {
        let m = model();
        m.begin_load();
        m.record_season("s2".into(), None).unwrap();
        m.finish_load();
        assert!(m.state(0).disrupted);
        assert!(m.record_season("s2".into(), Some("x".into())).is_err());
    }
}

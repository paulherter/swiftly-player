//! Searching subtitles through the server and adding one to a title: ONE model for every host.
//!
//! The server's subtitle providers (a plugin such as OpenSubtitles) are asked for a language (default: the
//! subtitle language of the settings); the hits come as finished rows (name, format, provider, rating, downloads,
//! hearing-impaired flag). A press on a row sends [`SubtitleSearchIntent::Download`]: the server fetches the file, the
//! model waits until the track shows in the title's streams and reports the title's subtitle tracks again, so the host
//! reloads its player and menu. Every state is one value of [`SubtitleSearchPhase`]; the host draws it and keeps no
//! flags of its own. Texts are finished in the host's language. Plex has no such call: [`subtitle_search_offered`]
//! says no and the host hides the entry.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_jellyfin::RemoteSubtitle;
use swiftly_l10n::{Arg, Translator};
use swiftly_model::Item;
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_playback::track_rule::language_code;

use crate::account::AccountRef;
use crate::bell::{Bell, Changed};
use crate::home::{Client, build_client};
use crate::host::{Host, Sleeper};
use crate::language_names::language_name;
use crate::plex::is_plex;

/// Where the search stands. The host draws exactly this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubtitleSearchPhase {
    /// Nothing asked yet.
    Idle,
    /// The providers are being asked.
    Loading,
    /// There are hits to choose from.
    Results,
    /// The providers answered, but know nothing for this language.
    Empty,
    /// No subtitle provider is set up on the server.
    NoProvider,
    /// The request failed (offline, refused, unreadable); `message` says why.
    Failed,
    /// One hit is being downloaded by the server.
    Downloading,
    /// The track is on the title; `tracks` lists the title's subtitle tracks now.
    Done,
}

/// A language to search in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleLanguage {
    /// Sent back as `SubtitleSearchIntent::Search { language: Some(value) }` (a two-letter code).
    pub value: String,
    /// "Deutsch" in the interface language.
    pub label: String,
    /// This is the language of the running search.
    pub selected: bool,
}

/// One hit, finished for the screen.
#[derive(Debug, Clone, PartialEq)]
pub struct SubtitleHitRow {
    /// Sent back as `SubtitleSearchIntent::Download { id }`.
    pub id: String,
    /// The provider's file name.
    pub title: String,
    /// "SRT · OpenSubtitles".
    pub source_line: String,
    /// "Bewertung 8,2 · 1204 Downloads · Für Hörgeschädigte"; empty when there is nothing to say.
    pub meta_line: String,
    /// The rating as text ("8,2"), when the provider has one.
    pub rating: Option<String>,
    /// How often it was downloaded.
    pub downloads: Option<i64>,
    /// Made for the hard of hearing.
    pub hearing_impaired: bool,
    /// The provider matched it by the file's hash: the timing fits.
    pub matches_file: bool,
    /// This is the row being downloaded.
    pub busy: bool,
}

/// One subtitle track of the title, as the server lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleTrackRow {
    /// The stream index on the server.
    pub index: i64,
    /// What the track menu shows.
    pub label: String,
    /// Language code the file carries.
    pub language: Option<String>,
    /// A file next to the video (the ones this search adds).
    pub external: bool,
}

/// The whole screen state, versioned like every part.
#[derive(Debug, Clone, PartialEq)]
pub struct SubtitleSearchPart {
    /// Moves whenever the part changes.
    pub version: u64,
    /// The state.
    pub phase: SubtitleSearchPhase,
    /// Title of the page (catalog text in the host's language).
    pub title: String,
    /// The languages to pick from, the settings language first.
    pub languages: Vec<SubtitleLanguage>,
    /// The hits (in `Results` and `Downloading`).
    pub rows: Vec<SubtitleHitRow>,
    /// The sentence for `Empty`, `NoProvider`, `Failed` and `Done`; `None` otherwise.
    pub message: Option<String>,
    /// The title's subtitle tracks after a download (`Done`); empty before.
    pub tracks: Vec<SubtitleTrackRow>,
    /// How many tracks the download added (`Done`); 0 when the server has not shown the file yet.
    pub added: i64,
    /// The stream index of the track the download added (`Done`): the host switches it on when it reloads the title
    /// (as the subtitle of the order it starts the title with). `None` when the server has not shown the file yet.
    pub selected_track: Option<i64>,
}

/// What the host sends.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubtitleSearchIntent {
    /// Search; `None` is the language of the settings.
    Search {
        /// A value of [`SubtitleLanguage`].
        language: Option<String>,
    },
    /// Let the server download this hit ([`SubtitleHitRow::id`]).
    Download {
        /// The hit.
        id: String,
    },
}

/// The pause between two looks at the title while the server fetches and re-reads the file.
pub const POLL_SECONDS: f64 = 1.0;
/// How often the title is looked at after a download.
pub const POLL_TRIES: u32 = 10;
/// The most hits one search shows.
pub const MAX_ROWS: usize = 40;

/// Does this account's server have the call? Jellyfin and Emby do, Plex does not (the host hides the entry).
pub fn subtitle_search_offered(account: &AccountRef) -> bool {
    !is_plex(account)
}

/// The language code the server is asked with: the three-letter code of the usual languages (what the servers list),
/// else the two-letter code.
fn server_code(two: &str) -> String {
    const TABLE: &[(&str, &str)] = &[
        ("de", "deu"),
        ("en", "eng"),
        ("fr", "fra"),
        ("es", "spa"),
        ("it", "ita"),
        ("ja", "jpn"),
        ("ru", "rus"),
        ("pt", "por"),
        ("nl", "nld"),
        ("pl", "pol"),
        ("tr", "tur"),
        ("ko", "kor"),
        ("zh", "zho"),
        ("sv", "swe"),
        ("da", "dan"),
        ("fi", "fin"),
        ("cs", "ces"),
        ("el", "ell"),
        ("he", "heb"),
        ("ar", "ara"),
        ("hu", "hun"),
        ("uk", "ukr"),
    ];
    TABLE
        .iter()
        .find(|(short, _)| *short == two)
        .map_or_else(|| two.to_owned(), |(_, long)| (*long).to_owned())
}

/// The two-letter code of a subtitle language of the settings (a key such as "Deutsch", or the code the picker
/// stores); `None` for "as the file" (empty) and anything unknown.
fn setting_code(setting: &str) -> Option<String> {
    if setting.is_empty() {
        return None;
    }
    if let Some(code) = language_code(setting) {
        return Some(code);
    }
    let is_code = setting.len() == 2 && setting.bytes().all(|b| b.is_ascii_lowercase());
    is_code.then(|| setting.to_owned())
}

struct Live {
    generation: u64,
    code: String,
    languages: Vec<String>,
    hits: Vec<RemoteSubtitle>,
    part: Arc<SubtitleSearchPart>,
}

struct Inner<T: HttpTransport + 'static> {
    host: Host,
    sleeper: Arc<dyn Sleeper>,
    client: Arc<Client<T>>,
    item_id: String,
    translator: Translator,
    separator: &'static str,
    bell: Arc<Bell>,
    live: Mutex<Live>,
}

/// The subtitle search of one title. Cheap to clone (a handle).
pub struct SubtitleSearchVm<T: HttpTransport + 'static> {
    inner: Arc<Inner<T>>,
}

impl<T: HttpTransport + 'static> Clone for SubtitleSearchVm<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<T: HttpTransport + 'static> SubtitleSearchVm<T> {
    /// A search for the title `item_id`. `subtitle_language` is the settings value `utSprache`; empty (as the file)
    /// searches in the interface language.
    ///
    /// # Errors
    /// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address, or the account is a Plex
    /// one (the host asks [`subtitle_search_offered`] first and hides the entry).
    pub fn new(
        transport: Arc<T>,
        host: Host,
        sleeper: Arc<dyn Sleeper>,
        account: &AccountRef,
        item_id: &str,
        subtitle_language: &str,
    ) -> Result<Self, ErrorKind> {
        if !subtitle_search_offered(account) {
            return Err(ErrorKind::InvalidServerUrl);
        }
        let client = Arc::new(build_client(&transport, &host, account)?);
        let ui = host.locale.language().to_owned();
        let main = setting_code(subtitle_language).unwrap_or_else(|| ui.clone());
        let mut languages = vec![main.clone()];
        for extra in [ui.as_str(), "en"] {
            if !languages.iter().any(|l| l == extra) {
                languages.push(extra.to_owned());
            }
        }
        let separator = if matches!(ui.as_str(), "en") {
            "."
        } else {
            ","
        };
        let translator = Translator::new(host.locale.clone());
        let part = SubtitleSearchPart {
            version: 1,
            phase: SubtitleSearchPhase::Idle,
            title: translator.t("Untertitel suchen"),
            languages: Vec::new(),
            rows: Vec::new(),
            message: None,
            tracks: Vec::new(),
            added: 0,
            selected_track: None,
        };
        let vm = Self {
            inner: Arc::new(Inner {
                host,
                sleeper,
                client,
                item_id: item_id.to_owned(),
                translator,
                separator,
                bell: Bell::new(),
                live: Mutex::new(Live {
                    generation: 0,
                    code: main,
                    languages,
                    hits: Vec::new(),
                    part: Arc::new(part),
                }),
            }),
        };
        {
            let mut live = vm.inner.live();
            let languages = vm.inner.language_rows(&live);
            let mut part = SubtitleSearchPart::clone(&live.part);
            part.languages = languages;
            live.part = Arc::new(part);
        }
        Ok(vm)
    }

    /// The version; moves whenever the part changes.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The screen state.
    pub fn part(&self) -> Arc<SubtitleSearchPart> {
        Arc::clone(&self.inner.live().part)
    }

    /// Waits until the part is newer than `seen`.
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// Observers currently parked in [`Self::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// An intent from the view. Never blocks; the state is `Loading` / `Downloading` when it returns.
    pub fn send(&self, intent: SubtitleSearchIntent) {
        match intent {
            SubtitleSearchIntent::Search { language } => Inner::search(&self.inner, language),
            SubtitleSearchIntent::Download { id } => Inner::download(&self.inner, &id),
        }
    }
}

impl<T: HttpTransport + 'static> Inner<T> {
    fn live(&self) -> MutexGuard<'_, Live> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn language_rows(&self, live: &Live) -> Vec<SubtitleLanguage> {
        let ui = self.host.locale.language();
        live.languages
            .iter()
            .map(|code| SubtitleLanguage {
                value: code.clone(),
                label: language_name(code, ui).unwrap_or_else(|| code.clone()),
                selected: *code == live.code,
            })
            .collect()
    }

    /// Replaces the part and rings the bell once.
    fn put(
        &self,
        live: &mut Live,
        phase: SubtitleSearchPhase,
        rows: Vec<SubtitleHitRow>,
        message: Option<String>,
        tracks: Vec<SubtitleTrackRow>,
        added: i64,
    ) {
        let version = self.bell.bump(&[0]);
        live.part = Arc::new(SubtitleSearchPart {
            version,
            phase,
            title: live.part.title.clone(),
            languages: self.language_rows(live),
            rows,
            message,
            tracks,
            added,
            selected_track: None,
        });
    }

    fn row(&self, hit: &RemoteSubtitle, busy: bool) -> SubtitleHitRow {
        let rating = hit
            .community_rating
            .filter(|r| *r > 0.0)
            .map(|r| format!("{r:.1}").replace('.', self.separator));
        let downloads = hit.download_count.filter(|d| *d > 0);
        let mut meta = Vec::new();
        if let Some(r) = &rating {
            meta.push(
                self.translator
                    .t_args("Bewertung %@", &[Arg::Str(r.clone())]),
            );
        }
        if let Some(d) = downloads {
            meta.push(self.translator.t_args("%lld Downloads", &[Arg::Int(d)]));
        }
        if hit.hearing_impaired {
            meta.push(self.translator.t("Für Hörgeschädigte"));
        }
        if hit.is_hash_match {
            meta.push(self.translator.t("Passt zur Datei"));
        }
        let format = hit.format.to_uppercase();
        let source_line = [format.as_str(), hit.provider_name.as_str()]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join(" · ");
        SubtitleHitRow {
            id: hit.id.clone(),
            title: if hit.name.is_empty() {
                hit.provider_name.clone()
            } else {
                hit.name.clone()
            },
            source_line,
            meta_line: meta.join(" · "),
            rating,
            downloads,
            hearing_impaired: hit.hearing_impaired,
            matches_file: hit.is_hash_match,
            busy,
        }
    }

    fn search(self: &Arc<Self>, language: Option<String>) {
        let (generation, code) = {
            let mut live = self.live();
            if let Some(l) = language.filter(|l| live.languages.contains(l)) {
                live.code = l;
            }
            live.generation += 1;
            live.hits.clear();
            let generation = live.generation;
            let code = live.code.clone();
            self.put(
                &mut live,
                SubtitleSearchPhase::Loading,
                Vec::new(),
                None,
                Vec::new(),
                0,
            );
            (generation, code)
        };
        let inner = Arc::clone(self);
        let lost = Arc::clone(self);
        self.host.spawn_guarded(
            Box::pin(async move {
                let answer = inner
                    .client
                    .subtitle_search(&inner.item_id, &server_code(&code))
                    .await;
                let known = match &answer {
                    Ok(hits) if hits.is_empty() => inner.client.subtitle_provider_known().await,
                    _ => None,
                };
                inner.finish_search(generation, answer, known);
            }),
            move || {
                lost.finish_search(generation, Err(ErrorKind::Decoding("lost".into())), None);
            },
        );
    }

    fn finish_search(
        &self,
        generation: u64,
        answer: Result<Vec<RemoteSubtitle>, ErrorKind>,
        provider_known: Option<bool>,
    ) {
        let mut live = self.live();
        if live.generation != generation {
            return;
        }
        match answer {
            Err(error) => {
                let text = swiftly_l10n::error_text::readable_error(&self.translator, &error);
                self.put(
                    &mut live,
                    SubtitleSearchPhase::Failed,
                    Vec::new(),
                    Some(text),
                    Vec::new(),
                    0,
                );
            }
            Ok(hits) if hits.is_empty() => {
                // The server answers an empty list both for "no provider" and for "nothing found". A plugin that
                // looks like a provider makes it "nothing found"; anything else reads as "no provider".
                let (phase, key) = if provider_known == Some(true) {
                    (SubtitleSearchPhase::Empty, "Keine Untertitel gefunden.")
                } else {
                    (
                        SubtitleSearchPhase::NoProvider,
                        "Auf dem Server ist kein Untertitel-Anbieter eingerichtet.",
                    )
                };
                let text = self.translator.t(key);
                self.put(&mut live, phase, Vec::new(), Some(text), Vec::new(), 0);
            }
            Ok(mut hits) => {
                hits.sort_by(|a, b| {
                    b.is_hash_match
                        .cmp(&a.is_hash_match)
                        .then_with(|| {
                            b.community_rating
                                .unwrap_or(0.0)
                                .total_cmp(&a.community_rating.unwrap_or(0.0))
                        })
                        .then_with(|| {
                            b.download_count
                                .unwrap_or(0)
                                .cmp(&a.download_count.unwrap_or(0))
                        })
                });
                hits.truncate(MAX_ROWS);
                let rows = hits.iter().map(|h| self.row(h, false)).collect();
                live.hits = hits;
                self.put(
                    &mut live,
                    SubtitleSearchPhase::Results,
                    rows,
                    None,
                    Vec::new(),
                    0,
                );
            }
        }
    }

    fn download(self: &Arc<Self>, id: &str) {
        let generation = {
            let mut live = self.live();
            if live.part.phase != SubtitleSearchPhase::Results {
                return;
            }
            if !live.hits.iter().any(|h| h.id == id) {
                return;
            }
            live.generation += 1;
            let rows = live.hits.iter().map(|h| self.row(h, h.id == id)).collect();
            self.put(
                &mut live,
                SubtitleSearchPhase::Downloading,
                rows,
                None,
                Vec::new(),
                0,
            );
            live.generation
        };
        let inner = Arc::clone(self);
        let lost = Arc::clone(self);
        let id = id.to_owned();
        self.host.spawn_guarded(
            Box::pin(async move {
                let outcome = inner.fetch(&id).await;
                inner.finish_download(generation, outcome);
            }),
            move || lost.finish_download(generation, Err(ErrorKind::Decoding("lost".into()))),
        );
    }

    /// Downloads and waits until the track shows in the title's streams.
    async fn fetch(&self, id: &str) -> Result<(Vec<SubtitleTrackRow>, Option<i64>), ErrorKind> {
        let before: Vec<i64> = self
            .tracks()
            .await
            .map(|t| t.iter().map(|t| t.index).collect())
            .unwrap_or_default();
        self.client.subtitle_download(&self.item_id, id).await?;
        let mut latest = Vec::new();
        let mut new_track = None;
        for _ in 0..POLL_TRIES {
            self.sleeper.sleep(POLL_SECONDS).await;
            if let Ok(tracks) = self.tracks().await {
                // The new track is the one the title did not list before the download.
                new_track = tracks
                    .iter()
                    .find(|t| !before.contains(&t.index))
                    .map(|t| t.index);
                latest = tracks;
                if new_track.is_some() {
                    break;
                }
            }
        }
        Ok((latest, new_track))
    }

    /// The subtitle tracks of the title now.
    async fn tracks(&self) -> Result<Vec<SubtitleTrackRow>, ErrorKind> {
        let item = self.client.item(&self.item_id).await?;
        Ok(subtitle_tracks(&item))
    }

    fn finish_download(
        &self,
        generation: u64,
        outcome: Result<(Vec<SubtitleTrackRow>, Option<i64>), ErrorKind>,
    ) {
        let mut live = self.live();
        if live.generation != generation {
            return;
        }
        let rows: Vec<SubtitleHitRow> = live.hits.iter().map(|h| self.row(h, false)).collect();
        match outcome {
            Err(error) => {
                let text = swiftly_l10n::error_text::readable_error(&self.translator, &error);
                self.put(
                    &mut live,
                    SubtitleSearchPhase::Failed,
                    rows,
                    Some(text),
                    Vec::new(),
                    0,
                );
            }
            Ok((tracks, new_track)) => {
                let added = tracks.iter().filter(|t| t.external).count() as i64;
                let text = self.translator.t("Untertitel hinzugefügt.");
                self.put(
                    &mut live,
                    SubtitleSearchPhase::Done,
                    rows,
                    Some(text),
                    tracks,
                    added,
                );
                // Same state, same version: the choice is part of the answer, not a second change.
                Arc::make_mut(&mut live.part).selected_track = new_track;
            }
        }
    }
}

/// The subtitle tracks of a title as the server lists them now (the first media source).
pub fn subtitle_tracks(item: &Item) -> Vec<SubtitleTrackRow> {
    let Some(streams) = item
        .media_sources
        .as_ref()
        .and_then(|sources| sources.first())
        .and_then(|source| source.media_streams.as_ref())
    else {
        return Vec::new();
    };
    streams
        .iter()
        .filter(|s| s.type_.as_deref() == Some("Subtitle"))
        .map(|s| SubtitleTrackRow {
            index: s.index.unwrap_or(0),
            label: s
                .display_title
                .clone()
                .or_else(|| s.title.clone())
                .or_else(|| s.language.clone())
                .unwrap_or_default(),
            language: s.language.clone(),
            external: s.is_external.unwrap_or(false),
        })
        .collect()
}

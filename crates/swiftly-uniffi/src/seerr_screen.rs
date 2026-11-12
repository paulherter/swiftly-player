//! The Seerr add-on screens as one model: discover tiles from a search, the detail page of a title and the
//! request flow (a movie asks twice, a series picks seasons in a sheet). The words, the states and the
//! button logic are the core's (`SeerrVm`); the calls run over the same connection as [`SeerrModel`]. The
//! host sends intents and redraws when `version` changes.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use swiftly_l10n::Locale;
use swiftly_seerr::SeerrHit;
use swiftly_vm::{
    CONFIRM_STANDS_SECONDS, DiscoverPart, SeerrCast, SeerrEffect, SeerrIntent, SeerrPart,
    SeerrSeasonRow, SeerrTile, SeerrVm,
};

use crate::error::CoreError;
use crate::seerr::SeerrModel;

/// One tile of the discover rail.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SeerrTileInfo {
    /// The hit behind it (hand it to `open`).
    pub hit: SeerrHit,
    /// Poster path (TMDB).
    pub poster: Option<String>,
    /// The short word of the state on the tile ("wartet").
    pub short_word: Option<String>,
    /// The spoken text of the tile.
    pub announcement: String,
}

fn tile_info(t: &SeerrTile) -> SeerrTileInfo {
    SeerrTileInfo {
        hit: t.hit.clone(),
        poster: t.poster.clone(),
        short_word: t.short_word.clone(),
        announcement: t.announcement.clone(),
    }
}

/// The discover rail.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SeerrDiscoverInfo {
    /// Counts up with every change.
    pub version: u64,
    /// The term searched for.
    pub term: String,
    /// The tiles.
    pub tiles: Vec<SeerrTileInfo>,
}

fn discover_info(d: &DiscoverPart) -> SeerrDiscoverInfo {
    SeerrDiscoverInfo {
        version: d.version,
        term: d.term.clone(),
        tiles: d.tiles.iter().map(tile_info).collect(),
    }
}

/// A season row of the sheet.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SeerrSeasonInfo {
    /// Season number.
    pub number: i64,
    /// "Staffel 2".
    pub title: String,
    /// "12 Folgen".
    pub episodes: Option<String>,
    /// May be requested.
    pub requestable: bool,
    /// Ticked.
    pub selected: bool,
    /// A note ("schon da").
    pub note: Option<String>,
}

fn season_info(s: &SeerrSeasonRow) -> SeerrSeasonInfo {
    SeerrSeasonInfo {
        number: s.number,
        title: s.title.clone(),
        episodes: s.episodes.clone(),
        requestable: s.requestable,
        selected: s.selected,
        note: s.note.clone(),
    }
}

/// One cast member.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SeerrCastInfo {
    /// Name.
    pub name: String,
    /// Role.
    pub role: Option<String>,
    /// Image path (TMDB).
    pub image: Option<String>,
}

fn cast_info(c: &SeerrCast) -> SeerrCastInfo {
    SeerrCastInfo {
        name: c.name.clone(),
        role: c.role.clone(),
        image: c.image.clone(),
    }
}

/// The detail page.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SeerrPageInfo {
    /// Counts up with every change.
    pub version: u64,
    /// The hit.
    pub hit: SeerrHit,
    /// Backdrop path.
    pub backdrop: Option<String>,
    /// Year and kind.
    pub secondary_line: String,
    /// The word of the state.
    pub status_word: String,
    /// Rating.
    pub rating: Option<f64>,
    /// Description.
    pub description: Option<String>,
    /// Cast.
    pub cast: Vec<SeerrCastInfo>,
    /// Similar titles.
    pub similar: Vec<SeerrTileInfo>,
    /// The main button works.
    pub can_request: bool,
    /// Text of the main button.
    pub button_text: String,
    /// The button shows its confirmed look.
    pub button_checked: bool,
    /// A note under the button.
    pub note: Option<String>,
    /// A request is on its way.
    pub running: bool,
    /// The season sheet is open.
    pub sheet_open: bool,
    /// The season rows.
    pub seasons: Vec<SeerrSeasonInfo>,
    /// Text of the sheet's button.
    pub sheet_button: String,
    /// The sheet's button works.
    pub sheet_button_enabled: bool,
    /// The hint strip.
    pub error: Option<String>,
    /// The state changed under the page since it opened.
    pub disturbed: bool,
}

fn page_info(p: &SeerrPart) -> SeerrPageInfo {
    SeerrPageInfo {
        version: p.version,
        hit: p.hit.clone(),
        backdrop: p.backdrop.clone(),
        secondary_line: p.secondary_line.clone(),
        status_word: p.status_word.clone(),
        rating: p.rating,
        description: p.description.clone(),
        cast: p.cast.iter().map(cast_info).collect(),
        similar: p.similar.iter().map(tile_info).collect(),
        can_request: p.can_request,
        button_text: p.button_text.clone(),
        button_checked: p.button_checked,
        note: p.note.clone(),
        running: p.running,
        sheet_open: p.sheet_open,
        seasons: p.seasons.iter().map(season_info).collect(),
        sheet_button: p.sheet_button.clone(),
        sheet_button_enabled: p.sheet_button_enabled,
        error: p.error.clone(),
        disturbed: p.disturbed,
    }
}

struct Inner {
    vm: Mutex<SeerrVm>,
    model: Arc<SeerrModel>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Runs effects until none is left: each call goes over the connection and its answer is fed back as the
/// next intent. The confirm timer runs on its own task.
async fn drive(inner: &Arc<Inner>, first: Vec<SeerrEffect>) {
    let mut queue = std::collections::VecDeque::from(first);
    while let Some(effect) = queue.pop_front() {
        if effect == SeerrEffect::StartConfirmTimer {
            let weak = Arc::clone(inner);
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(CONFIRM_STANDS_SECONDS)).await;
                let _ = lock(&weak.vm).handle(SeerrIntent::ConfirmExpired);
            });
            continue;
        }
        if let Some(intent) = SeerrVm::run(effect, inner.model.client()).await {
            let more = lock(&inner.vm).handle(intent);
            queue.extend(more);
        }
    }
}

/// The Seerr screens of one connection.
#[derive(uniffi::Object)]
pub struct SeerrScreen {
    inner: Arc<Inner>,
}

impl SeerrScreen {
    fn effects(&self, intent: SeerrIntent) -> Vec<SeerrEffect> {
        lock(&self.inner.vm).handle(intent)
    }
}

#[uniffi::export]
impl SeerrScreen {
    /// The screens over a connection, with the words of `locale`.
    #[uniffi::constructor]
    pub fn new(model: Arc<SeerrModel>, locale: String) -> Arc<Self> {
        Arc::new(Self {
            inner: Arc::new(Inner {
                vm: Mutex::new(SeerrVm::new(Locale::parse(&locale))),
                model,
            }),
        })
    }

    /// The discover rail.
    pub fn discover(&self) -> SeerrDiscoverInfo {
        discover_info(lock(&self.inner.vm).discover())
    }

    /// The open detail page, if any.
    pub fn page(&self) -> Option<SeerrPageInfo> {
        lock(&self.inner.vm).page().map(page_info)
    }

    /// Searches (also the discover rail); returns when the answer is in.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn search(&self, term: String) -> Result<(), CoreError> {
        let effects = self.effects(SeerrIntent::Search(term));
        drive(&self.inner, effects).await;
        Ok(())
    }

    /// Opens a tile; returns when the detail is in.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn open(&self, hit: SeerrHit) -> Result<(), CoreError> {
        let effects = self.effects(SeerrIntent::Open(hit));
        drive(&self.inner, effects).await;
        Ok(())
    }

    /// The main button; `roll` is any number that picks one of the other wordings of the second tap.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn press(&self, roll: u32) -> Result<(), CoreError> {
        let effects = self.effects(SeerrIntent::Press {
            roll: roll as usize,
        });
        drive(&self.inner, effects).await;
        Ok(())
    }

    /// The sheet's button.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn confirm_seasons(&self) -> Result<(), CoreError> {
        let effects = self.effects(SeerrIntent::ConfirmSeasons);
        drive(&self.inner, effects).await;
        Ok(())
    }

    /// A season row was tapped.
    pub fn toggle_season(&self, number: i64) {
        self.effects(SeerrIntent::ToggleSeason(number));
    }

    /// The sheet was closed without asking.
    pub fn close_sheet(&self) {
        self.effects(SeerrIntent::CloseSheet);
    }

    /// The hint strip was dismissed.
    pub fn dismiss_error(&self) {
        self.effects(SeerrIntent::DismissError);
    }

    /// Seconds the second tap of a movie stays open before the question is asked again.
    pub fn confirm_stands_seconds(&self) -> u64 {
        CONFIRM_STANDS_SECONDS
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::seerr::SeerrConnection;
    use crate::transport::{CoreTransport, HttpClient, HttpFailure, NetRequest, NetResponse};

    const SEARCH: &str = r#"{"results":[
      {"id":2,"mediaType":"tv","name":"The Lighthouse","firstAirDate":"2008-09-23","posterPath":"/def.jpg"},
      {"id":4,"mediaType":"person","name":"Simon Baker"}]}"#;
    const DETAIL: &str = r#"{"overview":"Text","genres":[{"name":"Krimi"}],"voteAverage":8.1,
      "seasons":[{"seasonNumber":1,"episodeCount":10},{"seasonNumber":2,"episodeCount":12}]}"#;

    struct Fake;
    #[async_trait::async_trait]
    impl HttpClient for Fake {
        async fn send(&self, request: NetRequest) -> Result<NetResponse, HttpFailure> {
            let body = if request.url.contains("/search") {
                SEARCH
            } else {
                DETAIL
            };
            Ok(NetResponse {
                status: 200,
                headers: Vec::new(),
                body: body.as_bytes().to_vec(),
                url: None,
            })
        }
    }

    #[tokio::test]
    async fn search_open_and_pick_seasons() {
        let transport = CoreTransport::new(Arc::new(Fake));
        let connection = SeerrConnection {
            address: "https://seerr.test".into(),
            cookie: "connect.sid=x".into(),
            headers: Vec::new(),
        };
        let screen = SeerrScreen::new(SeerrModel::build(transport, connection, None), "de".into());
        screen.search("Lighthouse".into()).await.unwrap();
        let rail = screen.discover();
        assert_eq!(rail.term, "Lighthouse");
        assert_eq!(rail.tiles.len(), 1, "people are left out");
        assert!(screen.page().is_none());
        screen.open(rail.tiles[0].hit.clone()).await.unwrap();
        let page = screen.page().expect("page");
        assert_eq!(page.rating, Some(8.1));
        screen.press(0).await.unwrap();
        let sheet = screen.page().expect("page");
        assert!(sheet.sheet_open, "a series opens the season sheet");
        assert_eq!(sheet.seasons.len(), 2);
        screen.toggle_season(1);
        assert!(
            screen
                .page()
                .is_some_and(|p| p.seasons.iter().any(|s| s.selected))
        );
        screen.close_sheet();
        assert!(screen.page().is_some_and(|p| !p.sheet_open));
    }
}

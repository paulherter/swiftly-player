//! One Seerr title page with its request sheet over a hub: the page of a title that is not on the
//! server, the season picker of a library series, the request sheet of both. The host sends intents
//! and reads `info()`; the calls run in `swiftly_vm::SeerrTitleScreen`, the one implementation the
//! desktop apps use too. This object only exports it: a second copy of the page's reads here once
//! skipped the request choices' prefetch, so the sheet opened without its values on every Apple host.

use std::sync::Arc;

use swiftly_vm::{SeerrSeasonRowInfo, SeerrSheetInfo, SeerrTitleInfo};

use crate::error::CoreError;
use crate::seerr::JarAdapter;
use crate::seerr_lists_screen::SeerrHub;
use crate::transport::CoreTransport;

/// How a request ended, for the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SeerrRequestResult {
    /// Nothing was sent (the button was not pressable).
    NotSent,
    /// It is in. `auto_approved`: no admin needed.
    Requested { auto_approved: bool },
    /// Somebody asked before; the page now reads "Angefragt".
    Exists,
    /// Refused; the sheet stays open and shows `message`.
    Failed { message: String },
}

impl From<swiftly_vm::SeerrRequestResult> for SeerrRequestResult {
    fn from(r: swiftly_vm::SeerrRequestResult) -> Self {
        match r {
            swiftly_vm::SeerrRequestResult::NotSent => Self::NotSent,
            swiftly_vm::SeerrRequestResult::Requested { auto_approved } => {
                Self::Requested { auto_approved }
            }
            swiftly_vm::SeerrRequestResult::Exists => Self::Exists,
            swiftly_vm::SeerrRequestResult::Failed { message } => Self::Failed { message },
        }
    }
}

/// The page and sheet of one title.
#[derive(uniffi::Object)]
pub struct SeerrTitleScreen {
    inner: Arc<swiftly_vm::SeerrTitleScreen<CoreTransport, JarAdapter>>,
}

#[uniffi::export]
impl SeerrTitleScreen {
    /// The page of `art` (`movie` / `tv`) and TMDB id over a hub.
    #[uniffi::constructor]
    pub fn new(hub: Arc<SeerrHub>, art: String, tmdb: i64) -> Arc<Self> {
        Arc::new(Self {
            inner: swiftly_vm::SeerrTitleScreen::new(Arc::clone(&hub.core), art, tmdb),
        })
    }

    /// The page now.
    pub fn info(&self) -> SeerrTitleInfo {
        self.inner.info()
    }

    /// The number of the season whose episodes the page lists: `picked` when that season has episodes, else the
    /// first one that has any (`None` when TMDB lists none). The one rule for every host
    /// (`SeerrTitleInfo::episode_season`); the choice itself stays the host's view state.
    pub fn episode_season(&self, picked: Option<i64>) -> Option<i64> {
        self.inner.info().episode_season(picked).map(|s| s.number)
    }

    /// The seasons of the library series (present on the server).
    pub fn set_library_seasons(&self, numbers: Vec<i64>) {
        self.inner.set_library_seasons(numbers);
    }

    /// The seasons for the picker of a library series: the library's and Seerr's, merged; missing
    /// ones are grey (`missing`) and a tap on them calls `open_sheet(Some(number))`.
    pub fn season_picker(&self) -> Vec<SeerrSeasonRowInfo> {
        self.inner.season_picker()
    }

    /// Reads the title, what is around it and the account (and, for an administrator, the request
    /// choices); returns when the page is there.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load(&self) -> Result<SeerrTitleInfo, CoreError> {
        Ok(self.inner.load().await)
    }

    /// Opens the request sheet at once and complete: the choices come from the page's prefetch; the
    /// quota line and choices not read yet fill in with `load_sheet`.
    pub fn open_sheet(&self, season: Option<i64>) -> SeerrSheetInfo {
        self.inner.open_sheet(season)
    }

    /// Reads the quota and (admin) the quality and folder choices for the open sheet.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_sheet(&self) -> Result<SeerrSheetInfo, CoreError> {
        Ok(self.inner.load_sheet().await)
    }

    /// A season row of the sheet was tapped.
    pub fn toggle(&self, number: i64) -> SeerrSheetInfo {
        self.inner.toggle(number)
    }

    /// "In 4K".
    pub fn set_four_k(&self, on: bool) -> SeerrSheetInfo {
        self.inner.set_four_k(on)
    }

    /// "Qualität": the id of the chosen option.
    pub fn choose_quality(&self, id: i64) -> SeerrSheetInfo {
        self.inner.choose_quality(id)
    }

    /// "Ordner": the path of the chosen option.
    pub fn choose_folder(&self, path: String) -> SeerrSheetInfo {
        self.inner.choose_folder(path)
    }

    /// The sheet was closed.
    pub fn close_sheet(&self) -> SeerrSheetInfo {
        self.inner.close_sheet()
    }

    /// The sheet's button: sends the request. On success the sheet closes and the page reads again;
    /// a refusal (limit, permission, blocked) comes back as `Failed` and stays in the sheet.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn confirm(&self) -> Result<SeerrRequestResult, CoreError> {
        Ok(self.inner.confirm().await.into())
    }

    /// Reads the page again (pull to refresh, a sheet that closed).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn refresh(&self) -> Result<SeerrTitleInfo, CoreError> {
        Ok(self.inner.refresh().await)
    }
}

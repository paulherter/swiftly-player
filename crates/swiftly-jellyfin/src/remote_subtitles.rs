//! Subtitles from the server's providers: search for a title in a language, ask the server to fetch one.
//!
//! `GET Items/{id}/RemoteSearch/Subtitles/{language}` lists what the providers (a plugin such as OpenSubtitles) know;
//! `POST Items/{id}/RemoteSearch/Subtitles/{subtitleId}` makes the server download one next to the file, after which the
//! track shows up in the title's media streams. Without a provider the first call answers an empty list.

use serde::Deserialize;
use swiftly_model::Lenient;
use swiftly_net::{ErrorKind, HttpTransport, Method};

use crate::client::{JellyfinClient, Query};
use crate::session::ServerKind;

/// One subtitle a provider offers (`RemoteSubtitleInfo`).
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct RemoteSubtitle {
    /// The id to download it with (`subtitleId`).
    pub id: String,
    /// The file name the provider gives it.
    pub name: String,
    /// The provider ("OpenSubtitles").
    pub provider_name: String,
    /// "srt", "ass", ...
    pub format: String,
    /// Three-letter language code of the file.
    #[serde(rename = "ThreeLetterISOLanguageName")]
    pub language: String,
    /// The uploader.
    pub author: Option<String>,
    /// The provider's rating (0 to 10), when it has one.
    pub community_rating: Option<f64>,
    /// How often it was downloaded, when the provider counts.
    pub download_count: Option<i64>,
    /// The provider matched it by the file's hash, so the timing fits for certain.
    pub is_hash_match: bool,
    /// For the hard of hearing (with sound descriptions).
    pub hearing_impaired: bool,
    /// Only the forced lines (foreign speech).
    pub forced: bool,
    /// Translated by a machine.
    pub machine_translated: bool,
    /// Translated by an AI.
    pub ai_translated: bool,
}

/// What the server answers for `GET Plugins` that matters here.
#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "PascalCase", default)]
struct PluginInfo {
    name: String,
    status: String,
}

impl<T: HttpTransport> JellyfinClient<T> {
    /// `GET Items/{id}/RemoteSearch/Subtitles/{language}`: what the providers offer for this title in `language`
    /// (a two- or three-letter code). An empty list means no provider knows one, or none is set up.
    pub async fn subtitle_search(
        &self,
        item_id: &str,
        language: &str,
    ) -> Result<Vec<RemoteSubtitle>, ErrorKind> {
        let q = Query::new().add("isPerfectMatch", "false");
        let list: Lenient<RemoteSubtitle> = self
            .send(self.get(
                &format!("Items/{item_id}/RemoteSearch/Subtitles/{language}"),
                &q,
            )?)
            .await?;
        Ok(list.0)
    }

    /// `POST Items/{id}/RemoteSearch/Subtitles/{subtitleId}`: the server downloads the file next to the title and
    /// refreshes it, so the new track appears in `Items/{id}` a moment later.
    pub async fn subtitle_download(
        &self,
        item_id: &str,
        subtitle_id: &str,
    ) -> Result<(), ErrorKind> {
        let req = self.request(
            &format!("Items/{item_id}/RemoteSearch/Subtitles/{subtitle_id}"),
            Method::Post,
            &Query::new(),
            None,
        )?;
        self.send_ignoring_body(req).await
    }

    /// Does the server have a plugin that looks like a subtitle provider (active, "subtitle" in its name)?
    /// `None` when the server does not tell (Emby, an answer that is not a plugin list, no right to ask).
    pub async fn subtitle_provider_known(&self) -> Option<bool> {
        if self.server_kind() != ServerKind::Jellyfin {
            return None;
        }
        let req = self.get("Plugins", &Query::new()).ok()?;
        let plugins: Lenient<PluginInfo> = self.send(req).await.ok()?;
        Some(plugins.0.iter().any(|p| {
            p.name.to_lowercase().contains("subtitle") && p.status.eq_ignore_ascii_case("Active")
        }))
    }
}

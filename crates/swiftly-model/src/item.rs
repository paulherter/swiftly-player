//! [`Item`] and its small companions (JellyfinKit/Models.swift:117-504,
//! ItemKind.swift).

use std::collections::HashMap;
use std::hash::{Hash, Hasher};

use serde::{Deserialize, Deserializer, Serialize};

use crate::l10n::{Localizer, Source};
use crate::media::MediaSource;
use crate::time::parse_timestamp;

/// A title, season, episode, folder or person as the server lists it
/// (Models.swift:117). Every field except `Id` and `Name` is optional; an
/// entry without them fails to decode (and is dropped by [`crate::Lenient`]).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Item {
    /// Server-wide unique id.
    pub id: String,
    /// Display name.
    pub name: String,
    /// `Movie`, `Series`, `Season`, `Episode`, `BoxSet` ... (raw, see [`Item::kind`]).
    #[serde(rename = "Type", skip_serializing_if = "Option::is_none")]
    pub type_: Option<String>,
    /// Library kind (`movies`, `tvshows` ...) on library entries.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collection_type: Option<String>,
    /// Year of production.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub production_year: Option<i64>,
    /// Description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overview: Option<String>,
    /// Runtime in 100 ns ticks.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub run_time_ticks: Option<i64>,
    /// Series context, for the line under the title in the player (Models.swift:125).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series_name: Option<String>,
    /// Episode number.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub index_number: Option<i64>,
    /// Season number.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub parent_index_number: Option<i64>,
    /// Series an episode belongs to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series_id: Option<String>,
    /// Season an episode belongs to (Models.swift:130).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub season_id: Option<String>,
    /// Genre names.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub genres: Option<Vec<String>>,
    /// Age rating text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub official_rating: Option<String>,
    /// Audience rating.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub community_rating: Option<f64>,
    /// Number of children. On `Items/Latest` series this counts new episodes, not seasons.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub child_count: Option<i64>,
    /// Trailers stored as a file on the server.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub local_trailer_count: Option<i64>,
    /// Tags of the backdrop images.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backdrop_image_tags: Option<Vec<String>>,
    /// Poster tag of the series (episodes only have a 16:9 thumbnail).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series_primary_image_tag: Option<String>,
    /// Cast and crew.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub people: Option<Vec<Person>>,
    /// Studios.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub studios: Option<Vec<NameId>>,
    /// Taglines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub taglines: Option<Vec<String>>,
    /// Critic rating.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub critic_rating: Option<f64>,
    /// Remote (web) trailers.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_trailers: Option<Vec<MediaUrl>>,
    /// Image type to tag.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_tags: Option<HashMap<String, String>>,
    /// Per-user state.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_data: Option<UserItemData>,
    /// File versions; absent on list entries, which means "not loaded yet".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_sources: Option<Vec<MediaSource>>,
    /// Backdrop tags of the series, delivered with every episode (Models.swift:151).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_backdrop_image_tags: Option<Vec<String>>,
    /// Which title the parent backdrop belongs to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_backdrop_item_id: Option<String>,
    /// Landscape thumbnail tag of the parent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_thumb_image_tag: Option<String>,
    /// Logo tag of the series.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_logo_image_tag: Option<String>,
    /// Which title the parent thumbnail belongs to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_thumb_item_id: Option<String>,
    /// For a person the birthday, otherwise the premiere date (text as sent).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub premiere_date: Option<String>,
    /// For a person the birthplace.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub production_locations: Option<Vec<String>>,
    /// `Tmdb`, `Imdb` ... to id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_ids: Option<HashMap<String, String>>,
    /// Language the title was made in; Jellyfin 12 and later (Models.swift:171).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_language: Option<String>,
    /// Kind of an extra; only on `SpecialFeatures` entries.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extra_type: Option<String>,
    /// `Video`, `Audio` ...
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_type: Option<String>,
    /// `FileSystem` for a title with a file, `Virtual` for a placeholder the server lists without one (a missing movie
    /// or episode); there is nothing to play then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub location_type: Option<String>,
    /// The name the server sorts by (Models.swift:179).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sort_name: Option<String>,
    /// When the title came onto the server (ISO 8601 text).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date_created: Option<String>,
}

/// Identity is the id only, as in Swift (Models.swift:404).
impl Hash for Item {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.id.hash(state);
    }
}

impl Item {
    /// An entry made of the bare minimum (Models.swift:344); use struct update
    /// syntax for more.
    pub fn new(id: impl Into<String>, name: impl Into<String>, type_: Option<&str>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            type_: type_.map(Into::into),
            ..Self::default()
        }
    }

    /// Names of the directors (Models.swift:231).
    pub fn direction(&self) -> Vec<&str> {
        self.people
            .iter()
            .flatten()
            .filter(|p| p.type_.as_deref() == Some("Director"))
            .map(|p| p.name.as_str())
            .collect()
    }

    /// Cast in order, without crew (Models.swift:236).
    pub fn actors(&self) -> Vec<&Person> {
        self.people
            .iter()
            .flatten()
            .filter(|p| p.is_cast())
            .collect()
    }

    /// Series, season or collection; has no media file of its own (Models.swift:241).
    pub fn is_container(&self) -> bool {
        matches!(
            self.type_.as_deref().unwrap_or(""),
            "Series" | "Season" | "BoxSet" | "Folder" | "CollectionFolder"
        )
    }

    /// "S1 · F3" (Models.swift:251), German source text. See [`Item::episode_code_with`].
    pub fn episode_code(&self) -> Option<String> {
        self.episode_code_with(&Source)
    }

    /// As [`Item::episode_code`] through a localizer. Key `"S%lld · F%lld"`
    /// with `[season, episode]`; `None` unless both numbers exist.
    pub fn episode_code_with(&self, l: &dyn Localizer) -> Option<String> {
        let (season, episode) = (self.parent_index_number?, self.index_number?);
        Some(l.text("S%lld · F%lld", &[season, episode]))
    }

    /// Fraction already watched, 0 to 1, for progress bars (Models.swift:261).
    pub fn watched_share(&self) -> Option<f64> {
        let percent = self.user_data.as_ref()?.played_percentage?;
        (percent > 0.0).then(|| percent / 100.0)
    }

    /// Whether the user has played it (Models.swift:266).
    pub fn is_watched(&self) -> bool {
        self.user_data
            .as_ref()
            .and_then(|d| d.played)
            .unwrap_or(false)
    }

    /// Second line for "Recently added" (Models.swift:273), German source text.
    pub fn new_arrivals_row(&self) -> Option<String> {
        self.new_arrivals_row_with(&Source)
    }

    /// As [`Item::new_arrivals_row`] through a localizer. Keys `"Staffel %lld"`,
    /// `"Folge %lld"`, `"%lld neue Folgen"`.
    pub fn new_arrivals_row_with(&self, l: &dyn Localizer) -> Option<String> {
        let year = || self.production_year.map(|y| y.to_string());
        match self.type_.as_deref() {
            // The season, not the episode (Models.swift:276-281).
            Some("Episode") => {
                if let Some(season) = self.parent_index_number {
                    return Some(l.text("Staffel %lld", &[season]));
                }
                self.index_number
                    .map(|episode| l.text("Folge %lld", &[episode]))
            }
            // Without a number the name carries the meaning (Models.swift:283-285).
            Some("Season") => Some(match self.index_number {
                Some(n) => l.text("Staffel %lld", &[n]),
                None => self.name.clone(),
            }),
            // `ChildCount` counts new episodes here, not seasons (Models.swift:287-298).
            Some("Series") => match self.child_count {
                Some(count) if count > 0 => Some(l.text("%lld neue Folgen", &[count])),
                _ => year(),
            },
            _ => year(),
        }
    }

    /// A series the server still lists but that has no seasons left (its files were deleted).
    /// Only a stated count of 0 counts: a missing count means "not asked", never "empty".
    pub fn is_hollow_series(&self) -> bool {
        self.type_.as_deref() == Some("Series") && self.child_count == Some(0)
    }

    /// "S1 • F3 • 21 Jump Street"; for a film the year (Models.swift:310),
    /// German source text.
    pub fn context_line(&self) -> Option<String> {
        self.context_line_with(&Source)
    }

    /// As [`Item::context_line`] through a localizer. Keys `"S%lld"`, `"F%lld"`.
    pub fn context_line_with(&self, l: &dyn Localizer) -> Option<String> {
        let mut parts: Vec<String> = Vec::new();
        if let Some(season) = self.parent_index_number {
            parts.push(l.text("S%lld", &[season]));
        }
        if let Some(episode) = self.index_number {
            parts.push(l.text("F%lld", &[episode]));
        }
        if let Some(series) = &self.series_name {
            parts.push(series.clone());
        }
        if parts.is_empty()
            && self.type_.as_deref() == Some("Movie")
            && let Some(year) = self.production_year
        {
            parts.push(year.to_string());
        }
        (!parts.is_empty()).then(|| parts.join(" • "))
    }

    /// Runtime in seconds; Jellyfin counts in 100 ns ticks (Models.swift:320).
    pub fn runtime_seconds(&self) -> Option<f64> {
        self.run_time_ticks.map(|t| t as f64 / 10_000_000.0)
    }

    /// A provisional series built from what an episode carries anyway
    /// (Models.swift:338). `None` if the episode names no series.
    pub fn pre_common_series(episode: &Item) -> Option<Item> {
        let id = episode.series_id.clone()?;
        let name = episode.series_name.clone()?;
        Some(Item::new(id, name, Some("Series")))
    }

    /// The interface-level kind (ItemKind.swift:31).
    pub fn kind(&self) -> ItemKind {
        ItemKind::from_type(self.type_.as_deref())
    }
}

/// The kind of a title in terms the interface can switch over
/// (JellyfinKit/ItemKind.swift:6). Unknown server strings are [`ItemKind::Other`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ItemKind {
    /// `Movie`
    Movie,
    /// `Series`
    Series,
    /// `Season`
    Season,
    /// `Episode`
    Episode,
    /// `BoxSet`
    Collection,
    /// `Playlist`
    Playlist,
    /// Libraries and plain folders (`CollectionFolder`, `UserView`, `Folder`).
    Folder,
    /// Anything else, including `None`.
    Other,
}

impl ItemKind {
    /// Map the server's `Type` string (ItemKind.swift:17).
    pub fn from_type(type_: Option<&str>) -> Self {
        match type_ {
            Some("Movie") => Self::Movie,
            Some("Series") => Self::Series,
            Some("Season") => Self::Season,
            Some("Episode") => Self::Episode,
            Some("BoxSet") => Self::Collection,
            Some("Playlist") => Self::Playlist,
            Some("CollectionFolder" | "UserView" | "Folder") => Self::Folder,
            _ => Self::Other,
        }
    }
}

/// Per-user state of an item (Models.swift:408).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct UserItemData {
    /// Resume position in ticks.
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub playback_position_ticks: Option<i64>,
    /// Watched.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub played: Option<bool>,
    /// Favourite.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_favorite: Option<bool>,
    /// Watched percentage, limited to 0..=100 on decoding (Models.swift:455-472):
    /// the tiles turn it into an integer and a broken server runtime used to
    /// crash them. A non-finite value becomes `None`.
    #[serde(
        default,
        deserialize_with = "clamp_percentage",
        skip_serializing_if = "Option::is_none"
    )]
    pub played_percentage: Option<f64>,
    /// How many episodes of a series are still unwatched (Models.swift:413).
    #[serde(
        default,
        deserialize_with = "crate::lenient::whole_number",
        skip_serializing_if = "Option::is_none"
    )]
    pub unplayed_item_count: Option<i64>,
    /// `LastPlayedDate` as the server sends it, text (Models.swift:419).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_played_date: Option<String>,
}

fn clamp_percentage<'de, D: Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
    Ok(Option::<f64>::deserialize(d)?.and_then(|v| v.is_finite().then(|| v.clamp(0.0, 100.0))))
}

impl UserItemData {
    /// When last played, seconds since 1970 UTC, for "newer state wins"
    /// (Models.swift:439).
    pub fn last_play(&self) -> Option<f64> {
        parse_timestamp(self.last_played_date.as_deref()?)
    }
}

/// A contributor (Models.swift:476). `role` is the role in the film, `type_`
/// the function (Actor, Director, Writer ...).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Person {
    /// Person id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Role played.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// Function: `Actor`, `Director` ...
    #[serde(rename = "Type", skip_serializing_if = "Option::is_none")]
    pub type_: Option<String>,
    /// Tag of the portrait.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary_image_tag: Option<String>,
}

impl Person {
    /// Whether this is a cast member (Models.swift:491).
    pub fn is_cast(&self) -> bool {
        self.type_.as_deref() == Some("Actor")
    }
}

/// An id and a name, both optional (Models.swift:494).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct NameId {
    /// Id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// A trailer link (Models.swift:500).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct MediaUrl {
    /// Address.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Label.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

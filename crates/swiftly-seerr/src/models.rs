//! Models. Persisted JSON keys are the German ones of the Swift `CodingKeys`.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use swiftly_jellyfin::{OwnHeader, OwnHeaders};

/// `MediaStatus` of the API (`SeerrState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SeerrState {
    /// 1: nothing requested yet.
    Opened,
    /// 2: waits for approval.
    WaitsSharing,
    /// 3: being fetched.
    Loads,
    /// 4: partly available.
    PartWayPresent,
    /// 5: available.
    Present,
    /// 6: deleted.
    Deleted,
}

impl SeerrState {
    /// The API number.
    pub fn raw(self) -> i64 {
        match self {
            Self::Opened => 1,
            Self::WaitsSharing => 2,
            Self::Loads => 3,
            Self::PartWayPresent => 4,
            Self::Present => 5,
            Self::Deleted => 6,
        }
    }

    /// `SeerrState(rawValue:)`.
    pub fn from_raw(raw: i64) -> Option<Self> {
        Some(match raw {
            1 => Self::Opened,
            2 => Self::WaitsSharing,
            3 => Self::Loads,
            4 => Self::PartWayPresent,
            5 => Self::Present,
            6 => Self::Deleted,
            _ => return None,
        })
    }

    /// Can be requested (again).
    pub fn requestable(self) -> bool {
        matches!(self, Self::Opened | Self::Deleted | Self::PartWayPresent)
    }

    /// Is fully there.
    pub fn already_present(self) -> bool {
        self == Self::Present
    }
}

impl Serialize for SeerrState {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_i64(self.raw())
    }
}

impl<'de> Deserialize<'de> for SeerrState {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = i64::deserialize(d)?;
        Self::from_raw(raw).ok_or_else(|| serde::de::Error::custom("unknown Seerr state"))
    }
}

fn tmdb(path: Option<&str>, width: u32) -> Option<String> {
    let path = path.filter(|p| !p.is_empty())?;
    Some(format!("https://image.tmdb.org/t/p/w{width}{path}"))
}

/// A search or suggestion hit.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SeerrHit {
    /// TMDB id.
    pub id: i64,
    /// `movie` or `tv`.
    pub art: String,
    /// Title.
    #[serde(rename = "titel")]
    pub title: String,
    /// Release year.
    #[serde(rename = "jahr", default)]
    pub year: Option<i64>,
    /// Poster path on TMDB.
    #[serde(rename = "plakatPfad", default)]
    pub poster_path: Option<String>,
    /// Backdrop path on TMDB.
    #[serde(rename = "kulissePfad", default)]
    pub backdrop_path: Option<String>,
    /// State.
    #[serde(rename = "stand")]
    pub state: SeerrState,
}

impl SeerrHit {
    /// Series, not film.
    pub fn is_series(&self) -> bool {
        self.art == "tv"
    }

    /// Poster address on TMDB (default width 342).
    pub fn poster(&self, width: u32) -> Option<String> {
        tmdb(self.poster_path.as_deref(), width)
    }

    /// Backdrop address (default width 780); never falls back to the poster.
    pub fn backdrop(&self, width: u32) -> Option<String> {
        tmdb(self.backdrop_path.as_deref(), width)
    }
}

/// A cast member.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SeerrPerson {
    /// TMDB id.
    pub id: i64,
    /// Name.
    pub name: String,
    /// Character.
    #[serde(rename = "rolle", default)]
    pub role: Option<String>,
    /// Profile image path.
    #[serde(rename = "bildPfad", default)]
    pub image_path: Option<String>,
}

impl SeerrPerson {
    /// Portrait address (default width 185).
    pub fn image(&self, width: u32) -> Option<String> {
        tmdb(self.image_path.as_deref(), width)
    }
}

/// A season with its state.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SeerrSeason {
    /// Season number (1...).
    #[serde(rename = "nummer")]
    pub number: i64,
    /// Episode count.
    #[serde(rename = "folgen")]
    pub episodes: i64,
    /// State.
    #[serde(rename = "stand")]
    pub state: SeerrState,
}

impl SeerrSeason {
    /// Season 0.
    pub fn is_specials(&self) -> bool {
        self.number == 0
    }
}

/// Detail of a film or series.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SeerrDetail {
    /// Overview, trimmed; `None` when empty.
    #[serde(rename = "beschreibung")]
    pub description: Option<String>,
    /// At most two genres.
    pub genres: Vec<String>,
    /// Minutes.
    #[serde(rename = "laufzeit")]
    pub runtime: Option<i64>,
    /// TMDB vote average.
    #[serde(rename = "bewertung")]
    pub rating: Option<f64>,
    /// Seasons without specials.
    #[serde(rename = "staffeln")]
    pub seasons: Vec<SeerrSeason>,
    /// At most twenty cast members.
    #[serde(rename = "besetzung")]
    pub cast: Vec<SeerrPerson>,
    /// Suggestions (filled by a separate fetch).
    #[serde(rename = "aehnliches")]
    pub similar_one: Vec<SeerrHit>,
    /// State of the title.
    #[serde(rename = "stand")]
    pub state: Option<SeerrState>,
}

impl SeerrDetail {
    /// The same detail with other suggestions.
    #[must_use]
    pub fn with_similar_one(mut self, new: Vec<SeerrHit>) -> Self {
        self.similar_one = new;
        self
    }
}

/// The stored connection: address, session cookie (`name=value`), own headers.
/// JSON keys `adresse`, `keks`, `koepfe` (omitted when empty).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeerrAccess {
    /// Base address without `/api`.
    pub address: String,
    /// Cookie header value.
    pub cookie: String,
    /// The user's own headers (cleaned).
    pub headers: Vec<OwnHeader>,
}

impl SeerrAccess {
    /// Builds an access; headers are cleaned like `OwnHeaders.cleaned`.
    pub fn new(address: &str, cookie: &str, headers: &[OwnHeader]) -> Self {
        Self {
            address: address.to_string(),
            cookie: cookie.to_string(),
            headers: OwnHeaders::cleaned(headers),
        }
    }
}

#[derive(Serialize, Deserialize)]
struct AccessWire {
    #[serde(rename = "adresse")]
    address: String,
    #[serde(rename = "keks")]
    cookie: String,
    #[serde(rename = "koepfe", default, skip_serializing_if = "Vec::is_empty")]
    headers: Vec<OwnHeader>,
}

impl Serialize for SeerrAccess {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        AccessWire {
            address: self.address.clone(),
            cookie: self.cookie.clone(),
            headers: self.headers.clone(),
        }
        .serialize(s)
    }
}

impl<'de> Deserialize<'de> for SeerrAccess {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let w = AccessWire::deserialize(d)?;
        // The Swift decoder takes headers as stored (no cleaning on read).
        Ok(Self {
            address: w.address,
            cookie: w.cookie,
            headers: w.headers,
        })
    }
}

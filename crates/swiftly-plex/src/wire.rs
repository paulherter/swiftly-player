//! The answers of a Plex server as they arrive on the wire (`Accept: application/json`),
//! ported from `PlexWire.swift`.
//!
//! **Every field is optional and read leniently** ([`crate::loose`]). A field that fails to
//! decode would take the whole list down with it, so nothing here fails for a single odd
//! value; only the few fields the Swift decoders `guard` on make an entry unreadable, and
//! such an entry is skipped by its list.

use serde_json::Value;
use swiftly_net::ErrorKind;

use crate::loose;

/// A tag on a title: genre, country, studio, person (PlexWire.swift:56).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexTag {
    /// The tag's id.
    pub id: Option<String>,
    /// The text.
    pub tag: String,
    /// For a person the part played; for a director empty.
    pub role: Option<String>,
    /// For a person an absolute address (plex.tv metadata), otherwise `None`.
    pub thumb: Option<String>,
    /// The ready-made query for `/all`, e.g. `genre=20`.
    pub filter: Option<String>,
}

impl PlexTag {
    /// A tag with only its text.
    pub fn new(tag: &str) -> Self {
        Self {
            id: None,
            tag: tag.into(),
            role: None,
            thumb: None,
            filter: None,
        }
    }

    /// Reads one entry; `None` without a `tag` (:75).
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            tag: loose::string(v, "tag")?,
            id: loose::string(v, "id"),
            role: loose::string(v, "role"),
            thumb: loose::string(v, "thumb"),
            filter: loose::string(v, "filter"),
        })
    }
}

/// One stream of a file (PlexWire.swift:96). `stream_type`: 1 video, 2 audio, 3 subtitle.
#[derive(Debug, Clone, PartialEq)]
#[allow(missing_docs)]
pub struct PlexStream {
    pub id: i64,
    pub stream_type: i64,
    /// Lower-cased.
    pub codec: Option<String>,
    pub index: Option<i64>,
    pub language: Option<String>,
    pub language_code: Option<String>,
    pub display_title: Option<String>,
    pub title: Option<String>,
    pub selected: bool,
    pub is_default: bool,
    pub forced: bool,
    pub hearing_impaired: bool,
    pub channels: Option<i64>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub frame_rate: Option<f64>,
    pub bit_depth: Option<i64>,
    pub profile: Option<String>,
    pub color_trc: Option<String>,
    pub color_primaries: Option<String>,
    pub dolby_vision_present: bool,
    pub dolby_vision_profile: Option<i64>,
    pub dolby_vision_compatibility: Option<i64>,
    /// Only for a subtitle **next to** the file (`/library/streams/{id}`); a track inside the
    /// container has none.
    pub key: Option<String>,
    /// Subtitle format (`srt`, `ass`), only for external ones.
    pub format: Option<String>,
}

impl PlexStream {
    /// Reads one entry; `None` without an `id` (:152).
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            id: loose::int(v, "id")?,
            stream_type: loose::int(v, "streamType").unwrap_or(0),
            codec: loose::string(v, "codec").map(|c| c.to_lowercase()),
            index: loose::int(v, "index"),
            language: loose::string(v, "language"),
            language_code: loose::string(v, "languageCode"),
            display_title: loose::string(v, "displayTitle"),
            title: loose::string(v, "title"),
            selected: loose::boolean(v, "selected").unwrap_or(false),
            is_default: loose::boolean(v, "default").unwrap_or(false),
            forced: loose::boolean(v, "forced").unwrap_or(false),
            hearing_impaired: loose::boolean(v, "hearingImpaired").unwrap_or(false),
            channels: loose::int(v, "channels"),
            width: loose::int(v, "width"),
            height: loose::int(v, "height"),
            frame_rate: loose::double(v, "frameRate"),
            bit_depth: loose::int(v, "bitDepth"),
            profile: loose::string(v, "profile"),
            color_trc: loose::string(v, "colorTrc"),
            color_primaries: loose::string(v, "colorPrimaries"),
            dolby_vision_present: loose::boolean(v, "DOVIPresent").unwrap_or(false),
            dolby_vision_profile: loose::int(v, "DOVIProfile"),
            dolby_vision_compatibility: loose::int(v, "DOVIBLCompatID"),
            key: loose::string(v, "key"),
            format: loose::string(v, "format"),
        })
    }
}

/// One file of a version (PlexWire.swift:196).
#[derive(Debug, Clone, PartialEq)]
pub struct PlexPart {
    /// Part id.
    pub id: i64,
    /// `/library/parts/{id}/{changestamp}/file.mkv`: the original file.
    pub key: String,
    /// Milliseconds.
    pub duration: Option<i64>,
    /// Bytes.
    pub size: Option<i64>,
    /// Container.
    pub container: Option<String>,
    /// Path on the server.
    pub file: Option<String>,
    /// `sd` when the server has made preview pictures (BIF).
    pub indexes: Option<String>,
    /// The streams.
    pub streams: Vec<PlexStream>,
}

impl PlexPart {
    /// Reads one entry; `None` without `id` and `key` (:222).
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            id: loose::int(v, "id")?,
            key: loose::string(v, "key")?,
            duration: loose::int(v, "duration"),
            size: loose::int(v, "size"),
            container: loose::string(v, "container"),
            file: loose::string(v, "file"),
            indexes: loose::string(v, "indexes"),
            streams: loose::list(v, "Stream", PlexStream::parse).unwrap_or_default(),
        })
    }
}

/// One **version** of a title (`Media`): resolution, container, bitrate; holds the files
/// (PlexWire.swift:238).
#[derive(Debug, Clone, PartialEq)]
#[allow(missing_docs)]
pub struct PlexMedia {
    pub id: i64,
    pub duration: Option<i64>,
    pub bitrate: Option<i64>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub container: Option<String>,
    pub video_codec: Option<String>,
    pub audio_codec: Option<String>,
    pub video_resolution: Option<String>,
    pub video_profile: Option<String>,
    pub parts: Vec<PlexPart>,
}

impl PlexMedia {
    /// Reads one entry; `None` without an `id` (:263).
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            id: loose::int(v, "id")?,
            duration: loose::int(v, "duration"),
            bitrate: loose::int(v, "bitrate"),
            width: loose::int(v, "width"),
            height: loose::int(v, "height"),
            container: loose::string(v, "container"),
            video_codec: loose::string(v, "videoCodec"),
            audio_codec: loose::string(v, "audioCodec"),
            video_resolution: loose::string(v, "videoResolution"),
            video_profile: loose::string(v, "videoProfile"),
            parts: loose::list(v, "Part", PlexPart::parse).unwrap_or_default(),
        })
    }
}

/// `type` is `intro`, `credits` or `commercial`; offsets in milliseconds (PlexWire.swift:283).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexMarker {
    /// Marker type.
    pub type_: String,
    /// Start offset, ms.
    pub start: i64,
    /// End offset, ms.
    pub end: i64,
    /// The last credits marker: after it nothing follows.
    pub final_: bool,
}

impl PlexMarker {
    /// Reads one entry; `None` without type, start and end (:304).
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            type_: loose::string(v, "type")?,
            start: loose::int(v, "startTimeOffset")?,
            end: loose::int(v, "endTimeOffset")?,
            final_: loose::boolean(v, "final").unwrap_or(false),
        })
    }
}

/// A chapter (PlexWire.swift:315).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexChapter {
    /// Name, if given.
    pub tag: Option<String>,
    /// Start offset, ms.
    pub start: i64,
    /// End offset, ms.
    pub end: Option<i64>,
    /// Picture path.
    pub thumb: Option<String>,
}

impl PlexChapter {
    /// Reads one entry; `None` without a start (:329).
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            start: loose::int(v, "startTimeOffset")?,
            end: loose::int(v, "endTimeOffset"),
            tag: loose::string(v, "tag"),
            thumb: loose::string(v, "thumb"),
        })
    }
}

/// An entry of a list: title, season, episode, collection, playlist (PlexWire.swift:340).
#[derive(Debug, Clone, PartialEq)]
#[allow(missing_docs)]
pub struct PlexMetadata {
    pub rating_key: String,
    pub type_: String,
    pub title: String,
    pub title_sort: Option<String>,
    pub original_title: Option<String>,
    pub summary: Option<String>,
    pub tagline: Option<String>,
    pub year: Option<i64>,
    pub content_rating: Option<String>,
    pub studio: Option<String>,
    /// Audience rating 0-10.
    pub audience_rating: Option<f64>,
    /// Critic rating 0-10.
    pub rating: Option<f64>,
    pub user_rating: Option<f64>,
    /// Milliseconds.
    pub duration: Option<i64>,
    pub originally_available_at: Option<String>,
    pub added_at: Option<i64>,
    pub last_viewed_at: Option<i64>,
    /// Milliseconds.
    pub view_offset: Option<i64>,
    pub view_count: Option<i64>,
    pub leaf_count: Option<i64>,
    pub viewed_leaf_count: Option<i64>,
    pub child_count: Option<i64>,
    pub index: Option<i64>,
    pub parent_index: Option<i64>,
    pub parent_rating_key: Option<String>,
    pub grandparent_rating_key: Option<String>,
    pub parent_title: Option<String>,
    pub grandparent_title: Option<String>,
    pub thumb: Option<String>,
    pub art: Option<String>,
    pub parent_thumb: Option<String>,
    pub grandparent_thumb: Option<String>,
    pub grandparent_art: Option<String>,
    pub clear_logo: Option<String>,
    pub updated_at: Option<i64>,
    pub library_section_id: Option<String>,
    pub smart: bool,
    pub playlist_type: Option<String>,
    pub subtype: Option<String>,
    pub original_language: Option<String>,
    pub media: Vec<PlexMedia>,
    pub genres: Vec<PlexTag>,
    pub countries: Vec<PlexTag>,
    pub cast: Vec<PlexTag>,
    pub directors: Vec<PlexTag>,
    pub writers: Vec<PlexTag>,
    pub collections: Vec<PlexTag>,
    pub markers: Vec<PlexMarker>,
    pub chapters: Vec<PlexChapter>,
    /// `imdb://tt0133093`, `tmdb://603`, `tvdb://78804` (the `Guid` ids).
    pub guids: Vec<String>,
}

impl PlexMetadata {
    /// A title with only the required fields; everything else empty. For tests and callers
    /// that build lists by hand.
    pub fn new(rating_key: &str, type_: &str, title: &str) -> Self {
        Self {
            rating_key: rating_key.into(),
            type_: type_.into(),
            title: title.into(),
            ..Self::blank()
        }
    }

    /// Reads one entry; `None` without `ratingKey` and `title` (:431).
    pub fn parse(v: &Value) -> Option<Self> {
        let image_logo = loose::list(v, "Image", |i| {
            Some((loose::string(i, "type"), loose::string(i, "url")))
        })
        .unwrap_or_default()
        .into_iter()
        .find(|(t, _)| t.as_deref() == Some("clearLogo"))
        .and_then(|(_, url)| url);
        let tags = |key: &str| loose::list(v, key, PlexTag::parse).unwrap_or_default();
        Some(Self {
            rating_key: loose::string(v, "ratingKey")?,
            title: loose::string(v, "title")?,
            type_: loose::string(v, "type").unwrap_or_else(|| "unknown".into()),
            title_sort: loose::string(v, "titleSort"),
            original_title: loose::string(v, "originalTitle"),
            summary: loose::string(v, "summary"),
            tagline: loose::string(v, "tagline"),
            year: loose::int(v, "year"),
            content_rating: loose::string(v, "contentRating"),
            studio: loose::string(v, "studio"),
            audience_rating: loose::double(v, "audienceRating"),
            rating: loose::double(v, "rating"),
            user_rating: loose::double(v, "userRating"),
            duration: loose::int(v, "duration"),
            originally_available_at: loose::string(v, "originallyAvailableAt"),
            added_at: loose::int(v, "addedAt"),
            last_viewed_at: loose::int(v, "lastViewedAt"),
            view_offset: loose::int(v, "viewOffset"),
            view_count: loose::int(v, "viewCount"),
            leaf_count: loose::int(v, "leafCount"),
            viewed_leaf_count: loose::int(v, "viewedLeafCount"),
            child_count: loose::int(v, "childCount"),
            index: loose::int(v, "index"),
            parent_index: loose::int(v, "parentIndex"),
            parent_rating_key: loose::string(v, "parentRatingKey"),
            grandparent_rating_key: loose::string(v, "grandparentRatingKey"),
            parent_title: loose::string(v, "parentTitle"),
            grandparent_title: loose::string(v, "grandparentTitle"),
            // A playlist carries its collage in `composite` instead of `thumb`.
            thumb: loose::string(v, "thumb").or_else(|| loose::string(v, "composite")),
            art: loose::string(v, "art"),
            parent_thumb: loose::string(v, "parentThumb"),
            grandparent_thumb: loose::string(v, "grandparentThumb"),
            grandparent_art: loose::string(v, "grandparentArt"),
            clear_logo: image_logo,
            updated_at: loose::int(v, "updatedAt"),
            library_section_id: loose::string(v, "librarySectionID"),
            smart: loose::boolean(v, "smart").unwrap_or(false),
            playlist_type: loose::string(v, "playlistType"),
            subtype: loose::string(v, "subtype"),
            original_language: loose::string(v, "originalLanguage"),
            media: loose::list(v, "Media", PlexMedia::parse).unwrap_or_default(),
            genres: tags("Genre"),
            countries: tags("Country"),
            cast: tags("Role"),
            directors: tags("Director"),
            writers: tags("Writer"),
            collections: tags("Collection"),
            markers: loose::list(v, "Marker", PlexMarker::parse).unwrap_or_default(),
            chapters: loose::list(v, "Chapter", PlexChapter::parse).unwrap_or_default(),
            guids: loose::list(v, "Guid", |g| loose::string(g, "id")).unwrap_or_default(),
        })
    }
}

impl PlexMetadata {
    fn blank() -> Self {
        Self {
            rating_key: String::new(),
            type_: String::new(),
            title: String::new(),
            title_sort: None,
            original_title: None,
            summary: None,
            tagline: None,
            year: None,
            content_rating: None,
            studio: None,
            audience_rating: None,
            rating: None,
            user_rating: None,
            duration: None,
            originally_available_at: None,
            added_at: None,
            last_viewed_at: None,
            view_offset: None,
            view_count: None,
            leaf_count: None,
            viewed_leaf_count: None,
            child_count: None,
            index: None,
            parent_index: None,
            parent_rating_key: None,
            grandparent_rating_key: None,
            parent_title: None,
            grandparent_title: None,
            thumb: None,
            art: None,
            parent_thumb: None,
            grandparent_thumb: None,
            grandparent_art: None,
            clear_logo: None,
            updated_at: None,
            library_section_id: None,
            smart: false,
            playlist_type: None,
            subtype: None,
            original_language: None,
            media: vec![],
            genres: vec![],
            countries: vec![],
            cast: vec![],
            directors: vec![],
            writers: vec![],
            collections: vec![],
            markers: vec![],
            chapters: vec![],
            guids: vec![],
        }
    }
}

/// A library (`/library/sections`; PlexWire.swift:~470).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexSection {
    /// Section key (a number).
    pub key: String,
    /// `movie`, `show`, `artist`, `photo`.
    pub type_: String,
    /// Name.
    pub title: String,
    /// Uuid.
    pub uuid: Option<String>,
    /// Last change.
    pub updated_at: Option<i64>,
}

impl PlexSection {
    /// Reads one entry; `None` without `key` and `title`.
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            key: loose::string(v, "key")?,
            title: loose::string(v, "title")?,
            type_: loose::string(v, "type").unwrap_or_else(|| "unknown".into()),
            uuid: loose::string(v, "uuid"),
            updated_at: loose::int(v, "updatedAt"),
        })
    }
}

/// A shelf the server composes itself: "Continue Watching", "Recently Added" ...
#[derive(Debug, Clone, PartialEq)]
pub struct PlexHub {
    /// `hubIdentifier`, the title if missing.
    pub identifier: String,
    /// Shelf title.
    pub title: String,
    /// What the shelf mostly holds.
    pub type_: Option<String>,
    /// Is there more behind it?
    pub more: bool,
    /// The entries.
    pub items: Vec<PlexMetadata>,
}

impl PlexHub {
    /// Reads one hub; never fails (:~490).
    pub fn parse(v: &Value) -> Option<Self> {
        let title = loose::string(v, "title").unwrap_or_default();
        Some(Self {
            identifier: loose::string(v, "hubIdentifier").unwrap_or_else(|| title.clone()),
            title,
            type_: loose::string(v, "type"),
            more: loose::boolean(v, "more").unwrap_or(false),
            items: loose::list(v, "Metadata", PlexMetadata::parse).unwrap_or_default(),
        })
    }
}

/// Everything a list answer can carry; each route fills a part (PlexWire.swift:~500).
#[derive(Debug, Clone, PartialEq)]
pub struct PlexListing {
    /// `size`, the entry count if missing.
    pub size: i64,
    /// `totalSize`.
    pub total_size: Option<i64>,
    /// `offset`.
    pub offset: Option<i64>,
    /// `Metadata`.
    pub metadata: Vec<PlexMetadata>,
    /// `Directory` (sections, genres).
    pub directories: Vec<PlexSection>,
    /// `Hub`.
    pub hubs: Vec<PlexHub>,
    /// `/identity`: the machine.
    pub machine_identifier: Option<String>,
    /// `/identity`: the version.
    pub version: Option<String>,
    /// `/identity`: has an account claimed the server?
    pub claimed: Option<bool>,
}

impl PlexListing {
    /// Reads the content of a `MediaContainer`.
    pub fn parse(v: &Value) -> Self {
        let metadata = loose::list(v, "Metadata", PlexMetadata::parse).unwrap_or_default();
        Self {
            size: loose::int(v, "size").unwrap_or(metadata.len() as i64),
            total_size: loose::int(v, "totalSize"),
            offset: loose::int(v, "offset"),
            directories: loose::list(v, "Directory", PlexSection::parse).unwrap_or_default(),
            hubs: loose::list(v, "Hub", PlexHub::parse).unwrap_or_default(),
            machine_identifier: loose::string(v, "machineIdentifier"),
            version: loose::string(v, "version"),
            claimed: loose::boolean(v, "claimed"),
            metadata,
        }
    }

    /// Reads a whole answer: `{"MediaContainer": {...}}` (`PlexEnvelope`). A body that is not
    /// JSON or has no container is a decoding error.
    pub fn from_body(body: &[u8]) -> Result<Self, ErrorKind> {
        let root: Value =
            serde_json::from_slice(body).map_err(|e| ErrorKind::Decoding(e.to_string()))?;
        let container = root
            .get("MediaContainer")
            .ok_or_else(|| ErrorKind::Decoding("keyNotFound MediaContainer".into()))?;
        Ok(Self::parse(container))
    }
}

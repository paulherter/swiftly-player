//! **Plex wire types into the shared types** (`Item`, `MediaSource`, `MediaStream`, `Segment`,
//! `Chapter`), so everything above the client stays as it is (`PlexMapping.swift`).
//!
//! Choices that are not obvious:
//! - `Item.id` is the `ratingKey`.
//! - `MediaStream.index` is the **Plex stream id**, not a running number: it is unique per item
//!   and exactly what `PUT /library/parts/{id}?audioStreamID=` takes.
//! - A *favourite* is a user rating of 10 (Plex has no favourite flag).
//! - `image_tags` hold the **relative image path** the server gave, which already contains the
//!   version stamp; [`crate::PlexPlayback::image_url`] turns it into an address.

use std::collections::HashMap;
use std::sync::Arc;

use swiftly_model::{
    ColorRange, Item, Localizer, MediaSource, MediaStream, NameId, Person, Source, UserItemData,
};
use swiftly_playback::sections::{Art, Segment};
use swiftly_rules::chapter::Chapter;

use crate::playback::{PlexFile, PlexPlayback};
use crate::wire::{PlexChapter, PlexMarker, PlexMetadata, PlexSection, PlexStream};

/// Maps Plex wire types to the shared ones.
#[derive(Clone)]
pub struct PlexMapper {
    l10n: Arc<dyn Localizer + Send + Sync>,
}

impl Default for PlexMapper {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for PlexMapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PlexMapper")
    }
}

impl PlexMapper {
    /// A mapper that writes the German source strings ("Kapitel 2", "Teil 2").
    pub fn new() -> Self {
        Self {
            l10n: Arc::new(Source),
        }
    }

    /// A mapper with its own text source.
    pub fn with_localizer(l10n: Arc<dyn Localizer + Send + Sync>) -> Self {
        Self { l10n }
    }

    // MARK: Types

    /// The `Item.type` for a Plex `type` (PlexMapping.swift:25).
    pub fn item_type(plex_type: &str) -> &'static str {
        match plex_type {
            "movie" => "Movie",
            "show" => "Series",
            "season" => "Season",
            "episode" => "Episode",
            "collection" => "BoxSet",
            "playlist" => "Playlist",
            "artist" => "MusicArtist",
            "album" => "MusicAlbum",
            "track" => "Audio",
            _ => "Video",
        }
    }

    /// The type number `/all?type=` takes (:40).
    pub fn plex_type_number(item_type: &str) -> Option<i64> {
        match item_type {
            "Movie" => Some(1),
            "Series" => Some(2),
            "Season" => Some(3),
            "Episode" => Some(4),
            _ => None,
        }
    }

    fn ticks(milliseconds: Option<i64>) -> Option<i64> {
        milliseconds.map(|ms| ms * 10_000)
    }

    /// `ISO8601DateFormatter().string(from:)` for seconds since 1970: `2023-11-14T22:13:20Z`.
    pub fn iso_date(seconds: i64) -> String {
        let days = seconds.div_euclid(86_400);
        let rest = seconds.rem_euclid(86_400);
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z.rem_euclid(146_097);
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        let y = yoe + era * 400 + i64::from(m <= 2);
        format!(
            "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
            rest / 3600,
            rest % 3600 / 60,
            rest % 60
        )
    }

    // MARK: Library

    /// A library as the home page's "view" (:57).
    pub fn view(&self, section: &PlexSection) -> Item {
        let kind = match section.type_.as_str() {
            "movie" => "movies",
            "show" => "tvshows",
            "artist" => "music",
            other => other,
        };
        Item {
            id: section.key.clone(),
            name: section.title.clone(),
            type_: Some("CollectionFolder".into()),
            collection_type: Some(kind.into()),
            ..Item::default()
        }
    }

    // MARK: Title

    /// A title as an `Item` (:71).
    pub fn item(&self, m: &PlexMetadata) -> Item {
        let type_ = Self::item_type(&m.type_);
        let is_episode = m.type_ == "episode";
        let is_season = m.type_ == "season";
        let is_container = m.type_ == "show" || is_season;

        // A show or season is "watched" when every leaf is; a single title by its count.
        let played = if is_container {
            m.leaf_count
                .filter(|all| *all > 0)
                .map(|all| m.viewed_leaf_count.unwrap_or(0) >= all)
        } else if m.type_ == "collection" || m.type_ == "playlist" {
            None
        } else {
            Some(m.view_count.unwrap_or(0) > 0)
        };
        let percentage = match (m.view_offset, m.duration) {
            (Some(offset), Some(duration)) if offset > 0 && duration > 0 => {
                Some((offset as f64 / duration as f64 * 100.0).min(100.0))
            }
            _ => None,
        };
        let data = UserItemData {
            playback_position_ticks: Self::ticks(m.view_offset),
            played,
            is_favorite: Some(m.user_rating.unwrap_or(0.0) >= 10.0),
            played_percentage: percentage,
            unplayed_item_count: if is_container {
                m.leaf_count
                    .map(|l| (l - m.viewed_leaf_count.unwrap_or(0)).max(0))
            } else {
                None
            },
            last_played_date: m.last_viewed_at.map(Self::iso_date),
        };

        let mut people = Vec::new();
        let person = |tag: &crate::wire::PlexTag, role: Option<String>, kind: &str| Person {
            id: tag.id.clone().unwrap_or_else(|| tag.tag.clone()),
            name: tag.tag.clone(),
            role,
            type_: Some(kind.into()),
            primary_image_tag: tag.thumb.clone(),
        };
        for tag in &m.cast {
            people.push(person(tag, tag.role.clone(), "Actor"));
        }
        for tag in &m.directors {
            people.push(person(tag, None, "Director"));
        }
        for tag in &m.writers {
            people.push(person(tag, None, "Writer"));
        }

        let mut images = HashMap::new();
        if let Some(thumb) = &m.thumb {
            images.insert("Primary".to_string(), thumb.clone());
        }
        if let Some(logo) = &m.clear_logo {
            images.insert("Logo".to_string(), logo.clone());
        }

        let mut providers = HashMap::new();
        for guid in &m.guids {
            let Some((scheme, value)) = guid.split_once("://") else {
                continue;
            };
            match scheme.to_lowercase().as_str() {
                "imdb" => providers.insert("Imdb".to_string(), value.to_string()),
                "tmdb" => providers.insert("Tmdb".to_string(), value.to_string()),
                "tvdb" => providers.insert("Tvdb".to_string(), value.to_string()),
                _ => None,
            };
        }

        let sources = if m.media.is_empty() {
            None
        } else {
            Some(self.media_sources(m))
        };

        // Both ratings are 0-10 in Plex; the item has a 0-10 community and a 0-100 critic rating.
        let community = m.audience_rating.or(m.rating);
        let critic = if m.audience_rating.is_some() {
            m.rating.map(|r| r * 10.0)
        } else {
            None
        };

        // Plex writes `de/12` or `gb/15`; the country prefix is of no use to the app. Swift
        // `split(separator: "/", maxSplits: 1).last`: with empty pieces dropped.
        let rating = m.content_rating.as_ref().map(|raw| {
            raw.splitn(2, '/')
                .filter(|p| !p.is_empty())
                .last()
                .unwrap_or(raw)
                .to_string()
        });

        Item {
            id: m.rating_key.clone(),
            name: m.title.clone(),
            type_: Some(type_.into()),
            production_year: m.year,
            overview: m.summary.clone().filter(|s| !s.is_empty()),
            run_time_ticks: Self::ticks(m.duration),
            series_name: if is_episode {
                m.grandparent_title.clone()
            } else if is_season {
                m.parent_title.clone()
            } else {
                None
            },
            index_number: m.index,
            parent_index_number: if is_episode { m.parent_index } else { None },
            series_id: if is_episode {
                m.grandparent_rating_key.clone()
            } else if is_season {
                m.parent_rating_key.clone()
            } else {
                None
            },
            season_id: if is_episode {
                m.parent_rating_key.clone()
            } else {
                None
            },
            genres: (!m.genres.is_empty())
                .then(|| m.genres.iter().map(|g| g.tag.clone()).collect()),
            official_rating: rating,
            community_rating: community,
            // A series' children are seasons, a season's are episodes.
            child_count: if m.type_ == "show" {
                m.child_count
            } else if is_season {
                m.leaf_count
            } else {
                None
            },
            backdrop_image_tags: m.art.clone().map(|a| vec![a]),
            series_primary_image_tag: if is_episode {
                m.grandparent_thumb.clone()
            } else if is_season {
                m.parent_thumb.clone()
            } else {
                None
            },
            people: (!people.is_empty()).then_some(people),
            studios: m.studio.clone().map(|s| {
                vec![NameId {
                    id: None,
                    name: Some(s),
                }]
            }),
            taglines: m.tagline.clone().map(|t| vec![t]),
            critic_rating: critic,
            image_tags: (!images.is_empty()).then_some(images),
            user_data: Some(data),
            media_sources: sources,
            parent_backdrop_image_tags: if is_episode {
                m.grandparent_art.clone().map(|a| vec![a])
            } else {
                None
            },
            parent_backdrop_item_id: if is_episode {
                m.grandparent_rating_key.clone()
            } else {
                None
            },
            premiere_date: m.originally_available_at.as_ref().map(|d| {
                if d.chars().count() == 10 {
                    format!("{d}T00:00:00Z")
                } else {
                    d.clone()
                }
            }),
            production_locations: (!m.countries.is_empty())
                .then(|| m.countries.iter().map(|c| c.tag.clone()).collect()),
            provider_ids: (!providers.is_empty()).then_some(providers),
            original_language: m.original_language.clone(),
            media_type: ["movie", "episode", "clip"]
                .contains(&m.type_.as_str())
                .then(|| "Video".to_string()),
            sort_name: Some(m.title_sort.as_ref().unwrap_or(&m.title).to_lowercase()),
            // Seconds since 1970; as ISO 8601 like Jellyfin's `DateCreated`.
            date_created: m.added_at.map(Self::iso_date),
            ..Item::default()
        }
    }

    // MARK: Files

    /// **Every file of a title as a media source** (:152). A title has several versions
    /// (4K next to 1080p) and each holds one or more files (a title split over CD1/CD2 has
    /// two). Each file is one source, so the version choice offers all of them.
    pub fn media_sources(&self, m: &PlexMetadata) -> Vec<MediaSource> {
        PlexPlayback::files(m)
            .iter()
            .map(|f| self.media_source(f, m.duration))
            .collect()
    }

    /// One file as a media source (:158).
    pub fn media_source(&self, file: &PlexFile, duration: Option<i64>) -> MediaSource {
        let media = &file.media;
        let part = &file.part;
        let streams: Vec<MediaStream> = part.streams.iter().map(|s| self.stream(s)).collect();
        // `(path as NSString).lastPathComponent`
        let mut name = part.file.as_ref().map(|f| {
            f.trim_end_matches('/')
                .rsplit('/')
                .next()
                .unwrap_or("")
                .to_string()
        });
        // A later part without a file name still needs something to tell it apart.
        if name.as_deref().unwrap_or("").is_empty() && file.number > 1 {
            name = Some(self.l10n.text("Teil %lld", &[file.number]));
        }
        let selected = |kind: i64| {
            part.streams
                .iter()
                .find(|s| s.stream_type == kind && s.selected)
                .map(|s| s.id)
        };
        MediaSource {
            id: Some(file.source_id.clone()),
            name,
            container: part.container.clone().or_else(|| media.container.clone()),
            size: part.size,
            supports_direct_play: Some(true),
            supports_direct_stream: Some(false),
            supports_transcoding: Some(false),
            transcoding_url: None,
            media_streams: Some(streams),
            default_audio_stream_index: selected(2),
            // Jellyfin says -1 for "none"; so do we, so the existing rule can read it.
            default_subtitle_stream_index: Some(selected(3).unwrap_or(-1)),
            run_time_ticks: Self::ticks(part.duration.or(media.duration).or(duration)),
        }
    }

    /// One stream (:187).
    pub fn stream(&self, s: &PlexStream) -> MediaStream {
        let type_ = match s.stream_type {
            1 => Some("Video"),
            2 => Some("Audio"),
            3 => Some("Subtitle"),
            _ => None,
        };
        let stream = MediaStream {
            codec: s.codec.clone(),
            type_: type_.map(String::from),
            language: s.language_code.clone().or_else(|| s.language.clone()),
            display_title: s.display_title.clone(),
            channels: s.channels,
            is_default: Some(s.is_default),
            index: Some(s.id),
            // Where the stream sits in the file: the engine numbers a track by this, not by the stream id.
            container_index: s.index,
            height: s.height,
            width: s.width,
            color_transfer: s.color_trc.clone(),
            color_primaries: s.color_primaries.clone(),
            is_forced: Some(s.forced),
            is_external: (s.stream_type == 3).then_some(s.key.is_some()),
            title: s.title.clone(),
            // The path only; the token is added by the client.
            delivery_url: if s.stream_type == 3 {
                s.key.clone()
            } else {
                None
            },
            is_hearing_impaired: Some(s.hearing_impaired),
            ..MediaStream::default()
        };
        let range = (s.stream_type == 1).then(|| Self::color_range(s));
        let mut stream = stream
            .with_frame_rates(s.frame_rate, s.frame_rate)
            .with_dolby_vision(
                s.dolby_vision_present
                    .then_some(s.dolby_vision_profile)
                    .flatten(),
                s.dolby_vision_present
                    .then_some(s.dolby_vision_compatibility)
                    .flatten(),
            );
        if let Some(range) = range {
            stream = stream.with_video_range_type(range);
        }
        stream
    }

    /// Plex has no "range type"; derive it from transfer function and Dolby Vision (:210).
    pub fn color_range(s: &PlexStream) -> ColorRange {
        let base = match s.color_trc.as_deref().map(str::to_lowercase).as_deref() {
            Some("smpte2084") => ColorRange::Hdr10,
            Some("arib-std-b67") => ColorRange::Hlg,
            None => ColorRange::Unknown,
            Some(_) => ColorRange::Sdr,
        };
        if !s.dolby_vision_present {
            return base;
        }
        match base {
            ColorRange::Hdr10 => ColorRange::DolbyVisionHdr10,
            ColorRange::Hlg => ColorRange::DolbyVisionHlg,
            ColorRange::Sdr => ColorRange::DolbyVisionSdr,
            _ => ColorRange::DolbyVision,
        }
    }

    // MARK: Markers and chapters

    /// `intro` and `credits` as skip buttons; `commercial` as an ad. Milliseconds to seconds. A
    /// final credits marker may end past the file; the end is cut to the runtime when it is
    /// known (:230).
    pub fn segments(&self, markers: &[PlexMarker], duration: Option<i64>) -> Vec<Segment> {
        let mut out: Vec<Segment> = markers
            .iter()
            .filter_map(|marker| {
                let art = match marker.type_.as_str() {
                    "intro" => Art::IntroSegment,
                    "credits" => Art::Credits,
                    "commercial" => Art::Ads,
                    _ => return None,
                };
                let mut end = marker.end;
                if let Some(d) = duration.filter(|d| *d > 0) {
                    end = end.min(d);
                }
                (end > marker.start)
                    .then(|| Segment::new(art, marker.start as f64 / 1000.0, end as f64 / 1000.0))
            })
            .collect();
        // Stable, like the offset-tie-broken sort of the Swift side for equal starts.
        out.sort_by(|a, b| a.from.total_cmp(&b.from));
        out
    }

    /// The chapters; an empty name becomes "Kapitel n" (:250).
    pub fn chapters(&self, list: &[PlexChapter]) -> Vec<Chapter> {
        list.iter()
            .enumerate()
            .map(|(index, chapter)| {
                let given = chapter.tag.as_deref().unwrap_or("").trim();
                let name = if given.is_empty() {
                    self.l10n.text("Kapitel %lld", &[index as i64 + 1])
                } else {
                    given.to_string()
                };
                Chapter::new(&name, chapter.start as f64 / 1000.0)
            })
            .collect()
    }
}

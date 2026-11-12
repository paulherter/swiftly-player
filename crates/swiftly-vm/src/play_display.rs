//! The display facts of a title that is about to play: what the player screens (header, now-playing card, file line,
//! hand-over card, next-episode card, HDR badge, sound decision) read from the plan and the title. On Android this is
//! the old `playbackOpen` answer (`PlayPlanResponse`), on Apple the computed properties of `PlayerScreen`
//! (`titleLine`, `metaText`, the card images) and of the `PlaybackPlan`. One place, same words and pictures everywhere.

use swiftly_images::{ImageAddress, ImageKind, ImageMetric, ImageSelection};
use swiftly_model::{DeliveryMethod, Item, ItemKind, Localizer, MediaSource};

use crate::tile::Words;
use crate::title_text::TitleText;

/// The episode that follows, as its card shows it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DisplayNext {
    /// Item id.
    pub id: String,
    /// Title of the episode.
    pub name: String,
    /// "S6 · F11" (`Item.episodeCode`), else the name.
    pub abbreviation: String,
    /// The episode's own still, else a landscape picture (1080 high / 1920 wide).
    pub image: Option<String>,
}

/// Everything the player screens show about the title, besides the stream itself.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PlayDisplay {
    /// `Item.contextLine`, `""` without one (the footer under the title on tvOS).
    pub context_line: String,
    /// "MKV · 1080p · H.264 · German · AAC · Stereo": container, picture, first sound track (the file line of the
    /// playback sheet); `None` without a known source.
    pub file_row: Option<String>,
    /// The series of an episode.
    pub series: Option<String>,
    /// "S6 · F11" for an episode (`Item.episodeCode`).
    pub abbreviation: Option<String>,
    /// The picture for the media controls: the title's primary image, 600 high.
    pub image: Option<String>,
    /// The title is an episode.
    pub episode: bool,
    /// Season id of an episode.
    pub season_id: Option<String>,
    /// Season number of an episode.
    pub season_number: Option<i64>,
    /// Episode number of an episode.
    pub episode_number: Option<i64>,
    /// The series for an episode, otherwise the title itself (`titleLine`).
    pub header_line: String,
    /// Year, runtime and genre of a movie (`secondaryLine`); `None` for an episode and when empty.
    pub secondary_line: Option<String>,
    /// What sits next to the title (`metaText`): "S1 · F3" for an episode (its context line without numbers),
    /// the secondary line for a movie.
    pub meta_line: Option<String>,
    /// The hand-over card's picture (`TakeoverModel.cardImageURL`): the episode's still, else the landscape picture.
    pub card_image: Option<String>,
    /// Dolby Vision profile of the picture when the file arrives untouched (`0` if the profile is unknown).
    pub dolby_vision: Option<i64>,
    /// Lower case codec of the sound track the server marks default (else the first); `Some("")` for a file without
    /// sound, `None` if the file is not known.
    pub audio_codec: Option<String>,
    /// The episode after this one.
    pub next: Option<DisplayNext>,
}

fn url_text(url: Option<impl ToString>) -> Option<String> {
    url.map(|u| u.to_string())
}

/// The Dolby Vision profile of the video track when the stream brings the file untouched.
fn dolby_vision(method: DeliveryMethod, source: Option<&MediaSource>) -> Option<i64> {
    use swiftly_model::ColorRange as C;
    if method == DeliveryMethod::Transcode {
        return None;
    }
    let track = source?.video_track()?;
    match track.video_range_type()? {
        C::DolbyVision
        | C::DolbyVisionHdr10
        | C::DolbyVisionHlg
        | C::DolbyVisionSdr
        | C::DolbyVisionEl
        | C::DolbyVisionHdr10Plus
        | C::DolbyVisionElHdr10Plus => Some(track.dv_profile().unwrap_or(0)),
        _ => None,
    }
}

fn audio_codec(source: Option<&MediaSource>) -> Option<String> {
    let source = source?;
    let audio: Vec<_> = source
        .media_streams
        .iter()
        .flatten()
        .filter(|s| s.type_.as_deref() == Some("Audio"))
        .collect();
    let Some(track) = audio
        .iter()
        .find(|s| s.is_default == Some(true))
        .or(audio.first())
    else {
        return Some(String::new());
    };
    Some(
        track
            .codec
            .as_deref()
            .map(str::to_lowercase)
            .unwrap_or_default(),
    )
}

/// "MKV · 1080p · H.264 · German · AAC · Stereo" (`fileRow`).
fn file_row(source: Option<&MediaSource>, words: &Words) -> Option<String> {
    let source = source?;
    let mut parts: Vec<String> = Vec::new();
    if let Some(container) = &source.container {
        parts.push(container.to_uppercase());
    }
    if let Some(video) = source.video_track() {
        let mut v = Vec::new();
        if let Some(h) = source.height() {
            v.push(format!("{h}p"));
        }
        if let Some(codec) = &video.codec {
            v.push(swiftly_model::codec_name(codec));
        }
        parts.push(if v.is_empty() {
            video.short_with(words)
        } else {
            v.join(" · ")
        });
    }
    if let Some(audio) = source
        .media_streams
        .iter()
        .flatten()
        .find(|s| s.type_.as_deref() == Some("Audio"))
    {
        parts.push(audio.short_with(words));
    }
    (!parts.is_empty()).then(|| parts.join(" · "))
}

/// The hand-over card's picture (`TakeoverModel.cardImageURL`).
pub fn card_image(item: &Item, a: &ImageAddress) -> Option<String> {
    if item.series_id.is_some()
        && let Some(mark) = item.image_tags.as_ref().and_then(|t| t.get("Primary"))
    {
        return url_text(a.construct(
            &item.id,
            ImageKind::Poster,
            Some(mark),
            ImageMetric::AtMostWide(1280),
        ));
    }
    ImageSelection::landscape(item, a, 1280).map(|l| l.url.to_string())
}

fn next_of(next: &Item, a: Option<&ImageAddress>, words: &Words) -> DisplayNext {
    let abbreviation = next
        .episode_code_with(words)
        .unwrap_or_else(|| next.name.clone());
    let image = a.and_then(|a| {
        let mark = next
            .image_tags
            .as_ref()
            .and_then(|t| t.get("Primary"))
            .map(String::as_str);
        url_text(a.construct(
            &next.id,
            ImageKind::Poster,
            mark,
            ImageMetric::AtMostHigh(1080),
        ))
        .or_else(|| ImageSelection::landscape(next, a, 1920).map(|l| l.url.to_string()))
    });
    DisplayNext {
        id: next.id.clone(),
        name: next.name.clone(),
        abbreviation,
        image,
    }
}

/// The display facts of `item` played with `method` (`source`: the chosen version), `next` the episode after it.
pub fn play_display(
    item: &Item,
    method: DeliveryMethod,
    source: Option<&MediaSource>,
    next: Option<&Item>,
    addresses: Option<&ImageAddress>,
    locale: swiftly_l10n::Locale,
) -> PlayDisplay {
    let words = Words::new(locale.clone());
    let text = TitleText::new(locale);
    let episode = item.kind() == ItemKind::Episode;
    let series_name = item.series_name.clone().filter(|s| !s.is_empty());
    let header_line = match (&series_name, episode) {
        (Some(series), true) => series.clone(),
        _ => item.name.clone(),
    };
    let secondary = text.secondary_line(item);
    let secondary_line = (!episode && !secondary.is_empty()).then_some(secondary.clone());
    let numbers = (item.parent_index_number, item.index_number);
    let meta_line = if episode {
        match numbers {
            (Some(s), Some(e)) => Some(words.text("S%lld · F%lld", &[s, e])),
            _ => item.context_line_with(&words),
        }
    } else {
        secondary_line.clone()
    };
    PlayDisplay {
        context_line: item.context_line_with(&words).unwrap_or_default(),
        file_row: file_row(source, &words),
        series: item.series_name.clone(),
        abbreviation: item.episode_code_with(&words),
        image: addresses.and_then(|a| {
            let mark = item
                .image_tags
                .as_ref()
                .and_then(|t| t.get("Primary"))
                .map(String::as_str);
            url_text(a.construct(
                &item.id,
                ImageKind::Poster,
                mark,
                ImageMetric::AtMostHigh(600),
            ))
        }),
        episode,
        season_id: item.season_id.clone(),
        season_number: if episode {
            item.parent_index_number
        } else {
            None
        },
        episode_number: if episode { item.index_number } else { None },
        header_line,
        secondary_line,
        meta_line,
        card_image: addresses.and_then(|a| card_image(item, a)),
        dolby_vision: dolby_vision(method, source),
        audio_codec: audio_codec(source),
        next: next.map(|n| next_of(n, addresses, &words)),
    }
}

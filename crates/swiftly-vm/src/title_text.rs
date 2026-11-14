//! How a title is labelled on the detail and series pages: `TitleDetails.swift` of JellyfinKit
//! (runtime, resume point, remaining time, the series button) plus the small helpers both pages
//! share (image addresses, the cast tiles).

use swiftly_images::{ImageAddress, ImageKind as Art, ImageMetric, ImageSelection};
use swiftly_jellyfin::JellyfinClient;
use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_model::Item;
use swiftly_net::HttpTransport;
use swiftly_playback::resume_point;

use crate::parts::{ImageKind, ImageRef};

/// Width of the head image in pixels (`AppModel.headerImageURL(for:)`).
pub(crate) const HEADER_WIDTH: i64 = 1200;
const LOGO_HEIGHT: i64 = 200;
const PERSON_HEIGHT: i64 = 220;

/// The words of the detail pages.
pub(crate) struct TitleText {
    translator: Translator,
}

impl TitleText {
    pub(crate) fn new(locale: Locale) -> Self {
        Self {
            translator: Translator::new(locale),
        }
    }

    pub(crate) fn locale(&self) -> Locale {
        self.translator.locale().clone()
    }

    pub(crate) fn key(&self, key: &str) -> String {
        self.translator.t(key)
    }

    pub(crate) fn with(&self, key: &str, args: &[Arg]) -> String {
        self.translator.t_args(key, args)
    }

    /// "2 Std. 8 Min." or "94 Min." (`runtime(_:)`).
    pub(crate) fn runtime(&self, seconds: f64) -> String {
        let m = whole(seconds / 60.0);
        if m >= 60 {
            self.with("%lld Std. %lld Min.", &[Arg::Int(m / 60), Arg::Int(m % 60)])
        } else {
            self.with("%lld Min.", &[Arg::Int(m)])
        }
    }

    /// The text of the resume button (`timeText(_:)`).
    pub(crate) fn time_text(&self, seconds: f64) -> String {
        let total = whole(seconds);
        let (h, m) = (total / 3600, (total % 3600) / 60);
        if h > 0 {
            self.with("%lld Std. %lld Min.", &[Arg::Int(h), Arg::Int(m)])
        } else {
            self.with("%lld Min.", &[Arg::Int(m)])
        }
    }

    /// Year, runtime and genre in one line (`Item.secondaryLine`). Series have no runtime of
    /// their own (the server delivers 0), so only a positive one counts.
    pub(crate) fn secondary_line(&self, item: &Item) -> String {
        let mut parts = Vec::new();
        if let Some(year) = item.production_year {
            parts.push(year.to_string());
        }
        if let Some(seconds) = item.runtime_seconds().filter(|s| *s > 0.0) {
            parts.push(self.runtime(seconds));
        }
        if let Some(genres) = item.genres.as_ref().filter(|g| !g.is_empty()) {
            parts.push(
                genres
                    .iter()
                    .take(2)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", "),
            );
        }
        parts.join(" · ")
    }

    /// "Noch 12 Min." or nothing (`Item.remainingTimeText`).
    pub(crate) fn remaining(&self, item: &Item) -> Option<String> {
        let total = item.runtime_seconds().filter(|t| *t > 0.0)?;
        let since = resume_from(item)?;
        let minutes = whole(((total - since) / 60.0).ceil()).max(1);
        Some(self.with("Noch %lld Min.", &[Arg::Int(minutes)]))
    }

    /// The label of the main button of a series page (`Item.seriesButton`).
    pub(crate) fn series_button(&self, episode: Option<&Item>, loads: bool) -> String {
        let Some(episode) = episode else {
            return self.key(if loads { "Lädt…" } else { "Keine Folgen" });
        };
        let code = episode
            .episode_code_with(&crate::tile::Words::new(self.translator.locale().clone()))
            .unwrap_or_else(|| episode.name.clone());
        let begun = episode
            .user_data
            .as_ref()
            .and_then(|d| d.playback_position_ticks)
            .unwrap_or(0)
            > 0;
        self.with(
            if begun {
                "Fortsetzen %@"
            } else {
                "Abspielen %@"
            },
            &[Arg::Str(code)],
        )
    }
}

/// A whole number from a float, clamped (`Int(capped:)`); not a number gives 0.
fn whole(value: f64) -> i64 {
    if value.is_finite() {
        value.clamp(0.0, 1_000_000_000.0) as i64
    } else {
        0
    }
}

/// The second playback resumes at, or nothing (`Item.resumeFrom`).
pub(crate) fn resume_from(item: &Item) -> Option<f64> {
    resume_point::since(
        item.user_data
            .as_ref()
            .and_then(|d| d.playback_position_ticks)
            .map(|t| t as f64 / 10_000_000.0),
        item.run_time_ticks.map(|t| t as f64 / 10_000_000.0),
    )
}

/// How far the title is watched, 0 to 1, only when started (`playedPercentage > 0`).
pub(crate) fn progress(item: &Item) -> Option<f32> {
    item.watched_share().map(|s| s.clamp(0.0, 1.0) as f32)
}

/// The address builder of a signed-in client.
pub(crate) fn addresses<T: HttpTransport>(client: &JellyfinClient<T>) -> Option<ImageAddress> {
    client.current_session().map(|s| {
        ImageAddress::new(
            client.base_url().clone(),
            Some(s.access_token),
            client.server_kind(),
        )
    })
}

/// The head image (`AppModel.headerImageURL(for:)`); `episode` is the one that plays next
/// on a series page.
pub(crate) fn header_image(
    item: &Item,
    episode: Option<&Item>,
    addresses: &ImageAddress,
) -> Option<ImageRef> {
    ImageSelection::header_with_fallback(item, episode, addresses, HEADER_WIDTH).map(|url| {
        ImageRef {
            address: url.into(),
            kind: ImageKind::Backdrop,
            wanted_width: 1200,
            wanted_height: 675,
        }
    })
}

/// The logo for the title mark.
pub(crate) fn logo_image(item: &Item, addresses: &ImageAddress) -> Option<ImageRef> {
    ImageSelection::logo(item, addresses, LOGO_HEIGHT).map(|url| ImageRef {
        address: url.into(),
        kind: ImageKind::Poster,
        wanted_width: 400,
        wanted_height: 200,
    })
}

/// A cast member's portrait.
pub(crate) fn person_image(
    id: &str,
    mark: Option<&str>,
    addresses: &ImageAddress,
) -> Option<ImageRef> {
    mark?;
    addresses
        .construct(
            id,
            Art::Poster,
            mark,
            ImageMetric::AtMostHigh(PERSON_HEIGHT),
        )
        .map(|url| ImageRef {
            address: url.into(),
            kind: ImageKind::Poster,
            wanted_width: 147,
            wanted_height: 220,
        })
}

/// Titles without double entries (`ListRules.withoutDouble`).
pub(crate) fn without_double(items: &[Item]) -> Vec<Item> {
    swiftly_library::ListRules::without_double(items)
}

/// What `JellyfinClient.similar(itemID:toward:)` does with the raw answer: drop the title itself
/// and merge titles that live in two libraries, at most `limit`.
pub(crate) fn similar_cleaned(raw: &[Item], own: &Item, limit: usize) -> Vec<Item> {
    let own_key = swiftly_library::ListRules::title_key(own);
    let rest: Vec<Item> = raw
        .iter()
        .filter(|i| i.id != own.id && swiftly_library::ListRules::title_key(i) != own_key)
        .cloned()
        .collect();
    swiftly_library::ListRules::je_title_in_times(&rest, limit)
}

/// A user's profile picture (the "Gesehen von" avatars).
pub(crate) fn user_image(user_id: &str, tag: &str, addresses: &ImageAddress) -> Option<ImageRef> {
    addresses.user(user_id, Some(tag), 160).map(|url| ImageRef {
        address: url.into(),
        kind: ImageKind::Poster,
        wanted_width: 160,
        wanted_height: 160,
    })
}

/// "1 Std. 5 Min." / "42 Min.": the position in the takeover offer (`timeText` of the old core).
pub fn minutes_text(locale: Locale, seconds: f64) -> String {
    TitleText::new(locale).time_text(seconds)
}

/// What the player shows over the picture at the top left (`PlayerScreen.titleLine`, `metaText`): for an episode the
/// series and "Staffel 1 · Folge 3", for anything else the title and year, runtime and genre. The second line may be empty.
pub fn player_head(locale: Locale, item: &Item) -> (String, String) {
    let text = TitleText::new(locale);
    let episode = item.type_.as_deref() == Some("Episode");
    let title = match item.series_name.as_deref() {
        Some(series) if episode && !series.is_empty() => series.to_string(),
        _ => item.name.clone(),
    };
    let meta = if episode {
        match (item.parent_index_number, item.index_number) {
            (Some(season), Some(number)) => text.with(
                "Staffel %lld · Folge %lld",
                &[Arg::Int(season), Arg::Int(number)],
            ),
            _ => item.context_line().unwrap_or_default(),
        }
    } else {
        text.secondary_line(item)
    };
    (title, meta)
}

/// The code a card names an episode by (`episode.episodeCode`: "S1 · F4"), `None` without both numbers.
pub fn episode_code(locale: Locale, item: &Item) -> Option<String> {
    item.episode_code_with(&crate::tile::Words::new(locale))
}

#[cfg(test)]
mod player_head_tests {
    use super::*;

    fn item(json: &str) -> Item {
        serde_json::from_str(json).expect("item")
    }

    #[test]
    fn an_episode_shows_its_series_and_the_season_line() {
        let ep = item(
            r#"{"Id":"1","Name":"Pilot","Type":"Episode","SeriesName":"Show","ParentIndexNumber":1,"IndexNumber":3}"#,
        );
        assert_eq!(
            player_head(Locale::parse("de"), &ep),
            ("Show".into(), "Staffel 1 · Folge 3".into())
        );
    }

    #[test]
    fn a_film_shows_year_runtime_and_genre() {
        let film = item(
            r#"{"Id":"2","Name":"Film","Type":"Movie","ProductionYear":1999,"RunTimeTicks":54000000000,"Genres":["Drama","Krimi","Western"]}"#,
        );
        assert_eq!(
            player_head(Locale::parse("de"), &film),
            ("Film".into(), "1999 · 1 Std. 30 Min. · Drama, Krimi".into())
        );
    }
}

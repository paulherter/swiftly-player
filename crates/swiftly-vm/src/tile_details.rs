//! The details line of the focused tile (the TV home header: year, runtime, stars, age rating,
//! description, time left, episode name). Additive: `Tile` and the `HomeVm` parts keep their
//! shapes; the host asks for one title when its tile gets the focus.

use swiftly_l10n::Locale;
use swiftly_model::Item;

use crate::detail_more::{age_rating_text, rating_text};
use crate::title_text::TitleText;

/// What the header under the focused tile shows.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct TileDetails {
    /// The title's id.
    pub id: String,
    /// Year, runtime and genre in one line (empty when the server gave none of them).
    pub details_line: String,
    /// The description.
    pub overview: Option<String>,
    /// Community rating as "7,5".
    pub rating: Option<String>,
    /// Age rating as the page shows it ("ab 12", "PG-13").
    pub age_rating: Option<String>,
    /// "Noch 12 Min." for a started title.
    pub remaining: Option<String>,
    /// The episode's own name; only for an episode.
    pub episode_name: Option<String>,
    /// Production year (a single mark of the TV header).
    pub year: Option<i32>,
    /// Runtime in seconds when positive (the header shows it as one mark).
    pub runtime_seconds: Option<f64>,
    /// Community rating as the server gave it (the stars mark).
    pub community_rating: Option<f64>,
    /// Age rating as the server gave it, before the wording ("FSK 12", "PG-13").
    pub official_rating: Option<String>,
    /// The second playback resumes at, when the title is started.
    pub resume_seconds: Option<f64>,
}

/// The details of one full title.
pub(crate) fn details_of(text: &TitleText, item: &Item) -> TileDetails {
    TileDetails {
        id: item.id.clone(),
        details_line: text.secondary_line(item),
        overview: item.overview.clone().filter(|o| !o.is_empty()),
        rating: item.community_rating.map(rating_text),
        age_rating: age_rating_text(text, item.official_rating.clone()),
        remaining: text.remaining(item),
        episode_name: (item.type_.as_deref() == Some("Episode"))
            .then(|| item.name.clone())
            .filter(|n| !n.is_empty()),
        year: item.production_year.and_then(|y| i32::try_from(y).ok()),
        runtime_seconds: item.runtime_seconds().filter(|s| *s > 0.0),
        community_rating: item.community_rating,
        official_rating: item.official_rating.clone().filter(|r| !r.is_empty()),
        resume_seconds: crate::title_text::resume_from(item),
    }
}

/// The words for a language.
pub(crate) fn text_for(locale: Locale) -> TitleText {
    TitleText::new(locale)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(json: &str) -> Item {
        serde_json::from_str(json).expect("item")
    }

    #[test]
    fn a_movie_in_progress_has_every_field() {
        let i = item(
            r#"{"Id":"m1","Name":"Heat","Type":"Movie","ProductionYear":1995,"RunTimeTicks":99000000000,
                "Overview":"A crew.","CommunityRating":8.5,"OfficialRating":"16",
                "UserData":{"PlaybackPositionTicks":36000000000}}"#,
        );
        let d = details_of(&text_for(Locale::parse("de")), &i);
        assert_eq!(d.id, "m1");
        assert!(d.details_line.starts_with("1995 · "), "{}", d.details_line);
        assert_eq!(d.overview.as_deref(), Some("A crew."));
        assert_eq!(d.rating.as_deref(), Some("8,5"));
        assert_eq!(d.age_rating.as_deref(), Some("ab 16"));
        assert_eq!(d.remaining.as_deref(), Some("Noch 105 Min."));
        assert_eq!(d.episode_name, None);
        assert_eq!(d.year, Some(1995));
        assert_eq!(d.runtime_seconds, Some(9900.0));
        assert_eq!(d.community_rating, Some(8.5));
        assert_eq!(d.official_rating.as_deref(), Some("16"));
        assert_eq!(d.resume_seconds, Some(3600.0));
    }

    #[test]
    fn an_episode_names_itself_and_a_bare_title_has_nothing() {
        let e = item(r#"{"Id":"e1","Name":"Pilot","Type":"Episode","SeriesName":"Show"}"#);
        let d = details_of(&text_for(Locale::parse("de")), &e);
        assert_eq!(d.episode_name.as_deref(), Some("Pilot"));
        assert_eq!(
            (d.overview, d.rating, d.age_rating, d.remaining),
            (None, None, None, None)
        );
        let bare =
            item(r#"{"Id":"x","Name":"X","Type":"Movie","Overview":"","OfficialRating":""}"#);
        let d = details_of(&text_for(Locale::parse("de")), &bare);
        assert_eq!(
            (d.overview, d.age_rating, d.episode_name),
            (None, None, None)
        );
    }
}

//! Account, settings, search, title pages, related titles, people and collections.

use std::collections::HashSet;

use serde::Deserialize;
use swiftly_net::HttpTransport;

use crate::client::{CookieJar, SeerrClient};
use crate::errors::AskError;
use crate::types::{
    Collection, Credits, DiscoverSlider, Me, Page, PersonInfo, PublicSettings, Quota, RawPage,
    RawResult, RawSlider, RawTitle, SearchResult, TitleCard, TitleEpisode, TitleInfo, list,
    or_default,
};

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct RawCollection {
    #[serde(deserialize_with = "or_default")]
    id: i64,
    name: Option<String>,
    overview: Option<String>,
    poster_path: Option<String>,
    backdrop_path: Option<String>,
    #[serde(deserialize_with = "list")]
    parts: Vec<RawResult>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct RawCredits {
    #[serde(deserialize_with = "list")]
    cast: Vec<RawResult>,
    #[serde(deserialize_with = "list")]
    crew: Vec<RawResult>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct RawSeasonPage {
    air_date: Option<String>,
    #[serde(deserialize_with = "list")]
    episodes: Vec<TitleEpisode>,
}

impl RawSeasonPage {
    /// The season's day; without one the first episode's day stands in.
    fn air_date(&self) -> Option<String> {
        self.air_date.clone().filter(|d| !d.is_empty()).or_else(|| {
            self.episodes
                .first()
                .and_then(|e| e.air_date.clone())
                .filter(|d| !d.is_empty())
        })
    }
}

fn unique(cards: Vec<TitleCard>) -> Vec<TitleCard> {
    let mut seen = HashSet::new();
    cards
        .into_iter()
        .filter(|c| seen.insert(format!("{}-{}", c.hit.art, c.hit.id)))
        .collect()
}

impl<T: HttpTransport, J: CookieJar> SeerrClient<T, J> {
    /// `GET auth/me`: the account with its permission bitmask.
    pub async fn me(&self) -> Result<Me, AskError> {
        self.get_json("auth/me", &[]).await
    }

    /// `GET user/{id}/quota`.
    pub async fn quota(&self, user_id: i64) -> Result<Quota, AskError> {
        self.get_json(&format!("user/{user_id}/quota"), &[]).await
    }

    /// `GET settings/public`: 4K and partial requests.
    pub async fn public_settings(&self) -> Result<PublicSettings, AskError> {
        self.get_json("settings/public", &[]).await
    }

    /// `GET settings/discover`: the admin's sliders in order; switched-off ones and kinds this
    /// client cannot fill (unknown, Plex watchlist, search) are left out.
    pub async fn discover_sliders(&self) -> Result<Vec<DiscoverSlider>, AskError> {
        let raw: Vec<RawSlider> = self.get_json("settings/discover", &[]).await?;
        Ok(raw
            .into_iter()
            .map(DiscoverSlider::from)
            .filter(|s| s.enabled && s.kind.supported())
            .collect())
    }

    /// `GET search?query=&page=`: films, series, people and collections.
    pub async fn search(&self, term: &str, page: u32) -> Result<Page<SearchResult>, AskError> {
        let page = page.max(1).to_string();
        let raw: RawPage = self
            .get_json("search", &[("query", term), ("page", &page)])
            .await?;
        Ok(raw.search())
    }

    /// `GET movie/{id}` or `tv/{id}` with `mediaInfo` (requests, seasons, downloads, 4K lane).
    /// A series is completed with `tv/{id}/season/{n}` for every season: its episodes (name, story, still,
    /// runtime, day) and, where the series answer has none, the season's air date.
    pub async fn title(&self, art: &str, tmdb: i64) -> Result<TitleInfo, AskError> {
        let raw: RawTitle = self.get_json(&format!("{art}/{tmdb}"), &[]).await?;
        let mut info = raw.into_info(art);
        if art == "tv" {
            let numbers: Vec<i64> = info.seasons.iter().map(|s| s.season_number).collect();
            let fetched =
                futures_util::future::join_all(numbers.iter().map(|n| self.season_page(tmdb, *n)))
                    .await;
            for (n, page) in numbers.iter().zip(fetched) {
                let Some(season) = info.seasons.iter_mut().find(|s| s.season_number == *n) else {
                    continue;
                };
                let Some(page) = page else { continue };
                if season.air_date.as_deref().is_none_or(str::is_empty) {
                    season.air_date = page.air_date();
                }
                season.episodes = page.episodes;
            }
        }
        Ok(info)
    }

    /// One season page (`GET tv/{id}/season/{n}`); `None` when it does not answer.
    async fn season_page(&self, tmdb: i64, season: i64) -> Option<RawSeasonPage> {
        self.get_json(&format!("tv/{tmdb}/season/{season}"), &[])
            .await
            .ok()
    }

    /// The air date of one season (`GET tv/{id}/season/{n}`); `None` when unknown.
    pub async fn season_air_date(&self, tmdb: i64, season: i64) -> Option<String> {
        self.season_page(tmdb, season).await?.air_date()
    }

    /// `GET {art}/{id}/recommendations`.
    pub async fn recommendations(
        &self,
        art: &str,
        tmdb: i64,
        page: u32,
    ) -> Result<Page<TitleCard>, AskError> {
        self.cards(
            &format!("{art}/{tmdb}/recommendations"),
            &[],
            Some(art),
            page,
        )
        .await
    }

    /// `GET {art}/{id}/similar`.
    pub async fn similar(
        &self,
        art: &str,
        tmdb: i64,
        page: u32,
    ) -> Result<Page<TitleCard>, AskError> {
        self.cards(&format!("{art}/{tmdb}/similar"), &[], Some(art), page)
            .await
    }

    /// Recommendations first, then similar titles, each title once. One failing half is dropped;
    /// both failing gives the error.
    pub async fn related(&self, art: &str, tmdb: i64) -> Result<Vec<TitleCard>, AskError> {
        let (a, b) = futures_util::future::join(
            self.recommendations(art, tmdb, 1),
            self.similar(art, tmdb, 1),
        )
        .await;
        match (a, b) {
            (Err(e), Err(_)) => Err(e),
            (a, b) => Ok(unique(
                [a, b]
                    .into_iter()
                    .flat_map(|p| p.map(|p| p.results).unwrap_or_default())
                    .collect(),
            )),
        }
    }

    /// `GET collection/{id}`.
    pub async fn collection(&self, id: i64) -> Result<Collection, AskError> {
        let raw: RawCollection = self.get_json(&format!("collection/{id}"), &[]).await?;
        Ok(Collection {
            id: raw.id,
            name: raw.name.unwrap_or_default(),
            overview: raw.overview.filter(|o| !o.is_empty()),
            poster_path: raw.poster_path,
            backdrop_path: raw.backdrop_path,
            parts: unique(
                raw.parts
                    .into_iter()
                    .filter_map(|p| p.card(Some("movie")))
                    .collect(),
            ),
        })
    }

    /// `GET person/{id}`.
    pub async fn person(&self, tmdb: i64) -> Result<PersonInfo, AskError> {
        self.get_json(&format!("person/{tmdb}"), &[]).await
    }

    /// `GET person/{id}/combined_credits` with Seerr's record of each title.
    pub async fn person_credits(&self, tmdb: i64) -> Result<Credits, AskError> {
        let raw: RawCredits = self
            .get_json(&format!("person/{tmdb}/combined_credits"), &[])
            .await?;
        let cards =
            |v: Vec<RawResult>| unique(v.into_iter().filter_map(|r| r.card(None)).collect());
        Ok(Credits {
            cast: cards(raw.cast),
            crew: cards(raw.crew),
        })
    }

    /// A list endpoint read as title cards.
    pub(crate) async fn cards(
        &self,
        path: &str,
        extra: &[(&str, &str)],
        standard_art: Option<&str>,
        page: u32,
    ) -> Result<Page<TitleCard>, AskError> {
        let page = page.max(1).to_string();
        let mut q: Vec<(&str, &str)> = vec![("page", &page)];
        q.extend_from_slice(extra);
        let raw: RawPage = self.get_json(path, &q).await?;
        Ok(raw.cards(standard_art))
    }
}

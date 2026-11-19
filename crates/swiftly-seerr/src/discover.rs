//! The discover sections of Seerr: trending, popular, upcoming, genres, studios, networks,
//! language, keyword, recently requested.

use swiftly_net::HttpTransport;

use crate::client::{CookieJar, SeerrClient};
use crate::errors::AskError;
use crate::requests::{RequestFilter, RequestQuery};
use crate::types::{GenreCard, Page, TitleCard};

impl<T: HttpTransport, J: CookieJar> SeerrClient<T, J> {
    /// `GET discover/trending`: films and series mixed.
    pub async fn trending(&self, page: u32) -> Result<Page<TitleCard>, AskError> {
        self.cards("discover/trending", &[], None, page).await
    }

    /// `GET discover/movies`.
    pub async fn popular_movies(&self, page: u32) -> Result<Page<TitleCard>, AskError> {
        self.cards("discover/movies", &[], Some("movie"), page)
            .await
    }

    /// `GET discover/tv`.
    pub async fn popular_tv(&self, page: u32) -> Result<Page<TitleCard>, AskError> {
        self.cards("discover/tv", &[], Some("tv"), page).await
    }

    /// `GET discover/movies/upcoming`.
    pub async fn upcoming_movies(&self, page: u32) -> Result<Page<TitleCard>, AskError> {
        self.cards("discover/movies/upcoming", &[], Some("movie"), page)
            .await
    }

    /// `GET discover/tv/upcoming`.
    pub async fn upcoming_tv(&self, page: u32) -> Result<Page<TitleCard>, AskError> {
        self.cards("discover/tv/upcoming", &[], Some("tv"), page)
            .await
    }

    /// `GET discover/genreslider/{movie|tv}`: genre tiles with backdrops.
    pub async fn genre_tiles(&self, art: &str) -> Result<Vec<GenreCard>, AskError> {
        self.get_json(&format!("discover/genreslider/{art}"), &[])
            .await
    }

    /// `GET discover/{movies|tv}/genre/{id}`.
    pub async fn by_genre(
        &self,
        art: &str,
        genre: i64,
        page: u32,
    ) -> Result<Page<TitleCard>, AskError> {
        self.cards(
            &format!("discover/{}/genre/{genre}", plural(art)),
            &[],
            Some(art),
            page,
        )
        .await
    }

    /// `GET discover/movies/studio/{id}`.
    pub async fn by_studio(&self, studio: i64, page: u32) -> Result<Page<TitleCard>, AskError> {
        self.cards(
            &format!("discover/movies/studio/{studio}"),
            &[],
            Some("movie"),
            page,
        )
        .await
    }

    /// `GET discover/tv/network/{id}`.
    pub async fn by_network(&self, network: i64, page: u32) -> Result<Page<TitleCard>, AskError> {
        self.cards(
            &format!("discover/tv/network/{network}"),
            &[],
            Some("tv"),
            page,
        )
        .await
    }

    /// `GET discover/{movies|tv}/language/{code}`.
    pub async fn by_language(
        &self,
        art: &str,
        language: &str,
        page: u32,
    ) -> Result<Page<TitleCard>, AskError> {
        self.cards(
            &format!("discover/{}/language/{language}", plural(art)),
            &[],
            Some(art),
            page,
        )
        .await
    }

    /// `GET discover/keyword/{id}/movies`.
    pub async fn by_keyword(&self, keyword: i64, page: u32) -> Result<Page<TitleCard>, AskError> {
        self.cards(
            &format!("discover/keyword/{keyword}/movies"),
            &[],
            Some("movie"),
            page,
        )
        .await
    }

    /// The newest requests (`GET request?sort=added`), as the "recently requested" slider.
    pub async fn recently_requested(
        &self,
        take: u32,
    ) -> Result<Vec<crate::types::RequestRow>, AskError> {
        let page = self
            .request_list(&RequestQuery {
                filter: RequestFilter::All,
                take,
                ..RequestQuery::default()
            })
            .await?;
        Ok(page.results)
    }
}

fn plural(art: &str) -> &'static str {
    if art == "tv" { "tv" } else { "movies" }
}

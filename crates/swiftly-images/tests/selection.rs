//! `ImageSelectionTests.swift` (11) and `PlexImageTests.swift` (11).

#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::collections::HashMap;
use swiftly_images::{ImageAddress, ImageKind, ImageMetric, ImageSelection, image_key};
use swiftly_jellyfin::{ServerKind, without_secret};
use swiftly_model::Item;
use swiftly_plex::{PlexMapper, PlexMetadata};
use url::Url;

fn jellyfin() -> ImageAddress {
    ImageAddress::new(
        Url::parse("https://tv.example.de").expect("url"),
        Some("abc".into()),
        ServerKind::Jellyfin,
    )
}

fn item(json: &str) -> Item {
    serde_json::from_str(json).expect("item json")
}

// MARK: Landscape: the chain

#[test]
fn series_background_first() {
    let episode = item(
        r#"{"Id":"f1","Name":"Folge","SeriesId":"s1",
         "ParentBackdropItemId":"s1","ParentBackdropImageTags":["bd"],
         "ImageTags":{"Primary":"pp","Thumb":"tt"}}"#,
    );
    let hit = ImageSelection::landscape(&episode, &jellyfin(), 600).expect("hit");
    assert_eq!(hit.source, "Serienhintergrund");
    assert!(hit.url.path().contains("/Items/s1/Images/Backdrop"));
}

#[test]
fn own_background() {
    let film = item(r#"{"Id":"m1","Name":"Film","BackdropImageTags":["bd"]}"#);
    let hit = ImageSelection::landscape(&film, &jellyfin(), 600).expect("hit");
    assert_eq!(hit.source, "eigener Hintergrund");
    assert!(hit.url.path().contains("/Items/m1/Images/Backdrop"));
}

#[test]
fn episodes_still_image_last() {
    let episode =
        item(r#"{"Id":"f1","Name":"Folge","SeriesId":"s1","ImageTags":{"Primary":"pp"}}"#);
    let hit = ImageSelection::landscape(&episode, &jellyfin(), 600).expect("hit");
    assert_eq!(hit.source, "Folgenstandbild");
}

#[test]
fn film_without_background_stays_empty() {
    // Step 5 applies to episodes only: a movie poster in a 16:9 tile looks worse than nothing.
    let film = item(r#"{"Id":"m1","Name":"Film","ImageTags":{"Primary":"pp"}}"#);
    assert_eq!(ImageSelection::landscape(&film, &jellyfin(), 600), None);
}

#[test]
fn without_mark_skipped() {
    // Without a tag the image does not exist, and a guessed address looks like an empty tile.
    let episode = item(
        r#"{"Id":"f1","Name":"Folge","SeriesId":"s1","ParentBackdropItemId":"s1",
         "ImageTags":{"Thumb":"tt"}}"#,
    );
    let hit = ImageSelection::landscape(&episode, &jellyfin(), 600).expect("hit");
    assert_eq!(hit.source, "eigene Vorschau");
}

#[test]
fn nothing_there_means_nothing() {
    let empty = item(r#"{"Id":"x","Name":"Leer"}"#);
    assert_eq!(ImageSelection::landscape(&empty, &jellyfin(), 600), None);
}

// MARK: Portrait

#[test]
fn episode_shows_series_poster() {
    let episode = item(
        r#"{"Id":"f1","Name":"Folge","SeriesId":"s1","SeriesPrimaryImageTag":"sp",
         "ImageTags":{"Primary":"pp"}}"#,
    );
    let url = ImageSelection::portrait(&episode, &jellyfin(), 480).expect("url");
    assert!(url.path().contains("/Items/s1/Images/Primary"));
}

#[test]
fn episode_without_series_mark() {
    let episode =
        item(r#"{"Id":"f1","Name":"Folge","SeriesId":"s1","ImageTags":{"Primary":"pp"}}"#);
    let url = ImageSelection::portrait(&episode, &jellyfin(), 480).expect("url");
    assert!(url.path().contains("/Items/f1/Images/Primary"));
}

#[test]
fn film_poster() {
    let film = item(r#"{"Id":"m1","Name":"Film","ImageTags":{"Primary":"pp"}}"#);
    let url = ImageSelection::portrait(&film, &jellyfin(), 480).expect("url");
    assert!(url.path().contains("/Items/m1/Images/Primary"));
}

// MARK: Watched fraction

#[test]
fn no_bar_for_zero() {
    let unwatched = item(r#"{"Id":"x","Name":"X","UserData":{"PlayedPercentage":0}}"#);
    assert_eq!(unwatched.watched_share(), None);
}

#[test]
fn share_out_of_percent() {
    let half = item(r#"{"Id":"x","Name":"X","UserData":{"PlayedPercentage":42.5}}"#);
    assert_eq!(half.watched_share(), Some(0.425));
}

// MARK: The rest of the rules (header, logo), no Swift test existed

#[test]
fn header_chain_and_fallback() {
    let series = item(r#"{"Id":"s1","Name":"S","Type":"Series","ImageTags":{"Primary":"pp"}}"#);
    let episode =
        item(r#"{"Id":"f1","Name":"F","SeriesId":"s1","ParentBackdropImageTags":["bd"]}"#);
    let a = jellyfin();
    assert_eq!(ImageSelection::header(&series, &a, 1200), None);
    // No head image: the next episode's landscape image, else the poster at head size.
    let via_episode = ImageSelection::header_with_fallback(&series, Some(&episode), &a, 1200)
        .expect("episode image");
    assert!(via_episode.path().contains("/Items/s1/Images/Backdrop"));
    assert!(
        via_episode
            .query()
            .unwrap_or_default()
            .contains("maxWidth=1200")
    );
    let poster = ImageSelection::header_with_fallback(&series, None, &a, 1200).expect("poster");
    assert!(
        poster
            .query()
            .unwrap_or_default()
            .contains("maxHeight=1200")
    );
    // The episode's header is the series' backdrop.
    let url = ImageSelection::header(&episode, &a, 1200).expect("header");
    assert!(url.path().contains("/Items/s1/Images/Backdrop"));
}

#[test]
fn logo_of_episode_is_the_series() {
    let episode = item(r#"{"Id":"f1","Name":"F","SeriesId":"s1","ParentLogoImageTag":"lg"}"#);
    let url = ImageSelection::logo(&episode, &jellyfin(), 240).expect("logo");
    assert!(url.path().contains("/Items/s1/Images/Logo"));
    let film = item(r#"{"Id":"m1","Name":"F","ImageTags":{"Logo":"x"}}"#);
    let url = ImageSelection::logo(&film, &jellyfin(), 240).expect("logo");
    assert!(
        url.as_str()
            .contains("/Items/m1/Images/Logo?tag=x&maxHeight=240")
    );
    assert_eq!(
        ImageSelection::logo(&item(r#"{"Id":"z","Name":"Z"}"#), &jellyfin(), 240),
        None
    );
}

// MARK: PlexImageTests

fn base() -> Url {
    Url::parse("https://plex.example.de:32400").expect("url")
}

fn plex(token: &str) -> ImageAddress {
    ImageAddress::new(base(), Some(token.into()), ServerKind::Plex)
}

fn query(url: Option<&Url>) -> HashMap<String, String> {
    url.map(|u| {
        u.query_pairs()
            .map(|(n, v)| (n.into_owned(), v.into_owned()))
            .collect()
    })
    .unwrap_or_default()
}

#[test]
fn plex_poster() {
    let url = plex("TOK")
        .construct(
            "5",
            ImageKind::Poster,
            Some("/library/metadata/5/thumb/1700"),
            ImageMetric::AtMostHigh(450),
        )
        .expect("url");
    assert_eq!(url.path(), "/photo/:/transcode");
    let q = query(Some(&url));
    assert_eq!(q["url"], "/library/metadata/5/thumb/1700");
    assert_eq!(q["height"], "450");
    assert!(q.contains_key("width"));
    assert_eq!(q["upscale"], "0");
    assert_eq!(q["X-Plex-Token"], "TOK");
}

#[test]
fn plex_background() {
    let url = plex("TOK").construct(
        "5",
        ImageKind::Background,
        Some("/library/metadata/5/art/9"),
        ImageMetric::AtMostWide(1280),
    );
    let q = query(url.as_ref());
    assert_eq!(q["width"], "1280");
    assert!(q.contains_key("height"));
}

#[test]
fn plex_fallback() {
    let a = plex("TOK");
    let thumb = a.construct("5", ImageKind::Poster, None, ImageMetric::AtMostHigh(300));
    assert_eq!(query(thumb.as_ref())["url"], "/library/metadata/5/thumb");
    let art = a.construct(
        "5",
        ImageKind::Background,
        None,
        ImageMetric::AtMostWide(300),
    );
    assert_eq!(query(art.as_ref())["url"], "/library/metadata/5/art");
    assert_eq!(
        a.construct("5", ImageKind::Logo, None, ImageMetric::AtMostWide(300)),
        None
    );
}

#[test]
fn plex_absolute() {
    let full = "https://metadata-static.plex.tv/a.jpg";
    let url = plex("TOK").construct(
        "5",
        ImageKind::Poster,
        Some(full),
        ImageMetric::AtMostHigh(300),
    );
    assert_eq!(url.expect("url").as_str(), full);
}

#[test]
fn plex_user_and_key() {
    let a = plex("TOK");
    assert_eq!(a.user("x", None, 64), None);
    let mark = Some("/library/metadata/5/thumb/1");
    let url_a = a
        .construct("5", ImageKind::Poster, mark, ImageMetric::AtMostHigh(300))
        .expect("a");
    let url_b = plex("OTHER")
        .construct("5", ImageKind::Poster, mark, ImageMetric::AtMostHigh(300))
        .expect("b");
    assert!(!image_key(&url_a).contains("TOK"));
    assert_eq!(image_key(&url_a), image_key(&url_b));
    assert!(!without_secret(&url_a).contains("TOK"));
}

// MARK: Continue watching tile: always landscape

fn mapped(body: &str) -> Item {
    let json = format!("{{{body}}}");
    let value: serde_json::Value = serde_json::from_str(&json).expect("json");
    let metadata = PlexMetadata::parse(&value).expect("metadata");
    PlexMapper::new().item(&metadata)
}

fn pick(item: &Item) -> swiftly_images::Landscape {
    ImageSelection::landscape(item, &plex("TOK"), 640).expect("pick")
}

#[test]
fn plex_landscape_box() {
    let film = mapped(
        r#""ratingKey":"7","type":"movie","title":"F","thumb":"/library/metadata/7/thumb/1","art":"/library/metadata/7/art/2""#,
    );
    let q = query(Some(&pick(&film).url));
    assert_eq!(q["url"], "/library/metadata/7/art/2");
    assert_eq!(q["width"], "640");
    assert_eq!(q["height"], "360");
    assert_eq!(q["minSize"], "1");
}

#[test]
fn plex_film_without_background() {
    let film = mapped(
        r#""ratingKey":"7","type":"movie","title":"F","thumb":"/library/metadata/7/thumb/1""#,
    );
    let q = query(Some(&pick(&film).url));
    assert_eq!(q["url"], "/library/metadata/7/thumb/1");
    assert!(q["height"] == "360" && q["width"] == "640" && q["minSize"] == "1");
}

#[test]
fn plex_episode_without_landscape() {
    let folge = mapped(
        r#""ratingKey":"20","type":"episode","title":"E","grandparentRatingKey":"3","grandparentTitle":"S","grandparentThumb":"/library/metadata/3/thumb/5""#,
    );
    let q = query(Some(&pick(&folge).url));
    assert_eq!(q["url"], "/library/metadata/3/thumb/5");
    assert!(q["height"] == "360" && q["minSize"] == "1");
}

#[test]
fn plex_nothing_known() {
    let folge =
        mapped(r#""ratingKey":"20","type":"episode","title":"E","grandparentRatingKey":"3""#);
    let hit = pick(&folge);
    assert_eq!(hit.source, "Hintergrund ohne Pfad");
    let q = query(Some(&hit.url));
    assert_eq!(q["url"], "/library/metadata/3/art");
    assert!(q["height"] == "360" && q["minSize"] == "1");
}

#[test]
fn plex_series_art_first() {
    let folge = mapped(
        r#""ratingKey":"20","type":"episode","title":"E","thumb":"/library/metadata/20/thumb/1","grandparentRatingKey":"3","grandparentArt":"/library/metadata/3/art/9","grandparentThumb":"/library/metadata/3/thumb/5""#,
    );
    let q = query(Some(&pick(&folge).url));
    assert_eq!(q["url"], "/library/metadata/3/art/9");
    assert_eq!(q["minSize"], "1");
}

#[test]
fn jellyfin_untouched() {
    let other = ImageAddress::new(base(), Some("T".into()), ServerKind::Jellyfin);
    let film = Item {
        id: "1".into(),
        name: "x".into(),
        type_: Some("Movie".into()),
        backdrop_image_tags: Some(vec!["b".into()]),
        image_tags: None::<HashMap<String, String>>,
        ..Item::default()
    };
    let url = ImageSelection::landscape(&film, &other, 640)
        .expect("pick")
        .url;
    assert!(url.as_str().contains("maxWidth=640"));
    assert!(!url.as_str().contains("minSize"));
}

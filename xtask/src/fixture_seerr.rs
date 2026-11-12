//! The Seerr side of `cargo xtask fixture-server` (`/api/v1/...`): just enough of a Jellyseerr for the old-against-new
//! comparisons of the Android facade (search, detail, filmography, request, session check). Deterministic; no cookie
//! is checked (the fixture cannot set one), so a stored session always counts as valid.

pub fn handles(path: &str) -> bool {
    path.starts_with("/api/v1/")
}

fn hit(id: u32, art: &str, title: &str, date: &str, status: Option<u8>) -> String {
    let name = if art == "tv" { "name" } else { "title" };
    let when = if art == "tv" {
        "firstAirDate"
    } else {
        "releaseDate"
    };
    let info = status
        .map(|s| format!(r#","mediaInfo":{{"status":{s}}}"#))
        .unwrap_or_default();
    format!(
        r#"{{"id":{id},"mediaType":"{art}","{name}":"{title}","{when}":"{date}","posterPath":"/p{id}.jpg","backdropPath":"/b{id}.jpg"{info}}}"#
    )
}

fn list() -> String {
    [
        hit(603, "movie", "Matrix Fixture", "1999-03-30", None),
        hit(1399, "tv", "Seerr Serie", "2011-04-17", Some(4)),
        hit(77, "movie", "Already Here", "2001-01-01", Some(5)),
        hit(88, "movie", "Deleted One", "2002-02-02", Some(6)),
        r#"{"id":7,"mediaType":"person","name":"Someone"}"#.into(),
    ]
    .join(",")
}

pub fn answer(method: &str, path: &str) -> Option<String> {
    let rest = path.strip_prefix("/api/v1/")?;
    Some(match (method, rest) {
        ("POST", "auth/jellyfin") => r#"{"id":1}"#.into(),
        ("GET", "auth/me") => r#"{"id":1}"#.into(),
        ("GET", "search") => format!(r#"{{"page":1,"results":[{}]}}"#, list()),
        ("POST", "request") => r#"{"id":1,"status":1}"#.into(),
        ("GET", "person/7/combined_credits") => format!(r#"{{"cast":[{},{}]}}"#, hit(603, "movie", "Matrix Fixture", "1999-03-30", None), hit(77, "movie", "Already Here", "2001-01-01", Some(5))),
        ("GET", "movie/603") => r#"{"overview":"A film.","genres":[{"name":"Action"},{"name":"Sci-Fi"}],"runtime":136,"voteAverage":8.2,"credits":{"cast":[{"id":6384,"name":"Keanu","character":"Neo","profilePath":"/k.jpg"},{"id":9,"name":"No Face"}]},"mediaInfo":{"status":3}}"#.into(),
        ("GET", "tv/1399") => r#"{"overview":"A series.","genres":[{"name":"Drama"}],"episodeRunTime":[55],"voteAverage":9.1,"seasons":[{"seasonNumber":0,"episodeCount":2},{"seasonNumber":1,"episodeCount":10},{"seasonNumber":2,"episodeCount":8}],"credits":{"cast":[{"id":1,"name":"Lead","character":"Hero"}]},"mediaInfo":{"status":4,"seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status":1}]}}"#.into(),
        ("GET", "movie/603/recommendations") | ("GET", "tv/1399/recommendations") => format!(r#"{{"results":[{},{}]}}"#, hit(88, "movie", "Deleted One", "2002-02-02", Some(6)), hit(77, "movie", "Already Here", "2001-01-01", Some(5))),
        _ => return None,
    })
}

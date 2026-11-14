//! The media side of `cargo xtask fixture-server` for the playback bench (`Werkzeuge/wiedergabe-pruefstand.sh`): real files
//! made by `Werkzeuge/pruefstand-medien.py` in the folder named by `SWIFTLY_FIXTURE_MEDIA_DIR`. Titles `bm-*` get an item, a
//! `PlaybackInfo`, the stream and download endpoints (the byte ranges are cut in `fixture_server::serve`) and external subtitle
//! files. Without the variable nothing here answers, so every older answer stays byte identical.

use crate::fixture_server::Reply;
use std::path::PathBuf;

fn dir() -> Option<PathBuf> {
    std::env::var_os("SWIFTLY_FIXTURE_MEDIA_DIR")
        .map(PathBuf::from)
        .filter(|d| d.is_dir())
}

fn read(dir: &std::path::Path, name: &str) -> Option<Vec<u8>> {
    // Names come from the URL: no path tricks out of the folder.
    if name.contains('/') || name.contains("..") {
        return None;
    }
    std::fs::read(dir.join(name))
        .ok()
        .or_else(|| extra_episode_file(dir, name, many_episodes()))
}

/// `SWIFTLY_FIXTURE_MANY_EPISODES=1`: season 1 of the bench series holds ten episodes (a strip that has to scroll).
/// The episodes 5 to 12 have no media of their own; their files are the first episode's with the id and the number
/// changed (the bench media script makes only four).
fn many_episodes() -> bool {
    std::env::var_os("SWIFTLY_FIXTURE_MANY_EPISODES").is_some()
}

fn extra_episode_file(dir: &std::path::Path, name: &str, many: bool) -> Option<Vec<u8>> {
    let rest = name.strip_prefix("bm-ep")?;
    let (digits, ext) = rest.split_once('.')?;
    let n: u32 = digits.parse().ok()?;
    if !many || !(5..=12).contains(&n) {
        return None;
    }
    let bytes = std::fs::read(dir.join(format!("bm-ep1.{ext}"))).ok()?;
    if !ext.ends_with("json") {
        return Some(bytes);
    }
    let number = n - 2;
    let text = String::from_utf8(bytes)
        .ok()?
        .replace("bm-ep1", &format!("bm-ep{n}"))
        .replace("Bench Episode 1", &format!("Bench Episode {number}"))
        .replace(
            r#""IndexNumber": 1"#,
            &format!(r#""IndexNumber": {number}"#),
        );
    Some(text.into_bytes())
}

/// An episode of the bench series carries a still, like every episode a real server holds (the bench media script
/// writes none).
fn with_still(id: &str, json: String) -> String {
    if !id.starts_with("bm-ep") || json.contains("\"ImageTags\"") {
        return json;
    }
    json.replacen(
        r#""Type": "Episode","#,
        &format!(r#""Type": "Episode", "ImageTags": {{"Primary": "p{id}"}},"#),
        1,
    )
}

/// With many episodes the strip needs cards in every state: episode 5 is watched, 7 is 40 % in and 8 is 75 % in (the
/// episodes 1 and 2 stay as the bench media script wrote them, so the plain bench runs do not change).
fn with_progress(id: &str, json: String, many: bool) -> String {
    const UNSEEN: &str = r#""UserData": {"PlaybackPositionTicks": 0, "Played": false}"#;
    let (share, played) = match id {
        "bm-ep5" => (0.0, true),
        "bm-ep7" => (0.4, false),
        "bm-ep8" => (0.75, false),
        _ => return json,
    };
    let run: Option<f64> = json
        .split(r#""RunTimeTicks": "#)
        .nth(1)
        .and_then(|rest| rest.split(|c: char| !c.is_ascii_digit()).next())
        .and_then(|digits| digits.parse().ok());
    let Some(run) = run.filter(|_| many && json.contains(UNSEEN)) else {
        return json;
    };
    // A tick count stays far below 2^53, so the float is exact.
    let position = (run * share).round() as u64;
    json.replacen(
        UNSEEN,
        // A real server sends the share too (`PlayedPercentage`); the app's progress bar reads it.
        &format!(
            r#""UserData": {{"PlaybackPositionTicks": {position}, "PlayedPercentage": {:.1}, "Played": {played}}}"#,
            share * 100.0
        ),
        1,
    )
}

/// The subtitle a client asks for. Like the real server, an ASS / SSA track asked for as `.srt` (the app does that when
/// "keep the file's style" is off) comes back as its own text converted to SRT (`<id>.sub<index>.srt`, made by the
/// media script), not as the plain SRT track of another stream.
fn subtitle_file(dir: &std::path::Path, id: &str, index: &str, ext: &str) -> Option<Vec<u8>> {
    if ext == "srt"
        && let Some(converted) = read(dir, &format!("{id}.sub{index}.srt"))
    {
        return Some(converted);
    }
    read(dir, &format!("cues.{ext}"))
}

fn kind_of(file: &str) -> &'static str {
    match file.rsplit('.').next().unwrap_or("") {
        "mp4" | "m4v" => "video/mp4",
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        "ts" => "video/mp2t",
        "avi" => "video/x-msvideo",
        "srt" => "application/x-subrip",
        "ass" | "ssa" => "text/x-ssa",
        "vtt" => "text/vtt",
        _ => "application/octet-stream",
    }
}

fn json(body: Vec<u8>) -> Reply {
    Reply(200, "application/json", body)
}

fn series_item(dir: &std::path::Path) -> Option<String> {
    let _ = dir;
    Some(r#"{"Id":"bm-series","Name":"Bench Series","Type":"Series","ChildCount":2,"UserData":{"UnplayedItemCount":4,"Played":false}}"#.into())
}

fn season_item(n: u32, name: &str) -> String {
    format!(
        r#"{{"Id":"bm-s{n}","Name":"{name}","Type":"Season","IndexNumber":{n},"SeriesId":"bm-series","SeriesName":"Bench Series","ChildCount":2}}"#
    )
}

/// The answer for a `bm-*` request, or `None` (the caller goes on with the older routes).
pub(crate) fn answer(path: &str, query: &str) -> Option<Reply> {
    answer_in(&dir()?, path, query)
}

fn answer_in(dir: &std::path::Path, path: &str, query: &str) -> Option<Reply> {
    let dir = dir.to_path_buf();
    let param = |k: &str| {
        query.split('&').find_map(|p| {
            p.split_once('=')
                .filter(|(n, _)| *n == k)
                .map(|(_, v)| v.to_owned())
        })
    };
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    let list = |items: Vec<String>| {
        let n = items.len();
        json(
            format!(
                r#"{{"Items":[{}],"TotalRecordCount":{n},"StartIndex":0}}"#,
                items.join(",")
            )
            .into_bytes(),
        )
    };
    let item = |id: &str| {
        read(&dir, &format!("{id}.item.json"))
            .map(|b| with_still(id, String::from_utf8_lossy(&b).into_owned()))
            .map(|json| with_progress(id, json, many_episodes()))
    };
    match parts.as_slice() {
        // Item detail: /Users/<u>/Items/<id> and /Items/<id>.
        [.., "Items", id] if id.starts_with("bm-") => {
            if *id == "bm-series" {
                return series_item(&dir).map(|s| json(s.into_bytes()));
            }
            Some(item(id).map_or_else(
                || Reply(404, "text/plain", Vec::new()),
                |s| json(s.into_bytes()),
            ))
        }
        [.., "Items"] if param("ids").is_some_and(|ids| ids.starts_with("bm-")) => {
            let ids = param("ids").unwrap_or_default();
            Some(list(ids.split(',').filter_map(&item).collect()))
        }
        ["Items", id, "PlaybackInfo"] if id.starts_with("bm-") => Some(
            read(&dir, &format!("{id}.info.json"))
                .map_or_else(|| Reply(404, "text/plain", Vec::new()), json),
        ),
        ["Shows", "bm-series", "Seasons"] => Some(list(vec![
            season_item(1, "Staffel 1"),
            season_item(2, "Staffel 2"),
        ])),
        // Like a real server: with `seasonId` the episodes of that season, without it all of them.
        ["Shows", "bm-series", "Episodes"] => {
            let season = param("seasonId").or_else(|| param("SeasonId"));
            let ids: &[&str] = match season.as_deref() {
                Some("bm-s1") if many_episodes() => &[
                    "bm-ep1", "bm-ep2", "bm-ep5", "bm-ep6", "bm-ep7", "bm-ep8", "bm-ep9",
                    "bm-ep10", "bm-ep11", "bm-ep12",
                ],
                Some("bm-s1") => &["bm-ep1", "bm-ep2"],
                Some("bm-s2") => &["bm-ep3", "bm-ep4"],
                Some(_) => &[],
                None => &["bm-ep1", "bm-ep2", "bm-ep3", "bm-ep4"],
            };
            Some(list(ids.iter().filter_map(|i| item(i)).collect()))
        }
        ["Shows", "NextUp"] if param("seriesId").as_deref() == Some("bm-series") => {
            Some(list(item("bm-ep2").into_iter().collect()))
        }
        ["Videos", id, last]
            if id.starts_with("bm-") && (*last == "stream" || last.starts_with("stream.")) =>
        {
            let media = String::from_utf8(read(&dir, &format!("{id}.media"))?).ok()?;
            // A server remux down to one audio track (the built download): a file written to a pipe, no duration in its header.
            let single = param("audioStreamIndex")
                .or_else(|| param("AudioStreamIndex"))
                .filter(|_| last.contains(".mkv") && param("static").as_deref() == Some("false"));
            let file = single
                .map(|n| format!("{id}.a{n}.mkv"))
                .filter(|f| dir.join(f).is_file())
                .unwrap_or(media);
            let kind = kind_of(&file);
            Some(read(&dir, &file).map_or_else(
                || Reply(404, "text/plain", Vec::new()),
                |b| Reply(200, kind, b),
            ))
        }
        ["Items", id, "Download"] | ["Items", id, "File"] if id.starts_with("bm-") => {
            let media = String::from_utf8(read(&dir, &format!("{id}.media"))?).ok()?;
            let kind = kind_of(&media);
            Some(read(&dir, &media).map_or_else(
                || Reply(404, "text/plain", Vec::new()),
                |b| Reply(200, kind, b),
            ))
        }
        ["Videos", id, _, "Subtitles", index, .., last] if id.starts_with("bm-") => {
            let ext = last.rsplit('.').next().unwrap_or("srt");
            let kind = kind_of(&format!("x.{ext}"));
            Some(subtitle_file(&dir, id, index, ext).map_or_else(
                || Reply(404, "text/plain", Vec::new()),
                |b| Reply(200, kind, b),
            ))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{answer_in, subtitle_file};

    #[test]
    fn the_bench_series_has_two_seasons_with_two_episodes_each() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../target/fixture-media-seasons");
        std::fs::create_dir_all(&dir).unwrap();
        for n in 1..=4 {
            let season = if n <= 2 { 1 } else { 2 };
            std::fs::write(
                dir.join(format!("bm-ep{n}.item.json")),
                format!(r#"{{"Id":"bm-ep{n}","Type":"Episode","SeasonId":"bm-s{season}"}}"#),
            )
            .unwrap();
        }
        let body = |path: &str, query: &str| {
            String::from_utf8(answer_in(&dir, path, query).expect("answered").2).unwrap()
        };
        let seasons = body("/Shows/bm-series/Seasons", "userId=u1");
        assert!(seasons.contains(r#""Id":"bm-s1""#) && seasons.contains(r#""Id":"bm-s2""#));
        let two = body("/Shows/bm-series/Episodes", "seasonId=bm-s2");
        assert!(two.contains("bm-ep3") && two.contains("bm-ep4") && !two.contains("bm-ep1"));
        let one = body("/Shows/bm-series/Episodes", "seasonId=bm-s1");
        assert!(one.contains("bm-ep1") && !one.contains("bm-ep3"));
        assert!(body("/Shows/bm-series/Episodes", "").contains("bm-ep4"));
        assert!(body("/Shows/bm-series/Episodes", "seasonId=nope").contains(r#""Items":[]"#));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn bench_episodes_carry_a_still_and_many_episodes_make_extra_files() {
        use super::{extra_episode_file, with_progress, with_still};
        let one =
            r#"{"Id": "bm-ep1", "Name": "Bench Episode 1", "Type": "Episode", "IndexNumber": 1}"#;
        let tagged = with_still("bm-ep1", one.to_owned());
        assert!(
            tagged.contains(r#""ImageTags": {"Primary": "pbm-ep1"}"#),
            "{tagged}"
        );
        // Not twice, and only episodes.
        assert_eq!(with_still("bm-ep1", tagged.clone()), tagged);
        assert_eq!(with_still("bm-h264", one.to_owned()), one);
        let dir =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../target/fixture-media-many");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("bm-ep1.item.json"), one).unwrap();
        // Off by default: no file for episode 7.
        assert!(extra_episode_file(&dir, "bm-ep7.item.json", false).is_none());
        let seven =
            String::from_utf8(extra_episode_file(&dir, "bm-ep7.item.json", true).unwrap()).unwrap();
        assert!(
            seven.contains(r#""Id": "bm-ep7""#)
                && seven.contains("Bench Episode 5")
                && seven.contains(r#""IndexNumber": 5"#),
            "{seven}"
        );
        assert!(extra_episode_file(&dir, "bm-ep13.item.json", true).is_none());
        // Progress and the watched mark only with many episodes, and only on the named ones.
        let unseen = r#"{"Id": "bm-ep7", "RunTimeTicks": 100000000, "UserData": {"PlaybackPositionTicks": 0, "Played": false}}"#;
        let part = with_progress("bm-ep7", unseen.to_owned(), true);
        assert!(
            part.contains(r#""PlaybackPositionTicks": 40000000, "PlayedPercentage": 40.0"#),
            "{part}"
        );
        let seen = with_progress("bm-ep5", unseen.to_owned(), true);
        assert!(seen.contains(r#""Played": true"#), "{seen}");
        assert_eq!(with_progress("bm-ep7", unseen.to_owned(), false), unseen);
        assert_eq!(with_progress("bm-ep6", unseen.to_owned(), true), unseen);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_ass_track_asked_for_as_srt_comes_back_as_its_own_text() {
        let dir =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../target/fixture-media-test");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("cues.srt"), "plain srt").unwrap();
        std::fs::write(dir.join("cues.ass"), "plain ass").unwrap();
        std::fs::write(dir.join("bm-x.sub3.srt"), "ass as srt").unwrap();
        assert_eq!(
            subtitle_file(&dir, "bm-x", "3", "srt").unwrap(),
            b"ass as srt"
        );
        assert_eq!(
            subtitle_file(&dir, "bm-x", "2", "srt").unwrap(),
            b"plain srt"
        );
        assert_eq!(
            subtitle_file(&dir, "bm-x", "3", "ass").unwrap(),
            b"plain ass"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

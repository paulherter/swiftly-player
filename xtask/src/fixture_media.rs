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
    std::fs::read(dir.join(name)).ok()
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
    Some(r#"{"Id":"bm-series","Name":"Bench Series","Type":"Series","ChildCount":1,"UserData":{"UnplayedItemCount":2,"Played":false}}"#.into())
}

/// The answer for a `bm-*` request, or `None` (the caller goes on with the older routes).
pub(crate) fn answer(path: &str, query: &str) -> Option<Reply> {
    let dir = dir()?;
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
        read(&dir, &format!("{id}.item.json")).map(|b| String::from_utf8_lossy(&b).into_owned())
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
        ["Shows", "bm-series", "Episodes"] => Some(list(
            ["bm-ep1", "bm-ep2"]
                .iter()
                .filter_map(|i| item(i))
                .collect(),
        )),
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
    use super::subtitle_file;

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

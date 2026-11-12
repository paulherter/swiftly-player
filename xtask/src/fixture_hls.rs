//! The server-transcode side of the playback bench (`Werkzeuge/wiedergabe-pruefstand.sh`): HLS made by ffmpeg in
//! `<SWIFTLY_FIXTURE_MEDIA_DIR>/<id>.hls/` by `Werkzeuge/pruefstand-medien.py` (master and variant playlists, fMP4 or TS
//! segments, the bitmap subtitle already burned into the picture). A title with an `<id>.info.transcode.json` answers its
//! `PlaybackInfo` like Jellyfin does: the direct answer for a client that may play the file, the transcode answer (an HLS
//! `TranscodingUrl`, no direct play) when the request turns direct play off or its bitrate limit is below the title's
//! `Bitrate`. Without the variable or the files nothing here answers, so every other answer stays byte identical.

use crate::fixture_server::Reply;
use std::path::{Path, PathBuf};

fn dir() -> Option<PathBuf> {
    std::env::var_os("SWIFTLY_FIXTURE_MEDIA_DIR")
        .map(PathBuf::from)
        .filter(|d| d.is_dir())
}

fn read(path: &Path) -> Option<Vec<u8>> {
    std::fs::read(path).ok()
}

fn kind_of(file: &str) -> &'static str {
    match file.rsplit('.').next().unwrap_or("") {
        "m3u8" => "application/vnd.apple.mpegurl",
        "ts" => "video/mp2t",
        "m4s" => "video/iso.segment",
        "mp4" => "video/mp4",
        _ => "application/octet-stream",
    }
}

/// The number after `"<key>":` in a JSON text (the fixture has no JSON library); spaces are ignored.
fn number_after(text: &str, key: &str) -> Option<u64> {
    let squeezed: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    let from = squeezed.find(&format!("\"{key}\":"))? + key.len() + 3;
    let digits: String = squeezed[from..]
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse().ok()
}

/// Whether the request asks for a transcode: direct play off, or a streaming bitrate limit under the title's bitrate.
pub(crate) fn wants_transcode(request_body: &str, direct_info: &str) -> bool {
    let squeezed: String = request_body
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    if squeezed.contains("\"EnableDirectPlay\":false") {
        return true;
    }
    match (
        number_after(&squeezed, "MaxStreamingBitrate"),
        number_after(direct_info, "Bitrate"),
    ) {
        (Some(limit), Some(bitrate)) => bitrate > limit,
        _ => false,
    }
}

/// The transcode answer for a request that names a subtitle track (the client's re-plan after the viewer picked a bitmap
/// track): like Jellyfin, the stream address then carries `SubtitleStreamIndex=<n>` and the picture comes with the track burned
/// in. The burned stream lives in the folder `<name>-burn<n>.hls` (made by `pruefstand-medien.py`); the plain folder
/// `<name>.hls` has no subtitle in the picture. Without such a folder the answer stays as it is.
fn with_burned_track(dir: &Path, answer: &str, request_body: &str) -> String {
    let Some(n) = number_after(request_body, "SubtitleStreamIndex") else {
        return answer.to_owned();
    };
    let Some(at) = answer.find("/videos/") else {
        return answer.to_owned();
    };
    let name: String = answer[at + 8..].chars().take_while(|c| *c != '/').collect();
    if !dir.join(format!("{name}-burn{n}.hls")).is_dir() {
        return answer.to_owned();
    }
    answer
        .replace(
            &format!("/videos/{name}/"),
            &format!("/videos/{name}-burn{n}/"),
        )
        .replace(
            "SubtitleMethod=Encode",
            &format!("SubtitleMethod=Encode&SubtitleStreamIndex={n}"),
        )
}

/// The answer for a title with an HLS folder, or `None` (the caller goes on with the older routes).
pub(crate) fn answer(method: &str, path: &str, body: &str) -> Option<Reply> {
    answer_in(&dir()?, method, path, body)
}

fn answer_in(dir: &Path, method: &str, path: &str, body: &str) -> Option<Reply> {
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    match parts.as_slice() {
        ["Items", id, "PlaybackInfo"]
            if id.starts_with("bm-") && dir.join(format!("{id}.info.transcode.json")).is_file() =>
        {
            let direct = read(&dir.join(format!("{id}.info.json")))?;
            let direct_text = String::from_utf8_lossy(&direct).into_owned();
            let file = if method == "POST" && wants_transcode(body, &direct_text) {
                format!("{id}.info.transcode.json")
            } else {
                format!("{id}.info.json")
            };
            Some(read(&dir.join(&file)).map_or_else(
                || Reply(404, "text/plain", Vec::new()),
                |b| {
                    let text = String::from_utf8_lossy(&b).into_owned();
                    Reply(
                        200,
                        "application/json",
                        with_burned_track(dir, &text, body).into_bytes(),
                    )
                },
            ))
        }
        // `/videos/<id>/master.m3u8`, `main.m3u8`, `init.mp4`, `seg<N>.m4s|ts`: only names that exist in the title's HLS folder
        // (so `/Videos/<id>/stream` and the downloads still go to the media routes).
        ["videos" | "Videos", id, name]
            if id.starts_with("bm-") && !name.contains("..") && !name.contains('/') =>
        {
            let file = dir.join(format!("{id}.hls")).join(name);
            file.is_file().then(|| {
                read(&file).map_or_else(
                    || Reply(404, "text/plain", Vec::new()),
                    |b| Reply(200, kind_of(name), b),
                )
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_play_off_asks_for_the_transcode() {
        assert!(wants_transcode(
            r#"{"EnableDirectPlay": false, "MaxStreamingBitrate": 1}"#,
            "{}"
        ));
        assert!(!wants_transcode(r#"{"EnableDirectPlay":true}"#, "{}"));
    }

    #[test]
    fn a_limit_under_the_bitrate_asks_for_the_transcode() {
        let info = r#"{"MediaSources":[{"Bitrate": 200000000}]}"#;
        assert!(wants_transcode(
            r#"{"MaxStreamingBitrate":120000000}"#,
            info
        ));
        assert!(!wants_transcode(
            r#"{"MaxStreamingBitrate":250000000}"#,
            info
        ));
        assert!(!wants_transcode(
            r#"{"MaxStreamingBitrate":120000000}"#,
            "{}"
        ));
    }

    #[test]
    fn segment_names_cannot_leave_the_folder() {
        assert!(answer("GET", "/videos/bm-x/../secret", "").is_none());
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("fixture-hls-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("bm-t.hls")).unwrap();
        std::fs::create_dir_all(d.join("bm-t-burn3.hls")).unwrap();
        std::fs::write(
            d.join("bm-t.info.json"),
            r#"{"MediaSources":[{"Bitrate":1}]}"#,
        )
        .unwrap();
        std::fs::write(
            d.join("bm-t.info.transcode.json"),
            r#"{"MediaSources":[{"TranscodingUrl":"/videos/bm-t/master.m3u8?MediaSourceId=s&SubtitleMethod=Encode"}]}"#,
        )
        .unwrap();
        d
    }

    #[test]
    fn a_re_plan_with_a_bitmap_track_answers_the_stream_with_it_burned_in() {
        let d = scratch("burn");
        let ask = r#"{"EnableDirectPlay":false,"SubtitleStreamIndex":3}"#;
        let Reply(code, _, bytes) = answer_in(&d, "POST", "/Items/bm-t/PlaybackInfo", ask).unwrap();
        let text = String::from_utf8(bytes).unwrap();
        assert_eq!(code, 200);
        assert!(text.contains("/videos/bm-t-burn3/master.m3u8"), "{text}");
        assert!(
            text.contains("SubtitleMethod=Encode&SubtitleStreamIndex=3"),
            "{text}"
        );
        // No track named, or one without a burned folder: the plain stream.
        for plain in [
            r#"{"EnableDirectPlay":false}"#,
            r#"{"EnableDirectPlay":false,"SubtitleStreamIndex":-1}"#,
            r#"{"EnableDirectPlay":false,"SubtitleStreamIndex":5}"#,
        ] {
            let Reply(_, _, bytes) =
                answer_in(&d, "POST", "/Items/bm-t/PlaybackInfo", plain).unwrap();
            let text = String::from_utf8(bytes).unwrap();
            assert!(
                text.contains("/videos/bm-t/master.m3u8") && !text.contains("burn"),
                "{text}"
            );
        }
        let _ = std::fs::remove_dir_all(&d);
    }
}

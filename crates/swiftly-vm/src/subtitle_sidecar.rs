//! What a download remembers about its external subtitle files. The files lie in `<file>.untertitel/<index>.<ext>`; the
//! facts the track list needs (language, title, forced, hearing impaired, codec) come from the server's stream rows and are
//! stored next to them in `info.json` (never an address or a key), so offline rows read like online rows.

use serde::{Deserialize, Serialize};
use std::path::Path;
use swiftly_model::MediaStream;

/// The sidecar's file name; it has no numeric stem, so the readers of the folder skip it.
pub const SIDECAR_NAME: &str = "info.json";

/// One subtitle file's facts.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubtitleMeta {
    /// The server's numbering of the stream (the file's name).
    pub index: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    /// ISO language code as the server gives it.
    pub language: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    /// The file's own title ("Signs").
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    /// The server's codec name (`subrip`, `ass`).
    pub codec: Option<String>,
    #[serde(default)]
    /// Shown only for forced lines.
    pub forced: bool,
    #[serde(default)]
    /// Contains sound descriptions.
    pub hearing_impaired: bool,
}

impl SubtitleMeta {
    /// The facts of a server stream row stored under `index`.
    pub fn of(stream: &MediaStream, index: i64) -> Self {
        Self {
            index,
            language: stream.language.clone(),
            title: stream.title.clone(),
            codec: stream.codec.clone(),
            forced: stream.is_forced == Some(true),
            hearing_impaired: stream.is_hearing_impaired == Some(true),
        }
    }
}

/// One row of the download's subtitle list: what to fetch, how to store it and what it is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubtitleRow {
    /// The server's numbering of the stream.
    pub index: i64,
    /// Where to fetch it.
    pub address: String,
    /// The file ending to store it under.
    pub ending: String,
    /// What the file is.
    pub meta: SubtitleMeta,
}

/// The rows of `DetailOf::download_subtitle_files` (`[{"index","adresse","endung","meta"}]`).
pub fn parse_rows(json: &str) -> Vec<SubtitleRow> {
    let Ok(serde_json::Value::Array(rows)) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|r| {
            let index = r.get("index")?.as_i64()?;
            let meta = r
                .get("meta")
                .and_then(|m| serde_json::from_value(m.clone()).ok())
                .unwrap_or(SubtitleMeta {
                    index,
                    ..SubtitleMeta::default()
                });
            Some(SubtitleRow {
                index,
                address: r.get("adresse")?.as_str()?.to_owned(),
                ending: r.get("endung")?.as_str()?.to_owned(),
                meta,
            })
        })
        .collect()
}

/// Stores the facts of `rows` in `folder` (call after the files are there; only the files that were fetched count).
pub fn write(folder: &Path, metas: &[SubtitleMeta]) {
    if metas.is_empty() {
        return;
    }
    if let Ok(text) = serde_json::to_string(metas) {
        let _ = std::fs::write(folder.join(SIDECAR_NAME), text);
    }
}

fn read_metas(folder: &Path) -> Vec<SubtitleMeta> {
    std::fs::read_to_string(folder.join(SIDECAR_NAME))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// The subtitle streams of the files in `folder` (sorted by index): the sidecar's facts where there are some, otherwise
/// only the format from the file ending. Empty without a folder.
pub fn streams(folder: &Path) -> Vec<MediaStream> {
    let metas = read_metas(folder);
    let mut found: Vec<(i64, String)> = std::fs::read_dir(folder)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let (index, ext) = name.split_once('.')?;
            Some((index.parse::<i64>().ok()?, ext.to_ascii_lowercase()))
        })
        .collect();
    found.sort_by_key(|f| f.0);
    found
        .into_iter()
        .map(|(index, ext)| {
            let meta = metas.iter().find(|m| m.index == index);
            MediaStream {
                index: Some(index),
                type_: Some("Subtitle".into()),
                codec: meta.and_then(|m| m.codec.clone()).or_else(|| {
                    Some(
                        match ext.as_str() {
                            "srt" => "subrip",
                            "vtt" => "webvtt",
                            other => other,
                        }
                        .to_owned(),
                    )
                }),
                language: meta.and_then(|m| m.language.clone()),
                title: meta.and_then(|m| m.title.clone()),
                is_forced: Some(meta.is_some_and(|m| m.forced)),
                is_hearing_impaired: Some(meta.is_some_and(|m| m.hearing_impaired)),
                is_external: Some(true),
                ..MediaStream::default()
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("sidecar-{tag}-{}", std::process::id()));
        std::fs::remove_dir_all(&d).ok();
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn the_sidecar_gives_the_files_their_language_title_and_flags() {
        let d = folder("meta");
        std::fs::write(d.join("3.srt"), "a").unwrap();
        std::fs::write(d.join("4.srt"), "a").unwrap();
        write(
            &d,
            &[
                SubtitleMeta {
                    index: 3,
                    language: Some("eng".into()),
                    codec: Some("subrip".into()),
                    ..Default::default()
                },
                SubtitleMeta {
                    index: 4,
                    language: Some("eng".into()),
                    title: Some("Signs".into()),
                    codec: Some("subrip".into()),
                    forced: true,
                    ..Default::default()
                },
            ],
        );
        let s = streams(&d);
        std::fs::remove_dir_all(&d).ok();
        assert_eq!(s.len(), 2, "info.json is no subtitle");
        assert_eq!(s[0].language.as_deref(), Some("eng"));
        assert_eq!(
            (s[1].title.as_deref(), s[1].is_forced),
            (Some("Signs"), Some(true))
        );
        assert!(
            !serde_json::to_string(&s).unwrap().contains("http"),
            "no address is kept"
        );
    }

    #[test]
    fn an_old_download_without_a_sidecar_keeps_its_format() {
        let d = folder("old");
        std::fs::write(d.join("2.vtt"), "a").unwrap();
        let s = streams(&d);
        std::fs::remove_dir_all(&d).ok();
        assert_eq!(
            (
                s[0].language.clone(),
                s[0].codec.as_deref(),
                s[0].is_external
            ),
            (None, Some("webvtt"), Some(true))
        );
        assert!(streams(Path::new("/nonexistent/x.untertitel")).is_empty());
    }

    #[test]
    fn rows_carry_their_facts_and_old_rows_still_parse() {
        let rows = parse_rows(
            r#"[{"index":3,"adresse":"http://h/x.srt","endung":"srt","meta":{"index":3,"language":"deu","forced":true}},{"index":4,"adresse":"a","endung":"ass"}]"#,
        );
        assert_eq!(
            (rows[0].meta.language.as_deref(), rows[0].meta.forced),
            (Some("deu"), true)
        );
        assert_eq!(rows[1].meta.index, 4);
    }
}

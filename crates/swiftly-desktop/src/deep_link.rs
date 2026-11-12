//! What the OS hands to the app besides clicks: `swiftly://` links (same paths as the Apple apps, see
//! `Sources/Shared`: `swiftly://titel/<id>`, `swiftly://abspielen/<id>`), video files dropped on the window or passed
//! as arguments (file association, "Open with"), parsed into a typed value. Links are routed by `link_route` and
//! the suite; [`open`] only names what a launch asks for (log line, and the file case).

use std::path::{Path, PathBuf};

/// A `swiftly://` link.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeepLink {
    /// `swiftly://titel/<id>` (also `title`, `item`): the detail page of a title.
    Title(String),
    /// `swiftly://abspielen/<id>` (also `play`): start playing a title.
    Play(String),
    /// `swiftly://suche?q=<text>` or `swiftly://suche/<text>` (also `search`): the search tab with a query.
    Search(String),
    /// `swiftly://einstellungen` (also `settings`).
    Settings,
    /// `swiftly://start` (also `home`).
    Home,
}

/// One thing to open.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Launch {
    /// A parsed link.
    Link(DeepLink),
    /// A local video file (dropped on the window, or an argument).
    File(PathBuf),
}

/// File extensions the player takes as "open this file".
pub const VIDEO_EXTENSIONS: [&str; 9] = [
    "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "wmv",
];

fn percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' => {
                let hex = s.get(i + 1..i + 3)?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

/// A title id: Jellyfin ids are hex, with or without dashes; nothing else is let through (no path tricks).
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Parses one `swiftly://` link. `None` for another scheme, an unknown host or a bad id.
pub fn parse_link(link: &str) -> Option<DeepLink> {
    let (scheme, rest) = link.trim().split_once("://")?;
    if !scheme.eq_ignore_ascii_case("swiftly") {
        return None;
    }
    let rest = rest.split('#').next().unwrap_or("");
    let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
    let mut parts = path.trim_matches('/').splitn(2, '/');
    let host = parts.next().unwrap_or("").to_ascii_lowercase();
    let tail = parts.next().unwrap_or("").trim_end_matches('/');
    match host.as_str() {
        "titel" | "title" | "item" => valid_id(tail).then(|| DeepLink::Title(tail.to_owned())),
        "abspielen" | "play" => valid_id(tail).then(|| DeepLink::Play(tail.to_owned())),
        "suche" | "search" => {
            let q = query
                .split('&')
                .find_map(|kv| kv.strip_prefix("q="))
                .map_or_else(|| percent_decode(tail), percent_decode)?;
            Some(DeepLink::Search(q.trim().to_owned()))
        }
        "einstellungen" | "settings" if tail.is_empty() => Some(DeepLink::Settings),
        "start" | "home" if tail.is_empty() => Some(DeepLink::Home),
        _ => None,
    }
}

/// Whether `path` looks like a video file by its extension.
pub fn is_video(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| VIDEO_EXTENSIONS.iter().any(|v| e.eq_ignore_ascii_case(v)))
}

/// What the command line asks for: links and video files, in order. Flags and everything else are skipped.
pub fn parse_args<I: IntoIterator<Item = String>>(args: I) -> Vec<Launch> {
    args.into_iter()
        .filter_map(|a| {
            if a.starts_with('-') {
                None
            } else if a.contains("://") {
                parse_link(&a).map(Launch::Link)
            } else {
                let p = PathBuf::from(&a);
                is_video(&p).then_some(Launch::File(p))
            }
        })
        .collect()
}

/// Names what a launch asks for, for the log. A file that is not there is reported, not opened.
pub fn open(l: &Launch) -> String {
    match l {
        Launch::Link(DeepLink::Title(id)) => format!("open title page {id}"),
        Launch::Link(DeepLink::Play(id)) => format!("play title {id}"),
        Launch::Link(DeepLink::Search(q)) => format!("search for {q:?}"),
        Launch::Link(DeepLink::Settings) => "open settings".to_owned(),
        Launch::Link(DeepLink::Home) => "open start".to_owned(),
        Launch::File(p) if p.is_file() => format!("open local file {}", p.display()),
        Launch::File(p) => format!("ignored: {} is not a file", p.display()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_parse_into_the_enum() {
        assert_eq!(
            parse_link("swiftly://titel/abc-123"),
            Some(DeepLink::Title("abc-123".into()))
        );
        assert_eq!(
            parse_link("SWIFTLY://Title/abc/"),
            Some(DeepLink::Title("abc".into()))
        );
        assert_eq!(
            parse_link("swiftly://abspielen/ff00"),
            Some(DeepLink::Play("ff00".into()))
        );
        assert_eq!(
            parse_link("swiftly://suche?q=the%20lighthouse"),
            Some(DeepLink::Search("the lighthouse".into()))
        );
        assert_eq!(
            parse_link("swiftly://search/dune+2"),
            Some(DeepLink::Search("dune 2".into()))
        );
        assert_eq!(parse_link("swiftly://settings"), Some(DeepLink::Settings));
        assert_eq!(parse_link("swiftly://start/"), Some(DeepLink::Home));
    }

    #[test]
    fn bad_links_are_refused() {
        for bad in [
            "https://titel/abc",
            "swiftly://titel/",
            "swiftly://titel/../etc",
            "swiftly://titel/a b",
            "swiftly://unbekannt/1",
            "swiftly://settings/extra",
            "swiftly://suche?q=%zz",
            "swiftly:titel/1",
            "",
        ] {
            assert_eq!(parse_link(bad), None, "{bad}");
        }
    }

    #[test]
    fn arguments_keep_links_and_videos_only() {
        let args = [
            "--stats",
            "swiftly://titel/1",
            "C:\\v\\Film.MKV",
            "notes.txt",
            "/tmp/a.mp4",
            "https://x/y.mp4",
        ];
        let got = parse_args(args.iter().map(|s| (*s).to_owned()));
        assert_eq!(
            got,
            vec![
                Launch::Link(DeepLink::Title("1".into())),
                Launch::File(PathBuf::from("C:\\v\\Film.MKV")),
                Launch::File(PathBuf::from("/tmp/a.mp4")),
            ]
        );
    }

    #[test]
    fn the_log_line_names_what_was_asked() {
        assert_eq!(
            open(&Launch::Link(DeepLink::Play("9".into()))),
            "play title 9"
        );
        assert!(open(&Launch::File(PathBuf::from("/no/such/file.mkv"))).starts_with("ignored"));
    }
}

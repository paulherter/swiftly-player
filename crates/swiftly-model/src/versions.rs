use crate::media::MediaSource;

/// Several versions of one title (JellyfinKit/MediaVersions.swift:6): 4K next
/// to 1080p, theatrical cut next to the extended one.
#[derive(Debug, Clone, Copy)]
pub struct MediaVersions;

/// The answer of [`MediaVersions::start`] (MediaVersions.swift:50).
#[derive(Debug, Clone, PartialEq)]
pub enum VersionStart {
    /// `MediaSources` not loaded yet: the play button waits.
    Wait,
    /// One version, or the copy on the device: start it.
    Play,
    /// Several versions: ask which one.
    Choose(Vec<MediaSource>),
}

impl MediaVersions {
    /// The sources worth choosing between: more than one, each with an id
    /// (MediaVersions.swift:10). Fewer than two means no choice.
    pub fn choices(sources: Option<&[MediaSource]>) -> Vec<MediaSource> {
        let usable: Vec<MediaSource> = sources
            .unwrap_or_default()
            .iter()
            .filter(|s| s.id.is_some())
            .cloned()
            .collect();
        if usable.len() > 1 { usable } else { Vec::new() }
    }

    /// What a start does about versions (MediaVersions.swift:24). `None` means
    /// "not loaded yet" (a list entry), not "only one version".
    pub fn start(sources: Option<&[MediaSource]>, downloaded: bool) -> VersionStart {
        if downloaded {
            return VersionStart::Play;
        }
        let Some(sources) = sources else {
            return VersionStart::Wait;
        };
        let offered = Self::choices(Some(sources));
        if offered.is_empty() {
            VersionStart::Play
        } else {
            VersionStart::Choose(offered)
        }
    }

    /// The version to keep for the next episode (MediaVersions.swift:35): the
    /// one with the same name (trimmed, case-insensitive), otherwise the one
    /// with the same resolution; `None` if neither exists.
    pub fn matching(previous: &MediaSource, next: Option<&[MediaSource]>) -> Option<MediaSource> {
        let usable: Vec<&MediaSource> = next
            .unwrap_or_default()
            .iter()
            .filter(|s| s.id.is_some())
            .collect();
        if usable.len() <= 1 {
            return None;
        }
        if let Some(name) = previous
            .name
            .as_deref()
            .map(swiftly_rules::trim_name)
            .filter(|n| !n.is_empty())
            && let Some(same) = usable.iter().find(|s| {
                s.name.as_deref().is_some_and(|n| {
                    swiftly_rules::case_insensitive_equal(swiftly_rules::trim_name(n), name)
                })
            })
        {
            return Some((*same).clone());
        }
        if let Some(height) = previous.height().filter(|h| *h > 0) {
            return usable
                .into_iter()
                .find(|s| s.height() == Some(height))
                .cloned();
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::MediaStream;

    fn src(id: Option<&str>, name: &str, height: i64) -> MediaSource {
        MediaSource {
            id: id.map(Into::into),
            name: Some(name.into()),
            media_streams: Some(vec![MediaStream {
                type_: Some("Video".into()),
                height: Some(height),
                codec: Some("hevc".into()),
                ..Default::default()
            }]),
            size: Some(1000),
            ..Default::default()
        }
    }

    #[test]
    fn choices_and_start() {
        let two = [src(Some("a"), "4K", 2160), src(Some("b"), "HD", 1080)];
        let one_usable = [src(Some("a"), "4K", 2160), src(None, "x", 1080)];
        assert_eq!(MediaVersions::choices(Some(&two)).len(), 2);
        assert!(MediaVersions::choices(Some(&one_usable)).is_empty());
        assert_eq!(MediaVersions::start(None, false), VersionStart::Wait);
        assert_eq!(MediaVersions::start(None, true), VersionStart::Play);
        assert_eq!(
            MediaVersions::start(Some(&one_usable), false),
            VersionStart::Play
        );
        assert!(
            matches!(MediaVersions::start(Some(&two), false), VersionStart::Choose(v) if v.len() == 2)
        );
    }

    #[test]
    fn matching_by_name_then_height() {
        let next = [
            src(Some("a"), "Director's Cut", 1080),
            src(Some("b"), "4K", 2160),
        ];
        let prev = src(Some("x"), "  4k ", 720);
        assert_eq!(
            MediaVersions::matching(&prev, Some(&next))
                .and_then(|s| s.id)
                .as_deref(),
            Some("b")
        );
        let prev = src(Some("x"), "", 1080);
        assert_eq!(
            MediaVersions::matching(&prev, Some(&next))
                .and_then(|s| s.id)
                .as_deref(),
            Some("a")
        );
        let prev = src(Some("x"), "other", 480);
        assert!(MediaVersions::matching(&prev, Some(&next)).is_none());
    }

    #[test]
    fn labels() {
        let s = src(Some("a"), "  ", 2160);
        assert_eq!(s.version_name(), "Fassung");
        assert_eq!(
            s.version_detail(&|n| format!("{n} B")),
            "2160p · HEVC · 1000 B"
        );
    }
}

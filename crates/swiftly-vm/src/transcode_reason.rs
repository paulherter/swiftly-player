//! The sentence that names why the server transcodes (`TranscodeReason.text`, JellyfinKit/PlaybackPlan.swift): shown in
//! warning colour under the delivery word of the technical overlay. The Apple apps still build it in Swift from the same
//! catalog keys; this is the shared rule for the desktop and Android, kept word for word identical (see the tests).

use swiftly_l10n::{Arg, Translator};
use swiftly_playback::playback_plan::{ReasonDetail, ReasonKind, TranscodeReason};

/// The label of a stream kind in the interface language (`TranscodeReason.Kind.label`).
fn kind_label(t: &Translator, kind: ReasonKind) -> String {
    t.t_package(kind.raw_value())
}

/// The detail in the parenthesis (`PlaybackPlan.diagnose`: "nicht im Profil deklariert", "würde eingebrannt", "6 Kanäle").
fn detail_text(t: &Translator, detail: &ReasonDetail) -> String {
    match detail {
        ReasonDetail::Channels(n) => t.t_args("%lld Kanäle", &[Arg::Int(*n)]),
        other => t.t_package(other.source_text()),
    }
}

/// `TranscodeReason.text`: `Audio „dts“ wird nicht direkt unterstützt (6 Kanäle).`, or without a detail
/// `Video „hevc“ steht nicht im Geräteprofil.`
pub fn reason_text(reason: &TranscodeReason, t: &Translator) -> String {
    let label = Arg::Str(kind_label(t, reason.kind));
    let codec = Arg::Str(reason.codec.clone());
    match &reason.detail {
        Some(d) => t.t_args(
            "%@ „%@“ wird nicht direkt unterstützt (%@).",
            &[label, codec, Arg::Str(detail_text(t, d))],
        ),
        None => t.t_args("%@ „%@“ steht nicht im Geräteprofil.", &[label, codec]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_l10n::Locale;

    fn reason(kind: ReasonKind, codec: &str, detail: Option<ReasonDetail>) -> TranscodeReason {
        TranscodeReason {
            kind,
            codec: codec.to_owned(),
            detail,
        }
    }

    /// The German sentences are the Swift ones, character for character (PlaybackPlan.swift `TranscodeReason.text`).
    #[test]
    fn the_german_wording_is_the_swift_wording() {
        let de = Translator::new(Locale::parse("de"));
        assert_eq!(
            reason_text(
                &reason(ReasonKind::Audio, "dts", Some(ReasonDetail::Channels(6))),
                &de
            ),
            "Audio „dts“ wird nicht direkt unterstützt (6 Kanäle)."
        );
        assert_eq!(
            reason_text(
                &reason(
                    ReasonKind::Container,
                    "mkv",
                    Some(ReasonDetail::NotDeclared)
                ),
                &de
            ),
            "Container „mkv“ wird nicht direkt unterstützt (nicht im Profil deklariert)."
        );
        assert_eq!(
            reason_text(
                &reason(
                    ReasonKind::Subtitle,
                    "pgssub",
                    Some(ReasonDetail::WouldBurnIn)
                ),
                &de
            ),
            "Untertitel „pgssub“ wird nicht direkt unterstützt (würde eingebrannt)."
        );
        assert_eq!(
            reason_text(&reason(ReasonKind::Video, "hevc", None), &de),
            "Video „hevc“ steht nicht im Geräteprofil."
        );
    }

    #[test]
    fn the_sentence_follows_the_interface_language() {
        let en = Translator::new(Locale::parse("en"));
        assert_eq!(
            reason_text(
                &reason(ReasonKind::Subtitle, "ass", Some(ReasonDetail::WouldBurnIn)),
                &en
            ),
            "Subtitles “ass” is not directly supported (would be burned in)."
        );
    }

    /// The Swift side still carries the same two sentences and the three details: a change there fails here.
    #[test]
    fn the_swift_source_still_says_the_same() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/JellyfinKit/Sources/JellyfinKit/PlaybackPlan.swift");
        let Ok(swift) = std::fs::read_to_string(path) else {
            return; // a source snapshot without the Swift package
        };
        for needle in [
            "„\\(codec)“ wird nicht direkt unterstützt (\\(detail)).",
            "„\\(codec)“ steht nicht im Geräteprofil.",
            "nicht im Profil deklariert",
            "würde eingebrannt",
            "\\($0) Kanäle",
        ] {
            assert!(swift.contains(needle), "Swift no longer has: {needle}");
        }
    }
}

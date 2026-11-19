//! The words the core puts into its answers (`ergebnis`, `angebot`, `einblendung`, `art`, the first-frame and
//! stream-watch advice), in one place.
//!
//! **Why.** A UI compares these strings with `==`. When a UI compares against a word the core never sends, the
//! branch never runs and nothing fails loudly (an older build did exactly that: "Next episode" did nothing). Every
//! producer therefore takes its word from here, every list is complete by construction (the producing `match` has no
//! wildcard arm), and `swiftly-uniffi`'s contract test writes all lists to `crates/swiftly-uniffi/data/core-words.json`, which the
//! Kotlin and Swift tests read to check the words their UIs compare against.

use swiftly_playback::first_frame::Rat;
use swiftly_playback::offering_layer::OfferingPresentation;
use swiftly_playback::sections::ButtonOffering;
use swiftly_playback::stream_watch::Advice;
use swiftly_rules::episodes_switch::Outcome;

/// `ergebnis` of an episode or quality switch.
pub mod ergebnis {
    use super::Outcome;

    /// The switch happened.
    pub const SWITCHED: &str = "gewechselt";
    /// Another switch was running, or the player is closed.
    pub const LOCKED: &str = "gesperrt";
    /// The player was closed.
    pub const CANCELLED: &str = "abgebrochen";
    /// No plan for the new title.
    pub const FAILED: &str = "gescheitert";
    /// Every word, in declaration order.
    pub const ALL: [&str; 4] = [SWITCHED, LOCKED, CANCELLED, FAILED];

    /// The word of an outcome (no wildcard arm: a new outcome must get a word).
    pub fn of(o: Outcome) -> &'static str {
        match o {
            Outcome::Switched => SWITCHED,
            Outcome::Locked => LOCKED,
            Outcome::Cancelled => CANCELLED,
            Outcome::Failed => FAILED,
        }
    }
}

/// `angebot`: what the button at the bottom right of the player offers.
pub mod angebot {
    use super::ButtonOffering;

    /// No button.
    pub const NOBODY: &str = "keiner";
    /// Skip a section (intro, credits, ...).
    pub const SKIP: &str = "ueberspringen";
    /// "Next episode".
    pub const NEXT: &str = "naechste";
    /// Every word, in declaration order.
    pub const ALL: [&str; 3] = [NOBODY, SKIP, NEXT];

    /// The word of an offering.
    pub fn of(o: &ButtonOffering) -> &'static str {
        match o {
            ButtonOffering::Nobody => NOBODY,
            ButtonOffering::Skip { .. } => SKIP,
            ButtonOffering::NextEpisode => NEXT,
        }
    }
}

/// `einblendung`: how the offering is shown above the picture.
pub mod einblendung {
    use super::OfferingPresentation;

    /// Nothing is shown.
    pub const NOTHING: &str = "nichts";
    /// The skip button.
    pub const BUTTON: &str = "knopf";
    /// The "Next episode" card.
    pub const CARD: &str = "karte";
    /// Every word, in declaration order.
    pub const ALL: [&str; 3] = [NOTHING, BUTTON, CARD];

    /// The word of a presentation.
    pub fn of(p: &OfferingPresentation) -> &'static str {
        match p {
            OfferingPresentation::Nothing => NOTHING,
            OfferingPresentation::Button(_) => BUTTON,
            OfferingPresentation::Card { .. } => CARD,
        }
    }
}

/// `art` of a row in the playback info sheet (`legacy_playback`): the header row is good or needs a warning.
pub mod info_art {
    /// The delivery is fine.
    pub const GOOD: &str = "gut";
    /// The delivery is transcoded or otherwise worth a warning.
    pub const WARNING: &str = "warnend";
    /// Every word, in declaration order.
    pub const ALL: [&str; 2] = [GOOD, WARNING];

    /// The word for a good or a warning header.
    pub fn of(good: bool) -> &'static str {
        if good { GOOD } else { WARNING }
    }
}

/// `Kern.firstFrameRat`: what to do while the first picture stays black.
pub mod first_frame_rat {
    use super::Rat;

    /// No case.
    pub const NOTHING: &str = "nichts";
    /// Not long enough yet.
    pub const WAIT: &str = "warten";
    /// Rebuild stream and output.
    pub const OUTPUT_NEW: &str = "ausgabeNeu";
    /// Reopen with the software decoder.
    pub const SOFTWARE_DECODER: &str = "softwareDekoder";
    /// Give up.
    pub const GIVE_UP: &str = "aufgeben";
    /// Every word, in declaration order.
    pub const ALL: [&str; 5] = [NOTHING, WAIT, OUTPUT_NEW, SOFTWARE_DECODER, GIVE_UP];

    /// The word of an advice.
    pub fn of(r: Rat) -> &'static str {
        match r {
            Rat::Nothing => NOTHING,
            Rat::Wait => WAIT,
            Rat::OutputNew => OUTPUT_NEW,
            Rat::SoftwareDecoder => SOFTWARE_DECODER,
            Rat::GiveUp => GIVE_UP,
        }
    }

    /// The advice of a word the core sent earlier, for the stage after it; `nichts` and `warten` read as no case.
    pub fn parse(word: &str) -> Rat {
        match word {
            OUTPUT_NEW => Rat::OutputNew,
            SOFTWARE_DECODER => Rat::SoftwareDecoder,
            GIVE_UP => Rat::GiveUp,
            _ => Rat::Nothing,
        }
    }
}

/// `Kern.streamWatchRat`: what the stream guard advises while the picture stands.
pub mod stream_watch_rat {
    use super::Advice;

    /// Has not stood long enough.
    pub const NOT_YET: &str = "nochNicht";
    /// A seek is in flight.
    pub const JUMP_RUNNING: &str = "sprungLaeuft";
    /// The buffer grows, so the stream is alive.
    pub const BUFFER_GROWS: &str = "pufferWaechst";
    /// Dropout: rebuild the stream.
    pub const NEW_CONNECT: &str = "neuVerbinden";
    /// Every word, in declaration order.
    pub const ALL: [&str; 4] = [NOT_YET, JUMP_RUNNING, BUFFER_GROWS, NEW_CONNECT];

    /// The word of an advice.
    pub fn of(a: Advice) -> &'static str {
        match a {
            Advice::NotYet => NOT_YET,
            Advice::JumpRunning => JUMP_RUNNING,
            Advice::BufferGrows => BUFFER_GROWS,
            Advice::NewConnect => NEW_CONNECT,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_playback::sections::Art;

    #[test]
    fn every_variant_has_its_listed_word() {
        let outcomes = [
            Outcome::Switched,
            Outcome::Locked,
            Outcome::Cancelled,
            Outcome::Failed,
        ];
        assert_eq!(outcomes.map(ergebnis::of), ergebnis::ALL);

        let offerings = [
            ButtonOffering::Nobody,
            ButtonOffering::Skip {
                to: 1.0,
                art: Art::IntroSegment,
            },
            ButtonOffering::NextEpisode,
        ];
        assert_eq!(offerings.each_ref().map(angebot::of), angebot::ALL);

        let shown = [
            OfferingPresentation::Nothing,
            OfferingPresentation::Button(ButtonOffering::NextEpisode),
            OfferingPresentation::Card { share: 0.5 },
        ];
        assert_eq!(shown.each_ref().map(einblendung::of), einblendung::ALL);

        assert_eq!([true, false].map(info_art::of), info_art::ALL);

        let rats = [
            Rat::Nothing,
            Rat::Wait,
            Rat::OutputNew,
            Rat::SoftwareDecoder,
            Rat::GiveUp,
        ];
        assert_eq!(rats.map(first_frame_rat::of), first_frame_rat::ALL);
        for r in [Rat::OutputNew, Rat::SoftwareDecoder, Rat::GiveUp] {
            assert_eq!(first_frame_rat::parse(first_frame_rat::of(r)), r);
        }
        assert_eq!(first_frame_rat::parse(first_frame_rat::WAIT), Rat::Nothing);

        let advice = [
            Advice::NotYet,
            Advice::JumpRunning,
            Advice::BufferGrows,
            Advice::NewConnect,
        ];
        assert_eq!(advice.map(stream_watch_rat::of), stream_watch_rat::ALL);
    }
}

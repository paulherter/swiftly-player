//! The contract between the core and every UI: the words the core sends and the UIs compare with `==`.
//!
//! The lists come from the producers (`swiftly_vm::core_words`, the download and library enums, the wire commands of
//! the native engine shells, the Plex sign-in steps) and are written to `crates/swiftly-uniffi/data/core-words.json`. That file is
//! committed. The Kotlin test (`CoreWordsContractTest`) and the Swift test (`CoreWordsContractTests`) read it and fail
//! for any word a UI compares against that is not in it. This test fails when the file is stale.
//!
//! Update the file after changing a producer: `UPDATE_CORE_WORDS=1 cargo test -p swiftly-uniffi core_words`.

use std::collections::BTreeMap;

use swiftly_downloads::state::DownloadState;
use swiftly_library::library_filter::LibraryFilter;
use swiftly_player_surface::wire::command;
use swiftly_rules::download_quality::DownloadQuality;
use swiftly_vm::core_words::{
    angebot, einblendung, ergebnis, first_frame_rat, info_art, stream_watch_rat,
};

const FILE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/data/core-words.json");

/// Group name (what the UI key means) to its words. Group names are the contract: UI tests look them up by name.
fn groups() -> BTreeMap<&'static str, Vec<&'static str>> {
    BTreeMap::from([
        ("playback.ergebnis", ergebnis::ALL.to_vec()),
        ("playback.angebot", angebot::ALL.to_vec()),
        ("playback.einblendung", einblendung::ALL.to_vec()),
        ("playback.infoArt", info_art::ALL.to_vec()),
        ("player.firstFrameRat", first_frame_rat::ALL.to_vec()),
        ("player.streamWatchRat", stream_watch_rat::ALL.to_vec()),
        (
            "plexSignIn.step",
            crate::plex_sign_in::legacy::STEP_WORDS.to_vec(),
        ),
        (
            "downloads.stand",
            DownloadState::ALL.map(DownloadState::raw_value).to_vec(),
        ),
        (
            "downloads.qualitaet",
            DownloadQuality::ALL
                .map(DownloadQuality::raw_value)
                .to_vec(),
        ),
        (
            "library.filter",
            LibraryFilter::ALL.map(LibraryFilter::raw_value).to_vec(),
        ),
        ("engine.command", command::ALL.to_vec()),
        ("engine.pip", command::PIP_VALUES.to_vec()),
    ])
}

fn render() -> String {
    let mut text = serde_json::to_string_pretty(&groups()).unwrap_or_default();
    text.push('\n');
    text
}

#[test]
fn core_words_file_is_current() {
    let want = render();
    if std::env::var_os("UPDATE_CORE_WORDS").is_some() {
        std::fs::write(FILE, &want).expect("write crates/swiftly-uniffi/data/core-words.json");
        return;
    }
    let have = std::fs::read_to_string(FILE).unwrap_or_default();
    assert!(
        have == want,
        "crates/swiftly-uniffi/data/core-words.json is stale or missing; regenerate it with \
         `UPDATE_CORE_WORDS=1 cargo test -p swiftly-uniffi core_words` and commit it"
    );
}

#[test]
fn every_group_is_filled_and_has_no_duplicates() {
    for (name, words) in groups() {
        assert!(!words.is_empty(), "{name} is empty");
        let mut sorted = words.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), words.len(), "{name} lists a word twice");
        assert!(
            words.iter().all(|w| !w.is_empty()),
            "{name} has an empty word"
        );
    }
}

/// The download quality handed to the platform host is the persisted raw value, never a `Debug` name.
#[test]
fn quality_words_are_the_raw_values() {
    let sent: Vec<&str> = DownloadQuality::ALL
        .map(DownloadQuality::raw_value)
        .to_vec();
    assert_eq!(sent, ["original", "hd1080", "hd720", "sd480"]);
}

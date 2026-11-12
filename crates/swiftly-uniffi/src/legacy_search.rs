//! Pure search rules of the old Android facade (`Kern.searchTermFits`, the history string, the TV keyboard, the screen
//! state), answered as before. Each is compared with the Swift answer by a Kotlin test.

use swiftly_library::search_history;

/// `Kern.searchTermFits`: from when to search.
#[uniffi::export]
pub fn legacy_search_term_fits(term: String) -> bool {
    swiftly_rules::display_rules::search_term_fits(&term)
}

/// `Kern.searchHistoryKey`: the shared key of the history string.
#[uniffi::export]
pub fn legacy_search_history_key() -> String {
    search_history::key_for(None)
}

/// `Kern.searchHistoryKeyAccount`: the key of one account's history.
#[uniffi::export]
pub fn legacy_search_history_key_account(account: String) -> String {
    search_history::key_for(Some(&account))
}

/// `Kern.searchHistoryRemember`: the new stored string after a term (eight at most, no duplicates, newest first).
#[uniffi::export]
pub fn legacy_search_history_remember(word: String, raw: String) -> String {
    search_history::remember(&word, &raw)
}

/// `Kern.searchHistoryList`: the terms of the stored string as a JSON array.
#[uniffi::export]
pub fn legacy_search_history_list(raw: String) -> String {
    serde_json::to_string(&search_history::list(&raw)).unwrap_or_else(|_| "[]".into())
}

/// `Kern.searchKeyRows`: the TV keyboard as rows of keys.
#[uniffi::export]
pub fn legacy_search_key_rows(speech: bool) -> String {
    swiftly_vm::search_key_rows(speech)
}

/// `Kern.searchKeyTyped`.
#[uniffi::export]
pub fn legacy_search_key_typed(character: String, term: String) -> String {
    swiftly_vm::search_key_typed(&character, &term)
}

/// `Kern.searchKeySpace`.
#[uniffi::export]
pub fn legacy_search_key_space(term: String) -> String {
    swiftly_vm::search_key_space(&term)
}

/// `Kern.searchKeySpaceFits`.
#[uniffi::export]
pub fn legacy_search_key_space_fits(term: String) -> bool {
    swiftly_vm::search_key_space_fits(&term)
}

/// `Kern.searchKeyDelete`.
#[uniffi::export]
pub fn legacy_search_key_delete(term: String) -> String {
    swiftly_vm::search_key_delete(&term)
}

/// `Kern.searchKeyHardware`.
#[uniffi::export]
pub fn legacy_search_key_hardware(text: String, term: String) -> String {
    swiftly_vm::search_key_hardware(&text, &term)
}

/// `Kern.searchTitlesShown`: block titles only stand when more than one block is there.
#[uniffi::export]
pub fn legacy_search_titles_shown(series: i64, films: i64, requests: i64) -> bool {
    swiftly_vm::search_titles_shown(series, films, requests)
}

/// `Kern.searchScreen`: `history`, `start`, `loading`, `blank`, `hits`, `nothing` or `disrupted`.
#[uniffi::export]
pub fn legacy_search_screen(
    term: String,
    history_count: i64,
    has_hits: bool,
    answered: bool,
    disrupted: bool,
    waited: bool,
) -> String {
    swiftly_vm::search_screen_state(&term, history_count, has_hits, answered, disrupted, waited)
        .to_owned()
}

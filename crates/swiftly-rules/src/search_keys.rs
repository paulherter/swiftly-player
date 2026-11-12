//! Rules of the TV search keyboard and screen (SearchKeys.swift: `SearchKeys`, `SearchGroups`,
//! `SearchScreen`). Swift's `String` works on characters (grapheme clusters): "last", "drop last"
//! and "count == 1" below follow that, not the Unicode scalar.

use crate::display_rules::search_term_fits;
use unicode_segmentation::UnicodeSegmentation;

fn last_grapheme(term: &str) -> Option<&str> {
    term.graphemes(true).next_back()
}

/// Where a letter starts a word: at the very beginning, after a space, after a hyphen.
fn starts_word(term: &str) -> bool {
    last_grapheme(term).is_none_or(|g| g == " " || g == "-")
}

/// What typing this key adds: a capital at the start of a word, otherwise lower case. The sharp
/// s stays lower case (its capital form is two characters).
pub fn typed(character: &str, term: &str) -> String {
    let one = character.to_lowercase();
    let capital = character.to_uppercase();
    let add = if starts_word(term) && capital.graphemes(true).count() == 1 {
        capital
    } else {
        one
    };
    format!("{term}{add}")
}

/// A space makes sense after a character that is not a space already.
pub fn space_fits(term: &str) -> bool {
    last_grapheme(term).is_some_and(|g| g != " ")
}

/// `withSpace`.
pub fn with_space(term: &str) -> String {
    if space_fits(term) {
        format!("{term} ")
    } else {
        term.to_owned()
    }
}

/// `withoutLast`: drops one character (grapheme cluster).
pub fn without_last(term: &str) -> String {
    match last_grapheme(term) {
        Some(g) => term[..term.len() - g.len()].to_owned(),
        None => String::new(),
    }
}

/// Swift `Character.isLetter` / `isNumber` look at the first scalar of the character.
fn is_letter_or_number(grapheme: &str) -> bool {
    grapheme
        .chars()
        .next()
        .is_some_and(|c| c.is_alphabetic() || c.is_numeric())
}

/// Text from a hardware keyboard: letters, digits and the hyphen are taken like the keys, a
/// space like the space key. Anything else is ignored.
pub fn hardware(text: &str, term: &str) -> String {
    let mut result = term.to_owned();
    for ch in text.graphemes(true) {
        if ch == " " {
            result = with_space(&result);
        } else if is_letter_or_number(ch) || ch == "-" {
            result = typed(ch, &result);
        }
    }
    result
}

/// `SearchGroups.showsTitles`: block titles only when more than one block stands there.
pub fn shows_titles(series: i64, films: i64, requests: i64) -> bool {
    [series, films, requests].iter().filter(|n| **n > 0).count() > 1
}

/// `SearchScreen.state`: `history`, `start`, `loading`, `blank`, `hits`, `nothing`, `disrupted`.
pub fn screen_state(
    term: &str,
    history_count: i64,
    has_hits: bool,
    answered: bool,
    disrupted: bool,
    waited: bool,
) -> &'static str {
    if !search_term_fits(term) {
        return if history_count > 0 {
            "history"
        } else {
            "start"
        };
    }
    if disrupted {
        "disrupted"
    } else if has_hits {
        "hits"
    } else if answered {
        "nothing"
    } else if waited {
        "loading"
    } else {
        "blank"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capitals_at_word_starts() {
        assert_eq!(typed("A", ""), "A");
        assert_eq!(typed("B", "A"), "Ab");
        assert_eq!(typed("M", "Tatort "), "Tatort M");
        assert_eq!(typed("ß", ""), "ß");
        assert_eq!(hardware("tatort münster", ""), "Tatort Münster");
    }

    #[test]
    fn delete_takes_a_whole_character() {
        assert_eq!(without_last("Ae\u{301}"), "A");
        assert_eq!(without_last(""), "");
        assert!(!space_fits("") && !space_fits("a ") && space_fits("a"));
        assert_eq!(with_space("a "), "a ");
    }

    #[test]
    fn blocks_and_screen() {
        assert!(!shows_titles(3, 0, 0) && shows_titles(1, 1, 0));
        assert_eq!(screen_state("", 2, false, false, false, false), "history");
        assert_eq!(screen_state("", 0, false, false, false, false), "start");
    }
}

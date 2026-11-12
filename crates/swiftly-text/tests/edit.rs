//! Behaviour of the text editor: graphemes, words, RTL, composition (ja/zh/ko), paste, undo grouping.

use swiftly_text::{EditKey, MemoryClipboard, Mods, PreeditStyle, TextEditor, TextInputEvent as E};

fn run(ed: &mut TextEditor, evs: &[E]) -> MemoryClipboard {
    let mut clip = MemoryClipboard::default();
    for e in evs {
        let _ = ed.apply(e, &mut clip);
    }
    clip
}
fn t(s: &str) -> E {
    E::Text(s.to_owned())
}
fn key(k: EditKey) -> E {
    E::Key(k, Mods::NONE)
}
fn pre(s: &str, c: Option<(usize, usize)>) -> E {
    E::Preedit {
        text: s.to_owned(),
        cursor: c,
    }
}

#[test]
fn backspace_removes_a_whole_zwj_emoji_and_a_flag() {
    let mut e = TextEditor::single_line();
    run(
        &mut e,
        &[
            t("a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{1F1E9}\u{1F1EA}"),
            key(EditKey::Backspace),
        ],
    );
    assert_eq!(e.text(), "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}");
    run(&mut e, &[key(EditKey::Backspace)]);
    assert_eq!(e.text(), "a");
}

#[test]
fn arrows_step_over_combining_marks_and_emoji() {
    let mut e = TextEditor::single_line();
    run(
        &mut e,
        &[
            t("e\u{301}\u{1F44D}\u{1F3FD}x"),
            E::Key(EditKey::Home, Mods::NONE),
            key(EditKey::Right),
        ],
    );
    assert_eq!(e.caret(), "e\u{301}".len());
    run(&mut e, &[key(EditKey::Right)]);
    assert_eq!(e.caret(), "e\u{301}\u{1F44D}\u{1F3FD}".len());
}

#[test]
fn shift_select_select_all_and_typing_replaces() {
    let mut e = TextEditor::single_line();
    run(
        &mut e,
        &[t("hello world"), E::Key(EditKey::Left, Mods::SHIFT_WORD)],
    );
    assert_eq!(e.selected_text(), "world");
    run(&mut e, &[t("there")]);
    assert_eq!(e.text(), "hello there");
    run(&mut e, &[E::SelectAll]);
    assert_eq!(e.selected_text(), "hello there");
    run(&mut e, &[key(EditKey::Left)]);
    assert_eq!(e.caret(), 0, "left collapses the selection to its start");
}

#[test]
fn word_delete_goes_back_one_word() {
    let mut e = TextEditor::single_line();
    run(
        &mut e,
        &[t("one two three"), E::Key(EditKey::Backspace, Mods::WORD)],
    );
    assert_eq!(e.text(), "one two ");
    run(&mut e, &[E::Key(EditKey::Backspace, Mods::WORD)]);
    assert_eq!(e.text(), "one ");
}

#[test]
fn rtl_arrows_move_visually() {
    let mut e = TextEditor::single_line();
    run(
        &mut e,
        &[
            t("\u{5E9}\u{5DC}\u{5D5}\u{5DD}"),
            E::Key(EditKey::Home, Mods::NONE),
        ],
    );
    assert!(e.is_rtl());
    assert_eq!(e.caret(), 0);
    run(&mut e, &[key(EditKey::Left)]);
    assert_eq!(
        e.caret(),
        2,
        "left in an RTL paragraph moves forward in the text"
    );
    run(&mut e, &[key(EditKey::Right)]);
    assert_eq!(e.caret(), 0);
    let mut ltr = TextEditor::single_line();
    run(&mut ltr, &[t("ab"), key(EditKey::Left)]);
    assert_eq!(ltr.caret(), 1);
}

#[test]
fn copy_cut_paste_and_password_never_copies() {
    let mut e = TextEditor::single_line();
    let clip = run(&mut e, &[t("abc def"), E::SelectAll, E::Copy]);
    assert_eq!(clip.text.as_deref(), Some("abc def"));
    let mut e = TextEditor::single_line();
    let mut c = MemoryClipboard::default();
    let _ = e.apply(&t("abc"), &mut c);
    let _ = e.apply(&E::SelectAll, &mut c);
    let _ = e.apply(&E::Cut, &mut c);
    assert_eq!((e.text(), c.text.as_deref()), ("", Some("abc")));
    let _ = e.apply(&E::Paste, &mut c);
    assert_eq!(e.text(), "abc");
    let mut p = TextEditor::single_line().password();
    let mut c = MemoryClipboard::default();
    let _ = p.apply(&t("secret"), &mut c);
    let _ = p.apply(&E::SelectAll, &mut c);
    let _ = p.apply(&E::Copy, &mut c);
    let _ = p.apply(&E::Cut, &mut c);
    assert_eq!((c.text, p.text()), (None, "secret"));
}

#[test]
fn paste_with_newlines_in_a_single_line_field_becomes_spaces() {
    let mut e = TextEditor::single_line();
    let mut c = MemoryClipboard {
        text: Some("one\r\ntwo\nthree\rfour\u{7}".into()),
    };
    let _ = e.apply(&E::Paste, &mut c);
    assert_eq!(e.text(), "one two three four");
    let mut m = TextEditor::multi_line();
    let mut c = MemoryClipboard {
        text: Some("a\r\nb\rc".into()),
    };
    let _ = m.apply(&E::Paste, &mut c);
    assert_eq!(m.text(), "a\nb\nc");
}

#[test]
fn undo_groups_typing_and_deleting_separately() {
    let mut e = TextEditor::single_line();
    run(
        &mut e,
        &[
            t("h"),
            t("e"),
            t("y"),
            key(EditKey::Backspace),
            key(EditKey::Backspace),
        ],
    );
    assert_eq!(e.text(), "h");
    run(&mut e, &[E::Undo]);
    assert_eq!(e.text(), "hey", "both backspaces are one step");
    run(&mut e, &[E::Undo]);
    assert_eq!(e.text(), "", "the typing is one step");
    run(&mut e, &[E::Redo]);
    assert_eq!(e.text(), "hey");
    run(&mut e, &[key(EditKey::Left), t("!")]);
    assert!(!e.can_redo(), "a new edit drops redo");
    run(&mut e, &[E::Undo]);
    assert_eq!(e.text(), "hey", "moving the caret breaks the group");
}

#[test]
fn max_length_counts_graphemes_and_truncates_paste() {
    let mut e = TextEditor::single_line().max_len(3);
    run(&mut e, &[t("\u{1F468}\u{200D}\u{1F469}ab"), t("c")]);
    assert_eq!(e.text(), "\u{1F468}\u{200D}\u{1F469}ab");
    run(&mut e, &[E::SelectAll, t("xyz123")]);
    assert_eq!(e.text(), "xyz");
}

#[test]
fn multi_line_enter_inserts_and_up_down_keep_the_column() {
    let mut e = TextEditor::multi_line();
    run(
        &mut e,
        &[
            t("abcd"),
            key(EditKey::Enter),
            t("ef"),
            key(EditKey::Enter),
            t("ghijk"),
        ],
    );
    assert_eq!(e.text(), "abcd\nef\nghijk");
    run(&mut e, &[key(EditKey::Up)]);
    assert_eq!(e.caret(), "abcd\nef".len(), "short line: end of it");
    run(&mut e, &[key(EditKey::Up)]);
    assert_eq!(
        e.caret(),
        "abcd".len(),
        "goal column 5 clamps to the line end"
    );
    let mut s = TextEditor::single_line();
    let mut c = MemoryClipboard::default();
    assert!(s.apply(&key(EditKey::Enter), &mut c).submitted);
}

#[test]
fn japanese_composition_then_commit() {
    let mut e = TextEditor::single_line();
    run(&mut e, &[t("a")]);
    run(&mut e, &[pre("に", Some(("に".len(), "に".len())))]);
    run(&mut e, &[pre("にほん", Some((0, "にほん".len())))]);
    let d = e.display();
    assert_eq!(d.text, "aにほん");
    assert_eq!(d.preedit, Some(1..1 + "にほん".len()));
    assert_eq!(d.spans[0].style, PreeditStyle::Active);
    assert_eq!(
        e.text(),
        "a",
        "the committed text is untouched while composing"
    );
    run(&mut e, &[pre("", None), E::Commit("日本".into())]);
    assert_eq!((e.text(), e.caret()), ("a日本", "a日本".len()));
    assert!(e.display().preedit.is_none());
}

#[test]
fn chinese_pinyin_clause_highlight_and_candidate_anchor() {
    let mut e = TextEditor::single_line();
    run(&mut e, &[pre("ni hao", Some((0, 2)))]);
    let d = e.display();
    assert_eq!(d.spans.len(), 2);
    assert_eq!(
        (d.spans[0].style, d.spans[0].range.clone()),
        (PreeditStyle::Active, 0..2)
    );
    assert_eq!(
        (d.spans[1].style, d.spans[1].range.clone()),
        (PreeditStyle::Underline, 2..6)
    );
    assert_eq!(e.candidate_anchor(), 0..6);
    run(&mut e, &[E::Commit("你好".into())]);
    assert_eq!(e.text(), "你好");
    assert_eq!(
        e.candidate_anchor(),
        6..6,
        "without composition the anchor is the caret"
    );
}

#[test]
fn korean_syllables_recompose_and_cancel_leaves_text() {
    let mut e = TextEditor::single_line();
    run(
        &mut e,
        &[
            t("x"),
            pre("ㅎ", Some((0, 3))),
            pre("하", Some((0, 3))),
            pre("한", Some((0, 3))),
        ],
    );
    assert_eq!(e.display().text, "x한");
    run(&mut e, &[E::Commit("한".into()), pre("ㄱ", Some((0, 3)))]);
    assert_eq!(e.display().text, "x한ㄱ");
    run(&mut e, &[E::CancelComposition]);
    assert_eq!(e.text(), "x한");
    run(&mut e, &[E::Undo]);
    assert_eq!(e.text(), "x", "a commit is its own undo step");
}

#[test]
fn composition_replaces_the_selection_and_caret_can_sit_inside_the_preedit() {
    let mut e = TextEditor::single_line();
    run(&mut e, &[t("abc"), E::SelectAll, pre("かな", Some((3, 3)))]);
    assert_eq!(e.text(), "");
    let d = e.display();
    assert_eq!((d.text.as_str(), d.caret), ("かな", Some(3)));
    run(&mut e, &[pre("かな", None)]);
    assert_eq!(e.display().caret, None);
}

#[test]
fn preedit_ends_when_a_key_arrives() {
    let mut e = TextEditor::single_line();
    run(&mut e, &[pre("ka", Some((2, 2))), key(EditKey::Left)]);
    assert!(e.preedit().is_none());
}

#[test]
fn password_masks_text_caret_and_preedit_and_reads_as_bullets() {
    let mut e = TextEditor::single_line().password();
    run(
        &mut e,
        &[t("pa\u{1F468}\u{200D}\u{1F469}"), pre("ん", Some((3, 3)))],
    );
    let d = e.display();
    assert_eq!(d.text, "\u{2022}".repeat(4));
    assert_eq!(d.caret, Some(12));
    let (v, sel) = e.a11y_value();
    assert_eq!((v.chars().count(), sel), (4, 4..4));
}

#[test]
fn a11y_selection_is_in_characters() {
    let mut e = TextEditor::single_line();
    run(
        &mut e,
        &[
            t("日本語abc"),
            E::SetCaret {
                index: 3,
                extend: false,
            },
            E::SetCaret {
                index: 9,
                extend: true,
            },
        ],
    );
    let (v, sel) = e.a11y_value();
    assert_eq!((v.as_str(), sel), ("日本語abc", 1..3));
}

#[test]
fn clear_is_undoable_and_pointer_snaps_to_graphemes() {
    let mut e = TextEditor::single_line();
    run(
        &mut e,
        &[
            t("e\u{301}x"),
            E::SetCaret {
                index: 1,
                extend: false,
            },
        ],
    );
    assert_eq!(e.caret(), 0, "inside a grapheme snaps to its start");
    run(&mut e, &[E::Clear]);
    assert_eq!(e.text(), "x".get(..0).unwrap_or(""));
    run(&mut e, &[E::Undo]);
    assert_eq!(e.text(), "e\u{301}x");
    run(&mut e, &[E::SelectWord(0)]);
    assert_eq!(e.selected_text(), "e\u{301}x");
}

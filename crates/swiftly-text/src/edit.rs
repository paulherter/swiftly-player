// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! [`TextEditor`]: the state machine of a text field. Grapheme-aware caret and selection, word and line movement,
//! undo with grouping, a max length, single- and multi-line, password masking and IME composition. No drawing and no
//! platform types: it is fed [`TextInputEvent`]s and read through [`TextEditor::display`].

use crate::input::{Clipboard, EditKey, Mods, TextInputEvent};
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;

/// The bullet a password field shows for each grapheme.
pub const MASK: char = '\u{2022}';
const UNDO_LIMIT: usize = 200;

/// The text under composition and where the input method wants its highlight.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preedit {
    /// The preedit string.
    pub text: String,
    /// Byte range inside `text` (the active clause, or a caret when both ends are equal). `None` hides the caret.
    pub cursor: Option<(usize, usize)>,
}

/// How a part of the preedit is drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreeditStyle {
    /// Thin underline: converted/unconverted text of the composition.
    Underline,
    /// Thick underline or highlight: the clause the input method is working on.
    Active,
}

/// A styled span of the preedit, in byte offsets of [`Display::text`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreeditSpan {
    /// Byte range in the display text.
    pub range: Range<usize>,
    /// Style.
    pub style: PreeditStyle,
}

/// What the field shows: text (masked for passwords, preedit included) and byte positions inside it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Display {
    /// The text to draw.
    pub text: String,
    /// The caret byte index, `None` while the input method hides it.
    pub caret: Option<usize>,
    /// The selected byte range (empty = none; always empty during composition).
    pub selection: Range<usize>,
    /// Byte range of the preedit in `text`.
    pub preedit: Option<Range<usize>>,
    /// Preedit spans with their styles.
    pub spans: Vec<PreeditSpan>,
    /// Whether the paragraph runs right to left.
    pub rtl: bool,
}

/// What an event changed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    /// The committed text changed.
    pub text_changed: bool,
    /// Caret, selection or composition changed (anything the view shows).
    pub view_changed: bool,
    /// Return in a single-line field.
    pub submitted: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Snap {
    text: String,
    anchor: usize,
    focus: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Typing,
    Back,
    Forward,
    Other,
}

/// The editor state.
#[derive(Clone, Debug)]
pub struct TextEditor {
    text: String,
    anchor: usize,
    focus: usize,
    preedit: Option<Preedit>,
    multiline: bool,
    password: bool,
    max_len: Option<usize>,
    undo: Vec<Snap>,
    redo: Vec<Snap>,
    last: Option<Kind>,
    goal_col: Option<usize>,
    rtl: Option<bool>,
}

fn count(s: &str) -> usize {
    s.graphemes(true).count()
}

/// True if the first strong character is Hebrew or Arabic script.
pub fn is_rtl_text(s: &str) -> bool {
    for c in s.chars() {
        let u = c as u32;
        if matches!(u, 0x0590..=0x08FF | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFF | 0x10800..=0x10FFF | 0x1E800..=0x1EFFF)
        {
            return true;
        }
        if c.is_alphabetic() {
            return false;
        }
    }
    false
}

impl TextEditor {
    /// An empty single-line editor.
    pub fn single_line() -> TextEditor {
        TextEditor {
            text: String::new(),
            anchor: 0,
            focus: 0,
            preedit: None,
            multiline: false,
            password: false,
            max_len: None,
            undo: Vec::new(),
            redo: Vec::new(),
            last: None,
            goal_col: None,
            rtl: None,
        }
    }
    /// An empty multi-line editor.
    pub fn multi_line() -> TextEditor {
        TextEditor {
            multiline: true,
            ..TextEditor::single_line()
        }
    }
    /// Masks the text with bullets and disables copy and cut.
    #[must_use]
    pub fn password(mut self) -> TextEditor {
        self.password = true;
        self
    }
    /// Limits the text to `n` graphemes.
    #[must_use]
    pub fn max_len(mut self, n: usize) -> TextEditor {
        self.max_len = Some(n);
        self.text = self.text.graphemes(true).take(n).collect();
        self.anchor = self.anchor.min(self.text.len());
        self.focus = self.focus.min(self.text.len());
        self
    }
    /// Forces the paragraph direction (the view knows it from the shaped layout); `None` detects it from the text.
    pub fn set_rtl(&mut self, rtl: Option<bool>) {
        self.rtl = rtl;
    }
    /// Replaces the text (programmatic: clears history and composition) and puts the caret at the end.
    pub fn set_text(&mut self, s: &str) {
        self.text = self.sanitize(s);
        if let Some(m) = self.max_len {
            self.text = self.text.graphemes(true).take(m).collect();
        }
        self.anchor = self.text.len();
        self.focus = self.text.len();
        self.preedit = None;
        self.undo.clear();
        self.redo.clear();
        self.last = None;
    }

    /// The committed text.
    pub fn text(&self) -> &str {
        &self.text
    }
    /// Whether the field is empty (committed text and composition).
    pub fn is_empty(&self) -> bool {
        self.text.is_empty() && self.preedit.is_none()
    }
    /// Whether it is multi-line.
    pub fn is_multiline(&self) -> bool {
        self.multiline
    }
    /// Whether it is a password field.
    pub fn is_password(&self) -> bool {
        self.password
    }
    /// The selection as a byte range (empty = caret).
    pub fn selection(&self) -> Range<usize> {
        self.anchor.min(self.focus)..self.anchor.max(self.focus)
    }
    /// The caret (moving end of the selection) as a byte index.
    pub fn caret(&self) -> usize {
        self.focus
    }
    /// The composition in progress.
    pub fn preedit(&self) -> Option<&Preedit> {
        self.preedit.as_ref()
    }
    /// Whether the paragraph is right to left.
    pub fn is_rtl(&self) -> bool {
        self.rtl.unwrap_or_else(|| is_rtl_text(&self.text))
    }
    /// The selected text.
    pub fn selected_text(&self) -> &str {
        &self.text[self.selection()]
    }
    /// Whether undo has a step.
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }
    /// Whether redo has a step.
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    /// What to draw: masked text with the preedit in place.
    pub fn display(&self) -> Display {
        let sel = self.selection();
        let rtl = self.is_rtl();
        let Some(pre) = &self.preedit else {
            if !self.password {
                return Display {
                    text: self.text.clone(),
                    caret: Some(self.focus),
                    selection: sel,
                    preedit: None,
                    spans: Vec::new(),
                    rtl,
                };
            }
            let m = |i| mask_index(&self.text, i);
            return Display {
                text: masked(&self.text),
                caret: Some(m(self.focus)),
                selection: m(sel.start)..m(sel.end),
                preedit: None,
                spans: Vec::new(),
                rtl,
            };
        };
        let at = self.focus;
        let mut raw = String::with_capacity(self.text.len() + pre.text.len());
        raw.push_str(&self.text[..at]);
        raw.push_str(&pre.text);
        raw.push_str(&self.text[at..]);
        let range = at..at + pre.text.len();
        let (cs, ce) = pre.cursor.unwrap_or((0, 0));
        let caret = pre.cursor.map(|_| at + cs);
        let mut spans = Vec::new();
        if pre.cursor.is_some() && ce > cs {
            for (r, style) in [
                (range.start..at + cs, PreeditStyle::Underline),
                (at + cs..at + ce, PreeditStyle::Active),
                (at + ce..range.end, PreeditStyle::Underline),
            ] {
                if r.start < r.end {
                    spans.push(PreeditSpan { range: r, style });
                }
            }
        } else if !range.is_empty() {
            spans.push(PreeditSpan {
                range: range.clone(),
                style: PreeditStyle::Underline,
            });
        }
        if !self.password {
            return Display {
                text: raw,
                caret,
                selection: at..at,
                preedit: Some(range),
                spans,
                rtl,
            };
        }
        let m = |i| mask_index(&raw, i);
        Display {
            text: masked(&raw),
            caret: caret.map(m),
            selection: m(at)..m(at),
            preedit: Some(m(range.start)..m(range.end)),
            spans: spans
                .into_iter()
                .map(|s| PreeditSpan {
                    range: m(s.range.start)..m(s.range.end),
                    style: s.style,
                })
                .collect(),
            rtl,
        }
    }

    /// The value a screen reader announces and the selection in characters (Unicode scalar values) of that value.
    /// Passwords read as bullets.
    pub fn a11y_value(&self) -> (String, Range<usize>) {
        let d = self.display();
        let chars = |i: usize| d.text[..i.min(d.text.len())].chars().count();
        let c = d.caret.unwrap_or(d.text.len());
        let r = if d.selection.is_empty() {
            chars(c)..chars(c)
        } else {
            chars(d.selection.start)..chars(d.selection.end)
        };
        (d.text, r)
    }

    /// Where the input method should put its candidate window: the byte range in the display text it anchors to (the
    /// preedit, or the caret). The view turns it into a rectangle with the shaped layout.
    pub fn candidate_anchor(&self) -> Range<usize> {
        let d = self.display();
        match d.preedit {
            Some(r) => r,
            None => {
                let c = d.caret.unwrap_or(0);
                c..c
            }
        }
    }

    // ---- events ----------------------------------------------------------------------------------------------

    /// Applies one event.
    pub fn apply(&mut self, ev: &TextInputEvent, clip: &mut dyn Clipboard) -> Outcome {
        let before = (
            self.text.clone(),
            self.anchor,
            self.focus,
            self.preedit.clone(),
        );
        let mut submitted = false;
        let keep_goal = matches!(ev, TextInputEvent::Key(EditKey::Up | EditKey::Down, _));
        match ev {
            TextInputEvent::Text(s) => {
                self.cancel_preedit();
                self.insert(s, Kind::Typing);
            }
            TextInputEvent::Preedit { text, cursor } => self.set_preedit(text, *cursor),
            TextInputEvent::Commit(s) => {
                self.preedit = None;
                self.insert(s, Kind::Other);
            }
            TextInputEvent::CancelComposition => self.cancel_preedit(),
            TextInputEvent::Key(k, m) => {
                self.cancel_preedit();
                submitted = self.key(*k, *m);
            }
            TextInputEvent::SelectAll => {
                self.cancel_preedit();
                self.anchor = 0;
                self.focus = self.text.len();
                self.last = None;
            }
            TextInputEvent::Copy => {
                if !self.password && !self.selection().is_empty() {
                    clip.set_text(self.selected_text());
                }
            }
            TextInputEvent::Cut => {
                self.cancel_preedit();
                if !self.password && !self.selection().is_empty() {
                    clip.set_text(self.selected_text());
                    self.insert_raw("", Kind::Other);
                }
            }
            TextInputEvent::Paste => {
                self.cancel_preedit();
                if let Some(s) = clip.get_text() {
                    self.insert(&s, Kind::Other);
                }
            }
            TextInputEvent::Undo => {
                self.cancel_preedit();
                self.undo_step();
            }
            TextInputEvent::Redo => {
                self.cancel_preedit();
                self.redo_step();
            }
            TextInputEvent::SetCaret { index, extend } => {
                self.cancel_preedit();
                let i = self.snap(*index);
                self.focus = i;
                if !extend {
                    self.anchor = i;
                }
                self.last = None;
            }
            TextInputEvent::SelectWord(index) => {
                self.cancel_preedit();
                let i = self.snap(*index);
                let (s, e) = self.word_at(i);
                self.anchor = s;
                self.focus = e;
                self.last = None;
            }
            TextInputEvent::Clear => {
                self.cancel_preedit();
                if !self.text.is_empty() {
                    self.anchor = 0;
                    self.focus = self.text.len();
                    self.insert_raw("", Kind::Other);
                }
            }
        }
        if !keep_goal {
            self.goal_col = None;
        }
        let after = (&self.text, self.anchor, self.focus, &self.preedit);
        Outcome {
            text_changed: before.0 != *after.0,
            view_changed: before.0 != *after.0
                || before.1 != after.1
                || before.2 != after.2
                || before.3 != *after.3,
            submitted,
        }
    }

    fn key(&mut self, k: EditKey, m: Mods) -> bool {
        let rtl = self.is_rtl();
        match k {
            EditKey::Left | EditKey::Right => {
                let forward = (k == EditKey::Right) != rtl;
                let sel = self.selection();
                if !sel.is_empty() && !m.shift && !m.word && !m.line {
                    let to = if forward { sel.end } else { sel.start };
                    self.anchor = to;
                    self.focus = to;
                } else {
                    let to = if m.line {
                        if forward {
                            self.line_end(self.focus)
                        } else {
                            self.line_start(self.focus)
                        }
                    } else if m.word {
                        if forward {
                            self.word_right(self.focus)
                        } else {
                            self.word_left(self.focus)
                        }
                    } else if forward {
                        self.next(self.focus)
                    } else {
                        self.prev(self.focus)
                    };
                    self.move_to(to, m.shift);
                }
                self.last = None;
            }
            EditKey::Home | EditKey::End => {
                let to = if !self.multiline || m.line || m.word {
                    if k == EditKey::Home {
                        0
                    } else {
                        self.text.len()
                    }
                } else if k == EditKey::Home {
                    self.line_start(self.focus)
                } else {
                    self.line_end(self.focus)
                };
                self.move_to(to, m.shift);
                self.last = None;
            }
            EditKey::Up | EditKey::Down => {
                let up = k == EditKey::Up;
                let to = if !self.multiline {
                    if up { 0 } else { self.text.len() }
                } else {
                    self.vertical(up)
                };
                self.move_to(to, m.shift);
                self.last = None;
            }
            EditKey::Backspace | EditKey::Delete => {
                let back = k == EditKey::Backspace;
                if self.selection().is_empty() {
                    let f = self.focus;
                    let to = if back {
                        if m.line {
                            self.line_start(f)
                        } else if m.word {
                            self.word_left(f)
                        } else {
                            self.prev(f)
                        }
                    } else if m.line {
                        self.line_end(f)
                    } else if m.word {
                        self.word_right(f)
                    } else {
                        self.next(f)
                    };
                    self.anchor = to;
                }
                self.insert_raw("", if back { Kind::Back } else { Kind::Forward });
            }
            EditKey::Enter => {
                if self.multiline {
                    self.insert("\n", Kind::Typing);
                } else {
                    return true;
                }
            }
        }
        false
    }

    fn move_to(&mut self, to: usize, extend: bool) {
        self.focus = to;
        if !extend {
            self.anchor = to;
        }
    }

    fn set_preedit(&mut self, text: &str, cursor: Option<(usize, usize)>) {
        if text.is_empty() {
            self.preedit = None;
            return;
        }
        if self.preedit.is_none() && !self.selection().is_empty() {
            // The composition replaces the selection (the delete joins the commit's undo step).
            self.insert_raw("", Kind::Other);
        }
        let text = self.sanitize(text);
        let cursor = cursor.map(|(a, b)| (snap_in(&text, a), snap_in(&text, b)));
        self.preedit = Some(Preedit { text, cursor });
    }

    fn cancel_preedit(&mut self) {
        self.preedit = None;
    }

    // ---- editing primitives -----------------------------------------------------------------------------------

    /// Replaces line breaks and control characters according to the field kind.
    fn sanitize(&self, s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        let mut chars = s.chars().peekable();
        while let Some(c) = chars.next() {
            match c {
                '\r' | '\n' | '\u{2028}' | '\u{2029}' | '\u{85}' => {
                    if c == '\r' && chars.peek() == Some(&'\n') {
                        let _ = chars.next();
                    }
                    out.push(if self.multiline { '\n' } else { ' ' });
                }
                '\t' => out.push(if self.multiline { '\t' } else { ' ' }),
                c if c.is_control() => {}
                c => out.push(c),
            }
        }
        out
    }

    fn insert(&mut self, s: &str, kind: Kind) {
        let mut s = self.sanitize(s);
        if s.is_empty() {
            return;
        }
        if let Some(max) = self.max_len {
            let room = max.saturating_sub(count(&self.text) - count(self.selected_text()));
            if room == 0 && self.selection().is_empty() {
                return;
            }
            s = s.graphemes(true).take(room).collect();
            if s.is_empty() {
                return;
            }
        }
        self.insert_raw(&s, kind);
    }

    /// Replaces the selection with `s` (already sanitised) and records undo.
    fn insert_raw(&mut self, s: &str, kind: Kind) {
        let sel = self.selection();
        if s.is_empty() && sel.is_empty() {
            return;
        }
        if self.last != Some(kind) || kind == Kind::Other {
            self.undo.push(Snap {
                text: self.text.clone(),
                anchor: self.anchor,
                focus: self.focus,
            });
            if self.undo.len() > UNDO_LIMIT {
                let _ = self.undo.remove(0);
            }
        }
        self.redo.clear();
        self.last = Some(kind);
        self.text.replace_range(sel.clone(), s);
        let at = sel.start + s.len();
        self.anchor = at;
        self.focus = at;
    }

    fn undo_step(&mut self) {
        if let Some(s) = self.undo.pop() {
            self.redo.push(Snap {
                text: self.text.clone(),
                anchor: self.anchor,
                focus: self.focus,
            });
            self.text = s.text;
            self.anchor = s.anchor;
            self.focus = s.focus;
        }
        self.last = None;
    }

    fn redo_step(&mut self) {
        if let Some(s) = self.redo.pop() {
            self.undo.push(Snap {
                text: self.text.clone(),
                anchor: self.anchor,
                focus: self.focus,
            });
            self.text = s.text;
            self.anchor = s.anchor;
            self.focus = s.focus;
        }
        self.last = None;
    }

    // ---- text geometry (byte indices on grapheme boundaries) ----------------------------------------------------

    fn snap(&self, i: usize) -> usize {
        snap_in(&self.text, i)
    }

    fn prev(&self, i: usize) -> usize {
        self.text
            .grapheme_indices(true)
            .map(|(s, _)| s)
            .take_while(|s| *s < i)
            .last()
            .unwrap_or(0)
    }

    fn next(&self, i: usize) -> usize {
        self.text
            .grapheme_indices(true)
            .map(|(s, g)| s + g.len())
            .find(|e| *e > i)
            .unwrap_or(self.text.len())
    }

    fn word_left(&self, i: usize) -> usize {
        self.text
            .unicode_word_indices()
            .map(|(s, _)| s)
            .take_while(|s| *s < i)
            .last()
            .unwrap_or(0)
    }

    fn word_right(&self, i: usize) -> usize {
        self.text
            .unicode_word_indices()
            .map(|(s, w)| s + w.len())
            .find(|e| *e > i)
            .unwrap_or(self.text.len())
    }

    fn word_at(&self, i: usize) -> (usize, usize) {
        for (s, w) in self.text.unicode_word_indices() {
            if i >= s && i <= s + w.len() {
                return (s, s + w.len());
            }
        }
        (i, i)
    }

    fn line_start(&self, i: usize) -> usize {
        if self.multiline {
            self.text[..i].rfind('\n').map_or(0, |p| p + 1)
        } else {
            0
        }
    }

    fn line_end(&self, i: usize) -> usize {
        if self.multiline {
            self.text[i..].find('\n').map_or(self.text.len(), |p| i + p)
        } else {
            self.text.len()
        }
    }

    /// Up/Down in a multi-line field by logical lines, keeping the column (in graphemes) across short lines.
    fn vertical(&mut self, up: bool) -> usize {
        let f = self.focus;
        let start = self.line_start(f);
        let col = *self
            .goal_col
            .get_or_insert_with(|| count(&self.text[start..f]));
        let target_start = if up {
            if start == 0 {
                return 0;
            }
            self.line_start(start - 1)
        } else {
            let end = self.line_end(f);
            if end >= self.text.len() {
                return self.text.len();
            }
            end + 1
        };
        let target_end = self.line_end(target_start);
        let line = &self.text[target_start..target_end];
        target_start
            + line
                .grapheme_indices(true)
                .nth(col)
                .map_or(line.len(), |(i, _)| i)
    }
}

fn snap_in(text: &str, i: usize) -> usize {
    if i >= text.len() {
        return text.len();
    }
    text.grapheme_indices(true)
        .map(|(s, _)| s)
        .take_while(|s| *s <= i)
        .last()
        .unwrap_or(0)
}

fn masked(s: &str) -> String {
    std::iter::repeat_n(MASK, count(s)).collect()
}

/// Maps a byte index of `raw` to the index in its masked form.
fn mask_index(raw: &str, i: usize) -> usize {
    raw.grapheme_indices(true)
        .take_while(|(s, _)| *s < i)
        .count()
        * MASK.len_utf8()
}

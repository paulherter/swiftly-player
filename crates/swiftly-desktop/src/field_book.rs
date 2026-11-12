//! The one field model of the desktop app: every text field (sign-in, search, settings) is a [`FieldState`] over the
//! shared `swiftly_text::TextEditor`, held in a [`FieldBook`] that owns which field has the keyboard and the system
//! clipboard. Caret keys, word jumps, selection (keys and mouse), copy/cut/paste and undo are the editor's state machine;
//! a password editor can take a paste but never gives text to the clipboard (Copy and Cut do nothing).

use swiftly_text::{Clipboard, TextEditor, TextInputEvent};
use swiftly_ui::field::FieldState;

/// The system clipboard (`pbcopy`/`pbpaste`, `clip`/PowerShell, `wl-copy`/`xclip`); the editor decides what may go there.
#[derive(Default)]
pub struct SystemClipboard;

impl Clipboard for SystemClipboard {
    fn get_text(&mut self) -> Option<String> {
        crate::signin_flows::paste_text()
    }
    fn set_text(&mut self, text: &str) {
        let _ = crate::signin_flows::copy_text(text);
    }
}

/// Several fields, at most one with the keyboard. `K` names a field (a form's own enum).
pub struct FieldBook<K: Copy + PartialEq> {
    fields: Vec<(K, FieldState)>,
    focus: Option<K>,
    clip: Box<dyn Clipboard>,
}

impl<K: Copy + PartialEq> FieldBook<K> {
    /// A book over the system clipboard.
    pub fn new() -> FieldBook<K> {
        FieldBook {
            fields: Vec::new(),
            focus: None,
            clip: Box::new(SystemClipboard),
        }
    }

    /// Replaces the clipboard (tests use a memory one).
    pub fn with_clipboard(mut self, clip: Box<dyn Clipboard>) -> FieldBook<K> {
        self.clip = clip;
        self
    }

    /// Swaps the clipboard in place.
    pub fn set_clipboard(&mut self, clip: Box<dyn Clipboard>) {
        self.clip = clip;
    }

    /// Adds a field.
    pub fn add(mut self, key: K, editor: TextEditor) -> FieldBook<K> {
        self.fields.push((key, FieldState::new(editor)));
        self
    }

    /// Adds the field when it is not there yet (forms with a variable number of fields).
    pub fn ensure(&mut self, key: K, make: impl FnOnce() -> TextEditor) {
        if self.state(key).is_none() {
            self.fields.push((key, FieldState::new(make())));
        }
    }

    /// The field with the keyboard.
    pub fn focused(&self) -> Option<K> {
        self.focus
    }

    /// Gives the keyboard to `key` (its caret and selection stay as they were); the one before loses it.
    pub fn focus(&mut self, key: K, now: f64) {
        if self.focus == Some(key) {
            return;
        }
        if let Some(old) = self.focus
            && let Some(f) = self.state_mut(old)
        {
            f.set_focused(false, now);
        }
        self.focus = Some(key);
        if let Some(f) = self.state_mut(key) {
            f.set_focused(true, now);
        }
    }

    /// Takes the keyboard from every field.
    pub fn blur(&mut self, now: f64) {
        if let Some(old) = self.focus.take()
            && let Some(f) = self.state_mut(old)
        {
            f.set_focused(false, now);
        }
    }

    /// The state of one field.
    pub fn state(&self, key: K) -> Option<&FieldState> {
        self.fields.iter().find(|(k, _)| *k == key).map(|(_, f)| f)
    }

    /// The state of one field, mutable.
    pub fn state_mut(&mut self, key: K) -> Option<&mut FieldState> {
        self.fields
            .iter_mut()
            .find(|(k, _)| *k == key)
            .map(|(_, f)| f)
    }

    /// The committed text of a field.
    pub fn text(&self, key: K) -> &str {
        self.state(key).map_or("", |f| f.editor.text())
    }

    /// Replaces a field's text from outside (the caret goes to the end). Does nothing when it already says that.
    pub fn set_text(&mut self, key: K, text: &str) {
        if let Some(f) = self.state_mut(key)
            && f.editor.text() != text
        {
            f.editor.set_text(text);
        }
    }

    /// Sends an event to the field with the keyboard. Returns what changed (`None`: no field has it).
    pub fn apply(&mut self, ev: &TextInputEvent, now: f64) -> Option<swiftly_text::Outcome> {
        let key = self.focus?;
        let f = self
            .fields
            .iter_mut()
            .find(|(k, _)| *k == key)
            .map(|(_, f)| f)?;
        Some(f.apply(ev, self.clip.as_mut(), now))
    }
}

impl<K: Copy + PartialEq> Default for FieldBook<K> {
    fn default() -> Self {
        Self::new()
    }
}

/// Byte offset in the committed `text` for a byte offset in the editor's display text: a password shows one bullet per
/// character, so the display index counts bullets.
pub fn committed_index(text: &str, password: bool, display_index: usize) -> usize {
    if !password {
        return display_index.min(text.len());
    }
    let n = display_index / swiftly_text::MASK.len_utf8();
    text.char_indices().nth(n).map_or(text.len(), |(i, _)| i)
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_text::{EditKey, MemoryClipboard, Mods, TextInputEvent as E};

    fn book() -> FieldBook<u8> {
        FieldBook::new()
            .with_clipboard(Box::new(MemoryClipboard::default()))
            .add(0, TextEditor::single_line())
            .add(1, TextEditor::single_line().password())
    }
    fn type_in(b: &mut FieldBook<u8>, s: &str) {
        b.apply(&E::Text(s.into()), 0.0);
    }

    #[test]
    fn caret_keys_word_jump_and_selection_edit_in_the_middle() {
        let mut b = book();
        b.focus(0, 0.0);
        type_in(&mut b, "hello big world");
        b.apply(&E::Key(EditKey::Home, Mods::NONE), 0.0);
        b.apply(&E::Key(EditKey::Right, Mods::WORD), 0.0);
        b.apply(&E::Text("!".into()), 0.0);
        assert_eq!(b.text(0), "hello! big world");
        b.apply(&E::Key(EditKey::End, Mods::SHIFT), 0.0);
        assert_eq!(b.state(0).unwrap().editor.selected_text(), " big world");
        b.apply(&E::Key(EditKey::Left, Mods::NONE), 0.0);
        assert!(b.state(0).unwrap().editor.selection().is_empty());
        b.apply(
            &E::SetCaret {
                index: 0,
                extend: false,
            },
            0.0,
        );
        b.apply(
            &E::SetCaret {
                index: 5,
                extend: true,
            },
            0.0,
        );
        assert_eq!(b.state(0).unwrap().editor.selected_text(), "hello");
    }

    #[test]
    fn copy_cut_paste_go_through_the_clipboard() {
        let mut b = book();
        b.focus(0, 0.0);
        type_in(&mut b, "alpha beta");
        b.apply(&E::SelectAll, 0.0);
        b.apply(&E::Copy, 0.0);
        b.apply(&E::Key(EditKey::End, Mods::NONE), 0.0);
        b.apply(&E::Paste, 0.0);
        assert_eq!(b.text(0), "alpha betaalpha beta");
        b.apply(&E::SelectAll, 0.0);
        b.apply(&E::Cut, 0.0);
        assert_eq!(b.text(0), "");
        b.apply(&E::Paste, 0.0);
        assert_eq!(b.text(0), "alpha betaalpha beta");
        b.apply(&E::Undo, 0.0);
        assert_eq!(b.text(0), "");
    }

    #[test]
    fn a_password_takes_a_paste_but_never_gives_text_away() {
        let mut b = book();
        b.focus(0, 0.0);
        type_in(&mut b, "visible");
        b.apply(&E::SelectAll, 0.0);
        b.apply(&E::Copy, 0.0);
        b.focus(1, 0.0);
        b.apply(&E::Paste, 0.0);
        assert_eq!(b.text(1), "visible", "pasting into a password works");
        b.apply(&E::SelectAll, 0.0);
        b.apply(&E::Text("x".into()), 0.0);
        b.apply(&E::Text("secret".into()), 0.0);
        b.apply(&E::SelectAll, 0.0);
        b.apply(&E::Copy, 0.0);
        b.apply(&E::Cut, 0.0);
        assert_eq!(b.text(1), "xsecret", "cut does not remove a password");
        b.focus(0, 0.0);
        b.apply(&E::SelectAll, 0.0);
        b.apply(&E::Paste, 0.0);
        assert_eq!(
            b.text(0),
            "visible",
            "the clipboard still holds the old text, not the password"
        );
        let display = b.state(1).unwrap().editor.display();
        assert!(!display.text.contains('x'), "a password is only bullets");
    }

    #[test]
    fn the_keyboard_is_in_one_field_and_the_other_keeps_its_caret() {
        let mut b = book();
        b.focus(0, 0.0);
        type_in(&mut b, "abc");
        b.apply(&E::Key(EditKey::Left, Mods::NONE), 0.0);
        b.focus(1, 0.0);
        type_in(&mut b, "pw");
        assert_eq!((b.text(0), b.text(1)), ("abc", "pw"));
        assert_eq!(b.state(0).unwrap().editor.caret(), 2);
        assert!(!b.state(0).unwrap().focused && b.state(1).unwrap().focused);
        b.blur(0.0);
        assert!(
            b.apply(&E::Text("z".into()), 0.0).is_none(),
            "nobody has the keyboard"
        );
    }

    #[test]
    fn display_offsets_of_a_password_count_bullets() {
        assert_eq!(committed_index("héllo", true, 6), "hé".len());
        assert_eq!(committed_index("héllo", false, 3), 3);
        assert_eq!(committed_index("ab", true, 99), 2);
    }
}

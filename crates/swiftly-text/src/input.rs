// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The platform-neutral input a text field understands. The shells (winit on desktop, later Android's
//! `InputConnection`, UIKit's `UITextInput`) map their own events to [`TextInputEvent`]; nothing here knows winit.

/// Modifier state of a key press, already mapped to what the editor needs (the shell decides that Alt is "word" on
/// macOS and Ctrl is "word" elsewhere, and that Cmd is "line" on macOS).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Mods {
    /// Extend the selection.
    pub shift: bool,
    /// Move or delete by word.
    pub word: bool,
    /// Move or delete to the line edge (Home/End behaviour on arrows and Backspace).
    pub line: bool,
}

impl Mods {
    /// No modifiers.
    pub const NONE: Mods = Mods {
        shift: false,
        word: false,
        line: false,
    };
    /// Shift only.
    pub const SHIFT: Mods = Mods {
        shift: true,
        word: false,
        line: false,
    };
    /// Word-wise.
    pub const WORD: Mods = Mods {
        shift: false,
        word: true,
        line: false,
    };
    /// Shift and word-wise.
    pub const SHIFT_WORD: Mods = Mods {
        shift: true,
        word: true,
        line: false,
    };
}

/// An editing key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditKey {
    /// Arrow left (visual direction: in a right-to-left paragraph it moves forward in the text).
    Left,
    /// Arrow right (visual).
    Right,
    /// Arrow up.
    Up,
    /// Arrow down.
    Down,
    /// Start of the line.
    Home,
    /// End of the line.
    End,
    /// Backspace.
    Backspace,
    /// Forward delete.
    Delete,
    /// Return: a line break in a multi-line field, a submit in a single-line one.
    Enter,
}

/// One input event for a text field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TextInputEvent {
    /// Typed text from a key press (not composition).
    Text(String),
    /// Composition: the text under composition changed. `cursor` is the byte range inside `text` the input method
    /// wants highlighted as the active clause (equal ends: a caret there; `None`: no caret). Empty text ends the
    /// composition without committing (as winit's `Ime::Preedit("", None)`).
    Preedit {
        /// The preedit text.
        text: String,
        /// Byte range inside `text`.
        cursor: Option<(usize, usize)>,
    },
    /// Composition finished with this text.
    Commit(String),
    /// Composition abandoned (focus lost, `Ime::Disabled`, Esc in the input method).
    CancelComposition,
    /// A key.
    Key(EditKey, Mods),
    /// Select everything.
    SelectAll,
    /// Copy the selection.
    Copy,
    /// Cut the selection.
    Cut,
    /// Paste from the clipboard.
    Paste,
    /// Undo.
    Undo,
    /// Redo.
    Redo,
    /// Pointer or touch put the caret at a byte index (`extend`: shift-click or drag).
    SetCaret {
        /// Byte index in the committed text.
        index: usize,
        /// Keep the anchor.
        extend: bool,
    },
    /// Double tap: select the word at a byte index.
    SelectWord(usize),
    /// The clear button: empties the field (undoable).
    Clear,
}

/// The system clipboard as the editor sees it. The shell implements it over `arboard` or the platform call.
pub trait Clipboard {
    /// The text on the clipboard, if any.
    fn get_text(&mut self) -> Option<String>;
    /// Puts text on the clipboard.
    fn set_text(&mut self, text: &str);
}

/// A clipboard in memory (tests and shells without a system clipboard).
#[derive(Clone, Debug, Default)]
pub struct MemoryClipboard {
    /// The held text.
    pub text: Option<String>,
}

impl Clipboard for MemoryClipboard {
    fn get_text(&mut self) -> Option<String> {
        self.text.clone()
    }
    fn set_text(&mut self, text: &str) {
        self.text = Some(text.to_owned());
    }
}

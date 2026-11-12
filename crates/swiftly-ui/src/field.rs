// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The text field: [`FieldState`] (editor + blink clock + loupe) and [`field_content`], the editable text area with
//! caret, selection, selection handles on touch, preedit underline and placeholder. The chrome around it (the capsule,
//! the magnifier, the clear button) belongs to the screen, as in the Swift search field.

use crate::a11y::{A11yNode, Role};
use crate::view::Node;
use swiftly_layout::{Alignment, EdgeInsets};
use swiftly_render::Color;
use swiftly_text::{
    Align, Clipboard, Display, Outcome, PreeditStyle, TextEditor, TextInputEvent, TextStyle,
};

/// Caret blink half-period in ms (UIKit: 0.5 s on, 0.5 s off; the caret stays solid while typing).
pub const BLINK_MS: f64 = 500.0;
/// Caret width in points (`UITextInput` default 2 at 3x; the Swift field draws 1.5).
pub const CARET_WIDTH: f32 = 1.5;
/// Key of the editable area, so a screen can find its frame in the window (the anchor of the candidate window).
pub const CONTENT_KEY: &str = "field.text";
/// Diameter of the touch selection handles' knob.
pub const HANDLE_KNOB: f32 = 10.0;

/// Whether the caret is drawn `now` ms, given the last edit or caret move at `last_input`.
pub fn caret_on(now: f64, last_input: f64) -> bool {
    (((now - last_input).max(0.0) / BLINK_MS) as u64).is_multiple_of(2)
}

/// The long-press loupe seam: the platform draws the magnifier at the finger and the caret follows `index`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Loupe {
    /// Byte index of the committed text the caret is over.
    pub index: usize,
}

/// Editor plus the state a view needs.
#[derive(Clone, Debug)]
pub struct FieldState {
    /// The editor.
    pub editor: TextEditor,
    /// Whether the field has input focus.
    pub focused: bool,
    /// Time of the last input (restarts the blink).
    pub last_input_ms: f64,
    /// The loupe while a long press drags the caret.
    pub loupe: Option<Loupe>,
}

impl FieldState {
    /// A state around an editor.
    pub fn new(editor: TextEditor) -> FieldState {
        FieldState {
            editor,
            focused: false,
            last_input_ms: 0.0,
            loupe: None,
        }
    }
    /// Feeds an event; any visible change restarts the blink so the caret is solid.
    pub fn apply(&mut self, ev: &TextInputEvent, clip: &mut dyn Clipboard, now: f64) -> Outcome {
        let out = self.editor.apply(ev, clip);
        if out.view_changed {
            self.last_input_ms = now;
        }
        out
    }
    /// Gives or takes the focus.
    pub fn set_focused(&mut self, focused: bool, now: f64) {
        if focused != self.focused {
            self.last_input_ms = now;
        }
        self.focused = focused;
        if !focused {
            self.loupe = None;
        }
    }
    /// A long press at a byte index starts the loupe and moves the caret there.
    pub fn long_press(&mut self, index: usize, clip: &mut dyn Clipboard, now: f64) {
        let _ = self.apply(
            &TextInputEvent::SetCaret {
                index,
                extend: false,
            },
            clip,
            now,
        );
        self.loupe = Some(Loupe { index });
    }
    /// The finger lifts: the loupe goes.
    pub fn end_long_press(&mut self) {
        self.loupe = None;
    }
    /// What `field_content` needs at `now`.
    pub fn view(&self, placeholder: &str, touch: bool, now: f64) -> FieldView {
        FieldView {
            display: self.editor.display(),
            placeholder: placeholder.to_owned(),
            focused: self.focused,
            caret_on: self.focused && caret_on(now, self.last_input_ms),
            touch,
            loupe: self.loupe,
        }
    }
    /// The accessibility node for the screen-reader bridges.
    pub fn a11y(&self, key: &str, label: &str, placeholder: &str) -> A11yNode {
        let (value, sel) = self.editor.a11y_value();
        let role = if self.editor.is_password() {
            Role::PasswordField
        } else if self.editor.is_multiline() {
            Role::MultilineTextField
        } else {
            Role::TextField
        };
        let mut n = A11yNode::new(key, role, label);
        n.value = Some(value);
        n.selection = Some(sel);
        n.placeholder = Some(placeholder.to_owned());
        n.focused = self.focused;
        n.editable = true;
        n
    }
}

/// Everything the view of a field reads (compared by value, so the view re-runs when the blink flips).
#[derive(Clone, Debug, PartialEq)]
pub struct FieldView {
    /// The display text with caret, selection and preedit.
    pub display: Display,
    /// Placeholder, shown while empty.
    pub placeholder: String,
    /// Input focus.
    pub focused: bool,
    /// The caret is in the on phase of its blink.
    pub caret_on: bool,
    /// Touch idiom: selection handles.
    pub touch: bool,
    /// Loupe seam.
    pub loupe: Option<Loupe>,
}

/// Colours and type of a field.
#[derive(Clone, Copy, Debug)]
pub struct FieldLook {
    /// Type of the text and placeholder.
    pub style: TextStyle,
    /// Text colour.
    pub text: Color,
    /// Placeholder colour.
    pub placeholder: Color,
    /// Caret and handle colour.
    pub caret: Color,
    /// Selection fill.
    pub selection: Color,
    /// Caret height in points (the line height when `None`).
    pub caret_height: Option<f32>,
}

fn at(x: f32, y: f32, w: f32, h: f32, node: Node) -> Node {
    node.frame(Some(w), Some(h), Alignment::CENTER)
        .padding(EdgeInsets {
            top: y,
            leading: x,
            bottom: 0.0,
            trailing: 0.0,
        })
}

/// The editable area. Its size is the text's (never zero high), so the screen can frame and align it.
pub fn field_content(cx: &crate::cx::Cx, v: &FieldView, look: &FieldLook) -> Node {
    let d = &v.display;
    let empty = d.text.is_empty();
    let measured = if !empty {
        d.text.as_str()
    } else if v.placeholder.is_empty() {
        "M"
    } else {
        v.placeholder.as_str()
    };
    let layout = cx
        .text
        .borrow_mut()
        .layout(measured, &look.style, None, None, Align::Start);
    let (tw, lh) = layout.size();
    let w = tw + CARET_WIDTH;
    let mut kids = Vec::new();
    if !empty {
        for r in layout.selection_rects(d.selection.clone()) {
            if d.selection.start < d.selection.end {
                kids.push(at(r.x, r.y, r.w, r.h, Node::rect(look.selection, 2.0)));
            }
        }
        for s in &d.spans {
            let (t, a) = match s.style {
                PreeditStyle::Underline => (1.0, 0.0),
                PreeditStyle::Active => (2.0, 0.16),
            };
            for r in layout.selection_rects(s.range.clone()) {
                if a > 0.0 {
                    kids.push(at(
                        r.x,
                        r.y,
                        r.w,
                        r.h,
                        Node::rect(look.selection.with_alpha(a + 0.1), 0.0),
                    ));
                }
                kids.push(at(r.x, r.y + r.h - t, r.w, t, Node::rect(look.text, 0.0)));
            }
        }
    }
    let (shown, c) = if empty {
        (v.placeholder.as_str(), look.placeholder)
    } else {
        (d.text.as_str(), look.text)
    };
    if !shown.is_empty() {
        kids.push(Node::text(cx, shown, &look.style, c, Some(1), Align::Start));
    }
    let h = look.caret_height.unwrap_or(lh);
    let mut width = w;
    if let (true, Some(i)) = (v.focused, d.caret) {
        let rc = layout.caret_rect(if empty { 0 } else { i }, CARET_WIDTH);
        let x = if empty { 0.0 } else { rc.x };
        if v.caret_on && d.selection.start == d.selection.end {
            kids.push(at(
                x,
                rc.y + (rc.h - h) / 2.0,
                CARET_WIDTH,
                h,
                Node::rect(look.caret, 0.75),
            ));
        }
        width = width.max(x + CARET_WIDTH);
    }
    if v.focused && v.touch && !empty && d.selection.start < d.selection.end {
        // Handles: a stem and a knob below the start, above the end (the UIKit look).
        let rs = layout.selection_rects(d.selection.clone());
        if let (Some(first), Some(last)) = (rs.first(), rs.last()) {
            kids.push(at(
                first.x - 0.75,
                first.y,
                CARET_WIDTH,
                first.h,
                Node::rect(look.caret, 0.0),
            ));
            kids.push(at(
                first.x - HANDLE_KNOB / 2.0,
                first.y - HANDLE_KNOB + 2.0,
                HANDLE_KNOB,
                HANDLE_KNOB,
                Node::rect(look.caret, HANDLE_KNOB / 2.0),
            ));
            kids.push(at(
                last.x + last.w - 0.75,
                last.y,
                CARET_WIDTH,
                last.h,
                Node::rect(look.caret, 0.0),
            ));
            kids.push(at(
                last.x + last.w - HANDLE_KNOB / 2.0,
                last.y + last.h - 2.0,
                HANDLE_KNOB,
                HANDLE_KNOB,
                Node::rect(look.caret, HANDLE_KNOB / 2.0),
            ));
        }
    }
    Node::zstack(Alignment::TOP_LEADING, kids)
        .frame(Some(width), Some(lh), Alignment::TOP_LEADING)
        .key(CONTENT_KEY)
}

/// The rectangle (x, y, w, h in the content's own coordinates) the input method's candidate window anchors to: the
/// preedit or the caret. The shell adds the field's window position and passes it to `Window::set_ime_cursor_area`.
pub fn candidate_rect(cx: &crate::cx::Cx, v: &FieldView, look: &FieldLook) -> (f32, f32, f32, f32) {
    let d = &v.display;
    let layout = cx
        .text
        .borrow_mut()
        .layout(&d.text, &look.style, None, None, Align::Start);
    let (s, e) = match &d.preedit {
        Some(r) => (r.start, r.end),
        None => {
            let c = d.caret.unwrap_or(0);
            (c, c)
        }
    };
    let a = layout.caret_rect(s, CARET_WIDTH);
    let b = layout.caret_rect(e, CARET_WIDTH);
    let (x0, x1) = (a.x.min(b.x), a.x.max(b.x));
    (x0, a.y, (x1 - x0).max(CARET_WIDTH), a.h)
}

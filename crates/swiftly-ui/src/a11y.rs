// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The accessibility seam: a small node tree the screen-reader bridges (AccessKit on desktop, TalkBack's
//! `AccessibilityNodeInfo` on Android, UIAccessibility if the Rust UI ever runs on Apple) read. Components return
//! their node; the screen assembles the tree and the bridge pairs each node with the laid-out rectangle by `key`.

use std::ops::Range;

/// What a node is to the screen reader.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// Container without meaning of its own.
    Group,
    /// Static text.
    Text,
    /// Button.
    Button,
    /// Single-line text field.
    TextField,
    /// Multi-line text field.
    MultilineTextField,
    /// Password field (value is bullets).
    PasswordField,
    /// Search field.
    SearchField,
    /// A heading (`label` is the text, `level` its rank).
    Heading,
    /// A picture with a description.
    Image,
    /// A list or a row of items (rail, grid).
    List,
    /// An item of a list.
    ListItem,
    /// A tab of the tab bar.
    Tab,
    /// The group of tabs.
    TabList,
    /// An on/off switch.
    Switch,
    /// A slider (scrubber, volume).
    Slider,
    /// A progress or loading indicator.
    ProgressBar,
    /// A sheet or dialog that takes focus.
    Dialog,
    /// A status line that is announced when it changes (`live`).
    Status,
    /// Decorative: neither the node nor anything under it is exposed.
    Decorative,
}

/// How a change of a node is announced.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Live {
    /// Not announced.
    #[default]
    Off,
    /// Announced when the reader is idle.
    Polite,
    /// Announced at once.
    Assertive,
}

/// One node.
#[derive(Clone, Debug, PartialEq)]
pub struct A11yNode {
    /// The UI key of the element, to find its rectangle.
    pub key: String,
    /// Role.
    pub role: Role,
    /// The name ("Suche").
    pub label: String,
    /// The value (the text of a field; bullets for a password).
    pub value: Option<String>,
    /// Selection or caret in characters (Unicode scalar values) of `value`.
    pub selection: Option<Range<usize>>,
    /// Placeholder text, announced when the value is empty.
    pub placeholder: Option<String>,
    /// Whether it has input focus.
    pub focused: bool,
    /// Whether the user can edit it.
    pub editable: bool,
    /// Children in reading order.
    pub children: Vec<A11yNode>,
    /// Identity of the laid-out node (0 for a node made by hand); the bridge uses it for actions.
    pub id: u64,
    /// The frame in points from the top-left of the window; `None` for a node made by hand.
    pub bounds: Option<[f32; 4]>,
    /// Extra help ("Doppeltippen zum Abspielen").
    pub hint: Option<String>,
    /// Announcement of changes.
    pub live: Live,
    /// Selected (tab, row).
    pub selected: Option<bool>,
    /// On or off (switch).
    pub toggled: Option<bool>,
    /// Current, minimum, maximum (slider, progress).
    pub range: Option<(f64, f64, f64)>,
    /// Dimmed and not operable.
    pub disabled: bool,
    /// Rank of a heading.
    pub level: Option<u8>,
    /// Whether activating it does something (tap or Enter).
    pub activatable: bool,
    /// The label stands for everything under the node: the children are not exposed.
    pub merge: bool,
}

impl A11yNode {
    /// A node with a role and a label.
    pub fn new(key: impl Into<String>, role: Role, label: impl Into<String>) -> A11yNode {
        A11yNode {
            key: key.into(),
            role,
            label: label.into(),
            value: None,
            selection: None,
            placeholder: None,
            focused: false,
            editable: false,
            children: Vec::new(),
            id: 0,
            bounds: None,
            hint: None,
            live: Live::Off,
            selected: None,
            toggled: None,
            range: None,
            disabled: false,
            level: None,
            activatable: false,
            merge: false,
        }
    }
    /// A node that stands for its whole subtree.
    #[must_use]
    pub fn merged(mut self) -> A11yNode {
        self.merge = true;
        self
    }
    /// Sets the value.
    #[must_use]
    pub fn with_value(mut self, v: impl Into<String>) -> A11yNode {
        self.value = Some(v.into());
        self
    }
    /// Sets the hint.
    #[must_use]
    pub fn with_hint(mut self, h: impl Into<String>) -> A11yNode {
        self.hint = Some(h.into());
        self
    }
    /// Sets how changes are announced.
    #[must_use]
    pub fn with_live(mut self, l: Live) -> A11yNode {
        self.live = l;
        self
    }
    /// Sets the selected state.
    #[must_use]
    pub fn with_selected(mut self, s: bool) -> A11yNode {
        self.selected = Some(s);
        self
    }
    /// Sets the on/off state.
    #[must_use]
    pub fn with_toggled(mut self, t: bool) -> A11yNode {
        self.toggled = Some(t);
        self
    }
    /// Sets current, minimum and maximum.
    #[must_use]
    pub fn with_range(mut self, now: f64, min: f64, max: f64) -> A11yNode {
        self.range = Some((now, min, max));
        self
    }
    /// Marks it dimmed.
    #[must_use]
    pub fn disabled(mut self, d: bool) -> A11yNode {
        self.disabled = d;
        self
    }
    /// Sets the heading rank.
    #[must_use]
    pub fn with_level(mut self, l: u8) -> A11yNode {
        self.level = Some(l);
        self
    }
    /// Adds a child.
    #[must_use]
    pub fn with_child(mut self, c: A11yNode) -> A11yNode {
        self.children.push(c);
        self
    }
    /// All nodes depth first, reading order.
    pub fn walk(&self) -> Vec<&A11yNode> {
        let mut out = vec![self];
        for c in &self.children {
            out.extend(c.walk());
        }
        out
    }
}

/// What a screen reader says for a node, in the order `role, label, value, state, hint` as NVDA and Narrator do.
pub fn spoken(n: &A11yNode) -> String {
    let mut parts: Vec<String> = Vec::new();
    if !n.label.is_empty() {
        parts.push(n.label.clone());
    }
    let role = match n.role {
        Role::Button => "Schaltfläche",
        Role::TextField | Role::MultilineTextField => "Bearbeiten",
        Role::PasswordField => "Passwort",
        Role::SearchField => "Suchfeld",
        Role::Heading => "Überschrift",
        Role::Image => "Grafik",
        Role::List => "Liste",
        Role::ListItem => "",
        Role::Tab => "Tab",
        Role::TabList => "Tableiste",
        Role::Switch => "Schalter",
        Role::Slider => "Schieberegler",
        Role::ProgressBar => "Fortschrittsanzeige",
        Role::Dialog => "Dialog",
        Role::Status | Role::Text | Role::Group | Role::Decorative => "",
    };
    if !role.is_empty() {
        parts.push(role.to_owned());
    }
    match (&n.value, n.role) {
        (Some(v), Role::PasswordField) => parts.push(format!("{} Zeichen", v.chars().count())),
        (Some(v), _) if !v.is_empty() => parts.push(v.clone()),
        (_, _) => {
            if let (Some(p), true) = (&n.placeholder, n.value.as_deref().is_none_or(str::is_empty))
            {
                parts.push(p.clone());
            }
        }
    }
    if let Some((now, min, max)) = n.range
        && max > min
    {
        parts.push(format!("{:.0} Prozent", (now - min) / (max - min) * 100.0));
    }
    if n.selected == Some(true) {
        parts.push("ausgewählt".to_owned());
    }
    match n.toggled {
        Some(true) => parts.push("ein".to_owned()),
        Some(false) => parts.push("aus".to_owned()),
        None => {}
    }
    if n.disabled {
        parts.push("nicht verfügbar".to_owned());
    }
    if let Some(h) = &n.hint {
        parts.push(h.clone());
    }
    parts.join(", ")
}

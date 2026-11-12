//! The screen-reader bridge: turns the nodes of the shared UI (`swiftly_ui::a11y`) into an AccessKit tree, which the
//! winit adapter exposes as UI Automation on Windows and AT-SPI on Linux, and maps the actions a reader asks for back
//! to a tap on the shared UI. No window is needed here, so the host tests read the tree directly.

use accesskit::{
    Action, ActionRequest, Live, Node, NodeId, Rect, Role, TextPosition, TextSelection, Toggled,
    TreeId, TreeInfo, TreeUpdate,
};
use std::collections::HashMap;
use swiftly_ui::a11y::{A11yNode, Live as UiLive, Role as UiRole};

/// The window node.
pub const ROOT: NodeId = NodeId(1);

/// The tree of one frame plus the frames of its nodes (to turn an action into a tap).
#[derive(Debug)]
pub struct Built {
    /// What to hand to the adapter.
    pub update: TreeUpdate,
    /// Centre of every node in window points, by AccessKit id.
    pub centres: HashMap<u64, (f32, f32)>,
}

fn role(r: UiRole, merged_text: bool) -> Role {
    match r {
        UiRole::Group => Role::GenericContainer,
        UiRole::Text => Role::Label,
        UiRole::Button => Role::Button,
        UiRole::TextField => Role::TextInput,
        UiRole::MultilineTextField => Role::MultilineTextInput,
        UiRole::PasswordField => Role::PasswordInput,
        UiRole::SearchField => Role::SearchInput,
        UiRole::Heading => Role::Heading,
        UiRole::Image => Role::Image,
        UiRole::List => Role::List,
        UiRole::ListItem => Role::ListItem,
        UiRole::Tab => Role::Tab,
        UiRole::TabList => Role::TabList,
        UiRole::Switch => Role::Switch,
        UiRole::Slider => Role::Slider,
        UiRole::ProgressBar => Role::ProgressIndicator,
        UiRole::Dialog => Role::Dialog,
        UiRole::Status => {
            if merged_text {
                Role::Status
            } else {
                Role::GenericContainer
            }
        }
        UiRole::Decorative => Role::GenericContainer,
    }
}

fn node_id(n: &A11yNode, index: u64) -> NodeId {
    // Nodes made by hand (no identity) get a number from their position; real ones keep the layout identity (62 bits)
    // so the id survives rebuilds and the reader keeps its place.
    if n.id == 0 {
        NodeId(0x8000_0000_0000_0000 | index)
    } else {
        NodeId((n.id & 0x3FFF_FFFF_FFFF_FFFF).max(2))
    }
}

struct Builder {
    scale: f32,
    nodes: Vec<(NodeId, Node)>,
    centres: HashMap<u64, (f32, f32)>,
    focus: Option<NodeId>,
    counter: u64,
}

impl Builder {
    fn add(&mut self, n: &A11yNode) -> NodeId {
        self.counter += 1;
        let id = node_id(n, self.counter);
        let is_text_field = matches!(
            n.role,
            UiRole::TextField
                | UiRole::MultilineTextField
                | UiRole::PasswordField
                | UiRole::SearchField
        );
        let mut node = Node::new(role(n.role, true));
        if !n.label.is_empty() && n.role != UiRole::Text {
            node.set_label(n.label.as_str());
        }
        if n.role == UiRole::Text {
            node.set_value(n.label.as_str());
        }
        if let Some(h) = &n.hint {
            node.set_description(h.as_str());
        }
        if let Some([x, y, w, h]) = n.bounds {
            let s = f64::from(self.scale);
            node.set_bounds(Rect {
                x0: f64::from(x) * s,
                y0: f64::from(y) * s,
                x1: f64::from(x + w) * s,
                y1: f64::from(y + h) * s,
            });
            self.centres.insert(id.0, (x + w / 2.0, y + h / 2.0));
        }
        node.set_live(match n.live {
            UiLive::Off => Live::Off,
            UiLive::Polite => Live::Polite,
            UiLive::Assertive => Live::Assertive,
        });
        if let Some(s) = n.selected {
            node.set_selected(s);
        }
        if let Some(t) = n.toggled {
            node.set_toggled(if t { Toggled::True } else { Toggled::False });
        }
        if let Some((now, min, max)) = n.range {
            node.set_numeric_value(now);
            node.set_min_numeric_value(min);
            node.set_max_numeric_value(max);
        }
        if let Some(l) = n.level {
            node.set_level(usize::from(l));
        }
        if n.disabled {
            node.set_disabled();
        }
        if n.activatable {
            node.add_action(Action::Click);
        }
        if n.activatable || is_text_field {
            node.add_action(Action::Focus);
        }
        let mut children = Vec::new();
        if is_text_field {
            if let Some(p) = &n.placeholder {
                node.set_placeholder(p.as_str());
            }
            // The text lives in a run child: the reader reads the value, moves the caret and selects by characters.
            let value = n.value.clone().unwrap_or_default();
            let run_id = NodeId(id.0 ^ 0x4000_0000_0000_0000);
            let mut run = Node::new(Role::TextRun);
            run.set_value(value.as_str());
            run.set_character_lengths(
                value
                    .chars()
                    .map(|c| c.len_utf8() as u8)
                    .collect::<Vec<_>>(),
            );
            run.set_word_starts(word_starts(&value));
            if let Some([x, y, w, h]) = n.bounds {
                let s = f64::from(self.scale);
                run.set_bounds(Rect {
                    x0: f64::from(x) * s,
                    y0: f64::from(y) * s,
                    x1: f64::from(x + w) * s,
                    y1: f64::from(y + h) * s,
                });
            }
            self.nodes.push((run_id, run));
            children.push(run_id);
            let sel = n.selection.clone().unwrap_or(0..0);
            let at = |i: usize| TextPosition {
                node: run_id,
                character_index: i,
            };
            node.set_text_selection(TextSelection {
                anchor: at(sel.start),
                focus: at(sel.end),
            });
            if n.role != UiRole::PasswordField {
                node.set_value(value.as_str());
            } else {
                node.set_value("\u{2022}".repeat(value.chars().count()));
            }
            if !n.editable {
                node.set_read_only();
            }
        } else {
            for c in &n.children {
                children.push(self.add(c));
            }
        }
        node.set_children(children);
        if n.focused {
            self.focus = Some(id);
        }
        self.nodes.push((id, node));
        id
    }
}

/// Character indices where a word starts (after whitespace), as AccessKit wants them; limited to what a `u8` holds.
fn word_starts(s: &str) -> Vec<u8> {
    let mut out = Vec::new();
    let mut prev_space = true;
    for (i, c) in s.chars().enumerate() {
        if !c.is_whitespace() && prev_space {
            match u8::try_from(i) {
                Ok(v) => out.push(v),
                Err(_) => break,
            }
        }
        prev_space = c.is_whitespace();
    }
    out
}

/// The AccessKit tree of one screen: a window node named `title` over `nodes`.
pub fn build(title: &str, nodes: &[A11yNode], scale: f32) -> Built {
    let mut b = Builder {
        scale,
        nodes: Vec::new(),
        centres: HashMap::new(),
        focus: None,
        counter: 0,
    };
    let kids: Vec<NodeId> = nodes.iter().map(|n| b.add(n)).collect();
    let mut root = Node::new(Role::Window);
    root.set_label(title);
    root.set_children(kids);
    let focus = b.focus.unwrap_or(ROOT);
    b.nodes.push((ROOT, root));
    let mut info = TreeInfo::new(ROOT);
    info.toolkit_name = Some("Swiftly".to_owned());
    Built {
        update: TreeUpdate {
            nodes: b.nodes,
            tree: Some(info),
            tree_id: TreeId::ROOT,
            focus,
        },
        centres: b.centres,
    }
}

/// What a reader asked for, in terms of the shared UI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wanted {
    /// Activate the node (tap); the AccessKit id.
    Click(u64),
    /// Nothing the UI can do.
    Ignore,
}

/// Maps an AccessKit action to the shared UI.
pub fn wanted(req: &ActionRequest) -> Wanted {
    match req.action {
        Action::Click => Wanted::Click(req.target_node.0),
        _ => Wanted::Ignore,
    }
}

//! The `tv` focus scene: a header button row and two poster rails with focusable tiles, for the focus goldens and the
//! Ui-level focus tests. Same components the Apple TV and Android TV shells use.

use crate::art;
use std::rc::Rc;
use swiftly_design::tokens::{colour, tv};
use swiftly_layout::{Align, Alignment, EdgeInsets, FlexFrame};
use swiftly_ui::components::{ButtonStyle, color, focus_id, themed_button, tile_card, tv_rail};
use swiftly_ui::{Action, Cx, Env, FocusId, Node, ScopeSpec, Ui};

/// Items per rail.
pub const ITEMS: usize = 60;

/// Focus id of tile `index` in rail `rail`.
pub fn tile_id(rail: usize, index: usize) -> FocusId {
    focus_id(format!("tv{rail}-{index}").as_str())
}

/// Focus id of the header button `index`.
pub fn button_id(index: usize) -> FocusId {
    focus_id(format!("btn{index}").as_str())
}

/// Builds the scene as a `Ui` (parts are `()`: nothing changes but focus).
pub fn ui(env: Env, cx: Cx) -> Ui<()> {
    let posters: Rc<Vec<_>> = Rc::new(art::posters(&cx).into_iter().take(12).collect());
    let view = move |_: &(), env: &Env, cx: &Cx| {
        let buttons = Node::hstack(
            Align::Center,
            Some(24.0),
            vec![
                themed_button(cx, "btn0", "Abspielen", ButtonStyle::Primary, "act.play")
                    .default_focus(),
                themed_button(cx, "btn1", "Merkliste", ButtonStyle::Secondary, "act.list"),
                themed_button(cx, "btn2", "Mehr", ButtonStyle::Secondary, "act.more"),
            ],
        )
        .padding(EdgeInsets {
            top: 0.0,
            leading: tv::RAILS_PADDING,
            bottom: 0.0,
            trailing: 0.0,
        })
        .focus_scope(ScopeSpec::section("buttons"));
        let mut rows = vec![buttons];
        for r in 0..2 {
            let (c2, p2) = (cx.clone(), Rc::clone(&posters));
            rows.push(tv_rail(
                cx,
                format!("rail{r}").as_str(),
                art::RAIL_TITLES[r],
                ITEMS,
                move |i| {
                    tile_card(
                        &c2,
                        format!("tv{r}-{i}").as_str(),
                        &art::title_for(r, i),
                        p2[(i * 5 + r * 3) % p2.len()],
                        Action::from(format!("open{r}-{i}").as_str()),
                        Some(Action::from(format!("menu{r}-{i}").as_str())),
                    )
                },
            ));
        }
        Node::vstack(Align::Start, Some(tv::RAILS_SPACING / 2.0), rows)
            .padding(EdgeInsets {
                top: env.safe.top + 60.0,
                leading: 0.0,
                bottom: 0.0,
                trailing: 0.0,
            })
            .flex_frame(FlexFrame {
                max_w: Some(f32::INFINITY),
                max_h: Some(f32::INFINITY),
                align: Some(Alignment::TOP_LEADING),
                ..FlexFrame::default()
            })
            .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
    };
    Ui::new(view, (), env, cx)
}

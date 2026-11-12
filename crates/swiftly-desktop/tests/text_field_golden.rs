//! Frame goldens of the shared text field (caret, selection, preedit, placeholder, password) in three form factors, plus
//! blink, candidate-window and accessibility checks. PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites.

use std::path::PathBuf;
use swiftly_design::tokens::colour;
use swiftly_layout::{Alignment, EdgeInsets, Size};
use swiftly_render::{Color, RgbaImage};
use swiftly_text::{EditKey, MemoryClipboard, Mods, TextEditor, TextInputEvent as E, TextStyle};
use swiftly_ui::a11y::Role;
use swiftly_ui::components::color;
use swiftly_ui::field::{
    FieldLook, FieldState, FieldView, candidate_rect, caret_on, field_content,
};
use swiftly_ui::{Cx, Env, Idiom, Node, Ui};

// The goldens come from macOS; the software renderer rounds a little differently on other systems (seen: up to 10 levels).
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 2 } else { 12 };

struct Form {
    name: &'static str,
    size: (f32, f32),
    scale: f32,
    idiom: Idiom,
    font: f32,
    touch: bool,
}
const FORMS: [Form; 3] = [
    Form {
        name: "touch",
        size: (390.0, 120.0),
        scale: 3.0,
        idiom: Idiom::Phone,
        font: 15.0,
        touch: true,
    },
    Form {
        name: "desktop",
        size: (640.0, 120.0),
        scale: 2.0,
        idiom: Idiom::Desktop,
        font: 15.0,
        touch: false,
    },
    Form {
        name: "tv",
        size: (960.0, 160.0),
        scale: 1.0,
        idiom: Idiom::Tv,
        font: 30.0,
        touch: false,
    },
];

fn look(f: &Form) -> FieldLook {
    FieldLook {
        style: TextStyle::new(f.font, 400),
        text: color(colour::FONT),
        placeholder: color(colour::FONT_VERY_QUIET),
        caret: color(colour::MARK_ACCENT),
        selection: color(colour::MARK_ACCENT).with_alpha(0.30),
        caret_height: None,
    }
}

fn check(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "golden {name}: size"
    );
    let (max, _) = img.diff(&golden);
    assert!(max <= TOLERANCE, "golden {name} differs by {max}");
}

fn render(f: &Form, v: FieldView) -> RgbaImage {
    let l = look(f);
    let env = Env::new(Size::new(f.size.0, f.size.1), f.scale, f.idiom);
    let mut ui = Ui::new(
        move |p: &FieldView, _env: &Env, cx: &Cx| {
            field_content(cx, p, &l)
                .padding(EdgeInsets::symmetric(14.0, 24.0))
                .frame(None, Some(56.0), Alignment::LEADING)
                .background(Node::rect(color(colour::AREA), 10.0), Alignment::CENTER)
                .flex_frame(swiftly_layout::FlexFrame {
                    max_w: Some(f32::INFINITY),
                    align: Some(Alignment::LEADING),
                    ..swiftly_layout::FlexFrame::default()
                })
                .padding(EdgeInsets::symmetric(16.0, 20.0))
                .flex_frame(swiftly_layout::FlexFrame {
                    max_w: Some(f32::INFINITY),
                    max_h: Some(f32::INFINITY),
                    align: Some(Alignment::TOP_LEADING),
                    ..swiftly_layout::FlexFrame::default()
                })
                .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
        },
        v,
        env,
        Cx::deterministic(),
    );
    let list = ui.frame(0.0);
    ui.render(&list, Color::BLACK)
}

fn state(ed: TextEditor, evs: &[E], placeholder: &str, touch: bool) -> FieldView {
    let mut s = FieldState::new(ed);
    let mut clip = MemoryClipboard::default();
    s.set_focused(true, 0.0);
    for e in evs {
        let _ = s.apply(e, &mut clip, 0.0);
    }
    s.view(placeholder, touch, 0.0)
}

#[test]
fn field_states_in_three_forms() {
    for f in &FORMS {
        let single = TextEditor::single_line;
        let cases: Vec<(&str, FieldView)> = vec![
            (
                "placeholder",
                state(single(), &[], "Filme, Serien, Folgen", f.touch),
            ),
            (
                "caret",
                state(
                    single(),
                    &[
                        E::Text("Nordlicht".into()),
                        E::Key(EditKey::Left, Mods::NONE),
                    ],
                    "",
                    f.touch,
                ),
            ),
            (
                "selection",
                state(
                    single(),
                    &[
                        E::Text("Nordlicht Brücke".into()),
                        E::Key(EditKey::Left, Mods::SHIFT_WORD),
                    ],
                    "",
                    f.touch,
                ),
            ),
            (
                "preedit",
                state(
                    single(),
                    &[
                        E::Text("Anime ".into()),
                        E::Preedit {
                            text: "ni hao ma".into(),
                            cursor: Some((0, 2)),
                        },
                    ],
                    "",
                    f.touch,
                ),
            ),
            (
                "password",
                state(
                    single().password(),
                    &[E::Text("geheim123".into())],
                    "Passwort",
                    f.touch,
                ),
            ),
        ];
        for (n, v) in cases {
            check(&format!("textfield_{}_{n}", f.name), &render(f, v));
        }
    }
}

#[test]
fn caret_blinks_every_half_second_and_stays_solid_while_typing() {
    assert!(caret_on(0.0, 0.0) && caret_on(499.0, 0.0));
    assert!(!caret_on(500.0, 0.0) && !caret_on(999.0, 0.0));
    assert!(caret_on(1000.0, 0.0));
    let mut s = FieldState::new(TextEditor::single_line());
    let mut clip = MemoryClipboard::default();
    s.set_focused(true, 0.0);
    assert!(!s.view("", false, 600.0).caret_on);
    let _ = s.apply(&E::Text("a".into()), &mut clip, 600.0);
    assert!(
        s.view("", false, 700.0).caret_on,
        "typing restarts the blink"
    );
    assert!(!s.view("", false, 600.0 + 500.0).caret_on);
    s.set_focused(false, 2000.0);
    assert!(
        !s.view("", false, 2000.0).caret_on,
        "no caret without focus"
    );
}

#[test]
fn candidate_window_anchors_to_the_preedit_then_the_caret() {
    let cx = Cx::deterministic();
    let l = look(&FORMS[1]);
    let v = state(
        TextEditor::single_line(),
        &[
            E::Text("ab".into()),
            E::Preedit {
                text: "にほん".into(),
                cursor: None,
            },
        ],
        "",
        false,
    );
    let (x, _, w, h) = candidate_rect(&cx, &v, &l);
    assert!(x > 5.0 && w > 20.0 && h > 10.0, "{x} {w} {h}");
    let v2 = state(
        TextEditor::single_line(),
        &[E::Text("ab".into())],
        "",
        false,
    );
    let (x2, _, w2, _) = candidate_rect(&cx, &v2, &l);
    assert!((x2 - x).abs() < 1.0 && w2 < 3.0);
}

#[test]
fn accessibility_node_reports_role_value_and_selection() {
    let mut s = FieldState::new(TextEditor::single_line());
    let mut clip = MemoryClipboard::default();
    s.set_focused(true, 0.0);
    let _ = s.apply(&E::Text("Frieren".into()), &mut clip, 0.0);
    let _ = s.apply(&E::Key(EditKey::Left, Mods::SHIFT), &mut clip, 0.0);
    let n = s.a11y("field", "Suche", "Filme");
    assert_eq!(
        (
            n.role,
            n.value.as_deref(),
            n.selection.clone(),
            n.focused,
            n.editable
        ),
        (Role::TextField, Some("Frieren"), Some(6..7), true, true)
    );
    let mut p = FieldState::new(TextEditor::single_line().password());
    let _ = p.apply(&E::Text("abc".into()), &mut clip, 0.0);
    let n = p.a11y("pw", "Passwort", "");
    assert_eq!(
        (n.role, n.value.as_deref()),
        (Role::PasswordField, Some("\u{2022}\u{2022}\u{2022}"))
    );
}

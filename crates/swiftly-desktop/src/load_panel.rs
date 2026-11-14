//! The download sheet (`Shared/LoadSheet.swift`): three layers by what the rules say - the normal case (size, quality,
//! sound, space left, "Laden"), no Wi-Fi ("In die Warteschlange", "Jetzt über Mobilfunk laden") and not enough space
//! ("Gesehene entfernen und laden", "Abbrechen" / "Verstanden"). Drawn on the sheet card of `browse::sheet`.

use crate::browse::wide;
use crate::forms::{self, Fm};
use crate::home::{ins, text};
use swiftly_design::TextStyle;
use swiftly_design::tokens::{colour, touch};
use swiftly_downloads::DownloadRules;
use swiftly_layout::{Align, Alignment};
use swiftly_render::Color;
use swiftly_ui::components::color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Action, Cx, Env, Node, Paint};

/// What the sheet shows, as the download manager's rules answer it.
#[derive(Clone, Debug, PartialEq)]
pub struct LoadSpec {
    /// The title.
    pub title: String,
    /// Size of the file(s).
    pub bytes: i64,
    /// The file is streamed to disk: converted or one audio track (size is estimated, "≈"; `Item.streamed`).
    pub converted: bool,
    /// The server re-encodes the file (`Item.converted`).
    pub recomputed: bool,
    /// Removing the watched titles makes room (`SpaceInfo.suffices_to_clean_up`) and there are some.
    pub can_clean: bool,
    /// Quality and container line ("MKV"), if known.
    pub quality: Option<String>,
    /// The chosen sound track, if the file has more than one.
    pub sound: Option<String>,
    /// Free space on the device.
    pub free: i64,
    /// Free space after this download.
    pub free_after: i64,
    /// Watched titles that could go, in bytes (0 = none).
    pub dispensable: i64,
    /// Mobile data only (no Wi-Fi) and the user wants Wi-Fi only.
    pub no_wlan: bool,
}

impl LoadSpec {
    /// The demo values (a 2.4 GB film).
    pub fn demo(title: &str) -> LoadSpec {
        LoadSpec {
            title: title.into(),
            bytes: 2_400_000_000,
            converted: false,
            recomputed: false,
            can_clean: false,
            quality: Some("Original (MKV)".into()),
            sound: Some("Original".into()),
            free: 48_000_000_000,
            free_after: 45_600_000_000,
            dispensable: 0,
            no_wlan: false,
        }
    }
    fn suffices(&self) -> bool {
        self.free_after >= 0
    }
}

/// The sentence under "Laden" (`LoadPanel`, `MacDownloads.swift:230-236`).
fn hint_text(spec: &LoadSpec) -> &'static str {
    if spec.recomputed {
        "Der Server wandelt die Datei beim Laden um. Die Größe ist geschätzt, Untertitel kommen als eigene Dateien mit."
    } else if spec.converted {
        "Der Server legt die Datei beim Laden mit nur einer Tonspur an. Die Größe ist geschätzt, Untertitel kommen als eigene Dateien mit."
    } else {
        "Swiftly lädt die Originaldatei, in derselben Qualität wie beim Streamen."
    }
}

fn size(b: i64) -> String {
    DownloadRules::size(b, ",")
}

fn line(cx: &Cx, icons: &Icons, symbol: &str, was: &str, value: &str, cautionary: bool) -> Node {
    line_with(cx, icons, symbol, was, value, cautionary, false, "")
}

/// A line; `picker` draws the value as a menu button (caret) that reports `key`.
#[allow(clippy::too_many_arguments)]
fn line_with(
    cx: &Cx,
    icons: &Icons,
    symbol: &str,
    was: &str,
    value: &str,
    cautionary: bool,
    picker: bool,
    key: &str,
) -> Node {
    let c = if cautionary {
        colour::ORIGINAL_WARNING
    } else {
        colour::FONT
    };
    let t = |w: u16| TextStyle {
        size: 15.0,
        weight: w,
        tracking: 0.0,
        uppercase: false,
    };
    let row = Node::hstack(
        Align::Center,
        Some(14.0),
        vec![
            icons
                .node(symbol, 17.0, true, color(c))
                .frame(Some(20.0), None, Alignment::CENTER),
            text(cx, was, t(400), c, Some(1), swiftly_text::Align::Start),
            Node::spacer(),
            text(
                cx,
                value,
                t(if picker { 600 } else { 400 }),
                colour::FONT,
                Some(1),
                swiftly_text::Align::End,
            ),
            if picker {
                icons
                    .node("caret-down", 14.0, true, color(colour::FONT))
                    .frame(Some(16.0), None, Alignment::CENTER)
            } else {
                Node::fixed(0.0, 0.0)
            },
        ],
    )
    .padding(ins(13.0, touch::EDGE_SPACING, 13.0, touch::EDGE_SPACING))
    .frame(None, Some(52.0), Alignment::LEADING);
    let n = wide(row, Alignment::LEADING).overlay(
        Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::TOP),
        Alignment::TOP,
    );
    if picker {
        n.key(key).on_tap(Action::from(key))
    } else {
        n
    }
}

fn hint(cx: &Cx, s: &str) -> Node {
    wide(
        text(
            cx,
            s,
            TextStyle {
                size: 13.0,
                weight: 400,
                tracking: 0.0,
                uppercase: false,
            },
            colour::FONT_QUIET,
            None,
            swiftly_text::Align::Start,
        )
        .padding(ins(10.0, touch::EDGE_SPACING, 0.0, touch::EDGE_SPACING)),
        Alignment::LEADING,
    )
}

/// Keys the buttons report: `load.go`, `load.queue`, `load.cell`, `load.clean`, `load.close`; the pickers (`load.quality`, `load.sound`) report their keys.
pub fn load_sheet(cx: &Cx, icons: &Icons, env: &Env, spec: &LoadSpec) -> Node {
    let f: Fm = forms::fm(env);
    let btn = |key: &str, label: &str, filled: bool| {
        forms::button(cx, icons, &f, key, label, None, filled, false, true).padding(ins(
            14.0,
            touch::EDGE_SPACING,
            0.0,
            touch::EDGE_SPACING,
        ))
    };
    let sizes = format!(
        "{}{}",
        if spec.converted { "\u{2248} " } else { "" },
        size(spec.bytes)
    );
    let mut col: Vec<Node> = Vec::new();
    let head = |s: &str| {
        wide(
            text(
                cx,
                s,
                TextStyle {
                    size: 17.0,
                    weight: 600,
                    tracking: 0.0,
                    uppercase: false,
                },
                colour::FONT,
                Some(1),
                swiftly_text::Align::Start,
            )
            .padding(ins(4.0, touch::EDGE_SPACING, 14.0, touch::EDGE_SPACING)),
            Alignment::LEADING,
        )
    };
    if !spec.suffices() {
        col.push(head("Nicht genug Platz"));
        col.push(line(cx, icons, "hard-drive", "Diese Datei", &sizes, false));
        col.push(line(
            cx,
            icons,
            "hard-drive",
            "Frei auf dem Gerät",
            &size(spec.free),
            true,
        ));
        if spec.free_after + spec.dispensable >= 0 && spec.dispensable > 0 {
            col.push(line(
                cx,
                icons,
                "check-circle",
                "Gesehene Titel",
                &size(spec.dispensable),
                false,
            ));
            col.push(btn("load.clean", "Gesehene entfernen und laden", true));
            col.push(btn("load.close", "Abbrechen", false));
        } else {
            col.push(hint(cx, "Auch nach dem Entfernen der gesehenen Titel reicht der Platz nicht. In den Einstellungen unter Offline steht, was belegt ist."));
            col.push(btn("load.close", "Verstanden", false));
        }
    } else if spec.no_wlan {
        col.push(head(&format!("{} laden", spec.title)));
        col.push(line(cx, icons, "hard-drive", "Größe", &sizes, false));
        col.push(line(
            cx,
            icons,
            "wifi-slash",
            "Kein WLAN",
            "Mobilfunk",
            true,
        ));
        col.push(btn("load.queue", "In die Warteschlange", true));
        col.push(btn("load.cell", "Jetzt über Mobilfunk laden", false));
        col.push(hint(
            cx,
            "Der Download startet von selbst, sobald WLAN da ist.",
        ));
    } else {
        col.push(head(&format!("{} laden", spec.title)));
        col.push(line(cx, icons, "hard-drive", "Größe", &sizes, false));
        if let Some(q) = &spec.quality {
            col.push(line_with(
                cx,
                icons,
                "sparkle",
                "Qualität",
                q,
                false,
                true,
                "load.quality",
            ));
        }
        if let Some(a) = &spec.sound {
            col.push(line_with(
                cx,
                icons,
                "speaker-high",
                "Ton",
                a,
                false,
                true,
                "load.sound",
            ));
        }
        col.push(line(
            cx,
            icons,
            "hard-drive",
            "Danach frei",
            &size(spec.free_after),
            false,
        ));
        col.push(btn("load.go", "Laden", true));
        col.push(hint(cx, hint_text(spec)));
    }
    let handle = Node::rect(Color::new(1.0, 1.0, 1.0, 0.18), 2.5)
        .frame(Some(36.0), Some(5.0), Alignment::CENTER)
        .padding(ins(8.0, 0.0, 0.0, 0.0));
    let card_w = (f.form != crate::home::Form::Touch).then_some(600.0);
    let card = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![
            wide(handle, Alignment::TOP),
            Node::vstack(Align::Start, Some(0.0), col),
        ],
    )
    .padding(ins(0.0, 0.0, 24.0, 0.0));
    let card = wide(card, Alignment::TOP_LEADING)
        .frame(card_w, None, Alignment::TOP_LEADING)
        .background(
            Node::rect(color(colour::AREA), 28.0).paint(Paint::Stroke {
                color: color(colour::LINE),
                width: 1.0,
                radius: 28.0,
            }),
            Alignment::CENTER,
        )
        .on_tap_silent(Action::from("sheet.nop"));
    let colm = Node::vstack(Align::Center, Some(0.0), vec![Node::spacer(), card]);
    crate::home::fill_frame(colm, Alignment::BOTTOM)
        .background(
            Node::rect(Color::new(0.0, 0.0, 0.0, 0.55), 0.0),
            Alignment::CENTER,
        )
        .on_tap(Action::from("load.close"))
}

// ---- the Mac popover (`LoadPanel` in `Sources/macOS/MacDownloads.swift`) -------------------------------------------

/// A line of tabular figures.
pub(crate) fn mono(cx: &Cx, s: &str, size: f32, c: swiftly_design::Colour) -> Node {
    let style = swiftly_text::TextStyle::from(TextStyle {
        size,
        weight: 400,
        tracking: 0.0,
        uppercase: false,
    })
    .with_tabular();
    Node::text(cx, s, &style, color(c), Some(1), swiftly_text::Align::End)
}

pub(crate) fn plain(cx: &Cx, s: &str, size: f32, weight: u16, c: swiftly_design::Colour) -> Node {
    text(
        cx,
        s,
        TextStyle {
            size,
            weight,
            tracking: 0.0,
            uppercase: false,
        },
        c,
        Some(1),
        swiftly_text::Align::Start,
    )
}

/// A detail row: 20 wide icon, label, value in tabular figures (pad 14 / 9, spacing 10). `cautionary` paints it in the warning colour.
fn mac_detail(
    cx: &Cx,
    icons: &Icons,
    symbol: &str,
    was: &str,
    value: &str,
    cautionary: bool,
) -> Node {
    let c = if cautionary {
        colour::ORIGINAL_WARNING
    } else {
        colour::FONT
    };
    let icon_c = if cautionary {
        colour::ORIGINAL_WARNING
    } else {
        colour::FONT_QUIET
    };
    let row = Node::hstack(
        Align::Center,
        Some(10.0),
        vec![
            icons
                .node(symbol, 15.0, true, color(icon_c))
                .frame(Some(20.0), None, Alignment::CENTER)
                .a11y_hidden(),
            plain(cx, was, 15.0, 400, c),
            Node::spacer(),
            mono(cx, value, 15.0, colour::FONT_QUIET),
        ],
    );
    wide(row.padding(ins(9.0, 14.0, 9.0, 14.0)), Alignment::LEADING)
}

/// A choice row: the value on the right is a pill (`MacQualityBadge` / `MacAudioBadge`: accent text 12, accent 15 % fill,
/// corner 8, pad 10 / 4, a leading glyph and the up/down chevron), reporting `key`.
pub(crate) fn mac_pick(
    cx: &Cx,
    icons: &Icons,
    symbol: &str,
    was: &str,
    value: &str,
    key: &str,
) -> Node {
    let accent = color(colour::MARK_ACCENT);
    // Quality: a check for the original, the "smaller" arrow otherwise; sound: the speaker.
    let lead = if key.ends_with("sound") {
        "speaker-high"
    } else if value.starts_with("Original") {
        "check"
    } else {
        "arrow-down"
    };
    let badge = Node::hstack(
        Align::Center,
        Some(6.0),
        vec![
            icons.node(lead, 11.0, true, accent).a11y_hidden(),
            plain(cx, value, 12.0, 400, colour::MARK_ACCENT),
            icons.node("caret-down", 9.0, true, accent).a11y_hidden(),
        ],
    )
    .padding(ins(4.0, 10.0, 4.0, 10.0))
    .background(
        Node::rect(Color::new(accent.r, accent.g, accent.b, 0.15), 8.0),
        Alignment::CENTER,
    )
    .hover_surface(color(colour::HOVER_AREA), 8.0)
    .key(key)
    .on_tap(Action::from(key))
    .a11y(
        swiftly_ui::a11y::A11yNode::new("", swiftly_ui::a11y::Role::Button, was)
            .with_value(value.to_owned()),
    );
    let row = Node::hstack(
        Align::Center,
        Some(10.0),
        vec![
            icons
                .node(symbol, 15.0, true, color(colour::FONT_QUIET))
                .frame(Some(20.0), None, Alignment::CENTER)
                .a11y_hidden(),
            plain(cx, was, 15.0, 400, colour::FONT),
            Node::spacer(),
            badge,
        ],
    );
    wide(row.padding(ins(5.0, 14.0, 5.0, 14.0)), Alignment::LEADING)
}

/// The white 48 pt button with the arrow (`PrimaryButton(symbol: "arrow.down")`), as wide as the sheet allows.
pub(crate) fn sheet_button(
    cx: &Cx,
    icons: &Icons,
    f: &Fm,
    key: &str,
    label: &str,
    enabled: bool,
) -> Node {
    let inner = Node::hstack(
        Align::Center,
        Some(8.0),
        vec![
            icons
                .node("arrow-down", 15.0, true, color(colour::REASON))
                .a11y_hidden(),
            plain(cx, label, 17.0, 600, colour::REASON),
        ],
    );
    let n = wide(inner, Alignment::CENTER)
        .frame(None, Some(48.0), Alignment::CENTER)
        .background(Node::rect(color(colour::FONT), 10.0), Alignment::CENTER)
        .hover_surface(Color::new(0.0, 0.0, 0.0, 0.12), 10.0);
    let n = if enabled {
        forms::tappable(n, f, key, 10.0)
    } else {
        n.key(key)
            .disabled(true)
            .opacity(0.4, swiftly_ui::feel::hover())
    };
    n.a11y(swiftly_ui::a11y::A11yNode::new(
        "",
        swiftly_ui::a11y::Role::Button,
        label,
    ))
}

fn mac_hint(cx: &Cx, s: &str) -> Node {
    wide(
        text(
            cx,
            s,
            TextStyle {
                size: 12.0,
                weight: 400,
                tracking: 0.0,
                uppercase: false,
            },
            colour::FONT_QUIET,
            None,
            swiftly_text::Align::Start,
        )
        .padding(ins(0.0, 14.0, 12.0, 14.0)),
        Alignment::LEADING,
    )
}

/// The "Abbrechen" way out, always present (Esc reports the same through the screen's back).
fn mac_cancel(cx: &Cx, f: &Fm) -> Node {
    let n = wide(
        plain(cx, "Abbrechen", 15.0, 400, colour::FONT_QUIET),
        Alignment::CENTER,
    )
    .padding(ins(0.0, 0.0, 12.0, 0.0));
    // `Theme.PressButton`: scale 0.97 and opacity 0.85 (the default press style).
    forms::tappable(n, f, "load.close", 10.0)
}

/// The card of the sheets: raised, margin stroke 1, corner 16, no shadow; `w` wide.
pub(crate) fn raised_card(content: Node, w: f32, title: &str) -> Node {
    let form = Node::rect(color(colour::RAISED), 16.0).paint(Paint::Stroke {
        color: color(colour::MARGIN),
        width: 1.0,
        radius: 16.0,
    });
    wide(content, Alignment::TOP_LEADING)
        .frame(Some(w), None, Alignment::TOP_LEADING)
        .background(form, Alignment::CENTER)
        .on_tap_silent(Action::from("sheet.nop"))
        .a11y(swiftly_ui::a11y::A11yNode::new(
            "",
            swiftly_ui::a11y::Role::Dialog,
            title,
        ))
}

/// The add popover of the Mac: 320 wide, "{title} laden" or "Nicht genug Platz", rows Größe / Qualität / Ton / "Danach frei",
/// "Laden", "Abbrechen". `quality_pick` shows the quality as a choice (`load.quality`) and `sound_pick` the sound
/// (`load.sound`) instead of a fixed value; the page opens the menu under the button with these keys.
pub fn mac_load_panel(
    cx: &Cx,
    icons: &Icons,
    env: &Env,
    spec: &LoadSpec,
    quality_pick: bool,
    sound_pick: bool,
) -> Node {
    let f: Fm = forms::fm(env);
    let sizes = format!(
        "{}{}",
        if spec.converted { "\u{2248} " } else { "" },
        size(spec.bytes)
    );
    let mut col: Vec<Node> = Vec::new();
    let head = if spec.suffices() {
        format!("{} laden", spec.title)
    } else {
        "Nicht genug Platz".to_owned()
    };
    col.push(wide(
        plain(cx, &head, 15.0, 600, colour::FONT).padding(ins(12.0, 14.0, 10.0, 14.0)),
        Alignment::LEADING,
    ));
    col.push(wide(
        Node::rect(color(colour::MARGIN), 0.0).frame(None, Some(1.0), Alignment::CENTER),
        Alignment::CENTER,
    ));
    let quality = |col: &mut Vec<Node>| match (&spec.quality, quality_pick) {
        (Some(q), true) => col.push(mac_pick(
            cx,
            icons,
            "sparkle",
            "Qualit\u{00E4}t",
            q,
            "load.quality",
        )),
        (Some(q), false) => col.push(mac_detail(
            cx,
            icons,
            "sparkle",
            "Qualit\u{00E4}t",
            q,
            false,
        )),
        _ => {}
    };
    if !spec.suffices() {
        col.push(mac_detail(
            cx,
            icons,
            "hard-drive",
            "Diese Datei",
            &sizes,
            false,
        ));
        if quality_pick {
            quality(&mut col);
        }
        if let (Some(a), true) = (&spec.sound, sound_pick) {
            col.push(mac_pick(cx, icons, "speaker-high", "Ton", a, "load.sound"));
        }
        col.push(mac_detail(
            cx,
            icons,
            "hard-drive",
            "Frei auf diesem PC",
            &size(spec.free),
            true,
        ));
        if spec.can_clean {
            col.push(mac_detail(
                cx,
                icons,
                "check-circle",
                "Gesehene Titel",
                &size(spec.dispensable),
                false,
            ));
            col.push(
                sheet_button(
                    cx,
                    icons,
                    &f,
                    "load.clean",
                    "Gesehene entfernen und laden",
                    true,
                )
                .padding(ins(6.0, 14.0, 12.0, 14.0)),
            );
        } else {
            col.push(mac_hint(
                cx,
                "Auch nach dem Entfernen der gesehenen Titel reicht der Platz nicht.",
            ));
        }
    } else if spec.no_wlan {
        col.push(mac_detail(
            cx,
            icons,
            "hard-drive",
            "Gr\u{00F6}\u{00DF}e",
            &sizes,
            false,
        ));
        col.push(mac_detail(
            cx,
            icons,
            "wifi-slash",
            "Kein WLAN",
            "Mobilfunk",
            true,
        ));
        col.push(
            sheet_button(cx, icons, &f, "load.queue", "In die Warteschlange", true)
                .padding(ins(6.0, 14.0, 12.0, 14.0)),
        );
    } else {
        col.push(mac_detail(
            cx,
            icons,
            "hard-drive",
            "Gr\u{00F6}\u{00DF}e",
            &sizes,
            false,
        ));
        quality(&mut col);
        match (&spec.sound, sound_pick) {
            (Some(a), true) => {
                col.push(mac_pick(cx, icons, "speaker-high", "Ton", a, "load.sound"))
            }
            (Some(a), false) => col.push(mac_detail(cx, icons, "speaker-high", "Ton", a, false)),
            _ => {}
        }
        col.push(mac_detail(
            cx,
            icons,
            "hard-drive",
            "Danach frei",
            &size(spec.free_after),
            false,
        ));
        col.push(
            sheet_button(cx, icons, &f, "load.go", "Laden", true)
                .padding(ins(6.0, 14.0, 12.0, 14.0)),
        );
        col.push(mac_hint(cx, hint_text(spec)));
    }
    col.push(mac_cancel(cx, &f));
    raised_card(Node::vstack(Align::Start, Some(0.0), col), 320.0, &head)
}

/// The scrim behind a sheet: a dim layer that closes the sheet on a click, the card centred above it.
pub(crate) fn scrim(card: Node) -> Node {
    crate::home::fill_frame(card, Alignment::CENTER)
        .background(
            Node::rect(Color::new(0.0, 0.0, 0.0, 0.35), 0.0),
            Alignment::CENTER,
        )
        .on_tap(Action::from("load.close"))
}

/// The card of an anchored sheet: it grows out of the corner of the button that opened it (scale 0.94 and opacity,
/// `Leap`, the same way back) on a clear layer that closes the sheet on a click.
pub(crate) fn scrim_at(card: Node, at: swiftly_ui::popover::Placement, env: &Env) -> Node {
    let leap = swiftly_ui::feel::leap();
    let card = card
        .scaled(1.0, leap)
        .appear_from(swiftly_ui::feel::PANEL_EXPAND_SCALE, 0.0)
        .exit_to(swiftly_ui::feel::PANEL_EXPAND_SCALE, 0.0)
        .opacity(1.0, leap)
        .scale_about(at.pivot.0, at.pivot.1)
        .key("load-card")
        .padding(ins(at.rect.y, at.rect.x, 0.0, 0.0));
    let catcher = Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 0.0)
        .on_tap(Action::from("load.close"))
        .key("load-catcher");
    Node::zstack(Alignment::TOP_LEADING, vec![catcher, card])
        .frame(Some(env.size.w), Some(env.size.h), Alignment::TOP_LEADING)
        .key("load-anchored")
}

#[cfg(test)]
mod hint_tests {
    use super::*;

    #[test]
    fn the_hint_follows_the_mac_rule_recomputed_then_converted_then_original() {
        let mut spec = LoadSpec::demo("Film");
        assert!(hint_text(&spec).starts_with("Swiftly lädt die Originaldatei"));
        spec.converted = true;
        assert!(
            hint_text(&spec)
                .starts_with("Der Server legt die Datei beim Laden mit nur einer Tonspur an")
        );
        spec.recomputed = true;
        assert!(hint_text(&spec).starts_with("Der Server wandelt die Datei beim Laden um."));
    }
}

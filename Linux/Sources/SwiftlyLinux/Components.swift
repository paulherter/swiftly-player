import CGtk
import Foundation
import JellyfinKit

/// The Mac's building blocks, rebuilt in GTK with the same numbers.
///
/// **Rebuilt rather than shared.** `MacComponents.swift` is SwiftUI, none of which
/// is usable here. What is shared is the *number*: every size below lives in
/// `Theme` and comes from `Sources/macOS/Style.swift`. Changing one here without
/// changing it there lets the platforms drift apart.
///
/// **Symbols are where this does not line up.** Apple draws SF Symbols, which do
/// not exist on Linux and may not be bundled. The closest icon from the Adwaita
/// set is used instead; each use below notes which one stands for what.

// MARK: - Input field

/// A field like `Eingabezeile` on the Mac: icon on the left, 38 high, corner 10,
/// hairline in white 12%, accent on focus. Sizes are in the stylesheet.
///
/// **`stretches` says whether the field fills its column.** On the Mac `Eingabezeile`
/// has no width of its own (`macOS/RootView.swift:159-193`); it comes from the
/// surrounding block: 360 on the sign-in screen, 460 on form pages. A fixed 360
/// with `ALIGN_CENTER` would leave a narrow strip floating in the middle of a
/// 460-point column.
func inputRow(symbol: String, placeholder: String, secret: Bool = false,
                  stretches: Bool = false) -> Widget! {
    let inputField: Widget! = gtk_entry_new()
    gtk_entry_set_placeholder_text(asField(inputField), placeholder)
    gtk_entry_set_icon_from_icon_name(asField(inputField), GTK_ENTRY_ICON_PRIMARY, symbol)
    // The icon should not look clickable; it is a label, not a button.
    gtk_entry_set_icon_activatable(asField(inputField), GTK_ENTRY_ICON_PRIMARY, 0)
    if secret { gtk_entry_set_visibility(asField(inputField), 0) }
    gtk_widget_set_size_request(inputField, stretches ? -1 : Int32(Theme.loginWidth),
                                Int32(Theme.fieldHeight))
    gtk_widget_set_hexpand(inputField, stretches ? 1 : 0)
    gtk_widget_set_halign(inputField, stretches ? GTK_ALIGN_FILL : GTK_ALIGN_CENTER)
    return inputField
}

// MARK: - Primary button

/// White with dark text, 48 high, icon and text 9 apart.
///
/// **Not in the accent colour.** On the Mac the primary button is `Theme.font` on
/// `Theme.reason`; the accent is used only for selection.
///
/// The width is that of the sign-in block. On the Mac the button currently
/// stretches across the whole window; here the width is right from the start.
func primaryButton(_ text: String, symbol: String = "go-next-symbolic") -> Widget! {
    let button: Widget! = gtk_button_new()
    gtk_widget_add_css_class(button, "swiftly-haupt")
    let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 9)
    gtk_widget_set_halign(rail, GTK_ALIGN_CENTER)
    append(rail, gtk_image_new_from_icon_name(symbol))
    append(rail, label(text))
    gtk_button_set_child(asButton(button), rail)
    gtk_widget_set_size_request(button, Int32(Theme.loginWidth), Int32(Theme.primaryButtonHeight))
    gtk_widget_set_hexpand(button, 0)
    gtk_widget_set_halign(button, GTK_ALIGN_CENTER)
    return button
}

/// Sets a primary button's label **afterwards** without losing its icon.
///
/// `gtk_button_set_label` replaces the whole child with a plain label, which would
/// drop the play arrow. The button holds a box of icon and text; only the text is
/// set here.
/// `symbol` additionally sets the icon in front: the player button alternates
/// between "skip intro" and "next episode", and the two carry **different**
/// icons: one continues within the same episode, the other leaves it. The same
/// icon for both would blur the difference, and it is the one that cannot be
/// undone after the press (`ButtonOffering.zeichen`).
func primaryButtonLabel(_ button: Widget!, _ text: String, symbol: String? = nil) {
    guard let rail = gtk_widget_get_first_child(button),
          let l = gtk_widget_get_last_child(rail) else { return }
    gtk_label_set_text(OpaquePointer(l), text)
    if let symbol, let image = gtk_widget_get_first_child(rail), image != l {
        gtk_image_set_from_icon_name(OpaquePointer(image), symbol)
    }
}

// MARK: - Sidebar

/// A sidebar row: icon (17 wide), 10 gap, label. 32 high, corner 6. When active
/// it uses the accent at 10% fill.
func sidebarRow(symbol: String, text: String, active: Bool) -> Widget! {
    let button: Widget! = gtk_button_new()
    gtk_widget_add_css_class(button, "swiftly-zeile")
    if active { gtk_widget_add_css_class(button, "swiftly-aktiv") }
    let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    let image: Widget! = gtk_image_new_from_icon_name(symbol)
    append(rail, image)
    let font = label(text)
    gtk_widget_set_hexpand(font, 1)
    gtk_label_set_xalign(OpaquePointer(font), 0)
    append(rail, font)
    gtk_button_set_child(asButton(button), rail)
    return button
}

/// "BIBLIOTHEKEN": 11 semibold, letter-spaced, very quiet, uppercase.
///
/// The caller uppercases, not the stylesheet: GTK CSS has no `text-transform`.
func category(_ text: String) -> Widget! {
    // **No more uppercase**: letter-spacing applies only to text in capitals, and
    // those are gone.
    let l = label(text, style: "swiftly-rubrik")
    gtk_widget_add_css_class(l, "swiftly-leise")
    gtk_label_set_xalign(OpaquePointer(l), 0)
    gtk_widget_set_margin_start(l, 10)
    gtk_widget_set_margin_end(l, 10)
    return l
}

/// The hairline above the profile row.
func divider() -> Widget! {
    let l: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(l, "swiftly-trennlinie")
    gtk_widget_set_size_request(l, -1, 1)
    return l
}

/// A horizontal spacer; pushes the sort chips to the right.
func paddingLandscape() -> Widget! {
    let l: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_set_hexpand(l, 1)
    return l
}

/// A vertical spacer. GTK has no `Spacer`, but an empty box with `vexpand` does
/// the same.
func padding() -> Widget! {
    let l: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_set_vexpand(l, 1)
    return l
}

// MARK: - Image cage

/// **A `GtkPicture` grows to the size of its image.** The cage keeps it at the
/// given size.
///
/// Same trap as with the wordmark: `gtk_widget_set_size_request` only sets a
/// **minimum** size. A 300-point image requests 300 and gets it whenever space
/// allows; tiles ended up twice as large and the profile image stretched the
/// sidebar from 220 to over 700. `hexpand = 0` does not help: it distributes spare
/// space, it does not limit a requested size.
///
/// **A `GtkScrolledWindow` was tried first** because it does not propagate its
/// child's natural size upward. It works, but brings scrollbars, which logged
/// `slider reported min width -2` because they do not fit in a 26-point tile.
///
/// `GtkOverlay` does the same without extras: it **measures only its main child**.
/// That is an empty box of the desired size; the image is an overlay on top, is not
/// measured, and still gets the full area.
///
/// Rounding belongs on the wrapper, not the image: on the Mac `ImageArea` is a
/// `ZStack` of background, image *and* progress bar, and only the whole stack gets
/// `clipShape`. That keeps the bar **inside** the rounding and scales it on hover.
///
/// The return type deliberately has no `!`: Swift forbids an implicitly unwrapped
/// optional in a tuple element. Neither is ever nil here.
func framedImage(width: Int, height: Int, style: String) -> (wrapper: Widget, image: Widget) {
    let wrapper: Widget! = gtk_overlay_new()
    gtk_widget_add_css_class(wrapper, style)
    gtk_widget_set_overflow(wrapper, GTK_OVERFLOW_HIDDEN)
    gtk_widget_set_hexpand(wrapper, 0)
    gtk_widget_set_vexpand(wrapper, 0)

    // An empty box sets the size. It is the main child, hence the only one measured.
    let mass: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_set_size_request(mass, Int32(width), Int32(height))
    gtk_overlay_set_child(OpaquePointer(wrapper), mass)

    let image: Widget! = gtk_picture_new()
    gtk_picture_set_content_fit(OpaquePointer(image), GTK_CONTENT_FIT_COVER)
    gtk_picture_set_can_shrink(OpaquePointer(image), 1)
    gtk_overlay_add_overlay(OpaquePointer(wrapper), image)
    return (wrapper!, image!)
}

/// A round profile badge: gradient, the image on top, and **instead of** the image
/// the first letter of the name if none arrives.
///
/// **The letter is a fallback, not a base layer.** Identical to `ProfileCharacter` in
/// `Sources/Shared/Components.swift`: if it always lay underneath, it would flash
/// through for every account *with* an image until the image loads. It becomes
/// visible only when ``imageLoad`` reports that nothing arrived, via its `fertig`
/// callback.
///
/// The gradient is set on the passed class in the stylesheet; it always shows and
/// is not noticed when an image covers it.
func profileCharacter(name: String, border: Int, style: String,
                   fontStyle: String) -> (wrapper: Widget, image: Widget, symbolText: Widget) {
    let (wrapper, image) = framedImage(width: border, height: border, style: style)
    let symbolText = label(String(name.prefix(1)).uppercased(), style: fontStyle)
    gtk_widget_set_halign(symbolText, GTK_ALIGN_CENTER)
    gtk_widget_set_valign(symbolText, GTK_ALIGN_CENTER)
    gtk_widget_set_visible(symbolText, 0)
    gtk_overlay_add_overlay(OpaquePointer(wrapper), symbolText)
    return (wrapper, image, symbolText!)
}

/// Loads the profile image and shows the letter if none arrives.
///
/// Without an address the letter shows immediately, since it is already clear
/// that nothing will arrive.
func profileImageLoad(_ parts: (wrapper: Widget, image: Widget, symbolText: Widget),
                     url: URL?, key: String) {
    guard let url else {
        gtk_widget_set_visible(parts.symbolText, 1)
        return
    }
    let container = PointerBox(parts.symbolText)
    // Only the image is retained; the letter next to it may already be gone with its
    // page when the response arrives.
    let lives = LifeCharacter(parts.symbolText)
    imageLoad(parts.image, url: url, key: key, immediate: true) { came in
        guard !came, lives.lives else { return }
        gtk_widget_set_visible(container.widget, 1)
    }
}

/// Places the progress bar at the bottom **inside** the image wrapper.
///
/// Two layers as on the Mac: a track in white 16% across the full width and on it
/// the accent, as wide as the watched fraction. 4 points high, like `ImageArea`
/// on the Mac and the iPhone ("4, not 3"); at three it disappeared under a still
/// in the episode list. GTK has no fractional width, but the tile has a fixed
/// width, so it can be computed.
/// Returns track and bar so a caller can remove them again.
@discardableResult
func barPut(_ wrapper: Widget!, width: Int, share: Double) -> [Widget?] {
    CheckCounter.stripe += 1
    let track: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(track, "swiftly-balkenspur")
    gtk_widget_set_size_request(track, -1, 4)
    gtk_widget_set_valign(track, GTK_ALIGN_END)
    gtk_widget_set_halign(track, GTK_ALIGN_FILL)
    gtk_overlay_add_overlay(OpaquePointer(wrapper), track)

    let stripe: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(stripe, "swiftly-balken")
    gtk_widget_set_size_request(stripe, Int32(Double(width) * min(max(share, 0), 1)), 4)
    gtk_widget_set_valign(stripe, GTK_ALIGN_END)
    gtk_widget_set_halign(stripe, GTK_ALIGN_START)
    gtk_overlay_add_overlay(OpaquePointer(wrapper), stripe)
    return [track, stripe]
}

/// **A symbol instead of emptiness when the server has no image.**
///
/// The rule is in `Sources/Shared/HomeView.swift`, with its rationale: an empty
/// area looks like an app bug, whereas a symbol says an image belongs here and the
/// server has none.
///
/// Television for anything with a series behind it, film strip for the rest; 22
/// large, very quiet. The Mac does **not** do this and leaves the area empty. That
/// is a gap there, not a deviation here.
func characterPut(_ wrapper: Widget!, series: Bool) {
    let symbolText: Widget! = gtk_image_new_from_icon_name(
        series ? "tv-symbolic" : "video-x-generic-symbolic")
    gtk_image_set_pixel_size(OpaquePointer(symbolText), 22)
    gtk_widget_add_css_class(symbolText, "swiftly-leise")
    gtk_widget_set_halign(symbolText, GTK_ALIGN_CENTER)
    gtk_widget_set_valign(symbolText, GTK_ALIGN_CENTER)
    gtk_overlay_add_overlay(OpaquePointer(wrapper), symbolText)
}

/// **Exactly this size, no more.**
///
/// `gtk_widget_set_size_request` is a minimum; a child may grow beyond it, and
/// labels do: Inter is taller than SF Pro, so every row of the hero block became a
/// few points taller than its slot on the Mac, and the gaps between them grew too.
///
/// A `GtkOverlay` measures **only its main child**. If that is an empty box of the
/// desired size, the slot is fixed; the content sits on top as an overlay and is
/// not measured. Same technique as the image cage, applied to text.
func compartment(_ kind: Widget!, width: Int, height: Int,
          verticalRight: GtkAlign = GTK_ALIGN_CENTER) -> Widget! {
    let wrapper: Widget! = gtk_overlay_new()
    let mass: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_set_size_request(mass, Int32(width), Int32(height))
    gtk_overlay_set_child(OpaquePointer(wrapper), mass)
    gtk_widget_set_valign(kind, verticalRight)
    gtk_widget_set_halign(kind, GTK_ALIGN_FILL)
    gtk_overlay_add_overlay(OpaquePointer(wrapper), kind)
    gtk_widget_set_overflow(wrapper, GTK_OVERFLOW_HIDDEN)
    return wrapper
}

// MARK: - Chip

/// Filter and sort chip. Active it is white with dark text, otherwise quiet with a
/// hairline around it: 28 high, 12 side padding, fully rounded.
///
/// The semibold text when active matches the Mac and is deliberate: the chip gets
/// slightly wider, which is the only cue to the selection that works without colour.
/// - Parameter zeichnung: A custom-drawn icon instead of a name from the icon
///   set, for cases where Adwaita has nothing suitable (see ``Reglerzeichen``).
///   Takes precedence over `symbol`.
func chip(_ text: String, symbol: String? = nil, active: Bool = false,
          onlySymbol: Bool = false, drawing: Widget? = nil) -> Widget! {
    let button: Widget! = gtk_button_new()
    gtk_widget_add_css_class(button, "swiftly-chip")
    if active { gtk_widget_add_css_class(button, "swiftly-aktiv") }
    gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
    // Icon and word 6 apart, the Mac's measurements (`Chip`).
    let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    // **Otherwise the content sticks to the left edge.**
    //
    // A button stretches its child to full width, so the row becomes as wide as the
    // button and the image in it sits at the start, not the middle. With a word it
    // goes unnoticed because the content fills the width anyway; with an icon alone
    // it visibly sat left instead of centred.
    gtk_widget_set_halign(rail, GTK_ALIGN_CENTER)
    if let drawing {
        append(rail, drawing)
    } else if let symbol {
        let image: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(image), 12)
        append(rail, image)
    }
    // **Icon only, but still inside its capsule.**
    //
    // In the player toolbar the icon says enough; a label next to it widens the bar
    // without explaining anything. The frame stays: a bare icon over moving video
    // looks like it floats there by accident. Same change as the Mac version.
    //
    // The label is not lost: it becomes the tooltip and what a screen reader
    // announces.
    if onlySymbol {
        gtk_widget_add_css_class(button, "swiftly-nursymbol")
        gtk_widget_set_tooltip_text(button, text)
        caption(button, text)
    } else {
        append(rail, label(text))
    }
    gtk_button_set_child(asButton(button), rail)
    return button
}

// MARK: - Side button, badge, tab

/// Side button of the button row: rounded square, **icon only**, 48 × 48.
///
/// The TV deliberately avoids labels, since the watchlist icon alone is enough
/// to convey the watchlist. Active it is white with dark text, otherwise white
/// 14% (hovered 22%).
func secondaryButton(_ symbol: String, name: String? = nil, active: Bool = false,
                drawing: Widget? = nil) -> Widget! {
    let button: Widget! = gtk_button_new()
    // Without a name, a button without a label is just "button" to a screen reader.
    // On the Mac this is `accessibilityLabel`.
    if let name { caption(button, name) }
    gtk_widget_add_css_class(button, "swiftly-neben")
    if active { gtk_widget_add_css_class(button, "swiftly-aktiv") }
    if let drawing {
        gtk_button_set_child(asButton(button), drawing)
    } else {
        let image: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(image), 17)
        gtk_button_set_child(asButton(button), image)
    }
    gtk_widget_set_size_request(button, Int32(Theme.primaryButtonHeight),
                                Int32(Theme.primaryButtonHeight))
    return button
}

/// Toggles a side button. **The button's state is the answer**; there is no
/// confirmation prompt and no message.
func buttonState(_ button: Widget!, active: Bool, symbol: String) {
    if active { gtk_widget_add_css_class(button, "swiftly-aktiv") }
    else { gtk_widget_remove_css_class(button, "swiftly-aktiv") }
    help(button, checkmark: active ? .an : .off)
    let image: Widget! = gtk_image_new_from_icon_name(symbol)
    gtk_image_set_pixel_size(OpaquePointer(image), 17)
    gtk_button_set_child(asButton(button), image)
}

/// The release badge: 10 semibold, 5 × 2 padding, corner 3, hairline.
func badge(_ text: String) -> Widget! {
    let l = label(text, style: "swiftly-plakette")
    gtk_widget_set_valign(l, GTK_ALIGN_CENTER)
    return l
}

/// A tab: 15, active semibold with a 2-point accent line underneath. The
/// hairline beneath runs the full width and is drawn by the caller, not the button.
func tabButton(_ text: String, active: Bool) -> Widget! {
    let button: Widget! = gtk_button_new()
    gtk_widget_add_css_class(button, "swiftly-reiter")
    if active { gtk_widget_add_css_class(button, "swiftly-aktiv") }
    help(button, selected: active)
    let smallStack = stack(GTK_ORIENTATION_VERTICAL, spacing: 8)
    append(smallStack, label(text))
    let stroke: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(stroke, "swiftly-reiterstrich")
    gtk_widget_set_size_request(stroke, -1, 2)
    append(smallStack, stroke)
    gtk_button_set_child(asButton(button), smallStack)
    return button
}

// MARK: - Settings rows

/// A group of rows as a card, filled in `Theme.area` with `eckeFlaeche`
/// (`macOS/SettingRows.swift:30`), like every row group on the Mac.
/// Rows lying bare on the page background would make each settings page look
/// different from the Mac, and groups without a heading would not look like
/// groups at all.
func rowsGroup() -> (outer: Widget, space: Widget) {
    let outer = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
    gtk_widget_add_css_class(outer, "swiftly-karte")
    let space = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
    append(outer, space)
    return (outer!, space!)
}

/// A group with a heading above it: "QUALITÄT", "SPRACHE", "VERHALTEN".
func settingGroup(_ title: String) -> (outer: Widget, space: Widget) {
    let outer = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let header = category(title)
    // **Not the same heading style as in the sidebar**; see `swiftly-gruppenrubrik`
    // in the stylesheet.
    gtk_widget_remove_css_class(header, "swiftly-leise")
    gtk_widget_add_css_class(header, "swiftly-gruppenrubrik")
    gtk_widget_set_margin_start(header, 0)
    gtk_widget_set_margin_top(header, 26)
    gtk_widget_set_margin_bottom(header, 10)
    append(outer, header)
    let group = rowsGroup()
    append(outer, group.outer)
    return (outer!, group.space)
}

/// The divider **inside** a group, indented by 48 so it starts under the icon and
/// not before it.
func rowsLine() -> Widget! {
    // **46, computed from the icon column** (`Theme.separatorInsetCard`): 12 margin +
    // 20 icon + 14 gap.
    let l = divider()
    gtk_widget_set_margin_start(l, 46)
    return l
}

/// The body of every row: icon (22 wide), 14 gap, title, subtitle, something on the
/// right. At least 44 high, 12 side padding.
func rowBody(symbol: String, title: String, under: String?,
                         accent: Bool, right: Widget?) -> Widget! {
    // **"14 + content + 14" as padding, not a fixed height**: a minimum height does
    // not include the content, and a row with a subtitle would have no room. The
    // measure is in the stylesheet (`padding: 14px 12px`); icon column 20 rather than 22.
    let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
    let image: Widget! = gtk_image_new_from_icon_name(symbol)
    gtk_image_set_pixel_size(OpaquePointer(image), 15)
    gtk_widget_set_size_request(image, 20, -1)
    append(rail, image)

    let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
    gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
    gtk_widget_set_hexpand(text, 1)
    // Title 15 semibold (`listTitle`), subtitle 12 `schriftSehrLeise`.
    let t = label(title, style: "swiftly-listentitel")
    gtk_label_set_xalign(OpaquePointer(t), 0)
    gtk_label_set_ellipsize(OpaquePointer(t), PANGO_ELLIPSIZE_END)
    append(text, t)
    if let under {
        let u = label(under, style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(u, "swiftly-fuss")
        gtk_label_set_xalign(OpaquePointer(u), 0)
        // **The subtitle may truncate.** Otherwise the longest sentence sets the natural
        // width of the whole column: "Download titles to this computer and watch without
        // a connection" once pushed the settings page past the window edge and left the
        // right column outside.
        gtk_label_set_ellipsize(OpaquePointer(u), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(u), 34)
        append(text, u)
    }
    append(rail, text)
    if let right { append(rail, right) }
    if accent { gtk_widget_add_css_class(rail, "swiftly-akzentzeile") }
    return rail
}

/// A row with a value on the right and an optional arrow.
func valuesRow(symbol: String, title: String, under: String? = nil,
                value: String? = nil, accent: Bool = false, arrow: Bool = false,
                checkmark: Bool = false, pick: (() -> Void)? = nil) -> Widget! {
    let right = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    gtk_widget_set_valign(right, GTK_ALIGN_CENTER)
    if let value, !value.isEmpty {
        // Value 15 in `schriftLeise`.
        let w = label(value, style: "swiftly-koerper")
        gtk_widget_add_css_class(w, "dim-label")
        append(right, w)
    }
    // Checkmark instead of arrow, for a choice among several; see the genre form in
    // `SettingsPages.swift`.
    if checkmark {
        let h: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(h), 15)
        gtk_widget_add_css_class(h, "swiftly-akzentzeile")
        append(right, h)
    }
    if arrow {
        // Chevron 13 in `schriftSehrLeise`.
        let p: Widget! = gtk_image_new_from_icon_name("go-next-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(p), 13)
        gtk_widget_add_css_class(p, "swiftly-leise")
        append(right, p)
    }
    let shell = rowBody(symbol: symbol, title: title, under: under,
                            accent: accent, right: right)
    guard let pick else {
        gtk_widget_add_css_class(shell, "swiftly-zeilenrumpf")
        return shell
    }
    let button: Widget! = gtk_button_new()
    gtk_widget_add_css_class(button, "swiftly-einstellzeile")
    gtk_button_set_child(asButton(button), shell)
    signal(button, "clicked", pick)
    return button
}

/// A row with a switch. **Not a `GtkSwitch`**, which brings the system's capsule
/// shape, colour and measurements.
func toggleRow(symbol: String, title: String, under: String? = nil,
                   an: Bool, toggled: @escaping (Bool) -> Void) -> Widget! {
    var condition = an
    let toggle: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(toggle, "swiftly-schalter")
    // **38 × 22 with a 16 knob.** The 46 × 28 variant came from
    // `Sources/Shared/Style.swift`, the iPhone stylesheet, where the switch is sized for
    // fingers. The Mac has its own `Schalter`
    // (`Sources/macOS/SettingRows.swift:128-143`), deliberately smaller; its file
    // header says rows are 44 rather than 52 high and only pointer-related things differ.
    gtk_widget_set_size_request(toggle, 38, 22)
    gtk_widget_set_valign(toggle, GTK_ALIGN_CENTER)
    let knob: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(knob, "swiftly-knauf")
    gtk_widget_set_size_request(knob, 16, 16)
    gtk_widget_set_valign(knob, GTK_ALIGN_CENTER)
    // Always on the left; the position comes from `margin-left` in the stylesheet so it
    // can animate (a different `halign` jumps, GTK does not animate it).
    gtk_widget_set_halign(knob, GTK_ALIGN_START)
    append(toggle, knob)

    func paint() {
        if condition {
            gtk_widget_add_css_class(toggle, "swiftly-aktiv")
                    } else {
            gtk_widget_remove_css_class(toggle, "swiftly-aktiv")
                    }
    }
    paint()

    let button: Widget! = gtk_button_new()
    gtk_widget_add_css_class(button, "swiftly-einstellzeile")
    gtk_button_set_child(asButton(button),
                         rowBody(symbol: symbol, title: title, under: under,
                                     accent: false, right: toggle))
    // A switch without state is only a button to assistive technology.
    help(button, name: title, checkmark: condition ? .an : .off)
    signal(button, "clicked") {
        condition.toggle()
        paint()
        help(button, checkmark: condition ? .an : .off)
        toggled(condition)
    }
    return button
}

/// The value list. On the iPhone it is a sheet from the bottom; here it opens
/// **below the row**, keeping the choice in place, the same rule as the season
/// pill.
func valueList<W: Equatable>(_ entries: [(String, W)], selected: W,
                              select: @escaping (W) -> Void) -> Widget! {
    let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
    gtk_widget_add_css_class(list, "swiftly-werteliste")
    for (name, value) in entries {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-wertzeile")
        if value == selected { gtk_widget_add_css_class(button, "swiftly-aktiv") }
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let l = label(name, style: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        append(rail, l)
        if value == selected {
            let checkmark: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(checkmark), 14)
            append(rail, checkmark)
        }
        gtk_button_set_child(asButton(button), rail)
        help(button, selected: value == selected)
        signal(button, "clicked") { select(value) }
        append(list, button)
    }
    return list
}

/// Vertical space of fixed height.
func paddingHigh(_ height: Int32) -> Widget! {
    let l: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_set_size_request(l, -1, height)
    return l
}


// MARK: - What must survive a reload

/// **Between the start of a task and its response, the page may have been rebuilt.**
/// The pointer the task holds is then long freed, and writing to it touches foreign
/// memory.
///
/// This crashed the app in libgtk with no line of our own in the stack: the detail
/// page shows the sparse list entry at once and rebuilds when the full data
/// arrives. Anyone who fetched the plan in between wrote it into a row that no
/// longer existed.
///
/// ``imageLoad`` has always retained the image field for this reason. Anything else
/// that fills in later must do the same; written down here once.
func held(_ w: Widget!) -> PointerBox {
    g_object_ref(w)
    return PointerBox(w)
}

func letGo(_ container: PointerBox) {
    g_object_unref(container.widget)
}

/// Holds a widget as long as the wrapper lives, for tasks that may never run and
/// are then simply discarded. Main thread only.
final class Retained {
    let widget: Widget!
    init(_ widget: Widget!) { self.widget = widget; g_object_ref(widget) }
    deinit { g_object_unref(widget) }
}


/// **A placeholder shaped like what is coming.**
///
/// Instead of a spinner that only says "wait". The page is then empty rather than
/// waiting, and nothing changes shape when the data arrives.
func loadField(width: Int, height: Int, narrow: Bool = false) -> Widget! {
    let inputField: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(inputField, "swiftly-ladefeld")
    if narrow { gtk_widget_add_css_class(inputField, "swiftly-schmal") }
    gtk_widget_set_size_request(inputField, Int32(width), Int32(height))
    gtk_widget_set_halign(inputField, GTK_ALIGN_START)
    gtk_widget_set_valign(inputField, GTK_ALIGN_START)
    return inputField
}

/// A grid of poster placeholders, for tabs that fill a grid.
func gridPlaceholder(count: Int = 8, margin: Int) -> Widget! {
    let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: Int32(Theme.tileSpacing))
    gtk_widget_set_margin_start(rail, Int32(margin))
    gtk_widget_set_margin_end(rail, Int32(margin))
    for _ in 0 ..< count {
        append(rail, loadField(width: Theme.tileWidth, height: Theme.tileHeight))
    }
    // **Clipped, not wider than the page.** Eight tiles are wider than the window;
    // without the wrapper the page grew with them for a moment and the header image
    // shifted right on the first "Similar".
    let wrapper: Widget! = gtk_scrolled_window_new()
    gtk_scrolled_window_set_policy(OpaquePointer(wrapper), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
    gtk_scrolled_window_set_child(OpaquePointer(wrapper), rail)
    return wrapper
}


/// Two placeholder rows: heading and tiles in their final shape.
///
/// For the home page on the very first load. Afterwards what exists stays and is
/// replaced once the new rows arrive.
func railsPlaceholder(margin: Int) -> Widget! {
    let block = stack(GTK_ORIENTATION_VERTICAL, spacing: Int32(Theme.railsSpacing))
    for i in 0 ..< 2 {
        let rail = stack(GTK_ORIENTATION_VERTICAL, spacing: 14)
        let header = loadField(width: i == 0 ? 190 : 150, height: 20, narrow: true)
        gtk_widget_set_margin_start(header, Int32(margin))
        append(rail, header)
        let landscape = i == 0
        let tiles = stack(GTK_ORIENTATION_HORIZONTAL, spacing: Int32(Theme.tileSpacing))
        gtk_widget_set_margin_start(tiles, Int32(margin))
        gtk_widget_set_margin_end(tiles, Int32(margin))
        for _ in 0 ..< (landscape ? 4 : 6) {
            append(tiles, loadField(width: landscape ? Theme.landscapeWidth : Theme.tileWidth,
                                        height: landscape ? Theme.landscapeHeight : Theme.tileHeight))
        }
        append(rail, tiles)
        append(block, rail)
    }
    return block
}


/// **Progress in words**, for assistive technology, which cannot see the bar and
/// checkmark. Only from one percent, as on Apple (`HomeView.swift`,
/// `TVComponents.swift`): "zero percent watched" is no information.
func watchStateWord(watched: Bool, share: Double?) -> String? {
    if watched { return translated("Gesehen") }
    guard let share, share >= 0.01 else { return nil }
    return String(format: translated("%lld Prozent gesehen"), Int(share * 100))
}

/// **One statement per tile instead of three fragments**, like
/// `.accessibilityElement(children: .ignore)` on Apple. Title first, then year or
/// second line; for an episode the spelled-out position instead of "S1 • E3", and
/// last how far it is watched.
func tileName(_ item: Item, top: String, bottom: String?) -> String {
    var parts = [top]
    if item.type == "Episode", let season = item.parentIndexNumber, let episode = item.indexNumber {
        parts.append(String(format: translated("Staffel %lld · Folge %lld"), season, episode))
    } else if let bottom, !bottom.isEmpty {
        parts.append(bottom)
    }
    if let word = watchStateWord(watched: item.isWatched, share: item.watchedShare) {
        parts.append(word)
    }
    return parts.joined(separator: ", ")
}

/// **The badge on a tile**: checkmark, open episodes or seasons.
///
/// Which one applies is decided by
/// ``Anzeigeregeln/kachelmarke(art:staffeln:gesehen:offeneFolgen:)`` in the package:
/// watched beats everything, open episodes beat the season count, an unwatched
/// movie gets nothing (a number that is always one is no information). The
/// **wording** lives here because it depends on the string catalog.
func tileMarkPut(_ wrapper: Widget!, item: Item) {
    guard let mark = DisplayRules.tileMark(art: item.type,
                                                seasons: item.childCount,
                                                watched: item.userData?.played,
                                                openEpisodes: item.userData?.unplayedItemCount)
    else { return }

    let inputField: Widget!
    switch mark {
    case .watched:
        inputField = gtk_image_new_from_icon_name("object-select-symbolic")
    case .opened(let n):
        // **"6 offen", not "6".** A bare number on a tile does not say what it counts;
        // the Mac uses the same wording (`Sources/macOS/MacComponents.swift:531`,
        // `wortlaut`).
        inputField = label(String(format: translated("%lld offen"), n))
    case .seasons(let n):
        inputField = label(numberWord(n, one: translated("1 Staffel"),
                                     many: translated("%lld Staffeln")))
    }
    gtk_widget_add_css_class(inputField, "swiftly-kachelmarke")
    // One point narrower without a word; see the class in the stylesheet.
    if case .watched = mark { gtk_widget_add_css_class(inputField, "swiftly-nurhaken") }
    gtk_widget_set_halign(inputField, GTK_ALIGN_END)
    gtk_widget_set_valign(inputField, GTK_ALIGN_START)
    gtk_overlay_add_overlay(OpaquePointer(wrapper), inputField)
}


/// A small arrow or minus button at the right edge of a list row.
///
/// **Not `insensitive` when unavailable**: GTK overlays its own veil, which looks
/// like an error. Instead half opacity and a callback that does nothing; same
/// lesson as the active account in the profile.
func listArrow(_ symbol: String, name: String, an: Bool,
                 _ perform: @escaping () -> Void) -> Widget! {
    let button: Widget! = gtk_button_new()
    caption(button, name)
    gtk_widget_add_css_class(button, "swiftly-listenpfeil")
    gtk_button_set_child(asButton(button), gtk_image_new_from_icon_name(symbol))
    gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
    if !an { gtk_widget_set_opacity(button, 0.3) }
    signal(button, "clicked") { if an { perform() } }
    return button
}

/// A row that carries one of several options, with a checkmark on the right for the
/// selected one.
///
/// **Not a `GtkCheckButton`**: the checkmark is an accent-coloured icon, and the
/// accent stands for selection.
func selectionRow(_ text: String, an: Bool, _ perform: @escaping () -> Void) -> Widget! {
    let button: Widget! = gtk_button_new()
    gtk_widget_add_css_class(button, "swiftly-zeilenrumpf")
    let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    // **No margins of its own.** `swiftly-zeilenrumpf` already provides a 44 minimum
    // height and 14 side padding; adding 14/10 on top made the row taller than every
    // other row in the same card.
    // **The icon is on the left, as on the Mac**: checkmark for the selected one,
    // empty circle for the others, and the selected row carries the accent (the accent
    // stands for selection).
    //
    // **The empty circle is drawn.** `radio-symbolic` was used here, and in the Adwaita
    // set that is a *portable radio with an antenna*, which indeed showed up in the
    // row. See ``Kreiszeichen``.
    let symbolText: Widget!
    if an {
        symbolText = gtk_image_new_from_icon_name("object-select-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(symbolText), 15)
        gtk_widget_add_css_class(symbolText, "swiftly-akzentzeile")
    } else {
        let circle = CircleCharacter(mass: 15)
        symbolText = circle.display
        // The drawing area holds its drawing; without this access it dies when the call
        // returns. Same case as ``Backdrop``.
        signal(symbolText, "destroy") { _ = circle }
    }
    gtk_widget_set_size_request(symbolText, 22, -1)
    gtk_widget_set_valign(symbolText, GTK_ALIGN_CENTER)
    append(row, symbolText)
    let l = label(text, style: "swiftly-koerper")
    gtk_label_set_xalign(OpaquePointer(l), 0)
    gtk_widget_set_hexpand(l, 1)
    if an { gtk_widget_add_css_class(l, "swiftly-akzentzeile") }
    append(row, l)
    gtk_button_set_child(asButton(button), row)
    help(button, checkmark: an ? .an : .off)
    signal(button, "clicked", perform)
    return button
}

/// The switch from ``schalterzeile(symbol:title:unter:an:toggled:)`` without
/// a surrounding row, for lists that already have one.
///
/// **"Small" here means without a row, not smaller.** The Mac has only one size
/// (`SettingRows.swift:128`); the row list in the appearance settings uses
/// the same `Schalter` as every other row.
func smallerToggle(an: Bool, name: String,
                     _ toggled: @escaping (Bool) -> Void) -> Widget! {
    var condition = an
    let toggle: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(toggle, "swiftly-schalter")
    gtk_widget_set_size_request(toggle, 38, 22)
    gtk_widget_set_valign(toggle, GTK_ALIGN_CENTER)
    let knob: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(knob, "swiftly-knauf")
    gtk_widget_set_size_request(knob, 16, 16)
    gtk_widget_set_valign(knob, GTK_ALIGN_CENTER)
    // Always on the left; the position comes from `margin-left` in the stylesheet so it
    // can animate (a different `halign` jumps, GTK does not animate it).
    gtk_widget_set_halign(knob, GTK_ALIGN_START)
    append(toggle, knob)

    func paint() {
        if condition {
            gtk_widget_add_css_class(toggle, "swiftly-aktiv")
                    } else {
            gtk_widget_remove_css_class(toggle, "swiftly-aktiv")
                    }
    }
    paint()

    let button: Widget! = gtk_button_new()
    gtk_widget_add_css_class(button, "swiftly-blank")
    gtk_button_set_child(asButton(button), toggle)
    gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
    help(button, name: name, checkmark: condition ? .an : .off)
    signal(button, "clicked") {
        condition.toggle()
        paint()
        help(button, checkmark: condition ? .an : .off)
        toggled(condition)
    }
    return button
}

/// **Two columns, left-aligned, as on the Mac.**
///
/// Playback, Appearance and Settings all use it
/// (`macOS/PlaybackSettingsView.swift:38` and siblings). The gap is a
/// double side margin so the cards sit apart like they do from the window edge,
/// and both columns are equally wide, otherwise the fuller one squeezes the other
/// into a strip.
///
/// Without this only the settings page was two-column, and Playback and Appearance
/// sat in a single narrow column, giving three pages three different looks.
func twoColumn(in block: Widget!) -> (left: Widget, right: Widget) {
    let columns = stack(GTK_ORIENTATION_HORIZONTAL,
                         spacing: Int32(Theme.edgeSpacing * 2))
    gtk_widget_set_valign(columns, GTK_ALIGN_START)
    let left = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let right = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
    for column in [left, right] {
        gtk_widget_set_hexpand(column, 1)
        gtk_widget_set_halign(column, GTK_ALIGN_FILL)
        gtk_widget_set_valign(column, GTK_ALIGN_START)
        gtk_widget_set_size_request(column, 300, -1)
        append(columns, column)
    }
    let same = gtk_size_group_new(GTK_SIZE_GROUP_HORIZONTAL)
    gtk_size_group_add_widget(same, left)
    gtk_size_group_add_widget(same, right)
    append(block, columns)
    return (left!, right!)
}

/// **Watch state on a thumbnail**: watched means dimmed, with a checkmark at the top
/// right. The same mark is used in the episode list and the download list, like
/// `Gesehenhaken` on Apple. Watched items step back rather than disappear: 0.45 as
/// on the Mac. The checkmark is returned so the episode list can fade it in and out
/// when toggling.
@discardableResult
func watchedCheckmarkPut(_ wrapper: Widget!, an: Bool) -> Widget! {
    imageDim(wrapper, an)
    let checkmark: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
    gtk_image_set_pixel_size(OpaquePointer(checkmark), 10)
    gtk_widget_add_css_class(checkmark, "swiftly-folgenhaken")
    gtk_widget_set_halign(checkmark, GTK_ALIGN_END)
    gtk_widget_set_valign(checkmark, GTK_ALIGN_START)
    gtk_widget_set_visible(checkmark, an ? 1 : 0)
    gtk_overlay_add_overlay(OpaquePointer(wrapper), checkmark)
    return checkmark
}

/// **Watched: the image only darker, never transparent** (`Gesehenhaken`:
/// `colorMultiply` instead of `opacity`). With the opacity of the whole wrapper the
/// background showed through; on a page in the colour of its header image every
/// watched still took on its tint. `brightness` on the image alone multiplies;
/// checkmark and bar stay as they are.
func imageDim(_ wrapper: Widget!, _ an: Bool) {
    gtk_widget_set_opacity(wrapper, 1)
    var kind = gtk_widget_get_first_child(wrapper)
    while let k = kind {
        if let name = gtk_widget_get_css_name(k), String(cString: name) == "picture" {
            if an { gtk_widget_add_css_class(k, "swiftly-abgedunkelt") }
            else { gtk_widget_remove_css_class(k, "swiftly-abgedunkelt") }
        }
        kind = gtk_widget_get_next_sibling(k)
    }
}

/// **A number with its noun, singular for 1.** Previously many places showed
/// "1 Folgen", "1 Filme". Both forms are separate keys so English can say
/// "1 episode"; `@autoclosure` lets call sites carry the key literally in
/// `translated`, so the translation check finds them.
func numberWord(_ n: Int, one: @autoclosure () -> String, many: @autoclosure () -> String) -> String {
    n == 1 ? one() : String(format: many(), n)
}

/// An icon from a **list** of names; the first one the icon theme knows is used.
/// Breeze (Linux) and Adwaita (Windows) differ: `view-calendar-symbolic` is missing
/// in Adwaita, `x-office-calendar-symbolic` in Breeze. A single name would show the
/// fallback image on one of the two.
func characterImage(_ names: [String]) -> Widget! {
    guard let firstOne = names.first, let icon = g_themed_icon_new(firstOne) else {
        return gtk_image_new()
    }
    for another in names.dropFirst() {
        g_themed_icon_append_name(icon, another)
    }
    let image: Widget! = gtk_image_new_from_gicon(icon)
    g_object_unref(UnsafeMutableRawPointer(icon))
    return image
}

/// **Every sort order has its icon** (Mac `Sorting.symbol`). The button used the
/// same arrows for all four, so next to "Alle" with the filter icon, "A–Z" read like
/// a button without an icon.
extension Sorting {
    var characterNames: [String] {
        switch self {
        case .name:        ["view-sort-ascending-name-symbolic", "view-sort-ascending-symbolic"]
        case .latest:     ["clock-symbolic", "document-open-recent-symbolic"]
        case .rating:   ["starred-symbolic"]
        case .erscheinung: ["view-calendar-symbolic", "x-office-calendar-symbolic"]
        }
    }
}

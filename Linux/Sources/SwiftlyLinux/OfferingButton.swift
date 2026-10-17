import CGtk
import Foundation
import JellyfinKit

/// **"Intro überspringen", "Abspann überspringen", "Nächste Folge"**: the
/// player chip, with the countdown as a fill from the left.
///
/// It exists twice: in the control bar footer, where it always was, and as a
/// separate layer above the picture that appears by itself when the controls
/// are hidden. Modeled on the Mac: `Chip(fuellung:)` in
/// `Sources/macOS/MacComponents.swift`, the overlay in
/// `Sources/macOS/PlayerScreen.swift` (`cardPresent`, `angebotChip`).
///
/// What is shown when is decided by the package (``Abschnittslogik`` and
/// ``Angebotsebene``). This file only does the drawing.
final class OfferingButton {
    private(set) var button: Widget!
    private var image: Widget!
    private var text: Widget!
    private var inner: Widget!
    private var fillContent: Widget!
    private var shown: ButtonOffering = .nobody
    /// The fill as continuous motion (`FillClock`), updated at the window's
    /// frame rate instead of every half second.
    fileprivate var clock: FillClock?
    private var tick: guint = 0

    init(_ fire: @escaping () -> Void) {
        // **White with dark text**, copied from the Mac pill: the accent color
        // belongs in the player only to the scrubber handle while dragging.
        // `active: true` here is not a selection state but this chip's fixed base
        // color.
        button = chip(translated("Nächste Folge"), symbol: "media-skip-forward-symbolic", active: true)
        // **The fill reaches the edge**, so the horizontal padding sits on the
        // content instead of the button; the capsule clips the fill round.
        gtk_widget_add_css_class(button, "swiftly-angebot")
        gtk_widget_set_overflow(button, GTK_OVERFLOW_HIDDEN)
        guard let rail = gtk_widget_get_first_child(button) else { return }
        // **A custom icon** instead of the system symbol (Mac: `forward.end.fill`),
        // dark on the white surface.
        if let alt = gtk_widget_get_first_child(rail) { gtk_box_remove(asBox(rail), alt) }
        let symbolText = PlayerCharacter("next", size: 16, color: (0.043, 0.043, 0.051, 1))
        gtk_box_prepend(asBox(rail), symbolText.display)
        image = symbolText.display
        text = gtk_widget_get_last_child(rail)
        g_object_ref(UnsafeMutableRawPointer(rail))
        gtk_button_set_child(asButton(button), nil)
        gtk_widget_set_margin_start(rail, 18)
        gtk_widget_set_margin_end(rail, 18)
        gtk_box_set_spacing(asBox(rail), 8)

        inner = gtk_overlay_new()
        let reason = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        fillContent = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(fillContent, "swiftly-angebotfuellung")
        gtk_widget_set_halign(fillContent, GTK_ALIGN_START)
        gtk_widget_set_visible(fillContent, 0)
        append(reason, fillContent)
        gtk_overlay_set_child(OpaquePointer(inner), reason)
        gtk_overlay_add_overlay(OpaquePointer(inner), rail)
        gtk_overlay_set_measure_overlay(OpaquePointer(inner), rail, 1)
        g_object_unref(UnsafeMutableRawPointer(rail))
        gtk_button_set_child(asButton(button), inner)

        caption(button, translated("Nächste Folge"))
        gtk_widget_set_visible(button, 0)
        signal(button, "clicked", fire)
        // The page also removes the button on teardown; afterwards nothing here
        // points to it.
        signal(button, "destroy") { [weak self] in
            self?.tick = 0
            self?.button = nil; self?.image = nil; self?.text = nil
            self?.inner = nil; self?.fillContent = nil
        }
    }

    /// Label, icon and accessible name for screen readers, only when the offer
    /// changed. `countdown` is the fraction from 0 to 1.
    func setDown(_ offering: ButtonOffering, visible: Bool, fillContent new: FillClock? = nil,
                fade: Bool = false) {
        guard button != nil else { return }
        if fade {
            // Stays attached and fades via opacity, with the same transition time as
            // the controls (`.swiftly-steuerung`, 180 ms).
            let an = visible && offering.visible
            gtk_widget_set_visible(button, offering.visible || shown.visible ? 1 : 0)
            gtk_widget_set_opacity(button, an ? 1 : 0)
            gtk_widget_set_can_target(button, an ? 1 : 0)
        } else {
            gtk_widget_set_visible(button, visible && offering.visible ? 1 : 0)
        }
        if offering.visible, offering != shown {
            shown = offering
            gtk_label_set_text(OpaquePointer(text), offering.label)
            caption(button, offering.label)
        }
        clock = new
        if clock != nil {
            fillDraw()
            if tick == 0 {
                tick = gtk_widget_add_tick_callback(button, fillTick,
                                                    Unmanaged.passUnretained(self).toOpaque(), nil)
            }
        } else {
            if tick != 0 { gtk_widget_remove_tick_callback(button, tick); tick = 0 }
            gtk_widget_set_visible(fillContent, 0)
        }
    }

    fileprivate func fillDraw() {
        guard let clock, inner != nil, gtk_widget_get_width(inner) > 0 else { return }
        gtk_widget_set_visible(fillContent, 1)
        gtk_widget_set_size_request(fillContent,
                                    Int32((Double(gtk_widget_get_width(inner)) * clock.share()).rounded()), -1)
    }
}

nonisolated(unsafe) private let fillTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    Unmanaged<OfferingButton>.fromOpaque(data).takeUnretainedValue().fillDraw()
    return 1
}

extension App {

    /// Seconds per tick; the same number the tick runs with.
    static var tickSeconds: Double {
        let t = PlaybackTick.tickLength.components
        return Double(t.seconds) + Double(t.attoseconds) / 1e18
    }

    /// Whether it advances automatically at the end: own choice before account
    /// setting before "on" (`Weiterschalten`, like `AppModel` on Apple).
    var nextAutomatic: Bool {
        Advance.applies(ownSelection: selection.nextAutomaticSelected,
                            account: nextAutomaticAccount)
    }

    /// Fetch `EnableNextEpisodeAutoPlay` and the download permission on the side,
    /// without an error message: if nothing arrives it stays at the own choice or
    /// "on", and the permission stays `.unknown`, i.e. allowed. **One request for
    /// both.**
    func accountPreGiftFetch(_ c: JellyfinClient) {
        Task.detached { [self] in
            let guidelines = await c.accountDefaults()
            let account = guidelines?.nextEpisodeAutomatic
            let rights = guidelines?.downloadPermission ?? .unknown
            let convert = guidelines?.convertAllowed ?? true
            let quality = guidelines?.downloadQualitySelectable ?? true
            onMainThread {
                // Another account in the meantime: its setting is fetched itself.
                guard self.client === c else { return }
                self.nextAutomaticAccount = account
                self.downloadPermission = rights
                self.convertAllowed = convert
                self.downloadQualitySelectable = quality
                AppLog.writeOut("[Konto] Nächste Folge automatisch: \(account.map { String($0) } ?? "nil"), gilt \(self.nextAutomatic), Downloads: \(rights.rawValue)")
                fflush(nil)
                // The open page may have built the button already.
                self.seasonLoadButtonDraw()
            }
        }
    }

    /// The controls are visible. They fade out via opacity, not visibility, so
    /// they stay laid out. Uses the state, not the opacity, which is an
    /// intermediate value during a fade.
    private var controlsPresent: Bool {
        playerControls != nil && controlsOpen && openLayerArt == nil
    }

    /// **The offer button is shown in one place, whether or not the controls are
    /// open** (Mac: `offeringPresent`): Skip for the first six seconds of the section,
    /// after that only with the controls (`OfferingLayer.buttonDuration`); the card
    /// when the controls are closed, the normal "Nächste Folge" button when they
    /// are open. The footer button only holds the space.
    var offeringPresent: Bool {
        guard runningTitle != nil, currentOffering.visible, playerLoadingScreen == nil,
              openLayer == nil, !episodesSwitch.running else { return false }
        return offeringLayer.display.visible || (controlsPresent && currentOffering == .nextEpisode)
    }

    /// **The overlay is shown without controls**, since the keys depend on it
    /// (Mac: `cardPresent`).
    var offeringImage: Bool {
        guard runningTitle != nil, playerLoadingScreen == nil,
              openLayer == nil, !episodesSwitch.running else { return false }
        // The card also shows over controls opened only by the pointer.
        if case .card = offeringLayer.display { return true }
        return offeringLayer.display.visible && !controlsPresent
    }

    /// Bring both buttons in line with the offer and layer state.
    func offeringUpdate() {
        // The layer follows the controls; this is only a sync because every fade in
        // and out passes through here. Whether opening cancels the card is decided by
        // `controlsShow(through:)`.
        if runningTitle != nil { offeringLayer.controls(opened: controlsPresent, through: .beside) }
        var countdown: Double?
        if case let .card(share) = offeringLayer.display { countdown = share }
        offeringClock.set(share: countdown,
                            running: playState.running && playerLoadingScreen == nil && !atSlider,
                            length: offeringLayer.countdownLength)
        // In the footer only the space: invisible and not clickable.
        playerNext?.setDown(currentOffering, visible: true)
        if let footer = playerNext?.button {
            gtk_widget_set_opacity(footer, 0)
            gtk_widget_set_can_target(footer, 0)
        }

        cardUpdate(countdown: countdown)

        guard let layer = playerOffering, layer.button != nil else { return }
        // **While the card is shown, the button yields** (iOS `buttonPresent`): the
        // "Nächste Folge" button is only shown with open controls, without
        // countdown.
        let showItem = offeringPresent && countdown == nil
        // **In place of the footer button.** If the controls open because the
        // pointer moves toward the button, the same button is there, so the click
        // lands instead of hitting nothing.
        if showItem, let footer = playerNext?.button, let frameRect = playerFrame,
           gtk_widget_get_visible(footer) != 0 {
            var r = graphene_rect_t()
            if gtk_widget_compute_bounds(footer, frameRect, &r) != 0, r.size.width > 0 {
                let right = Double(gtk_widget_get_width(frameRect)) - Double(r.origin.x + r.size.width)
                let bottom = Double(gtk_widget_get_height(frameRect)) - Double(r.origin.y + r.size.height)
                gtk_widget_set_margin_end(layer.button, Int32(max(0, right).rounded()))
                gtk_widget_set_margin_bottom(layer.button, Int32(max(0, bottom).rounded()))
            }
        }
        let before = gtk_widget_get_opacity(layer.button) > 0.5 && gtk_widget_get_visible(layer.button) != 0
        layer.setDown(currentOffering, visible: showItem, fillContent: nil, fade: true)
        if before != showItem {
            AppLog.writeOut("[Angebot] Einblendung \(showItem ? "an" : "aus"): \(currentOffering.label)\(countdown != nil ? " mit Countdown" : "") bei \(Int(playState.position)) s, Steuerung \(controlsPresent ? "offen" : "zu")")
            fflush(nil)
        }
    }

    /// **Track the next-episode card** (variant C, iOS `cardsLayer`): shown
    /// while the layer shows its countdown, not in the group, not under a sheet,
    /// not during a switch. If the pointer merely opens the controls, it stays and
    /// moves above the timeline; opened deliberately (click, key), it goes away
    /// and the countdown waits (``Angebotsebene/cardWaitsControls``).
    private func cardUpdate(countdown: Double?) {
        guard let card = playerCard, card.wrapper != nil else { return }
        let present = offeringPresent && countdown != nil && !inGroup
        let episode = prefetchedEpisode
        var image: URL?
        if let episode, let addresses {
            if let mark = episode.imageTags?["Primary"] {
                image = addresses.construct(itemID: episode.id, mark: mark, mass: .atMostHigh(Int(card.width)))
            } else {
                image = ImageSelection.landscape(episode, addresses: addresses, width: Int(card.width) * 2)?.url
            }
        }
        let windowWidthValue = playerFrame.map { gtk_widget_get_width($0) } ?? 0
        card.setDown(episode: episode, image: image, present: present,
                     clock: countdown == nil ? nil : offeringClock,
                     rest: offeringLayer.countdownRest,
                     windowWidthValue: windowWidthValue > 0 ? windowWidthValue : 1280)
        // Above the timeline while the controls are shown; otherwise at a safe
        // distance from the edge, as on iPhone.
        var bottom = PlayerMetric.bottom + Int32(EpisodeCard.bottomSpacing)
        if controlsPresent, let slider = playerSlider, let frameRect = playerFrame {
            var r = graphene_rect_t()
            if gtk_widget_compute_bounds(slider, frameRect, &r) != 0, r.size.height > 0 {
                bottom = Int32((Double(gtk_widget_get_height(frameRect)) - Double(r.origin.y)).rounded()) + 12
            }
        }
        card.bottom(bottom)
        // The scrim: darkened while the card is shown and the controls do not
        // already provide it (iOS `dimmed`); the gradient at the bottom right
        // stays under the controls too.
        if let scrim = playerCardsScrim {
            let an = present
            if an { gtk_widget_add_css_class(scrim, "swiftly-kartenschleier-an") }
            else { gtk_widget_remove_css_class(scrim, "swiftly-kartenschleier-an") }
            if controlsPresent { gtk_widget_add_css_class(scrim, "swiftly-kartenschleier-hell") }
            else { gtk_widget_remove_css_class(scrim, "swiftly-kartenschleier-hell") }
            if abs(gtk_widget_get_opacity(scrim) - (an ? 1 : 0)) > 0.01 {
                crossfade(scrim, on: an ? 1 : 0, duration: an ? 0.18 : 0.34,
                        curve: an ? .easeOut : .easeInOut)
            }
        }
    }

    /// Cancel: X on the card (iOS `cancel`): countdown gone, no auto-advance
    /// at end of file (`OfferingLayer.nextCancelled`).
    func cardCancel() {
        offeringLayer.close()
        AppLog.writeOut("[Angebot] Karte abgesagt, weiter abgesagt: \(offeringLayer.nextCancelled)")
        fflush(nil)
        offeringUpdate()
    }

    /// Create the layer above the picture, above the controls, bottom right.
    func offeringLayerBuild(in frameRect: Widget!) {
        let card = EpisodeCardsView(fire: { [weak self] in
            guard let self else { return }
            AppLog.writeOut("[Karte] Start")
            fflush(nil)
            self.offeringLayer.pressed()
            self.offeringUpdate()
            self.nextEpisode()
        }, cancel: { [weak self] in self?.cardCancel() })
        gtk_widget_set_margin_end(card.wrapper, PlayerMetric.page)
        gtk_widget_set_margin_bottom(card.wrapper, PlayerMetric.bottom + Int32(EpisodeCard.bottomSpacing))
        gtk_overlay_add_overlay(OpaquePointer(frameRect), card.wrapper)
        playerCard = card

        let layer = OfferingButton { [weak self] in self?.offeringRun() }
        gtk_widget_set_halign(layer.button, GTK_ALIGN_END)
        gtk_widget_set_valign(layer.button, GTK_ALIGN_END)
        gtk_widget_add_css_class(layer.button, "swiftly-angebotblende")
        // Until the footer button's position is known, use the Mac's sizes.
        gtk_widget_set_margin_end(layer.button, 28)
        gtk_widget_set_margin_bottom(layer.button, 26 + 38)
        gtk_overlay_add_overlay(OpaquePointer(frameRect), layer.button)
        playerOffering = layer
    }
}

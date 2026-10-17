import JellyfinKit
import SwiftUI

// MARK: - Badge at the top

/// **One badge for everything playing elsewhere.** Same spot as the old "continue watching
/// here" badge, left of the profile picture. If something plays elsewhere **and** a group
/// exists, a counter is shown and a press opens a panel with both, instead of two badges
/// that push the profile picture around.
/// **One line at rest, the second line on focus.** Two lines next to tabs at 31 pt ran
/// under the backdrop image. The first line says what a press does; the reason is visible
/// before pressing.
struct OfferingBadge: View {
    let continueWatching: [RemoteSession]
    let groups: [SyncPlayGroup]
    var action: () -> Void

    /// How many entries the panel would have.
    var count: Int { continueWatching.count + groups.count }

    var body: some View {
        Button(action: action) {
            ContentBody(symbol: symbol, label: label, under: value,
                   counter: count > 1 ? count : nil)
        }
        .buttonStyle(BadgeStyle(otherDevice: true))
        .accessibilityLabel(label)
        .accessibilityValue(Text(verbatim: value))
    }

    private var symbol: String {
        if let first = continueWatching.first { return first.devicesCharacter }
        return "person.2.fill"
    }

    private var label: Text {
        if count > 1 { return Text("Läuft gerade") }
        return continueWatching.isEmpty ? Text("Gemeinsam schauen") : Text("Hier weiterschauen")
    }

    private var value: String {
        (continueWatching.map(\.titleLine) + groups.map(\.name)).joined(separator: ", ")
    }

    private struct ContentBody: View {
        let symbol: String
        let label: Text
        let under: String
        let counter: Int?
        @Environment(\.isFocused) private var focus

        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(Theme.tile)
                VStack(alignment: .leading, spacing: 1) {
                    label
                        .font(Theme.button)
                    if focus {
                        // Server data, hence `verbatim`.
                        Text(verbatim: under)
                            .font(Theme.small)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let counter {
                    // Like the counter on iPhone: accent color, at rest and focused.
                    Text(verbatim: "\(counter)")
                        .font(Theme.badge.monospacedDigit())
                        .foregroundStyle(Theme.onAccent)
                        .frame(minWidth: 34, minHeight: 34)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 28)
            .frame(height: focus ? 76 : 64)
        }
    }
}

// MARK: - Panels

/// **Create, join and pick, as focus panels above everything.** On iPhone these are sheets
/// from the bottom; the TV has no thumb at the bottom and the choice has consequences, so
/// it uses the same form as `TVTakeoverSelection`: dimmed, centered, Menu closes. Attached
/// to ``MainView`` because any page can open it.
///
/// **The name is prefilled, the keyboard optional.** Focus starts on "Gruppe öffnen", not
/// in the field, so one press is enough for a default name. Typing with the remote is a
/// detour nobody should need for a group name.
struct TVSharedPanel: View {
    let continueWatching: [RemoteSession]
    let hereContinueWatching: (RemoteSession) -> Void
    var gemeinsam: SharedModel

    @State private var name = ""
    /// The row of the picker that has focus; see `pick`.
    @FocusState private var selectionFocus: String?

    var body: some View {
        ZStack {
            if let title = gemeinsam.createFor {
                panel(close: { gemeinsam.createFor = nil }) { create(title) }
                    .onAppear { name = String(localized: "Filmabend") }
            } else if case let .join(g)? = gemeinsam.sheet {
                panel(close: { gemeinsam.sheet = nil }) { join(g) }
            } else if gemeinsam.sheet == .pick {
                panel(close: { gemeinsam.sheet = nil }) { pick }
                    .defaultFocus($selectionFocus, firstRow)
                    .task { selectionFocus = firstRow }
            }
        }
    }

    /// The frame around every panel, same as in `TVTakeoverSelection`. `MainView` puts the
    /// dimming layer below it as its own layer; it only fades, while the panel comes out of
    /// the badge.
    private func panel<ContentBody: View>(close: @escaping () -> Void,
                                     @ViewBuilder content: () -> ContentBody) -> some View {
        ZStack {
            VStack(spacing: 34) { content() }
                .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Menu closes, as everywhere on the TV.
        .onExitCommand(perform: close)
    }

    private func header(_ title: Text, _ under: String) -> some View {
        VStack(spacing: 10) {
            title
                .font(Theme.subpageTitle)
                .tracking(Theme.lockSubpage)
            // Titles and names from the server, shown verbatim.
            Text(verbatim: under)
                .font(Theme.small)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Create

    @ViewBuilder
    private func create(_ title: Item) -> some View {
        header(Text("Gemeinsam schauen"), SharedModel.titleLine(title))
        VStack(alignment: .leading, spacing: 12) {
            Text("Name der Gruppe")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
            InputField(placeholder: "Filmabend", text: $name)
            Text("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle.")
                .font(Theme.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .frame(width: 760)
        .focusSection()
        ButtonPair(main: Text("Gruppe öffnen"), locked: gemeinsam.works,
                  perform: { Task { await gemeinsam.create(name: name, title: title) } },
                  cancel: { gemeinsam.createFor = nil })
    }

    // MARK: Join

    @ViewBuilder
    private func join(_ g: SyncPlayGroup) -> some View {
        header(Text(verbatim: g.name), SharedModel.wer(g))
        VStack(spacing: 8) {
            if let condition = SharedModel.stateTextOf(g.condition) {
                Text(condition)
                    .font(Theme.small)
                    .foregroundStyle(Theme.accent)
            }
            Text("Pause und Springen gelten für alle.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
        }
        ButtonPair(main: Text("Beitreten"), locked: gemeinsam.works,
                  perform: { Task { await gemeinsam.join(g) } },
                  cancel: { gemeinsam.sheet = nil })
    }

    // MARK: Pick

    /// Devices and groups in one list, as on iPhone; each row says what a press does on its
    /// right.
    ///
    /// **Focus is placed explicitly, not searched.** The badge that opens the panel is
    /// disabled along with it, but tvOS does not take focus away from it. Without this,
    /// focus stayed on the disabled badge and the panel ignored presses until the app went
    /// to the background and focus was searched again. Join and create do the same in
    /// ``Knopfpaar``.
    @ViewBuilder
    private var pick: some View {
        Text("Läuft gerade")
            .font(Theme.subpageTitle)
            .tracking(Theme.lockSubpage)
        VStack(spacing: 14) {
            ForEach(continueWatching) { s in
                row(key: "s" + s.id, symbol: s.devicesCharacter,
                      title: s.deviceName ?? String(localized: "Gerät"),
                      under: s.titleLine,
                      action: Text("Hier weiterschauen")) {
                    gemeinsam.sheet = nil
                    hereContinueWatching(s)
                }
            }
            ForEach(gemeinsam.group == nil ? gemeinsam.offerings : []) { g in
                row(key: "g" + g.id, symbol: "person.2.fill", title: g.name, under: SharedModel.wer(g),
                      action: Text("Beitreten")) {
                    Task { await gemeinsam.join(g) }
                }
            }
        }
        .focusSection()
        Button("Abbrechen") { gemeinsam.sheet = nil }
            .buttonStyle(BadgeStyle())
    }

    /// The top row of the picker, where focus starts.
    private var firstRow: String? {
        if let s = continueWatching.first { return "s" + s.id }
        return (gemeinsam.group == nil ? gemeinsam.offerings.first : nil).map { "g" + $0.id }
    }

    private func row(key: String, symbol: String, title: String, under: String, action: Text,
                       perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .medium))
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(Theme.listTitle)
                    Text(verbatim: under)
                        .font(Theme.small)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                action
                    .font(Theme.small.weight(.semibold))
            }
            .padding(.horizontal, 28)
            .frame(height: 88)
            .frame(maxWidth: 760)
        }
        // As in the handover picker: cool tint, because it plays elsewhere.
        .buttonStyle(BadgeStyle(otherDevice: true))
        .focused($selectionFocus, equals: key)
    }
}

/// The main action and "Abbrechen" side by side. Focus starts on the main action; see
/// ``TVGemeinsamtafeln``.
private struct ButtonPair: View {
    let main: Text
    let locked: Bool
    let perform: () -> Void
    let cancel: () -> Void
    @FocusState private var atMain: Bool

    var body: some View {
        HStack(spacing: 24) {
            Button(action: perform) { main }
                .buttonStyle(ThemedButtonStyle())
                .disabled(locked)
                .focused($atMain)
            Button("Abbrechen", action: cancel)
                .buttonStyle(ThemedButtonStyle())
        }
        .focusSection()
        .defaultFocus($atMain, true)
        .task { atMain = true }
    }
}

// MARK: - Way back

/// "Filmabend verlassen · Wieder beitreten": undo instead of asking for confirmation.
///
/// **At the bottom, where nothing else is focusable**, as its own full-width focus section,
/// so a press down reaches the button from anywhere. It does not claim focus itself; after
/// the player closes, focus belongs to the trigger.
struct TVReturnPathStrip: View {
    let name: String
    let join: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                Text("\(name) verlassen")
                    .font(Theme.body)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                Button(action: join) {
                    Text("Wieder beitreten")
                        .padding(.horizontal, 28)
                        .frame(height: 64)
                }
                .buttonStyle(BadgeStyle(otherDevice: true))
            }
            .padding(.leading, 36)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .background(Theme.raised, in: Capsule())
            .frame(maxWidth: .infinity)
            .focusSection()
            .padding(.bottom, Theme.edgeTop)
        }
    }
}

// MARK: - In the player

/// "Filmabend · mit Anna und Ben" under the title, where season and episode usually go. The
/// name takes the accent color because being in a group is a state.
struct TVGroupsRow: View {
    let name: String
    let withWhom: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(Theme.accent)
            // Name and participants come from the server, shown verbatim.
            Text(verbatim: name)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.accent)
            Text(verbatim: "· \(withWhom)")
        }
        .accessibilityElement(children: .combine)
    }
}

/// Briefly at the top of the picture: who joined, who left, why the film stopped.
struct TVGroupsEvent: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(verbatim: text)
                .font(Theme.body)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
        }
        .padding(.horizontal, 30)
        .frame(minHeight: 76)
        .background(Theme.area, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

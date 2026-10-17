import JellyfinKit
import SwiftUI

// "Watch together" on the Mac.
//
// **The template is iOS** (`Sources/iOS/SharedViews.swift`). The flow lives
// in the package (`SyncPlaySession`), its mirror in
// `Sources/Shared/SharedModel.swift`. This file only holds the presentation,
// adapted to pointer, keyboard and window:
// - The badge is the row at the bottom of the sidebar, the same place as
// "Hier weiterschauen", where the iPhone has the header on the right.
// - Create, join and the picker are not sheets from below but a panel in the
// middle of the window over a scrim, like the handover device picker
// (`Uebernahmeauswahl`). The Mac has no bottom sheets.
// - Return confirms, Escape cancels.

// MARK: - In the player

/// "Movie night · with Anna and Ben" under the title, where year and runtime
/// usually go. The name carries the accent: being in a group is a state. Verbatim
/// the iPhone version.
struct GroupsRow: View {
    let name: String
    let withWhom: String
    let size: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.system(size: size + 1))
                .foregroundStyle(Theme.accent)
            // Name and participants come from the server, verbatim.
            Text(verbatim: name)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.accent)
            Text(verbatim: "· \(withWhom)")
        }
        .font(.system(size: size))
        .accessibilityElement(children: .combine)
    }
}

/// Briefly at the top of the picture: who joined, who left, why the film stopped.
///
/// In the shape of `Hinweisstreifen`, the capsule that floats over a surface on the
/// Mac. On iPhone it is 44 high because every capsule there is a finger target;
/// here it takes no click.
struct GroupsEvent: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(Theme.listTitle)
                .foregroundStyle(Theme.accent)
            Text(verbatim: text)
                .font(Theme.body)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.buttonField)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.margin, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The sidebar row

/// **One row for everything currently playing elsewhere.**
///
/// Formerly `Uebernahmezeile`, which only knew "Hier weiterschauen".
/// **A Mac-specific version because the sidebar is narrow.** On TV the badge shows
/// two rows side by side; here they are stacked.
///
/// Same place as "Hier weiterschauen"; it *is* that row. If something plays
/// elsewhere **and** there is a group, a counter sits at the icon and a click opens
/// the picker with both, instead of two stacked rows pushing the account upward.
struct OfferingRow: View {
    let continueWatching: [RemoteSession]
    let groups: [SyncPlayGroup]

    @State private var hovers = false

    /// How many entries the picker would have.
    var count: Int { continueWatching.count + groups.count }

    var body: some View {
        // **The TV's shape** (`OfferingBadge`, `AbzeichenStil` with
        // `otherDevice`): a capsule in accent at 18 % over `reason`, icon and title in
        // accent, the counter as its own capsule at the end.
        HStack(spacing: 10) {
            // **The accent, and the icon makes the difference**: no separate blue for
            // "playing elsewhere".
            Image(systemName: symbol)
                .font(Theme.tile)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(Theme.tileTitleText)
                    .lineLimit(1)
                Text(verbatim: under)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if count > 1 {
                // As on TV: accent, tabular digits.
                Text(verbatim: "\(count)")
                    .font(Theme.badge.monospacedDigit())
                    .foregroundStyle(Theme.onAccent)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .foregroundStyle(Theme.accent)
        .padding(.leading, 14)
        .padding(.trailing, count > 1 ? 10 : 14)
        .frame(height: Theme.badgeHeight)
        .background {
            ZStack {
                Capsule().fill(Theme.reason)
                Capsule().fill(Theme.accent.opacity(0.18))
                if hovers { Capsule().fill(Theme.hoverArea) }
            }
        }
        .contentShape(Capsule())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: under))
    }

    private var symbol: String {
        if let first = continueWatching.first { return first.devicesCharacter }
        return "person.2.fill"
    }

    /// The same names as the badge on iPhone.
    private var title: Text {
        if count > 1 { return Text("Läuft gerade") }
        return continueWatching.isEmpty ? Text("Gemeinsam schauen") : Text("Hier weiterschauen")
    }

    /// What is playing: its title for one entry, otherwise all in a row.
    private var under: String {
        (continueWatching.map(\.titleLine) + groups.map(\.name)).joined(separator: ", ")
    }
}

// MARK: - The panels

/// The panels "Watch together", "Join" and the picker. Attached in ``MainView``
/// above everything except the player, because any page can open them.
struct SharedPanel: View {
    let takeover: [RemoteSession]
    let continueWatching: (RemoteSession) -> Void

    @State private var gemeinsam = SharedModel.shared
    @State private var name = ""
    @FocusState private var taps: Bool

    /// Which panel is shown. Create takes priority since it comes from a click on this
    /// machine; join and picker come from the sidebar.
    private enum Panel: Equatable { case create, join, pick }
    private var panel: Panel? {
        if gemeinsam.createFor != nil { return .create }
        switch gemeinsam.sheet {
        case .join?: return .join
        case .pick?: return .pick
        case nil: return nil
        }
    }

    var body: some View {
        ZStack {
            if let panel {
                // Catches the click so nothing behind it reacts, and closes, as with the handover
                // device picker.
                Theme.reason.opacity(0.62)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: cancel)
                    .transition(.opacity)

                VStack(spacing: 0) {
                    switch panel {
                    case .create: create
                    case .join: join
                    case .pick: pick
                    }
                    SheetLine()
                    Button(action: cancel) {
                        Text("Abbrechen")
                            .font(Theme.body)
                            .foregroundStyle(Theme.fontQuiet)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(Theme.PressRow())
                    .keyboardShortcut(.cancelAction)
                }
                .foregroundStyle(Theme.font)
                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
                .frame(width: Theme.formWidth)
                .accessibilityAction(.escape, cancel)
                // **The picker grows out of the badge** in the sidebar (as on iPhone and as
                // "Wo weiterschauen?"); create and join come from elsewhere and fade as before.
                .transition(panel == .pick ? .outPoint(BadgeOrigin.point)
                                              : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(panel == .pick || panel == nil ? Theme.spring : Theme.leap, value: panel)
        .onChange(of: gemeinsam.createFor?.id, initial: true) { _, new in
            guard new != nil else { taps = false; return }
            name = String(localized: "Filmabend")
            // Only once the field exists; it does not in the same pass.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                if gemeinsam.createFor != nil { taps = true }
            }
        }
    }

    private func cancel() {
        taps = false
        gemeinsam.createFor = nil
        gemeinsam.sheet = nil
    }

    // MARK: Create

    @ViewBuilder private var create: some View {
        PanelCategory(text: Text("Gemeinsam schauen"))
        if let title = gemeinsam.createFor {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Self.titleLine(title))
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(2)
                    .padding(.bottom, 16)
                Text("Name der Gruppe")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.bottom, 6)
                TextField(text: $name) { Text("Filmabend") }
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.font)
                    .focused($taps)
                    // Return in the field opens the group. No `.defaultAction` on the button for it,
                    // otherwise it would fire twice.
                    .onSubmit { open(title) }
                    .padding(.horizontal, 12)
                    .frame(height: Theme.buttonField)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                Text("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                PrimaryButton(label: "Gruppe öffnen", symbol: "person.2.fill") { open(title) }
                    .disabled(gemeinsam.works)
                    .opacity(gemeinsam.works ? 0.5 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func open(_ title: Item) {
        guard !gemeinsam.works else { return }
        taps = false
        Task { await gemeinsam.create(name: name, title: title) }
    }

    // MARK: Join

    @ViewBuilder private var join: some View {
        if case let .join(g)? = gemeinsam.sheet {
            PanelCategory(text: Text(verbatim: g.name))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Self.wer(g))
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                if let condition = Self.stateTextOf(g.condition) {
                    Text(condition)
                        .font(Theme.small)
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 6)
                }
                Text("Pause und Springen gelten für alle.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
                PrimaryButton(label: "Beitreten", symbol: "person.2.fill") {
                    guard !gemeinsam.works else { return }
                    Task { await gemeinsam.join(g) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(gemeinsam.works)
                .opacity(gemeinsam.works ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: Picker

    @ViewBuilder private var pick: some View {
        PanelCategory(text: Text("Läuft gerade"))
        ForEach(takeover) { s in
            SheetLine()
            SelectionRow(symbol: s.devicesCharacter,
                         title: s.deviceName ?? String(localized: "Gerät"),
                         under: s.titleLine,
                         action: Text("Hier weiterschauen")) {
                gemeinsam.sheet = nil
                continueWatching(s)
            }
        }
        ForEach(gemeinsam.group == nil ? gemeinsam.offerings : []) { g in
            SheetLine()
            SelectionRow(symbol: "person.2.fill", title: g.name, under: Self.wer(g),
                         action: Text("Beitreten")) {
                Task { await gemeinsam.join(g) }
            }
        }
    }

    /// For an episode, the series with season and episode; otherwise the panel does not
    /// say which episode the group will watch.
    static func titleLine(_ title: Item) -> String {
        guard title.type == "Episode", let series = title.seriesName, !series.isEmpty else {
            return title.name
        }
        if let season = title.parentIndexNumber, let episode = title.indexNumber {
            return "\(series) · " + String(localized: "Staffel \(season) · Folge \(episode)")
        }
        return "\(series) · \(title.name)"
    }

    /// "Anna and Ben are watching".
    static func wer(_ g: SyncPlayGroup) -> String {
        var watched = Set<String>()
        let names = g.participant.filter { watched.insert($0).inserted }
        guard !names.isEmpty else { return String(localized: "Noch niemand dabei") }
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1 ? String(localized: "\(list) schaut gerade")
                                : String(localized: "\(list) schauen gerade")
    }

    static func stateTextOf(_ z: SyncPlayGroup.Phase?) -> LocalizedStringKey? {
        switch z {
        case .running: "Läuft gerade"
        case .halted: "Angehalten"
        case .waits: "Wartet auf alle"
        case .empty, nil: nil
        }
    }
}

/// The heading of a panel, at the size of the sheet section heading (17 semibold).
private struct PanelCategory: View {
    let text: Text

    var body: some View {
        text
            .font(Theme.categoryLarge)
            .tracking(Theme.lockCategory)
            .foregroundStyle(Theme.font)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One picker row: icon, what and where, the action on the right.
private struct SelectionRow: View {
    let symbol: String
    let title: String
    let under: String
    let action: Text
    let perform: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(Theme.categoryLarge)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(Theme.listTitle)
                        .foregroundStyle(Theme.font)
                        .lineLimit(1)
                    Text(verbatim: under)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                action
                    .font(Theme.listTitle)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 58)
            .background(hovers ? Theme.hoverArea : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
    }
}

// MARK: - Errors

/// What went wrong with the group, shown in the `Hinweisstreifen` like any short
/// message on the Mac. A click or four seconds dismisses it.
struct SharedError: View {
    @State private var gemeinsam = SharedModel.shared

    var body: some View {
        ZStack {
            if let text = gemeinsam.error {
                HintStrip(text: text)
                    .contentShape(Capsule())
                    .onTapGesture { gemeinsam.error = nil }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { gemeinsam.error = nil }
                    .transition(.opacity)
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, gemeinsam.error == text else { return }
                        gemeinsam.error = nil
                    }
            }
        }
        .animation(Theme.reveal, value: gemeinsam.error)
    }
}

// MARK: - After leaving

/// "Left Movie night · Rejoin": undo instead of a confirmation.
///
/// In the shape of `Hinweisstreifen`, bottom centre of the content, where every
/// notice sits on iPhone too. How long it stays is defined by the package
/// (`SyncPlayStatus.lastLeave`).
struct ReturnPathStrip: View {
    let name: String
    let join: () -> Void

    @State private var hovers = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(name) verlassen")
                .font(Theme.body)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
            Button(action: join) {
                Text("Wieder beitreten")
                    .font(Theme.listTitle)
                    .foregroundStyle(hovers ? Theme.accentLight : Theme.accent)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            .onHover { hovers = $0 }
            .animation(Theme.timeFloat, value: hovers)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.margin, lineWidth: 1))
    }
}

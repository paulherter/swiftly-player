import JellyfinKit
import SwiftUI

// MARK: - In the player

/// "Movie night - with Anna and Ben" under the title, where year and
/// runtime normally are. The name carries the accent: being in a group
/// is a state.
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
struct GroupsEvent: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(verbatim: text)
                .font(Theme.body)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(Theme.area, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The badge at the top

/// **One badge for everything playing elsewhere**.
///
/// Same spot as "Continue watching here": left of watchlist and profile.
/// If something plays elsewhere **and** there is a group, a counter sits on
/// it and a tap opens a sheet with both - not two icons side by side that
/// would shift watchlist and profile.
struct OfferingBadge: View {
    let takeover: TakeoverModel?
    /// Spacing below - only if the badge exists.
    var bottom: CGFloat = 0
    @State private var gemeinsam = SharedModel.shared
    /// Where the icon sits on screen - the picker grows from there.
    @State private var frameRect: CGRect = .zero

    private var groups: [SyncPlayGroup] {
        gemeinsam.group == nil && gemeinsam.mayJoin ? gemeinsam.offerings : []
    }
    private var continueWatching: [RemoteSession] { takeover?.offerings ?? [] }

    /// How many entries the sheet would have.
    var count: Int { continueWatching.count + groups.count }

    var body: some View {
        if count > 0 {
            Button(action: tapOn) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if count > 1 {
                            Text(verbatim: "\(count)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.onAccent)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Theme.accent, in: Capsule())
                                .offset(x: -2, y: 4)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameRect = $0 }
            .accessibilityLabel(label)
            .accessibilityValue(Text(verbatim: value))
            .padding(.bottom, bottom)
            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
        }
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

    private func tapOn() {
        BadgeOrigin.point = CGPoint(x: frameRect.midX, y: frameRect.midY)
        if groups.isEmpty {
            takeover?.tapped = true
        } else if continueWatching.isEmpty, groups.count == 1, let g = groups.first {
            gemeinsam.sheet = .join(g)
        } else {
            gemeinsam.sheet = .pick
        }
    }
}

// MARK: - Sheets

/// The sheets "Watch together", "Join" and the picker, and the strip after
/// leaving. Attached in ``MainView`` above everything, because every root
/// page and detail page can open them.
struct SharedSheets: View {
    let takeover: [RemoteSession]
    let continueWatching: (RemoteSession) -> Void

    @State private var gemeinsam = SharedModel.shared
    @State private var name = ""
    @FocusState private var taps: Bool

    /// **What the sheet shows stays in the tree - even closed, and even before it
    /// opens.** If the content hung directly on `createFor`, it was created at
    /// the same moment the sheet opened: newly inserted views sit at their final
    /// position at once and do not follow the sheet's animated offset - text and
    /// button were there and the sheet arrived underneath. Now the content comes
    /// first and the sheet opens one beat later.
    @State private var createTitle: Item?
    @State private var createOn = false
    @State private var joinGroup: SyncPlayGroup?
    @State private var joinOn = false

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
                .sheet(opened: createOpen) { create }
            Color.clear
                .allowsHitTesting(false)
                .sheet(opened: joinOpen) { join }
            // **The picker is a card from the badge**, not a bottom sheet
            // (`experiment-glas` attempt) - like "Where to continue?" in `MainView`.
            if selectionOpen {
                TakeoverSelection.scrim { gemeinsam.sheet = nil }
                    .transition(.opacity)
                VStack(spacing: 0) { pick }
                    .padding(.top, 15)
                    .background(Theme.area,
                                in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .accessibilityAction(.escape) { gemeinsam.sheet = nil }
                    .transition(.outPoint(BadgeOrigin.point))
            }

            if let alt = gemeinsam.lastLeave {
                ReturnPathStrip(name: alt.name) { gemeinsam.againJoin() }
                    .transition(.opacity)
            } else if let error = gemeinsam.error, !gemeinsam.inPlayer {
                // In the player it shows the strip itself.
                HintStrip(text: error) { gemeinsam.error = nil }
            }
        }
        .animation(Theme.spring, value: selectionOpen)
        .animation(Theme.reveal, value: gemeinsam.lastLeave?.id)
        .animation(Theme.reveal, value: gemeinsam.error)
        .onChange(of: gemeinsam.createFor?.id) { _, new in
            guard new != nil, let title = gemeinsam.createFor else {
                createOn = false
                return
            }
            createTitle = title
            name = String(localized: "Filmabend")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                createOn = gemeinsam.createFor != nil
            }
        }
        .onChange(of: gemeinsam.sheet) { _, new in
            guard case let .join(g)? = new else {
                joinOn = false
                return
            }
            joinGroup = g
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                if case .join? = gemeinsam.sheet { joinOn = true }
            }
        }
    }

    // MARK: Create

    private var createOpen: Binding<Bool> {
        Binding(get: { createOn },
                set: { if !$0 { createOn = false; gemeinsam.createFor = nil; taps = false } })
    }

    @ViewBuilder private var create: some View {
        SheetCategory(text: Text("Gemeinsam schauen"))
        if let title = createTitle {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: SharedModel.titleLine(title))
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, -10)
                    .padding(.bottom, 16)
                Text("Name der Gruppe")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.bottom, 6)
                TextField(text: $name) { Text("Filmabend") }
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.font)
                    .focused($taps)
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                Text("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                Button {
                    taps = false
                    Task { await gemeinsam.create(name: name, title: title) }
                } label: {
                    Text("Gruppe öffnen")
                }
                .buttonStyle(PrimaryButtonStyle(lockedArea: Theme.raised))
                .disabled(gemeinsam.works)
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.bottom, 12)
        }
        SheetLine()
        SheetCancel { gemeinsam.createFor = nil; taps = false }
    }

    // MARK: Join

    private var joinOpen: Binding<Bool> {
        Binding(get: { joinOn },
                set: { if !$0 { joinOn = false; gemeinsam.sheet = nil } })
    }

    @ViewBuilder private var join: some View {
        if let g = joinGroup {
            SheetCategory(text: Text(verbatim: g.name))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: SharedModel.wer(g))
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, -10)
                if let condition = SharedModel.stateTextOf(g.condition) {
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
                Button {
                    Task { await gemeinsam.join(g) }
                } label: {
                    Text("Beitreten")
                }
                .buttonStyle(PrimaryButtonStyle(lockedArea: Theme.raised))
                .disabled(gemeinsam.works)
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.bottom, 12)
        }
        SheetLine()
        SheetCancel { gemeinsam.sheet = nil }
    }

    // MARK: Selection

    private var selectionOpen: Bool { gemeinsam.sheet == .pick }

    @ViewBuilder private var pick: some View {
        SheetCategory(text: Text("Läuft gerade"))
        ForEach(takeover) { s in
            SheetLine()
            row(symbol: s.devicesCharacter,
                  title: s.deviceName ?? String(localized: "Gerät"),
                  under: s.titleLine,
                  action: Text("Hier weiterschauen")) {
                gemeinsam.sheet = nil
                continueWatching(s)
            }
        }
        ForEach(gemeinsam.group == nil ? gemeinsam.offerings : []) { g in
            SheetLine()
            row(symbol: "person.2.fill", title: g.name, under: SharedModel.wer(g),
                  action: Text("Beitreten")) {
                Task { await gemeinsam.join(g) }
            }
        }
        SheetLine()
        SheetCancel { gemeinsam.sheet = nil }
    }

    private func row(symbol: String, title: String, under: String, action: Text,
                       perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(Theme.listTitle)
                        .foregroundStyle(Theme.font)
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
            .padding(.horizontal, Theme.edgeSpacing)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
    }
}

/// "Left movie night - Rejoin": undo instead of a confirmation.
struct ReturnPathStrip: View {
    let name: String
    let join: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Text("\(name) verlassen")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                Button(action: join) {
                    Text("Wieder beitreten")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .background(Theme.area, in: Capsule())
            // **Same spot as any notice** (`Hinweisstreifen`):
            // 34 above the bottom edge, 24 from the side. It used 96 - the
            // strip hung in the lower third.
            .padding(.bottom, 34)
            .padding(.horizontal, 24)
        }
    }
}

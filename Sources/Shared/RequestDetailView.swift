import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **One request opened**: the poster and its state, one card of label/value rows from the core (who asked,
/// which version, quality, folder, seasons, when) and the verbs the core allows this account: "Freigeben",
/// "Ablehnen", "Nochmal", "Zurückziehen".
///
/// It comes in as a whole once the card is read. A verb runs through the flow of the list that opened this, so
/// the list is already right when you go back.
struct RequestDetailView: View {
    let model: AppModel
    let flow: SeerrAdminFlow
    let id: Int64
    /// The list behind this page reads again (a verb changed something).
    var changed: () -> Void = {}

    @Environment(\.dismiss) private var back
    #if os(iOS)
    @Environment(\.wide) private var wide
    #else
    /// The Mac shows the card in a window sheet, Apple TV full screen: one width.
    private let wide = false
    #endif
    @State private var detail: SwiftlyCore.SeerrRequestDetail?
    @State private var settled = false
    @State private var declineOpen = false

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        pageBody
        #endif
    }

    #if !os(tvOS)
    private var pageBody: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                content
                    .opacity(settled ? 1 : 0)
                    .animation(Theme.reveal, value: settled)
            }
            .scrollIndicators(.hidden)
            #if os(macOS)
            .overlay(alignment: .topTrailing) {
                // A native sheet: Esc closes it (cancel action), and so does this button.
                Button { back() } label: {
                    Image(icon: "xmark", size: 12).font(.app(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.fontQuiet)
                        .frame(width: 28, height: 28)
                        .background(Theme.groupsArea, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(Theme.PressButton())
                .keyboardShortcut(.cancelAction)
                .padding(12)
                .accessibilityLabel(Text("Schließen"))
                .accessibilityIdentifier("detail-close")
            }
            #else
            .fadingUnderSubpageHeader(title: detail?.row.title ?? String(localized: "Anfrage")) { back() }
            #endif

            DeclineSheet(opened: $declineOpen, title: detail?.row.title ?? "") {
                Task { await act { await flow.decline(id) } }
            }
            .zIndex(20)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task {
            await flow.attach(model)
            detail = await flow.detail(id)
            settled = true
        }
    }

    @ViewBuilder private var content: some View {
        if let detail {
            let row = detail.row
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Picture(url: row.poster.flatMap { URL(string: $0) }, corner: Theme.cornerTile)
                        .frame(width: 80, height: 120)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: row.title).growing(20, .bold).lineLimit(3)
                        Text(verbatim: kind(row)).growing(13).foregroundStyle(Theme.fontVeryQuiet)
                        HStack(spacing: 6) {
                            Image(icon: row.badge.symbol, size: 12)
                                .font(.app(size: 12, weight: .semibold))
                                .accessibilityHidden(true)
                            Text(verbatim: row.badge.line).growing(14, .medium)
                        }
                        .foregroundStyle(row.badge.kind.tint)
                        .padding(.top, 2)
                        if let progress = row.badge.progress {
                            ProgressBar(share: Double(progress), round: true).padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .accessibilityElement(children: .combine)

                if !detail.rows.isEmpty {
                    CardView {
                        ForEach(Array(detail.rows.enumerated()), id: \.offset) { pair in
                            if pair.offset > 0 { SheetLine().padding(.leading, 16) }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(verbatim: pair.element.label)
                                    .font(.app(size: 15))
                                    .foregroundStyle(Theme.fontQuiet)
                                Spacer(minLength: 8)
                                Text(verbatim: pair.element.value)
                                    .font(.app(size: 15))
                                    .foregroundStyle(Theme.font)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                verbs(row)
            }
            .padding(.bottom, 40)
            #if os(macOS)
            .padding(.top, 36)
            #endif
            .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if settled {
            EmptyState(symbol: "wifi.slash", headerLine: "Seerr antwortet gerade nicht",
                       text: "Diese Anfrage lässt sich gerade nicht lesen.")
                .frame(minHeight: 420)
        }
    }

    @ViewBuilder private func verbs(_ row: SwiftlyCore.SeerrRequestRow) -> some View {
        VStack(spacing: 10) {
            if row.work == .working {
                Text(verbatim: row.workText ?? "")
                    .font(.app(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            if row.canApprove {
                Button { Task { await act { await flow.approve(id) } } } label: { Text("Freigeben") }
                    .buttonStyle(PrimaryButtonStyle(stretches: true))
                    .accessibilityIdentifier("detail-approve")
            }
            if row.canRetry {
                Button { Task { await act { await flow.retry(id) } } } label: { Text("Nochmal") }
                    .buttonStyle(PrimaryButtonStyle(stretches: true))
            }
            if row.canDecline {
                Button { declineOpen = true } label: { Text("Ablehnen") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("detail-decline")
            }
            if row.canWithdraw {
                Button {
                    Task {
                        await act { await flow.withdraw(id) }
                        back()
                    }
                } label: { Text("Zurückziehen") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
    }
    #endif

    /// Runs a verb, reads the card again and tells the list.
    private func act(_ verb: () async -> Void) async {
        #if !os(tvOS)
        Theme.jerk(.medium)
        #endif
        await verb()
        detail = await flow.detail(id) ?? detail
        changed()
    }

    private func kind(_ row: SwiftlyCore.SeerrRequestRow) -> String {
        let art = row.art == "tv" ? String(localized: "Serie") : String(localized: "Film")
        return [art, row.detail].compactMap { $0 }.joined(separator: " · ")
    }
}

#if os(tvOS)
/// Apple TV: the same card, full screen and in large type. The poster and the state stand left, the core's rows and
/// the verbs right; every verb is a focusable button, "Ablehnen" asks once in the TV action panel. Menu closes it.
extension RequestDetailView {
    var tvBody: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            tvContent
                .opacity(settled ? 1 : 0)
                .animation(Theme.reveal, value: settled)
            if declineOpen, let row = detail?.row {
                TVAskLayer(heading: "Anfrage ablehnen?", subject: row.title,
                           sentence: "Wer sie gestellt hat, sieht nur „Abgelehnt“.", actions: [
                    TitleAction(symbol: "xmark", text: "Ablehnen", cautionary: true) {
                        Task { await act { await flow.decline(id) } }
                    },
                    TitleAction(symbol: "arrow.uturn.backward", text: "Abbrechen") {},
                ], start: 1) { declineOpen = false }
            }
        }
        .animation(Theme.focusAnimation, value: declineOpen)
        .accessibilityIdentifier("request-detail")
        .task {
            await flow.attach(model)
            detail = await flow.detail(id)
            settled = true
        }
    }

    @ViewBuilder private var tvContent: some View {
        if let detail {
            let row = detail.row
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 20) {
                    Picture(url: row.poster.flatMap { URL(string: $0) }, width: 300, height: 450, symbolText: "film")
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: row.title).font(Theme.titleLarge).foregroundStyle(Theme.font).lineLimit(2)
                        Text(verbatim: kind(row)).font(Theme.body).foregroundStyle(Theme.fontVeryQuiet)
                        Text(verbatim: row.badge.line).font(Theme.rail).foregroundStyle(row.badge.kind.tint).lineLimit(2)
                        if let progress = row.badge.progress {
                            ProgressBar(share: Double(progress)).frame(width: 420).padding(.top, 6)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    VStack(spacing: 0) {
                        ForEach(Array(detail.rows.enumerated()), id: \.offset) { pair in
                            if pair.offset > 0 { SheetLine() }
                            HStack(alignment: .firstTextBaseline, spacing: 24) {
                                Text(verbatim: pair.element.label).font(Theme.body).foregroundStyle(Theme.fontQuiet)
                                Spacer(minLength: 16)
                                Text(verbatim: pair.element.value).font(Theme.body).foregroundStyle(Theme.font)
                                    .multilineTextAlignment(.trailing).lineLimit(2)
                            }
                            .padding(.vertical, 14)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    if row.work == .working {
                        Text(verbatim: row.workText ?? "").font(Theme.body).foregroundStyle(Theme.accent)
                    }
                    tvVerbs(row)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.edgePage)
            .padding(.top, Theme.edgeTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(declineOpen)
        } else if settled {
            EmptyState(symbol: "wifi.slash", title: "Seerr antwortet gerade nicht",
                       hint: "Diese Anfrage lässt sich gerade nicht lesen.")
        }
    }

    private func tvVerbs(_ row: SwiftlyCore.SeerrRequestRow) -> some View {
        HStack(spacing: 24) {
            if row.canApprove {
                Button { Task { await act { await flow.approve(id) } } } label: { Text("Freigeben") }
                    .buttonStyle(ThemedButtonStyle())
                    .accessibilityIdentifier("detail-approve")
            }
            if row.canRetry {
                Button { Task { await act { await flow.retry(id) } } } label: { Text("Nochmal") }
                    .buttonStyle(ThemedButtonStyle())
            }
            if row.canDecline {
                Button { declineOpen = true } label: { Text("Ablehnen") }
                    .buttonStyle(ThemedButtonStyle())
                    .accessibilityIdentifier("detail-decline")
            }
            if row.canWithdraw {
                Button {
                    Task {
                        await act { await flow.withdraw(id) }
                        back()
                    }
                } label: { Text("Zurückziehen") }
                    .buttonStyle(ThemedButtonStyle())
            }
        }
        .focusSection()
    }
}
#endif

import JellyfinKit
import SwiftUI

// **Support on the profile page** (design v6 "Mix", board 2): the looks card at the top,
// the support status under it, and the pop-up on the first visit.

/// **"Make Swiftly yours": glass over the page's glow, a fan of icons, the way to the
/// looks.** The whole card is the button.
struct SupportLooksCard: View {
    var body: some View {
        Button { SupportFlow.shared.openLooks() } label: {
            VStack(alignment: .leading, spacing: 0) {
                IconFan()
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wähl deinen Look")
                        .growing(20, .semibold)
                        .tracking(-0.2)
                        .foregroundStyle(Theme.font)
                    Text("Looks und Icons für alle, die Swiftly am Laufen halten.")
                        .growing(13)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("Look ausprobieren")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .accessibilityHidden(true)
                    }
                    .growing(14, .semibold)
                    .foregroundStyle(Theme.font)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .glassPill()
                    .padding(.top, 10)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // **Dark glass without a live blur.** Translucent, so the glow behind it shows at
            // the top, dark below that, with a light edge at the top. A material here
            // redrew the blur on every frame of the icon animation.
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.10).opacity(0.62), Color(white: 0.07).opacity(0.9)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Theme.font.opacity(0.14), Theme.font.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// **Five icons in a fan, bobbing gently; the middle one gets a white ring now and then**
/// (the design's `bob` and `pick`).
///
/// Plain repeating animations of offset and opacity on each icon, nothing that rebuilds
/// the whole fan each frame (it used to be a 30 fps `TimelineView`).
private struct IconFan: View {
    private static let icons: [(name: String, turn: Double, drop: CGFloat, size: CGFloat, delay: Double)] = [
        ("LookFan-Sunset", -10, 12, 60, 0),
        ("LookIcon-NeonNight", -4, 4, 60, 0.3),
        ("LookIcon-Original", 0, 0, 70, 0.6),
        ("LookFan-Aurora", 4, 4, 60, 0.9),
        ("LookFan-Gold", 10, 12, 60, 1.2),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: -10) {
            ForEach(Self.icons.indices, id: \.self) { index in
                let icon = Self.icons[index]
                BobbingIcon(name: icon.name, size: icon.size, turn: icon.turn, delay: icon.delay,
                            picks: index == 2)
                    .offset(y: icon.drop)
                    .zIndex(index == 2 ? 2 : 0)
            }
        }
        .padding(.top, 22)
        .frame(height: 104, alignment: .top)
        .accessibilityHidden(true)
    }
}

private struct BobbingIcon: View {
    let name: String
    let size: CGFloat
    let turn: Double
    let delay: Double
    let picks: Bool
    @State private var up = false

    var body: some View {
        Image(name)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if picks, !Theme.motionReduced {
                    // pick: off, then on from 70 to 92 percent of a 4.8 s cycle.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.font, lineWidth: 2)
                        .padding(-4)
                        .keyframeAnimator(initialValue: 0.0, repeating: true) { ring, value in
                            ring.opacity(value)
                        } keyframes: { _ in
                            KeyframeTrack {
                                LinearKeyframe(0.0, duration: 2.98)
                                LinearKeyframe(1.0, duration: 0.38)
                                LinearKeyframe(1.0, duration: 1.06)
                                LinearKeyframe(0.0, duration: 0.38)
                            }
                        }
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
            .rotationEffect(.degrees(turn))
            .offset(y: up ? -3 : 0)
            .onAppear {
                guard !Theme.motionReduced else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(delay)) { up = true }
            }
    }
}

/// **What kind of supporter you are**, only for supporters.
struct SupportStatusCard: View {
    var body: some View {
        let support = SupportModel.shared
        if support.isSupporter {
            HStack(spacing: 14) {
                Image(systemName: support.plan == .tip ? "cup.and.saucer.fill" : "heart.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        RadialGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.06)],
                                       center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 26),
                        in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .growing(17, .semibold)
                        .foregroundStyle(Theme.font)
                    Text(detail(since: support.supporterSince ?? .now))
                        .growing(13)
                        .foregroundStyle(Theme.fontQuiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
                    .fill(Theme.groupsArea)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
                            .fill(RadialGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0)],
                                                 center: .topLeading, startRadius: 0, endRadius: 220))
                    }
            }
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }

    private var title: String {
        switch SupportModel.shared.plan {
        case .monthly: String(localized: "Monatlich dabei")
        case .tip: String(localized: "Danke für den Kaffee")
        default: String(localized: "Unterstützer für immer")
        }
    }

    private func detail(since: Date) -> String {
        let day = since.formatted(.dateTime.day().month(.wide).year())
        switch SupportModel.shared.plan {
        case .monthly:
            let support = SupportModel.shared
            guard let renewsOn = support.renewsOn else {
                return String(localized: "Unterstützer seit \(day). Danke, dass du dabeibleibst.")
            }
            let date = renewsOn.formatted(.dateTime.day().month(.wide))
            if support.autoRenews == false {
                return String(localized: "Läuft bis zum \(date). Danach verlängert sich nichts, deine Extras gehen zurück auf Standard.")
            }
            if let price = support.price(.monthly) {
                return String(localized: "Verlängert sich am \(date) für \(price). Danke, dass du dabeibleibst.")
            }
            return String(localized: "Verlängert sich am \(date). Danke, dass du dabeibleibst.")
        case .tip:
            return String(localized: "Unterstützer seit \(day). Noch ein Trinkgeld freut uns immer, erwartet wird keins.")
        default:
            return String(localized: "Seit \(day). Nichts verlängert sich, deine Extras bleiben.")
        }
    }
}

// MARK: - First visit

extension View {
    /// **Once, on the first visit to the profile:** what Swiftly costs (nothing) and how it
    /// stays that way. The one ask this page shows by itself.
    func supportProfileIntro() -> some View {
        modifier(SupportProfileIntro())
    }
}

private struct SupportProfileIntro: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            // **The app's own flush sheet**, like every sheet that is not full height: a system
            // sheet of this height floats above the bottom edge in iOS 26, with the page
            // showing below it.
            .sheet(opened: $shown) {
                ProfileIntroPanel {
                    shown = false
                    SupportModel.shared.open()
                } later: {
                    shown = false
                }
            }
            .task {
                // Once, and only for someone who does not support yet.
                guard !UserDefaults.standard.bool(forKey: SupportLinks.profileIntroKey),
                      !SupportModel.shared.isSupporter else { return }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, !SupportModel.shared.isSupporter else { return }
                UserDefaults.standard.set(true, forKey: SupportLinks.profileIntroKey)
                shown = true
            }
    }
}

private struct ProfileIntroPanel: View {
    let look: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent)
                .frame(width: 60, height: 60)
                .background(
                    RadialGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.06)],
                                   center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 36),
                    in: Circle())
                .accessibilityHidden(true)
            Text("Swiftly ist kostenlos.\nSo bleibt es dabei.")
                .growing(22, .semibold)
                .tracking(-0.3)
                .foregroundStyle(Theme.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Keine Werbung, kein Tracking, kein Konto bei uns. Swiftly entsteht offen, und wer es mag, legt etwas dazu, damit es weiterwachsen kann.")
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                fact("checkmark", accent: false, Text("Jede Funktion bleibt kostenlos, für alle."))
                fact("sparkle", accent: true, Text("Wer unterstützt, bekommt ein paar persönliche Extras als Dankeschön."))
                fact("heart.fill", accent: false, Text("Wann du magst: übers Herz auf der Startseite oder in den Einstellungen."))
            }
            .padding(.top, 4)
            VStack(spacing: 10) {
                Button(action: look) { Text("Schau's dir an") }
                    .buttonStyle(PrimaryButtonStyle())
                Button(SupportCopy.notNow.localized, action: later)
                    .buttonStyle(SecondaryButtonStyle(area: Theme.raised))
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, Theme.sheetInset)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            Button(action: later) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(width: 30, height: 30)
                    .background(Theme.raised, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            .padding(.trailing, 8)
            .padding(.top, 8)
            .accessibilityLabel(Text("Schließen"))
        }
    }

    private func fact(_ symbol: String, accent: Bool, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent ? Theme.accent : Theme.font)
                .frame(width: 32, height: 32)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            text
                .growing(15)
                .foregroundStyle(Theme.font)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
    }
}

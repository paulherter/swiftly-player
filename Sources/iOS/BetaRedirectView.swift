#if BETA_REDIRECT
import SwiftUI

/// The only screen of the "move to the App Store" build for TestFlight testers.
///
/// Compiled in only with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) BETA_REDIRECT'`
/// on the command line; the repo never sets the flag. `SwiftlyApp` shows this
/// instead of `RootView`, so no model, no network, no sign-in and no player
/// exists in this build.
struct BetaRedirectView: View {
    @Environment(\.openURL) private var openURL

    private let storeURL = URL(string: "https://apps.apple.com/app/id6806824067")!

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                Image("AppIconPreview-Standard")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityHidden(true)
                Text("Swiftly gibt es jetzt im App Store")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.font)
                    .multilineTextAlignment(.center)
                Text("Diese Testversion wird nicht mehr aktualisiert. Lade Swiftly bitte aus dem App Store und lösche vorher diese Testversion. Bald öffnen wir ein neues TestFlight für alle, die wirklich Beta-Versionen testen wollen.")
                    .font(.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    openURL(storeURL)
                } label: {
                    Text("App Store öffnen")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .preferredColorScheme(.dark)
    }
}
#endif

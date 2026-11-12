import Foundation
import JellyfinKit

// MARK: - Signing in at Emby and Plex
//
// **What the finished pages call, and the network work behind it.**
//
// `EmbySignInModel` and `PlexSignInModel` (SignInModels.swift) only hold what the screen
// shows and a set of closures; this file fills the closures. The result of both flows is
// the account the core saved, handed to ``accountAdded()``: from there on it is an
// ordinary account, in the bundle of its kind.

/// What a flow holds between its steps, so the model stays a plain value holder.
@MainActor
private final class EmbyHeld {
    var server: (any MediaServer)?
}

extension AppModel {

    /// **Signing in plays the same overlay as the switch in the profile**: the
    /// page slides away, the new account's picture flies to the corner, the rows
    /// come in afterwards. `adopt` is what actually takes the account in; it runs
    /// at the point where the switch would happen, 0.3 s before the picture rests.
    ///
    /// The picture starts in the middle of the window since a sign-in has no
    /// circle to lift it from. Without a known corner yet (the very first sign-in,
    /// no home page was ever shown) it stays with the page sliding away.
    func signInTransition(_ s: Session, adopt: @escaping () -> Void) {
        let transition = AccountSwitchTransition.shared
        guard !transition.waits, let size = AccountSwitchStage.windowSize,
              size.width > 0, size.height > 0 else {
            adopt()
            return
        }
        let side: CGFloat = 96
        let from = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                          width: side, height: side)
        let address = userImageURL(for: s)
        let withoutImage = address.map { ImageCache.shared.image($0) == nil } ?? true
        transition.start(
            account: s.accountKey,
            image: ProfileCharacter(name: s.userName, image: address, size: side * 1.06,
                                    withoutImage: withoutImage),
            // Clear: there is no circle on the snapshot that would need covering.
            from: from, area: .clear, address: address, switchTo: adopt)
    }

    // MARK: Emby

    /// - Parameters:
    ///   - address: a server already in the set; the page then goes straight to sign-in.
    ///   - finished: the account is in; the caller leaves the page.
    ///   - back: the arrow on the address step.
    ///   - useJellyfin: only offered when an address answers as Jellyfin.
    func embySignInModel(address: String? = nil, finished: @escaping () -> Void,
                         back: @escaping () -> Void,
                         useJellyfin: ((String) -> Void)? = nil) -> EmbySignInModel {
        let model = EmbySignInModel()
        let held = EmbyHeld()
        model.actions.cancel = back
        model.actions.useJellyfin = useJellyfin
        model.actions.check = { [weak self, weak model] raw, headers in
            guard let self, let model else { return }
            Task { await self.embyCheck(raw, headers: headers, model: model, held: held) }
        }
        model.actions.signIn = { [weak self, weak model] user, password in
            guard let self, let model else { return }
            Task {
                await self.embySignIn(user: user, password: password, model: model, held: held,
                                      finished: finished)
            }
        }
        if let address {
            model.address = address
            Task { await embyCheck(address, headers: [], model: model, held: held) }
        }
        return model
    }

    private func embyCheck(_ raw: String, headers: [OwnHeader], model: EmbySignInModel,
                           held: EmbyHeld) async {
        model.checking = true
        model.problem = nil
        defer { model.checking = false }
        // The HTTP client reads the app's header table, so the new headers go in before the core asks.
        let new = OwnHeaders.cleaned(headers)
        let target = Self.normalizeServerURL(raw)
        let before = target.map { OwnHeaders.registered(for: $0) } ?? []
        if let target, !new.isEmpty { OwnHeaders.setDown(new, for: target) }
        let found = await AccountsHost.shared.embyCheck(raw)
        func undo() { if let target, !new.isEmpty { OwnHeaders.setDown(before, for: target) } }
        guard let found else { undo(); model.problem = .unreachable(address: raw); return }
        switch found.result {
        case "ok":
            guard let address = URL(string: found.adresse), let client = Self.makeServer(kind: .emby, baseURL: address) else {
                undo(); model.problem = .unreachable(address: raw); return
            }
            // The core may have used the other scheme: the headers belong to the address that answered.
            if address != target { undo(); if !new.isEmpty { OwnHeaders.setDown(new, for: address) } }
            if !new.isEmpty { ownHeadersSafe(new, for: address) }
            held.server = client
            model.address = found.adresse
            model.users = nil
            model.step = .signIn(serverName: found.name, version: found.version)
            model.users = found.konten.map { EmbyUserChoice(id: $0.id, name: $0.name, image: $0.image.flatMap(URL.init(string:))) }
        case "notEmby":
            undo()
            model.problem = .notEmby(kindFound: ServerKind.jellyfin.displayName)
        case "badAddress":
            undo()
            model.problem = .other(String(localized: "Die Adresse konnte nicht gelesen werden."))
        case "other":
            undo()
            model.problem = .other(found.message ?? readable(JellyfinError.notAuthenticated))
        default:
            undo()
            model.problem = .unreachable(address: raw)
        }
    }

    private func embySignIn(user: String, password: String, model: EmbySignInModel,
                            held: EmbyHeld, finished: () -> Void) async {
        guard let client = held.server else { return }
        model.signingIn = true
        model.signInError = nil
        defer { model.signingIn = false }
        do {
            try await AccountsHost.shared.signIn(
                address: client.baseURL, kind: .emby, user: user, password: password)
            accountAdded()
            finished()
        } catch {
            model.signInError = readable(error)
        }
    }

    // MARK: Plex

    /// - Parameters:
    ///   - finished: the account is in; the caller leaves the page.
    ///   - back: the arrow at the top when there is no earlier step.
    func plexSignInModel(finished: @escaping () -> Void,
                         back: @escaping () -> Void) -> PlexSignInModel {
        let model = PlexSignInModel()
        guard let flow = try? AccountsHost.shared.plexSignIn() else {
            model.step = .failed(.plexUnreachable)
            model.actions.cancel = back
            return model
        }
        // Everything the actions need, once, so each closure stays one line.
        let run = PlexRun(app: self, model: model, flow: flow, finished: finished)

        model.actions.start = { Task { await run.start() } }
        model.actions.browserClosed = { _ in Task { await run.pollOnce() } }
        model.actions.pickProfile = { p in Task { await run.pickProfile(p) } }
        model.actions.submitPin = { p, pin in Task { await run.submitPin(p, pin: pin) } }
        model.actions.pickServer = { s in Task { await run.pickServer(s) } }
        model.actions.reloadServers = { Task { await run.loadServers() } }
        model.actions.otherAccount = { run.otherAccount() }
        model.actions.cancel = { run.stop(); back() }
        return model
    }
}

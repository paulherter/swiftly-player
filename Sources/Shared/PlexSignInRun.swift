import Foundation
import JellyfinKit
import SwiftlyCore

// MARK: - The Plex steps

/// The Plex flow as one object, so the closures of the model hold it (and through it the
/// app) for as long as the page lives. The steps run in the core (`PlexSignIn`): the code, the wait for
/// the confirmation, the account and its profiles, the servers, the address that answers, and saving
/// the account; this object only turns the answers into the page's states.
@MainActor
final class PlexRun {
    let app: AppModel
    let model: PlexSignInModel
    let flow: PlexSignIn
    let finished: () -> Void
    private var polling: Task<Void, Never>?
    /// The timer and a closing browser window can both see the token; one wins.
    private var handled = false
    /// What the open page shows: the address and, on the TV, the short code.
    private var prompt: (url: URL, code: String?)?

    init(app: AppModel, model: PlexSignInModel, flow: PlexSignIn, finished: @escaping () -> Void) {
        self.app = app; self.model = model; self.flow = flow; self.finished = finished
    }

    func stop() { polling?.cancel(); polling = nil }

    // MARK: Browser sign-in

    func start() async {
        stop()
        handled = false
        model.step = .opening
        do {
            #if os(tvOS)
            // The TV has no browser: a short code the person types at plex.tv/link on
            // another device, shown next to a QR code of that page.
            let pin = try await flow.start(strong: false)
            let url = pin.linkUrl.flatMap(URL.init(string:))
            let code: String? = pin.code
            #else
            let pin = try await flow.start(strong: true)
            let url = URL(string: pin.plainAuthUrl)
            // The code of the browser sign-in is long and not made for typing; only the
            // countdown is shown. On the TV the code is the short one and is the point.
            let code: String? = nil
            #endif
            guard let url else { throw PlexError.pinExpired }
            prompt = (url, code)
            model.step = .waiting(prompting(seconds: Int(pin.seconds)))
            polling = Task { [weak self] in await self?.poll() }
        } catch {
            fail(error)
        }
    }

    // No forwardUrl: plex.tv documents https addresses there, and with a custom scheme
    // the page was seen landing on the Watch start page. The poll sees the token anyway.

    private func prompting(seconds: Int) -> PlexPinPrompt {
        let held = prompt
        return PlexPinPrompt(
            url: held?.url ?? URL(fileURLWithPath: "/"), callbackScheme: "swiftly", code: held?.code,
            secondsLeft: max(seconds, 0))
    }

    /// About once a second until the token is there or the code is gone (the core's loop).
    private func poll() async {
        let rest = PlexRest { [weak self] seconds in
            Task { @MainActor in
                guard let self, !self.handled, case .waiting = self.model.step, self.prompt != nil else { return }
                self.model.step = .waiting(self.prompting(seconds: Int(seconds)))
            }
        }
        do {
            switch try await flow.waitForToken(listener: rest) {
            case .token: await signedIn()
            case .expired: model.step = .failed(.expired)
            case .failed(let message):
                model.step = .failed(flow.lastFailureUnreachable() ? .plexUnreachable : .other(message))
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    /// The browser window closed: look right now instead of waiting for the next beat.
    func pollOnce() async {
        guard case .waiting = model.step else { return }
        if let found = try? await flow.checkNow(), found { await signedIn() }
    }

    // MARK: After the token

    private func signedIn() async {
        guard !handled else { return }
        handled = true
        // Not `stop()`: when the timer's own task got us here, cancelling it would cancel
        // the requests below. The loop ends by itself once `handled` is set.
        polling = nil
        model.step = .loading(.profiles)
        do {
            guard case .ready(let info) = try await flow.loadAccount() else { throw PlexError.pinExpired }
            model.account = info.name
            if info.profiles.count > 1 {
                let choices = info.profiles.map {
                    PlexProfileChoice(
                        id: $0.id, name: $0.name, image: $0.image.flatMap(URL.init(string:)),
                        protected: $0.protected)
                }
                model.lastProfiles = choices
                model.step = .profiles(choices)
            } else {
                model.step = .loading(.servers)
                await loadServers()
            }
        } catch {
            fail(error)
        }
    }

    func pickProfile(_ choice: PlexProfileChoice) async {
        if choice.protected { model.pinWrong = false; model.step = .pin(choice); return }
        await switchTo(choice, pin: nil)
    }

    func submitPin(_ choice: PlexProfileChoice, pin: String) async {
        model.pinChecking = true
        model.pinWrong = false
        await switchTo(choice, pin: pin)
        model.pinChecking = false
    }

    private func switchTo(_ choice: PlexProfileChoice, pin: String?) async {
        do {
            switch try await flow.pickProfile(id: choice.id, pin: pin) {
            case .accepted:
                model.profile = choice
                model.step = .loading(.servers)
                await loadServers()
            case .pinWrong:
                // A wrong PIN stays on the PIN page; an unprotected profile that is refused
                // has nothing to retry, so it goes back to the list.
                if pin != nil { model.pinWrong = true } else { fail(PlexError.profilePinWrong) }
            }
        } catch {
            fail(error)
        }
    }

    // MARK: Servers

    func loadServers() async {
        model.step = .loading(.servers)
        model.unreachable = []
        do {
            let found = try await flow.servers()
            model.step = .servers(found.map {
                PlexServerChoice(id: $0.id, name: $0.name, sharedBy: $0.sharedBy, local: $0.local, online: $0.online)
            })
        } catch {
            fail(error)
        }
    }

    func pickServer(_ choice: PlexServerChoice) async {
        guard model.connecting == nil else { return }
        model.connecting = choice.id
        model.unreachable.remove(choice.id)
        defer { model.connecting = nil }
        do {
            // The core picks the address that answers, signs in at that server and saves the account.
            switch try await flow.connect(serverId: choice.id) {
            case .connected:
                app.accountAdded()
                finished()
            case .unreachable:
                model.unreachable.insert(choice.id)
            }
        } catch {
            model.unreachable.insert(choice.id)
        }
    }

    func otherAccount() {
        stop()
        flow.reset()
        prompt = nil
        model.account = nil
        model.profile = nil
        model.lastProfiles = nil
        model.step = .start
    }

    // MARK: Errors

    /// The sentences are in `DESIGN-AUSWAHL.md`: plex.tv gone, code expired, anything else
    /// with its own words.
    private func fail(_ error: any Error) {
        stop()
        if let plex = error as? PlexError {
            switch plex {
            case .pinExpired: model.step = .failed(.expired)
            default: model.step = .failed(.other(app.readable(error)))
            }
            return
        }
        if flow.lastFailureUnreachable() {
            model.step = .failed(.plexUnreachable)
            return
        }
        if case CoreError.Failed(let message) = error {
            model.step = .failed(.other(message))
            return
        }
        model.step = .failed(.other(app.readable(error)))
    }
}

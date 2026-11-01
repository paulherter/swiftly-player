import CGtk
import Foundation
import JellyfinKit

/// **The Jellyfin servers on the local network**, under the address on the sign-in
/// page and in "Server hinzufügen", as on every other platform.
///
/// The search is in the package (``ServerDiscovery``). One loop serves both pages and
/// asks the network only while one of the lists is on screen: the window lives as long
/// as the program, the sign-in page mostly hidden behind the library.
extension App {
    func serverSearchStart() {
        guard serverSearchRun == nil else { return }
        serverSearchRun = Task.detached { [self] in
            while !Task.isCancelled {
                let visible = await withCheckedContinuation { done in
                    onMainThread { done.resume(returning: self.foundListShown) }
                }
                if visible {
                    let round = await ServerDiscovery.search()
                    onMainThread {
                        let now = ServerDiscovery.merged(self.foundServers, round)
                        guard now != self.foundServers else { return }
                        self.foundServers = now
                        self.foundServersFill()
                    }
                }
                try? await Task.sleep(for: visible ? ServerDiscovery.pause : .seconds(2))
            }
        }
    }

    private var foundListShown: Bool {
        [foundOnLogin, foundOnOnboarding].contains { list in
            list.map { gtk_widget_get_mapped($0) != 0 } ?? false
        }
    }

    /// Both lists anew from ``foundServers``. Nothing while none has answered, so a
    /// network without a server shows the page as before.
    func foundServersFill() {
        if let list = foundOnLogin {
            fill(list, ServerDiscovery.shown(foundServers, except: [])) { [weak self] server in
                guard let self else { return }
                gtk_editable_set_text(OpaquePointer(self.serverField), server.address)
                self.linkUp()
            }
        }
        if let list = foundOnOnboarding {
            let known = bundle?.server.map(\.absoluteString) ?? []
            fill(list, ServerDiscovery.shown(foundServers, except: known)) { [weak self] server in
                guard let self else { return }
                self.serverOnboardingHeaders = []
                self.serverCheck(server.address)
            }
        }
    }

    private func fill(_ list: Widget!, _ found: [FoundServer], pick: @escaping (FoundServer) -> Void) {
        wipe(list)
        guard !found.isEmpty else { return }
        let group = settingGroup(translated("Im Netzwerk gefunden"))
        for (i, server) in found.enumerated() {
            if i > 0 { append(group.space, rowsLine()) }
            append(group.space, valuesRow(symbol: "network-server-symbolic", title: server.name,
                                          under: server.shortAddress, arrow: true) { pick(server) })
        }
        append(list, group.outer)
    }
}

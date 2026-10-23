import CGtk
import Foundation
import JellyfinKit

/// **Video playlists: the tile in "Wiedergabelisten" and the page behind it.**
///
/// Ported from `Sources/macOS/PlaylistPage.swift`. The entries stand in the playlist's order
/// (the server keeps it); sorting or filtering would undo what someone arranged, so there are
/// neither. Back arrow in the bar, name and count, "Abspielen", then the grid. "Abspielen" starts
/// the first entry; the player's "Nächste Folge" then walks along the list (``shuffleRun``).
extension App {

    // MARK: Tile in the Movies / Series grid

    /// Same tile as a collection; under the name the number of entries in this area.
    func playlistTile(_ list: VideoPlaylist, art genre: String) -> Widget! {
        let item = list.item
        let (cage, image) = framedImage(width: Theme.tileWidth, height: Theme.tileHeight,
                                        style: "swiftly-plakat")
        if item.imageTags?["Primary"] != nil,
           let address = addresses.flatMap({ ImageSelection.portrait(item, addresses: $0,
                                                    maxHeight: Scaling.requestEdge(Theme.tileHeight)) }) {
            imageLoad(image, url: address, key: ImageKey.of(address),
                      border: Scaling.imageEdge(Theme.tileHeight))
        } else {
            characterPut(cage, series: genre == "tvshows")
        }
        let bottom = String(format: translated("%lld Titel"), list.count(art: genre))
        let tile = tileWrapper(image: cage, width: Theme.tileWidth,
                               top: item.name, bottom: bottom) { [weak self] in
            self?.playlistOpen(item, art: genre)
        }
        gtk_widget_set_halign(tile, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(tile, GTK_ALIGN_START)
        return tile
    }

    // MARK: Opening

    /// Pushes the playlist onto the stack of the visible area. `art`: its movies or its
    /// episodes; `nil`: everything in it.
    func playlistOpen(_ list: Item, art: String?) {
        playlistArt[section.identifier + "|" + list.id] = art ?? ""
        pagesStack[section, default: []].append(list)
        detailShow(list)
    }

    // MARK: Page

    func playlistPageShow(_ list: Item, push: Push) {
        detailTouched = false
        sections = []
        let disc = nextDisc()
        let art = playlistArt[section.identifier + "|" + list.id].flatMap { $0.isEmpty ? nil : $0 }

        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        var figure: Widget!, title: Widget!, serverRow: Widget!
        append(block, pageHeader(list.name, figure: &figure, titleField: &title,
                                 serverField: &serverRow, withServer: false))

        let play = primaryButton(translated("Abspielen"), symbol: "media-playback-start-symbolic")
        gtk_widget_set_size_request(play, 200, Int32(Theme.primaryButtonHeight))
        gtk_widget_set_halign(play, GTK_ALIGN_START)
        gtk_widget_set_margin_top(play, 14)
        gtk_widget_set_sensitive(play, 0)
        append(block, play)

        let grid = gridBuild()
        gtk_widget_set_margin_top(grid, 22)
        append(block, grid)
        let state = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_visible(state, 0)
        append(block, state)

        let bar = stateBar(pagesFrame(block), title: list.name, back: { [weak self] in self?.back() })
        append(disc, bar.wrapper)

        // The entries arrive afterwards; the page is built, the button waits.
        let shown = PlaylistEntries()
        signal(play, "clicked") { [weak self] in
            guard let self, let first = self.playlistStart(shown.items) else { return }
            self.launch(first)
        }
        let load: () -> Void = { [weak self] in
            guard let self, let client = self.client else { return }
            let gridHeld = held(grid), playHeld = held(play), figureHeld = held(figure)
            let stateHeld = held(state)
            Task.detached { [self] in
                let found = try? await client.playlistEntries(list.id)
                onMainThread {
                    defer { letGo(gridHeld); letGo(playHeld); letGo(figureHeld); letGo(stateHeld) }
                    guard let grid = gridHeld.widget, let play = playHeld.widget,
                          let figure = figureHeld.widget, let state = stateHeld.widget else { return }
                    wipe(state)
                    guard let found else {
                        append(state, self.disturbState(top: 80, retry: { [weak self] in
                            self?.playlistPageShow(list, push: .fade)
                        }))
                        gtk_widget_set_visible(state, 1)
                        return
                    }
                    let items = VideoPlaylist.shown(found, art: art)
                    shown.items = items
                    self.gridFill(grid, items)
                    gtk_widget_set_sensitive(play, items.isEmpty ? 0 : 1)
                    gtk_label_set_text(OpaquePointer(figure), String(items.count))
                    gtk_widget_set_visible(figure, items.isEmpty ? 0 : 1)
                    if items.isEmpty {
                        append(state, self.emptyState("mail-inbox-symbolic", translated("Hier ist noch nichts"),
                                                      translated("Sobald in dieser Wiedergabeliste etwas liegt, taucht es hier auf."),
                                                      top: 80))
                        gtk_widget_set_visible(state, 1)
                    } else {
                        gtk_widget_set_visible(state, 0)
                    }
                }
            }
        }
        load()
        shove(toward: disc, bearing: push)
    }

    /// Starts a playlist: the entries in their order are the run, and "Nächste Folge" in the
    /// player walks along it, movies and episodes alike. Returns the first entry.
    func playlistStart(_ entries: [Item]) -> Item? {
        guard let first = entries.first else { return nil }
        shuffleRun = ShuffleRun(episodes: entries)
        return first
    }
}

/// Lets the click closure see the entries once they have arrived (main thread only).
final class PlaylistEntries: @unchecked Sendable {
    var items: [Item] = []
}

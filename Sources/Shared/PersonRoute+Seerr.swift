import Foundation
import JellyfinKit
import SwiftlyCore

extension PersonRoute {
    /// The one open-person intent of a Seerr cast tile: the core (`seerrCastPerson`) turns the tapped tile into what the
    /// person page opens with, the same page a library cast tile ends on.
    init(seerrCast cast: SwiftlyCore.SeerrCast, origin: String?) {
        let info = SwiftlyCore.seerrCastPerson(cast: cast)
        self.init(
            person: Person(id: info.id, name: info.name, role: info.role, type: info.kind),
            origin: origin,
            seerr: info.tmdb.map { SeerrPersonRef(tmdb: $0, portrait: info.imageUrl.flatMap { URL(string: $0) }) })
    }
}

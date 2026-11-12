import Foundation

/// **How the core numbers the subtitle tracks an engine lists.** Embedded tracks keep the server's `Index`. An external
/// subtitle file (not in the container, handed to the engine at load) is `externalBase + its position in the list handed
/// over` (`PlayerStart.externalTrackIdBase`): the core selects it by that number (`Command::SelectSubtitle`) and only when the
/// engine's `tracks` event lists it. A host that listed the file under its server index never got the file selected.
public enum CoreTrackIDs {
    public static let externalBase: Int64 = 1000

    public static func external(position: Int) -> Int64 { externalBase + Int64(position) }

    /// The position in the external list, or `nil` for an embedded track's server index.
    public static func externalPosition(of id: Int64) -> Int? {
        id >= externalBase ? Int(id - externalBase) : nil
    }
}

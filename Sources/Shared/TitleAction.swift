import JellyfinKit
import SwiftUI

/// An action a sheet offers: icon, label, what it does.
///
/// Deliberately **not** in `ActionSheet`. There it was tied as
/// `ActionSheet.Handlung` to a component that exists only on iPhone, so TV
/// and Mac could not build the same lists although the actions themselves are
/// the same everywhere: "play from start", "reset progress", "refresh metadata".
///
/// How the list **looks** is up to the platform. iPhone shows it as a bottom
/// sheet, TV will do something else. What it contains is the same question.
struct TitleAction: Identifiable {
    let id = UUID()
    let symbol: String
    let text: LocalizedStringKey
    /// Uses the warning colour instead of the text colour - for anything that
    /// deletes or discards.
    var cautionary = false
    let perform: () -> Void

    /// **Verbatim, not looked up** - for names from the server. A library named
    /// "Filme" would be searched in the catalog as a `LocalizedStringKey` and
    /// become "Movies" in English.
    var wording: String?

    init(symbol: String, text: LocalizedStringKey, cautionary: Bool = false,
         perform: @escaping () -> Void) {
        self.symbol = symbol
        self.text = text
        self.cautionary = cautionary
        self.perform = perform
    }

    init(symbol: String, wording: String, perform: @escaping () -> Void) {
        self.symbol = symbol
        self.text = LocalizedStringKey(wording)
        self.wording = wording
        self.perform = perform
    }

    /// What every presentation shows: the wording, if there is one.
    var label: Text {
        wording.map { Text(verbatim: $0) } ?? Text(text)
    }
}

/// **What VoiceOver says for a tile** - the same sentence on all three Apple
/// platforms.
///
/// Before, the tile only read the name. For an episode that is the episode
/// title while the tile shows the series name, and the abbreviation
/// "S1 - E3" would be read as "S1 bullet E3". A movie's year was in the
/// picture but not in the announcement.
extension Item {
    /// Title line of an episode tile in the player's episode strip (tvOS, iPhone,
    /// iPad): "F3 · Name" ("E3" in English).
    var stripHeaderLine: String {
        guard let number = indexNumber else { return name }
        return String(localized: "F\(number)") + " · " + name
    }

    /// "52 Min", and where something is started, the remainder behind it.
    var stripDurationLine: String? {
        var parts: [String] = []
        if DisplayRules.runtimeShow(seconds: runtimeSeconds), let seconds = runtimeSeconds {
            parts.append(String(localized: "\(Int(seconds / 60)) Min."))
        }
        // "Watched" shows as a check mark in the image, not as a word.
        if let rest = remainingTimeText { parts.append(rest) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var tileAnnouncement: String {
        var parts: [String] = []
        if type == "Episode" {
            parts.append(seriesName ?? name)
            if let season = parentIndexNumber, let episode = indexNumber {
                parts.append(String(localized: "Staffel \(season), Folge \(episode)"))
            }
            if seriesName != nil, !name.isEmpty { parts.append(name) }
        } else {
            parts.append(name)
            if let year = productionYear { parts.append(String(year)) }
        }
        return parts.joined(separator: ", ")
    }

    /// A tile's state as a value: watched, or how far. Only from one percent -
    /// "zero percent watched" tells nothing.
    var tileState: String {
        if userData?.played == true { return String(localized: "Gesehen") }
        if let share = watchedShare {
            return String(localized: "\(Int(share * 100)) Prozent gesehen")
        }
        return ""
    }
}

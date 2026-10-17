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

/// **Start the trailer - in one place, not two.**
///
/// The body was word for word in `BrowseViews` and `SeriesView`; the only
/// difference was the variable name (`current` vs `series`).
/// `find-duplicates.sh` flagged it at 97 percent.
///
/// It cannot go into the package: it depends on `AppModel`, `PlayRequest`,
/// `UIApplication` and `String(localized:)`. So it lives here, next to
/// ``Titelhandlungen`` - which already takes its callbacks the same way.
@MainActor
enum TrailerStart {

    /// Server trailer first, then the linked one.
    ///
    /// If it is a file, it plays in the app's own player - with Direct Play like
    /// everything else. Otherwise only the linked URL remains, which on Jellyfin
    /// almost always leads to YouTube; only the browser can open that.
    static func start(_ title: Item, model: AppModel,
                        play: @escaping (PlayRequest) -> Void,
                        report: @escaping (String) -> Void) {
        Task {
            if let film = await model.trailer(toward: title),
               let plan = await model.plan(for: film.id) {
                play(PlayRequest(item: film, plan: plan, startAt: 0))
                return
            }
            #if os(iOS)
            if let address = title.remoteTrailers?.compactMap(\.url).first,
               let target = URL(string: address) {
                await UIApplication.shared.open(target)
                return
            }
            #endif
            report(String(localized: "Für diesen Titel liegt kein Trailer vor."))
        }
    }
}

/// Which actions a title offers.
///
/// The lists existed four times: movie and series, each once on phone and once
/// on TV. TV copied them because it must not touch shared logic yet still
/// needed the list.
///
/// **What is here is the question: which entries exist and when.** How the
/// list looks is up to the platform - bottom sheet on the phone, a panel at
/// the trigger on large screens.
///
/// The view passes in the callbacks: only it knows how playing, reporting and
/// refreshing work in its context.
///
/// `auffrischen` only where the view does not already react to
/// `pagesRefresh`: `setWatched` bumps the watched counter and thereby
/// reloads it anyway - a second call loaded it twice.
@MainActor
enum TitleActions {

    /// For a movie.
    ///
    /// `gemeinsam` exists only where watching together is possible
    /// (so far iPhone and iPad); if absent, the entry is absent.
    static func forMovie(_ title: Item, plan: PlaybackPlan?, model: AppModel,
                         start: @escaping (Double) -> Void,
                         report: @escaping (String) -> Void,
                         refresh: (() async -> Void)? = nil,
                         gemeinsam: (() -> Void)? = nil) -> [TitleAction] {
        var list: [TitleAction] = []
        // Only if there is anything to reset: "from start" on a movie still at
        // zero is a row with no effect.
        if plan != nil, title.resumeFrom != nil {
            list.append(.init(symbol: "gobackward", text: "Von vorn abspielen") {
                start(0)
            })
            list.append(.init(symbol: "arrow.counterclockwise.circle",
                               text: "Fortschritt zurücksetzen") {
                Task {
                    if let reason = await model.setWatched(title, an: false) {
                        report(reason)
                        return
                    }
                    report(String(localized: "Der Fortschritt ist zurückgesetzt."))
                    await refresh?()
                }
            })
        }
        if plan != nil, let gemeinsam {
            list.append(sharedWatch(gemeinsam))
        }
        list.append(metadata(title, model: model, report: report))
        return list
    }

    /// For a series.
    ///
    /// `state` is the episode at which the server sees the viewer;
    /// `season` the currently selected season.
    static func forSeries(_ series: Item, state: Item?, season: Item?, model: AppModel,
                          episodeStart: @escaping (Item, Double) -> Void,
                          report: @escaping (String) -> Void,
                          refresh: (() async -> Void)? = nil,
                          gemeinsam: ((Item) -> Void)? = nil) -> [TitleAction] {
        var list: [TitleAction] = []
        if let state {
            list.append(.init(symbol: "gobackward", text: "Folge von vorn abspielen") {
                episodeStart(state, 0)
            })
            // **On iPhone and iPad "Next episode" gives way to "Watch
            // together"**. The sheet should not get longer, and the next
            // episode is reachable through the list as well.
            if let gemeinsam {
                list.append(sharedWatch { gemeinsam(state) })
            } else {
            list.append(.init(symbol: "forward.end.alt", text: "Nächste Folge abspielen") {
                Task {
                    guard let next = await model.episodePost(state) else {
                        report(String(localized: "Danach kommt nichts mehr."))
                        return
                    }
                    episodeStart(next, 0)
                }
            })
            }
        }
        if let season {
            list.append(.init(symbol: "checkmark.circle",
                               text: "\(season.name) als gesehen") {
                Task {
                    if let reason = await model.setWatched(season, an: true) {
                        report(reason)
                        return
                    }
                    report(String(localized: "\(season.name) ist als gesehen vermerkt."))
                    await refresh?()
                }
            })
        }
        list.append(metadata(series, model: model, report: report))
        return list
    }

    private static func sharedWatch(_ perform: @escaping () -> Void) -> TitleAction {
        .init(symbol: "person.2", text: "Gemeinsam schauen", perform: perform)
    }

    /// Sits under both lists, so it lives here once.
    private static func metadata(_ title: Item, model: AppModel,
                                  report: @escaping (String) -> Void) -> TitleAction {
        .init(symbol: "arrow.clockwise", text: "Metadaten neu einlesen") {
            Task { report(await model.metadataRefresh(title)) }
        }
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

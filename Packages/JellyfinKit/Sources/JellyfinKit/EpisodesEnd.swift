import Foundation

/// When an episode counts as "finished", and what happens then.
///
/// Two questions that are easily confused: when the **button** appears, and when
/// playback **advances by itself**. One is an offer, the other an action.
///
/// The rules lived in two places (iPhone and TV). They agreed apart from the
/// comparisons (`>` vs `>=`), which is harmless on its own. Merging them
/// anticipates a bug rather than fixing one: two copies of the same question
/// drift apart over time.
///
/// The iPhone version is authoritative; the numbers were worked out there.
public enum EpisodeEnd {

    /// Below this runtime nothing is checked.
    ///
    /// Otherwise the button would practically always be on screen for an intro or a
    /// short extra; at five minutes the last two and a half would already be "near
    /// the end".
    public static let minRuntime: Double = 300

    /// From here an episode counts as nearly done: two and a half minutes before
    /// the end or at 96 percent, whichever comes first.
    public static let secondsLeft: Double = 150
    public static let share: Double = 0.96

    /// Whether the "Next episode" button is offered.
    ///
    /// An offer, not an action, so generously sized. Otherwise it would be in the
    /// way for two hours in a two-hour film.
    public static func buttonShow(position: Double, duration: Double) -> Bool {
        guard duration > minRuntime else { return false }
        return (duration - position) <= secondsLeft || (position / duration) >= share
    }

    /// How long after opening playback does not advance by itself.
    ///
    /// **Without this grace period a freshly opened stream advances immediately.**
    /// An episode opened with `:start-time=3721` reported position 3721 s at once,
    /// while the length was not yet reliable in the same milliseconds. So
    /// `position >= dauer - 1` was true and the next episode started 629 ms after
    /// opening.
    /// The grace period is right even without a start seek: an episode that is
    /// just opening is not finished. Nobody loses anything or notices the delay,
    /// while the case it prevents costs the whole episode.
    public static let rampUpIdle: Double = 5

    /// Is playback at the end of the file? Same limit as
    /// ``advance(position:dauer:sinceOpen:cardCounts:)``.
    public static func atEnd(position: Double, duration: Double) -> Bool {
        duration > 60 && position >= duration - 1
    }

    /// Whether playback advances to the next episode by itself.
    ///
    /// Much narrower than the button: this acts without being asked. Only when
    /// nothing more is coming, and no earlier than ``anlaufruhe`` seconds after
    /// opening.
    ///
    /// **`cardCounts`**: if the card is counting down its countdown, advancing
    /// belongs to it. A seek to the end satisfies `position >= dauer - 1`
    /// immediately; without this condition the player would switch in the same
    /// tick, before the card even appeared.
    public static func advance(position: Double, duration: Double,
                                      sinceOpen: Double, cardCounts: Bool = false) -> Bool {
        guard !cardCounts else { return false }
        guard sinceOpen > rampUpIdle else { return false }
        guard duration > 60 else { return false }
        return position >= duration - 1
    }
}

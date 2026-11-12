//! Where a `swiftly://` link goes once the app has it, as one explicit state machine (`reduce`): the Mac family opens
//! `titel/<id>` as a title page on Start and `abspielen/<id>` as playback from the remembered position, always from a
//! fresh read of the title (`Sources/tvOS/MainView.swift`, `onOpenURL`). All transitions live in [`reduce`]; the suite
//! only runs the [`Action`] it returns.

use crate::deep_link::DeepLink;

/// A title as the link router needs it: what the fresh server read said.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Found {
    /// Server id.
    pub id: String,
    /// Display name (the title page's heading while it loads).
    pub title: String,
    /// Item type (`Movie`, `Series`, `Episode`...), empty when unknown.
    pub kind: String,
}

impl Found {
    /// Whether the title plays itself (a series, season or folder opens its page instead).
    fn plays(&self) -> bool {
        matches!(
            self.kind.to_ascii_lowercase().as_str(),
            "movie" | "episode" | "video" | "musicvideo" | ""
        )
    }
}

/// What a link is doing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkState {
    /// Nothing pending.
    Idle,
    /// Arrived before an account is signed in: kept until the sign-in is done.
    WaitingForAccount(DeepLink),
    /// The title is being read from the server; `play` asks for playback instead of the page.
    Fetching {
        /// The title id from the link.
        id: String,
        /// Play it (else show its page).
        play: bool,
    },
}

/// What happens to the state machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// A link came in (command line, second launch).
    Arrived(DeepLink),
    /// The tick of the app: tells whether an account is signed in and whether a player is open.
    Tick,
    /// The fresh read of the title finished (`None`: not found or the server did not answer).
    Fetched(Option<Found>),
}

/// What the suite does next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// Nothing.
    None,
    /// Read the title `id` from the server, then send [`Event::Fetched`].
    Fetch(String),
    /// Play `id` from the server's resume position.
    Play(String),
    /// Push the title page of `Found` on Start.
    Show(Found),
    /// Back to Start (no page pushed).
    Home,
    /// The settings page.
    Settings,
    /// The search tab with this text.
    Search(String),
}

/// The outside world the machine looks at.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ctx {
    /// An account is signed in.
    pub signed_in: bool,
    /// The player is open or starting: a link must not swap the film under the viewer's eyes.
    pub player_busy: bool,
}

/// The one transition function.
#[must_use]
pub fn reduce(state: LinkState, ctx: Ctx, event: Event) -> (LinkState, Action) {
    match (state, event) {
        // The player has the screen: a new link is dropped (the window still comes to the front).
        (s, Event::Arrived(_)) if ctx.player_busy => (s, Action::None),
        (_, Event::Arrived(link)) if !ctx.signed_in => {
            (LinkState::WaitingForAccount(link), Action::None)
        }
        (_, Event::Arrived(link)) => start(link),
        (LinkState::WaitingForAccount(link), Event::Tick) if ctx.signed_in => start(link),
        (LinkState::Fetching { id, play }, Event::Fetched(Some(found)))
            if found.id == id || id.is_empty() =>
        {
            if ctx.player_busy {
                (LinkState::Idle, Action::None)
            } else if play && found.plays() {
                (LinkState::Idle, Action::Play(found.id))
            } else {
                (LinkState::Idle, Action::Show(found))
            }
        }
        // Not found, a stale answer or an answer nobody asked for: back to rest.
        (LinkState::Fetching { .. }, Event::Fetched(_)) => (LinkState::Idle, Action::None),
        (s, Event::Fetched(_) | Event::Tick) => (s, Action::None),
    }
}

fn start(link: DeepLink) -> (LinkState, Action) {
    match link {
        DeepLink::Title(id) => (
            LinkState::Fetching {
                id: id.clone(),
                play: false,
            },
            Action::Fetch(id),
        ),
        DeepLink::Play(id) => (
            LinkState::Fetching {
                id: id.clone(),
                play: true,
            },
            Action::Fetch(id),
        ),
        DeepLink::Search(q) => (LinkState::Idle, Action::Search(q)),
        DeepLink::Settings => (LinkState::Idle, Action::Settings),
        DeepLink::Home => (LinkState::Idle, Action::Home),
    }
}

impl Found {
    /// Whether the page for it is the series page.
    #[must_use]
    pub fn series_page(&self) -> bool {
        self.kind.eq_ignore_ascii_case("series")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const IN: Ctx = Ctx {
        signed_in: true,
        player_busy: false,
    };
    const OUT: Ctx = Ctx {
        signed_in: false,
        player_busy: false,
    };
    const BUSY: Ctx = Ctx {
        signed_in: true,
        player_busy: true,
    };

    fn found(kind: &str) -> Found {
        Found {
            id: "a1".into(),
            title: "T".into(),
            kind: kind.into(),
        }
    }

    #[test]
    fn a_title_link_fetches_then_shows_the_page() {
        let (s, a) = reduce(
            LinkState::Idle,
            IN,
            Event::Arrived(DeepLink::Title("a1".into())),
        );
        assert_eq!(
            (&s, &a),
            (
                &LinkState::Fetching {
                    id: "a1".into(),
                    play: false
                },
                &Action::Fetch("a1".into())
            )
        );
        let (s, a) = reduce(s, IN, Event::Fetched(Some(found("Movie"))));
        assert_eq!((s, a), (LinkState::Idle, Action::Show(found("Movie"))));
    }

    #[test]
    fn a_play_link_plays_a_film_and_opens_the_page_of_a_series() {
        let (s, _) = reduce(
            LinkState::Idle,
            IN,
            Event::Arrived(DeepLink::Play("a1".into())),
        );
        assert_eq!(
            reduce(s.clone(), IN, Event::Fetched(Some(found("Movie")))),
            (LinkState::Idle, Action::Play("a1".into()))
        );
        assert_eq!(
            reduce(s.clone(), IN, Event::Fetched(Some(found("Episode")))),
            (LinkState::Idle, Action::Play("a1".into()))
        );
        assert_eq!(
            reduce(s, IN, Event::Fetched(Some(found("Series")))),
            (LinkState::Idle, Action::Show(found("Series")))
        );
    }

    #[test]
    fn a_link_before_the_sign_in_waits_for_it() {
        let (s, a) = reduce(
            LinkState::Idle,
            OUT,
            Event::Arrived(DeepLink::Play("a1".into())),
        );
        assert_eq!(
            (&s, &a),
            (
                &LinkState::WaitingForAccount(DeepLink::Play("a1".into())),
                &Action::None
            )
        );
        assert_eq!(
            reduce(s.clone(), OUT, Event::Tick),
            (s.clone(), Action::None)
        );
        let (s2, a2) = reduce(s, IN, Event::Tick);
        assert_eq!(
            (s2, a2),
            (
                LinkState::Fetching {
                    id: "a1".into(),
                    play: true
                },
                Action::Fetch("a1".into())
            )
        );
    }

    #[test]
    fn a_missing_title_or_a_stale_answer_ends_quietly() {
        let f = LinkState::Fetching {
            id: "a1".into(),
            play: true,
        };
        assert_eq!(
            reduce(f.clone(), IN, Event::Fetched(None)),
            (LinkState::Idle, Action::None)
        );
        let other = Found {
            id: "zz".into(),
            ..found("Movie")
        };
        assert_eq!(
            reduce(f, IN, Event::Fetched(Some(other))),
            (LinkState::Idle, Action::None)
        );
        assert_eq!(
            reduce(LinkState::Idle, IN, Event::Fetched(Some(found("Movie")))),
            (LinkState::Idle, Action::None)
        );
    }

    #[test]
    fn an_open_player_keeps_the_film_it_has() {
        assert_eq!(
            reduce(
                LinkState::Idle,
                BUSY,
                Event::Arrived(DeepLink::Play("a1".into()))
            ),
            (LinkState::Idle, Action::None)
        );
        let f = LinkState::Fetching {
            id: "a1".into(),
            play: true,
        };
        assert_eq!(
            reduce(f, BUSY, Event::Fetched(Some(found("Movie")))),
            (LinkState::Idle, Action::None)
        );
    }

    #[test]
    fn a_newer_link_replaces_a_running_fetch() {
        let f = LinkState::Fetching {
            id: "a1".into(),
            play: false,
        };
        let (s, a) = reduce(f, IN, Event::Arrived(DeepLink::Play("b2".into())));
        assert_eq!(
            (s, a),
            (
                LinkState::Fetching {
                    id: "b2".into(),
                    play: true
                },
                Action::Fetch("b2".into())
            )
        );
    }

    #[test]
    fn the_plain_links_act_at_once() {
        assert_eq!(
            reduce(LinkState::Idle, IN, Event::Arrived(DeepLink::Home)).1,
            Action::Home
        );
        assert_eq!(
            reduce(LinkState::Idle, IN, Event::Arrived(DeepLink::Settings)).1,
            Action::Settings
        );
        assert_eq!(
            reduce(
                LinkState::Idle,
                IN,
                Event::Arrived(DeepLink::Search("x".into()))
            )
            .1,
            Action::Search("x".into())
        );
    }

    #[test]
    fn only_a_series_gets_the_series_page() {
        assert!(found("Series").series_page());
        assert!(!found("Movie").series_page());
        assert!(!found("").series_page());
    }
}

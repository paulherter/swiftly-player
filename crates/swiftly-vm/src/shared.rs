//! "Watch together" and "continue here" as one view model (`SharedModel.swift`, `SharedSheets`,
//! `TakeoverModel.swift`, `HandoffStage.swift`): the SyncPlay groups (list, create, join, leave,
//! the current group), the list of other sessions that can be taken over, and the stage of a
//! handoff on the sender and the receiver side.
//!
//! The SyncPlay protocol lives in [`swiftly_sync::SyncPlaySession`] and the takeover rules in
//! `swiftly_playback::takeover`; this model only adds the texts and the parts a view draws.
//! [`SharedVm::apply`] splits the session's effects: status and errors become parts, server calls,
//! player steps and title loads go back to the host.

use swiftly_jellyfin::RemoteSession;
use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_playback::takeover::{
    self, DevicesKind, RemoteSessionExt, TakeoverEvent, TakeoverOffer,
};
use swiftly_sync::syncplay::Phase;
use swiftly_sync::{Effect, SyncPlayError, SyncPlayGroup, SyncPlaySession, SyncPlayStatus};

/// "A, B and C" in the language of the locale (`ListFormatter.localizedString(byJoining:)`).
pub fn join_names(language: &str, names: &[String]) -> String {
    let (and, oxford) = match language {
        "de" => (" und ", false),
        "ru" => (" и ", false),
        "en" => (" and ", true),
        _ => (" & ", false),
    };
    match names {
        [] => String::new(),
        [one] => one.clone(),
        [a, b] => format!("{a}{and}{b}"),
        [init @ .., last] => {
            let comma = if oxford { "," } else { "" };
            format!("{}{comma}{and}{last}", init.join(", "))
        }
    }
}

/// The text of a group's phase (`stateTextOf`); `None` for an empty group.
pub fn phase_text(t: &Translator, phase: Option<Phase>) -> Option<String> {
    Some(t.t(match phase? {
        Phase::Running => "Läuft gerade",
        Phase::Halted => "Angehalten",
        Phase::Waits => "Wartet auf alle",
        Phase::Empty => return None,
    }))
}

/// One group of the list.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupRow {
    /// Group id.
    pub id: String,
    /// Group name.
    pub name: String,
    /// "A und B schauen gerade" (`wer`).
    pub who: String,
    /// The phase in words.
    pub state_text: Option<String>,
}

/// The group the user is in.
#[derive(Debug, Clone, PartialEq)]
pub struct CurrentGroup {
    /// Group id.
    pub id: String,
    /// Group name.
    pub name: String,
    /// "mit A" or "noch niemand dabei" (`withWhom`).
    pub with_whom: String,
    /// The phase in words.
    pub state_text: Option<String>,
}

/// A group with the structured facts a host needs beside the words (Android's old `SharedStatus`).
#[derive(Debug, Clone, PartialEq)]
pub struct GroupDetail {
    /// Group id.
    pub id: String,
    /// Group name.
    pub name: String,
    /// All participants as the server names them (the player's column).
    pub participants: Vec<String>,
    /// Each name once.
    pub names: Vec<String>,
    /// The phase as a code: `laeuft`, `angehalten`, `wartet`; `None` for an empty group.
    pub phase: Option<String>,
}

/// The structured side of [`SharedPart`], additive: everything the old Android JSON carried that the words alone do not.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SharedDetail {
    /// All groups on offer, also while in a group (the sheet's `groups` is empty then).
    pub offerings: Vec<GroupDetail>,
    /// The group the user is in; its phase is the session's phase.
    pub group: Option<GroupDetail>,
    /// Everyone else in the group, once each, without the user.
    pub other: Vec<String>,
    /// What kind of event the notice is: `dabei`, `gegangen`, `wartet`, `angehalten`, `weiter`, `gesprungen`, `warnung`.
    pub notice_kind: Option<String>,
    /// Id of the event (grows with every event).
    pub notice_id: Option<u64>,
    /// The latest error text; stays until the next error, also when the strip is dismissed.
    pub error_last: Option<String>,
    /// Counts the errors.
    pub error_count: u64,
    /// Counts the creates and joins the server accepted.
    pub accepted: u64,
}

/// What the SyncPlay sheet draws.
#[derive(Debug, Clone, PartialEq)]
pub struct SharedPart {
    /// Grows with every change.
    pub version: u64,
    /// The groups to join; empty while in a group.
    pub groups: Vec<GroupRow>,
    /// The account may create a group.
    pub may_create: bool,
    /// The account may join one.
    pub may_join: bool,
    /// The current group.
    pub current: Option<CurrentGroup>,
    /// The short notice of the latest event ("A ist dabei").
    pub notice: Option<String>,
    /// The error, readable.
    pub error: Option<String>,
    /// The channel works.
    pub works: bool,
    /// The title the group watches.
    pub queue_title: Option<String>,
    /// The group last left, for "rejoin".
    pub last_leave: Option<String>,
    /// The structured facts beside the words.
    pub detail: SharedDetail,
}

/// One row of the takeover list.
#[derive(Debug, Clone, PartialEq)]
pub struct TakeoverRow {
    /// Session id.
    pub id: String,
    /// The device's name.
    pub device: String,
    /// What kind of device (for the symbol).
    pub kind: DevicesKind,
    /// "Series · S1E2" or the device's name.
    pub title: String,
}

/// What the takeover card draws.
#[derive(Debug, Clone, PartialEq)]
pub enum TakeoverPart {
    /// Nothing to take over.
    Hidden,
    /// The badge; one device or several.
    Badge {
        /// The offered sessions.
        rows: Vec<TakeoverRow>,
    },
    /// The choice among several.
    Choosing {
        /// The offered sessions.
        rows: Vec<TakeoverRow>,
    },
    /// The takeover runs; the host fetches the position and starts the player.
    Taking {
        /// The chosen session.
        row: TakeoverRow,
    },
    /// It failed.
    Failed {
        /// The message.
        message: String,
    },
}

/// The stage of a handoff (`HandoffStage`, `HandoffCard`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandoffStage {
    /// Nothing happens.
    Idle,
    /// Receiver: the card grows out of the badge, the stream is not ready.
    ReceiverWaiting,
    /// Receiver: the first picture is there; the card zooms to the full picture.
    ReceiverZooming,
    /// Sender: the picture shrinks to the card and flies out.
    SenderLeaving,
}

/// What happens on a handoff.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum HandoffEvent {
    /// The user tapped "continue here" (receiver).
    Tapped,
    /// The first picture is there at this second since the tap (receiver).
    FirstFrame(f64),
    /// Another device took over; this player stops (sender).
    TakenOver,
    /// The stage is torn down.
    Finished,
}

/// The next stage.
pub fn handoff_next(stage: HandoffStage, event: HandoffEvent) -> HandoffStage {
    use HandoffEvent as E;
    use HandoffStage as S;
    match (stage, event) {
        (_, E::Finished) => S::Idle,
        (S::Idle, E::Tapped) => S::ReceiverWaiting,
        (S::ReceiverWaiting, E::FirstFrame(_)) => S::ReceiverZooming,
        (S::Idle, E::TakenOver) => S::SenderLeaving,
        (s, _) => s,
    }
}

/// An action for the SyncPlay sheet.
#[derive(Debug, Clone, PartialEq)]
pub enum SharedIntent {
    /// Load the right and the group list.
    Refresh,
    /// Create a group for the title.
    Create {
        /// The group's name.
        name: String,
        /// The title the group will watch.
        title_id: String,
    },
    /// Join a group of the list.
    Join(String),
    /// Leave the group.
    Leave,
    /// The error strip was dismissed.
    DismissError,
}

/// The shared model.
pub struct SharedVm {
    translator: Translator,
    session: SyncPlaySession,
    me: Option<String>,
    own_device_id: String,
    own_user_id: String,
    offer: TakeoverOffer,
    stage: HandoffStage,
    error: Option<String>,
    error_last: Option<String>,
    error_count: u64,
    accepted: u64,
    part: SharedPart,
    takeover_version: u64,
}

impl SharedVm {
    /// A model for the signed-in user; `me` is the display name excluded from "with whom".
    pub fn new(locale: Locale, me: Option<&str>, own_device_id: &str, own_user_id: &str) -> Self {
        let mut session = SyncPlaySession::new();
        session.set_self_name(me);
        let mut vm = Self {
            translator: Translator::new(locale),
            session,
            me: me.map(Into::into),
            own_device_id: own_device_id.into(),
            own_user_id: own_user_id.into(),
            offer: TakeoverOffer::None,
            stage: HandoffStage::Idle,
            error: None,
            error_last: None,
            error_count: 0,
            accepted: 0,
            part: SharedPart {
                version: 0,
                groups: Vec::new(),
                may_create: true,
                may_join: true,
                current: None,
                notice: None,
                error: None,
                works: false,
                queue_title: None,
                last_leave: None,
                detail: SharedDetail::default(),
            },
            takeover_version: 0,
        };
        vm.refresh_part();
        vm
    }

    /// The protocol session, for the player glue (ticks, control channel, deadlines).
    pub fn session_mut(&mut self) -> &mut SyncPlaySession {
        &mut self.session
    }

    /// What the SyncPlay sheet draws.
    pub fn part(&self) -> &SharedPart {
        &self.part
    }

    /// The stage of the handoff.
    pub fn stage(&self) -> HandoffStage {
        self.stage
    }

    /// Moves the handoff stage.
    pub fn handoff(&mut self, event: HandoffEvent) -> HandoffStage {
        self.stage = handoff_next(self.stage, event);
        self.stage
    }

    fn language(&self) -> String {
        self.translator.locale().language().to_string()
    }

    fn who(&self, g: &SyncPlayGroup) -> String {
        let mut seen = std::collections::HashSet::new();
        let names: Vec<String> = g
            .participant
            .iter()
            .filter(|n| seen.insert((*n).clone()))
            .cloned()
            .collect();
        if names.is_empty() {
            return self.translator.t("Noch niemand dabei");
        }
        let list = join_names(&self.language(), &names);
        let key = if names.len() == 1 {
            "%@ schaut gerade"
        } else {
            "%@ schauen gerade"
        };
        self.translator.t_args(key, &[Arg::Str(list)])
    }

    fn with_whom(&self, g: &SyncPlayGroup) -> String {
        let other = g.other(self.me.as_deref());
        if other.is_empty() {
            return self.translator.t("noch niemand dabei");
        }
        let list = join_names(&self.language(), &other);
        self.translator.t_args("mit %@", &[Arg::Str(list)])
    }

    fn event_text(&self, s: &SyncPlayStatus) -> Option<String> {
        use swiftly_sync::session::EventArt as A;
        let t = &self.translator;
        let e = s.event.as_ref()?;
        Some(match &e.art {
            A::Present(n) => t.t_args("%@ ist dabei", &[Arg::Str(n.clone())]),
            A::Gone(n) => t.t_args("%@ ist gegangen", &[Arg::Str(n.clone())]),
            A::WaitsOnAll => t.t("Wartet auf alle"),
            A::Halted => t.t("Angehalten"),
            A::GoesNext => t.t("Geht weiter"),
            A::Jumped => t.t("Gesprungen"),
            A::NoAccess => t.t("Einem in der Gruppe fehlt dieser Titel."),
            A::NotPlayable => t.t("Der Titel der Gruppe lässt sich hier nicht abspielen."),
        })
    }

    fn detail_of(g: &SyncPlayGroup, phase: Option<Phase>) -> GroupDetail {
        let mut seen = std::collections::HashSet::new();
        GroupDetail {
            id: g.id.clone(),
            name: g.name.clone(),
            participants: g.participant.clone(),
            names: g
                .participant
                .iter()
                .filter(|n| seen.insert((*n).clone()))
                .cloned()
                .collect(),
            phase: match phase {
                Some(Phase::Running) => Some("laeuft".to_owned()),
                Some(Phase::Halted) => Some("angehalten".to_owned()),
                Some(Phase::Waits) => Some("wartet".to_owned()),
                Some(Phase::Empty) | None => None,
            },
        }
    }

    fn notice_kind(s: &SyncPlayStatus) -> Option<String> {
        use swiftly_sync::session::EventArt as A;
        Some(
            match s.event.as_ref()?.art {
                A::Present(_) => "dabei",
                A::Gone(_) => "gegangen",
                A::WaitsOnAll => "wartet",
                A::Halted => "angehalten",
                A::GoesNext => "weiter",
                A::Jumped => "gesprungen",
                A::NoAccess | A::NotPlayable => "warnung",
            }
            .to_owned(),
        )
    }

    /// The server accepted a create or join: the sheet may close (Android: `angenommen`).
    pub fn accepted_mark(&mut self) {
        self.accepted += 1;
        self.refresh_part();
    }

    fn error_text(&self, e: &SyncPlayError) -> String {
        let t = &self.translator;
        match e {
            SyncPlayError::NotReleased => t.t(
                "Gemeinsam schauen ist für dein Konto auf dem Server nicht freigegeben.",
            ),
            SyncPlayError::NoResponse => t.t(
                "Die Gruppe kam nicht zustande: vom Server kam keine Antwort über die Verbindung. Versuch es gleich noch einmal.",
            ),
            SyncPlayError::DoesNotExist => t.t("Diese Gruppe gibt es nicht mehr."),
            SyncPlayError::ConnectionLost => t.t(
                "Die Verbindung zur Gruppe ist abgerissen und ließ sich nicht wiederherstellen. Tritt der Gruppe bitte erneut bei.",
            ),
            SyncPlayError::Other(k) => swiftly_l10n::error_text::readable_error(t, k),
        }
    }

    fn refresh_part(&mut self) {
        let s = self.session.status().clone();
        let t = &self.translator;
        let in_group = s.group.is_some();
        let rows = if in_group {
            Vec::new()
        } else {
            s.offerings
                .iter()
                .map(|g| GroupRow {
                    id: g.id.clone(),
                    name: g.name.clone(),
                    who: self.who(g),
                    state_text: phase_text(t, g.condition),
                })
                .collect()
        };
        let current = s.group.as_ref().map(|g| CurrentGroup {
            id: g.id.clone(),
            name: g.name.clone(),
            with_whom: self.with_whom(g),
            state_text: phase_text(t, s.condition.or(g.condition)),
        });
        let notice = self.event_text(&s);
        let detail = SharedDetail {
            offerings: s
                .offerings
                .iter()
                .map(|g| Self::detail_of(g, g.condition))
                .collect(),
            group: s
                .group
                .as_ref()
                .map(|g| Self::detail_of(g, s.condition.or(g.condition))),
            other: s
                .group
                .as_ref()
                .map(|g| g.other(self.me.as_deref()))
                .unwrap_or_default(),
            notice_kind: Self::notice_kind(&s),
            notice_id: s.event.as_ref().map(|e| e.id),
            error_last: self.error_last.clone(),
            error_count: self.error_count,
            accepted: self.accepted,
        };
        let p = &mut self.part;
        p.detail = detail;
        p.groups = rows;
        p.may_create = s.may_create();
        p.may_join = s.may_join();
        p.current = current;
        p.works = s.works;
        p.queue_title = s.queue_title.clone();
        p.last_leave = s.last_leave.as_ref().map(|g| g.name.clone());
        p.notice = notice;
        p.error = self.error.clone();
        p.version += 1;
    }

    /// Takes the session's effects: status and errors become parts, the rest is for the host.
    pub fn apply(&mut self, effects: Vec<Effect>) -> Vec<Effect> {
        let mut host = Vec::new();
        for e in effects {
            match e {
                Effect::Status(_) => {}
                Effect::Error(err) => {
                    let text = self.error_text(&err);
                    self.error = Some(text.clone());
                    self.error_last = Some(text);
                    self.error_count += 1;
                }
                other => host.push(other),
            }
        }
        self.refresh_part();
        host
    }

    /// An intent of the sheet; returns what the host must run.
    pub fn handle(&mut self, intent: SharedIntent, now: f64) -> Vec<Effect> {
        let effects = match intent {
            SharedIntent::Refresh => {
                let mut e = self.session.right_fetch();
                e.extend(self.session.offerings_ask());
                e
            }
            SharedIntent::Create { name, title_id } => {
                self.error = None;
                self.session.create(&name, &title_id)
            }
            SharedIntent::Join(id) => {
                self.error = None;
                match self
                    .session
                    .status()
                    .offerings
                    .iter()
                    .find(|g| g.id == id)
                    .cloned()
                {
                    Some(g) => self.session.join(&g),
                    None => Vec::new(),
                }
            }
            SharedIntent::Leave => self.session.leave(now),
            SharedIntent::DismissError => {
                self.error = None;
                Vec::new()
            }
        };
        self.apply(effects)
    }

    // MARK: Takeover

    /// A new session list arrived (every few seconds); keeps only what can be taken over.
    pub fn sessions_polled(&mut self, sessions: &[RemoteSession], now: f64) {
        let list: Vec<RemoteSession> =
            takeover::offerings(sessions, &self.own_device_id, &self.own_user_id, now)
                .into_iter()
                .cloned()
                .collect();
        self.takeover_event(TakeoverEvent::Polled(list));
    }

    /// An event of the takeover card (tap, selection, cancel, result).
    pub fn takeover_event(&mut self, event: TakeoverEvent) {
        let old = std::mem::replace(&mut self.offer, TakeoverOffer::None);
        self.offer = takeover::next(old, event);
        self.takeover_version += 1;
    }

    fn row(s: &RemoteSession) -> TakeoverRow {
        TakeoverRow {
            id: s.id.clone(),
            device: s.device_name.clone().unwrap_or_default(),
            kind: s.devices_kind(),
            title: s.title_line(),
        }
    }

    /// What the takeover card draws, with its version.
    pub fn takeover(&self) -> (u64, TakeoverPart) {
        let part = match &self.offer {
            TakeoverOffer::None => TakeoverPart::Hidden,
            TakeoverOffer::Offer(l) => TakeoverPart::Badge {
                rows: l.iter().map(Self::row).collect(),
            },
            TakeoverOffer::Choosing(l) => TakeoverPart::Choosing {
                rows: l.iter().map(Self::row).collect(),
            },
            TakeoverOffer::Taking(s) => TakeoverPart::Taking { row: Self::row(s) },
            TakeoverOffer::Failed(m) => TakeoverPart::Failed { message: m.clone() },
        };
        (self.takeover_version, part)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_sync::{SyncPlayCall, SyncPlayRight};

    fn vm() -> SharedVm {
        SharedVm::new(Locale::parse("de"), Some("Paul"), "dev-1", "u1")
    }

    fn group(id: &str, who: &[&str], phase: Option<Phase>) -> SyncPlayGroup {
        let mut g = SyncPlayGroup::new(id, &format!("Gruppe {id}"));
        g.participant = who.iter().map(|s| (*s).to_string()).collect();
        g.condition = phase;
        g
    }

    fn session_json(
        id: &str,
        device: &str,
        program: &str,
        playing: bool,
        user: &str,
    ) -> RemoteSession {
        let mut v = serde_json::json!({
            "Id": id, "UserId": user, "DeviceId": format!("d-{id}"), "DeviceName": device,
            "Client": program, "SupportsRemoteControl": true,
            "LastActivityDate": "2023-11-14T22:13:00Z",
        });
        if playing {
            v["NowPlayingItem"] =
                serde_json::json!({"Id":"i","Name":"Folge","Type":"Episode","SeriesName":"Serie"});
            v["PlayState"] = serde_json::json!({"IsPaused": false});
        }
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn names_are_joined_the_way_the_language_does() {
        let n = |a: &[&str]| a.iter().map(|s| (*s).to_string()).collect::<Vec<_>>();
        assert_eq!(join_names("de", &n(&["A"])), "A");
        assert_eq!(join_names("de", &n(&["A", "B"])), "A und B");
        assert_eq!(join_names("de", &n(&["A", "B", "C"])), "A, B und C");
        assert_eq!(join_names("en", &n(&["A", "B", "C"])), "A, B, and C");
        assert_eq!(join_names("de", &[]), "");
    }

    #[test]
    fn phase_texts_follow_the_catalog() {
        let t = Translator::new(Locale::parse("de"));
        assert_eq!(
            phase_text(&t, Some(Phase::Running)).as_deref(),
            Some("Läuft gerade")
        );
        assert_eq!(
            phase_text(&t, Some(Phase::Halted)).as_deref(),
            Some("Angehalten")
        );
        assert_eq!(
            phase_text(&t, Some(Phase::Waits)).as_deref(),
            Some("Wartet auf alle")
        );
        assert_eq!(phase_text(&t, Some(Phase::Empty)), None);
        assert_eq!(phase_text(&t, None), None);
    }

    #[test]
    fn refresh_asks_for_the_right_and_the_list_and_shows_the_groups() {
        let mut vm = vm();
        let eff = vm.handle(SharedIntent::Refresh, 0.0);
        let calls: Vec<&SyncPlayCall> = eff
            .iter()
            .filter_map(|e| match e {
                Effect::Api { call, .. } => Some(call),
                _ => None,
            })
            .collect();
        assert!(calls.contains(&&SyncPlayCall::Right) && calls.contains(&&SyncPlayCall::List));
        let e = vm.session_mut().offerings_loaded(vec![
            group("a", &["Ben", "Ben", "Cleo"], Some(Phase::Running)),
            group("b", &[], None),
        ]);
        vm.apply(e);
        let p = vm.part();
        assert_eq!(p.groups.len(), 2);
        assert_eq!(p.groups[0].who, "Ben und Cleo schauen gerade");
        assert_eq!(p.groups[0].state_text.as_deref(), Some("Läuft gerade"));
        assert_eq!(p.groups[1].who, "Noch niemand dabei");
        assert!(p.current.is_none() && p.may_create && p.may_join);
    }

    #[test]
    fn the_detail_carries_names_phase_code_counters_and_the_sticky_error() {
        let mut vm = vm();
        let e = vm.session_mut().offerings_loaded(vec![group(
            "a",
            &["Ben", "Ben", "Cleo"],
            Some(Phase::Waits),
        )]);
        vm.apply(e);
        let d = &vm.part().detail;
        assert_eq!(d.offerings[0].participants, ["Ben", "Ben", "Cleo"]);
        assert_eq!(d.offerings[0].names, ["Ben", "Cleo"]);
        assert_eq!(d.offerings[0].phase.as_deref(), Some("wartet"));
        assert!(d.group.is_none() && d.other.is_empty() && d.notice_kind.is_none());
        vm.apply(vec![Effect::Error(SyncPlayError::DoesNotExist)]);
        vm.handle(SharedIntent::DismissError, 0.0);
        vm.accepted_mark();
        let d = &vm.part().detail;
        assert_eq!((d.error_count, d.accepted), (1, 1));
        assert!(d.error_last.is_some() && vm.part().error.is_none());
    }

    #[test]
    fn the_right_limits_create_and_join() {
        let mut vm = vm();
        let e = vm.session_mut().right_loaded(Some(SyncPlayRight::Join));
        vm.apply(e);
        assert!(!vm.part().may_create && vm.part().may_join);
        let e = vm.session_mut().right_loaded(Some(SyncPlayRight::No));
        vm.apply(e);
        assert!(!vm.part().may_create && !vm.part().may_join);
    }

    #[test]
    fn joining_an_unknown_group_does_nothing_and_a_known_one_calls_the_server() {
        let mut vm = vm();
        assert!(vm.handle(SharedIntent::Join("zz".into()), 0.0).is_empty());
        let e = vm
            .session_mut()
            .offerings_loaded(vec![group("a", &["Ben"], None)]);
        vm.apply(e);
        let eff = vm.handle(SharedIntent::Join("a".into()), 0.0);
        assert!(eff.iter().any(|e| matches!(e, Effect::Api { call: SyncPlayCall::Join { group, .. }, .. } if group == "a")));
    }

    #[test]
    fn create_calls_the_server_and_an_error_is_shown_until_dismissed() {
        let mut vm = vm();
        let eff = vm.handle(
            SharedIntent::Create {
                name: "Abend".into(),
                title_id: "t1".into(),
            },
            0.0,
        );
        assert!(eff.iter().any(|e| matches!(e, Effect::Api { call: SyncPlayCall::Create { name }, .. } if name == "Abend")));
        vm.apply(vec![Effect::Error(SyncPlayError::NotReleased)]);
        assert_eq!(
            vm.part().error.as_deref(),
            Some("Gemeinsam schauen ist für dein Konto auf dem Server nicht freigegeben.")
        );
        vm.handle(SharedIntent::DismissError, 0.0);
        assert!(vm.part().error.is_none());
    }

    #[test]
    fn effects_that_are_not_status_or_error_go_back_to_the_host() {
        let mut vm = vm();
        let out = vm.apply(vec![
            Effect::Error(SyncPlayError::DoesNotExist),
            Effect::LoadTitle {
                title: "t".into(),
                since: 0.0,
            },
        ]);
        assert_eq!(out.len(), 1);
        assert_eq!(
            vm.part().error.as_deref(),
            Some("Diese Gruppe gibt es nicht mehr.")
        );
    }

    #[test]
    fn the_handoff_stage_runs_receiver_and_sender_paths() {
        use HandoffEvent as E;
        use HandoffStage as S;
        assert_eq!(handoff_next(S::Idle, E::Tapped), S::ReceiverWaiting);
        assert_eq!(
            handoff_next(S::ReceiverWaiting, E::FirstFrame(1.2)),
            S::ReceiverZooming
        );
        assert_eq!(handoff_next(S::Idle, E::FirstFrame(1.0)), S::Idle);
        assert_eq!(handoff_next(S::Idle, E::TakenOver), S::SenderLeaving);
        assert_eq!(handoff_next(S::ReceiverZooming, E::Finished), S::Idle);
        let mut vm = vm();
        assert_eq!(vm.handoff(E::TakenOver), S::SenderLeaving);
        assert_eq!(vm.stage(), S::SenderLeaving);
    }

    #[test]
    fn takeover_lists_only_other_playing_devices_of_the_same_user() {
        let mut vm = vm();
        let now = 1_700_000_005.0;
        let sessions = vec![
            session_json("s1", "Wohnzimmer iPad", "Swiftly", true, "u1"),
            session_json("s2", "Küche", "Swiftly", false, "u1"),
            session_json("s3", "Fremd", "Swiftly", true, "u2"),
        ];
        vm.sessions_polled(&sessions, now);
        let (v1, part) = vm.takeover();
        let TakeoverPart::Badge { rows } = part else {
            panic!("badge expected")
        };
        assert_eq!(rows.len(), 1);
        assert_eq!(
            (rows[0].id.as_str(), rows[0].title.as_str()),
            ("s1", "Serie")
        );
        assert_eq!(rows[0].kind, DevicesKind::Tablet);
        // One device: tap goes straight to taking over.
        vm.takeover_event(TakeoverEvent::Tapped);
        assert!(matches!(vm.takeover().1, TakeoverPart::Taking { .. }));
        assert!(vm.takeover().0 > v1);
        vm.takeover_event(TakeoverEvent::Failed("Nein".into()));
        assert_eq!(
            vm.takeover().1,
            TakeoverPart::Failed {
                message: "Nein".into()
            }
        );
        vm.takeover_event(TakeoverEvent::Cancelled);
        assert_eq!(vm.takeover().1, TakeoverPart::Hidden);
        // An empty poll hides the badge.
        vm.sessions_polled(&[], now);
        assert_eq!(vm.takeover().1, TakeoverPart::Hidden);
    }
}

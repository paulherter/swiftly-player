//! **"Problem melden"** as one flow for every host (the Mac's `ReportIssueSheet` + `SeerrReportFlow`): which kind of
//! problem, a few words, the place it is about (title, season, episode, the player's position), and the states
//! editing / sending / sent / failed. The host draws [`ReportInfo`] and forwards presses; the words come from the
//! catalogue. [`SeerrReportFlow`] runs the send through the admin screen of the same hub.
//!
//! Also here: what Seerr adds to a library title's More menu ([`SeerrHub::title_menu`]), so the rule and the words live once.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_l10n::{Arg, Translator};
use swiftly_net::HttpTransport;
use swiftly_seerr::CookieJar;
use swiftly_seerr::issues::IssueKind;

use crate::seerr_admin_io::SeerrAdminScreen;
use crate::seerr_delete::delete_offered;
use crate::seerr_io::SeerrHub;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The title a problem is about, in Seerr's terms: `art` (`movie` / `tv`), the TMDB id, and for an episode the
/// season, number and the player's position ("23:14").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeerrPlace {
    /// `movie` or `tv`.
    pub art: String,
    /// The TMDB id (a series' for an episode).
    pub tmdb: i64,
    /// The title's name (the series' for an episode).
    pub title: String,
    /// Season number, 0 = none.
    pub season: i64,
    /// Episode number, 0 = none.
    pub episode: i64,
    /// The player's position, "23:14".
    pub at: Option<String>,
}

impl SeerrPlace {
    /// A film or a series as a whole.
    pub fn title(art: &str, tmdb: i64, title: &str, seconds: Option<f64>) -> Self {
        Self {
            art: art.to_owned(),
            tmdb,
            title: title.to_owned(),
            season: 0,
            episode: 0,
            at: seconds.map(Self::clock),
        }
    }

    /// An episode of a series (by the series' TMDB id).
    pub fn episode(
        tmdb: i64,
        series: &str,
        season: i64,
        episode: i64,
        seconds: Option<f64>,
    ) -> Self {
        Self {
            art: "tv".to_owned(),
            tmdb,
            title: series.to_owned(),
            season,
            episode,
            at: seconds.map(Self::clock),
        }
    }

    /// "23:14" (minutes can pass 59: the core reads `m:ss`).
    pub fn clock(seconds: f64) -> String {
        let whole = seconds.max(0.0) as i64;
        format!("{}:{:02}", whole / 60, whole % 60)
    }

    /// "Staffel 2 · Folge 3 · bei 23:14" for the sheet's quiet line (`None` for a film without a position).
    pub fn line(&self, t: &Translator) -> Option<String> {
        let mut parts = Vec::new();
        if self.season > 0 {
            parts.push(t.t_args("Staffel %lld", &[Arg::Int(self.season)]));
        }
        if self.episode > 0 {
            parts.push(t.t_args("Folge %lld", &[Arg::Int(self.episode)]));
        }
        if let Some(at) = &self.at {
            parts.push(t.t_args("bei %@", &[Arg::Str(at.clone())]));
        }
        (!parts.is_empty()).then(|| parts.join(" · "))
    }
}

/// The place of a library item (the Mac's `SeerrPlace.of`): a film or series by its own TMDB id (a fresh read when the
/// list left the provider ids out), an episode by its series'. `None` when the title has no TMDB id.
pub async fn place_of_item<T: HttpTransport>(
    client: &swiftly_jellyfin::JellyfinClient<T>,
    item_id: &str,
    seconds: Option<f64>,
) -> Option<SeerrPlace> {
    let item = client.item(item_id).await.ok()?;
    let name = |i: &swiftly_model::Item| i.name.clone();
    match item.type_.as_deref() {
        Some("Movie") => Some(SeerrPlace::title(
            "movie",
            crate::series::tmdb_of(&item)?,
            &name(&item),
            seconds,
        )),
        Some("Series") => Some(SeerrPlace::title(
            "tv",
            crate::series::tmdb_of(&item)?,
            &name(&item),
            None,
        )),
        Some("Episode") => {
            let series = client.item(item.series_id.as_deref()?).await.ok()?;
            Some(SeerrPlace::episode(
                crate::series::tmdb_of(&series)?,
                item.series_name.as_deref().unwrap_or(&series.name),
                item.parent_index_number.unwrap_or(0),
                item.index_number.unwrap_or(0),
                seconds,
            ))
        }
        _ => None,
    }
}

/// Where the report is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReportPhase {
    /// The form is open.
    Editing,
    /// On its way to Seerr.
    Sending,
    /// Seerr took it: "Gemeldet. Danke."
    Sent,
    /// Seerr (or the connection) refused, in Seerr's own words.
    Failed(String),
}

/// One kind of problem as a row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportKindRow {
    /// The kind.
    pub kind: IssueKind,
    /// "Bild", "Ton", "Untertitel", "Sonstiges".
    pub text: String,
    /// This one is chosen.
    pub selected: bool,
}

/// Everything the sheet draws.
#[derive(Debug, Clone, PartialEq)]
pub struct ReportInfo {
    /// A report is open (a place was started).
    pub open: bool,
    /// "Problem melden".
    pub heading: String,
    /// The title the report is about.
    pub title: String,
    /// "Staffel 2 · Folge 3 · bei 23:14".
    pub line: Option<String>,
    /// The four kinds, in the Mac's order.
    pub kinds: Vec<ReportKindRow>,
    /// The few words written so far.
    pub message: String,
    /// "Was stimmt nicht?" (the empty field's hint).
    pub placeholder: String,
    /// The phase.
    pub phase: ReportPhase,
    /// The send button is live (a few words, nothing on its way, nothing sent yet).
    pub can_send: bool,
    /// "Melden", or "Wird gemeldet …" while sending.
    pub send_label: String,
    /// "Gemeldet. Danke." (shown in the `Sent` phase).
    pub sent_text: String,
    /// "Fertig".
    pub done_text: String,
    /// "Abbrechen".
    pub cancel_text: String,
}

/// The pure state of the sheet.
#[derive(Debug, Clone)]
pub struct SeerrReportVm {
    locale: swiftly_l10n::Locale,
    place: Option<SeerrPlace>,
    kind: IssueKind,
    message: String,
    phase: ReportPhase,
}

/// What the send needs, handed out once by [`SeerrReportVm::begin_send`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportSend {
    /// The place.
    pub place: SeerrPlace,
    /// The kind.
    pub kind: IssueKind,
    /// The trimmed words.
    pub message: String,
}

impl SeerrReportVm {
    /// A closed flow in this language.
    pub fn new(locale: swiftly_l10n::Locale) -> Self {
        Self {
            locale,
            place: None,
            kind: IssueKind::Video,
            message: String::new(),
            phase: ReportPhase::Editing,
        }
    }

    /// Starts a fresh report for a place (the sheet opens on it).
    pub fn start(&mut self, place: SeerrPlace) {
        self.place = Some(place);
        self.kind = IssueKind::Video;
        self.message.clear();
        self.phase = ReportPhase::Editing;
    }

    /// Closes the report (the sheet went away).
    pub fn close(&mut self) {
        self.place = None;
        self.message.clear();
        self.phase = ReportPhase::Editing;
    }

    /// The kind chosen. Ignored while sending or once sent.
    pub fn set_kind(&mut self, kind: IssueKind) {
        if self.editable() {
            self.kind = kind;
        }
    }

    /// The words written. Ignored while sending or once sent.
    pub fn set_message(&mut self, text: &str) {
        if self.editable() {
            self.message = text.to_owned();
        }
    }

    fn editable(&self) -> bool {
        self.place.is_some() && matches!(self.phase, ReportPhase::Editing | ReportPhase::Failed(_))
    }

    /// A report needs a few words (the core sends nothing empty) and one send at a time.
    pub fn can_send(&self) -> bool {
        self.editable() && !self.message.trim().is_empty()
    }

    /// The send was pressed: `Some` once (the phase becomes `Sending`), `None` when it is not allowed now.
    pub fn begin_send(&mut self) -> Option<ReportSend> {
        if !self.can_send() {
            return None;
        }
        self.phase = ReportPhase::Sending;
        Some(ReportSend {
            place: self.place.clone()?,
            kind: self.kind,
            message: self.message.trim().to_owned(),
        })
    }

    /// The send came back: `None` = Seerr took it, `Some(text)` = it did not (the form stays, the text shows).
    pub fn finished(&mut self, failure: Option<String>) {
        if self.phase != ReportPhase::Sending {
            return;
        }
        self.phase = failure.map_or(ReportPhase::Sent, ReportPhase::Failed);
    }

    /// The phase.
    pub fn phase(&self) -> &ReportPhase {
        &self.phase
    }

    /// What the sheet draws.
    pub fn info(&self) -> ReportInfo {
        let t = Translator::new(self.locale.clone());
        let kinds = [
            (IssueKind::Video, "Bild"),
            (IssueKind::Audio, "Ton"),
            (IssueKind::Subtitles, "Untertitel"),
            (IssueKind::Other, "Sonstiges"),
        ]
        .into_iter()
        .map(|(kind, key)| ReportKindRow {
            kind,
            text: t.t(key),
            selected: kind == self.kind,
        })
        .collect();
        ReportInfo {
            open: self.place.is_some(),
            heading: t.t("Problem melden"),
            title: self
                .place
                .as_ref()
                .map(|p| p.title.clone())
                .unwrap_or_default(),
            line: self.place.as_ref().and_then(|p| p.line(&t)),
            kinds,
            message: self.message.clone(),
            placeholder: t.t("Was stimmt nicht?"),
            phase: self.phase.clone(),
            can_send: self.can_send(),
            send_label: t.t(if self.phase == ReportPhase::Sending {
                "Wird gemeldet …"
            } else {
                "Melden"
            }),
            sent_text: t.t("Gemeldet. Danke."),
            done_text: t.t("Fertig"),
            cancel_text: t.t("Abbrechen"),
        }
    }
}

/// The flow over a hub: the state plus the send through Seerr.
pub struct SeerrReportFlow<T: HttpTransport, J: CookieJar> {
    admin: Arc<SeerrAdminScreen<T, J>>,
    vm: Mutex<SeerrReportVm>,
}

impl<T: HttpTransport, J: CookieJar> SeerrReportFlow<T, J> {
    /// A closed flow over an admin screen (its hub's language).
    pub fn new(admin: Arc<SeerrAdminScreen<T, J>>, locale: swiftly_l10n::Locale) -> Arc<Self> {
        Arc::new(Self {
            admin,
            vm: Mutex::new(SeerrReportVm::new(locale)),
        })
    }

    /// Starts a fresh report for a place.
    pub fn start(&self, place: SeerrPlace) {
        lock(&self.vm).start(place);
    }

    /// The sheet went away.
    pub fn close(&self) {
        lock(&self.vm).close();
    }

    /// The kind chosen.
    pub fn set_kind(&self, kind: IssueKind) {
        lock(&self.vm).set_kind(kind);
    }

    /// The words written.
    pub fn set_message(&self, text: &str) {
        lock(&self.vm).set_message(text);
    }

    /// What the sheet draws.
    pub fn info(&self) -> ReportInfo {
        lock(&self.vm).info()
    }

    /// Sends the report; returns the phase it ended in. Nothing goes out when sending is not allowed now.
    pub async fn send(&self) -> ReportPhase {
        let Some(send) = lock(&self.vm).begin_send() else {
            return lock(&self.vm).phase().clone();
        };
        let p = send.place;
        let failure = self
            .admin
            .report_issue(
                p.art,
                p.tmdb,
                send.kind,
                send.message,
                p.season,
                p.episode,
                p.at,
            )
            .await;
        let mut vm = lock(&self.vm);
        vm.finished(failure);
        vm.phase().clone()
    }
}

/// What a Seerr entry of the More menu does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TitleMenuKind {
    /// Opens the report sheet ("Problem melden").
    ReportProblem,
    /// Opens the delete flow ("Vom Server löschen").
    DeleteFromServer,
}

/// One Seerr entry of a title's More menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TitleMenuEntry {
    /// What it does.
    pub kind: TitleMenuKind,
    /// The words.
    pub text: String,
}

impl<T: HttpTransport, J: CookieJar> SeerrHub<T, J> {
    /// What Seerr adds to the More menu of a title the own server has: "Problem melden" for an account that may
    /// report, "Vom Server löschen" for one that manages requests (unless this device locked the delete). Empty
    /// without a working connection. Every platform asks here, so the rule and the words live once.
    pub fn title_menu(&self) -> Vec<TitleMenuEntry> {
        if !self.available() {
            return Vec::new();
        }
        let perms = lock(&self.vm).perms();
        let t = Translator::new(self.locale_of());
        let mut out = Vec::new();
        if perms.can_create_issues() {
            out.push(TitleMenuEntry {
                kind: TitleMenuKind::ReportProblem,
                text: t.t("Problem melden"),
            });
        }
        if delete_offered(perms.can_manage_requests()) {
            out.push(TitleMenuEntry {
                kind: TitleMenuKind::DeleteFromServer,
                text: t.t("Vom Server löschen"),
            });
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vm() -> SeerrReportVm {
        SeerrReportVm::new(swiftly_l10n::Locale::parse("de"))
    }

    fn episode() -> SeerrPlace {
        SeerrPlace::episode(1396, "Breaking Bad", 2, 3, Some(1394.0))
    }

    #[test]
    fn the_clock_reads_minutes_and_seconds() {
        assert_eq!(SeerrPlace::clock(1394.0), "23:14");
        assert_eq!(SeerrPlace::clock(3923.0), "65:23");
        assert_eq!(SeerrPlace::clock(-4.0), "0:00");
    }

    #[test]
    fn the_line_names_season_episode_and_position() {
        let t = Translator::new(swiftly_l10n::Locale::parse("de"));
        assert_eq!(
            episode().line(&t).as_deref(),
            Some("Staffel 2 · Folge 3 · bei 23:14")
        );
        assert_eq!(SeerrPlace::title("movie", 1, "Heat", None).line(&t), None);
        assert_eq!(
            SeerrPlace::title("movie", 1, "Heat", Some(61.0))
                .line(&t)
                .as_deref(),
            Some("bei 1:01")
        );
    }

    #[test]
    fn a_fresh_report_is_closed_and_cannot_send() {
        let v = vm();
        assert!(!v.info().open);
        assert!(!v.can_send());
    }

    #[test]
    fn it_needs_a_few_words_before_it_sends() {
        let mut v = vm();
        v.start(episode());
        assert!(v.info().open);
        assert!(!v.can_send());
        v.set_message("   ");
        assert!(!v.can_send());
        assert!(v.begin_send().is_none());
        v.set_message("  Ton läuft versetzt ");
        assert!(v.can_send());
        let send = v.begin_send().expect("sends");
        assert_eq!(send.message, "Ton läuft versetzt");
        assert_eq!(send.kind, IssueKind::Video);
        assert_eq!(send.place.episode, 3);
    }

    #[test]
    fn the_kinds_come_in_the_macs_order_with_the_chosen_one_marked() {
        let mut v = vm();
        v.start(episode());
        v.set_kind(IssueKind::Subtitles);
        let rows = v.info().kinds;
        let texts: Vec<_> = rows.iter().map(|r| r.text.as_str()).collect();
        assert_eq!(texts, ["Bild", "Ton", "Untertitel", "Sonstiges"]);
        assert_eq!(
            rows.iter().map(|r| r.selected).collect::<Vec<_>>(),
            [false, false, true, false]
        );
    }

    #[test]
    fn sending_goes_once_and_a_sent_report_is_final() {
        let mut v = vm();
        v.start(episode());
        v.set_message("Bild ruckelt");
        assert!(v.begin_send().is_some());
        assert_eq!(v.info().send_label, "Wird gemeldet …");
        assert!(v.begin_send().is_none(), "no second send while one is out");
        v.set_message("changed on its way");
        assert_eq!(v.info().message, "Bild ruckelt");
        v.finished(None);
        let info = v.info();
        assert_eq!(info.phase, ReportPhase::Sent);
        assert_eq!(info.sent_text, "Gemeldet. Danke.");
        assert!(!info.can_send);
        v.set_kind(IssueKind::Other);
        assert!(v.info().kinds[0].selected, "sent: nothing changes any more");
    }

    #[test]
    fn a_refusal_keeps_the_form_and_the_words_and_allows_another_try() {
        let mut v = vm();
        v.start(episode());
        v.set_message("kaputt");
        v.begin_send();
        v.finished(Some("Seerr braucht eine neue Anmeldung.".into()));
        assert_eq!(
            v.info().phase,
            ReportPhase::Failed("Seerr braucht eine neue Anmeldung.".into())
        );
        assert_eq!(v.info().message, "kaputt");
        assert!(v.can_send());
        assert!(v.begin_send().is_some());
    }

    #[test]
    fn a_late_answer_without_a_send_changes_nothing() {
        let mut v = vm();
        v.start(episode());
        v.finished(None);
        assert_eq!(v.info().phase, ReportPhase::Editing);
    }

    #[test]
    fn starting_again_begins_empty() {
        let mut v = vm();
        v.start(episode());
        v.set_message("x");
        v.set_kind(IssueKind::Audio);
        v.begin_send();
        v.finished(None);
        v.start(SeerrPlace::title("movie", 5, "Heat", None));
        let info = v.info();
        assert_eq!(info.phase, ReportPhase::Editing);
        assert_eq!(info.message, "");
        assert!(info.kinds[0].selected);
        assert_eq!(info.title, "Heat");
    }

    #[test]
    fn the_english_words_come_from_the_catalogue() {
        let mut v = SeerrReportVm::new(swiftly_l10n::Locale::parse("en"));
        v.start(episode());
        let info = v.info();
        assert_eq!(info.placeholder, "What’s wrong?");
        assert_eq!(info.sent_text, "Reported. Thanks.");
        assert_eq!(
            info.line.as_deref(),
            Some("Season 2 · Episode 3 · at 23:14")
        );
    }
}

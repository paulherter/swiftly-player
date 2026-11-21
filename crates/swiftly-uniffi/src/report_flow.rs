//! "Problem melden" for the hosts that draw the sheet themselves (Android; the iPhone keeps its own flow object for
//! now): the state machine is `swiftly_vm::SeerrReportFlow`, this only exports it.

use std::sync::Arc;

use swiftly_seerr::issues::IssueKind;
use swiftly_vm::{ReportPhase, SeerrPlace};

use crate::error::CoreError;
use crate::seerr::JarAdapter;
use crate::transport::CoreTransport;

/// Where the report is.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ReportIssuePhase {
    /// The form is open.
    Editing,
    /// On its way to Seerr.
    Sending,
    /// Seerr took it ("Gemeldet. Danke.").
    Sent,
    /// Refused, in Seerr's own words.
    Failed {
        /// The text.
        text: String,
    },
}

impl From<ReportPhase> for ReportIssuePhase {
    fn from(p: ReportPhase) -> Self {
        match p {
            ReportPhase::Editing => Self::Editing,
            ReportPhase::Sending => Self::Sending,
            ReportPhase::Sent => Self::Sent,
            ReportPhase::Failed(text) => Self::Failed { text },
        }
    }
}

/// One kind of problem as a row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReportIssueKindRow {
    /// The kind.
    pub kind: IssueKind,
    /// "Bild", "Ton", "Untertitel", "Sonstiges".
    pub text: String,
    /// Chosen.
    pub selected: bool,
}

/// Everything the sheet draws.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ReportIssueInfo {
    /// A report is open.
    pub open: bool,
    /// "Problem melden".
    pub heading: String,
    /// The title.
    pub title: String,
    /// "Staffel 2 · Folge 3 · bei 23:14".
    pub line: Option<String>,
    /// The four kinds.
    pub kinds: Vec<ReportIssueKindRow>,
    /// The words so far.
    pub message: String,
    /// "Was stimmt nicht?".
    pub placeholder: String,
    /// The phase.
    pub phase: ReportIssuePhase,
    /// The send button is live.
    pub can_send: bool,
    /// "Melden" / "Wird gemeldet …".
    pub send_label: String,
    /// "Gemeldet. Danke.".
    pub sent_text: String,
    /// "Fertig".
    pub done_text: String,
    /// "Abbrechen".
    pub cancel_text: String,
}

/// The report flow of one hub.
#[derive(uniffi::Object)]
pub struct ReportIssueFlow {
    core: Arc<swiftly_vm::SeerrReportFlow<CoreTransport, JarAdapter>>,
}

impl ReportIssueFlow {
    pub(crate) fn new(
        core: Arc<swiftly_vm::SeerrReportFlow<CoreTransport, JarAdapter>>,
    ) -> Arc<Self> {
        Arc::new(Self { core })
    }

    /// Starts a fresh report for a place the core resolved.
    pub(crate) fn start_place(&self, place: SeerrPlace) {
        self.core.start(place);
    }
}

#[uniffi::export]
impl ReportIssueFlow {
    /// Starts a fresh report for a film or a whole series (`art`: `movie` / `tv`); `seconds` is the player's
    /// position when it comes from the player.
    pub fn start_title(&self, art: String, tmdb: i64, title: String, seconds: Option<f64>) {
        self.core
            .start(SeerrPlace::title(&art, tmdb, &title, seconds));
    }

    /// Starts a fresh report for an episode (by the series' TMDB id).
    pub fn start_episode(
        &self,
        tmdb: i64,
        series: String,
        season: i64,
        episode: i64,
        seconds: Option<f64>,
    ) {
        self.core
            .start(SeerrPlace::episode(tmdb, &series, season, episode, seconds));
    }

    /// The sheet went away (not `close`: that name is the generated object's own `close()` in Kotlin).
    pub fn dismiss(&self) {
        self.core.close();
    }

    /// The kind chosen.
    pub fn set_kind(&self, kind: IssueKind) {
        self.core.set_kind(kind);
    }

    /// The words written.
    pub fn set_message(&self, text: String) {
        self.core.set_message(&text);
    }

    /// What the sheet draws.
    pub fn info(&self) -> ReportIssueInfo {
        let i = self.core.info();
        ReportIssueInfo {
            open: i.open,
            heading: i.heading,
            title: i.title,
            line: i.line,
            kinds: i
                .kinds
                .into_iter()
                .map(|k| ReportIssueKindRow {
                    kind: k.kind,
                    text: k.text,
                    selected: k.selected,
                })
                .collect(),
            message: i.message,
            placeholder: i.placeholder,
            phase: i.phase.into(),
            can_send: i.can_send,
            send_label: i.send_label,
            sent_text: i.sent_text,
            done_text: i.done_text,
            cancel_text: i.cancel_text,
        }
    }

    /// Sends the report; answers the phase it ended in.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn send(&self) -> Result<ReportIssuePhase, CoreError> {
        Ok(self.core.send().await.into())
    }
}

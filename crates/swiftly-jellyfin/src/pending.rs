use serde::{Deserialize, Serialize};
use swiftly_model::parse_timestamp;
use swiftly_net::{ErrorKind, HttpTransport};

use crate::client::JellyfinClient;
use crate::reporting::ReportPlan;

/// Seconds between the Unix epoch and Apple's reference date (2001-01-01), which is what Swift's
/// default `Date` coding writes.
const REFERENCE_DATE: f64 = 978_307_200.0;

/// What the server does not know yet: where someone stopped while offline
/// (`PendingReport`, PendingReport.swift:14-37). One entry per title and account, the newest wins.
///
/// Persisted as `{"itemID","konto","ticks","wann"}` where `wann` is seconds since 2001-01-01
/// (Swift `Date`), so files written by the Apple app stay readable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(from = "PendingWire", into = "PendingWire")]
pub struct PendingReport {
    /// Title id.
    pub item_id: String,
    /// The account the position belongs to; a position in someone else's account is worse than none.
    pub account: String,
    /// Position in ticks.
    pub ticks: i64,
    /// When it happened, seconds since 1970.
    pub moment: f64,
}

#[derive(Serialize, Deserialize)]
struct PendingWire {
    #[serde(rename = "itemID")]
    item_id: String,
    #[serde(rename = "konto")]
    account: String,
    ticks: i64,
    #[serde(rename = "wann")]
    moment: f64,
}

impl From<PendingWire> for PendingReport {
    fn from(w: PendingWire) -> Self {
        Self {
            item_id: w.item_id,
            account: w.account,
            ticks: w.ticks,
            moment: w.moment + REFERENCE_DATE,
        }
    }
}

impl From<PendingReport> for PendingWire {
    fn from(p: PendingReport) -> Self {
        Self {
            item_id: p.item_id,
            account: p.account,
            ticks: p.ticks,
            moment: p.moment - REFERENCE_DATE,
        }
    }
}

impl PendingReport {
    /// A report.
    pub fn new(item_id: &str, account: &str, ticks: i64, moment: f64) -> Self {
        Self {
            item_id: item_id.into(),
            account: account.into(),
            ticks,
            moment,
        }
    }

    /// `account/itemID` (PendingReport.swift:28).
    pub fn id(&self) -> String {
        format!("{}/{}", self.account, self.item_id)
    }
}

/// The store rules (`PostReportRules`, PendingReport.swift:39-93).
pub struct PostReportRules;

impl PostReportRules {
    /// Puts a report into the store; the old one for the same title is dropped. The older
    /// one never wins: a report restored after a crash must not overwrite a newer position.
    pub fn record(new: PendingReport, store: &[PendingReport]) -> Vec<PendingReport> {
        let id = new.id();
        if store
            .iter()
            .find(|m| m.id() == id)
            .is_some_and(|alt| alt.moment > new.moment)
        {
            return store.to_vec();
        }
        let mut out: Vec<PendingReport> = store.iter().filter(|m| m.id() != id).cloned().collect();
        out.push(new);
        out
    }

    /// What is to be sent for this account, oldest first.
    pub fn due(store: &[PendingReport], account: &str) -> Vec<PendingReport> {
        let mut out: Vec<PendingReport> = store
            .iter()
            .filter(|m| m.account == account)
            .cloned()
            .collect();
        out.sort_by(|a, b| a.moment.total_cmp(&b.moment));
        out
    }

    /// After sending successfully.
    pub fn completed(ids: &[String], store: &[PendingReport]) -> Vec<PendingReport> {
        store
            .iter()
            .filter(|m| !ids.contains(&m.id()))
            .cloned()
            .collect()
    }

    /// The newer state wins (`UserData.LastPlayedDate`): if someone continued the title
    /// elsewhere since, the stored position would be a step back and lapses. Without a server
    /// timestamp (never played) it goes through.
    pub fn dispatch(m: &PendingReport, server_last: Option<f64>) -> bool {
        server_last.is_none_or(|last| m.moment > last)
    }

    /// A report did get through after all: the stored one for the same title of this account
    /// is outdated and must never go out.
    pub fn over_fetches(
        item_id: &str,
        account: &str,
        store: &[PendingReport],
    ) -> Vec<PendingReport> {
        store
            .iter()
            .filter(|m| !(m.item_id == item_id && m.account == account))
            .cloned()
            .collect()
    }
}

/// What became of a late report (`PostReportOutput`, PendingReport.swift:97-103).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PostReportOutput {
    /// Arrived.
    Sent,
    /// Not sent and settled: the server has a newer state, or the title no longer exists there.
    Discarded,
}

/// `ISO8601DateFormatter` with internet date-time and fractional seconds: UTC, three digits,
/// `Z` (`lastPlaySet`, JellyfinClient.swift:803). Milliseconds are truncated.
pub(crate) fn iso8601_millis(unix_seconds: f64) -> String {
    let total_ms = (unix_seconds * 1000.0).floor() as i64;
    let secs = total_ms.div_euclid(1000);
    let ms = total_ms.rem_euclid(1000);
    let days = secs.div_euclid(86_400);
    let rest = secs.rem_euclid(86_400);
    // civil-from-days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{ms:03}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

impl<T: HttpTransport> JellyfinClient<T> {
    /// A leftover position to the server, if it still applies (`reportLater`,
    /// PendingReport.swift:117-140).
    ///
    /// First read the state on the server, then decide ([`PostReportRules::dispatch`]), then
    /// report as the **end** of a playback so the server applies its own thresholds and marks
    /// "watched" like with network. Afterwards the time is set on top, because an end without
    /// a start sets no `LastPlayedDate`; if only that fails, the position has arrived anyway.
    ///
    /// # Errors
    /// A network or server error; the report then stays.
    pub async fn report_later(&self, m: &PendingReport) -> Result<PostReportOutput, ErrorKind> {
        let state = match self.user_record(&m.item_id).await {
            Ok(s) => s,
            Err(ErrorKind::Http { status: 404, .. }) => return Ok(PostReportOutput::Discarded),
            Err(e) => return Err(e),
        };
        let server_last = state.last_played_date.as_deref().and_then(parse_timestamp);
        if !PostReportRules::dispatch(m, server_last) {
            return Ok(PostReportOutput::Discarded);
        }
        self.report_stopped(&m.item_id, &ReportPlan::from_file(), m.ticks)
            .await?;
        let _ = self.last_play_set(&m.item_id, m.moment).await;
        Ok(PostReportOutput::Sent)
    }

    /// Everything left over for an account, oldest first (PendingReport.swift:142-159). Returns
    /// the ids that are settled (sent or discarded). Stops at the first error: the server is
    /// gone again, and the rest would be lost afterwards.
    pub async fn report_later_all(
        &self,
        opened: &[PendingReport],
        mut log: impl FnMut(&str) + Send,
    ) -> Vec<String> {
        let mut completed = Vec::new();
        for m in opened {
            match self.report_later(m).await {
                Ok(output) => {
                    log(&format!(
                        "[Melden] Nachmeldung {} {} s: {output:?}",
                        m.item_id,
                        m.ticks / 10_000_000
                    ));
                    completed.push(m.id());
                }
                Err(_) => {
                    log(&format!(
                        "[Melden] Nachmeldung {} gescheitert, bleibt liegen",
                        m.item_id
                    ));
                    break;
                }
            }
        }
        completed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(item: &str, ticks: i64, sek: f64, account: &str) -> PendingReport {
        PendingReport::new(item, account, ticks, 1_000_000.0 + sek)
    }

    // DownloadRulesTests.swift:487 newWins
    #[test]
    fn newest_wins() {
        let mut a = Vec::new();
        a = PostReportRules::record(m("f1", 100, 10.0, "u1"), &a);
        a = PostReportRules::record(m("f1", 900, 20.0, "u1"), &a);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].ticks, 900);
    }

    // :497 olderLoses
    #[test]
    fn older_loses() {
        let mut a = Vec::new();
        a = PostReportRules::record(m("f1", 900, 20.0, "u1"), &a);
        a = PostReportRules::record(m("f1", 100, 10.0, "u1"), &a);
        assert_eq!(a[0].ticks, 900);
    }

    // :505 accountsDisconnected
    #[test]
    fn accounts_do_not_share_a_state() {
        let mut a = Vec::new();
        a = PostReportRules::record(m("f1", 100, 10.0, "u1"), &a);
        a = PostReportRules::record(m("f1", 900, 20.0, "u2"), &a);
        assert_eq!(a.len(), 2);
        assert_eq!(
            PostReportRules::due(&a, "u1")
                .iter()
                .map(|x| x.ticks)
                .collect::<Vec<_>>(),
            [100]
        );
        assert_eq!(
            PostReportRules::due(&a, "u2")
                .iter()
                .map(|x| x.ticks)
                .collect::<Vec<_>>(),
            [900]
        );
    }

    // :515 railsEpisode: oldest first
    #[test]
    fn due_is_oldest_first() {
        let mut a = Vec::new();
        a = PostReportRules::record(m("b", 1, 30.0, "u1"), &a);
        a = PostReportRules::record(m("a", 1, 10.0, "u1"), &a);
        let ids: Vec<_> = PostReportRules::due(&a, "u1")
            .into_iter()
            .map(|x| x.item_id)
            .collect();
        assert_eq!(ids, ["a", "b"]);
    }

    // :523 completed
    #[test]
    fn completed_drops_only_the_done() {
        let mut a = Vec::new();
        a = PostReportRules::record(m("a", 1, 10.0, "u1"), &a);
        a = PostReportRules::record(m("b", 1, 20.0, "u1"), &a);
        let rest = PostReportRules::completed(&["u1/a".to_string()], &a);
        assert_eq!(
            rest.iter().map(|x| x.item_id.as_str()).collect::<Vec<_>>(),
            ["b"]
        );
    }

    // :532 format: the Apple app's literal JSON
    #[test]
    fn literal_json_survives() {
        let raw = r#"{"itemID":"abc","konto":"u1","ticks":123456789,"wann":757382400}"#;
        let n: PendingReport = serde_json::from_str(raw).expect("decode");
        assert_eq!((n.item_id.as_str(), n.ticks), ("abc", 123_456_789));
        assert_eq!(n.id(), "u1/abc");
        assert_eq!(n.moment, 757_382_400.0 + 978_307_200.0);
        let back: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&n).expect("encode")).expect("json");
        assert_eq!(back["wann"], 757_382_400.0);
        assert_eq!(back["konto"], "u1");
    }

    // OfflineTests.swift:196 conflict
    #[test]
    fn newer_timestamp_wins() {
        let p = |s: f64| PendingReport::new("a", "u1", 1, s);
        assert!(PostReportRules::dispatch(&p(200.0), Some(100.0)));
        assert!(!PostReportRules::dispatch(&p(100.0), Some(200.0)));
        assert!(!PostReportRules::dispatch(&p(100.0), Some(100.0)));
        assert!(PostReportRules::dispatch(&p(100.0), None));
    }

    // :204 overFetches
    #[test]
    fn a_report_that_got_through_outdates_the_stored_one() {
        let store = vec![
            PendingReport::new("a", "u1", 1, 1.0),
            PendingReport::new("a", "u2", 1, 2.0),
            PendingReport::new("b", "u1", 1, 3.0),
        ];
        let rest = PostReportRules::over_fetches("a", "u1", &store);
        assert_eq!(
            rest.iter().map(PendingReport::id).collect::<Vec<_>>(),
            ["u2/a", "u1/b"]
        );
    }

    #[test]
    fn iso_text_has_milliseconds_and_z() {
        assert_eq!(iso8601_millis(0.0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso8601_millis(1_767_225_600.5), "2026-01-01T00:00:00.500Z");
        assert_eq!(iso8601_millis(1_709_164_800.0), "2024-02-29T00:00:00.000Z");
    }
}

//! The admin side of Seerr as view models (Sans-I/O): the queue tabs, the request detail rows and
//! the issue list with its thread. The request queue itself is [`crate::seerr_lists::SeerrRequestsVm`] in
//! the `Queue` scope; here are the rest and the permission gates.

use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_seerr::issues::{Issue, IssueKind, IssueStatus};
use swiftly_seerr::requests::ServiceDetail;
use swiftly_seerr::types::RequestRow;
use swiftly_seerr::{AskError, Perms};

use crate::seerr_lists::{ListLoad, RowWork, TitleCache};
use crate::seerr_title::{ask_text, is_offline};

/// A tab of the admin page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdminTab {
    /// Requests.
    Requests,
    /// Problems.
    Issues,
}

/// A tab with its count.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrTabInfo {
    /// Which.
    pub tab: AdminTab,
    /// "Anfragen".
    pub title: String,
    /// Open entries.
    pub count: i64,
}

/// The tabs this account may open (requests: manager; problems: view or manage issues).
pub fn tabs(locale: &Locale, perms: Perms, pending: i64, issues_open: i64) -> Vec<SeerrTabInfo> {
    let t = Translator::new(locale.clone());
    let mut out = Vec::new();
    if perms.can_manage_requests() {
        out.push(SeerrTabInfo {
            tab: AdminTab::Requests,
            title: t.t("Anfragen"),
            count: pending,
        });
    }
    if perms.can_view_issues() {
        out.push(SeerrTabInfo {
            tab: AdminTab::Issues,
            title: t.t("Probleme"),
            count: issues_open,
        });
    }
    out
}

/// A label and a value of the request detail card.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeerrDetailRow {
    /// "Angefragt von".
    pub label: String,
    /// "Lena".
    pub value: String,
}

/// The rows of the request detail: who, version, quality, folder, seasons, when.
pub fn request_detail_rows(
    locale: &Locale,
    req: &RequestRow,
    service: Option<&ServiceDetail>,
) -> Vec<SeerrDetailRow> {
    let t = Translator::new(locale.clone());
    let row = |label: &str, value: String| SeerrDetailRow {
        label: t.t(label),
        value,
    };
    let mut out = Vec::new();
    if let Some(name) = req
        .requested_by
        .as_ref()
        .map(|u| u.name())
        .filter(|n| !n.is_empty())
    {
        out.push(row("Angefragt von", name));
    }
    out.push(row(
        "Fassung",
        t.t(if req.is4k { "4K" } else { "Standard" }),
    ));
    let seasons = req.season_numbers();
    if !seasons.is_empty() {
        let list: Vec<String> = seasons.iter().map(i64::to_string).collect();
        out.push(row("Staffeln", list.join(", ")));
    }
    let profile = req.profile_id.and_then(|id| {
        service?
            .profiles
            .iter()
            .find(|p| p.id == id)
            .and_then(|p| p.name.clone())
    });
    if let Some(p) = profile {
        out.push(row("Qualität", p));
    }
    if let Some(f) = req.root_folder.clone().filter(|f| !f.is_empty()) {
        out.push(row("Ordner", f));
    }
    if let Some(day) = req.created_at.as_deref().and_then(|d| d.get(..10)) {
        out.push(row("Angefragt am", crate::seerr_title::short_date(&t, day)));
    }
    out
}

// ---------------------------------------------------------------- issues

/// The issue filter pills.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IssuePill {
    /// Open ones.
    Open,
    /// Resolved ones.
    Resolved,
    /// All.
    All,
}

/// A pill.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrIssuePill {
    /// Which.
    pub pill: IssuePill,
    /// "Offen".
    pub title: String,
    /// Count.
    pub count: i64,
    /// Active.
    pub selected: bool,
}

/// One issue row.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrIssueRow {
    /// Seerr's issue id.
    pub id: i64,
    /// `movie` / `tv`.
    pub art: String,
    /// TMDB id.
    pub tmdb: i64,
    /// Title.
    pub title: String,
    /// Poster path.
    pub poster: Option<String>,
    /// "Bild", "Ton", "Untertitel", "Sonstiges".
    pub kind_word: String,
    /// "Staffel 2 · Folge 3".
    pub place: Option<String>,
    /// "bei 23:14".
    pub time_text: Option<String>,
    /// Open.
    pub is_open: bool,
    /// "Offen" / "Erledigt".
    pub status_word: String,
    /// Who reported it (managers see everyone's).
    pub reporter: Option<String>,
    /// First line of the first message.
    pub message: String,
    /// Messages in the thread.
    pub messages: i64,
}

/// One message of the thread.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrIssueMessage {
    /// Id.
    pub id: i64,
    /// Author.
    pub author: String,
    /// Text without the position suffix.
    pub text: String,
    /// When it was written, in words ("vor 3 Tagen", "10. Nov."); never the raw server time.
    pub when_text: Option<String>,
    /// Written by a manager (the admin bubble).
    pub by_admin: bool,
    /// Written by this account.
    pub mine: bool,
}

/// The issue list.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrIssuesInfo {
    /// Grows with every change.
    pub version: u64,
    /// State.
    pub load: ListLoad,
    /// Pills with counts.
    pub pills: Vec<SeerrIssuePill>,
    /// Rows of the active pill.
    pub rows: Vec<SeerrIssueRow>,
    /// Failure text.
    pub error: Option<String>,
}

/// One issue opened.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrIssueDetail {
    /// Grows with every change.
    pub version: u64,
    /// The row on top.
    pub row: SeerrIssueRow,
    /// The thread, oldest first.
    pub messages: Vec<SeerrIssueMessage>,
    /// "Ab 23:14 abspielen" (a library item exists and the reporter named a position).
    pub play_from: Option<String>,
    /// The reply field is offered.
    pub can_reply: bool,
    /// "Erledigt" is offered.
    pub can_resolve: bool,
    /// "Wieder öffnen" is offered.
    pub can_reopen: bool,
    /// Action state.
    pub work: RowWork,
    /// Failure text of the last action.
    pub error: Option<String>,
}

/// The issue list and the open issue.
pub struct SeerrIssuesVm {
    t: Translator,
    me: i64,
    perms: Perms,
    load: ListLoad,
    issues: Vec<Issue>,
    pill: IssuePill,
    error: Option<String>,
    open: Option<Issue>,
    work: RowWork,
    work_error: Option<String>,
    version: u64,
}

impl SeerrIssuesVm {
    /// Who the list is for and what that account may; a load hands them in once the hub has read them (see
    /// `SeerrRequestsVm::set_account`).
    pub fn set_account(&mut self, me: i64, perms: Perms) {
        self.me = me;
        self.perms = perms;
    }

    /// An empty list for user `me` with `perms`.
    pub fn new(locale: Locale, me: i64, perms: Perms) -> Self {
        Self {
            t: Translator::new(locale),
            me,
            perms,
            load: ListLoad::Idle,
            issues: Vec::new(),
            pill: IssuePill::Open,
            error: None,
            open: None,
            work: RowWork::Idle,
            work_error: None,
            version: 1,
        }
    }

    /// A load starts.
    pub fn begin(&mut self) {
        if self.load != ListLoad::Content {
            self.load = ListLoad::Loading;
        }
        self.version += 1;
    }

    /// The issues came back (a non-manager's call asks for their own only).
    pub fn loaded(&mut self, result: Result<Vec<Issue>, AskError>) {
        match result {
            Ok(list) => {
                self.issues = list;
                self.load = if self.issues.is_empty() {
                    ListLoad::Empty
                } else {
                    ListLoad::Content
                };
                self.error = None;
            }
            Err(e) if is_offline(&e) => {
                self.load = ListLoad::Offline;
                self.error = Some(self.t.t("Seerr antwortet gerade nicht."));
            }
            Err(e) => {
                self.load = ListLoad::Failed;
                self.error = Some(ask_text(&self.t, &e));
            }
        }
        self.version += 1;
    }

    /// Picks a pill.
    pub fn select(&mut self, pill: IssuePill) {
        self.pill = pill;
        self.version += 1;
    }

    /// An issue was opened (its thread came back).
    pub fn opened(&mut self, issue: Issue) {
        self.open = Some(issue);
        self.work = RowWork::Idle;
        self.work_error = None;
        self.version += 1;
    }

    /// The issue was closed again (back to the list).
    pub fn closed(&mut self) {
        self.open = None;
        self.version += 1;
    }

    /// An action (reply, resolve, reopen) starts.
    pub fn begin_action(&mut self) {
        self.work = RowWork::Working;
        self.work_error = None;
        self.version += 1;
    }

    /// The action came back with the updated issue. The list keeps the new state.
    pub fn action_done(&mut self, result: Result<Issue, AskError>) {
        match result {
            Ok(issue) => {
                if let Some(slot) = self.issues.iter_mut().find(|i| i.id == issue.id) {
                    // The answer of a comment carries the thread but the media only sometimes.
                    let media = slot.media.clone();
                    *slot = issue.clone();
                    if slot.media.is_none() {
                        slot.media = media;
                    }
                }
                let media = self.open.as_ref().and_then(|o| o.media.clone());
                let mut issue = issue;
                if issue.media.is_none() {
                    issue.media = media;
                }
                self.open = Some(issue);
                self.work = RowWork::Idle;
            }
            Err(e) => {
                self.work = RowWork::Failed;
                self.work_error = Some(ask_text(&self.t, &e));
            }
        }
        self.version += 1;
    }

    /// The issues as loaded.
    pub fn issues(&self) -> &[Issue] {
        &self.issues
    }

    fn row(&self, i: &Issue, cache: &TitleCache) -> SeerrIssueRow {
        let t = &self.t;
        let (art, tmdb) = i
            .media
            .as_ref()
            .and_then(|m| {
                Some((
                    m.media_type.clone().unwrap_or_else(|| "movie".into()),
                    m.tmdb_id?,
                ))
            })
            .unwrap_or_else(|| ("movie".into(), 0));
        let lite = cache.get(&art, tmdb);
        let place = match (i.problem_season, i.problem_episode) {
            (s, e) if s > 0 && e > 0 => {
                Some(t.t_args("Staffel %lld · Folge %lld", &[Arg::Int(s), Arg::Int(e)]))
            }
            (s, _) if s > 0 => Some(t.t_args("Staffel %lld", &[Arg::Int(s)])),
            _ => None,
        };
        let first = i
            .comments
            .first()
            .map(|c| c.text().to_string())
            .unwrap_or_default();
        SeerrIssueRow {
            id: i.id,
            art,
            tmdb,
            title: lite.map(|l| l.title.clone()).unwrap_or_default(),
            poster: lite.and_then(|l| l.poster.clone()),
            kind_word: t.t(match i.issue_type {
                IssueKind::Video => "Bild",
                IssueKind::Audio => "Ton",
                IssueKind::Subtitles => "Untertitel",
                IssueKind::Other => "Sonstiges",
            }),
            place,
            time_text: i
                .time_mark()
                .map(|m| t.t_args("bei %@", &[Arg::Str(m.to_string())])),
            is_open: i.is_open(),
            status_word: t.t(if i.is_open() { "Offen" } else { "Erledigt" }),
            reporter: i
                .created_by
                .as_ref()
                .map(|u| u.name())
                .filter(|n| !n.is_empty() && self.perms.can_manage_issues()),
            message: first,
            messages: i64::try_from(i.comments.len()).unwrap_or(0),
        }
    }

    /// The list now.
    pub fn info(&self, cache: &TitleCache) -> SeerrIssuesInfo {
        let t = &self.t;
        let open = |i: &&Issue| i.status == IssueStatus::Open;
        let n_open = i64::try_from(self.issues.iter().filter(open).count()).unwrap_or(0);
        let n_all = i64::try_from(self.issues.len()).unwrap_or(0);
        let pills = [
            (IssuePill::Open, "Offen", n_open),
            (IssuePill::Resolved, "Erledigt", n_all - n_open),
            (IssuePill::All, "Alle", n_all),
        ]
        .into_iter()
        .map(|(pill, title, count)| SeerrIssuePill {
            pill,
            title: t.t(title),
            count,
            selected: pill == self.pill,
        })
        .collect();
        let rows = self
            .issues
            .iter()
            .filter(|i| match self.pill {
                IssuePill::Open => i.is_open(),
                IssuePill::Resolved => !i.is_open(),
                IssuePill::All => true,
            })
            .map(|i| self.row(i, cache))
            .collect();
        SeerrIssuesInfo {
            version: self.version,
            load: self.load,
            pills,
            rows,
            error: self.error.clone(),
        }
    }

    /// The open issue now; `library_has` says a library item exists for the title (offers the
    /// "Ab 23:14 abspielen" line).
    pub fn detail(&self, cache: &TitleCache, library_has: bool) -> Option<SeerrIssueDetail> {
        let t = &self.t;
        let i = self.open.as_ref()?;
        let managers = self.perms.can_manage_issues();
        let messages = i
            .comments
            .iter()
            .map(|c| SeerrIssueMessage {
                id: c.id,
                author: c
                    .user
                    .as_ref()
                    .map(|u| u.name())
                    .filter(|n| !n.is_empty())
                    .unwrap_or_default(),
                text: c.text().to_string(),
                when_text: c
                    .created_at
                    .as_deref()
                    .map(|d| crate::seerr_title::when_text(t, d)),
                by_admin: c
                    .user
                    .as_ref()
                    .is_some_and(|u| u.perms().can_manage_issues()),
                mine: c.user.as_ref().is_some_and(|u| u.id == self.me),
            })
            .collect();
        Some(SeerrIssueDetail {
            version: self.version,
            row: self.row(i, cache),
            messages,
            play_from: i
                .time_mark()
                .filter(|_| library_has)
                .map(|m| t.t_args("Ab %@ abspielen", &[Arg::Str(m.to_string())])),
            can_reply: managers || i.created_by.as_ref().is_some_and(|u| u.id == self.me),
            can_resolve: managers && i.is_open(),
            can_reopen: managers && !i.is_open(),
            work: self.work,
            error: self.work_error.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn issue(json: &str) -> Issue {
        serde_json::from_str(json).expect("issue")
    }

    const ISSUE: &str = r#"{"id":4,"issueType":3,"status":1,"problemSeason":2,"problemEpisode":3,
        "createdBy":{"id":2,"displayName":"Lena"},"media":{"tmdbId":7777,"mediaType":"tv"},
        "comments":[{"id":1,"message":"Ton fehlt · bei 23:14","createdAt":"2026-11-10T10:00:00.000Z","user":{"id":2,"displayName":"Lena","permissions":0}},
                    {"id":2,"message":"Sehe ich mir an","createdAt":"2026-11-10T10:05:00.000Z","user":{"id":1,"displayName":"Paul","permissions":2}}]}"#;

    #[test]
    fn an_issue_reads_with_place_time_and_a_play_line() {
        let perms = Perms(2);
        let mut vm = SeerrIssuesVm::new(Locale::parse("de"), 1, perms);
        vm.loaded(Ok(vec![issue(ISSUE)]));
        let cache = TitleCache::default();
        let info = vm.info(&cache);
        let row = &info.rows[0];
        assert_eq!(row.kind_word, "Untertitel");
        assert_eq!(row.place.as_deref(), Some("Staffel 2 · Folge 3"));
        assert_eq!(row.time_text.as_deref(), Some("bei 23:14"));
        assert_eq!(
            row.message, "Ton fehlt",
            "the suffix is not part of the text"
        );
        assert_eq!(row.reporter.as_deref(), Some("Lena"));
        vm.opened(issue(ISSUE));
        let d = vm.detail(&cache, true).expect("detail");
        assert_eq!(d.play_from.as_deref(), Some("Ab 23:14 abspielen"));
        assert!(d.can_resolve && !d.can_reopen && d.can_reply);
        assert!(d.messages[1].by_admin && d.messages[1].mine);
        for m in &d.messages {
            let w = m.when_text.as_deref().expect("a time on every comment");
            assert!(!w.contains('T') && !w.contains('Z'), "no raw ISO time: {w}");
        }
        assert!(
            vm.detail(&cache, false)
                .expect("detail")
                .play_from
                .is_none()
        );
    }

    #[test]
    fn a_plain_user_only_replies_to_their_own_and_cannot_resolve() {
        let mut vm = SeerrIssuesVm::new(Locale::parse("de"), 9, Perms(4_194_304));
        vm.opened(issue(ISSUE));
        let d = vm.detail(&TitleCache::default(), false).expect("detail");
        assert!(!d.can_reply && !d.can_resolve);
        assert!(d.row.reporter.is_none(), "only managers see the reporter");
    }

    #[test]
    fn resolving_moves_the_issue_to_the_resolved_pill() {
        let mut vm = SeerrIssuesVm::new(Locale::parse("de"), 1, Perms(2));
        vm.loaded(Ok(vec![issue(ISSUE)]));
        vm.opened(issue(ISSUE));
        vm.begin_action();
        let mut done = issue(ISSUE);
        done.status = IssueStatus::Resolved;
        vm.action_done(Ok(done));
        let cache = TitleCache::default();
        let info = vm.info(&cache);
        assert_eq!((info.pills[0].count, info.pills[1].count), (0, 1));
        assert!(info.rows.is_empty(), "the open pill is empty now");
        vm.select(IssuePill::Resolved);
        assert_eq!(vm.info(&cache).rows[0].status_word, "Erledigt");
    }

    #[test]
    fn tabs_follow_the_permissions() {
        let l = Locale::parse("de");
        assert!(tabs(&l, Perms(32), 3, 1).is_empty());
        let t = tabs(&l, Perms(16 | 2_097_152), 3, 1);
        assert_eq!(t.iter().map(|x| x.count).collect::<Vec<_>>(), [3, 1]);
        assert_eq!(tabs(&l, Perms(2_097_152), 3, 1).len(), 1);
    }
}

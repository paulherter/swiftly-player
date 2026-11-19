//! Issues ("Problem melden"): list, count, read, create, comment, resolve, reopen.
//!
//! Seerr issues have no time field. The position in the film goes into the message as a plain
//! suffix `" · bei 23:14"` and is read back by [`split_time`].

use serde::Deserialize;
use serde_json::json;
use swiftly_net::{HttpTransport, Method};

use crate::client::{CookieJar, SeerrClient};
use crate::errors::AskError;
use crate::requests::PageInfo;
use crate::types::{MediaInfo, SeerrUser, list, or_default};

/// The separator before the position.
const TIME_MARK: &str = " · bei ";

/// `issueType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum IssueKind {
    /// 1: picture.
    #[default]
    Video,
    /// 2: sound.
    Audio,
    /// 3: subtitles.
    Subtitles,
    /// 4: something else.
    Other,
}

impl IssueKind {
    /// The API number.
    pub fn raw(self) -> i64 {
        match self {
            Self::Video => 1,
            Self::Audio => 2,
            Self::Subtitles => 3,
            Self::Other => 4,
        }
    }

    /// From the API number (unknown = other).
    pub fn from_raw(raw: i64) -> Self {
        match raw {
            1 => Self::Video,
            2 => Self::Audio,
            3 => Self::Subtitles,
            _ => Self::Other,
        }
    }
}

impl<'de> Deserialize<'de> for IssueKind {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Option::<serde_json::Value>::deserialize(d)?;
        Ok(v.and_then(|v| v.as_i64())
            .map_or(Self::Other, Self::from_raw))
    }
}

/// `status` of an issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum IssueStatus {
    /// 1.
    #[default]
    Open,
    /// 2.
    Resolved,
}

impl<'de> Deserialize<'de> for IssueStatus {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Option::<serde_json::Value>::deserialize(d)?;
        Ok(match v.and_then(|v| v.as_i64()) {
            Some(2) => Self::Resolved,
            _ => Self::Open,
        })
    }
}

/// A message of an issue.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IssueComment {
    /// Id.
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// The text as stored (with the position suffix on the first message).
    #[serde(deserialize_with = "or_default")]
    pub message: String,
    /// Author.
    pub user: Option<SeerrUser>,
    /// ISO time.
    pub created_at: Option<String>,
}

impl IssueComment {
    /// The text without the position suffix.
    pub fn text(&self) -> &str {
        split_time(&self.message).0
    }

    /// The position (`23:14`, `1:05:23`) the reporter was at.
    pub fn time_mark(&self) -> Option<&str> {
        split_time(&self.message).1
    }
}

/// An issue.
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Issue {
    /// Id.
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// Kind.
    pub issue_type: IssueKind,
    /// Open or resolved.
    pub status: IssueStatus,
    /// Season (0 = none).
    #[serde(deserialize_with = "or_default")]
    pub problem_season: i64,
    /// Episode (0 = none).
    #[serde(deserialize_with = "or_default")]
    pub problem_episode: i64,
    /// ISO time.
    pub created_at: Option<String>,
    /// The title.
    pub media: Option<MediaInfo>,
    /// Reporter.
    pub created_by: Option<SeerrUser>,
    /// The thread, oldest first.
    #[serde(deserialize_with = "list")]
    pub comments: Vec<IssueComment>,
}

impl Issue {
    /// Open.
    pub fn is_open(&self) -> bool {
        self.status == IssueStatus::Open
    }

    /// The position the reporter named (first message).
    pub fn time_mark(&self) -> Option<&str> {
        self.comments.first().and_then(IssueComment::time_mark)
    }
}

/// `message · bei 23:14`.
pub fn with_time(message: &str, time: Option<&str>) -> String {
    match time.map(str::trim).filter(|t| is_time(t)) {
        Some(t) => format!("{}{TIME_MARK}{t}", message.trim_end()),
        None => message.to_string(),
    }
}

/// `(text, Some("23:14"))` of a message made by [`with_time`]; any other message comes back whole.
pub fn split_time(message: &str) -> (&str, Option<&str>) {
    if let Some(at) = message.rfind(TIME_MARK) {
        let time = &message[at + TIME_MARK.len()..];
        if is_time(time) {
            return (&message[..at], Some(time));
        }
    }
    (message, None)
}

/// `m:ss`, `mm:ss`, `h:mm:ss`: digits, colons, the last group two digits.
fn is_time(text: &str) -> bool {
    let groups: Vec<&str> = text.split(':').collect();
    (2..=3).contains(&groups.len())
        && groups
            .iter()
            .all(|g| !g.is_empty() && g.bytes().all(|b| b.is_ascii_digit()))
        && groups.last().is_some_and(|g| g.len() == 2)
}

/// A new issue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IssueSpec {
    /// Kind.
    pub kind: IssueKind,
    /// What is wrong.
    pub message: String,
    /// Seerr's media id (`MediaInfo::id`, not the TMDB id).
    pub media_id: i64,
    /// Season, 0 = none.
    pub season: i64,
    /// Episode, 0 = none.
    pub episode: i64,
    /// Position in the film (`23:14`), appended to the message.
    pub at: Option<String>,
}

/// `filter=` of `GET issue`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum IssueFilter {
    /// All.
    #[default]
    All,
    /// Open.
    Open,
    /// Resolved.
    Resolved,
}

/// Which issues.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IssueQuery {
    /// Filter.
    pub filter: IssueFilter,
    /// Newest change first.
    pub by_modified: bool,
    /// Only this reporter's.
    pub requested_by: Option<i64>,
    /// Page size.
    pub take: u32,
    /// Entries to skip.
    pub skip: u32,
}

impl Default for IssueQuery {
    fn default() -> Self {
        Self {
            filter: IssueFilter::All,
            by_modified: false,
            requested_by: None,
            take: 20,
            skip: 0,
        }
    }
}

/// A page of issues.
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IssuePage {
    /// Paging.
    pub page_info: PageInfo,
    /// The issues.
    #[serde(deserialize_with = "list")]
    pub results: Vec<Issue>,
}

/// `GET issue/count`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct IssueCount {
    /// All.
    #[serde(deserialize_with = "or_default")]
    pub total: i64,
    /// Picture.
    #[serde(deserialize_with = "or_default")]
    pub video: i64,
    /// Sound.
    #[serde(deserialize_with = "or_default")]
    pub audio: i64,
    /// Subtitles.
    #[serde(deserialize_with = "or_default")]
    pub subtitles: i64,
    /// Other.
    #[serde(deserialize_with = "or_default")]
    pub others: i64,
    /// Open.
    #[serde(deserialize_with = "or_default")]
    pub open: i64,
    /// Resolved.
    #[serde(deserialize_with = "or_default")]
    pub closed: i64,
}

impl<T: HttpTransport, J: CookieJar> SeerrClient<T, J> {
    /// `GET issue`.
    pub async fn issue_list(&self, query: &IssueQuery) -> Result<IssuePage, AskError> {
        let filter = match query.filter {
            IssueFilter::All => "all",
            IssueFilter::Open => "open",
            IssueFilter::Resolved => "resolved",
        };
        let mut pairs = vec![
            ("take".to_string(), query.take.to_string()),
            ("skip".to_string(), query.skip.to_string()),
            ("filter".to_string(), filter.to_string()),
            (
                "sort".to_string(),
                if query.by_modified {
                    "modified"
                } else {
                    "added"
                }
                .to_string(),
            ),
        ];
        if let Some(u) = query.requested_by {
            pairs.push(("requestedBy".to_string(), u.to_string()));
        }
        let q: Vec<(&str, &str)> = pairs
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        self.get_json("issue", &q).await
    }

    /// `GET issue/count`.
    pub async fn issue_count(&self) -> Result<IssueCount, AskError> {
        self.get_json("issue/count", &[]).await
    }

    /// `GET issue/{id}` with its thread.
    pub async fn issue(&self, id: i64) -> Result<Issue, AskError> {
        self.get_json(&format!("issue/{id}"), &[]).await
    }

    /// `POST issue`.
    pub async fn create_issue(&self, spec: &IssueSpec) -> Result<Issue, AskError> {
        let body = json!({
            "issueType": spec.kind.raw(),
            "message": with_time(&spec.message, spec.at.as_deref()),
            "mediaId": spec.media_id,
            "problemSeason": spec.season.max(0),
            "problemEpisode": spec.episode.max(0),
        });
        let a = self
            .send(Method::Post, "issue", &[], Some(body), false)
            .await?;
        Ok(serde_json::from_slice(&a.body).unwrap_or_default())
    }

    /// `POST issue/{id}/comment`; gives the issue with the new message.
    pub async fn comment_issue(&self, id: i64, message: &str) -> Result<Issue, AskError> {
        self.issue_verb(id, "comment", Some(json!({ "message": message })))
            .await
    }

    /// `POST issue/{id}/resolved` (`MANAGE_ISSUES`).
    pub async fn resolve_issue(&self, id: i64) -> Result<Issue, AskError> {
        self.issue_verb(id, "resolved", None).await
    }

    /// `POST issue/{id}/open` (`MANAGE_ISSUES`).
    pub async fn reopen_issue(&self, id: i64) -> Result<Issue, AskError> {
        self.issue_verb(id, "open", None).await
    }

    async fn issue_verb(
        &self,
        id: i64,
        verb: &str,
        body: Option<serde_json::Value>,
    ) -> Result<Issue, AskError> {
        let a = self
            .send(
                Method::Post,
                &format!("issue/{id}/{verb}"),
                &[],
                body,
                false,
            )
            .await?;
        Ok(serde_json::from_slice(&a.body).unwrap_or_default())
    }
}

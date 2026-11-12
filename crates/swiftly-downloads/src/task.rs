//! Port of DownloadTask.swift: which task a callback refers to.
//!
//! Every transfer carries a generation that increments on every start, pause and removal of
//! the title. A callback counts only if its generation is still the current one. The parts
//! travel in the transfer's description string because a system callback cannot reach the list.

/// Id, generation and file name of a transfer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskParts {
    /// The title's id.
    pub id: String,
    /// `0` for a transfer from a version without generations.
    pub generation: i64,
    /// File name in the downloads folder.
    pub file: String,
}

impl TaskParts {
    /// Plain constructor.
    pub fn new(id: impl Into<String>, generation: i64, file: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            generation,
            file: file.into(),
        }
    }

    /// The description string for the transfer.
    pub fn description(&self) -> String {
        DownloadTask::description(&self.id, self.generation, &self.file)
    }
}

/// Namespace of the description rules.
pub struct DownloadTask;

impl DownloadTask {
    /// Unit separator between the three parts.
    pub const SEPARATOR: &'static str = "\u{1F}";

    /// What goes into the transfer's description: id, generation, file name.
    pub fn description(id: &str, generation: i64, file: &str) -> String {
        [id, &generation.to_string(), file].join(Self::SEPARATOR)
    }

    /// Back into the parts. The old form `id<US>file` gets generation 0.
    pub fn dismantle(text: Option<&str>) -> Option<TaskParts> {
        let pieces: Vec<&str> = text.unwrap_or("").split(Self::SEPARATOR).collect();
        let first = pieces.first().copied().unwrap_or("");
        match pieces.len() {
            2 if !first.is_empty() => Some(TaskParts::new(first, 0, pieces[1])),
            n if n >= 3 && !first.is_empty() => match pieces[1].parse::<i64>() {
                Ok(g) => Some(TaskParts::new(first, g, pieces[2..].join(Self::SEPARATOR))),
                // No number field: the old form, and the file name itself held the separator.
                Err(_) => Some(TaskParts::new(first, 0, pieces[1..].join(Self::SEPARATOR))),
            },
            _ => None,
        }
    }

    /// Whether a callback counts. If no generation is known for the title yet (freshly
    /// started, the transfer kept running in the system), it counts: otherwise a download
    /// that finished in the background would be lost.
    pub fn applies(reported: i64, current: Option<i64>) -> bool {
        current.is_none_or(|c| reported == c)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_and_back() {
        let text = DownloadTask::description("abc", 42, "abc.mkv");
        assert_eq!(
            DownloadTask::dismantle(Some(&text)),
            Some(TaskParts::new("abc", 42, "abc.mkv"))
        );
    }

    #[test]
    fn old_form_gets_null() {
        assert_eq!(
            DownloadTask::dismantle(Some("abc\u{1F}abc.mp4")),
            Some(TaskParts::new("abc", 0, "abc.mp4"))
        );
    }

    #[test]
    fn unusable() {
        assert_eq!(DownloadTask::dismantle(None), None);
        assert_eq!(DownloadTask::dismantle(Some("nur-ein-teil")), None);
        assert_eq!(DownloadTask::dismantle(Some("\u{1F}datei")), None);
    }

    /// The reported case: pause, resume, and then the cancellation of the old task arrives.
    #[test]
    fn late_message_old_task_counts_not() {
        let (old, new) = (7, 9);
        assert!(!DownloadTask::applies(old, Some(new)));
        assert!(DownloadTask::applies(new, Some(new)));
    }

    #[test]
    fn unknown_title_counts() {
        assert!(DownloadTask::applies(3, None));
    }

    #[test]
    fn separator_inside_the_file_name_survives() {
        let text = DownloadTask::description("a", 5, "x\u{1F}y");
        assert_eq!(
            DownloadTask::dismantle(Some(&text)),
            Some(TaskParts::new("a", 5, "x\u{1F}y"))
        );
        // Old form whose file name contained the separator.
        assert_eq!(
            DownloadTask::dismantle(Some("a\u{1F}x\u{1F}y")),
            Some(TaskParts::new("a", 0, "x\u{1F}y"))
        );
    }
}

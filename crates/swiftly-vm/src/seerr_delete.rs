//! "Vom Server löschen" as a resumable flow (Sans-I/O): files (Radarr / Sonarr), forget in Seerr,
//! Jellyfin rescans, verify. The host runs one [`DeleteAction`] at a time and feeds the result back;
//! a failed step keeps the earlier ones done and `retry` resumes at that step only.

use swiftly_l10n::{Locale, Translator};

/// Whether "Vom Server löschen" may be offered or run: the account manages requests and this device has not
/// switched "Löschen vom Server sperren" on. Every entry to the flow asks here, on every platform.
pub fn delete_offered(can_manage_requests: bool) -> bool {
    delete_allowed(
        can_manage_requests,
        swiftly_model::switches::server_delete_locked(),
    )
}

/// The rule of [`delete_offered`] with the lock given, for tests and callers that hold it already.
pub fn delete_allowed(can_manage_requests: bool, locked: bool) -> bool {
    can_manage_requests && !locked
}

/// One step as the sheet lists it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteStepKind {
    /// Radarr / Sonarr remove the files.
    Files,
    /// Seerr forgets the title.
    Seerr,
    /// Jellyfin reads the library again.
    Library,
    /// The title is gone from the library.
    Verify,
}

/// State of a step.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepState {
    /// Not yet.
    Pending,
    /// Running.
    Running,
    /// Done.
    Done,
    /// Failed.
    Failed,
}

/// A step row.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrDeleteStep {
    /// Which.
    pub kind: DeleteStepKind,
    /// "Dateien gelöscht".
    pub label: String,
    /// State.
    pub state: StepState,
}

/// A version of the title the sheet can delete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeerrDeleteVersion {
    /// The 4K lane.
    pub is4k: bool,
    /// "Standard" / "4K".
    pub label: String,
    /// "4,2 GB" where known.
    pub size: Option<String>,
}

/// Where the flow is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeletePhase {
    /// The question with one row per version.
    Confirm,
    /// Steps run.
    Running,
    /// A step failed (`headline` says "Ein Schritt hängt").
    Failed,
    /// Everything is done.
    Done,
}

/// The sheet.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrDeleteInfo {
    /// Grows with every change.
    pub version: u64,
    /// Where it is.
    pub phase: DeletePhase,
    /// The title being deleted.
    pub title: String,
    /// The versions (confirm).
    pub versions: Vec<SeerrDeleteVersion>,
    /// The steps (running, failed, done).
    pub steps: Vec<SeerrDeleteStep>,
    /// "Ein Schritt hängt".
    pub headline: Option<String>,
    /// Why the step failed.
    pub error: Option<String>,
    /// "Nochmal versuchen" is offered.
    pub can_retry: bool,
}

/// What the host runs next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteAction {
    /// `DELETE media/{id}/file?is4k=`.
    DeleteFiles {
        /// The lane.
        is4k: bool,
    },
    /// `DELETE media/{id}`.
    ForgetMedia,
    /// Jellyfin `POST /Library/Refresh`.
    RefreshLibrary,
    /// Look the title up in the library until it is gone (the host waits up to 20 s).
    VerifyGone,
}

fn kind_of(a: DeleteAction) -> DeleteStepKind {
    match a {
        DeleteAction::DeleteFiles { .. } => DeleteStepKind::Files,
        DeleteAction::ForgetMedia => DeleteStepKind::Seerr,
        DeleteAction::RefreshLibrary => DeleteStepKind::Library,
        DeleteAction::VerifyGone => DeleteStepKind::Verify,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Flow {
    Confirm,
    Running,
    Failed(String),
    Done,
}

/// The delete flow of one title.
pub struct SeerrDeleteVm {
    t: Translator,
    title: String,
    versions: Vec<SeerrDeleteVersion>,
    plan: Vec<DeleteAction>,
    cursor: usize,
    flow: Flow,
    version: u64,
}

impl SeerrDeleteVm {
    /// A flow for a title with these versions (`(is4k, size text)`).
    pub fn new(locale: Locale, title: &str, versions: &[(bool, Option<String>)]) -> Self {
        let t = Translator::new(locale);
        let versions = versions
            .iter()
            .map(|(is4k, size)| SeerrDeleteVersion {
                is4k: *is4k,
                label: t.t(if *is4k { "4K" } else { "Standard" }),
                size: size.clone(),
            })
            .collect();
        Self {
            t,
            title: title.to_string(),
            versions,
            plan: Vec::new(),
            cursor: 0,
            flow: Flow::Confirm,
            version: 1,
        }
    }

    /// The versions (host-side: which lanes exist).
    pub fn versions(&self) -> &[SeerrDeleteVersion] {
        &self.versions
    }

    /// Delete these lanes. Returns the first action; `None` when nothing was chosen or the flow
    /// already runs.
    pub fn start(&mut self, lanes: &[bool]) -> Option<DeleteAction> {
        if self.flow != Flow::Confirm {
            return None;
        }
        let chosen: Vec<bool> = self
            .versions
            .iter()
            .map(|v| v.is4k)
            .filter(|l| lanes.contains(l))
            .collect();
        if chosen.is_empty() {
            return None;
        }
        let mut plan: Vec<DeleteAction> = chosen
            .iter()
            .map(|is4k| DeleteAction::DeleteFiles { is4k: *is4k })
            .collect();
        // Seerr keeps the title while another version stays.
        if chosen.len() == self.versions.len() {
            plan.push(DeleteAction::ForgetMedia);
        }
        plan.push(DeleteAction::RefreshLibrary);
        plan.push(DeleteAction::VerifyGone);
        self.plan = plan;
        self.cursor = 0;
        self.flow = Flow::Running;
        self.version += 1;
        self.plan.first().copied()
    }

    /// The running action came back. Returns the next one; `None` when done or failed.
    pub fn finished(&mut self, result: Result<(), String>) -> Option<DeleteAction> {
        if self.flow != Flow::Running {
            return None;
        }
        self.version += 1;
        match result {
            Ok(()) => {
                self.cursor += 1;
                if self.cursor >= self.plan.len() {
                    self.flow = Flow::Done;
                    None
                } else {
                    Some(self.plan[self.cursor])
                }
            }
            Err(text) => {
                self.flow = Flow::Failed(text);
                None
            }
        }
    }

    /// "Nochmal versuchen": resumes at the failed action only.
    pub fn retry(&mut self) -> Option<DeleteAction> {
        if !matches!(self.flow, Flow::Failed(_)) {
            return None;
        }
        self.flow = Flow::Running;
        self.version += 1;
        self.plan.get(self.cursor).copied()
    }

    /// The failure text of an action when the host has none of its own.
    pub fn default_error(&self, action: DeleteAction) -> String {
        self.t.t(match action {
            DeleteAction::DeleteFiles { .. } => {
                "Radarr oder Sonarr hat die Dateien nicht gelöscht."
            }
            DeleteAction::ForgetMedia => "Seerr hat den Titel nicht entfernt.",
            DeleteAction::RefreshLibrary => "Jellyfin antwortet nicht.",
            DeleteAction::VerifyGone => "Der Titel ist noch in der Bibliothek.",
        })
    }

    /// The sheet now.
    pub fn info(&self) -> SeerrDeleteInfo {
        let t = &self.t;
        let mut steps: Vec<SeerrDeleteStep> = Vec::new();
        for (i, a) in self.plan.iter().enumerate() {
            let state = if i < self.cursor || self.flow == Flow::Done {
                StepState::Done
            } else if i == self.cursor {
                match self.flow {
                    Flow::Failed(_) => StepState::Failed,
                    _ => StepState::Running,
                }
            } else {
                StepState::Pending
            };
            let kind = kind_of(*a);
            // Several file deletes read as one row: the worst state of its group wins.
            if let Some(last) = steps.last_mut()
                && last.kind == kind
            {
                let rank = |s: StepState| match s {
                    StepState::Done => 0,
                    StepState::Pending => 1,
                    StepState::Running => 2,
                    StepState::Failed => 3,
                };
                if rank(state) > rank(last.state) {
                    last.state = state;
                }
                continue;
            }
            steps.push(SeerrDeleteStep {
                kind,
                label: t.t(match kind {
                    DeleteStepKind::Files => "Dateien gelöscht",
                    DeleteStepKind::Seerr => "In Seerr entfernt",
                    DeleteStepKind::Library => "Jellyfin liest neu ein",
                    DeleteStepKind::Verify => "Prüfen",
                }),
                state,
            });
        }
        let (phase, error) = match &self.flow {
            Flow::Confirm => (DeletePhase::Confirm, None),
            Flow::Running => (DeletePhase::Running, None),
            Flow::Failed(e) => (DeletePhase::Failed, Some(e.clone())),
            Flow::Done => (DeletePhase::Done, None),
        };
        SeerrDeleteInfo {
            version: self.version,
            phase,
            title: self.title.clone(),
            versions: self.versions.clone(),
            steps,
            headline: (phase == DeletePhase::Failed).then(|| t.t("Ein Schritt hängt")),
            error,
            can_retry: phase == DeletePhase::Failed,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_locked_device_offers_no_server_delete_to_anyone() {
        assert!(delete_allowed(true, false));
        assert!(!delete_allowed(true, true), "the lock wins over the right");
        assert!(!delete_allowed(false, false));
        assert!(!delete_allowed(false, true));
    }

    fn vm(versions: &[(bool, Option<String>)]) -> SeerrDeleteVm {
        SeerrDeleteVm::new(Locale::parse("de"), "Küstenwache", versions)
    }

    #[test]
    fn a_failed_step_keeps_the_earlier_ones_and_retry_resumes_there() {
        let mut vm = vm(&[(false, Some("4 GB".into()))]);
        assert_eq!(vm.info().phase, DeletePhase::Confirm);
        assert_eq!(
            vm.start(&[false]),
            Some(DeleteAction::DeleteFiles { is4k: false })
        );
        assert_eq!(vm.finished(Ok(())), Some(DeleteAction::ForgetMedia));
        assert_eq!(vm.finished(Ok(())), Some(DeleteAction::RefreshLibrary));
        assert_eq!(vm.finished(Err("Jellyfin antwortet nicht.".into())), None);
        let info = vm.info();
        assert_eq!(info.phase, DeletePhase::Failed);
        assert!(info.can_retry);
        assert_eq!(info.headline.as_deref(), Some("Ein Schritt hängt"));
        let states: Vec<StepState> = info.steps.iter().map(|s| s.state).collect();
        assert_eq!(
            states,
            [
                StepState::Done,
                StepState::Done,
                StepState::Failed,
                StepState::Pending
            ]
        );
        // Resumes at the failed step: no second file delete.
        assert_eq!(vm.retry(), Some(DeleteAction::RefreshLibrary));
        assert_eq!(vm.finished(Ok(())), Some(DeleteAction::VerifyGone));
        assert_eq!(vm.finished(Ok(())), None);
        let info = vm.info();
        assert_eq!(info.phase, DeletePhase::Done);
        assert!(info.steps.iter().all(|s| s.state == StepState::Done));
        let labels: Vec<&str> = info.steps.iter().map(|s| s.label.as_str()).collect();
        assert_eq!(
            labels,
            [
                "Dateien gelöscht",
                "In Seerr entfernt",
                "Jellyfin liest neu ein",
                "Prüfen"
            ]
        );
    }

    #[test]
    fn deleting_only_4k_keeps_the_title_in_seerr() {
        let mut vm = vm(&[(false, None), (true, None)]);
        assert_eq!(
            vm.start(&[true]),
            Some(DeleteAction::DeleteFiles { is4k: true })
        );
        assert_eq!(vm.finished(Ok(())), Some(DeleteAction::RefreshLibrary));
        let kinds: Vec<DeleteStepKind> = vm.info().steps.iter().map(|s| s.kind).collect();
        assert_eq!(
            kinds,
            [
                DeleteStepKind::Files,
                DeleteStepKind::Library,
                DeleteStepKind::Verify
            ]
        );
    }

    #[test]
    fn nothing_chosen_starts_nothing() {
        let mut vm = vm(&[(false, None)]);
        assert_eq!(vm.start(&[true]), None);
        assert_eq!(vm.info().phase, DeletePhase::Confirm);
    }
}

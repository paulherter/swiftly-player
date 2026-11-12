//! `DownloadTransport`: what a platform implements to do the actual transfer.
//!
//! iOS: a background `URLSession` in Swift (the app is suspended, so it must be native) with a
//! fixed session id, a delegate that moves the finished file before returning, and a re-attach
//! at launch. Android and desktop: `reqwest` in-process. tvOS: none.
//!
//! The transport never decides anything. It does what [`Effect`]s say and reports back as
//! [`TransferEvent`]s, which [`TransferEvent::into_intent`] turns into [`Intent`]s.

use crate::manager::{Effect, Intent, RunningTransfer};
use crate::task::TaskParts;

/// What the platform's transfer layer implements. All methods return at once; results arrive
/// later as [`TransferEvent`]s.
pub trait DownloadTransport: Send + Sync {
    /// Start a transfer. `parts.description()` must travel with it so callbacks can be matched;
    /// `resume` is opaque data returned by an earlier cancel.
    fn start(&self, parts: &TaskParts, address: &str, resume: Option<&[u8]>);

    /// Cancel the transfer of `id` (the one with `task_generation`). When `want_resume_data` is
    /// set, report [`TransferEvent::ResumeData`] tagged with `new_generation` if data exists.
    fn cancel(
        &self,
        id: &str,
        task_generation: Option<i64>,
        new_generation: i64,
        want_resume_data: bool,
    );

    /// Resume a suspended transfer that was adopted.
    fn resume(&self, id: &str);

    /// The transfers the system still has from an earlier run. The caller feeds the answer in as
    /// [`Intent::RunningTransfers`].
    fn running(&self) -> Vec<RunningTransfer>;
}

/// What the transfer layer reports.
#[derive(Debug, Clone, PartialEq)]
pub enum TransferEvent {
    /// Bytes arrived.
    Progress {
        /// Which transfer.
        parts: TaskParts,
        /// Bytes on disk.
        loaded: i64,
        /// Bytes expected (0 if unknown).
        total: i64,
        /// Clock reading in seconds.
        now: f64,
    },
    /// The transfer finished; the file is (or is not) in place.
    Finished {
        /// Which transfer.
        parts: TaskParts,
        /// The file was moved into place.
        worked: bool,
        /// Its size on disk.
        real_size: Option<i64>,
    },
    /// The transfer failed or was cancelled (`resume` data makes it a pause).
    Failed {
        /// Which transfer.
        parts: TaskParts,
        /// Readable reason.
        reason: String,
        /// Resume data.
        resume: Option<Vec<u8>>,
    },
    /// Resume data that arrived after a cancel.
    ResumeData {
        /// Item id.
        id: String,
        /// The cancel's `new_generation`.
        generation: i64,
        /// The data.
        data: Vec<u8>,
    },
}

impl TransferEvent {
    /// The intent for the state machine.
    pub fn into_intent(self) -> Intent {
        match self {
            Self::Progress {
                parts,
                loaded,
                total,
                now,
            } => Intent::Progress {
                parts,
                loaded,
                total,
                now,
            },
            Self::Finished {
                parts,
                worked,
                real_size,
            } => Intent::TransferFinished {
                parts,
                worked,
                real_size,
            },
            Self::Failed {
                parts,
                reason,
                resume,
            } => Intent::TransferFailed {
                parts,
                reason,
                resume,
            },
            Self::ResumeData {
                id,
                generation,
                data,
            } => Intent::ResumeData {
                id,
                generation,
                data,
            },
        }
    }
}

/// Run the transfer-related effects on a transport. Returns `true` if the effect was one of
/// them; the others (persist, delete, fetch, address, report) belong to other platform services.
pub fn apply_effect(transport: &dyn DownloadTransport, effect: &Effect) -> bool {
    match effect {
        Effect::StartTransfer {
            parts,
            address,
            resume,
        } => {
            transport.start(parts, address, resume.as_deref());
            true
        }
        Effect::CancelTransfer {
            id,
            task_generation,
            new_generation,
            want_resume_data,
        } => {
            transport.cancel(id, *task_generation, *new_generation, *want_resume_data);
            true
        }
        Effect::ResumeTransfer { id } => {
            transport.resume(id);
            true
        }
        _ => false,
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::manager::FileKind;
    use crate::task::DownloadTask;
    use std::sync::Mutex;

    /// What a scripted transport saw, in order.
    #[derive(Debug, Clone, PartialEq)]
    enum Call {
        Start(TaskParts, String, Option<Vec<u8>>),
        Cancel(String, Option<i64>, i64, bool),
        Resume(String),
    }

    #[derive(Default)]
    struct Recorder {
        calls: Mutex<Vec<Call>>,
        running: Vec<RunningTransfer>,
    }

    impl DownloadTransport for Recorder {
        fn start(&self, parts: &TaskParts, address: &str, resume: Option<&[u8]>) {
            self.calls.lock().unwrap().push(Call::Start(
                parts.clone(),
                address.to_string(),
                resume.map(<[u8]>::to_vec),
            ));
        }
        fn cancel(&self, id: &str, g: Option<i64>, new_g: i64, want: bool) {
            self.calls
                .lock()
                .unwrap()
                .push(Call::Cancel(id.to_string(), g, new_g, want));
        }
        fn resume(&self, id: &str) {
            self.calls
                .lock()
                .unwrap()
                .push(Call::Resume(id.to_string()));
        }
        fn running(&self) -> Vec<RunningTransfer> {
            self.running.clone()
        }
    }

    fn parts() -> TaskParts {
        TaskParts::new("abc", 4, "abc.mkv")
    }

    #[test]
    fn progress_event_becomes_progress_intent() {
        let intent = TransferEvent::Progress {
            parts: parts(),
            loaded: 10,
            total: 0,
            now: 1.5,
        }
        .into_intent();
        let Intent::Progress {
            parts: p,
            loaded,
            total,
            now,
        } = intent
        else {
            panic!("expected Progress");
        };
        assert_eq!((p, loaded, total, now), (parts(), 10, 0, 1.5));
    }

    #[test]
    fn finished_event_keeps_worked_and_real_size() {
        for (worked, size) in [(true, Some(99)), (false, None)] {
            let intent = TransferEvent::Finished {
                parts: parts(),
                worked,
                real_size: size,
            }
            .into_intent();
            let Intent::TransferFinished {
                parts: p,
                worked: w,
                real_size,
            } = intent
            else {
                panic!("expected TransferFinished");
            };
            assert_eq!((p, w, real_size), (parts(), worked, size));
        }
    }

    #[test]
    fn failed_event_carries_reason_and_resume_data() {
        let intent = TransferEvent::Failed {
            parts: parts(),
            reason: "offline".into(),
            resume: Some(vec![1, 2, 3]),
        }
        .into_intent();
        let Intent::TransferFailed {
            parts: p,
            reason,
            resume,
        } = intent
        else {
            panic!("expected TransferFailed");
        };
        assert_eq!(p, parts());
        assert_eq!(reason, "offline");
        assert_eq!(resume, Some(vec![1, 2, 3]));
        let plain = TransferEvent::Failed {
            parts: parts(),
            reason: "x".into(),
            resume: None,
        }
        .into_intent();
        assert!(matches!(plain, Intent::TransferFailed { resume: None, .. }));
    }

    #[test]
    fn resume_data_event_keeps_generation() {
        let intent = TransferEvent::ResumeData {
            id: "abc".into(),
            generation: 12,
            data: vec![9],
        }
        .into_intent();
        let Intent::ResumeData {
            id,
            generation,
            data,
        } = intent
        else {
            panic!("expected ResumeData");
        };
        assert_eq!((id.as_str(), generation, data), ("abc", 12, vec![9]));
    }

    #[test]
    fn start_effect_reaches_transport_with_resume_data() {
        let t = Recorder::default();
        let fx = Effect::StartTransfer {
            parts: parts(),
            address: "http://h/file".into(),
            resume: Some(vec![7, 7]),
        };
        assert!(apply_effect(&t, &fx));
        let fresh = Effect::StartTransfer {
            parts: parts(),
            address: "http://h/other".into(),
            resume: None,
        };
        assert!(apply_effect(&t, &fresh));
        assert_eq!(
            *t.calls.lock().unwrap(),
            vec![
                Call::Start(parts(), "http://h/file".into(), Some(vec![7, 7])),
                Call::Start(parts(), "http://h/other".into(), None),
            ]
        );
    }

    #[test]
    fn cancel_and_resume_effects_pass_every_field() {
        let t = Recorder::default();
        assert!(apply_effect(
            &t,
            &Effect::CancelTransfer {
                id: "abc".into(),
                task_generation: Some(3),
                new_generation: 5,
                want_resume_data: true,
            }
        ));
        assert!(apply_effect(
            &t,
            &Effect::CancelTransfer {
                id: "def".into(),
                task_generation: None,
                new_generation: 6,
                want_resume_data: false,
            }
        ));
        assert!(apply_effect(
            &t,
            &Effect::ResumeTransfer { id: "abc".into() }
        ));
        assert_eq!(
            *t.calls.lock().unwrap(),
            vec![
                Call::Cancel("abc".into(), Some(3), 5, true),
                Call::Cancel("def".into(), None, 6, false),
                Call::Resume("abc".into()),
            ]
        );
    }

    #[test]
    fn other_effects_are_left_alone() {
        let t = Recorder::default();
        let others = [
            Effect::Persist(Vec::new()),
            Effect::FindRunningTransfers,
            Effect::MeasureSpace,
            Effect::DeleteFile {
                kind: FileKind::Media,
                name: "a.mkv".into(),
            },
            Effect::FetchImage {
                name: "a.jpg".into(),
                url: "http://h/a".into(),
            },
            Effect::FetchSections { id: "abc".into() },
        ];
        for fx in &others {
            assert!(
                !apply_effect(&t, fx),
                "{fx:?} must not be a transfer effect"
            );
        }
        assert!(t.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn running_transfers_come_back_with_a_decodable_description() {
        let r = RunningTransfer {
            description: Some(parts().description()),
            suspended: true,
            bytes_received: 1024,
        };
        let t = Recorder {
            running: vec![r.clone()],
            ..Recorder::default()
        };
        let got = t.running();
        assert_eq!(got, vec![r]);
        assert_eq!(
            DownloadTask::dismantle(got[0].description.as_deref()),
            Some(parts())
        );
    }

    #[test]
    fn description_with_separator_in_file_name_survives_the_transport() {
        let t = Recorder::default();
        let fx = Effect::StartTransfer {
            parts: TaskParts::new("a", 2, "x\u{1F}y.mkv"),
            address: "u".into(),
            resume: None,
        };
        apply_effect(&t, &fx);
        let Call::Start(p, _, _) = t.calls.lock().unwrap()[0].clone() else {
            panic!("expected start");
        };
        let back = DownloadTask::dismantle(Some(&p.description())).unwrap();
        assert_eq!(back, p);
    }
}

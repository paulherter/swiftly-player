//! When the server notice over stored Start rows comes and goes.
//!
//! The notice is a block of about 250 pt in the rows' column, so coming or going it moves every row below it. It changes
//! only while the page is at its top (scrolled down, the change waits for the way back instead of pushing what the
//! reader is looking at), and the column makes room in one eased move (`feel::change()`, none under Reduce Motion)
//! instead of in one frame. Leaving, the block stays in the tree while its frame closes and is dropped once it has
//! got there; it keeps the words it showed meanwhile, so the text does not change while it fades.

use swiftly_vm::{FailKind, LoadFailure, Status};

/// The page counts as "at the top" below this offset (the Apple page's `offset + inset < 40`).
pub(crate) const AT_TOP: f32 = 40.0;

/// A moment after the curve has settled, so the last frame of the move is drawn before the block is dropped.
const AFTER_SETTLE_MS: f64 = 32.0;

/// What the notice says and whether its button waits for a retry.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Words {
    pub failure: LoadFailure,
    pub busy: bool,
}

/// Where the notice is in its coming and going.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) enum NoticeFlow {
    /// Not in the tree.
    #[default]
    Gone,
    /// Stands above the rows.
    Open(Words),
    /// Closing: still in the tree while its frame shrinks, until `since_ms` plus the settle time.
    Closing { words: Words, since_ms: f64 },
}

/// The notice the page asks for: stored rows (the full-page notice has no rows) and the server does not answer. Only the
/// two "does not answer" failures; a refused sign-in or an unreadable answer have their own page. A retry in flight
/// (`busy`) keeps the block, its button waits.
pub(crate) fn wanted(
    status: Status,
    has_rows: bool,
    waiting: Option<LoadFailure>,
    failure: LoadFailure,
) -> Option<Words> {
    let busy = status == Status::Loading && waiting.is_some();
    if !has_rows || !(status == Status::Offline || busy) {
        return None;
    }
    let failure = waiting.unwrap_or(failure);
    matches!(
        failure,
        LoadFailure::Offline | LoadFailure::Failed(FailKind::Server)
    )
    .then_some(Words { failure, busy })
}

impl NoticeFlow {
    /// One step at `now` ms. `settle_ms` is how long a closing frame takes (0: the block goes at once).
    pub(crate) fn step(self, want: Option<Words>, at_top: bool, now: f64, settle_ms: f64) -> Self {
        match (self, want) {
            (Self::Gone, Some(words)) if at_top => Self::Open(words),
            (Self::Gone, _) => Self::Gone,
            // The words and the busy button follow in place; only a change of the block's presence waits for the top.
            (Self::Open(_), Some(words)) => Self::Open(words),
            (Self::Open(words), None) if at_top => Self::Closing {
                words,
                since_ms: now,
            },
            (open @ Self::Open(_), None) => open,
            (Self::Closing { .. }, Some(words)) if at_top => Self::Open(words),
            (Self::Closing { since_ms, .. }, _)
                if now >= since_ms + settle_ms + AFTER_SETTLE_MS =>
            {
                Self::Gone
            }
            (closing @ Self::Closing { .. }, _) => closing,
        }
    }

    /// A closing block that no frame has dropped yet: frames keep coming until it is gone.
    pub(crate) fn closing(self) -> bool {
        matches!(self, Self::Closing { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: Words = Words {
        failure: LoadFailure::Offline,
        busy: false,
    };

    #[test]
    fn it_wants_the_notice_only_over_rows_for_the_two_failures() {
        let f = LoadFailure::Offline;
        assert_eq!(wanted(Status::Offline, true, None, f), Some(W));
        assert_eq!(wanted(Status::Offline, false, None, f), None);
        assert_eq!(wanted(Status::Ready, true, None, f), None);
        assert_eq!(
            wanted(
                Status::Offline,
                true,
                None,
                LoadFailure::Failed(FailKind::Denied)
            ),
            None
        );
        // A retry in flight keeps the block with a waiting button.
        let busy = wanted(Status::Loading, true, Some(f), f).expect("busy");
        assert!(busy.busy);
        assert_eq!(wanted(Status::Loading, true, None, f), None);
    }

    #[test]
    fn it_opens_and_closes_only_at_the_top() {
        let mut s = NoticeFlow::Gone;
        s = s.step(Some(W), false, 0.0, 280.0);
        assert_eq!(s, NoticeFlow::Gone, "scrolled down: it waits");
        s = s.step(Some(W), true, 10.0, 280.0);
        assert_eq!(s, NoticeFlow::Open(W));
        s = s.step(None, false, 20.0, 280.0);
        assert_eq!(s, NoticeFlow::Open(W), "scrolled down: it stays");
        s = s.step(None, true, 30.0, 280.0);
        assert_eq!(
            s,
            NoticeFlow::Closing {
                words: W,
                since_ms: 30.0
            }
        );
    }

    #[test]
    fn it_drops_the_closing_block_after_the_settle_time_and_not_before() {
        let closing = NoticeFlow::Closing {
            words: W,
            since_ms: 100.0,
        };
        assert!(closing.step(None, true, 100.0 + 280.0, 280.0).closing());
        assert_eq!(
            closing.step(None, true, 100.0 + 280.0 + AFTER_SETTLE_MS, 280.0),
            NoticeFlow::Gone
        );
        // Reduce Motion: no settle time, gone at the next step past the margin.
        assert_eq!(
            closing.step(None, true, 100.0 + AFTER_SETTLE_MS, 0.0),
            NoticeFlow::Gone
        );
    }

    #[test]
    fn it_reopens_while_closing_and_keeps_the_words() {
        let closing = NoticeFlow::Closing {
            words: W,
            since_ms: 0.0,
        };
        let busy = Words { busy: true, ..W };
        assert_eq!(
            closing.step(Some(busy), true, 50.0, 280.0),
            NoticeFlow::Open(busy)
        );
        assert_eq!(
            NoticeFlow::Open(W).step(Some(busy), false, 60.0, 280.0),
            NoticeFlow::Open(busy),
            "the button waits in place, whatever the scroll"
        );
    }
}

//! Single-threaded UI executor, worker pool, modal asks, channels and the UI root handle (std only).
//! Copied from Sequence Studio's `sq-runtime` (same author), see `LICENSES/PROVENANCE`.
pub mod channel;
pub mod clock;
pub mod executor;
pub mod group;
pub mod inbox;
pub mod modal;
pub mod pool;
pub mod root;
pub mod testing;

pub use clock::{Clock, FakeClock, SystemClock};
pub use executor::{
    Cancelled, FrameStats, JoinError, JoinHandle, UiExecutor, is_cancelled, sleep,
    spawn_cooperative, spawn_local, yield_now,
};
pub use group::TaskGroup;
pub use inbox::Inbox;
pub use modal::{Dismissed, ModalAnswer, ModalAsk, modal};
pub use pool::{JobCtl, WorkFuture, WorkerPanic, WorkerPool};
pub use root::{UiRef, UiRoot};

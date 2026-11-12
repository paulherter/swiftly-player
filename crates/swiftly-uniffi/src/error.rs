use std::fmt;

use swiftly_net::ErrorKind;

/// Every async export returns this: a cancelled Swift `Task` surfaces as `CancellationError`
/// in Swift, so a call must be able to throw (see the xtask patch of the generated Swift).
#[derive(Debug, uniffi::Error)]
pub enum CoreError {
    /// The thing being observed is gone.
    Closed,
    /// Anything else, with a message that never contains a secret.
    Failed {
        /// What went wrong.
        message: String,
    },
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Closed => f.write_str("closed"),
            Self::Failed { message } => write!(f, "failed: {message}"),
        }
    }
}

impl std::error::Error for CoreError {}

impl From<ErrorKind> for CoreError {
    fn from(kind: ErrorKind) -> Self {
        Self::Failed {
            message: format!("{kind:?}"),
        }
    }
}

/// Why a supporter key was refused (feature `supporter-key`).
#[cfg(feature = "supporter-key")]
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum SupporterKeyError {
    /// `failure` is the shared word, for example `badSignature` or `expired`.
    Refused { failure: String },
}

#[cfg(feature = "supporter-key")]
impl std::fmt::Display for SupporterKeyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Refused { failure } => write!(f, "{failure}"),
        }
    }
}
#[cfg(feature = "supporter-key")]
impl std::error::Error for SupporterKeyError {}

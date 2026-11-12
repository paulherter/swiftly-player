use std::time::Duration;

/// Longest time for checking a typed address (`AddressCheck.deadline`, AddressCheck.swift:56).
/// Both the request and the whole call; a typo must not hang as long as a normal call.
pub const ADDRESS_CHECK_DEADLINE: Duration = Duration::from_secs(8);

/// The number of one address check, so an old answer can be told from the current one
/// (`CheckMark`, AddressCheck.swift:9-12).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckMark {
    /// Running number.
    pub number: u64,
    /// The address that was checked.
    pub address: String,
}

/// Which address check is the current one (`CheckState`, AddressCheck.swift:20-60). An answer
/// from an older check, or from one the user changed their mind about, is discarded.
#[derive(Debug, Clone, Default)]
pub struct CheckState {
    ongoing: Option<CheckMark>,
    counter: u64,
}

impl CheckState {
    /// A fresh state.
    pub fn new() -> Self {
        Self::default()
    }

    /// The check that is running now, if any.
    pub fn ongoing(&self) -> Option<&CheckMark> {
        self.ongoing.as_ref()
    }

    /// Starts a check; it replaces the running one.
    pub fn begin(&mut self, address: &str) -> CheckMark {
        self.counter += 1;
        let mark = CheckMark {
            number: self.counter,
            address: address.into(),
        };
        self.ongoing = Some(mark.clone());
        mark
    }

    /// Is this check still the current one?
    pub fn applies(&self, mark: &CheckMark) -> bool {
        self.ongoing.as_ref() == Some(mark)
    }

    /// Ends a check. `true` only if it was the current one (so the answer may act).
    pub fn complete(&mut self, mark: &CheckMark) -> bool {
        if !self.applies(mark) {
            return false;
        }
        self.ongoing = None;
        true
    }

    /// Drops the running check (the address changed).
    pub fn discard(&mut self) {
        self.ongoing = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // AddressCheckTests.swift:9 oldResponseBecomesDiscarded
    #[test]
    fn old_response_becomes_discarded() {
        let mut state = CheckState::new();
        let old = state.begin("gibtsnicht.example");
        let new = state.begin("tv.example.de");
        assert!(!state.applies(&old));
        assert!(state.applies(&new));
        assert!(!state.complete(&old));
        assert_eq!(state.ongoing(), Some(&new));
        assert!(state.complete(&new));
        assert_eq!(state.ongoing(), None);
    }

    // :22 changedAddressThrowsCheck
    #[test]
    fn changed_address_throws_check() {
        let mut state = CheckState::new();
        let mark = state.begin("tv.example");
        state.discard();
        assert!(!state.applies(&mark));
        assert!(!state.complete(&mark));
    }

    // :30 marksAreInUnambiguousAlsoSameAddress
    #[test]
    fn marks_differ_even_for_the_same_address() {
        let mut state = CheckState::new();
        let first = state.begin("tv.example.de");
        let second = state.begin("tv.example.de");
        assert_ne!(first, second);
        assert!(!state.applies(&first));
    }
}

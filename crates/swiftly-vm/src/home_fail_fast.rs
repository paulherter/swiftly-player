//! A home load that gives up on the server as soon as it is known to be unreachable.
//!
//! A server that refuses the connection refuses every call of the page. The load used to find that out call by call:
//! each fetch was tried three times by the network layer, and the fallback chain of a split "new" row asked the next
//! level after every failed one. A refused connect takes 1.5 s (Apple, `waitsForConnectivity` grace) to 2 s (Windows)
//! per try, so the notice over the stored rows came after 6 to 9 s.
//!
//! Now the whole run sends each call once (the retry is the page's own "try again", see `home::begin_run`), and this
//! wrapper stops the run after the first call that did not get through: every later call of the same run is answered at
//! once with the same failure, without touching the network. The page then reports `Offline` as soon as that one try ends.

use std::sync::OnceLock;

use swiftly_library::home::HomePageSource;
use swiftly_model::Item;
use swiftly_net::{ErrorKind, url_error};

/// The wrapped source and the failure of the first call that did not get through (set once, never cleared: one
/// wrapper serves one run).
pub(crate) struct FailFast<'a, S: HomePageSource> {
    source: &'a S,
    unreachable: OnceLock<i32>,
}

impl<'a, S: HomePageSource> FailFast<'a, S> {
    pub(crate) fn new(source: &'a S) -> Self {
        Self {
            source,
            unreachable: OnceLock::new(),
        }
    }

    /// Whether the server was found unreachable during this run.
    #[cfg(test)]
    pub(crate) fn is_down(&self) -> bool {
        self.unreachable.get().is_some()
    }

    /// The failure every call gets once the server is known to be unreachable.
    fn refused(&self) -> Option<ErrorKind> {
        self.unreachable
            .get()
            .map(|code| ErrorKind::Network { code: *code })
    }

    /// Remembers a call that did not get through. A caller that gave up (`Cancelled`) says nothing about the server.
    fn note(&self, answer: &Result<Vec<Item>, ErrorKind>) {
        if let Err(ErrorKind::Network { code }) = answer
            && *code != url_error::CANCELLED
        {
            let _ = self.unreachable.set(*code);
        }
    }
}

impl<S: HomePageSource> HomePageSource for FailFast<'_, S> {
    async fn resume_items(&self, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        if let Some(refused) = self.refused() {
            return Err(refused);
        }
        let answer = self.source.resume_items(limit).await;
        self.note(&answer);
        answer
    }
    async fn next_up(&self, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        if let Some(refused) = self.refused() {
            return Err(refused);
        }
        let answer = self.source.next_up(limit).await;
        self.note(&answer);
        answer
    }
    async fn last_added(
        &self,
        library: Option<&str>,
        fetch: i64,
        show_item: i64,
    ) -> Option<Vec<Item>> {
        if self.unreachable.get().is_some() {
            return None;
        }
        self.source.last_added(library, fetch, show_item).await
    }
    async fn title(&self, genre: &str, limit: i64) -> Option<Vec<Item>> {
        if self.unreachable.get().is_some() {
            return None;
        }
        self.source.title(genre, limit).await
    }
    async fn libraries(&self) -> Option<Vec<Item>> {
        if self.unreachable.get().is_some() {
            return None;
        }
        self.source.libraries().await
    }
    async fn new_arrivals(&self, genre: &str, fetch: i64, show_item: i64) -> Option<Vec<Item>> {
        if self.unreachable.get().is_some() {
            return None;
        }
        self.source.new_arrivals(genre, fetch, show_item).await
    }
    async fn new_series(&self, library: Option<&str>, show_item: i64) -> Option<Vec<Item>> {
        if self.unreachable.get().is_some() {
            return None;
        }
        self.source.new_series(library, show_item).await
    }
    async fn latest_title(
        &self,
        library: &str,
        collection: bool,
        show_item: i64,
    ) -> Option<Vec<Item>> {
        if self.unreachable.get().is_some() {
            return None;
        }
        self.source
            .latest_title(library, collection, show_item)
            .await
    }
    fn merges_libraries(&self) -> bool {
        self.source.merges_libraries()
    }
    fn log(&self, line: &str) {
        self.source.log(line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_executor::block_on;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// What the wrapped source answers to the two throwing calls, and how often anything reached it.
    struct Source {
        resume: Result<Vec<Item>, ErrorKind>,
        reached: AtomicUsize,
    }

    impl Source {
        fn answering(resume: Result<Vec<Item>, ErrorKind>) -> Self {
            Self {
                resume,
                reached: AtomicUsize::new(0),
            }
        }
        fn reached(&self) -> usize {
            self.reached.load(Ordering::SeqCst)
        }
        fn hit(&self) {
            self.reached.fetch_add(1, Ordering::SeqCst);
        }
    }

    impl HomePageSource for Source {
        async fn resume_items(&self, _limit: i64) -> Result<Vec<Item>, ErrorKind> {
            self.hit();
            self.resume.clone()
        }
        async fn next_up(&self, _limit: i64) -> Result<Vec<Item>, ErrorKind> {
            self.hit();
            Ok(Vec::new())
        }
        async fn last_added(&self, _l: Option<&str>, _f: i64, _s: i64) -> Option<Vec<Item>> {
            self.hit();
            Some(Vec::new())
        }
        async fn title(&self, _g: &str, _l: i64) -> Option<Vec<Item>> {
            self.hit();
            Some(Vec::new())
        }
        async fn libraries(&self) -> Option<Vec<Item>> {
            self.hit();
            Some(Vec::new())
        }
        async fn new_arrivals(&self, _g: &str, _f: i64, _s: i64) -> Option<Vec<Item>> {
            self.hit();
            Some(Vec::new())
        }
        async fn new_series(&self, _l: Option<&str>, _s: i64) -> Option<Vec<Item>> {
            self.hit();
            Some(Vec::new())
        }
        async fn latest_title(&self, _l: &str, _c: bool, _s: i64) -> Option<Vec<Item>> {
            self.hit();
            Some(Vec::new())
        }
    }

    const REFUSED: ErrorKind = ErrorKind::Network {
        code: url_error::CANNOT_CONNECT_TO_HOST,
    };

    #[test]
    fn after_the_first_call_that_did_not_get_through_nothing_more_is_sent() {
        let inner = Source::answering(Err(REFUSED));
        let source = FailFast::new(&inner);
        assert!(!source.is_down());
        assert_eq!(block_on(source.resume_items(20)), Err(REFUSED));
        assert!(source.is_down());
        assert_eq!(inner.reached(), 1);
        // Every later call of the run is answered at once, with the same failure, without reaching the source.
        assert_eq!(block_on(source.next_up(20)), Err(REFUSED));
        assert_eq!(block_on(source.last_added(None, 200, 24)), None);
        assert_eq!(block_on(source.title("Drama", 24)), None);
        assert_eq!(block_on(source.libraries()), None);
        assert_eq!(block_on(source.new_arrivals("Movie", 200, 24)), None);
        assert_eq!(block_on(source.new_series(None, 24)), None);
        assert_eq!(block_on(source.latest_title("lib", false, 24)), None);
        assert_eq!(inner.reached(), 1, "the refused server is not asked again");
    }

    #[test]
    fn a_failure_that_says_nothing_about_the_server_does_not_stop_the_run() {
        for failure in [
            ErrorKind::Cancelled,
            ErrorKind::Http {
                status: 500,
                body: None,
            },
            ErrorKind::Decoding("x".into()),
        ] {
            let inner = Source::answering(Err(failure));
            let source = FailFast::new(&inner);
            assert!(block_on(source.resume_items(20)).is_err());
            assert!(!source.is_down());
            assert_eq!(block_on(source.next_up(20)), Ok(Vec::new()));
            assert_eq!(block_on(source.libraries()), Some(Vec::new()));
            assert_eq!(inner.reached(), 3);
        }
    }
}

//! The account's libraries for one home load, asked at most once and never ahead of the rest.
//!
//! The loader reads the library list (to pick the library of a split "new" row) while the page
//! also keeps it for its snapshot. Without this wrapper a cold load asked for it twice, one wave
//! before everything else; a warm load asked again although the snapshot already had it.

use std::future::Future;

use futures_util::future::{BoxFuture, FutureExt, Shared};
use swiftly_library::home::HomePageSource;
use swiftly_model::Item;
use swiftly_net::ErrorKind;

/// A page source whose `libraries()` answers from the known list, or from one shared request
/// that every caller awaits together. Everything else goes to the wrapped source unchanged.
pub(crate) struct ViewsOnce<'a, S: HomePageSource> {
    source: &'a S,
    libraries: Shared<BoxFuture<'a, Option<Vec<Item>>>>,
}

impl<'a, S: HomePageSource> ViewsOnce<'a, S> {
    /// `known` is the list the page already has (the stored snapshot); empty means "ask the server".
    pub(crate) fn new(source: &'a S, known: Vec<Item>) -> Self {
        let libraries = async move {
            if known.is_empty() {
                source.libraries().await
            } else {
                Some(known)
            }
        }
        .boxed()
        .shared();
        Self { source, libraries }
    }
}

impl<S: HomePageSource> HomePageSource for ViewsOnce<'_, S> {
    fn resume_items(
        &self,
        limit: i64,
    ) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send {
        self.source.resume_items(limit)
    }
    fn next_up(
        &self,
        limit: i64,
        enable_rewatching: bool,
        date_cutoff: &str,
    ) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send {
        self.source.next_up(limit, enable_rewatching, date_cutoff)
    }
    fn last_added(
        &self,
        library: Option<&str>,
        fetch: i64,
        show_item: i64,
    ) -> impl Future<Output = Option<Vec<Item>>> + Send {
        self.source.last_added(library, fetch, show_item)
    }
    fn title(&self, genre: &str, limit: i64) -> impl Future<Output = Option<Vec<Item>>> + Send {
        self.source.title(genre, limit)
    }
    fn libraries(&self) -> impl Future<Output = Option<Vec<Item>>> + Send {
        self.libraries.clone()
    }
    fn new_arrivals(
        &self,
        genre: &str,
        fetch: i64,
        show_item: i64,
    ) -> impl Future<Output = Option<Vec<Item>>> + Send {
        self.source.new_arrivals(genre, fetch, show_item)
    }
    fn new_series(
        &self,
        library: Option<&str>,
        show_item: i64,
    ) -> impl Future<Output = Option<Vec<Item>>> + Send {
        self.source.new_series(library, show_item)
    }
    fn latest_title(
        &self,
        library: &str,
        collection: bool,
        show_item: i64,
    ) -> impl Future<Output = Option<Vec<Item>>> + Send {
        self.source.latest_title(library, collection, show_item)
    }
    fn merges_libraries(&self) -> bool {
        self.source.merges_libraries()
    }
    fn log(&self, line: &str) {
        self.source.log(line);
    }
}

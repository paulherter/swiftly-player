//! What the "Bibliothek hinzufügen" and "Genre hinzufügen" pages offer: the libraries and genres of the server of the
//! account (`AppModel.startSelection()` / `AppModel.genres()`). The page talks to [`HomeChoices`]; the demo uses
//! [`ScriptedChoices`], the real app [`LiveChoices`], which asks the server on the Core runtime.

use std::sync::{Arc, Mutex};
use swiftly_library::start_libraries::{StartLibraries, StartLibrary};

/// The answer of the server to one list.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum Offer<T> {
    /// Not asked yet.
    #[default]
    Idle,
    /// The question is out.
    Loading,
    /// The server did not answer (the page offers a retry).
    Failed,
    /// The entries.
    Ready(Vec<T>),
}

/// The lists as the pages use them.
pub trait HomeChoices {
    /// The libraries the server has that carry a poster row.
    fn libraries(&self) -> Offer<StartLibrary>;
    /// The genre names of the server.
    fn genres(&self) -> Offer<String>;
    /// Asks the server for the libraries (every time the page opens).
    fn load_libraries(&self);
    /// Asks the server for the genres.
    fn load_genres(&self);
}

/// A fixed answer (the demo and the tests).
pub struct ScriptedChoices {
    libraries: Mutex<Offer<StartLibrary>>,
    genres: Mutex<Offer<String>>,
}

impl ScriptedChoices {
    /// Answers at once with these lists.
    pub fn new(libraries: Vec<StartLibrary>, genres: Vec<String>) -> Self {
        Self {
            libraries: Mutex::new(Offer::Ready(libraries)),
            genres: Mutex::new(Offer::Ready(genres)),
        }
    }

    /// A server that does not answer.
    pub fn failing() -> Self {
        Self {
            libraries: Mutex::new(Offer::Failed),
            genres: Mutex::new(Offer::Failed),
        }
    }
}

fn read<T: Clone>(m: &Mutex<Offer<T>>) -> Offer<T> {
    m.lock().map(|g| g.clone()).unwrap_or(Offer::Failed)
}

impl HomeChoices for ScriptedChoices {
    fn libraries(&self) -> Offer<StartLibrary> {
        read(&self.libraries)
    }
    fn genres(&self) -> Offer<String> {
        read(&self.genres)
    }
    fn load_libraries(&self) {}
    fn load_genres(&self) {}
}

/// The real lists over the Core runtime.
pub struct LiveChoices {
    core: Arc<crate::live::Core>,
    libraries: Arc<Mutex<Offer<StartLibrary>>>,
    genres: Arc<Mutex<Offer<String>>>,
}

impl LiveChoices {
    /// Nothing is asked until a page opens.
    pub fn new(core: Arc<crate::live::Core>) -> Self {
        Self {
            core,
            libraries: Arc::default(),
            genres: Arc::default(),
        }
    }
}

fn set<T>(m: &Mutex<Offer<T>>, v: Offer<T>) {
    if let Ok(mut g) = m.lock() {
        *g = v;
    }
}

impl HomeChoices for LiveChoices {
    fn libraries(&self) -> Offer<StartLibrary> {
        read(&self.libraries)
    }
    fn genres(&self) -> Offer<String> {
        read(&self.genres)
    }

    fn load_libraries(&self) {
        let (core, out) = (Arc::clone(&self.core), Arc::clone(&self.libraries));
        let Some(account) = core.account() else {
            set(&out, Offer::Failed);
            return;
        };
        set(&out, Offer::Loading);
        let worker = Arc::clone(&core);
        core.spawn(async move {
            let answer = match worker.server_for(&account) {
                Ok(server) => crate::live_server::views_and_shares(&server)
                    .await
                    .map(|(views, _)| {
                        views
                            .iter()
                            .filter(|v| StartLibraries::selectable(v))
                            .map(StartLibrary::from_item)
                            .collect::<Vec<_>>()
                    })
                    .ok(),
                Err(_) => None,
            };
            set(&out, answer.map_or(Offer::Failed, Offer::Ready));
        });
    }

    fn load_genres(&self) {
        let (core, out) = (Arc::clone(&self.core), Arc::clone(&self.genres));
        let Some(account) = core.account() else {
            set(&out, Offer::Failed);
            return;
        };
        set(&out, Offer::Loading);
        let worker = Arc::clone(&core);
        core.spawn(async move {
            let answer = match worker.server_for(&account) {
                Ok(server) => crate::live_server::genres(&server).await.ok(),
                Err(_) => None,
            };
            set(&out, answer.map_or(Offer::Failed, Offer::Ready));
        });
    }
}

//! Two device switches that the core reads where no settings store is at hand (decoding a server list, the
//! delete flow). The settings view model owns them: it writes them when a switch changes and when it starts.
//! Everything that filters or offers by these switches asks here, so no host decides on its own.

use std::sync::atomic::{AtomicBool, Ordering};

use crate::Item;

static HIDE_EMPTY_SERIES: AtomicBool = AtomicBool::new(true);
static SERVER_DELETE_LOCKED: AtomicBool = AtomicBool::new(false);

/// Series without episodes stay out of every list (libraries, home rows, search). On unless switched off.
pub fn hides_empty_series() -> bool {
    HIDE_EMPTY_SERIES.load(Ordering::Relaxed)
}

/// Sets "Leere Serien ausblenden".
pub fn set_hide_empty_series(on: bool) {
    HIDE_EMPTY_SERIES.store(on, Ordering::Relaxed);
}

/// "Löschen vom Server sperren" is on: no "Vom Server löschen" action is offered or runs.
pub fn server_delete_locked() -> bool {
    SERVER_DELETE_LOCKED.load(Ordering::Relaxed)
}

/// Sets "Löschen vom Server sperren".
pub fn set_server_delete_locked(on: bool) {
    SERVER_DELETE_LOCKED.store(on, Ordering::Relaxed);
}

/// The one place that applies "Leere Serien ausblenden" to a list: drops the series that [`Item::is_hollow_series`] names,
/// unless the device switched the rule off. Every list a server returns (Jellyfin, Emby, Plex) goes through this.
pub fn without_hollow_series(mut items: Vec<Item>) -> Vec<Item> {
    if hides_empty_series() {
        items.retain(|i| !i.is_hollow_series());
    }
    items
}

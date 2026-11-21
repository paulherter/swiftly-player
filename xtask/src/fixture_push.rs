//! A second client for the fixture: changes made "from another device" that the server tells every open socket about.
//!
//! `POST /__push/next-up?episode=3` moves the series' next episode (Home's "Next Up") and sends `UserDataChanged`;
//! `POST /__push/film` adds one film to the film library and sends `LibraryChanged`; `POST /__push/film-remove?n=2` takes the
//! library film `ra2` away again and sends `LibraryChanged` (`ItemsRemoved`); `POST /__push/reset` undoes all of it
//! silently. Only what the real shapes serve reads these (`next_up_episode`, `extra_films`).

use std::sync::atomic::{AtomicUsize, Ordering};

use crate::fixture_server::Reply;

static NEXT_UP: AtomicUsize = AtomicUsize::new(2);
static FILMS: AtomicUsize = AtomicUsize::new(0);
/// Bit i set: the library film `ra<i>` was removed by the second client.
static REMOVED: AtomicUsize = AtomicUsize::new(0);

/// The episode "Next Up" offers (2 until a second client moves it).
pub(crate) fn next_up_episode() -> usize {
    NEXT_UP.load(Ordering::SeqCst)
}

/// How many films the second client added to the film library.
pub(crate) fn extra_films() -> usize {
    FILMS.load(Ordering::SeqCst)
}

/// Whether the second client removed the library film with this index (`ra<index>`).
pub(crate) fn film_removed(index: usize) -> bool {
    index < usize::BITS as usize && REMOVED.load(Ordering::SeqCst) & (1 << index) != 0
}

pub(crate) fn answer(method: &str, path: &str, query: &str) -> Option<Reply> {
    let what = path.strip_prefix("/__push/")?;
    if method != "POST" {
        return Some(Reply(405, "text/plain", b"POST only".to_vec()));
    }
    let heard = match what {
        "next-up" => {
            let n = query
                .split('&')
                .find_map(|p| p.strip_prefix("episode="))
                .and_then(|v| v.parse().ok())
                .unwrap_or(3);
            NEXT_UP.store(n, Ordering::SeqCst);
            crate::fixture_syncplay::send_all(
                r#"{"MessageType":"UserDataChanged","Data":{"UserId":"u1","UserDataList":[{"ItemId":"re2","Played":true}]}}"#,
            )
        }
        "film" => {
            let n = FILMS.fetch_add(1, Ordering::SeqCst) + 1;
            crate::fixture_syncplay::send_all(&format!(
                r#"{{"MessageType":"LibraryChanged","Data":{{"ItemsAdded":["rn{n}"],"ItemsUpdated":[],"ItemsRemoved":[]}}}}"#
            ))
        }
        "film-remove" => {
            let n: usize = query
                .split('&')
                .find_map(|p| p.strip_prefix("n="))
                .and_then(|v| v.parse().ok())
                .unwrap_or(2);
            if n >= 5 {
                return Some(Reply(400, "text/plain", b"n must be 0..4".to_vec()));
            }
            REMOVED.fetch_or(1 << n, Ordering::SeqCst);
            crate::fixture_syncplay::send_all(&format!(
                r#"{{"MessageType":"LibraryChanged","Data":{{"ItemsAdded":[],"ItemsUpdated":[],"ItemsRemoved":["ra{n}"]}}}}"#
            ))
        }
        "reset" => {
            NEXT_UP.store(2, Ordering::SeqCst);
            FILMS.store(0, Ordering::SeqCst);
            REMOVED.store(0, Ordering::SeqCst);
            0
        }
        _ => return Some(Reply(404, "text/plain", b"unknown push".to_vec())),
    };
    Some(Reply(
        200,
        "text/plain",
        format!("sockets {heard}").into_bytes(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_second_client_changes_the_catalogue_and_reset_undoes_it() {
        assert!(answer("GET", "/Items", "").is_none());
        assert_eq!(answer("GET", "/__push/film", "").unwrap().0, 405);
        answer("POST", "/__push/next-up", "episode=4");
        answer("POST", "/__push/film", "");
        answer("POST", "/__push/film", "");
        assert_eq!((next_up_episode(), extra_films()), (4, 2));
        answer("POST", "/__push/film-remove", "n=1");
        assert!(film_removed(1) && !film_removed(2));
        assert_eq!(answer("POST", "/__push/film-remove", "n=9").unwrap().0, 400);
        answer("POST", "/__push/reset", "");
        assert_eq!((next_up_episode(), extra_films()), (2, 0));
        assert!(!film_removed(1));
    }
}

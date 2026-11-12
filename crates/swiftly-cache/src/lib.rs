//! The persistent entity cache of the Swiftly core.
//!
//! * **Normalised.** Items live once, by `(scope, kind, id)`; lists hold only ids, their order
//!   and the server's total. A list paints from the entities, so one `UserDataChanged` fixes
//!   every list that shows the item.
//! * **Per account.** A [`Scope`] is `server|user`; nothing crosses scopes. [`EntityCache::drop_scope`]
//!   (logout, account removal) deletes the rows and makes every [`Ticket`] taken earlier useless,
//!   so a response that was in flight cannot write old data back.
//! * **Stale-while-revalidate.** Reads return what is there with its age and a `stale` flag; the
//!   caller paints it at once and fetches in the background. [`ListDiff`] says what changed
//!   when the fresh list is stored, so the UI patches instead of redrawing.
//! * **Events.** [`EntityCache::apply_event`] applies `LibraryChanged`/`UserDataChanged`
//!   ([`parse_ws`] reads the WebSocket message), marks what is affected stale, and tells the
//!   listeners so the screen refreshes the moment something changes. A fetch that started
//!   before the event stores its result as stale ([`Ticket`] epoch).
//! * **Bounded.** A memory budget for the hot copy, a size cap on disk with least-recently-used
//!   eviction.
//! * **Safe.** SQLite in WAL mode with a busy timeout, `user_version` schema check with a
//!   rebuild for anything it cannot migrate (the cache is disposable), integrity check on
//!   open, and a rebuild when SQLite reports corruption at run time.
//! * **Blobs.** [`SqliteStore`] implements the library's `Store` (named blobs per account), so
//!   the start page preview of the Swift snapshot lives in the same database, written
//!   atomically, and stays when offline.
#![deny(missing_docs)]

mod events;
mod mem;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, params};

pub use events::{Invalidation, parse_ws};
use mem::Mem;

/// The schema this build writes.
pub const SCHEMA_VERSION: i64 = 1;

/// `server|user`, e.g. `https://jf.example|7f3a…`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Scope(pub String);

impl Scope {
    /// Builds the scope of one account on one server.
    pub fn new(server: &str, user: &str) -> Self {
        Self(format!("{server}|{user}"))
    }
}

/// Why a cache call did not store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CacheError {
    /// The scope was dropped (logout, account removed) after the ticket was taken.
    StaleTicket,
    /// SQLite failed; the text is for the log. The cache keeps working as a miss.
    Storage(String),
}

/// Taken before a fetch starts and handed back when the result is stored.
#[derive(Debug, Clone)]
pub struct Ticket {
    scope: Scope,
    generation: u64,
    epoch: u64,
}

impl Ticket {
    /// The scope the ticket belongs to.
    pub fn scope(&self) -> &Scope {
        &self.scope
    }
}

/// Tuning.
#[derive(Clone)]
pub struct CacheConfig {
    /// Most bytes of payload on disk before eviction starts (it evicts down to 90 %).
    pub max_bytes: u64,
    /// Bytes of decoded payload kept in memory.
    pub memory_budget: usize,
    /// Seconds; a read within this age of a stored row does not rewrite `accessed`.
    pub touch_interval: f64,
    /// The clock in seconds since 1970; tests replace it.
    pub now: Arc<dyn Fn() -> f64 + Send + Sync>,
}

impl Default for CacheConfig {
    fn default() -> Self {
        Self {
            max_bytes: 256 * 1024 * 1024,
            memory_budget: 16 * 1024 * 1024,
            touch_interval: 60.0,
            now: Arc::new(|| {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_or(0.0, |d| d.as_secs_f64())
            }),
        }
    }
}

/// A stored payload with its bookkeeping.
#[derive(Debug, Clone, PartialEq)]
pub struct Cached {
    /// The payload (JSON of the item, as the server sent it).
    pub data: Arc<[u8]>,
    /// When it was fetched, seconds since 1970.
    pub fetched: f64,
    /// An event or a failed revalidation marked it out of date.
    pub stale: bool,
}

/// A stored list: ids in server order and the server's total.
#[derive(Debug, Clone, PartialEq)]
pub struct CachedList {
    /// Item ids in order.
    pub ids: Vec<String>,
    /// `TotalRecordCount`, if the server gave one.
    pub total: Option<u64>,
    /// When it was fetched.
    pub fetched: f64,
    /// Marked out of date.
    pub stale: bool,
}

impl CachedList {
    /// Fresh enough to skip the refresh: not stale and younger than `ttl` seconds at `now`.
    pub fn is_fresh(&self, now: f64, ttl: f64) -> bool {
        !self.stale && now - self.fetched <= ttl
    }
}

/// What changed between the old and the new version of a list.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ListDiff {
    /// Ids that were not in the list: `(new index, id)`.
    pub inserted: Vec<(usize, String)>,
    /// Ids that left the list.
    pub removed: Vec<String>,
    /// Ids that stayed but not at the same relative place.
    pub moved: Vec<String>,
    /// The total changed.
    pub total_changed: bool,
}

impl ListDiff {
    /// Nothing differs: the screen needs no update.
    pub fn is_empty(&self) -> bool {
        self.inserted.is_empty()
            && self.removed.is_empty()
            && self.moved.is_empty()
            && !self.total_changed
    }
}

/// Compares two id lists. `moved` is every kept id outside the longest common subsequence.
pub fn diff_ids(old: &[String], new: &[String]) -> ListDiff {
    use std::collections::HashSet;
    let old_set: HashSet<&String> = old.iter().collect();
    let new_set: HashSet<&String> = new.iter().collect();
    let inserted = new
        .iter()
        .enumerate()
        .filter(|(_, id)| !old_set.contains(id))
        .map(|(i, id)| (i, id.clone()))
        .collect();
    let removed = old
        .iter()
        .filter(|id| !new_set.contains(id))
        .cloned()
        .collect();
    let kept_old: Vec<&String> = old.iter().filter(|id| new_set.contains(id)).collect();
    let kept_new: Vec<&String> = new.iter().filter(|id| old_set.contains(id)).collect();
    // Longest common subsequence over the kept ids; everything outside it moved.
    let (n, m) = (kept_old.len(), kept_new.len());
    let mut table = vec![vec![0u32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            table[i][j] = if kept_old[i] == kept_new[j] {
                table[i + 1][j + 1] + 1
            } else {
                table[i + 1][j].max(table[i][j + 1])
            };
        }
    }
    let mut in_lcs: HashSet<&String> = HashSet::new();
    let (mut i, mut j) = (0, 0);
    while i < n && j < m {
        if kept_old[i] == kept_new[j] {
            in_lcs.insert(kept_old[i]);
            i += 1;
            j += 1;
        } else if table[i + 1][j] >= table[i][j + 1] {
            i += 1;
        } else {
            j += 1;
        }
    }
    let moved = kept_new
        .iter()
        .filter(|id| !in_lcs.contains(**id))
        .map(|id| (*id).clone())
        .collect();
    ListDiff {
        inserted,
        removed,
        moved,
        total_changed: false,
    }
}

/// What a listener hears.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CacheChange {
    /// Lists of the scope are out of date: refresh what is on screen.
    ListsStale(Scope),
    /// These items are out of date or gone.
    ItemsChanged(Scope, Vec<String>),
    /// The scope was dropped.
    ScopeDropped(Scope),
}

type Listener = Arc<dyn Fn(&CacheChange) -> bool + Send + Sync>;

struct Db {
    conn: Option<Connection>,
}

struct Inner {
    path: Option<PathBuf>,
    config: CacheConfig,
    db: Mutex<Db>,
    mem: Mutex<Mem>,
    generations: Mutex<HashMap<Scope, (u64, u64)>>,
    bytes: AtomicU64,
    recoveries: AtomicU64,
    listeners: Mutex<Vec<Listener>>,
}

/// The cache. Cheap to clone; clones share everything.
#[derive(Clone)]
pub struct EntityCache {
    inner: Arc<Inner>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn storage(e: &rusqlite::Error) -> CacheError {
    CacheError::Storage(e.to_string())
}

fn is_corruption(e: &rusqlite::Error) -> bool {
    use rusqlite::ErrorCode::{DatabaseCorrupt, NotADatabase};
    matches!(e.sqlite_error_code(), Some(DatabaseCorrupt | NotADatabase))
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS entity(
  scope TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, data BLOB NOT NULL,
  fetched REAL NOT NULL, accessed REAL NOT NULL, bytes INTEGER NOT NULL, stale INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(scope, kind, id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS entity_accessed ON entity(accessed);
CREATE TABLE IF NOT EXISTS list(
  scope TEXT NOT NULL, key TEXT NOT NULL, ids BLOB NOT NULL, total INTEGER,
  fetched REAL NOT NULL, accessed REAL NOT NULL, bytes INTEGER NOT NULL, stale INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(scope, key)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS list_accessed ON list(accessed);
CREATE TABLE IF NOT EXISTS blob(
  scope TEXT NOT NULL, name TEXT NOT NULL, data BLOB NOT NULL, saved REAL NOT NULL,
  PRIMARY KEY(scope, name)) WITHOUT ROWID;
";

/// Steps from version `i + 1` to `i + 2`. Empty while the schema is at version 1.
type Migration = fn(&Connection) -> rusqlite::Result<()>;
const MIGRATIONS: &[Migration] = &[];

fn open_connection(path: Option<&Path>) -> rusqlite::Result<Connection> {
    let conn = match path {
        Some(p) => Connection::open(p)?,
        None => Connection::open_in_memory()?,
    };
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    if path.is_some() {
        conn.pragma_update(None, "journal_mode", "WAL")?;
    }
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if path.is_some() {
        let check: String = conn.query_row("PRAGMA quick_check(1)", [], |r| r.get(0))?;
        if check != "ok" {
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CORRUPT),
                Some(check),
            ));
        }
    }
    match version {
        0 => {}
        v if v == SCHEMA_VERSION => {}
        v if v > 0 && v < SCHEMA_VERSION => {
            let steps = MIGRATIONS.get((v - 1) as usize..).unwrap_or(&[]);
            let mut ok = steps.len() as i64 == SCHEMA_VERSION - v;
            if ok {
                for step in steps {
                    if step(&conn).is_err() {
                        ok = false;
                        break;
                    }
                }
            }
            if !ok {
                wipe(&conn)?;
            }
        }
        _ => wipe(&conn)?,
    }
    conn.execute_batch(SCHEMA)?;
    conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    Ok(conn)
}

fn wipe(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "DROP TABLE IF EXISTS entity; DROP TABLE IF EXISTS list; DROP TABLE IF EXISTS blob;",
    )
}

fn remove_files(path: &Path) {
    for suffix in ["", "-wal", "-shm"] {
        let mut p = path.as_os_str().to_owned();
        p.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(p));
    }
}

impl EntityCache {
    /// A cache in memory only (tests, private sessions).
    ///
    /// # Errors
    /// [`CacheError::Storage`] if SQLite cannot start.
    pub fn in_memory(config: CacheConfig) -> Result<Self, CacheError> {
        Self::build(None, config)
    }

    /// Opens (creates) the cache file. A file that is damaged or from a schema this build
    /// cannot read is replaced by an empty cache; [`recoveries`](Self::recoveries) counts that.
    ///
    /// # Errors
    /// [`CacheError::Storage`] if even a fresh file cannot be created.
    pub fn open(path: &Path, config: CacheConfig) -> Result<Self, CacheError> {
        Self::build(Some(path.to_path_buf()), config)
    }

    fn build(path: Option<PathBuf>, config: CacheConfig) -> Result<Self, CacheError> {
        let mut recovered = 0;
        let conn = match open_connection(path.as_deref()) {
            Ok(c) => c,
            Err(_) if path.is_some() => {
                let p = path
                    .as_deref()
                    .ok_or_else(|| CacheError::Storage("no path".into()))?;
                remove_files(p);
                recovered = 1;
                open_connection(Some(p)).map_err(|e| storage(&e))?
            }
            Err(e) => return Err(storage(&e)),
        };
        let bytes = Self::total_bytes(&conn).unwrap_or(0);
        let memory_budget = config.memory_budget;
        Ok(Self {
            inner: Arc::new(Inner {
                path,
                config,
                db: Mutex::new(Db { conn: Some(conn) }),
                mem: Mutex::new(Mem::new(memory_budget)),
                generations: Mutex::new(HashMap::new()),
                bytes: AtomicU64::new(bytes),
                recoveries: AtomicU64::new(recovered),
                listeners: Mutex::new(Vec::new()),
            }),
        })
    }

    fn total_bytes(conn: &Connection) -> rusqlite::Result<u64> {
        let e: i64 = conn.query_row("SELECT COALESCE(SUM(bytes),0) FROM entity", [], |r| {
            r.get(0)
        })?;
        let l: i64 = conn.query_row("SELECT COALESCE(SUM(bytes),0) FROM list", [], |r| r.get(0))?;
        Ok((e + l).max(0) as u64)
    }

    /// How often the file had to be rebuilt after damage.
    pub fn recoveries(&self) -> u64 {
        self.inner.recoveries.load(Ordering::Relaxed)
    }

    /// Bytes of payload on disk (entities and lists).
    pub fn disk_bytes(&self) -> u64 {
        self.inner.bytes.load(Ordering::Relaxed)
    }

    /// Bytes held in the memory copy.
    pub fn memory_bytes(&self) -> usize {
        lock(&self.inner.mem).bytes()
    }

    fn now(&self) -> f64 {
        (self.inner.config.now)()
    }

    /// Runs `f` on the connection. SQLite corruption rebuilds the file and reports a miss.
    fn with_db<R>(
        &self,
        f: impl FnOnce(&Connection) -> rusqlite::Result<R>,
    ) -> Result<R, CacheError> {
        let mut db = lock(&self.inner.db);
        let Some(conn) = db.conn.as_ref() else {
            return Err(CacheError::Storage("closed".into()));
        };
        match f(conn) {
            Ok(v) => Ok(v),
            Err(e) if is_corruption(&e) => {
                db.conn = None;
                let fresh = match self.inner.path.as_deref() {
                    Some(p) => {
                        remove_files(p);
                        open_connection(Some(p))
                    }
                    None => open_connection(None),
                };
                self.inner.recoveries.fetch_add(1, Ordering::Relaxed);
                lock(&self.inner.mem).clear();
                self.inner.bytes.store(0, Ordering::Relaxed);
                db.conn = fresh.ok();
                Err(storage(&e))
            }
            Err(e) => Err(storage(&e)),
        }
    }

    /// Registers a listener for [`CacheChange`]s. It runs on the thread that caused the change
    /// and must not block.
    pub fn subscribe(&self, listener: impl Fn(&CacheChange) + Send + Sync + 'static) {
        lock(&self.inner.listeners).push(Arc::new(move |c| {
            listener(c);
            true
        }));
    }

    /// Like [`subscribe`](Self::subscribe), but the listener leaves the list the first time it
    /// returns `false` (its owner is gone). View models use this, so a closed screen costs nothing.
    pub fn subscribe_while(&self, listener: impl Fn(&CacheChange) -> bool + Send + Sync + 'static) {
        lock(&self.inner.listeners).push(Arc::new(listener));
    }

    fn notify(&self, change: &CacheChange) {
        let listeners: Vec<Listener> = lock(&self.inner.listeners).clone();
        let dead: Vec<*const ()> = listeners
            .iter()
            .filter(|l| !l(change))
            .map(|l| Arc::as_ptr(l).cast::<()>())
            .collect();
        if !dead.is_empty() {
            lock(&self.inner.listeners).retain(|l| !dead.contains(&Arc::as_ptr(l).cast::<()>()));
        }
    }

    /// Something changed on the server that the cache cannot name (a polling tick found a newer
    /// library, a WebSocket that is down): every list of the scope is marked stale and the
    /// screens refresh. The hook for the polling fallback.
    pub fn lists_changed(&self, scope: &Scope) {
        {
            let mut g = lock(&self.inner.generations);
            g.entry(scope.clone()).or_insert((0, 0)).1 += 1;
        }
        self.mark_lists_stale(scope);
        self.notify(&CacheChange::ListsStale(scope.clone()));
    }

    /// A ticket for a fetch that is about to start in `scope`.
    pub fn ticket(&self, scope: &Scope) -> Ticket {
        let g = lock(&self.inner.generations);
        let (generation, epoch) = g.get(scope).copied().unwrap_or((0, 0));
        Ticket {
            scope: scope.clone(),
            generation,
            epoch,
        }
    }

    /// `Ok(stored_as_fresh)`; `Err(StaleTicket)` if the scope was dropped since.
    fn check(&self, ticket: &Ticket) -> Result<bool, CacheError> {
        let g = lock(&self.inner.generations);
        let (generation, epoch) = g.get(&ticket.scope).copied().unwrap_or((0, 0));
        if generation != ticket.generation {
            return Err(CacheError::StaleTicket);
        }
        Ok(epoch == ticket.epoch)
    }

    // ------------------------------------------------------------ entities

    /// Stores items of one `kind` (`"item"`, `"person"`, …) in one transaction.
    ///
    /// # Errors
    /// [`CacheError::StaleTicket`] or [`CacheError::Storage`].
    pub fn put_entities(
        &self,
        ticket: &Ticket,
        kind: &str,
        items: &[(String, Vec<u8>)],
    ) -> Result<(), CacheError> {
        let fresh = self.check(ticket)?;
        let now = self.now();
        let scope = &ticket.scope.0;
        let added: i64 = self.with_db(|c| {
            let tx = rusqlite::Transaction::new_unchecked(c, rusqlite::TransactionBehavior::Immediate)?;
            let mut delta = 0i64;
            {
                let mut old = tx.prepare_cached("SELECT bytes FROM entity WHERE scope=?1 AND kind=?2 AND id=?3")?;
                let mut put = tx.prepare_cached(
                    "INSERT OR REPLACE INTO entity(scope,kind,id,data,fetched,accessed,bytes,stale) VALUES(?1,?2,?3,?4,?5,?5,?6,?7)",
                )?;
                for (id, data) in items {
                    let before: Option<i64> = old.query_row(params![scope, kind, id], |r| r.get(0)).optional()?;
                    put.execute(params![scope, kind, id, data, now, data.len() as i64, i64::from(!fresh)])?;
                    delta += data.len() as i64 - before.unwrap_or(0);
                }
            }
            tx.commit()?;
            Ok(delta)
        })?;
        self.adjust_bytes(added);
        {
            let mut mem = lock(&self.inner.mem);
            for (id, data) in items {
                mem.put(
                    mem_key(scope, kind, id),
                    Cached {
                        data: Arc::from(data.as_slice()),
                        fetched: now,
                        stale: !fresh,
                    },
                );
            }
        }
        self.evict_if_needed();
        Ok(())
    }

    /// One item: memory first, then disk.
    pub fn get_entity(&self, scope: &Scope, kind: &str, id: &str) -> Option<Cached> {
        let key = mem_key(&scope.0, kind, id);
        if let Some(hit) = lock(&self.inner.mem).get(&key) {
            return Some(hit);
        }
        let now = self.now();
        let touch = self.inner.config.touch_interval;
        let row = self
            .with_db(|c| {
                let row = c
                    .query_row(
                        "SELECT data, fetched, stale, accessed FROM entity WHERE scope=?1 AND kind=?2 AND id=?3",
                        params![scope.0, kind, id],
                        |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, f64>(1)?, r.get::<_, i64>(2)?, r.get::<_, f64>(3)?)),
                    )
                    .optional()?;
                if let Some((_, _, _, accessed)) = &row
                    && now - accessed > touch {
                        c.execute(
                            "UPDATE entity SET accessed=?4 WHERE scope=?1 AND kind=?2 AND id=?3",
                            params![scope.0, kind, id, now],
                        )?;
                    }
                Ok(row)
            })
            .ok()??;
        let cached = Cached {
            data: Arc::from(row.0),
            fetched: row.1,
            stale: row.2 != 0,
        };
        lock(&self.inner.mem).put(key, cached.clone());
        Some(cached)
    }

    /// Many items, in the order asked. Missing ones are `None` (an evicted or removed item).
    pub fn get_entities(&self, scope: &Scope, kind: &str, ids: &[String]) -> Vec<Option<Cached>> {
        ids.iter()
            .map(|id| self.get_entity(scope, kind, id))
            .collect()
    }

    // --------------------------------------------------------------- lists

    /// Stores (replaces) the whole list under `key` and returns what changed against the old one.
    ///
    /// # Errors
    /// [`CacheError::StaleTicket`] or [`CacheError::Storage`].
    pub fn put_list(
        &self,
        ticket: &Ticket,
        key: &str,
        ids: &[String],
        total: Option<u64>,
    ) -> Result<ListDiff, CacheError> {
        let old = self.get_list(&ticket.scope, key);
        self.write_list(ticket, key, ids, total, old)
    }

    /// Stores one page: `ids` replace the slice starting at `start`; the rest of the list stays
    /// (a refreshed first page keeps the pages behind it). The list is cut to `total`.
    ///
    /// # Errors
    /// [`CacheError::StaleTicket`] or [`CacheError::Storage`].
    pub fn put_list_page(
        &self,
        ticket: &Ticket,
        key: &str,
        start: usize,
        ids: &[String],
        total: Option<u64>,
    ) -> Result<ListDiff, CacheError> {
        let old = self.get_list(&ticket.scope, key);
        let mut merged = old.as_ref().map(|l| l.ids.clone()).unwrap_or_default();
        if merged.len() < start {
            // A gap would put ids at the wrong places; keep only this page as the list.
            merged.clear();
            if start > 0 {
                return self.write_list(ticket, key, ids, total, old).map(|mut d| {
                    d.total_changed = true;
                    d
                });
            }
        }
        let end = (start + ids.len()).min(merged.len().max(start + ids.len()));
        merged.splice(start..end.min(merged.len()), ids.iter().cloned());
        if let Some(t) = total {
            merged.truncate(t as usize);
        }
        self.write_list(ticket, key, &merged, total, old)
    }

    fn write_list(
        &self,
        ticket: &Ticket,
        key: &str,
        ids: &[String],
        total: Option<u64>,
        old: Option<CachedList>,
    ) -> Result<ListDiff, CacheError> {
        let fresh = self.check(ticket)?;
        let now = self.now();
        let blob = serde_json::to_vec(ids).map_err(|e| CacheError::Storage(e.to_string()))?;
        let scope = &ticket.scope.0;
        let before: i64 = self.with_db(|c| {
            let before: Option<i64> = c
                .query_row("SELECT bytes FROM list WHERE scope=?1 AND key=?2", params![scope, key], |r| r.get(0))
                .optional()?;
            c.execute(
                "INSERT OR REPLACE INTO list(scope,key,ids,total,fetched,accessed,bytes,stale) VALUES(?1,?2,?3,?4,?5,?5,?6,?7)",
                params![scope, key, blob, total.map(|t| t as i64), now, blob.len() as i64, i64::from(!fresh)],
            )?;
            Ok(before.unwrap_or(0))
        })?;
        self.adjust_bytes(blob.len() as i64 - before);
        self.evict_if_needed();
        let mut diff = old.as_ref().map_or_else(
            || ListDiff {
                inserted: ids.iter().cloned().enumerate().collect(),
                ..ListDiff::default()
            },
            |o| diff_ids(&o.ids, ids),
        );
        diff.total_changed = old.as_ref().is_none_or(|o| o.total != total);
        Ok(diff)
    }

    /// The list under `key`.
    pub fn get_list(&self, scope: &Scope, key: &str) -> Option<CachedList> {
        let now = self.now();
        let touch = self.inner.config.touch_interval;
        self.with_db(|c| {
            let row = c
                .query_row(
                    "SELECT ids, total, fetched, stale, accessed FROM list WHERE scope=?1 AND key=?2",
                    params![scope.0, key],
                    |r| {
                        Ok((
                            r.get::<_, Vec<u8>>(0)?,
                            r.get::<_, Option<i64>>(1)?,
                            r.get::<_, f64>(2)?,
                            r.get::<_, i64>(3)?,
                            r.get::<_, f64>(4)?,
                        ))
                    },
                )
                .optional()?;
            if let Some(r) = &row
                && now - r.4 > touch {
                    c.execute("UPDATE list SET accessed=?3 WHERE scope=?1 AND key=?2", params![scope.0, key, now])?;
                }
            Ok(row)
        })
        .ok()
        .flatten()
        .and_then(|(ids, total, fetched, stale, _)| {
            Some(CachedList {
                ids: serde_json::from_slice(&ids).ok()?,
                total: total.map(|t| t.max(0) as u64),
                fetched,
                stale: stale != 0,
            })
        })
    }

    // ------------------------------------------------------------- events

    /// Applies a server event: marks what is affected stale (removed items are deleted), bumps
    /// the scope's epoch so fetches already under way store as stale, and tells the listeners.
    pub fn apply_event(&self, scope: &Scope, event: &Invalidation) {
        {
            let mut g = lock(&self.inner.generations);
            g.entry(scope.clone()).or_insert((0, 0)).1 += 1;
        }
        let (touched, removed): (Vec<String>, Vec<String>) = match event {
            Invalidation::LibraryChanged {
                updated, removed, ..
            } => (
                updated.iter().chain(removed).cloned().collect(),
                removed.clone(),
            ),
            Invalidation::UserDataChanged { item_ids } => (item_ids.clone(), Vec::new()),
        };
        let _ = self.with_db(|c| {
            let tx =
                rusqlite::Transaction::new_unchecked(c, rusqlite::TransactionBehavior::Immediate)?;
            tx.execute("UPDATE list SET stale=1 WHERE scope=?1", params![scope.0])?;
            for id in &touched {
                tx.execute(
                    "UPDATE entity SET stale=1 WHERE scope=?1 AND id=?2",
                    params![scope.0, id],
                )?;
            }
            let mut freed = 0i64;
            for id in &removed {
                let n: i64 = tx.query_row(
                    "SELECT COALESCE(SUM(bytes),0) FROM entity WHERE scope=?1 AND id=?2",
                    params![scope.0, id],
                    |r| r.get(0),
                )?;
                freed += n;
                tx.execute(
                    "DELETE FROM entity WHERE scope=?1 AND id=?2",
                    params![scope.0, id],
                )?;
            }
            tx.commit()?;
            self.adjust_bytes(-freed);
            Ok(())
        });
        lock(&self.inner.mem).mark_scope(&scope.0, &touched, &removed);
        self.notify(&CacheChange::ListsStale(scope.clone()));
        if !touched.is_empty() {
            self.notify(&CacheChange::ItemsChanged(scope.clone(), touched));
        }
    }

    /// Marks every list of the scope stale (pull to refresh, a failed background refresh).
    pub fn mark_lists_stale(&self, scope: &Scope) {
        let _ =
            self.with_db(|c| c.execute("UPDATE list SET stale=1 WHERE scope=?1", params![scope.0]));
    }

    /// Deletes everything of the scope and voids its tickets (logout, account removed).
    pub fn drop_scope(&self, scope: &Scope) {
        {
            let mut g = lock(&self.inner.generations);
            let e = g.entry(scope.clone()).or_insert((0, 0));
            e.0 += 1;
            e.1 += 1;
        }
        let _ = self.with_db(|c| {
            let tx =
                rusqlite::Transaction::new_unchecked(c, rusqlite::TransactionBehavior::Immediate)?;
            tx.execute("DELETE FROM entity WHERE scope=?1", params![scope.0])?;
            tx.execute("DELETE FROM list WHERE scope=?1", params![scope.0])?;
            tx.execute("DELETE FROM blob WHERE scope=?1", params![scope.0])?;
            tx.commit()?;
            let total = Self::total_bytes(c)?;
            self.inner.bytes.store(total, Ordering::Relaxed);
            Ok(())
        });
        lock(&self.inner.mem).drop_scope(&scope.0);
        self.notify(&CacheChange::ScopeDropped(scope.clone()));
    }

    // -------------------------------------------------------------- budget

    fn adjust_bytes(&self, delta: i64) {
        if delta >= 0 {
            self.inner.bytes.fetch_add(delta as u64, Ordering::Relaxed);
        } else {
            let sub = delta.unsigned_abs();
            let _ = self
                .inner
                .bytes
                .try_update(Ordering::Relaxed, Ordering::Relaxed, |v| {
                    Some(v.saturating_sub(sub))
                });
        }
    }

    /// Deletes the least recently used rows until the payload is at 90 % of the cap.
    fn evict_if_needed(&self) {
        let cap = self.inner.config.max_bytes;
        if self.disk_bytes() <= cap {
            return;
        }
        let target = cap / 10 * 9;
        let _ = self.with_db(|c| {
            let tx = rusqlite::Transaction::new_unchecked(c, rusqlite::TransactionBehavior::Immediate)?;
            let mut total = Self::total_bytes(&tx)?;
            while total > target {
                let victim: Option<(String, String, String, i64, f64)> = tx
                    .query_row(
                        "SELECT 'e', scope || char(0) || kind || char(0) || id, '', bytes, accessed FROM entity
                         UNION ALL SELECT 'l', scope || char(0) || key, '', bytes, accessed FROM list
                         ORDER BY 5 LIMIT 1",
                        [],
                        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
                    )
                    .optional()?;
                let Some((table, key, _, bytes, _)) = victim else { break };
                let parts: Vec<&str> = key.split('\0').collect();
                if table == "e" && parts.len() == 3 {
                    tx.execute("DELETE FROM entity WHERE scope=?1 AND kind=?2 AND id=?3", params![parts[0], parts[1], parts[2]])?;
                    lock(&self.inner.mem).remove(&mem_key(parts[0], parts[1], parts[2]));
                } else if parts.len() == 2 {
                    tx.execute("DELETE FROM list WHERE scope=?1 AND key=?2", params![parts[0], parts[1]])?;
                } else {
                    break;
                }
                total = total.saturating_sub(bytes.max(0) as u64);
            }
            tx.commit()?;
            self.inner.bytes.store(total, Ordering::Relaxed);
            Ok(())
        });
    }

    // ---------------------------------------------------------------- blobs

    /// The blob store (`swiftly_library::Store`) over this database, for the start page preview.
    pub fn blob_store(&self, scope: &Scope) -> SqliteStore {
        SqliteStore {
            cache: self.clone(),
            scope: scope.0.clone(),
        }
    }
}

fn mem_key(scope: &str, kind: &str, id: &str) -> String {
    format!("{scope}\0{kind}\0{id}")
}

/// Named blobs per scope in the cache database; implements the library's `Store`.
#[derive(Clone)]
pub struct SqliteStore {
    cache: EntityCache,
    scope: String,
}

impl swiftly_library::Store for SqliteStore {
    fn read(&self, name: &str) -> Option<Vec<u8>> {
        self.cache
            .with_db(|c| {
                c.query_row(
                    "SELECT data FROM blob WHERE scope=?1 AND name=?2",
                    params![self.scope, name],
                    |r| r.get(0),
                )
                .optional()
            })
            .ok()
            .flatten()
    }

    fn write(&self, name: &str, data: &[u8]) {
        let now = self.cache.now();
        let _ = self.cache.with_db(|c| {
            c.execute(
                "INSERT OR REPLACE INTO blob(scope,name,data,saved) VALUES(?1,?2,?3,?4)",
                params![self.scope, name, data, now],
            )
        });
    }

    fn remove(&self, name: &str) {
        let _ = self.cache.with_db(|c| {
            c.execute(
                "DELETE FROM blob WHERE scope=?1 AND name=?2",
                params![self.scope, name],
            )
        });
    }
}

#[cfg(test)]
mod tests;

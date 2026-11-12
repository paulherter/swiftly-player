//! The in-memory copy: a byte-budgeted least-recently-used map of decoded payloads.

use std::collections::HashMap;

use crate::Cached;

struct Slot {
    value: Cached,
    stamp: u64,
}

pub(crate) struct Mem {
    budget: usize,
    bytes: usize,
    clock: u64,
    map: HashMap<String, Slot>,
}

impl Mem {
    pub(crate) fn new(budget: usize) -> Self {
        Self {
            budget,
            bytes: 0,
            clock: 0,
            map: HashMap::new(),
        }
    }

    pub(crate) fn bytes(&self) -> usize {
        self.bytes
    }

    pub(crate) fn get(&mut self, key: &str) -> Option<Cached> {
        self.clock += 1;
        let clock = self.clock;
        self.map.get_mut(key).map(|s| {
            s.stamp = clock;
            s.value.clone()
        })
    }

    pub(crate) fn put(&mut self, key: String, value: Cached) {
        let size = value.data.len();
        if size > self.budget / 2 {
            self.remove(&key);
            return;
        }
        self.clock += 1;
        if let Some(old) = self.map.insert(
            key,
            Slot {
                value,
                stamp: self.clock,
            },
        ) {
            self.bytes -= old.value.data.len();
        }
        self.bytes += size;
        while self.bytes > self.budget {
            let Some(oldest) = self
                .map
                .iter()
                .min_by_key(|(_, s)| s.stamp)
                .map(|(k, _)| k.clone())
            else {
                break;
            };
            self.remove(&oldest);
        }
    }

    pub(crate) fn remove(&mut self, key: &str) {
        if let Some(old) = self.map.remove(key) {
            self.bytes -= old.value.data.len();
        }
    }

    pub(crate) fn clear(&mut self) {
        self.map.clear();
        self.bytes = 0;
    }

    /// An event touched `touched` ids and removed `removed` ones in `scope`.
    pub(crate) fn mark_scope(&mut self, scope: &str, touched: &[String], removed: &[String]) {
        let prefix = format!("{scope}\0");
        let gone: Vec<String> = self
            .map
            .keys()
            .filter(|k| {
                k.starts_with(&prefix) && removed.iter().any(|id| k.ends_with(&format!("\0{id}")))
            })
            .cloned()
            .collect();
        for k in gone {
            self.remove(&k);
        }
        for (k, slot) in &mut self.map {
            if k.starts_with(&prefix) && touched.iter().any(|id| k.ends_with(&format!("\0{id}"))) {
                slot.value.stale = true;
            }
        }
    }

    pub(crate) fn drop_scope(&mut self, scope: &str) {
        let prefix = format!("{scope}\0");
        let keys: Vec<String> = self
            .map
            .keys()
            .filter(|k| k.starts_with(&prefix))
            .cloned()
            .collect();
        for k in keys {
            self.remove(&k);
        }
    }
}

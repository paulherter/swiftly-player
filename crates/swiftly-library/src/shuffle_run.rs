//! `ShuffleRun` (Swift `ShuffleRun.swift`): "play shuffled" for a series, all episodes in one
//! random order, mixed once, not yet watched first.

use swiftly_model::Item;

/// A source of random numbers (Swift `RandomNumberGenerator`). Swift's `shuffled(using:)`
/// algorithm and its exact sequences are not reproduced; only the guarantees are.
pub trait Rng {
    /// The next 64 random bits.
    fn next_u64(&mut self) -> u64;
}

/// A small deterministic generator (SplitMix64) for tests and for seeding from the clock.
#[derive(Debug, Clone)]
pub struct SplitMix(pub u64);

impl SplitMix {
    /// Seeded from the system clock.
    pub fn from_clock() -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        Self(nanos as u64 ^ 0x9E37_79B9_7F4A_7C15)
    }
}

impl Rng for SplitMix {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

fn shuffled<T>(mut v: Vec<T>, rng: &mut impl Rng) -> Vec<T> {
    for i in (1..v.len()).rev() {
        let j = (rng.next_u64() % (i as u64 + 1)) as usize;
        v.swap(i, j);
    }
    v
}

/// The mixed order: unwatched first, then watched, each group shuffled (`mix`, :27-31).
pub fn mix<T>(items: Vec<T>, is_played: impl Fn(&T) -> bool, rng: &mut impl Rng) -> Vec<T> {
    let (played, unplayed): (Vec<T>, Vec<T>) = items.into_iter().partition(|i| is_played(i));
    let mut out = shuffled(unplayed, rng);
    out.extend(shuffled(played, rng));
    out
}

/// One shuffled run through a series (:9-41).
#[derive(Debug, Clone, PartialEq)]
pub struct ShuffleRun {
    /// The episodes in the fixed order.
    pub episodes: Vec<Item>,
}

impl ShuffleRun {
    /// `mixed(_:using:)`.
    pub fn mixed(items: Vec<Item>, rng: &mut impl Rng) -> Self {
        Self {
            episodes: mix(
                items,
                |i| i.user_data.as_ref().and_then(|d| d.played) == Some(true),
                rng,
            ),
        }
    }
    /// The episode after this one in the order; `None` at the end and for an episode that is
    /// not part of the run (:34-38).
    pub fn next_after(&self, id: &str) -> Option<&Item> {
        let now = self.episodes.iter().position(|e| e.id == id)?;
        self.episodes.get(now + 1)
    }
    /// Whether the episode is part of the run.
    pub fn contains(&self, id: &str) -> bool {
        self.episodes.iter().any(|e| e.id == id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unplayed_first_nothing_lost() {
        let mut g = SplitMix(42);
        let items: Vec<i32> = (1..=20).collect();
        let out = mix(items.clone(), |i| i % 2 == 0, &mut g);
        let mut sorted = out.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, items);
        assert!(out[..10].iter().all(|i| i % 2 == 1));
    }
    #[test]
    fn next_after_walks_the_order() {
        let run = ShuffleRun {
            episodes: ["a", "b", "c"]
                .iter()
                .map(|i| Item::new(*i, *i, None))
                .collect(),
        };
        assert_eq!(run.next_after("a").map(|i| i.id.as_str()), Some("b"));
        assert!(run.next_after("c").is_none());
        assert!(run.next_after("zz").is_none());
        assert!(run.contains("b"));
    }
    #[test]
    fn mixed_uses_played_state() {
        let mut played = Item::new("p", "p", None);
        played.user_data = Some(swiftly_model::UserItemData {
            played: Some(true),
            ..Default::default()
        });
        let items = vec![played, Item::new("u", "u", None)];
        let run = ShuffleRun::mixed(items, &mut SplitMix(1));
        assert_eq!(run.episodes[0].id, "u");
    }
}

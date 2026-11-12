//! Port of BufferLevel.swift.
//!
//! How much buffer the player holds before the picture appears: three levels, because VLC's
//! buffer is held in bytes, not seconds. The level *names* are UI strings (catalog), not
//! ported.

/// The buffer level setting. Raw values are the persisted strings (`pufferstufe`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BufferLevel {
    /// As before. Fast seeks, buffer from the prefetch filter.
    Normal,
    /// For a connection that occasionally drops (raw `schlecht`).
    Bad,
    /// For a connection that is sometimes gone entirely (raw `sehrSchlecht`).
    VeryBad,
}

impl BufferLevel {
    /// `CaseIterable.allCases`, in declaration order.
    pub const ALL: [BufferLevel; 3] = [BufferLevel::Normal, BufferLevel::Bad, BufferLevel::VeryBad];

    /// The persisted raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            BufferLevel::Normal => "normal",
            BufferLevel::Bad => "schlecht",
            BufferLevel::VeryBad => "sehrSchlecht",
        }
    }

    /// `init?(rawValue:)`.
    pub fn from_raw_value(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|l| l.raw_value() == raw)
    }

    /// How much the prefetch filter holds, in KiB (VLC's own unit).
    pub fn prefetch_kib(self) -> i64 {
        match self {
            BufferLevel::Normal => 16_384,
            BufferLevel::Bad => 65_536,
            BufferLevel::VeryBad => 196_608,
        }
    }

    /// VLC's time-ahead in milliseconds, or `None` for "leave alone" (deliberately `None`
    /// for `Normal`, not 1000).
    pub fn network_lead_milliseconds(self) -> Option<i64> {
        match self {
            BufferLevel::Normal => None,
            BufferLevel::Bad => Some(15_000),
            BufferLevel::VeryBad => Some(45_000),
        }
    }

    /// Rough guide for the UI: about how many seconds this is at the given bitrate;
    /// `None` without a bitrate. `Int((bytes * 8 / bps).rounded())`, half away from zero.
    pub fn approx_seconds(self, bits_per_second: i64) -> Option<i64> {
        if bits_per_second <= 0 {
            return None;
        }
        let bytes = self.prefetch_kib() as f64 * 1024.0;
        Some(crate::whole_number::capped(
            (bytes * 8.0 / bits_per_second as f64).round(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: normalLetsVLCInIdle()
    #[test]
    fn normal_lets_vlc_in_idle() {
        assert_eq!(BufferLevel::Normal.network_lead_milliseconds(), None);
        assert_eq!(BufferLevel::Normal.prefetch_kib(), 16_384);
    }

    // Swift: levelsGrow()
    #[test]
    fn levels_grow() {
        for pair in BufferLevel::ALL.windows(2) {
            assert!(pair[0].prefetch_kib() < pair[1].prefetch_kib());
        }
    }

    // Swift: secondsAttachToBitrate()
    #[test]
    fn seconds_attach_to_bitrate() {
        let rung = BufferLevel::Normal;
        let series = rung.approx_seconds(5_000_000);
        let four_k = rung.approx_seconds(80_000_000);
        assert!(series.is_some() && four_k.is_some());
        assert!(series.is_some_and(|s| s > 20 && s < 30));
        assert!(four_k.is_some_and(|s| s < 3));
    }

    // Swift: withoutBitrateNil()
    #[test]
    fn without_bitrate_nil() {
        assert_eq!(BufferLevel::Bad.approx_seconds(0), None);
    }

    // Swift: veryRealCarriesAlso4K()
    #[test]
    fn very_bad_carries_4k() {
        let s = BufferLevel::VeryBad.approx_seconds(40_000_000);
        assert!(s.is_some_and(|s| s >= 30));
    }

    // Swift: namesPresentAndDistinct() asserts the catalog names; those are UI strings and
    // not ported. The part that is logic (distinct identities) is checked on raw values.
    #[test]
    fn raw_values_distinct_and_round_trip() {
        let raws: Vec<&str> = BufferLevel::ALL.iter().map(|l| l.raw_value()).collect();
        let mut unique = raws.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), BufferLevel::ALL.len());
        for l in BufferLevel::ALL {
            assert_eq!(BufferLevel::from_raw_value(l.raw_value()), Some(l));
        }
    }
}

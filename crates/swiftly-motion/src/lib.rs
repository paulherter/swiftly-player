//! Pure-math feel module of the Swiftly Rust UI: closed-form springs ([`spring`]), one-axis scroll physics
//! ([`scroll`]) and every feel constant in one file ([`tuning`]). `std` only, `f64` math, no clock inside: time is
//! always passed in, so everything is deterministic and unit-testable.

#![deny(missing_docs)]

pub mod blend;
pub mod catalogue;
pub mod curve;
pub mod profile;
pub mod scroll;
pub mod spring;
pub mod tuning;

pub use blend::Blend;
pub use curve::{Curve, Ease, Kind, bezier, bezier_slope};
pub use profile::{Glide, NotchGlide, Os, ScrollTuning, mac_momentum_table};
pub use scroll::{ScrollBody, ScrollMetrics, ScrollState};
pub use spring::{Spring, SpringAnim};

/// Tiny deterministic PRNG (splitmix64) for the property-style tests; no dependencies.
#[cfg(test)]
pub(crate) mod testutil {
    /// A splitmix64 generator.
    pub struct Rng(pub u64);

    impl Rng {
        /// Next raw 64 bits.
        pub fn next_u64(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }
        /// Uniform in `[0, 1)`.
        pub fn unit(&mut self) -> f64 {
            (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
        }
        /// Uniform in `[lo, hi)`.
        pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
            lo + (hi - lo) * self.unit()
        }
    }
}

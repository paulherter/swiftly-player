//! Shared pieces of the hardening harness.
//!
//! * [`Rng`]: a tiny seeded generator (splitmix64) so every random input is reproducible from a
//!   seed printed in the failure message. Used by the oracle input generators and the soak runs.
//! * [`oracle`]: the differential oracle. Inputs are generated here (`oracle-inputs` binary),
//!   run through the REAL Swift code by `Tools/Oracle` (`cargo xtask hardening --regen-oracle`) and
//!   stored under `oracle/<domain>.in.json` / `oracle/<domain>.swift.json`. The Rust tests load
//!   both files and must produce equal output; differences land in `target/hardening/`.

#![allow(clippy::unwrap_used, clippy::expect_used)] // test harness: a panic is the failure signal

pub mod inputs;
pub mod oracle;
pub mod rng;
pub mod soak;

pub use rng::Rng;

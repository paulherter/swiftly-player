//! Token constants for the Swiftly Rust UI.
//!
//! The values live in [`tokens`], which is generated. Never edit `tokens.rs` by hand.
//! The value types are defined here in [`types`].
//!
//! Layout sets: [`LayoutSet::Touch`] (phones, tablets), [`LayoutSet::Desktop`] (windows with a pointer) and
//! [`LayoutSet::Tv`] (remote, about 3 m). Values that do not differ by layout set are in `tokens::common` and
//! `tokens::colour`.

pub mod types;

#[rustfmt::skip]
pub mod tokens;

#[rustfmt::skip]
pub mod tokens_generated;

pub use types::{Colour, Curve, LayoutSet, Shadow, TextStyle};

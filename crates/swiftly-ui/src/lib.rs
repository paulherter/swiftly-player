//! The retained UI of the shared Swiftly Rust UI.
//!
//! * [`Node`]: the declarative tree `view(parts, env, cx)` returns (layout from `swiftly-layout`, paint, gestures).
//! * [`Ui`]: re-runs `view` only when the parts or the [`Env`] change, reconciles by path and key so springs, scroll
//!   bodies and press state survive, hit-tests, arbitrates gestures and runs the frame loop `frame(now) -> DrawList`.
//! * [`components`]: `tile`, `rail`, `press_button`, built from `swiftly-design` tokens.
//! * [`harness`]: synthetic touch traces for headless tests and goldens.
//!
//! Every feel number is in [`tuning`] with its source.

#![deny(missing_docs)]

pub mod a11y;
mod anim;
pub mod components;
pub mod cx;
pub mod env;
pub mod feel;
pub mod field;
pub mod focus;
pub mod harness;
mod icon_data;
mod icon_data_audit;
mod icon_data_forms;
mod icon_data_keys;
mod icon_data_more;
mod icon_data_phos;
mod icon_data_rest;
pub mod icons;
pub mod interact;
pub mod nav;
pub mod popover;
pub mod scrollbar;
pub mod shortcuts;
mod tree;
pub mod tuning;
mod ui;
pub mod view;

pub use anim::{Animated, Ease, Motion};
pub use cx::{
    Cx, GpuVideo, ImageId, ImageSlot, ImageStore, TextSystem, VIDEO_MAX, VideoFrame, VideoHandoff,
};
pub use env::{Env, Idiom, InputMode, Insets, SizeClass, classes};
pub use focus::{
    BackOutcome, Dir, Focus, FocusId, FocusMap, NavKey, Outcome, ScopeKind, ScopeSpec,
};
pub use interact::{Cursor, Interact, PressStyle, Ring, Surface};
pub use ui::{NodeValues, Phase, Ui, UiEvent, set_precise_wheel};
pub use view::{Action, Edge, FocusLook, Gestures, Key, Node, Paint, ScrollSpec};

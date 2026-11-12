//! Playback decision logic of the Swiftly core, ported 1:1 from Swift (`JellyfinKit` and the
//! engine-neutral part of `Sources/Shared/AetherPlayerEngine.swift`).
//!
//! One module per Swift file; module headers name the Swift source and cite `file:line`.
//! No I/O, no UI strings. Time is plain `f64` seconds on any consistent clock.

pub mod airplay_suitability;
pub mod audio_guards;
pub mod av_computation;
pub mod decoder_choice;
pub mod device_profile;
pub mod dolby_vision;
pub mod endpoints;
pub mod engine;
pub mod fade_times;
pub mod first_frame;
pub mod handoff_card;
pub mod handoff_flow;
pub mod header_scroll;
pub mod media_server;
pub mod offering_layer;
pub mod original_audio;
pub mod pause_jump_back;
pub mod playback_plan;
pub mod player_state;
pub mod prebuffer;
pub mod resume_point;
pub mod section_offering;
pub mod sections;
pub mod stream_forwarder;
pub mod stream_watch;
pub mod subtitle_cues;
pub mod takeover;
pub mod tech_details;
pub mod track_label;
pub mod track_mapping;
pub mod track_rule;
pub mod transcode_subtitle;
pub mod trickplay;

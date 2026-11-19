//! Desktop shell of the shared Swiftly Rust UI: a winit window with a wgpu surface (`app`), the window-independent
//! input and frame core (`shell`), the gate G1 demo (`demo`), wheel and touchpad scrolling (`wheel`), frame statistics
//! (`stats`) and a headless renderer for smoke tests (`headless`).

#![deny(missing_docs)]

pub mod a11y_bridge;
#[cfg(feature = "window")]
pub mod app;
pub mod art;
pub mod autoplay;
pub mod browse;
pub mod browser_open;
pub mod cli;
pub mod crash;
pub mod deep_link;
pub mod demo;
pub mod desk;
pub mod detail_screen;
pub mod device_language;
#[cfg(all(feature = "mpv", any(target_os = "linux", windows)))]
#[cfg_attr(windows, path = "win_gpu_video.rs")]
pub mod dmabuf_import;
pub mod downloads_screen;
pub mod dump;
pub mod effects;
pub mod field_book;
pub mod focus_scene;
pub mod forms;
pub mod frame_surface;
pub mod headless;
pub mod home;
pub mod home_choices;
pub mod home_data;
pub mod hub;
pub mod ime;
pub mod latency;
pub mod legacy_import;
pub mod library_screen;
pub mod link_route;
pub mod live;
pub mod live_accounts;
pub mod live_downloads;
pub mod live_offline;
pub mod live_person;
pub mod live_play;
pub mod live_server;
pub mod load_panel;
pub mod load_sheets;
pub mod local_clock;
pub mod login_mac;
pub mod login_screen;
pub mod look_glow;
pub mod lottie;
pub mod management_hub;
pub mod media_keys;
pub mod nav_machine;
pub mod net;
pub mod net_watch;
pub mod os_media;
pub mod pages_screen;
pub mod player_card;
pub mod player_glyphs;
pub mod player_host;
pub(crate) mod player_menu_box;
pub mod player_screen;
pub mod quit_guard;
#[cfg(feature = "window")]
pub mod resize_latency;
pub mod script;
pub mod search_screen;
pub mod seerr_desk;
pub mod seerr_flow;
pub mod seerr_link;
pub mod series_screen;
pub mod server_admin_link;
pub mod server_admin_pages;
pub mod server_check;
pub mod settings_pages;
pub mod settings_run;
pub mod settings_screen;
pub mod shell;
pub mod signin_flows;
pub mod single_instance;
pub mod skip_fill;
pub mod stats;
pub mod store;
pub mod subtitle_style;
pub mod suite;
pub mod support_card;
pub mod switch_stage;
pub mod tile_menu;
pub mod title_data;
pub mod title_target;
pub mod together;
pub mod together_socket;
pub mod together_ui;
#[cfg(all(
    feature = "window",
    unix,
    not(any(target_os = "macos", target_os = "ios", target_os = "android"))
))]
pub mod toplevel_icon;
pub mod trick_preview;
pub mod update_check;
#[cfg(feature = "mpv")]
pub mod video_demo;
pub mod wheel;
#[cfg(all(feature = "window", target_os = "windows"))]
pub mod win_backdrop;
#[cfg(feature = "window")]
pub mod win_dark;
#[cfg(feature = "window")]
pub mod win_shell;
#[cfg(feature = "window")]
pub mod window_extras;
#[cfg(feature = "window")]
pub mod window_rules;

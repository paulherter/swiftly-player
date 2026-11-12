//! JNI side of the Media3 engine (G3). Kotlin's `Media3Engine` pushes events as JSON lines and drains the commands the Rust
//! player queued; the wire format and the Rust half are `swiftly_player_surface::wire::QueueEngine` (host-tested).
#![allow(unsafe_code)]

use std::sync::{Arc, OnceLock};

use jni::JNIEnv;
use jni::objects::{JClass, JString};
use jni::sys::{jboolean, jstring};
use swiftly_playback::engine::{EngineLoad, PlaybackEngine};
use swiftly_player_surface::SurfaceEngine;
use swiftly_player_surface::wire::QueueEngine;
use swiftly_rules::buffer_level::BufferLevel;

/// The one engine of the process; the player screen holds a clone of this reference.
pub fn engine() -> &'static Arc<QueueEngine> {
    static ENGINE: OnceLock<Arc<QueueEngine>> = OnceLock::new();
    ENGINE.get_or_init(|| Arc::new(QueueEngine::new()))
}

/// Events and (no) frames of the Media3 engine for the live player: Media3 draws into its own surface under the UI.
struct Feed(Arc<QueueEngine>);

impl swiftly_desktop::player_screen::LiveEngine for Feed {
    fn events(&self) -> Vec<swiftly_playback::engine::EngineEvent> {
        self.0.poll_events()
    }
    fn frame(&self, _max_w: u32, _max_h: u32, _sink: &mut dyn FnMut(u32, u32, &[u8])) {}
}

/// Makes the live player (`Core::open_player`) use the Media3 engine.
pub fn register_factory() {
    swiftly_desktop::live_play::set_engine_factory(Box::new(|| {
        let e = Arc::clone(engine());
        Ok((Arc::clone(&e) as Arc<dyn PlaybackEngine>, Arc::new(Feed(e))))
    }));
}

/// `Native.engineEvent(json: String): Boolean`: one event line from Media3.
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_engineEvent(
    mut env: JNIEnv,
    _class: JClass,
    line: JString,
) -> jboolean {
    let Ok(line) = env.get_string(&line) else {
        return 0;
    };
    let ok = engine().feed(&line.to_string_lossy());
    jboolean::from(ok)
}

/// `Native.engineCommands(): String`: the queued commands, one JSON line each (empty when none).
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_engineCommands(
    env: JNIEnv,
    _class: JClass,
) -> jstring {
    env.new_string(engine().take_commands())
        .map_or(std::ptr::null_mut(), |s| s.into_raw())
}

/// `Native.engineLoad(url: String)`: opens a file through the Rust engine contract (`--es video` of the shell, for tests).
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_swiftly_rustshell_Native_engineLoad(
    mut env: JNIEnv,
    _class: JClass,
    url: JString,
) {
    let Ok(url) = env.get_string(&url) else {
        return;
    };
    engine().load(EngineLoad {
        url: url.to_string_lossy().into_owned(),
        headers: Vec::new(),
        start: None,
        audio_server_index: None,
        subtitle_server_index: -1,
        external_subtitles: Vec::new(),
        software_decode: false,
        buffer_level: BufferLevel::Normal,
        frame_rate_match: true,
    });
}

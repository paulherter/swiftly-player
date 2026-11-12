#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let cues = swiftly_playback::subtitle_cues::SubtitleCues::parse(&String::from_utf8_lossy(data));
    let _ = cues.text_at(1.5);
});

//! The embedded app icon picture, decoded from its PNG. No window dependency, so the shared sign-in pages (which also
//! build without the `window` feature for the Apple shells) and the window code read the same picture.

const ICON_256: &[u8] = include_bytes!("../assets/app-icon-256.png");
const ICON_64: &[u8] = include_bytes!("../assets/app-icon-64.png");

/// The same logo with its corners already cut (the files the Linux packages install as the launcher icon).
#[cfg(all(
    unix,
    not(any(target_os = "macos", target_os = "ios", target_os = "android"))
))]
const ROUND_256: &[u8] =
    include_bytes!("../../../Distribution/desktop/icons/swiftly-player-256.png");
#[cfg(all(
    unix,
    not(any(target_os = "macos", target_os = "ios", target_os = "android"))
))]
const ROUND_64: &[u8] = include_bytes!("../../../Distribution/desktop/icons/swiftly-player-64.png");

/// The embedded logo picture (`small`: 64 px, otherwise 256 px) as straight-alpha RGBA with its size; `None` when it
/// cannot be decoded.
pub fn icon_rgba(small: bool) -> Option<(Vec<u8>, u32, u32)> {
    decode(if small { ICON_64 } else { ICON_256 })
}

/// The logo as the shell shows it for the app itself (window icon, taskbar, task switcher). Linux shells draw a picture
/// exactly as given, where iOS and macOS cut the square's corners themselves, so on Linux this is the picture with its
/// corners cut; everywhere else it is [`icon_rgba`].
pub fn shell_icon_rgba(small: bool) -> Option<(Vec<u8>, u32, u32)> {
    #[cfg(all(
        unix,
        not(any(target_os = "macos", target_os = "ios", target_os = "android"))
    ))]
    {
        decode(if small { ROUND_64 } else { ROUND_256 })
    }
    #[cfg(not(all(
        unix,
        not(any(target_os = "macos", target_os = "ios", target_os = "android"))
    )))]
    {
        icon_rgba(small)
    }
}

fn decode(png_bytes: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
    let mut reader = png::Decoder::new(std::io::Cursor::new(png_bytes))
        .read_info()
        .ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    buf.truncate(info.buffer_size());
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => buf
            .as_chunks::<3>()
            .0
            .iter()
            .flat_map(|p| [p[0], p[1], p[2], 255])
            .collect(),
        _ => return None,
    };
    Some((rgba, info.width, info.height))
}

/// The app icon picture (the 256 px logo, straight-alpha RGBA, width, height) decoded once, for pages that show the icon
/// itself (the first-start and sign-in pages). `None` when the embedded picture cannot be decoded.
pub fn app_icon_picture() -> Option<&'static (Vec<u8>, u32, u32)> {
    static PICTURE: std::sync::OnceLock<Option<(Vec<u8>, u32, u32)>> = std::sync::OnceLock::new();
    PICTURE.get_or_init(|| icon_rgba(false)).as_ref()
}

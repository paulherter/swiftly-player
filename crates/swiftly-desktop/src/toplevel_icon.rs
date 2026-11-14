//! The window icon on Wayland, through `xdg-toplevel-icon-v1`. winit 0.30 ignores `with_window_icon` there, so a build
//! that runs without an installed desktop file (the unpacked tar.gz) showed a generic icon in the taskbar. The protocol
//! is optional: a compositor that does not offer it keeps the icon of the desktop file, which is the way the packages
//! (deb, rpm, the installed tar.gz) show it.
//!
//! The icon is set on the window's `xdg_toplevel` over a second event queue of winit's own connection (the display
//! pointer and the toplevel pointer come from winit's public handles); winit's queue never sees these objects.
#![allow(unsafe_code)]

use std::io::Write;
use std::os::fd::AsFd;
use std::path::PathBuf;
use wayland_backend::client::{Backend, ObjectId};
use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::wl_buffer::WlBuffer;
use wayland_client::protocol::wl_registry::WlRegistry;
use wayland_client::protocol::wl_shm::{self, WlShm};
use wayland_client::protocol::wl_shm_pool::WlShmPool;
use wayland_client::{Connection, Dispatch, EventQueue, Proxy, QueueHandle};
use wayland_protocols::xdg::shell::client::xdg_toplevel::XdgToplevel;
use wayland_protocols::xdg::toplevel_icon::v1::client::xdg_toplevel_icon_manager_v1::XdgToplevelIconManagerV1;
use wayland_protocols::xdg::toplevel_icon::v1::client::xdg_toplevel_icon_v1::XdgToplevelIconV1;
use winit::platform::wayland::WindowExtWayland;
use winit::raw_window_handle::{HasDisplayHandle, RawDisplayHandle};
use winit::window::Window;

/// A square picture: straight-alpha RGBA texels, `side` x `side`.
pub struct Picture {
    /// The side in pixels.
    pub side: u32,
    /// `side * side * 4` bytes, R G B A.
    pub rgba: Vec<u8>,
}

/// What keeps the icon alive: the compositor needs the buffers for as long as the icon exists. It is never dropped:
/// winit closes the display when its event loop ends, which can be before the app lets go of this, and destroying a
/// proxy or a queue of a closed display crashes the process at exit (the process ends right after anyway).
pub struct Held {
    _parts: std::mem::ManuallyDrop<Parts>,
}

#[allow(dead_code)]
struct Parts {
    conn: Connection,
    queue: EventQueue<State>,
    icon: XdgToplevelIconV1,
    pool: WlShmPool,
    buffers: Vec<WlBuffer>,
}

struct State;

impl Dispatch<WlRegistry, GlobalListContents> for State {
    fn event(
        _: &mut State,
        _: &WlRegistry,
        _: <WlRegistry as Proxy>::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<State>,
    ) {
    }
}

macro_rules! no_events {
    ($($interface:ty),*) => {$(
        impl Dispatch<$interface, ()> for State {
            fn event(
                _: &mut State,
                _: &$interface,
                _: <$interface as Proxy>::Event,
                _: &(),
                _: &Connection,
                _: &QueueHandle<State>,
            ) {
            }
        }
    )*};
}
no_events!(
    WlShm,
    WlShmPool,
    WlBuffer,
    XdgToplevelIconManagerV1,
    XdgToplevelIconV1
);

/// The bytes of a `wl_shm` `Argb8888` buffer: premultiplied, B G R A in memory.
pub fn argb8888(rgba: &[u8]) -> Vec<u8> {
    rgba.as_chunks::<4>()
        .0
        .iter()
        .flat_map(|p| {
            let a = u32::from(p[3]);
            let m = |c: u8| ((u32::from(c) * a + 127) / 255) as u8;
            [m(p[2]), m(p[1]), m(p[0]), p[3]]
        })
        .collect()
}

/// An unnamed file for the pixels: created in the runtime directory and unlinked at once.
fn scratch_file() -> Option<std::fs::File> {
    let dir = std::env::var_os("XDG_RUNTIME_DIR").map_or_else(std::env::temp_dir, PathBuf::from);
    for n in 0..16 {
        let path = dir.join(format!("swiftly-icon-{}-{n}", std::process::id()));
        if let Ok(f) = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
        {
            let _ = std::fs::remove_file(&path);
            return Some(f);
        }
    }
    None
}

/// Sets `pictures` as the icon of `window` when it is a Wayland window and the compositor offers the protocol;
/// `None` otherwise (X11, Windows, no protocol, any failure): the desktop file then decides, as before.
pub fn apply(window: &Window, pictures: &[Picture]) -> Option<Held> {
    let toplevel = window.xdg_toplevel()?;
    let RawDisplayHandle::Wayland(display) = window.display_handle().ok()?.as_raw() else {
        return None;
    };
    // SAFETY: winit's display pointer is the live `wl_display` of this process; it outlives the connection made here
    // because the window (and with it winit's event loop) is held by the app for as long as `Held` is.
    let backend = unsafe { Backend::from_foreign_display(display.display.as_ptr().cast()) };
    let conn = Connection::from_backend(backend);
    let (globals, mut queue) = registry_queue_init::<State>(&conn).ok()?;
    let qh = queue.handle();
    let manager: XdgToplevelIconManagerV1 = globals.bind(&qh, 1..=1, ()).ok()?;
    let shm: WlShm = globals.bind(&qh, 1..=1, ()).ok()?;
    let pictures: Vec<&Picture> = pictures
        .iter()
        .filter(|p| p.side > 0 && p.rgba.len() == (p.side as usize).pow(2) * 4)
        .collect();
    if pictures.is_empty() {
        return None;
    }
    let bytes: Vec<Vec<u8>> = pictures.iter().map(|p| argb8888(&p.rgba)).collect();
    let total: usize = bytes.iter().map(Vec::len).sum();
    let mut file = scratch_file()?;
    for b in &bytes {
        file.write_all(b).ok()?;
    }
    file.flush().ok()?;
    let pool = shm.create_pool(file.as_fd(), i32::try_from(total).ok()?, &qh, ());
    let icon = manager.create_icon(&qh, ());
    let mut buffers = Vec::new();
    let mut offset = 0_i32;
    for (p, b) in pictures.iter().zip(&bytes) {
        let side = i32::try_from(p.side).ok()?;
        let buffer = pool.create_buffer(
            offset,
            side,
            side,
            side * 4,
            wl_shm::Format::Argb8888,
            &qh,
            (),
        );
        icon.add_buffer(&buffer, 1);
        buffers.push(buffer);
        offset += i32::try_from(b.len()).ok()?;
    }
    // SAFETY: the pointer is winit's live `xdg_toplevel` of this window (`WindowExtWayland::xdg_toplevel`), the
    // interface is the one it was created with.
    let id =
        unsafe { ObjectId::from_ptr(XdgToplevel::interface(), toplevel.as_ptr().cast()).ok()? };
    let toplevel = XdgToplevel::from_id(&conn, id).ok()?;
    manager.set_icon(&toplevel, Some(&icon));
    conn.flush().ok()?;
    // One round trip so the requests are known to have arrived (and a protocol error shows up here, not later).
    queue.roundtrip(&mut State).ok()?;
    Some(Held {
        _parts: std::mem::ManuallyDrop::new(Parts {
            conn,
            queue,
            icon,
            pool,
            buffers,
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::argb8888;

    #[test]
    fn the_pixels_are_premultiplied_and_swapped_to_bgra() {
        assert_eq!(argb8888(&[200, 100, 50, 255]), vec![50, 100, 200, 255]);
        assert_eq!(argb8888(&[200, 100, 50, 0]), vec![0, 0, 0, 0]);
        assert_eq!(argb8888(&[255, 255, 255, 128]), vec![128, 128, 128, 128]);
    }
}

//! Windows only: does ANGLE (OpenGL ES over Direct3D 11) come up on the real GPU, and which texture-sharing
//! extensions does it have? `angle_probe <dir with libEGL.dll and libGLESv2.dll>`
#[cfg(not(all(windows, feature = "mpv")))]
fn main() {
    eprintln!("angle_probe: Windows with the `mpv` feature only");
}

#[cfg(all(windows, feature = "mpv"))]
#[allow(unsafe_code)]
fn main() {
    use libloading::Library;
    use std::ffi::{CStr, c_char, c_void};
    type P = *const c_void;
    unsafe {
        // The LUID of the first Vulkan device that is not a software one: the adapter ANGLE should draw on.
        let vk = Library::new("vulkan-1.dll").expect("vulkan-1");
        type Gipa = unsafe extern "system" fn(usize, *const c_char) -> P;
        let gipa: libloading::Symbol<Gipa> = vk.get(b"vkGetInstanceProcAddr\0").expect("gipa");
        let mut info = [0u8; 64];
        info[0] = 1;
        let ci: unsafe extern "system" fn(*const u8, P, *mut usize) -> i32 =
            std::mem::transmute(gipa(0, c"vkCreateInstance".as_ptr()));
        let mut inst = 0usize;
        ci(info.as_ptr(), std::ptr::null(), &mut inst);
        let ep: unsafe extern "system" fn(usize, *mut u32, *mut usize) -> i32 =
            std::mem::transmute(gipa(inst, c"vkEnumeratePhysicalDevices".as_ptr()));
        let p2: unsafe extern "system" fn(usize, *mut u8) =
            std::mem::transmute(gipa(inst, c"vkGetPhysicalDeviceProperties2".as_ptr()));
        let mut n = 8u32;
        let mut devs = [0usize; 8];
        ep(inst, &mut n, devs.as_mut_ptr());
        let mut luid = (0u32, 0i32);
        for d in &devs[..n as usize] {
            let mut idp = [0u8; 80];
            idp[0..4].copy_from_slice(&1000071004u32.to_le_bytes());
            let mut p = vec![0u8; 1024];
            p[0..4].copy_from_slice(&1000059001u32.to_le_bytes());
            p[8..16].copy_from_slice(&(idp.as_mut_ptr() as usize).to_le_bytes());
            p2(*d, p.as_mut_ptr());
            let name = CStr::from_ptr(p.as_ptr().add(16 + 20).cast())
                .to_string_lossy()
                .into_owned();
            let lo = u32::from_le_bytes([idp[48], idp[49], idp[50], idp[51]]);
            let hi = i32::from_le_bytes([idp[52], idp[53], idp[54], idp[55]]);
            println!("vk {name}: LUID {hi:#x}:{lo:#x}");
            luid = (lo, hi);
        }
        let dir = std::env::args().nth(1).expect("dir");
        let _g = Library::new(format!("{dir}\\libGLESv2.dll")).expect("libGLESv2");
        let egl = Library::new(format!("{dir}\\libEGL.dll")).expect("libEGL");
        let gpa: libloading::Symbol<unsafe extern "C" fn(*const c_char) -> P> =
            egl.get(b"eglGetProcAddress\0").expect("eglGetProcAddress");
        let gpd: unsafe extern "C" fn(u32, P, *const isize) -> P =
            std::mem::transmute(gpa(c"eglGetPlatformDisplayEXT".as_ptr()));
        for use_luid in [false, true] {
            let mut a: Vec<isize> = vec![0x3203, 0x3208]; // PLATFORM_ANGLE_TYPE = D3D11
            if use_luid {
                a.extend([0x34A0, luid.1 as isize, 0x34A1, luid.0 as isize]);
            }
            a.push(0x3038);
            let dpy = gpd(0x3202, std::ptr::null(), a.as_ptr()); // EGL_PLATFORM_ANGLE_ANGLE
            println!("egl (luid {use_luid}): display {dpy:?}");
            let init: unsafe extern "C" fn(P, *mut i32, *mut i32) -> u32 = std::mem::transmute(
                egl.get::<unsafe extern "C" fn()>(b"eglInitialize\0")
                    .expect("init")
                    .into_raw()
                    .as_raw_ptr(),
            );
            let (mut ma, mut mi) = (0, 0);
            if init(dpy, &mut ma, &mut mi) == 0 {
                println!("egl: eglInitialize failed");
                continue;
            }
            let q: unsafe extern "C" fn(P, i32) -> *const c_char = std::mem::transmute(
                egl.get::<unsafe extern "C" fn()>(b"eglQueryString\0")
                    .expect("q")
                    .into_raw()
                    .as_raw_ptr(),
            );
            let ext = CStr::from_ptr(q(dpy, 0x3055))
                .to_string_lossy()
                .into_owned();
            println!("egl {ma}.{mi}");
            for e in [
                "EGL_ANGLE_d3d_texture_client_buffer",
                "EGL_ANGLE_device_d3d",
                "EGL_ANGLE_platform_angle_d3d_luid",
                "EGL_ANGLE_d3d_share_handle_client_buffer",
                "EGL_ANGLE_keyed_mutex",
            ] {
                println!("egl ext {e}: {}", ext.split(' ').any(|x| x == e));
            }
            let bind: unsafe extern "C" fn(u32) -> u32 = std::mem::transmute(
                egl.get::<unsafe extern "C" fn()>(b"eglBindAPI\0")
                    .expect("b")
                    .into_raw()
                    .as_raw_ptr(),
            );
            bind(0x30A0);
            let cc: unsafe extern "C" fn(P, *const i32, *mut P, i32, *mut i32) -> u32 =
                std::mem::transmute(
                    egl.get::<unsafe extern "C" fn()>(b"eglChooseConfig\0")
                        .expect("cc")
                        .into_raw()
                        .as_raw_ptr(),
                );
            let ca = [0x3040, 0x40, 0x3033, 1, 0x3038]; // RENDERABLE_TYPE ES3_BIT, SURFACE_TYPE PBUFFER
            let mut cfg: P = std::ptr::null();
            let mut nc = 0;
            cc(dpy, ca.as_ptr(), &mut cfg, 1, &mut nc);
            let cx: unsafe extern "C" fn(P, P, P, *const i32) -> P = std::mem::transmute(
                egl.get::<unsafe extern "C" fn()>(b"eglCreateContext\0")
                    .expect("cx")
                    .into_raw()
                    .as_raw_ptr(),
            );
            let ctx = cx(dpy, cfg, std::ptr::null(), [0x3098, 3, 0x3038].as_ptr());
            let mk: unsafe extern "C" fn(P, P, P, P) -> u32 = std::mem::transmute(
                egl.get::<unsafe extern "C" fn()>(b"eglMakeCurrent\0")
                    .expect("mk")
                    .into_raw()
                    .as_raw_ptr(),
            );
            println!(
                "egl: configs {nc}, context {ctx:?}, current {}",
                mk(dpy, std::ptr::null(), std::ptr::null(), ctx)
            );
            let gs: unsafe extern "C" fn(u32) -> *const c_char =
                std::mem::transmute(gpa(c"glGetString".as_ptr()));
            let s = |n| CStr::from_ptr(gs(n)).to_string_lossy().into_owned();
            println!(
                "gl: VENDOR {} | RENDERER {} | VERSION {}",
                s(0x1F00),
                s(0x1F01),
                s(0x1F02)
            );
        }
    }
}

//! Windows only: which OpenGL a hidden window gets (renderer, memory-object extensions) and which Vulkan GPUs exist.
//! Run on the machine the GPU video path should work on; prints one line per fact.
#[cfg(not(all(windows, feature = "mpv")))]
fn main() {
    eprintln!("wgl_probe: Windows with the `mpv` feature only");
}

#[cfg(all(windows, feature = "mpv"))]
#[allow(unsafe_code, clippy::missing_safety_doc)]
fn main() {
    use libloading::Library;
    use std::ffi::{CStr, CString, c_char, c_void};
    unsafe {
        let user32 = Library::new("user32.dll").expect("user32");
        let gdi32 = Library::new("gdi32.dll").expect("gdi32");
        let gl = Library::new("opengl32.dll").expect("opengl32");
        let create: libloading::Symbol<
            unsafe extern "system" fn(
                u32,
                *const u8,
                *const u8,
                u32,
                i32,
                i32,
                i32,
                i32,
                usize,
                usize,
                usize,
                usize,
            ) -> usize,
        > = user32.get(b"CreateWindowExA\0").expect("CreateWindowExA");
        let getdc: libloading::Symbol<unsafe extern "system" fn(usize) -> usize> =
            user32.get(b"GetDC\0").expect("GetDC");
        let choose: libloading::Symbol<unsafe extern "system" fn(usize, *const u8) -> i32> =
            gdi32.get(b"ChoosePixelFormat\0").expect("choose");
        let setpf: libloading::Symbol<unsafe extern "system" fn(usize, i32, *const u8) -> i32> =
            gdi32.get(b"SetPixelFormat\0").expect("setpf");
        let wcreate: libloading::Symbol<unsafe extern "system" fn(usize) -> usize> =
            gl.get(b"wglCreateContext\0").expect("wcreate");
        let wmake: libloading::Symbol<unsafe extern "system" fn(usize, usize) -> i32> =
            gl.get(b"wglMakeCurrent\0").expect("wmake");
        let wproc: libloading::Symbol<unsafe extern "system" fn(*const c_char) -> *const c_void> =
            gl.get(b"wglGetProcAddress\0").expect("wproc");
        let getstr: libloading::Symbol<unsafe extern "system" fn(u32) -> *const c_char> =
            gl.get(b"glGetString\0").expect("glGetString");
        // WS_POPUP (hidden: never shown), class STATIC.
        let hwnd = create(
            0,
            c"STATIC".as_ptr().cast(),
            c"p".as_ptr().cast(),
            0x8000_0000,
            0,
            0,
            16,
            16,
            0,
            0,
            0,
            0,
        );
        let hdc = getdc(hwnd);
        let mut pfd = [0u8; 40];
        pfd[0..2].copy_from_slice(&40u16.to_le_bytes());
        pfd[2..4].copy_from_slice(&1u16.to_le_bytes());
        pfd[4..8].copy_from_slice(&(0x4u32 | 0x20 | 0x1).to_le_bytes());
        pfd[9] = 32;
        let pf = choose(hdc, pfd.as_ptr());
        println!(
            "wgl: window {hwnd:#x}, pixel format {pf}, set {}",
            setpf(hdc, pf, pfd.as_ptr())
        );
        let ctx = wcreate(hdc);
        println!("wgl: context {ctx:#x}, current {}", wmake(hdc, ctx));
        let s = |n: u32| {
            let p = getstr(n);
            if p.is_null() {
                String::from("(null)")
            } else {
                CStr::from_ptr(p).to_string_lossy().into_owned()
            }
        };
        println!(
            "gl: VENDOR {} | RENDERER {} | VERSION {}",
            s(0x1F00),
            s(0x1F01),
            s(0x1F02)
        );
        let ext = s(0x1F03);
        for e in [
            "GL_EXT_memory_object",
            "GL_EXT_memory_object_win32",
            "GL_EXT_semaphore",
            "GL_EXT_semaphore_win32",
            "GL_NV_gpu_affinity",
            "GL_AMD_gpu_association",
        ] {
            println!("gl ext {e}: {}", ext.split(' ').any(|x| x == e));
        }
        let get_ext = wproc(c"wglGetExtensionsStringARB".as_ptr());
        if !get_ext.is_null() {
            let f: unsafe extern "system" fn(usize) -> *const c_char = std::mem::transmute(get_ext);
            let w = CStr::from_ptr(f(hdc)).to_string_lossy().into_owned();
            for e in [
                "WGL_ARB_create_context",
                "WGL_NV_DX_interop2",
                "WGL_AMD_gpu_association",
                "WGL_NV_gpu_affinity",
            ] {
                println!("wgl ext {e}: {}", w.split(' ').any(|x| x == e));
            }
        }
        // Vulkan: devices and the Win32 external-memory extension.
        match Library::new("vulkan-1.dll") {
            Err(e) => println!("vk: no vulkan-1.dll ({e})"),
            Ok(vk) => {
                type Gipa = unsafe extern "system" fn(usize, *const c_char) -> *const c_void;
                let gipa: libloading::Symbol<Gipa> =
                    vk.get(b"vkGetInstanceProcAddr\0").expect("gipa");
                let mut info = [0u8; 64]; // VkInstanceCreateInfo, sType 1, all else zero
                info[0] = 1;
                let create_i: unsafe extern "system" fn(
                    *const u8,
                    *const c_void,
                    *mut usize,
                ) -> i32 = std::mem::transmute(gipa(0, c"vkCreateInstance".as_ptr()));
                let mut inst = 0usize;
                println!(
                    "vk: vkCreateInstance {}",
                    create_i(info.as_ptr(), std::ptr::null(), &mut inst)
                );
                let enum_p: unsafe extern "system" fn(usize, *mut u32, *mut usize) -> i32 =
                    std::mem::transmute(gipa(inst, c"vkEnumeratePhysicalDevices".as_ptr()));
                let props: unsafe extern "system" fn(usize, *mut u8) =
                    std::mem::transmute(gipa(inst, c"vkGetPhysicalDeviceProperties".as_ptr()));
                let exts: unsafe extern "system" fn(
                    usize,
                    *const c_char,
                    *mut u32,
                    *mut u8,
                ) -> i32 = std::mem::transmute(gipa(
                    inst,
                    c"vkEnumerateDeviceExtensionProperties".as_ptr(),
                ));
                let mut n = 0u32;
                enum_p(inst, &mut n, std::ptr::null_mut());
                let mut devs = vec![0usize; n as usize];
                enum_p(inst, &mut n, devs.as_mut_ptr());
                for d in devs {
                    let mut p = vec![0u8; 1024];
                    props(d, p.as_mut_ptr());
                    let name = CStr::from_ptr(p.as_ptr().add(20).cast())
                        .to_string_lossy()
                        .into_owned();
                    let vendor = u32::from_le_bytes([p[8], p[9], p[10], p[11]]);
                    let mut m = 0u32;
                    exts(d, std::ptr::null(), &mut m, std::ptr::null_mut());
                    let mut buf = vec![0u8; m as usize * 260];
                    exts(d, std::ptr::null(), &mut m, buf.as_mut_ptr());
                    let names: Vec<String> = (0..m as usize)
                        .map(|i| {
                            CStr::from_ptr(buf.as_ptr().add(i * 260).cast())
                                .to_string_lossy()
                                .into_owned()
                        })
                        .collect();
                    let has = |e: &str| names.iter().any(|x| x == e);
                    println!(
                        "vk device {name} (vendor {vendor:#x}): external_memory_win32 {}, external_semaphore_win32 {}",
                        has("VK_KHR_external_memory_win32"),
                        has("VK_KHR_external_semaphore_win32")
                    );
                }
            }
        }
        let _ = CString::new("");
    }
}

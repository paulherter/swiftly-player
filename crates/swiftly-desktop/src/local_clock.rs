//! The local time of day, for "Endet um" in the player (the Mac asks `Date.now` in the user's time zone).
#![allow(unsafe_code)]

/// Seconds since local midnight now, in the user's time zone.
#[must_use]
pub fn day_seconds() -> f64 {
    imp::day_seconds()
}

#[cfg(unix)]
mod imp {
    pub fn day_seconds() -> f64 {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        let t = now.floor() as libc::time_t;
        // SAFETY: `tm` is plain data that `localtime_r` fills; `t` outlives the call.
        let tm = unsafe {
            let mut tm: libc::tm = std::mem::zeroed();
            if libc::localtime_r(&t, &mut tm).is_null() {
                return now.rem_euclid(86_400.0);
            }
            tm
        };
        f64::from(tm.tm_hour) * 3600.0
            + f64::from(tm.tm_min) * 60.0
            + f64::from(tm.tm_sec)
            + now.fract()
    }
}

#[cfg(windows)]
mod imp {
    pub fn day_seconds() -> f64 {
        use windows_sys::Win32::Foundation::SYSTEMTIME;
        use windows_sys::Win32::System::SystemInformation::GetLocalTime;
        // SAFETY: `SYSTEMTIME` is plain integers, valid when zeroed; `GetLocalTime` fills the struct it is given.
        let mut t: SYSTEMTIME = unsafe { std::mem::zeroed() };
        // SAFETY: as above, `t` outlives the call.
        unsafe { GetLocalTime(&mut t) };
        f64::from(t.wHour) * 3600.0
            + f64::from(t.wMinute) * 60.0
            + f64::from(t.wSecond)
            + f64::from(t.wMilliseconds) / 1000.0
    }
}

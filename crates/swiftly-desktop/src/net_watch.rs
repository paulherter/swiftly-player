//! The network watcher of the downloads: the Mac app listens to `NWPathMonitor`; the desktop asks a [`NetworkWatcher`]
//! from time to time and tells the download machine (`Intent::NetworkChanged`) when the answer changed. The machine
//! then shows "Wartet auf Netz" and picks the waiting titles up again when the network returns.
//!
//! Windows asks the routing table (a UDP socket "connected" to a public address sends nothing and fails at once
//! without a route). Unix reports online. Whether a connection is metered is unknown on every platform here, and
//! unknown counts as allowed: `wlan` is true whenever there is a connection, so "Nur über WLAN" never blocks a
//! desktop that has a network.

use crate::downloads_screen::Dyn;
use swiftly_downloads::Intent;
use swiftly_vm::{DownloadsIntent, DownloadsVm};

/// What the platform knows about the connection (`NWPath`: Wi-Fi or cable, none).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NetState {
    /// Wi-Fi or cable (not metered as far as known).
    pub wlan: bool,
    /// No connection at all.
    pub none: bool,
}

impl NetState {
    /// Connected, not metered.
    pub const ONLINE: NetState = NetState {
        wlan: true,
        none: false,
    };
    /// No connection.
    pub const OFFLINE: NetState = NetState {
        wlan: false,
        none: true,
    };
}

/// Reports the connection. Cheap enough to call every few seconds.
pub trait NetworkWatcher: Send + Sync {
    /// The state right now.
    fn state(&self) -> NetState;
}

/// The real watcher of the platform.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemWatcher;

impl NetworkWatcher for SystemWatcher {
    fn state(&self) -> NetState {
        system_state()
    }
}

#[cfg(windows)]
fn system_state() -> NetState {
    use std::net::UdpSocket;
    let route = |bind: &str, to: &str| {
        UdpSocket::bind(bind)
            .and_then(|s| s.connect(to).map(|()| s))
            .is_ok()
    };
    if route("0.0.0.0:0", "1.1.1.1:53") || route("[::]:0", "[2606:4700:4700::1111]:53") {
        NetState::ONLINE
    } else {
        NetState::OFFLINE
    }
}

#[cfg(not(windows))]
fn system_state() -> NetState {
    NetState::ONLINE
}

/// Remembers the last answer and forwards changes.
#[derive(Debug, Default)]
pub struct Pump {
    last: Option<NetState>,
}

impl Pump {
    /// A pump that has not reported yet (the first poll always reports).
    pub fn new() -> Pump {
        Pump::default()
    }

    /// Asks `watcher` and, when the answer is new, sends `NetworkChanged` to `vm`. True when something was sent.
    pub fn poll(&mut self, watcher: &dyn NetworkWatcher, vm: &DownloadsVm<Dyn>) -> bool {
        let now = watcher.state();
        if self.last == Some(now) {
            return false;
        }
        self.last = Some(now);
        let _ = vm.send(DownloadsIntent::Engine(Box::new(Intent::NetworkChanged {
            wlan: now.wlan,
            none: now.none,
        })));
        let _ = vm.send(DownloadsIntent::Engine(Box::new(Intent::Tick)));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_system_watcher_answers() {
        let s = SystemWatcher.state();
        assert_eq!(s.none, !s.wlan);
    }
}

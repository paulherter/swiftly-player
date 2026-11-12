//! Finding a Jellyfin server on the local network (`ServerDiscovery`, ServerDiscovery.swift).
//!
//! Jellyfin listens on UDP 7359 for the sentence "who is JellyfinServer?" and answers the
//! sender with a [`FoundServer`]. This module is sans-I/O: it builds the question, reads and
//! merges answers; the host owns the socket behind [`DatagramSocket`] (a broadcast needs
//! platform permissions, so it is never done here).

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};
pub use swiftly_rules::natural_order::StandardCollator;

use crate::server_url::{normalize, normalize_zoned};

/// The UDP port Jellyfin listens on (`ServerDiscovery.port`).
pub const PORT: u16 = 7359;
/// The sentence Jellyfin answers to (`ServerDiscovery.question`).
pub const QUESTION: &str = "who is JellyfinServer?";
/// How long one round listens for answers, in seconds (`ServerDiscovery.listening`).
pub const LISTENING_SECONDS: u32 = 2;
/// The pause between rounds while the page is open, in seconds (`ServerDiscovery.pause`).
pub const PAUSE_SECONDS: u32 = 8;

/// A Jellyfin server that answered on the local network. Keys are the server's own
/// (`Id`, `Name`, `Address`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct FoundServer {
    /// The server id.
    #[serde(rename = "Id")]
    pub id: String,
    /// The server name.
    #[serde(rename = "Name")]
    pub name: String,
    /// A full base address, "http://192.168.1.5:8096", as the server publishes it.
    #[serde(rename = "Address")]
    pub address: String,
}

impl FoundServer {
    /// The address as a person would say it: "192.168.1.5:8096", without the scheme.
    pub fn short_address(&self) -> String {
        let mut text = self.address.as_str();
        for scheme in ["http://", "https://"] {
            if text.len() >= scheme.len() && text[..scheme.len()].eq_ignore_ascii_case(scheme) {
                text = &text[scheme.len()..];
                break;
            }
        }
        text.trim_end_matches('/').to_string()
    }
}

/// One answer (`ServerDiscovery.read`). `None` for anything that is not a usable server:
/// another program on the port, a server without id or address.
pub fn read(data: &[u8]) -> Option<FoundServer> {
    let server: FoundServer = serde_json::from_slice(data).ok()?;
    if server.id.is_empty() || normalize(&server.address).is_none() {
        return None;
    }
    Some(server)
}

/// One entry per server, in a stable order, with the root collation (no app language known).
/// Hosts that know the language use [`merged_localized`].
pub fn merged(known: &[FoundServer], new: &[FoundServer]) -> Vec<FoundServer> {
    match StandardCollator::new("") {
        Ok(collator) => merged_localized(known, new, &collator),
        Err(_) => merged_by(known, new, |a, b| a.to_lowercase().cmp(&b.to_lowercase())),
    }
}

/// One entry per server, in a stable order (`ServerDiscovery.merged`). The latest answer wins,
/// the order is by name as Swift's `localizedStandardCompare` reads it (numbers as numbers,
/// case and accents ignored first) in the language of `collator`, then by id.
pub fn merged_localized(
    known: &[FoundServer],
    new: &[FoundServer],
    collator: &StandardCollator,
) -> Vec<FoundServer> {
    merged_by(known, new, |a, b| collator.compare(a, b))
}

fn merged_by(
    known: &[FoundServer],
    new: &[FoundServer],
    compare: impl Fn(&str, &str) -> Ordering,
) -> Vec<FoundServer> {
    let mut by_id: BTreeMap<&str, &FoundServer> = BTreeMap::new();
    for server in known.iter().chain(new) {
        by_id.insert(&server.id, server);
    }
    let mut all: Vec<FoundServer> = by_id.into_values().cloned().collect();
    all.sort_by(|a, b| compare(&a.name, &b.name).then_with(|| a.id.cmp(&b.id)));
    all
}

/// What the page shows (`ServerDiscovery.shown`): without the servers whose address is already
/// in the field or under "Zuletzt verbunden". Compared by host and port.
pub fn shown(found: &[FoundServer], except: &[Option<&str>]) -> Vec<FoundServer> {
    let taken: HashSet<String> = except.iter().flatten().filter_map(|a| key(a)).collect();
    found
        .iter()
        .filter(|s| key(&s.address).is_some_and(|k| !taken.contains(&k)))
        .cloned()
        .collect()
}

fn key(address: &str) -> Option<String> {
    let zoned = normalize_zoned(address)?;
    let url = &zoned.url;
    let host = url.host_str()?.to_lowercase();
    let host = match &zoned.zone {
        Some(zone) => format!("{host}%25{}", zone.to_lowercase()),
        None => host,
    };
    let port = url
        .port()
        .unwrap_or(if url.scheme() == "https" { 443 } else { 80 });
    Some(format!("{host}:{port}"))
}

/// The broadcast address of an interface: its address with all host bits set, both in host byte
/// order (`ServerDiscovery.broadcast`).
pub fn broadcast(address: u32, netmask: u32) -> u32 {
    address | !netmask
}

/// The targets of a round: 255.255.255.255 always, then the broadcast address of every
/// `(address, netmask)` interface, without duplicates (the Apple path of `Datagram.targets`).
pub fn targets(interfaces: &[(u32, u32)]) -> Vec<u32> {
    let mut all = vec![u32::MAX];
    for (address, netmask) in interfaces {
        let target = broadcast(*address, *netmask);
        if !all.contains(&target) {
            all.push(target);
        }
    }
    all
}

/// The UDP half the host provides: one socket, the sentence to every target, then whatever
/// comes back until the time is up.
pub trait DatagramSocket {
    /// Sends `payload` to `target` (host byte order) on `port`; `true` if all bytes went out.
    fn send(&self, payload: &[u8], target: u32, port: u16) -> bool;
    /// Everything received within `seconds`.
    fn receive(&self, seconds: u32) -> Vec<Vec<u8>>;
}

/// One round (`ServerDiscovery.search`): ask every target, listen, keep the usable answers.
/// Empty when the network refuses the broadcast.
pub fn search<S: DatagramSocket>(socket: &S, interfaces: &[(u32, u32)]) -> Vec<FoundServer> {
    let mut sent = false;
    for target in targets(interfaces) {
        sent = socket.send(QUESTION.as_bytes(), target, PORT) || sent;
    }
    if !sent {
        return Vec::new();
    }
    socket
        .receive(LISTENING_SECONDS)
        .iter()
        .filter_map(|d| read(d))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn server(id: &str, name: &str, address: &str) -> FoundServer {
        FoundServer {
            id: id.into(),
            name: name.into(),
            address: address.into(),
        }
    }

    // ServerDiscoveryTests.swift:13 answerOfJellyfinIsRead
    #[test]
    fn answer_of_jellyfin_is_read() {
        let answer = r#"{"Address":"http://192.168.1.5:8096","Id":"a1b2","Name":"Wohnzimmer","EndpointAddress":null}"#;
        assert_eq!(
            read(answer.as_bytes()),
            Some(server("a1b2", "Wohnzimmer", "http://192.168.1.5:8096"))
        );
    }

    // :19 otherAnswersAreIgnored
    #[test]
    fn other_answers_are_ignored() {
        for text in [
            "who is JellyfinServer?",
            r#"{"Address":"","Id":"a1b2","Name":"x"}"#,
            r#"{"Address":"http://192.168.1.5:8096","Id":"","Name":"x"}"#,
            r#"{"Name":"x"}"#,
        ] {
            assert!(read(text.as_bytes()).is_none(), "{text}");
        }
    }

    // :31 eachServerOnceSortedByName
    #[test]
    fn each_server_once_sorted_by_name() {
        let first = [server("2", "Wohnzimmer", "http://192.168.1.5:8096")];
        let next = [
            server("1", "Büro", "http://10.0.0.2:8096"),
            server("2", "Wohnzimmer", "http://192.168.1.6:8096"),
        ];
        let all = merged(&first, &next);
        assert_eq!(
            all.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            ["1", "2"]
        );
        assert_eq!(all[1].address, "http://192.168.1.6:8096");
    }

    fn names(list: &[FoundServer]) -> Vec<&str> {
        list.iter().map(|s| s.name.as_str()).collect()
    }

    fn sorted(locale: &str, input: &[&str]) -> Vec<String> {
        let c = StandardCollator::new(locale).expect("collator");
        let list: Vec<FoundServer> = input
            .iter()
            .enumerate()
            .map(|(i, n)| server(&i.to_string(), n, "http://x.de"))
            .collect();
        merged_localized(&list, &[], &c)
            .iter()
            .map(|s| s.name.clone())
            .collect()
    }

    #[test]
    fn digits_are_numbers() {
        for locale in ["de", "en", "ru"] {
            assert_eq!(
                sorted(locale, &["Server 10", "Server 2", "server 1"]),
                ["server 1", "Server 2", "Server 10"],
                "{locale}"
            );
        }
    }

    #[test]
    fn case_and_accents_come_second() {
        for locale in ["de", "en", "ru"] {
            assert_eq!(
                sorted(locale, &["Zebra", "ärger", "alpha"]),
                ["alpha", "ärger", "Zebra"],
                "{locale}"
            );
            assert_eq!(
                sorted(locale, &["Kiste", "é", "kiste", "e", "E"]),
                ["e", "E", "é", "kiste", "Kiste"],
                "{locale}"
            );
        }
    }

    #[test]
    fn language_decides_between_scripts() {
        assert_eq!(sorted("ru", &["Wohnzimmer", "Жук"]), ["Жук", "Wohnzimmer"]);
        assert_eq!(sorted("de", &["Жук", "Wohnzimmer"]), ["Wohnzimmer", "Жук"]);
        assert_eq!(sorted("en", &["Жук", "Wohnzimmer"]), ["Wohnzimmer", "Жук"]);
    }

    #[test]
    fn equal_names_fall_back_to_the_id() {
        let c = StandardCollator::new("de").expect("collator");
        let list = [
            server("b", "Same", "http://x.de"),
            server("a", "Same", "http://x.de"),
        ];
        let all = merged_localized(&list, &[], &c);
        assert_eq!(
            all.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            ["a", "b"]
        );
        assert_eq!(names(&all), ["Same", "Same"]);
    }

    #[test]
    fn plain_merged_still_orders_by_name() {
        let list = [
            server("1", "b", "http://x.de"),
            server("2", "A10", "http://x.de"),
            server("3", "a2", "http://x.de"),
        ];
        assert_eq!(names(&merged(&list, &[])), ["a2", "A10", "b"]);
    }

    // :41 serverAlreadyOfferedIsHidden
    #[test]
    fn server_already_offered_is_hidden() {
        let found = [
            server("1", "Büro", "http://10.0.0.2:8096"),
            server("2", "Wohnzimmer", "http://192.168.1.5:8096/"),
        ];
        let kept = shown(&found, &[Some("192.168.1.5:8096"), None]);
        assert_eq!(
            kept.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            ["1"]
        );
    }

    // :49 otherPortIsAnotherServer
    #[test]
    fn other_port_is_another_server() {
        let found = [server("1", "Test", "http://192.168.1.5:8097")];
        assert_eq!(shown(&found, &[Some("192.168.1.5:8096")]).len(), 1);
    }

    #[test]
    fn link_local_server_with_a_zone_is_read_and_told_apart() {
        let answer = r#"{"Address":"http://[fe80::1%25en0]:8096","Id":"z1","Name":"Kiste"}"#;
        let found = read(answer.as_bytes()).expect("a zone id is a usable address");
        assert_eq!(found.short_address(), "[fe80::1%25en0]:8096");
        assert_eq!(
            shown(
                std::slice::from_ref(&found),
                &[Some("[fe80::1%25en1]:8096")]
            )
            .len(),
            1
        );
        assert!(shown(&[found], &[Some("http://[fe80::1%25EN0]:8096/")]).is_empty());
    }

    // :54 shortAddressWithoutScheme
    #[test]
    fn short_address_without_scheme() {
        assert_eq!(
            server("1", "x", "http://192.168.1.5:8096/").short_address(),
            "192.168.1.5:8096"
        );
        assert_eq!(
            server("1", "x", "https://media.home.arpa").short_address(),
            "media.home.arpa"
        );
    }

    // :59 broadcastAddressOfInterface
    #[test]
    fn broadcast_address_of_interface() {
        assert_eq!(broadcast(0xC0A8_0117, 0xFFFF_FF00), 0xC0A8_01FF);
        assert_eq!(broadcast(0x0A01_0203, 0xFFFF_FC00), 0x0A01_03FF);
    }

    struct Fake {
        sent: RefCell<Vec<(Vec<u8>, u32, u16)>>,
        works: bool,
        answers: Vec<Vec<u8>>,
    }

    impl DatagramSocket for Fake {
        fn send(&self, payload: &[u8], target: u32, port: u16) -> bool {
            self.sent
                .borrow_mut()
                .push((payload.to_vec(), target, port));
            self.works
        }
        fn receive(&self, _seconds: u32) -> Vec<Vec<u8>> {
            self.answers.clone()
        }
    }

    #[test]
    fn a_round_asks_every_target_once_and_keeps_usable_answers() {
        let socket = Fake {
            sent: RefCell::default(),
            works: true,
            answers: vec![
                r#"{"Address":"http://10.0.0.2:8096","Id":"1","Name":"Büro"}"#
                    .as_bytes()
                    .to_vec(),
                b"noise".to_vec(),
            ],
        };
        let found = search(
            &socket,
            &[(0xC0A8_0117, 0xFFFF_FF00), (0xC0A8_0118, 0xFFFF_FF00)],
        );
        assert_eq!(found.len(), 1);
        let sent = socket.sent.borrow();
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0], (QUESTION.as_bytes().to_vec(), u32::MAX, 7359));
        assert_eq!(sent[1].1, 0xC0A8_01FF);
    }

    #[test]
    fn a_refused_broadcast_gives_an_empty_list() {
        let socket = Fake {
            sent: RefCell::default(),
            works: false,
            answers: vec![b"x".to_vec()],
        };
        assert!(search(&socket, &[]).is_empty());
    }
}

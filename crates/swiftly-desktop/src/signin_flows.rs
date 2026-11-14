//! The sign-in steps for Emby and Plex, the search for servers on the local network, and the two calls out of the app
//! (the browser, the clipboard). The steps are generic over the transport, so the tests run them over the mock; the
//! live backend (`live.rs`) calls them with the real one. Texts are German sentences, the way `MacEmbySignIn` and
//! `MacPlexSignIn` say them.

use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use swiftly_jellyfin::discovery::{self, DatagramSocket, FoundServer};
use swiftly_jellyfin::{ClientConfig, JellyfinClient, ServerKind};
use swiftly_jellyfin::{
    EmbyAttempt, EmbyProblem, emby_classify_attempt, emby_classify_failure, emby_sign_in_header,
    not_emby_jellyfin,
};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_plex::{
    PlexAccountService, PlexAccountSession, PlexConnector, PlexError, PlexHomeUser, PlexIdentity,
    PlexServerResource, Sleep,
};
use swiftly_seerr::Seerr;
use swiftly_vm::Shared;

/// What the Emby address step found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbyFound {
    /// The address that answered.
    pub address: String,
    /// The server's own name (else the host).
    pub name: String,
    /// The server's version.
    pub version: String,
}

/// The answer of one Quick Connect poll (the screen feeds the core's `QuickConnectWait` with it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QuickAnswer {
    /// Not approved yet.
    Waiting,
    /// The question did not get through (the wait goes on).
    Failed,
    /// The server says the code ran out.
    Expired,
    /// Approved and signed in: the user name.
    SignedIn(String),
    /// Approved, but the sign-in itself failed: the sentence.
    SignInFailed(String),
}

/// The sentence when nothing answers at an Emby address (the "Server ist abgetaucht" banner shows it).
pub const EMBY_DOWN: &str = "Der Server antwortet nicht.";
/// The sentence when nothing answers at a Jellyfin address.
pub const JELLYFIN_DOWN: &str =
    "Unter dieser Adresse antwortet kein Jellyfin-Server. Stimmt die Adresse?";

fn config(device: &(String, String, String), kind: ServerKind) -> ClientConfig {
    ClientConfig::new(&device.0, &device.1, &device.2).kind(kind)
}

/// Checks the typed Emby address: scheme guess, a Jellyfin behind it is told apart (`AppModel.embyCheck`).
/// `device` is (device id, device name, client version).
///
/// # Errors
/// The German line for the failure.
pub async fn emby_connect<T: HttpTransport + 'static>(
    net: Arc<T>,
    device: &(String, String, String),
    typed: &str,
) -> Result<EmbyFound, String> {
    let mut last = None;
    for address in Seerr::addresses(typed) {
        let client = JellyfinClient::new(
            Shared(Arc::clone(&net)),
            &address,
            config(device, ServerKind::Emby),
        )
        .map_err(|_| "Die Adresse ist nicht gültig.".to_owned())?;
        let answer = client.check_reachability().await;
        match emby_classify_attempt(&answer) {
            EmbyAttempt::Accepted => {
                let info = answer.map_err(|_| EMBY_DOWN.to_owned())?;
                let host = address
                    .trim_start_matches("https://")
                    .trim_start_matches("http://")
                    .trim_end_matches('/')
                    .to_owned();
                let (name, version) = emby_sign_in_header(&info, Some(&host));
                return Ok(EmbyFound {
                    address,
                    name: name.unwrap_or(host),
                    version,
                });
            }
            EmbyAttempt::LooksLikeJellyfin => return Err(problem_text(&not_emby_jellyfin())),
            EmbyAttempt::Failed { try_next } => {
                last = answer.err();
                if !try_next {
                    break;
                }
            }
        }
    }
    Err(problem_text(&emby_classify_failure(last.as_ref(), typed)))
}

fn problem_text(p: &EmbyProblem) -> String {
    match p {
        EmbyProblem::Unreachable { .. } => EMBY_DOWN.into(),
        EmbyProblem::NotEmby { found } => format!("Hier antwortet {}, kein Emby. Nimm bei der Auswahl den passenden Server.", found.as_deref().unwrap_or("ein anderer Server")),
        EmbyProblem::BadAddress => "Die Adresse ist nicht gültig.".into(),
        EmbyProblem::LoginPage => "Vor dem Server sitzt eine Anmeldeseite. Trag unter Erweitert den Header ein, den sie verlangt.".into(),
    }
}

/// The names of the Emby users the server lists ("Wer schaut?"); empty when the server hides the list.
pub async fn emby_users<T: HttpTransport + 'static>(
    net: Arc<T>,
    device: &(String, String, String),
    address: &str,
) -> Vec<String> {
    emby_users_with_pictures(net, device, address)
        .await
        .into_iter()
        .map(|u| u.0)
        .collect()
}

/// The Emby users with the address of their picture (`MacEmbySignIn`'s `AccountCharacter` shows it; the server answers
/// 404 for a user without one and the page then keeps the initial).
pub async fn emby_users_with_pictures<T: HttpTransport + 'static>(
    net: Arc<T>,
    device: &(String, String, String),
    address: &str,
) -> Vec<(String, Option<String>)> {
    let Ok(client) = JellyfinClient::new(Shared(net), address, config(device, ServerKind::Emby))
    else {
        return Vec::new();
    };
    client
        .public_users()
        .await
        .map(|list| {
            list.iter()
                .map(|u| {
                    (
                        u.name.clone(),
                        client.user_image(u, 480).map(|a| a.to_string()),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

// ---- Plex ----------------------------------------------------------------------------------------------------------

/// The plex.tv account service: the real hosts, or one fixture server for every host (`SWIFTLY_PLEX_FIXTURE=http://127.0.0.1:PORT`,
/// live runs only).
pub fn plex_service<T: HttpTransport + 'static>(
    identity: PlexIdentity,
    net: Arc<T>,
) -> PlexAccountService<T> {
    match std::env::var("SWIFTLY_PLEX_FIXTURE") {
        Ok(base) if !base.is_empty() => {
            PlexAccountService::with_bases(identity, net, &base, &base, &base)
        }
        _ => PlexAccountService::new(identity, net),
    }
}

/// What the Plex worker tells the screen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlexEvent {
    /// Open this page in the browser; the wait for plex.tv begins.
    Open(String),
    /// How long the code lives, in seconds, as plex.tv reports it (`PlexPin.expires_in`): the countdown runs on it.
    Expiry(u64),
    /// The picture address of each profile in the `Profiles` that follows (`PlexHomeUser.thumb`).
    Pictures(Vec<Option<String>>),
    /// Signed in at plex.tv: the profiles (name, asks for a PIN).
    Profiles(Vec<(String, bool)>),
    /// The flow failed, with the sentence.
    Failed(String),
    /// The plex.tv account's name (the page title once signed in).
    Account(String),
    /// The code ran out before the sign-in was finished.
    Expired,
    /// plex.tv does not answer.
    Unreachable,
}

/// What the flow remembers between its steps.
#[derive(Default)]
pub struct PlexState {
    account_token: String,
    users: Vec<PlexHomeUser>,
    token: String,
    profile: usize,
    servers: Vec<PlexServerResource>,
}

/// The state shared by the steps.
pub type SharedPlex = Arc<Mutex<PlexState>>;

/// The German line of a failed Plex step.
pub fn plex_text(e: &PlexError) -> String {
    match e {
        PlexError::Request(k) => match k {
            ErrorKind::Certificate(_) => "Dem Zertifikat wird nicht vertraut.".into(),
            ErrorKind::Network { .. } => "Plex ist gerade nicht erreichbar. Läuft das Netz?".into(),
            _ => "Plex hat nicht geantwortet. Versuch es noch mal.".into(),
        },
        other => other
            .text_key()
            .unwrap_or("Das hat nicht geklappt.")
            .to_owned(),
    }
}

/// Makes the code, tells the screen which page to open, waits for the confirmation (`pause` between asks, `limit` in
/// all), then loads the Plex Home profiles and tells the screen.
pub async fn plex_sign_in<T: HttpTransport + 'static>(
    svc: &PlexAccountService<T>,
    sleep: &Sleep,
    pause: Duration,
    limit: Duration,
    state: &SharedPlex,
    tx: &Sender<PlexEvent>,
) {
    let run = async {
        let pin = svc.start_pin(true).await?;
        let url = svc
            .auth_url(&pin, None)
            .ok_or(PlexError::Request(ErrorKind::InvalidServerUrl))?;
        let _ = tx.send(PlexEvent::Open(url.to_string()));
        if let Some(secs) = pin
            .expires_in
            .and_then(|s| u64::try_from(s).ok())
            .filter(|s| *s > 0)
        {
            let _ = tx.send(PlexEvent::Expiry(secs));
        }
        let token = svc.await_token(&pin, pause, limit, sleep).await?;
        let users = svc.home_users(&token).await?;
        if let Ok(swiftly_plex::TokenState::Valid(account)) = svc.validate(&token).await {
            let _ = tx.send(PlexEvent::Account(account.title));
        }
        let shown = if users.is_empty() {
            vec![("Plex".to_owned(), false)]
        } else {
            users
                .iter()
                .map(|u| (u.title.clone(), u.is_protected))
                .collect()
        };
        let _ = tx.send(PlexEvent::Pictures(
            users.iter().map(|u| u.thumb.clone()).collect(),
        ));
        if let Ok(mut s) = state.lock() {
            s.account_token = token;
            s.users = users;
        }
        Ok::<_, PlexError>(shown)
    };
    let _ = tx.send(match run.await {
        Ok(shown) => PlexEvent::Profiles(shown),
        Err(PlexError::PinExpired) => PlexEvent::Expired,
        Err(PlexError::Request(ErrorKind::Network { .. })) => PlexEvent::Unreachable,
        Err(e) => PlexEvent::Failed(plex_text(&e)),
    });
}

/// The line under a server's name (`MacPlexSignIn.serverLine`): whose it is, and where it can be reached.
pub fn plex_server_line(s: &PlexServerResource) -> String {
    let owner = if s.owned {
        "Dein Server".to_owned()
    } else {
        match s.source_title.as_deref() {
            Some(x) => format!("Von {x} freigegeben"),
            None => "Dein Server".to_owned(),
        }
    };
    let place = if !s.presence {
        "laut Plex offline"
    } else if s.connections.iter().any(|c| c.is_local) {
        "im WLAN"
    } else {
        "über das Internet"
    };
    format!("{owner} · {place}")
}

/// Picks profile `index` (with its `pin`, empty for none) and loads the servers of the account: (name, detail).
///
/// # Errors
/// The German line; a wrong PIN is [`PlexError::ProfilePinWrong`]'s sentence.
pub async fn plex_pick<T: HttpTransport + 'static>(
    svc: &PlexAccountService<T>,
    state: &SharedPlex,
    index: usize,
    pin: &str,
) -> Result<Vec<(String, String)>, String> {
    let (user, account_token) = {
        let s = state
            .lock()
            .map_err(|_| "Das hat nicht geklappt.".to_owned())?;
        (s.users.get(index).cloned(), s.account_token.clone())
    };
    let token = match &user {
        Some(u) => svc
            .switch_user(u, Some(pin), &account_token)
            .await
            .map_err(|e| plex_text(&e))?,
        None => account_token,
    };
    let servers = svc.servers(&token).await.map_err(|e| plex_text(&e))?;
    let shown = servers
        .iter()
        .map(|s| (s.name.clone(), plex_server_line(s)))
        .collect();
    if let Ok(mut s) = state.lock() {
        s.token = token;
        s.profile = index;
        s.servers = servers;
    }
    Ok(shown)
}

/// Picks server `index`: finds the address that answers and builds the session to store. Answer: the session and the
/// profile name.
///
/// # Errors
/// The German line.
pub async fn plex_finish<T: HttpTransport + 'static>(
    net: Arc<T>,
    identity: &PlexIdentity,
    sleep: &Sleep,
    state: &SharedPlex,
    index: usize,
) -> Result<(PlexAccountSession, String), String> {
    let (server, token, account_token, user) = {
        let s = state
            .lock()
            .map_err(|_| "Das hat nicht geklappt.".to_owned())?;
        (
            s.servers.get(index).cloned(),
            s.token.clone(),
            s.account_token.clone(),
            s.users.get(s.profile).cloned(),
        )
    };
    let server = server.ok_or("Der Server ist nicht mehr in der Liste.")?;
    let connector = PlexConnector::with_transport(
        net,
        identity.clone(),
        token.clone(),
        server.machine_identifier.clone(),
        Duration::from_secs(3),
        Arc::clone(sleep),
    );
    let chosen = connector
        .choose(&server, None)
        .await
        .map_err(|e| plex_text(&e))?;
    let (id, name, uuid, thumb) = match &user {
        Some(u) => (
            u.id.clone(),
            u.title.clone(),
            Some(u.uuid.clone()),
            u.thumb.clone(),
        ),
        None => ("plex".to_owned(), "Plex".to_owned(), None, None),
    };
    // The profile's own token is the one the server was asked with; `from_server` keeps the account token for refreshes.
    let session = PlexAccountSession::from_server(
        &server,
        &chosen,
        if user.is_some() {
            &token
        } else {
            &account_token
        },
        &id,
        &name,
        uuid.as_deref(),
        thumb.as_deref(),
    );
    Ok((session, name))
}

// ---- Discovery -----------------------------------------------------------------------------------------------------

struct Udp(std::net::UdpSocket);

impl DatagramSocket for Udp {
    fn send(&self, payload: &[u8], target: u32, port: u16) -> bool {
        self.0
            .send_to(payload, (std::net::Ipv4Addr::from(target), port))
            .is_ok_and(|n| n == payload.len())
    }
    fn receive(&self, seconds: u32) -> Vec<Vec<u8>> {
        let end = std::time::Instant::now() + Duration::from_secs(u64::from(seconds));
        let mut out = Vec::new();
        let mut buf = [0u8; 2048];
        while let Some(left) = end.checked_duration_since(std::time::Instant::now()) {
            if self
                .0
                .set_read_timeout(Some(left.max(Duration::from_millis(1))))
                .is_err()
            {
                break;
            }
            match self.0.recv_from(&mut buf) {
                Ok((n, _)) => out.push(buf[..n].to_vec()),
                Err(_) => break,
            }
        }
        out
    }
}

/// Searches the local network for Jellyfin servers in a few rounds (broadcast on UDP 7359, 255.255.255.255 only: the
/// per-interface broadcast addresses need the interface list, which no crate of ours reads). Every round sends the
/// servers found so far; the worker ends when the receiver is dropped.
pub fn discover() -> std::sync::mpsc::Receiver<Vec<FoundServer>> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut known: Vec<FoundServer> = Vec::new();
        for round in 0..4 {
            if round > 0 {
                std::thread::sleep(Duration::from_secs(u64::from(discovery::PAUSE_SECONDS)));
            }
            let Ok(sock) = std::net::UdpSocket::bind("0.0.0.0:0") else {
                return;
            };
            if sock.set_broadcast(true).is_err() {
                return;
            }
            let found = discovery::search(&Udp(sock), &[]);
            known = discovery::merged(&known, &found);
            if tx.send(discovery::shown(&known, &[])).is_err() {
                return;
            }
        }
    });
    rx
}

// ---- The system ----------------------------------------------------------------------------------------------------

/// Opens `url` in the browser. Only web addresses go out.
pub fn open_url(url: &str) -> bool {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return false;
    }
    // Live runs in a private compositor never start a browser (`SWIFTLY_NO_BROWSER=1`).
    if std::env::var_os("SWIFTLY_NO_BROWSER").is_some() {
        return true;
    }
    let mut cmd = if cfg!(target_os = "macos") {
        let mut c = std::process::Command::new("open");
        c.arg(url);
        c
    } else if cfg!(windows) {
        let mut c = std::process::Command::new("rundll32");
        c.args(["url.dll,FileProtocolHandler", url]);
        c
    } else {
        let mut c = std::process::Command::new("xdg-open");
        c.arg(url);
        c
    };
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .is_ok()
}

/// The text on the system clipboard (`pbpaste`, PowerShell `Get-Clipboard`, `wl-paste` or `xclip`).
pub fn paste_text() -> Option<String> {
    let tools: &[(&str, &[&str])] = if cfg!(target_os = "macos") {
        &[("pbpaste", &[])]
    } else if cfg!(windows) {
        &[(
            "powershell",
            &["-NoProfile", "-Command", "Get-Clipboard -Raw"],
        )]
    } else {
        &[
            ("wl-paste", &["-n"]),
            ("xclip", &["-selection", "clipboard", "-o"]),
        ]
    };
    for (tool, args) in tools {
        let Ok(out) = std::process::Command::new(tool)
            .args(*args)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
        else {
            continue;
        };
        if out.status.success() {
            return String::from_utf8(out.stdout)
                .ok()
                .map(|s| s.trim_end_matches(['\r', '\n']).to_owned())
                .filter(|s| !s.is_empty());
        }
    }
    None
}

/// Puts `text` on the system clipboard (`pbcopy`, `clip`, `wl-copy` or `xclip`).
pub fn copy_text(text: &str) -> bool {
    use std::io::Write;
    let tools: &[(&str, &[&str])] = if cfg!(target_os = "macos") {
        &[("pbcopy", &[])]
    } else if cfg!(windows) {
        &[("clip", &[])]
    } else {
        &[("wl-copy", &[]), ("xclip", &["-selection", "clipboard"])]
    };
    for (tool, args) in tools {
        let Ok(mut child) = std::process::Command::new(tool)
            .args(*args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
        else {
            continue;
        };
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(text.as_bytes());
        }
        if child.wait().is_ok_and(|s| s.success()) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_net::{Method, MockTransport, TransportReason};

    fn device() -> (String, String, String) {
        ("dev".into(), "Test".into(), "1".into())
    }

    fn instant() -> Sleep {
        Arc::new(|_| Box::pin(async {}))
    }

    #[test]
    fn emby_address_says_name_and_version() {
        let net = Arc::new(MockTransport::new().route("System/Info/Public", 200, r#"{"ServerName":"Emby Zuhause","Version":"4.8.8.0","Id":"e1","ProductName":"Emby Server"}"#));
        let found = futures_executor::block_on(emby_connect(net, &device(), "emby.beispiel.de"))
            .expect("found");
        assert_eq!(
            (found.name.as_str(), found.version.as_str()),
            ("Emby Zuhause", "4.8.8.0")
        );
        assert!(
            found.address.ends_with("emby.beispiel.de")
                || found.address.contains("emby.beispiel.de")
        );
    }

    #[test]
    fn emby_address_that_is_jellyfin_and_silence_get_their_lines() {
        let net = Arc::new(MockTransport::new().route("System/Info/Public", 200, r#"{"ServerName":"Kino","Version":"10.10.3","Id":"j1","ProductName":"Jellyfin Server"}"#));
        let e = futures_executor::block_on(emby_connect(net, &device(), "kino.test"))
            .expect_err("jellyfin");
        assert!(e.contains("Jellyfin"), "{e}");
        let net = Arc::new(MockTransport::new().route_error(
            "System/Info/Public",
            ErrorKind::Transport(TransportReason::NoHttpResponse),
        ));
        assert_eq!(
            futures_executor::block_on(emby_connect(net, &device(), "http://weg.test")),
            Err(EMBY_DOWN.to_owned())
        );
    }

    #[test]
    fn emby_user_list_comes_from_public_users() {
        let net = Arc::new(MockTransport::new().route(
            "Users/Public",
            200,
            r#"[{"Id":"1","Name":"Paul"},{"Id":"2","Name":"Mama"}]"#,
        ));
        assert_eq!(
            futures_executor::block_on(emby_users(net, &device(), "http://e.test")),
            vec!["Paul".to_owned(), "Mama".to_owned()]
        );
    }

    fn plex_net() -> Arc<MockTransport> {
        Arc::new(
            MockTransport::new()
                .route_method(Method::Post, "api/v2/pins", 200, r#"{"id":7,"code":"K7QMXXXX"}"#)
                .route_method(Method::Get, "api/v2/pins/7", 200, r#"{"id":7,"code":"K7QMXXXX","authToken":"acct-token"}"#)
                .route_method(Method::Get, "api/v2/home/users", 200, r#"{"users":[{"id":"1","uuid":"u1","title":"Paul","protected":false},{"id":"2","uuid":"u2","title":"Mama","protected":true}]}"#)
                .route_method(Method::Post, "u2/switch", 200, r#"{"authToken":"mama-token"}"#)
                .route_method(Method::Get, "api/v2/resources", 200, r#"[{"clientIdentifier":"m1","name":"Wohnzimmer","provides":"server","owned":true,"presence":true,"connections":[]},{"clientIdentifier":"m2","name":"Kino","provides":"server","owned":false,"sourceTitle":"Oma","presence":true,"connections":[]},{"clientIdentifier":"p1","name":"Telefon","provides":"player"}]"#),
        )
    }

    #[test]
    fn plex_pin_flow_reports_the_real_expiry_of_the_code() {
        let net = Arc::new(
            MockTransport::new()
                .route_method(Method::Post, "api/v2/pins", 200, r#"{"id":7,"code":"K7QMXXXX","expiresIn":900}"#)
                .route_method(Method::Get, "api/v2/pins/7", 200, r#"{"id":7,"code":"K7QMXXXX","authToken":"acct-token"}"#)
                .route_method(Method::Get, "api/v2/home/users", 200, r#"{"users":[{"id":"1","uuid":"u1","title":"Paul","thumb":"https://plex.tv/u/1.png"}]}"#),
        );
        let identity = PlexIdentity::new("client-1", "1", "Test", "pc", "Test");
        let svc = PlexAccountService::with_bases(
            identity,
            net,
            "https://plex.test",
            "https://clients.test",
            "https://app.test",
        );
        let (tx, rx) = std::sync::mpsc::channel();
        futures_executor::block_on(plex_sign_in(
            &svc,
            &instant(),
            Duration::from_millis(1),
            Duration::from_secs(5),
            &SharedPlex::default(),
            &tx,
        ));
        let events: Vec<PlexEvent> = rx.try_iter().collect();
        assert!(matches!(&events[0], PlexEvent::Open(_)), "{events:?}");
        assert_eq!(events[1], PlexEvent::Expiry(900), "{events:?}");
        assert!(
            events.contains(&PlexEvent::Pictures(vec![Some(
                "https://plex.tv/u/1.png".into()
            )])),
            "the profile pictures come with the profiles: {events:?}"
        );
    }

    #[test]
    fn plex_pin_flow_opens_the_browser_then_lists_profiles_and_servers() {
        let net = plex_net();
        let identity = PlexIdentity::new("client-1", "1", "Test", "pc", "Test");
        let svc = PlexAccountService::with_bases(
            identity,
            Arc::clone(&net),
            "https://plex.test",
            "https://clients.test",
            "https://app.test",
        );
        let (tx, rx) = std::sync::mpsc::channel();
        let state = SharedPlex::default();
        futures_executor::block_on(plex_sign_in(
            &svc,
            &instant(),
            Duration::from_millis(1),
            Duration::from_secs(5),
            &state,
            &tx,
        ));
        let events: Vec<PlexEvent> = rx.try_iter().collect();
        assert!(
            matches!(&events[0], PlexEvent::Open(u) if u.starts_with("https://app.test/auth#") && u.contains("code=K7QMXXXX")),
            "{events:?}"
        );
        assert_eq!(events[1], PlexEvent::Pictures(vec![None, None]));
        assert_eq!(
            events[2],
            PlexEvent::Profiles(vec![("Paul".into(), false), ("Mama".into(), true)])
        );
        let servers =
            futures_executor::block_on(plex_pick(&svc, &state, 1, "1234")).expect("servers");
        assert_eq!(
            servers,
            vec![
                (
                    "Wohnzimmer".to_owned(),
                    "Dein Server · über das Internet".to_owned()
                ),
                (
                    "Kino".to_owned(),
                    "Von Oma freigegeben · über das Internet".to_owned()
                )
            ]
        );
        // The switch carried the PIN.
        assert!(
            net.requests().iter().any(
                |r| r.url.as_str().contains("u2/switch") && r.url.as_str().contains("pin=1234")
            )
        );
    }

    #[test]
    fn plex_wrong_pin_and_expired_code_have_their_sentences() {
        let net = Arc::new(
            MockTransport::new()
                .route_method(Method::Post, "u2/switch", 401, "{}")
                .route_method(Method::Post, "api/v2/pins", 200, r#"{"id":7,"code":"A"}"#)
                .route_method(Method::Get, "api/v2/pins/7", 404, "{}"),
        );
        let identity = PlexIdentity::new("client-1", "1", "Test", "pc", "Test");
        let svc = PlexAccountService::with_bases(
            identity,
            net,
            "https://plex.test",
            "https://clients.test",
            "https://app.test",
        );
        let state = SharedPlex::default();
        state.lock().expect("lock").users = vec![PlexHomeUser {
            id: "2".into(),
            uuid: "u2".into(),
            title: "Mama".into(),
            thumb: None,
            is_protected: true,
            is_admin: false,
            is_restricted: false,
            is_guest: false,
        }];
        let wrong =
            futures_executor::block_on(plex_pick(&svc, &state, 0, "0000")).expect_err("wrong pin");
        assert_eq!(wrong, PlexError::ProfilePinWrong.text_key().expect("text"));
        let (tx, rx) = std::sync::mpsc::channel();
        futures_executor::block_on(plex_sign_in(
            &svc,
            &instant(),
            Duration::from_millis(1),
            Duration::from_secs(5),
            &state,
            &tx,
        ));
        let last = rx.try_iter().last();
        assert!(matches!(last, Some(PlexEvent::Expired)));
    }

    #[test]
    fn only_web_addresses_open() {
        assert!(!open_url("file:///etc/passwd"));
        assert!(!open_url("javascript:alert(1)"));
    }
}

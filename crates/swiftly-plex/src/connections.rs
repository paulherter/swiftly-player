//! **Which address of a Plex server to use** (`PlexConnections.swift`).
//!
//! plex.tv lists every way to reach a server: its LAN address, the public one, the
//! `plex.direct` host names with a certificate, and the relay (slow, throttled). The right one
//! depends on where the device is right now, so it is decided by asking, not by reading a
//! flag: order the list, then try the entries and take the best that answers.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use futures_util::future::BoxFuture;
use futures_util::stream::{FuturesUnordered, StreamExt};
use serde::{Deserialize, Serialize};
use swiftly_net::{HttpRequest, HttpTransport, Method};
use url::Url;

use crate::identity::{PlexError, PlexIdentity};
use crate::server::{PlexConnectionInfo, PlexServerResource};
use crate::wire::PlexListing;

/// A timer the caller provides, because this crate has no runtime of its own: a future that
/// is ready after the given time.
pub type Sleep = Arc<dyn Fn(Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;

/// The address of a server that answered, and who answered under it (PlexConnections.swift:6).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlexChosenConnection {
    /// The machine that answered.
    #[serde(rename = "machineIdentifier")]
    pub machine_identifier: String,
    /// The address.
    pub uri: String,
    /// On the home network?
    #[serde(rename = "isLocal")]
    pub is_local: bool,
    /// A relay?
    #[serde(rename = "isRelay")]
    pub is_relay: bool,
}

/// Asks one address "are you the server I want?". Replaceable so a test needs no network.
pub type Probe = Arc<dyn Fn(PlexConnectionInfo) -> BoxFuture<'static, bool> + Send + Sync>;

/// Chooses among the addresses of a server (PlexConnections.swift:26).
#[derive(Clone)]
pub struct PlexConnector {
    probe: Probe,
    /// How long a better-ranked address may still be pending once a worse one has answered.
    /// Short: a few hundred milliseconds cost less than a dead LAN address.
    grace: Duration,
    sleep: Sleep,
}

impl PlexConnector {
    /// The default grace (one second).
    pub const GRACE: Duration = Duration::from_secs(1);

    /// A connector with its own probe.
    pub fn new(grace: Duration, sleep: Sleep, probe: Probe) -> Self {
        Self {
            probe,
            grace,
            sleep,
        }
    }

    /// The real probe: `GET /identity` with a short timeout, and the machine identifier in the
    /// answer must be the one we are looking for. **Without that check** a different server
    /// answering at a recycled home address would be taken for ours (the account often holds
    /// two: an owned one and a shared one).
    pub fn with_transport<T: HttpTransport + 'static>(
        transport: Arc<T>,
        identity: PlexIdentity,
        token: String,
        machine_identifier: String,
        timeout: Duration,
        sleep: Sleep,
    ) -> Self {
        let probe: Probe = Arc::new(move |connection: PlexConnectionInfo| {
            let transport = Arc::clone(&transport);
            let identity = identity.clone();
            let token = token.clone();
            let machine = machine_identifier.clone();
            Box::pin(async move {
                let Ok(base) = Url::parse(&connection.uri) else {
                    return false;
                };
                let wait = if connection.is_relay {
                    timeout.max(Duration::from_secs(6))
                } else {
                    timeout
                };
                Self::identity_matches(transport.as_ref(), &base, &identity, &token, &machine, wait)
                    .await
            })
        });
        Self::new(Self::GRACE, sleep, probe)
    }

    // MARK: Order

    /// Best first: the remembered address, then local, then remote, then relay. Within a group
    /// the plain `http` address comes before the `https` one for a LAN address (no certificate
    /// to go wrong) unless the server insists on https; IPv6 last (PlexConnections.swift:60).
    pub fn ranked(
        connections: &[PlexConnectionInfo],
        https_required: bool,
        remembered: Option<&str>,
    ) -> Vec<PlexConnectionInfo> {
        let remembered_url = remembered.map(Url::parse);
        let score = |c: &PlexConnectionInfo| -> i64 {
            let mut points = 0;
            if c.is_relay {
                points += 1000;
            } else if !c.is_local {
                points += 100;
            }
            if c.is_ipv6 {
                points += 10;
            }
            if https_required {
                if !c.is_https {
                    points += 50; // would be refused anyway
                }
            } else if c.is_local {
                if c.is_https {
                    points += 1; // no certificate to go wrong on the LAN
                }
            } else if !c.is_https {
                points += 1; // across the internet https first
            }
            if let (Some(Ok(want)), Ok(have)) = (&remembered_url, Url::parse(&c.uri))
                && *want == have
            {
                points -= 10_000;
            }
            points
        };
        // `sorted` is not stable in Swift; the original index keeps equal scores in plex.tv's
        // order.
        let mut indexed: Vec<(i64, usize, &PlexConnectionInfo)> = connections
            .iter()
            .enumerate()
            .map(|(i, c)| (score(c), i, c))
            .collect();
        indexed.sort_by_key(|(s, i, _)| (*s, *i));
        indexed.into_iter().map(|(_, _, c)| c.clone()).collect()
    }

    // MARK: Choice

    /// Tries the remembered address alone first (one quick round trip on the usual path);
    /// otherwise tries all in parallel and takes **the best-ranked one that answers**, as soon
    /// as every better-ranked one has failed. Nothing answering is
    /// [`PlexError::ServerUnreachable`] (PlexConnections.swift:83).
    pub async fn choose(
        &self,
        server: &PlexServerResource,
        remembered: Option<&PlexChosenConnection>,
    ) -> Result<PlexChosenConnection, PlexError> {
        let ordered = Self::ranked(
            &server.connections,
            server.https_required,
            remembered.map(|r| r.uri.as_str()),
        );
        if ordered.is_empty() {
            return Err(PlexError::ServerUnreachable);
        }
        let chosen = |c: &PlexConnectionInfo, uri: &str| PlexChosenConnection {
            machine_identifier: server.machine_identifier.clone(),
            uri: uri.to_string(),
            is_local: c.is_local,
            is_relay: c.is_relay,
        };

        if let Some(rem) = remembered.filter(|r| r.machine_identifier == server.machine_identifier)
        {
            let want = Url::parse(&rem.uri).ok();
            let known = ordered
                .iter()
                .find(|c| Url::parse(&c.uri).ok() == want && want.is_some());
            if let Some(known) = known
                && (self.probe)(known.clone()).await
            {
                return Ok(chosen(known, &rem.uri));
            }
        }

        // The best answering address wins. A better-ranked one that is still pending when a
        // worse one has answered gets `grace` more, then the answered one is taken.
        let mut group: FuturesUnordered<BoxFuture<'static, (i64, bool)>> = FuturesUnordered::new();
        for (index, connection) in ordered.iter().enumerate() {
            let probe = Arc::clone(&self.probe);
            let connection = connection.clone();
            group.push(Box::pin(
                async move { (index as i64, probe(connection).await) },
            ));
        }
        let mut answered: HashMap<i64, bool> = HashMap::new();
        let mut best: Option<i64> = None;
        let mut timer_started = false;
        let mut winner = None;
        while let Some((index, ok)) = group.next().await {
            if index < 0 {
                // The grace ran out.
                winner = best;
                break;
            }
            answered.insert(index, ok);
            if ok && best.is_none_or(|b| index < b) {
                best = Some(index);
            }
            if let Some(candidate) = best {
                if (0..candidate).all(|i| answered.get(&i) == Some(&false)) {
                    winner = Some(candidate);
                    break;
                }
                if !timer_started {
                    timer_started = true;
                    let sleep = Arc::clone(&self.sleep);
                    let grace = self.grace;
                    group.push(Box::pin(async move {
                        sleep(grace).await;
                        (-1, false)
                    }));
                }
            }
            winner = best;
        }
        let winner = winner.ok_or(PlexError::ServerUnreachable)?;
        let c = ordered
            .get(usize::try_from(winner).map_err(|_| PlexError::ServerUnreachable)?)
            .ok_or(PlexError::ServerUnreachable)?;
        Url::parse(&c.uri).map_err(|_| PlexError::ServerUnreachable)?;
        Ok(chosen(c, &c.uri))
    }

    // MARK: Probe

    /// `GET {base}/identity`; true if it answers `200` with the machine we look for
    /// (PlexConnections.swift:154).
    pub async fn identity_matches<T: HttpTransport>(
        transport: &T,
        base: &Url,
        identity: &PlexIdentity,
        token: &str,
        machine_identifier: &str,
        timeout: Duration,
    ) -> bool {
        // Swift appends "identity" to the address: only one trailing slash goes, a second one stays (`//identity`).
        let text = format!(
            "{}/identity",
            base.as_str().strip_suffix('/').unwrap_or(base.as_str())
        );
        let Ok(url) = Url::parse(&text) else {
            return false;
        };
        let mut request = HttpRequest::new(Method::Get, url);
        request.timeout = Some(timeout);
        for (name, value) in identity.headers(Some(token), None) {
            request.set_header(&name, &value);
        }
        let Ok(response) = transport.send(request).await else {
            return false;
        };
        if response.status != 200 {
            return false;
        }
        PlexListing::from_body(&response.body)
            .map(|l| l.machine_identifier.as_deref() == Some(machine_identifier))
            .unwrap_or(false)
    }
}

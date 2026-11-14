//! The desktop WebSocket of the control channel (`/socket`): one blocking link over tungstenite (MIT), polled in
//! short slices by the thread that owns it, so the same thread can also send and stop. The rules of the channel
//! (keep-alive, silence, reconnect) live in `swiftly_sync::RemoteControl` and in [`crate::together`]; this file only
//! moves text. On mobile shells (no tungstenite there) `connect` always fails and the channel stays quiet.

use swiftly_sync::LinkError;

/// How long one read waits before the owner may do something else.
#[cfg(not(any(target_os = "android", target_os = "ios", target_os = "tvos")))]
const SLICE_MS: u64 = 100;

#[cfg(not(any(target_os = "android", target_os = "ios", target_os = "tvos")))]
mod real {
    use super::{LinkError, SLICE_MS};
    use std::io::ErrorKind as IoKind;
    use std::net::TcpStream;
    use std::sync::Arc;
    use std::time::Duration;
    use swiftly_net::TlsOptions;
    use tungstenite::client::IntoClientRequest;
    use tungstenite::stream::MaybeTlsStream;
    use tungstenite::{Connector, Error, Message, WebSocket};

    use rustls::client::WebPkiServerVerifier;
    use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use rustls::crypto::{WebPkiSupportedAlgorithms, aws_lc_rs};
    use rustls::{DigitallySignedStruct, RootCertStore, SignatureScheme};
    use rustls_pki_types::pem::PemObject;
    use rustls_pki_types::{CertificateDer, ServerName, UnixTime};

    /// The checks the app's options switch off: every host (the legacy switch) or the hosts the user accepted; all
    /// other hosts go through the normal verifier.
    #[derive(Debug)]
    struct Lenient {
        inner: Arc<WebPkiServerVerifier>,
        algs: WebPkiSupportedAlgorithms,
        all: bool,
        hosts: Vec<String>,
    }

    impl Lenient {
        fn skips(&self, name: &ServerName<'_>) -> bool {
            self.all
                || matches!(name, ServerName::DnsName(d)
                    if self.hosts.iter().any(|h| h.eq_ignore_ascii_case(d.as_ref())))
                || matches!(name, ServerName::IpAddress(ip)
                    if self.hosts.iter().any(|h| *h == std::net::IpAddr::from(*ip).to_string()))
        }
    }

    impl ServerCertVerifier for Lenient {
        fn verify_server_cert(
            &self,
            end_entity: &CertificateDer<'_>,
            intermediates: &[CertificateDer<'_>],
            name: &ServerName<'_>,
            ocsp: &[u8],
            now: UnixTime,
        ) -> Result<ServerCertVerified, rustls::Error> {
            if self.skips(name) {
                return Ok(ServerCertVerified::assertion());
            }
            self.inner
                .verify_server_cert(end_entity, intermediates, name, ocsp, now)
        }

        fn verify_tls12_signature(
            &self,
            message: &[u8],
            cert: &CertificateDer<'_>,
            dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(message, cert, dss, &self.algs).or_else(|e| {
                if self.all || !self.hosts.is_empty() {
                    Ok(HandshakeSignatureValid::assertion())
                } else {
                    Err(e)
                }
            })
        }

        fn verify_tls13_signature(
            &self,
            message: &[u8],
            cert: &CertificateDer<'_>,
            dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algs).or_else(|e| {
                if self.all || !self.hosts.is_empty() {
                    Ok(HandshakeSignatureValid::assertion())
                } else {
                    Err(e)
                }
            })
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            self.algs.supported_schemes()
        }
    }

    /// The TLS setup of the socket: the platform roots plus the authorities the user added, and the leniency the user
    /// switched on (`tls.ca`, `tls.acceptSelfSigned`, the accepted hosts) - the same cases `ReqwestTransport` honours.
    fn config(tls: &TlsOptions) -> Result<rustls::ClientConfig, LinkError> {
        let other = |e: &dyn std::fmt::Display| LinkError::Other(e.to_string());
        let mut roots = RootCertStore::empty();
        for cert in rustls_native_certs::load_native_certs().certs {
            let _ = roots.add(cert);
        }
        for bytes in &tls.extra_roots {
            let pem: Vec<CertificateDer<'static>> =
                CertificateDer::pem_slice_iter(bytes).flatten().collect();
            if pem.is_empty() {
                let _ = roots.add(CertificateDer::from(bytes.clone()));
            }
            for cert in pem {
                let _ = roots.add(cert);
            }
        }
        let provider = Arc::new(aws_lc_rs::default_provider());
        let algs = provider.signature_verification_algorithms;
        let builder = rustls::ClientConfig::builder_with_provider(Arc::clone(&provider))
            .with_safe_default_protocol_versions()
            .map_err(|e| other(&e))?;
        if tls.accept_invalid_certs || !tls.accept_invalid_hosts.is_empty() {
            let inner = WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider)
                .build()
                .map_err(|e| other(&e))?;
            let verifier = Lenient {
                inner,
                algs,
                all: tls.accept_invalid_certs,
                hosts: tls
                    .accept_invalid_hosts
                    .iter()
                    .map(|h| h.to_lowercase())
                    .collect(),
            };
            return Ok(builder
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(verifier))
                .with_no_client_auth());
        }
        Ok(builder.with_root_certificates(roots).with_no_client_auth())
    }

    /// An open socket.
    pub struct Link {
        socket: WebSocket<MaybeTlsStream<TcpStream>>,
    }

    fn failure(e: &Error) -> LinkError {
        match e {
            Error::Http(r) => LinkError::SetupFailed {
                code: i32::from(r.status().as_u16()),
            },
            other => LinkError::Other(other.to_string()),
        }
    }

    impl Link {
        /// Opens `url` (`ws://` or `wss://`); `wss` honours the app's certificate options.
        ///
        /// # Errors
        /// Why the upgrade did not work.
        pub fn connect(url: &str, tls: &TlsOptions) -> Result<Link, LinkError> {
            let request = url.into_client_request().map_err(|e| failure(&e))?;
            let secure = request.uri().scheme_str() == Some("wss");
            let host = request
                .uri()
                .host()
                .ok_or_else(|| LinkError::Other("no host".into()))?
                .to_owned();
            let port = request
                .uri()
                .port_u16()
                .unwrap_or(if secure { 443 } else { 80 });
            let tcp = TcpStream::connect((host.as_str(), port))
                .map_err(|e| LinkError::Other(e.to_string()))?;
            let connector = if secure {
                Some(Connector::Rustls(Arc::new(config(tls)?)))
            } else {
                Some(Connector::Plain)
            };
            let (socket, _) = tungstenite::client_tls_with_config(request, tcp, None, connector)
                .map_err(|e| match e {
                    tungstenite::HandshakeError::Failure(e) => failure(&e),
                    tungstenite::HandshakeError::Interrupted(_) => {
                        LinkError::Other("handshake interrupted".into())
                    }
                })?;
            let tcp = match socket.get_ref() {
                MaybeTlsStream::Plain(s) => Some(s),
                MaybeTlsStream::Rustls(s) => Some(s.get_ref()),
                _ => None,
            };
            if let Some(tcp) = tcp {
                let _ = tcp.set_read_timeout(Some(Duration::from_millis(SLICE_MS)));
            }
            Ok(Link { socket })
        }

        /// The next text message, `Ok(None)` after one slice without news or for a frame to skip.
        ///
        /// # Errors
        /// The link ended.
        pub fn read(&mut self) -> Result<Option<String>, LinkError> {
            match self.socket.read() {
                Ok(Message::Text(t)) => Ok(Some(t.as_str().to_owned())),
                Ok(Message::Close(_)) => Err(LinkError::Other("closed".into())),
                Ok(_) => Ok(None),
                Err(Error::Io(e)) if matches!(e.kind(), IoKind::WouldBlock | IoKind::TimedOut) => {
                    Ok(None)
                }
                Err(e) => Err(failure(&e)),
            }
        }

        /// Sends a text message.
        ///
        /// # Errors
        /// The link ended.
        pub fn send(&mut self, text: &str) -> Result<(), LinkError> {
            self.socket
                .send(Message::text(text))
                .map_err(|e| failure(&e))
        }

        /// Closes politely.
        pub fn close(&mut self) {
            let _ = self.socket.close(None);
            let _ = self.socket.flush();
        }
    }
}

#[cfg(any(target_os = "android", target_os = "ios", target_os = "tvos"))]
mod real {
    use super::LinkError;

    /// No socket on this shell.
    pub struct Link;

    impl Link {
        /// Always fails: the shell has no socket here.
        ///
        /// # Errors
        /// Always.
        pub fn connect(_url: &str, _tls: &swiftly_net::TlsOptions) -> Result<Link, LinkError> {
            Err(LinkError::NotSupported)
        }
        /// Never reached.
        ///
        /// # Errors
        /// Always.
        pub fn read(&mut self) -> Result<Option<String>, LinkError> {
            Err(LinkError::NotSupported)
        }
        /// Never reached.
        ///
        /// # Errors
        /// Always.
        pub fn send(&mut self, _text: &str) -> Result<(), LinkError> {
            Err(LinkError::NotSupported)
        }
        /// Nothing to close.
        pub fn close(&mut self) {}
    }
}

pub use real::Link;

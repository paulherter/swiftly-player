//! The control channel over `wss://` against a local TLS server (tungstenite behind rustls, test-only certificates
//! generated at run time with rcgen): a self-signed certificate is refused until the user accepts that host (or every
//! host), and a certificate from an authority the user added is trusted; accepting one host never opens another. The
//! plain `ws://` path is covered by `together_live.rs`.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::net::{IpAddr, Ipv4Addr, TcpListener};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use rcgen::{
    BasicConstraints, CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose, SanType,
};
use rustls::crypto::aws_lc_rs;
use rustls::{ServerConfig, ServerConnection, StreamOwned};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use swiftly_desktop::together_socket::Link;
use swiftly_net::TlsOptions;

/// One server identity: the certificate and its private key, both DER.
struct Identity {
    cert: Vec<u8>,
    key: Vec<u8>,
}

/// The test certificates, made once per test run: a certificate authority, a leaf for `localhost` and 127.0.0.1 signed
/// by it, and a self-signed certificate for the same names.
struct Pki {
    /// The authority as PEM, as the user adds it in the settings.
    ca_pem: Vec<u8>,
    leaf: Identity,
    self_signed: Identity,
}

fn server_params() -> CertificateParams {
    let mut params = CertificateParams::new(vec!["localhost".to_string()]).unwrap();
    params
        .subject_alt_names
        .push(SanType::IpAddress(IpAddr::V4(Ipv4Addr::LOCALHOST)));
    params
        .distinguished_name
        .push(DnType::CommonName, "localhost");
    params.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyEncipherment,
    ];
    params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    params
}

fn pki() -> &'static Pki {
    static PKI: OnceLock<Pki> = OnceLock::new();
    PKI.get_or_init(|| {
        let mut ca_params = CertificateParams::new(Vec::<String>::new()).unwrap();
        ca_params
            .distinguished_name
            .push(DnType::CommonName, "Swiftly Test CA");
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        ca_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
        let ca_key = KeyPair::generate().unwrap();
        let ca_cert = ca_params.self_signed(&ca_key).unwrap();
        let issuer = Issuer::new(ca_params, ca_key);

        let leaf_key = KeyPair::generate().unwrap();
        let leaf_cert = server_params().signed_by(&leaf_key, &issuer).unwrap();

        let self_key = KeyPair::generate().unwrap();
        let self_cert = server_params().self_signed(&self_key).unwrap();

        Pki {
            ca_pem: ca_cert.pem().into_bytes(),
            leaf: Identity {
                cert: leaf_cert.der().to_vec(),
                key: leaf_key.serialize_der(),
            },
            self_signed: Identity {
                cert: self_cert.der().to_vec(),
                key: self_key.serialize_der(),
            },
        }
    })
}

/// A TLS WebSocket server on a free local port that greets every client with "hello" and echoes what it reads.
fn serve(identity: &Identity) -> u16 {
    let certs = vec![CertificateDer::from(identity.cert.clone())];
    let key = PrivateKeyDer::from(PrivatePkcs8KeyDer::from(identity.key.clone()));
    let config = Arc::new(
        ServerConfig::builder_with_provider(Arc::new(aws_lc_rs::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(certs, key)
            .unwrap(),
    );
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for tcp in listener.incoming().flatten() {
            let config = Arc::clone(&config);
            std::thread::spawn(move || {
                let Ok(conn) = ServerConnection::new(config) else {
                    return;
                };
                let Ok(mut ws) = tungstenite::accept(StreamOwned::new(conn, tcp)) else {
                    return;
                };
                let _ = ws.send(tungstenite::Message::text("hello"));
                while let Ok(m) = ws.read() {
                    if let tungstenite::Message::Text(t) = m {
                        let _ = ws.send(tungstenite::Message::text(format!("echo {t}")));
                    }
                }
            });
        }
    });
    port
}

/// Opens the link and reads the greeting and one echo.
fn talk(host: &str, port: u16, tls: &TlsOptions) -> Result<(), String> {
    let mut link =
        Link::connect(&format!("wss://{host}:{port}/socket"), tls).map_err(|e| format!("{e:?}"))?;
    let mut got = Vec::new();
    let began = Instant::now();
    let mut sent = false;
    while got.len() < 2 {
        if began.elapsed() > Duration::from_secs(10) {
            return Err(format!("no answer, got {got:?}"));
        }
        if let Some(t) = link.read().map_err(|e| format!("{e:?}"))? {
            got.push(t);
        }
        if !sent && !got.is_empty() {
            link.send("ping").map_err(|e| format!("{e:?}"))?;
            sent = true;
        }
    }
    link.close();
    assert_eq!(got, ["hello", "echo ping"]);
    Ok(())
}

#[test]
fn a_self_signed_server_is_refused_by_default() {
    let port = serve(&pki().self_signed);
    let err = talk("127.0.0.1", port, &TlsOptions::default()).expect_err("must not connect");
    assert!(
        err.to_lowercase().contains("unknownissuer") || err.to_lowercase().contains("certificate"),
        "{err}"
    );
}

#[test]
fn an_accepted_host_connects_over_wss_and_no_other_does() {
    let port = serve(&pki().self_signed);
    let accepted = TlsOptions {
        accept_invalid_hosts: vec!["127.0.0.1".into()],
        ..TlsOptions::default()
    };
    talk("127.0.0.1", port, &accepted).expect("the accepted host connects");
    // The same server under another name stays refused: the exception is per host.
    let other = TlsOptions {
        accept_invalid_hosts: vec!["example.org".into()],
        ..TlsOptions::default()
    };
    assert!(talk("127.0.0.1", port, &other).is_err());
    assert!(talk("localhost", port, &accepted).is_err());
}

#[test]
fn the_legacy_switch_accepts_a_self_signed_server() {
    let port = serve(&pki().self_signed);
    let all = TlsOptions {
        accept_invalid_certs: true,
        ..TlsOptions::default()
    };
    talk("127.0.0.1", port, &all).expect("accepts every host");
}

#[test]
fn a_certificate_from_a_user_added_authority_is_trusted() {
    let port = serve(&pki().leaf);
    // Without the authority the chain is unknown ...
    assert!(talk("127.0.0.1", port, &TlsOptions::default()).is_err());
    // ... with it (PEM) the server is trusted without any leniency, by IP and by name.
    let with_ca = TlsOptions {
        extra_roots: vec![pki().ca_pem.clone()],
        ..TlsOptions::default()
    };
    talk("127.0.0.1", port, &with_ca).expect("trusted by the added authority");
    talk("localhost", port, &with_ca).expect("trusted by name too");
}

//! Error cases of the Swift client (`JellyfinError`, JellyfinClient.swift:24-76) without user text.
//!
//! Wording lives in another crate. `ErrorKind` only says what happened; the
//! four [`ErrorTopic`]s sort it for the callers that react differently to a
//! network, an auth, a server or a decode problem.

/// Codes of `NSURLErrorDomain`. The Swift code keeps them in `JellyfinError.network(code:)`
/// and the UI wording and the address fallback rule key on them, so the Rust
/// error carries the same numbers.
pub mod url_error {
    /// `.cancelled`
    pub const CANCELLED: i32 = -999;
    /// `.timedOut`
    pub const TIMED_OUT: i32 = -1001;
    /// `.cannotFindHost`
    pub const CANNOT_FIND_HOST: i32 = -1003;
    /// `.cannotConnectToHost`
    pub const CANNOT_CONNECT_TO_HOST: i32 = -1004;
    /// `.networkConnectionLost`
    pub const NETWORK_CONNECTION_LOST: i32 = -1005;
    /// `.dnsLookupFailed`
    pub const DNS_LOOKUP_FAILED: i32 = -1006;
    /// `.httpTooManyRedirects`
    pub const TOO_MANY_REDIRECTS: i32 = -1007;
    /// `.notConnectedToInternet`
    pub const NOT_CONNECTED_TO_INTERNET: i32 = -1009;
    /// `.cannotParseResponse`
    pub const CANNOT_PARSE_RESPONSE: i32 = -1017;
    /// `.secureConnectionFailed`
    pub const SECURE_CONNECTION_FAILED: i32 = -1200;
    /// `.serverCertificateHasBadDate`
    pub const CERTIFICATE_BAD_DATE: i32 = -1201;
    /// `.serverCertificateUntrusted`
    pub const CERTIFICATE_UNTRUSTED: i32 = -1202;
    /// `.serverCertificateHasUnknownRoot`
    pub const CERTIFICATE_UNKNOWN_ROOT: i32 = -1203;
    /// `.serverCertificateNotYetValid`
    pub const CERTIFICATE_NOT_YET_VALID: i32 = -1204;
    /// `.clientCertificateRejected`
    pub const CLIENT_CERTIFICATE_REJECTED: i32 = -1205;
    /// `.clientCertificateRequired`
    pub const CLIENT_CERTIFICATE_REQUIRED: i32 = -1206;
}

/// What made the server's certificate fail (JellyfinClient.swift:11-22).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CertificateReason {
    /// Self-signed, or the issuer is unknown.
    NotTrusted,
    /// The validity period is over.
    Expired,
    /// The validity period has not started yet.
    AppliesNotYet,
    /// Valid, but issued for a different name.
    OtherAddress,
    /// TLS failed and the reason is not available.
    Otherwise,
}

/// Why a request failed without a status, where the Swift code had its own sentence
/// (`JellyfinError.transport(String)`). The sentence is the other crate's job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportReason {
    /// "Keine HTTP-Antwort." (JellyfinClient.swift:239, 279)
    NoHttpResponse,
    /// A gateway answered with a login page instead of JSON
    /// (`OwnHeaders.loginPageText`, OwnHeaders.swift).
    LoginPage,
    /// The server turned Quick Connect off, 503 (Login.swift:84).
    QuickConnectDisabled,
    /// The server refused the metadata refresh (JellyfinClient.swift:964).
    RefreshRejected,
    /// The other device did not react (JellyfinClient.swift:1166).
    RemoteDeviceSilent,
    /// Anything else; a developer-readable description.
    Other(String),
}

/// The four groups a failure belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorTopic {
    /// The request did not get through (connection, TLS, address).
    Network,
    /// Sign-in or permission.
    Auth,
    /// The server answered, but not with success.
    Server,
    /// The answer could not be read.
    Decode,
}

/// Everything that can go wrong in a client call (Swift `JellyfinError`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorKind {
    /// The server address cannot be turned into a request address.
    InvalidServerUrl,
    /// A call that needs a session was made without one.
    NotAuthenticated,
    /// Name and password are right, the server wants another confirmation
    /// (401 with an `AccessToken` in the body).
    TwoFactor,
    /// A status outside 2xx; `body` is the first bytes of the answer as text.
    Http {
        /// Status code.
        status: u16,
        /// First bytes of the body, if readable UTF-8.
        body: Option<String>,
    },
    /// The answer could not be decoded; the decoder's text, for the log only.
    Decoding(String),
    /// The request did not get through: the `NSURLErrorDomain` code, see [`url_error`].
    Network {
        /// URL error code.
        code: i32,
    },
    /// The server's certificate was the cause.
    Certificate(CertificateReason),
    /// A failure with its own case instead of a code.
    Transport(TransportReason),
    /// The server names no playable version.
    NoPlayableSource,
    /// The server names no version and says why (`ErrorCode` in `PlaybackInfo`).
    PlaybackRejected(String),
    /// The Quick Connect code ran out (`QuickConnectExpired`, Login.swift).
    QuickConnectExpired,
    /// The caller gave up (`CancellationError`).
    Cancelled,
}

impl ErrorKind {
    /// The group this failure belongs to.
    pub fn topic(&self) -> ErrorTopic {
        match self {
            Self::InvalidServerUrl
            | Self::Network { .. }
            | Self::Certificate(_)
            | Self::Cancelled => ErrorTopic::Network,
            Self::Transport(TransportReason::LoginPage) => ErrorTopic::Auth,
            Self::Transport(_) => ErrorTopic::Network,
            Self::NotAuthenticated | Self::TwoFactor => ErrorTopic::Auth,
            Self::Http {
                status: 401 | 403, ..
            } => ErrorTopic::Auth,
            Self::Http { .. }
            | Self::NoPlayableSource
            | Self::PlaybackRejected(_)
            | Self::QuickConnectExpired => ErrorTopic::Server,
            Self::Decoding(_) => ErrorTopic::Decode,
        }
    }

    /// The URL error code if the request did not get through (`urlErrorCode`,
    /// JellyfinClient.swift:70). For a certificate failure there is none.
    pub fn url_error_code(&self) -> Option<i32> {
        match self {
            Self::Network { code } => Some(*code),
            _ => None,
        }
    }

    /// Classifies a failed sign-in (JellyfinClient.swift:1547): 401 **with** a token in
    /// the body means the password was right and a two-factor plugin wants
    /// confirmation. Everything else stays an [`ErrorKind::Http`].
    pub fn login_error(status: u16, body: Option<String>) -> Self {
        if status == 401
            && body
                .as_deref()
                .is_some_and(|b| b.contains("\"AccessToken\""))
        {
            return Self::TwoFactor;
        }
        Self::Http { status, body }
    }

    /// Does a second try on the other scheme (http/https) make sense after this failure?
    /// (`AddressCheck.fallbackPaysOff`, AddressCheck.swift)
    ///
    /// No when the name does not resolve, the time ran out, the user cancelled or there is
    /// no network at all; yes for everything else (refused connection, certificate, ...).
    pub fn fallback_pays_off(&self) -> bool {
        match self {
            Self::Cancelled => false,
            Self::Network { code } => !matches!(
                *code,
                url_error::CANNOT_FIND_HOST
                    | url_error::DNS_LOOKUP_FAILED
                    | url_error::TIMED_OUT
                    | url_error::CANCELLED
                    | url_error::NOT_CONNECTED_TO_INTERNET
            ),
            _ => true,
        }
    }
}

/// Sorts a TLS failure (`certificateReason(code:text:)`, ErrorText.swift).
///
/// First by code. For anything else the text decides, but only when it is about TLS at
/// all, so no error sticks to a word like "expired". The more specific words come first
/// ("certificate has expired" also contains "certificate").
pub fn certificate_reason(code: i32, text: &str) -> Option<CertificateReason> {
    match code {
        url_error::CERTIFICATE_BAD_DATE => return Some(CertificateReason::Expired),
        url_error::CERTIFICATE_NOT_YET_VALID => return Some(CertificateReason::AppliesNotYet),
        url_error::CERTIFICATE_UNTRUSTED | url_error::CERTIFICATE_UNKNOWN_ROOT => {
            return Some(CertificateReason::NotTrusted);
        }
        url_error::SECURE_CONNECTION_FAILED
        | url_error::CLIENT_CERTIFICATE_REJECTED
        | url_error::CLIENT_CERTIFICATE_REQUIRED => return Some(CertificateReason::Otherwise),
        _ => {}
    }
    let k = text.to_lowercase();
    if !(k.contains("ssl") || k.contains("tls") || k.contains("certificate")) {
        return None;
    }
    let has = |w: &str| k.contains(w);
    Some(if has("not yet valid") || has("notvalidyet") {
        CertificateReason::AppliesNotYet
    } else if has("expired") {
        CertificateReason::Expired
    } else if has("subject name") || has("hostname") || has("notvalidforname") {
        CertificateReason::OtherAddress
    } else if has("self signed")
        || has("self-signed")
        || has("unable to get local issuer")
        || has("unable to get issuer")
        || has("verify failed")
        || has("not trusted")
        || has("unknownissuer")
        || has("unknown issuer")
    {
        CertificateReason::NotTrusted
    } else {
        CertificateReason::Otherwise
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // ErrorKindTests.swift: network codes stay codes, certificate reasons are sorted.
    #[test]
    fn codes_stay_codes() {
        for code in [-1001, -1003, -1004, -1005, -1009] {
            let e = ErrorKind::Network { code };
            assert_eq!(e.url_error_code(), Some(code));
            assert_eq!(e.topic(), ErrorTopic::Network);
        }
        assert_eq!(
            ErrorKind::Certificate(CertificateReason::Expired).url_error_code(),
            None
        );
    }

    #[test]
    fn certificate_codes_and_text() {
        assert_eq!(
            certificate_reason(-1201, ""),
            Some(CertificateReason::Expired)
        );
        assert_eq!(
            certificate_reason(-1204, ""),
            Some(CertificateReason::AppliesNotYet)
        );
        assert_eq!(
            certificate_reason(-1202, ""),
            Some(CertificateReason::NotTrusted)
        );
        assert_eq!(
            certificate_reason(-1203, ""),
            Some(CertificateReason::NotTrusted)
        );
        assert_eq!(
            certificate_reason(-1200, ""),
            Some(CertificateReason::Otherwise)
        );
        assert_eq!(
            certificate_reason(-1, "SSL certificate problem: self signed certificate"),
            Some(CertificateReason::NotTrusted)
        );
        assert_eq!(
            certificate_reason(-1, "SSL: certificate has expired"),
            Some(CertificateReason::Expired)
        );
        assert_eq!(
            certificate_reason(-1, "TLS: no alternative certificate subject name matches"),
            Some(CertificateReason::OtherAddress)
        );
        assert_eq!(
            certificate_reason(-1, "TLS certificate is not yet valid"),
            Some(CertificateReason::AppliesNotYet)
        );
        // Not about TLS: "expired" alone is not enough.
        assert_eq!(certificate_reason(-1, "the cookie expired"), None);
        assert_eq!(certificate_reason(-1001, "timed out"), None);
    }

    // ErrorKindTests.swift:241 twoFactorBecomesDetected
    #[test]
    fn two_factor_is_a_401_with_a_token() {
        assert_eq!(
            ErrorKind::login_error(401, Some(r#"{"AccessToken":"x"}"#.into())),
            ErrorKind::TwoFactor
        );
        assert_eq!(
            ErrorKind::login_error(401, Some("{}".into())),
            ErrorKind::Http {
                status: 401,
                body: Some("{}".into())
            }
        );
        assert_eq!(
            ErrorKind::login_error(500, Some(r#"{"AccessToken":"x"}"#.into())),
            ErrorKind::Http {
                status: 500,
                body: Some(r#"{"AccessToken":"x"}"#.into())
            }
        );
    }

    #[test]
    fn topics() {
        assert_eq!(ErrorKind::NotAuthenticated.topic(), ErrorTopic::Auth);
        assert_eq!(
            ErrorKind::Http {
                status: 401,
                body: None
            }
            .topic(),
            ErrorTopic::Auth
        );
        assert_eq!(
            ErrorKind::Http {
                status: 500,
                body: None
            }
            .topic(),
            ErrorTopic::Server
        );
        assert_eq!(ErrorKind::Decoding("x".into()).topic(), ErrorTopic::Decode);
    }

    // AddressCheckTests.swift: noFallBackNameDeadlineCancel, fallBackRejectedConnection
    #[test]
    fn address_fallback_rule() {
        for code in [-1003, -1006, -1001, -999, -1009] {
            assert!(!ErrorKind::Network { code }.fallback_pays_off(), "{code}");
        }
        assert!(ErrorKind::Network { code: -1004 }.fallback_pays_off());
        assert!(ErrorKind::Certificate(CertificateReason::NotTrusted).fallback_pays_off());
        assert!(!ErrorKind::Cancelled.fallback_pays_off());
    }
}

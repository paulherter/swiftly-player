//! **What the user is told instead of "Error Domain=... Code=-1004"** (`ErrorText.swift`).
//!
//! Error texts name the cause, not just "something went wrong". Texts go through the catalogue
//! (German wording is the key). Differences to Swift: there is no system text for unknown
//! network codes here, so those use the platform-neutral sentence of the non-Apple branch
//! ("Die Verbindung zum Server hat nicht geklappt."); the Swift `NSError` path becomes
//! [`readable_url_error`] for hosts that only have a code and a description.

use swiftly_net::{CertificateReason, ErrorKind, TransportReason, url_error};

use crate::Translator;

/// The sentence for an error (`readableError`).
pub fn readable_error(tr: &Translator, error: &ErrorKind) -> String {
    match error {
        ErrorKind::Network { code } => network_text(tr, *code),
        ErrorKind::Certificate(reason) => certificate_text(tr, *reason),
        ErrorKind::Transport(reason) => transport_text(tr, reason),
        ErrorKind::NotAuthenticated => tr.t("Nicht angemeldet."),
        ErrorKind::TwoFactor => tr.t("Dein Server will eine Zwei-Faktor-Bestätigung. Gib dieses Gerät im Browser frei oder melde dich mit einem App-Passwort an."),
        ErrorKind::InvalidServerUrl => tr.t("Die Adresse konnte nicht gelesen werden."),
        ErrorKind::Http { status, .. } => match status {
            401 => tr.t("Benutzername oder Passwort stimmt nicht."),
            403 => tr.t("Dieses Konto darf das nicht."),
            404 => tr.t("Das gibt es auf dem Server nicht."),
            500..=599 => tr.t("Der Server hat einen Fehler gemeldet."),
            s => tr.t_args("Der Server hat mit %lld geantwortet.", &[crate::Arg::Int(i64::from(*s))]),
        },
        // Without the decoder text: it says nothing the user could act on.
        ErrorKind::Decoding(_) => tr.t("Die Antwort des Servers war unverständlich."),
        ErrorKind::NoPlayableSource => tr.t("Der Server nennt keine abspielbare Fassung."),
        ErrorKind::PlaybackRejected(reason) => match reason.as_str() {
            "NotAllowed" => tr.t("Der Server lässt dieses Konto den Titel nicht abspielen."),
            "RateLimitExceeded" => tr.t("Der Server lässt gerade keine weitere Wiedergabe zu. Die Bandbreite für dieses Konto ist ausgeschöpft."),
            _ => tr.t("Der Server findet keine Fassung, die er an dieses Gerät schicken darf. Meist ist Umwandeln für dieses Konto abgeschaltet."),
        },
        ErrorKind::QuickConnectExpired => tr.t("Der Code ist abgelaufen oder falsch."),
        ErrorKind::Cancelled => String::new(),
    }
}

/// What is shown when the Quick Connect wait ends without approval (`QuickConnectDeadline.endText`):
/// if even the last poll failed the cause was the connection, otherwise the code ran out. The
/// same sentence as the shown text of an expired code in `QuickConnectExpired.errorDescription`.
pub fn quick_connect_end_text(tr: &Translator, last_failed: bool) -> String {
    if last_failed {
        tr.t("Der Server hat nicht geantwortet.")
    } else {
        tr.t("Der Code ist abgelaufen. Hol dir einen neuen.")
    }
}

/// The sentence for a raw `NSURLErrorDomain` error given as code plus the system's English
/// description (`readableError` via `NSError`): a certificate cause wins over the code text.
pub fn readable_url_error(tr: &Translator, code: i32, description: &str) -> String {
    match certificate_reason(code, description) {
        Some(reason) => certificate_text(tr, reason),
        None => network_text(tr, code),
    }
}

/// [`readable_url_error`] for hosts whose `description` is the system's own, already translated
/// text of the error (Apple: `localizedDescription`). For a code without a sentence of its own
/// the Swift app shows exactly that text, so this does too (also an empty one: the
/// host decides what it passes). The curl-based hosts keep [`readable_url_error`]: their
/// description is English and technical and must not reach the user.
pub fn readable_url_error_system(tr: &Translator, code: i32, description: &str) -> String {
    if let Some(reason) = certificate_reason(code, description) {
        return certificate_text(tr, reason);
    }
    if matches!(
        code,
        url_error::NOT_CONNECTED_TO_INTERNET
            | url_error::TIMED_OUT
            | url_error::CANNOT_FIND_HOST
            | url_error::CANNOT_CONNECT_TO_HOST
            | url_error::NETWORK_CONNECTION_LOST
    ) {
        return network_text(tr, code);
    }
    description.to_owned()
}

fn transport_text(tr: &Translator, reason: &TransportReason) -> String {
    match reason {
        TransportReason::NoHttpResponse => "Keine HTTP-Antwort.".into(),
        TransportReason::LoginPage => tr.t("Vor dem Server sitzt eine Anmeldeseite, etwa Cloudflare Access oder Authelia. Trag die Header, die sie verlangt, unter „Erweitert“ ein."),
        TransportReason::QuickConnectDisabled => tr.t("Der Server hat Quick Connect abgeschaltet."),
        TransportReason::RefreshRejected => "Der Server hat die Auffrischung abgelehnt.".into(),
        TransportReason::RemoteDeviceSilent => tr.t("Das andere Gerät hat nicht reagiert."),
        TransportReason::Other(text) => text.clone(),
    }
}

/// The sentence for an `NSURLErrorDomain` code.
fn network_text(tr: &Translator, code: i32) -> String {
    match code {
        url_error::NOT_CONNECTED_TO_INTERNET => tr.t("Keine Verbindung."),
        url_error::TIMED_OUT => tr.t("Der Server hat nicht geantwortet."),
        url_error::CANNOT_FIND_HOST | url_error::CANNOT_CONNECT_TO_HOST => {
            tr.t("Unter dieser Adresse ist kein Server erreichbar.")
        }
        url_error::NETWORK_CONNECTION_LOST => tr.t("Die Verbindung zum Server ist abgebrochen."),
        // Unknown: claim nothing (this used to say "cancelled", which was wrong).
        _ => tr.t("Die Verbindung zum Server hat nicht geklappt."),
    }
}

/// What is wrong with the server's certificate, or `None` if that is not the cause. Apple has a
/// code per cause (-1200 to -1206); curl-based platforms send `-1` with an English sentence.
pub fn certificate_reason(code: i32, text: &str) -> Option<CertificateReason> {
    use CertificateReason::{AppliesNotYet, Expired, NotTrusted, OtherAddress, Otherwise};
    match code {
        url_error::CERTIFICATE_BAD_DATE => Some(Expired),
        url_error::CERTIFICATE_NOT_YET_VALID => Some(AppliesNotYet),
        url_error::CERTIFICATE_UNTRUSTED | url_error::CERTIFICATE_UNKNOWN_ROOT => Some(NotTrusted),
        url_error::SECURE_CONNECTION_FAILED
        | url_error::CLIENT_CERTIFICATE_REJECTED
        | url_error::CLIENT_CERTIFICATE_REQUIRED => Some(Otherwise),
        _ => {
            let k = text.to_lowercase();
            // First check the sentence is about TLS at all.
            if !(k.contains("ssl") || k.contains("tls") || k.contains("certificate")) {
                return None;
            }
            // More specific first: "certificate has expired" also contains "certificate".
            if k.contains("not yet valid") {
                Some(AppliesNotYet)
            } else if k.contains("expired") {
                Some(Expired)
            } else if k.contains("subject name") || k.contains("hostname") {
                Some(OtherAddress)
            } else if [
                "self signed",
                "self-signed",
                "unable to get local issuer",
                "unable to get issuer",
                "verify failed",
                "not trusted",
            ]
            .iter()
            .any(|p| k.contains(p))
            {
                Some(NotTrusted)
            } else {
                Some(Otherwise)
            }
        }
    }
}

/// One sentence per cause: "invalid certificate" alone does not say whether the clock is
/// wrong or a different server answers.
fn certificate_text(tr: &Translator, reason: CertificateReason) -> String {
    match reason {
        CertificateReason::NotTrusted => tr.t("Dem Zertifikat des Servers wird nicht vertraut."),
        CertificateReason::Expired => tr.t("Das Zertifikat des Servers ist abgelaufen."),
        CertificateReason::AppliesNotYet => tr.t("Das Zertifikat des Servers gilt noch nicht."),
        CertificateReason::OtherAddress => {
            tr.t("Das Zertifikat des Servers gehört zu einer anderen Adresse.")
        }
        CertificateReason::Otherwise => tr.t("Die verschlüsselte Verbindung kam nicht zustande."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Locale, Lookup};
    use CertificateReason::*;

    const CODES: [i32; 5] = [-1001, -1003, -1004, -1005, -1009];

    fn tr(l: &str) -> Translator {
        Translator::new(Locale::parse(l))
    }
    fn de() -> Translator {
        tr("de")
    }

    // ErrorKindTests.swift: networkErrorSameRead / timeoutAndNoServerDiffer
    #[test]
    fn network_error_same_read_raw_or_wrapped() {
        for code in CODES {
            assert_eq!(
                readable_error(&de(), &ErrorKind::Network { code }),
                readable_url_error(&de(), code, "The request timed out.")
            );
        }
        assert_ne!(
            readable_error(&de(), &ErrorKind::Network { code: -1001 }),
            readable_error(&de(), &ErrorKind::Network { code: -1003 })
        );
    }

    #[test]
    fn decoder_text_reaches_user_not() {
        let text = readable_error(
            &de(),
            &ErrorKind::Decoding("keyNotFound(CodingKeys(stringValue: \"Id\"))".into()),
        );
        assert!(!text.contains("keyNotFound") && !text.is_empty());
    }

    #[test]
    fn curl_tls_error_is_not_cancelled() {
        let cancelled = readable_error(&de(), &ErrorKind::Network { code: -1005 });
        for text in [
            "SSL certificate problem: self signed certificate",
            "SSL certificate problem: certificate has expired",
            "SSL: no alternative certificate subject name matches target hostname 'x.de'",
            "SSL certificate problem: self signed certificate in certificate chain",
        ] {
            assert_ne!(readable_url_error(&de(), -1, text), cancelled);
            assert!(certificate_reason(-1, text).is_some(), "{text}");
        }
        assert!(
            !readable_url_error(
                &de(),
                -1,
                "SSL certificate problem: self signed certificate"
            )
            .contains("SSL")
        );
    }

    #[test]
    fn each_reason_says_something_other() {
        let all = [NotTrusted, Expired, AppliesNotYet, OtherAddress, Otherwise];
        let s: Vec<String> = all
            .iter()
            .map(|r| readable_error(&de(), &ErrorKind::Certificate(*r)))
            .collect();
        let mut dedup = s.clone();
        dedup.sort();
        dedup.dedup();
        assert_eq!(dedup.len(), all.len());
        assert!(s.iter().all(|x| !x.is_empty()));
    }

    #[test]
    fn reason_from_sentence() {
        for (text, want) in [
            (
                "SSL certificate problem: self signed certificate",
                NotTrusted,
            ),
            (
                "SSL certificate problem: self signed certificate in certificate chain",
                NotTrusted,
            ),
            (
                "SSL certificate problem: unable to get local issuer certificate",
                NotTrusted,
            ),
            ("SSL certificate problem: certificate has expired", Expired),
            (
                "SSL certificate problem: certificate is not yet valid",
                AppliesNotYet,
            ),
            (
                "SSL: no alternative certificate subject name matches target hostname 'x.de'",
                OtherAddress,
            ),
            ("SSL connect error", Otherwise),
        ] {
            assert_eq!(certificate_reason(-1, text), Some(want), "{text}");
        }
    }

    #[test]
    fn reason_from_apple_code() {
        for (code, want) in [
            (-1202, NotTrusted),
            (-1203, NotTrusted),
            (-1201, Expired),
            (-1204, AppliesNotYet),
            (-1200, Otherwise),
        ] {
            assert_eq!(certificate_reason(code, ""), Some(want));
        }
    }

    #[test]
    fn network_error_stays_network_error() {
        for code in CODES {
            assert_eq!(certificate_reason(code, "The request timed out."), None);
        }
    }

    #[test]
    fn unknown_code_claims_nothing() {
        let cancelled = readable_error(&de(), &ErrorKind::Network { code: -1005 });
        assert_ne!(
            readable_error(&de(), &ErrorKind::Network { code: -1 }),
            cancelled
        );
        assert_ne!(
            readable_error(&de(), &ErrorKind::Network { code: -9999 }),
            cancelled
        );
    }

    #[test]
    fn response_body_reaches_user_not() {
        let text = readable_error(
            &de(),
            &ErrorKind::Http {
                status: 500,
                body: Some("Stapel geheim".into()),
            },
        );
        assert!(!text.contains("geheim"));
    }

    #[test]
    fn http_statuses() {
        let t = de();
        let h = |s| {
            readable_error(
                &t,
                &ErrorKind::Http {
                    status: s,
                    body: None,
                },
            )
        };
        assert_eq!(h(401), "Benutzername oder Passwort stimmt nicht.");
        assert_eq!(h(403), "Dieses Konto darf das nicht.");
        assert_eq!(h(404), "Das gibt es auf dem Server nicht.");
        assert_eq!(h(502), "Der Server hat einen Fehler gemeldet.");
        assert_eq!(h(418), "Der Server hat mit 418 geantwortet.");
        assert_eq!(
            readable_error(
                &tr("en"),
                &ErrorKind::Http {
                    status: 418,
                    body: None
                }
            ),
            "The server answered with 418."
        );
    }

    #[test]
    fn two_factor_mentions_it_and_transport_passes_text() {
        assert!(readable_error(&de(), &ErrorKind::TwoFactor).contains("Zwei-Faktor"));
        let own = ErrorKind::Transport(TransportReason::Other("Eigener Satz.".into()));
        assert_eq!(readable_error(&de(), &own), "Eigener Satz.");
    }

    #[test]
    fn every_catalogue_sentence_exists_in_all_three_languages() {
        let errors = [
            ErrorKind::NotAuthenticated,
            ErrorKind::TwoFactor,
            ErrorKind::InvalidServerUrl,
            ErrorKind::NoPlayableSource,
            ErrorKind::QuickConnectExpired,
            ErrorKind::PlaybackRejected("NotAllowed".into()),
            ErrorKind::PlaybackRejected("RateLimitExceeded".into()),
            ErrorKind::PlaybackRejected("x".into()),
            ErrorKind::Decoding(String::new()),
            ErrorKind::Network { code: -1009 },
            ErrorKind::Network { code: -1001 },
            ErrorKind::Network { code: -1003 },
            ErrorKind::Network { code: -1005 },
            ErrorKind::Network { code: -1 },
            ErrorKind::Transport(TransportReason::LoginPage),
            ErrorKind::Transport(TransportReason::QuickConnectDisabled),
            ErrorKind::Transport(TransportReason::RemoteDeviceSilent),
            ErrorKind::Http {
                status: 401,
                body: None,
            },
            ErrorKind::Http {
                status: 403,
                body: None,
            },
            ErrorKind::Http {
                status: 404,
                body: None,
            },
            ErrorKind::Http {
                status: 500,
                body: None,
            },
            ErrorKind::Certificate(NotTrusted),
            ErrorKind::Certificate(Expired),
            ErrorKind::Certificate(AppliesNotYet),
            ErrorKind::Certificate(OtherAddress),
            ErrorKind::Certificate(Otherwise),
        ];
        for e in &errors {
            let german = readable_error(&de(), e);
            for l in ["en", "ru"] {
                let t = tr(l);
                let text = readable_error(&t, e);
                assert!(!text.is_empty(), "{e:?} {l}");
                assert_ne!(text, german, "{e:?} not translated to {l}");
                let _ = t.lookup(&german);
            }
        }
        // The sentences are real catalogue entries, not accidental fallbacks.
        assert!(matches!(de().lookup("Nicht angemeldet."), Lookup { .. }));
    }
}

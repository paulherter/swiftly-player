use swiftly_model::PublicSystemInfo;
use swiftly_net::{ErrorKind, TransportReason};

use crate::ServerKind;

/// The Jellyfin path of the client, turned into the one Emby answers
/// (`EmbyPaths.rewrite`, Emby/EmbyPaths.swift:21-44).
///
/// Without a user there is nothing to build a user path from, so the path stays.
pub fn rewrite_path(path: &str, user_id: Option<&str>) -> String {
    let Some(user_id) = user_id.filter(|u| !u.is_empty()) else {
        return path.to_string();
    };
    let user = format!("Users/{user_id}/");
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let Some(first) = parts.first() else {
        return path.to_string();
    };
    match (*first, parts.len()) {
        ("UserViews", 1) => format!("{user}Views"),
        ("Items", 1) => format!("{user}Items"),
        ("Items", 2) => format!("{user}{path}"),
        ("Items", 3) if matches!(parts[2], "SpecialFeatures" | "LocalTrailers") => {
            format!("{user}{path}")
        }
        ("UserItems", 2) if parts[1] == "Resume" => format!("{user}Items/Resume"),
        ("UserItems", 3) if parts[2] == "UserData" => format!("{user}Items/{}/UserData", parts[1]),
        ("UserFavoriteItems", 2) => format!("{user}FavoriteItems/{}", parts[1]),
        ("UserPlayedItems", 2) => format!("{user}PlayedItems/{}", parts[1]),
        _ => path.to_string(),
    }
}

/// The query name that carries the token in an address the player or the image loader
/// opens without headers (`EmbyPaths.tokenName`, Emby/EmbyPaths.swift:48).
pub fn token_name(kind: ServerKind) -> &'static str {
    match kind {
        ServerKind::Emby => "api_key",
        ServerKind::Plex => "X-Plex-Token",
        ServerKind::Jellyfin => "ApiKey",
    }
}

/// What one attempt at an Emby address showed (`AppModel.embyCheck`,
/// Sources/Shared/AppModel+Servers.swift:109-155).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EmbyAttempt {
    /// An Emby answered: go on to the sign-in step.
    Accepted,
    /// Something answered, but it is a Jellyfin (the two look alike from outside).
    LooksLikeJellyfin,
    /// Nothing usable answered; `try_next` says whether the other spelling of the address
    /// (https/http swapped) is worth a try. Only an address typed without a scheme has one.
    Failed {
        /// Whether the next candidate address should be tried.
        try_next: bool,
    },
}

/// Classifies the answer of `checkReachability` at one candidate address.
pub fn classify_attempt(answer: &Result<PublicSystemInfo, ErrorKind>) -> EmbyAttempt {
    match answer {
        Ok(info) if info.looks_like_jellyfin() => EmbyAttempt::LooksLikeJellyfin,
        Ok(_) => EmbyAttempt::Accepted,
        Err(e) => EmbyAttempt::Failed {
            try_next: e.fallback_pays_off(),
        },
    }
}

/// What the address step shows when no candidate worked (`EmbySignInProblem`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EmbyProblem {
    /// Nothing answered at the address (the address as typed).
    Unreachable {
        /// The address the user typed.
        address: String,
    },
    /// Something answered, but not Emby; `found` names it when known ("Jellyfin").
    NotEmby {
        /// The product found at the address.
        found: Option<String>,
    },
    /// The address could not be read.
    BadAddress,
    /// A gateway's login page sits in front of the server; the header hint is the sentence.
    LoginPage,
}

/// The problem after the last candidate failed: a login page in front of the server is its own
/// sentence, everything else is "unreachable" with the address as typed.
pub fn classify_failure(last_error: Option<&ErrorKind>, raw: &str) -> EmbyProblem {
    if matches!(
        last_error,
        Some(ErrorKind::Transport(TransportReason::LoginPage))
    ) {
        return EmbyProblem::LoginPage;
    }
    EmbyProblem::Unreachable {
        address: raw.to_string(),
    }
}

/// The problem when a Jellyfin answered where Emby was expected.
pub fn not_emby_jellyfin() -> EmbyProblem {
    EmbyProblem::NotEmby {
        found: Some("Jellyfin".into()),
    }
}

/// Name and version for the sign-in header: the server's own, else the host of the address,
/// else "Server" (name, German key text) and "?" (version).
pub fn sign_in_header(info: &PublicSystemInfo, host: Option<&str>) -> (Option<String>, String) {
    let name = info
        .server_name
        .clone()
        .or_else(|| host.map(str::to_string));
    (name, info.version.clone().unwrap_or_else(|| "?".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    // EmbyTests.swift:55 pathTable
    #[test]
    fn path_table() {
        let table = [
            ("UserViews", "Users/u1/Views"),
            ("Items", "Users/u1/Items"),
            ("Items/42", "Users/u1/Items/42"),
            (
                "Items/42/SpecialFeatures",
                "Users/u1/Items/42/SpecialFeatures",
            ),
            ("Items/42/LocalTrailers", "Users/u1/Items/42/LocalTrailers"),
            ("UserItems/Resume", "Users/u1/Items/Resume"),
            ("UserItems/42/UserData", "Users/u1/Items/42/UserData"),
            ("UserFavoriteItems/42", "Users/u1/FavoriteItems/42"),
            ("UserPlayedItems/42", "Users/u1/PlayedItems/42"),
            ("Shows/NextUp", "Shows/NextUp"),
            ("Shows/7/Episodes", "Shows/7/Episodes"),
            ("Items/42/PlaybackInfo", "Items/42/PlaybackInfo"),
            ("Items/42/Similar", "Items/42/Similar"),
            ("Sessions/Playing", "Sessions/Playing"),
            ("Users/AuthenticateByName", "Users/AuthenticateByName"),
            ("System/Info/Public", "System/Info/Public"),
        ];
        for (jellyfin, emby) in table {
            assert_eq!(rewrite_path(jellyfin, Some("u1")), emby, "{jellyfin}");
        }
        assert_eq!(rewrite_path("UserViews", None), "UserViews");
        assert_eq!(rewrite_path("UserViews", Some("")), "UserViews");
    }

    // EmbyTests.swift:96 tokenSpelling (names part)
    #[test]
    fn token_spelling() {
        assert_eq!(token_name(ServerKind::Emby), "api_key");
        assert_eq!(token_name(ServerKind::Jellyfin), "ApiKey");
        assert_eq!(token_name(ServerKind::Plex), "X-Plex-Token");
    }

    fn info(product: Option<&str>, version: Option<&str>) -> PublicSystemInfo {
        PublicSystemInfo {
            server_name: Some("S".into()),
            version: version.map(Into::into),
            id: None,
            product_name: product.map(Into::into),
        }
    }

    // AppModel+Servers.swift embyCheck: Jellyfin is told from Emby by the public info.
    #[test]
    fn attempt_tells_jellyfin_from_emby() {
        let jf = Ok(info(Some("Jellyfin Server"), Some("10.9.0")));
        assert_eq!(classify_attempt(&jf), EmbyAttempt::LooksLikeJellyfin);
        let old = Ok(info(None, Some("10.8.1")));
        assert_eq!(classify_attempt(&old), EmbyAttempt::LooksLikeJellyfin);
        let emby = Ok(info(None, Some("4.8.0.0")));
        assert_eq!(classify_attempt(&emby), EmbyAttempt::Accepted);
    }

    #[test]
    fn attempt_failure_tries_the_other_spelling_only_when_it_pays_off() {
        let no_route = Err(ErrorKind::Network { code: -1004 });
        assert_eq!(
            classify_attempt(&no_route),
            EmbyAttempt::Failed { try_next: true }
        );
        let cancelled = Err(ErrorKind::Cancelled);
        assert_eq!(
            classify_attempt(&cancelled),
            EmbyAttempt::Failed { try_next: false }
        );
    }

    #[test]
    fn failure_is_unreachable_unless_a_login_page_answered() {
        let page = ErrorKind::Transport(TransportReason::LoginPage);
        assert_eq!(
            classify_failure(Some(&page), "tv.example.de"),
            EmbyProblem::LoginPage
        );
        let net = ErrorKind::Network { code: -1004 };
        assert_eq!(
            classify_failure(Some(&net), "tv.example.de"),
            EmbyProblem::Unreachable {
                address: "tv.example.de".into()
            }
        );
        assert_eq!(
            classify_failure(None, "x"),
            EmbyProblem::Unreachable {
                address: "x".into()
            }
        );
        assert_eq!(
            not_emby_jellyfin(),
            EmbyProblem::NotEmby {
                found: Some("Jellyfin".into())
            }
        );
    }

    #[test]
    fn header_falls_back_to_host_and_question_mark() {
        let mut i = info(None, None);
        i.server_name = None;
        assert_eq!(
            sign_in_header(&i, Some("tv.example.de")),
            (Some("tv.example.de".into()), "?".into())
        );
        assert_eq!(sign_in_header(&i, None), (None, "?".into()));
        assert_eq!(
            sign_in_header(&info(None, Some("4.8")), None),
            (Some("S".into()), "4.8".into())
        );
    }
}

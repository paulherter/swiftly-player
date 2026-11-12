//! Seerr as the old Android facade (`Kern.seerr…`) answered it: the same JSON strings over the core's [`SeerrModel`].
//! The Compose code keeps the stored access (`{"adresse","keks","koepfe"}`) in its vault; this object is built from it.

use std::sync::Arc;

use serde_json::{Value, json};
use swiftly_seerr::{SeerrAccess, SeerrHit, SeerrSessionState};

use crate::seerr::{SeerrConnection, SeerrModel};

/// One connection's calls (`Kern.seerrApplies/Search/Filmography/Detail/Request`).
#[derive(uniffi::Object)]
pub struct LegacySeerr {
    model: Arc<SeerrModel>,
}

impl LegacySeerr {
    pub(crate) fn new(model: Arc<SeerrModel>) -> Arc<Self> {
        Arc::new(Self { model })
    }
}

/// The stored access as a connection; `None` when it does not read (`Kern.seerrSet`).
pub(crate) fn connection_of(access: &str) -> Option<SeerrConnection> {
    let a: SeerrAccess = serde_json::from_str(access).ok()?;
    Some(SeerrConnection {
        address: a.address,
        cookie: a.cookie,
        headers: a.headers,
    })
}

/// The access to store for a connection (`{"adresse","keks","koepfe"}`).
pub(crate) fn access_json(c: &SeerrConnection) -> String {
    serde_json::to_string(&SeerrAccess {
        address: c.address.clone(),
        cookie: c.cookie.clone(),
        headers: c.headers.clone(),
    })
    .unwrap_or_default()
}

/// Swift's `Encodable` leaves a missing optional out instead of writing `null`.
fn without_nulls(v: Value) -> Value {
    match v {
        Value::Object(m) => Value::Object(
            m.into_iter()
                .filter(|(_, v)| !v.is_null())
                .map(|(k, v)| (k, without_nulls(v)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.into_iter().map(without_nulls).collect()),
        other => other,
    }
}

fn tile(t: &SeerrHit) -> Value {
    without_nulls(json!({
        "id": t.id, "art": t.art, "titel": t.title, "jahr": t.year, "plakat": t.poster(342), "kulisse": t.backdrop(780),
        "stand": t.state.raw(), "anfragbar": t.state.requestable(),
    }))
}

fn tiles(hits: Vec<SeerrHit>) -> String {
    Value::Array(
        hits.iter()
            .filter(|h| !h.state.already_present())
            .map(tile)
            .collect(),
    )
    .to_string()
}

#[uniffi::export]
impl LegacySeerr {
    /// `false` only when Seerr said the session is gone; a network error is not an expired session.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn applies(&self) -> bool {
        self.model.client().applies().await != SeerrSessionState::Invalid
    }

    /// Only what the own server does not have yet.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn search(&self, term: String) -> String {
        if !swiftly_rules::display_rules::search_term_fits(&term) {
            return "[]".into();
        }
        tiles(self.model.client().searching(&term).await)
    }

    /// A person's titles that the own server does not have yet.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn filmography(&self, tmdb: i64) -> String {
        tiles(self.model.client().filmography(tmdb).await)
    }

    /// Details and suggestions; `{}` when Seerr did not answer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn detail(&self, art: String, id: i64) -> String {
        let Some(d) = self.model.client().detail(&art, id).await else {
            return "{}".into();
        };
        without_nulls(json!({
            "beschreibung": d.description, "genres": d.genres, "laufzeit": d.runtime, "bewertung": d.rating,
            "staffeln": d.seasons.iter().map(|s| json!({"nummer": s.number, "folgen": s.episodes, "stand": s.state.raw(), "anfragbar": s.state.requestable()})).collect::<Vec<_>>(),
            "besetzung": d.cast.iter().map(|p| json!({"id": p.id.to_string(), "name": p.name, "rolle": p.role, "bild": p.image(185)})).collect::<Vec<_>>(),
            "aehnliches": d.similar_one.iter().map(tile).collect::<Vec<_>>(),
            "stand": d.state.map(|s| s.raw()), "anfragbar": d.state.map(|s| s.requestable()),
        }))
        .to_string()
    }

    /// Empty means done; `seasons` as "1,2" (meaningless for a movie, never empty for a series), else the error sentence.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn request(&self, art: String, id: i64, seasons: String) -> String {
        let numbers: Vec<i64> = seasons.split(',').filter_map(|s| s.parse().ok()).collect();
        if art == "tv" && numbers.is_empty() {
            return String::new();
        }
        match self
            .model
            .client()
            .ask_for(&art, id, (art == "tv").then_some(numbers.as_slice()))
            .await
        {
            Ok(()) => String::new(),
            Err(e) => crate::seerr::readable(&e).to_string(),
        }
    }

    /// Forgets the platform cookies of this address (sign-out).
    pub fn forget_cookies(&self) {
        self.model.forget_cookies();
    }
}

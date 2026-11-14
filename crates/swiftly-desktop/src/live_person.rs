//! The live data of a person page, the same calls the Mac's `PersonController` makes (`swiftly-uniffi` `PersonModel`):
//! `item(person_id)` for the biography, birthday, place and Tmdb id, and `Items?PersonIds=` (movies and series, newest
//! first, doubles removed) for the filmography, both at once. The answer goes into `PersonVm::loaded` unchanged.

use crate::login_screen::Pending;
use swiftly_images::{ImageAddress, ImageKind, ImageMetric};
use swiftly_jellyfin::{ItemsQuery, JellyfinClient};
use swiftly_l10n::Locale;
use swiftly_library::ListRules;
use swiftly_model::Item;
use swiftly_net::HttpTransport;
use swiftly_vm::{AccountRef, ImageRef, PERSON_PAGE_SIZE, PersonDetail};

/// Height of the portrait in pixels (`personImage(_, maxHeight: 300)`).
const PORTRAIT_HEIGHT: i64 = 300;

/// What the two requests brought.
#[derive(Debug, Clone, Default)]
pub struct Loaded {
    /// The person's own entry (`None`: the request failed).
    pub detail: Option<PersonDetail>,
    /// The first page of the filmography and the server's total (`None`: the request failed).
    pub page: Option<(Vec<Item>, i64)>,
    /// The tag of the person's picture, for the sharp portrait.
    pub tag: Option<String>,
}

/// "12. März 1984" (`date.formatted(date: .long)`) from a server timestamp; `None` when it cannot be read.
#[must_use]
pub fn long_date(iso: &str, locale: &Locale) -> Option<String> {
    let mut parts = iso.get(..10)?.split('-');
    let year: i32 = parts.next()?.parse().ok()?;
    let month: usize = parts.next()?.parse().ok()?;
    let day: u32 = parts.next()?.parse().ok()?;
    if !(1..=12).contains(&month) || day == 0 || day > 31 {
        return None;
    }
    const DE: [&str; 12] = [
        "Januar",
        "Februar",
        "März",
        "April",
        "Mai",
        "Juni",
        "Juli",
        "August",
        "September",
        "Oktober",
        "November",
        "Dezember",
    ];
    const EN: [&str; 12] = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ];
    Some(if locale.language() == "de" {
        format!("{day}. {} {year}", DE[month - 1])
    } else {
        format!("{} {day}, {year}", EN[month - 1])
    })
}

async fn filmography<T: HttpTransport>(
    client: &JellyfinClient<T>,
    id: &str,
    since: i64,
) -> Option<(Vec<Item>, i64)> {
    let q = ItemsQuery {
        limit: PERSON_PAGE_SIZE,
        start_index: since,
        sort_by: "ProductionYear,SortName".into(),
        sort_order: "Descending".into(),
        recursive: true,
        include_item_types: vec!["Movie".into(), "Series".into()],
        person_ids: vec![id.to_owned()],
        ..ItemsQuery::default()
    };
    let answer = client.items(&q).await.ok()?;
    Some((
        ListRules::without_double(&answer.items),
        answer.total_record_count,
    ))
}

/// Loads the person and the filmography together (`PersonModel.load`).
pub async fn load<T: HttpTransport>(
    client: &JellyfinClient<T>,
    id: &str,
    locale: &Locale,
) -> Loaded {
    let (item, page) =
        futures_util::future::join(client.item(id), filmography(client, id, 0)).await;
    let item = item.ok();
    Loaded {
        tag: item
            .as_ref()
            .and_then(|i| i.image_tags.as_ref())
            .and_then(|t| t.get("Primary").cloned()),
        detail: item.map(|i| PersonDetail {
            born: i
                .premiere_date
                .as_deref()
                .and_then(|d| long_date(d, locale)),
            places: i.production_locations.clone().unwrap_or_default(),
            biography: i.overview.clone().filter(|t| !t.is_empty()),
            tmdb_id: i
                .provider_ids
                .as_ref()
                .and_then(|m| m.get("Tmdb"))
                .and_then(|t| t.parse().ok()),
        }),
        page,
    }
}

/// Starts the load of `id` on the network runtime; the answer arrives in the `Pending`.
pub fn start(core: &crate::live::Core, account: &AccountRef, id: &str) -> Option<Pending<Loaded>> {
    let client = core.client_for(account).ok()?;
    let (tx, rx) = Pending::channel();
    let (id, locale) = (id.to_owned(), core.host().locale);
    core.spawn(async move {
        let _ = tx.send(load(&client, &id, &locale).await);
    });
    Some(rx)
}

fn addresses<T: HttpTransport>(client: &JellyfinClient<T>) -> Option<ImageAddress> {
    let s = client.current_session()?;
    Some(ImageAddress::new(
        client.base_url().clone(),
        Some(s.access_token),
        client.server_kind(),
    ))
}

/// The sharp portrait (`personImage(_, maxHeight: 300)`); `None` without a picture tag.
pub fn portrait<T: HttpTransport>(
    client: &JellyfinClient<T>,
    id: &str,
    tag: Option<&str>,
) -> Option<ImageRef> {
    let tag = tag?;
    addresses(client)?
        .construct(
            id,
            ImageKind::Poster,
            Some(tag),
            ImageMetric::AtMostHigh(PORTRAIT_HEIGHT),
        )
        .map(|url| ImageRef {
            address: url.into(),
            kind: swiftly_vm::ImageKind::Poster,
            wanted_width: PORTRAIT_HEIGHT as u32,
            wanted_height: PORTRAIT_HEIGHT as u32,
        })
}

/// The banner: the first real landscape picture of the titles (`bannerURL`, 1200 high like the core's).
pub fn banner<T: HttpTransport>(titles: &[Item], client: &JellyfinClient<T>) -> Option<ImageRef> {
    swiftly_vm::banner_of(titles, client).map(|address| ImageRef {
        address,
        kind: swiftly_vm::ImageKind::Backdrop,
        wanted_width: 1200,
        wanted_height: 675,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::AppTransport;
    use std::sync::Arc;
    use swiftly_jellyfin::ClientConfig;
    use swiftly_net::MockTransport;
    use swiftly_vm::Shared;

    fn client(mock: MockTransport) -> JellyfinClient<Shared<AppTransport>> {
        let c = JellyfinClient::new(
            Shared(Arc::new(AppTransport::Mock(mock))),
            "http://fixture.test",
            ClientConfig::new("dev", "Test", "0"),
        )
        .unwrap();
        c.set_session(Some(swiftly_jellyfin::Session {
            access_token: "tok".into(),
            user_id: "u1".into(),
            user_name: String::new(),
            server_url: "http://fixture.test".into(),
            kind: swiftly_jellyfin::ServerKind::Jellyfin,
        }));
        c
    }

    const PERSON: &str = r#"{"Id":"p1","Name":"Mara Brandt","Type":"Person","Overview":"Wuchs an der Küste auf.","PremiereDate":"1984-03-12T00:00:00.0000000Z","ProductionLocations":["Kiel"],"ProviderIds":{"Tmdb":"77"},"ImageTags":{"Primary":"tagp"}}"#;

    #[test]
    fn dates_read_like_the_long_style_of_the_language() {
        let de = Locale::parse("de");
        assert_eq!(
            long_date("1984-03-12T00:00:00.0000000Z", &de).as_deref(),
            Some("12. März 1984")
        );
        assert_eq!(
            long_date("1984-03-12", &Locale::parse("en")).as_deref(),
            Some("March 12, 1984")
        );
        assert_eq!(long_date("nonsense", &de), None);
    }

    #[test]
    fn the_person_page_asks_item_and_person_ids_and_fills_the_view_model() {
        let mock = MockTransport::new()
            .route("/Items/p1", 200, PERSON)
            .route(
                "/Items",
                200,
                r#"{"Items":[{"Id":"m1","Name":"Nordlicht","Type":"Movie","ProductionYear":2021},{"Id":"s1","Name":"Hafen","Type":"Series","ProductionYear":2019}],"TotalRecordCount":2}"#,
            );
        let c = client(mock);
        let got = futures_executor::block_on(load(&c, "p1", &Locale::parse("de")));
        let d = got.detail.expect("person answered");
        assert_eq!(d.born.as_deref(), Some("12. März 1984"));
        assert_eq!(d.places, ["Kiel"]);
        assert_eq!(d.tmdb_id, Some(77));
        let (items, total) = got.page.expect("filmography answered");
        assert_eq!((items.len(), total), (2, 2));
        assert_eq!(got.tag.as_deref(), Some("tagp"));
        let url = portrait(&c, "p1", got.tag.as_deref())
            .expect("portrait")
            .address;
        assert!(url.contains("Items/p1/Images/Primary"), "{url}");
        assert!(
            url.contains("maxHeight=300") || url.contains("fillHeight=300"),
            "{url}"
        );
        assert!(url.contains("tagp"), "{url}");
        assert!(portrait(&c, "p1", None).is_none());
    }
}

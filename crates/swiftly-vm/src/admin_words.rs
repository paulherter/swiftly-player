//! **The action words of the management hub** (request queue, reports, server), said once for every host.
//!
//! Every host draws these buttons and empty states; none picks its own wording or its own catalogue. Android reads this
//! record; the Apple hosts use the same German keys through the shared catalogue, so one list holds the words:
//! [`ADMIN_KEYS`].

use swiftly_l10n::{Locale, Translator};

/// The German keys, in the order of [`AdminWords`]' fields (a test keeps both in step).
pub const ADMIN_KEYS: [&str; 15] = [
    "Freigeben",
    "Ablehnen",
    "Nochmal",
    "Zurückziehen",
    "Antworten",
    "Erledigt",
    "Wieder öffnen",
    "Abbrechen",
    "Zurück",
    "Moment…",
    "Keine Meldungen",
    "Noch nichts angefragt",
    "Seerr antwortet gerade nicht",
    "Meldungen",
    "Server",
];

/// The words, in the account's language.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdminWords {
    /// Approve a waiting request.
    pub approve: String,
    /// Decline a waiting request.
    pub decline: String,
    /// Start a failed request again.
    pub retry: String,
    /// Take an own request back.
    pub withdraw: String,
    /// Send a reply in a report thread.
    pub reply: String,
    /// Mark a report resolved.
    pub resolve: String,
    /// Open a resolved report again.
    pub reopen: String,
    /// Leave a question without doing anything.
    pub cancel: String,
    /// Back one level.
    pub back: String,
    /// While a list loads.
    pub loading: String,
    /// The report list is empty.
    pub no_reports: String,
    /// The request list is empty.
    pub nothing_requested: String,
    /// Seerr does not answer.
    pub seerr_offline: String,
    /// Name of the reports section (the way back out of a thread).
    pub reports: String,
    /// Name of the server section (the way back out of the logs).
    pub server: String,
}

impl AdminWords {
    /// The words for `locale`.
    pub fn new(locale: &Locale) -> Self {
        let t = Translator::new(locale.clone());
        let [
            approve,
            decline,
            retry,
            withdraw,
            reply,
            resolve,
            reopen,
            cancel,
            back,
            loading,
            no_reports,
            nothing_requested,
            seerr_offline,
            reports,
            server,
        ] = ADMIN_KEYS.map(|k| t.t(k));
        Self {
            approve,
            decline,
            retry,
            withdraw,
            reply,
            resolve,
            reopen,
            cancel,
            back,
            loading,
            no_reports,
            nothing_requested,
            seerr_offline,
            reports,
            server,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_l10n::Resolution;

    fn all(w: &AdminWords) -> [&str; 15] {
        [
            &w.approve,
            &w.decline,
            &w.retry,
            &w.withdraw,
            &w.reply,
            &w.resolve,
            &w.reopen,
            &w.cancel,
            &w.back,
            &w.loading,
            &w.no_reports,
            &w.nothing_requested,
            &w.seerr_offline,
            &w.reports,
            &w.server,
        ]
    }

    #[test]
    fn every_key_is_in_the_catalogue_in_all_three_languages() {
        for lang in ["de", "en", "ru"] {
            let t = Translator::new(Locale::parse(lang));
            for k in ADMIN_KEYS {
                assert_eq!(
                    t.lookup(k).resolution,
                    Resolution::Exact,
                    "{k} missing in {lang}"
                );
            }
        }
    }

    #[test]
    fn the_words_follow_the_language() {
        let de = AdminWords::new(&Locale::parse("de"));
        let en = AdminWords::new(&Locale::parse("en"));
        let ru = AdminWords::new(&Locale::parse("ru"));
        assert_eq!(
            (de.decline.as_str(), de.reply.as_str()),
            ("Ablehnen", "Antworten")
        );
        assert_eq!(
            (en.decline.as_str(), en.approve.as_str()),
            ("Decline", "Approve")
        );
        assert_eq!(ru.decline, "Отклонить");
        assert_eq!(en.reports, "Reports");
        // No German word is left on an English or Russian host, and none is empty.
        for (a, b) in all(&de).iter().zip(all(&en)) {
            assert!(!b.is_empty());
            if !matches!(*a, "Server") {
                assert_ne!(*a, b, "{a} not translated to English");
            }
        }
        for (a, b) in all(&de).iter().zip(all(&ru)) {
            if !matches!(*a, "Server") {
                assert_ne!(*a, b, "{a} not translated to Russian");
            }
        }
    }
}

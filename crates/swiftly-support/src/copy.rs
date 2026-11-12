//! The texts of "Support Swiftly" in German and English, the three tips, the Apple product ids
//! and the supporter icons (`SupportCopy.swift`, `SupportStanding.swift`,
//! `SupportModel.swift:622-627`). The German sentence is the lookup key, as everywhere.

use crate::support::SupportPlan;

/// A pair of texts. `de` is also the catalogue key. Placeholders use catalogue syntax: `%lld`
/// for a whole number, `%@` for text.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SupportCopy {
    /// German wording, also the catalogue key.
    pub de: &'static str,
    /// English wording.
    pub en: &'static str,
}

impl SupportCopy {
    /// A pair.
    pub const fn new(de: &'static str, en: &'static str) -> Self {
        Self { de, en }
    }

    /// The catalogue key.
    pub const fn key(&self) -> &'static str {
        self.de
    }

    /// The text for a language code such as "de", "de-AT" or "en-US"; English otherwise.
    pub fn text_for_language(&self, code: &str) -> &'static str {
        if code.to_lowercase().starts_with("de") {
            self.de
        } else {
            self.en
        }
    }

    pub const SUPPORT_SWIFTLY: Self = Self::new("Swiftly unterstützen", "Support Swiftly");
    pub const SAY_THANKS: Self =
        Self::new("Mit einem Kaffee Danke sagen", "Say thanks with a coffee");
    pub const SAY_THANKS_FREE_FOR_ALL: Self = Self::new(
        "Mit einem Kaffee Danke sagen. Alles bleibt für alle kostenlos.",
        "Say thanks with a coffee. Everything stays free for everyone.",
    );
    pub const SHEET_INTRO: Self = Self::new(
        "Wir bauen Swiftly ohne Werbung und ohne Tracking. Wenn es deine Abende besser macht, hilft uns ein Kaffee, weiterzumachen.",
        "We build Swiftly without ads or tracking. If it makes your evenings better, a coffee helps us keep going.",
    );
    pub const FREE_FOR_EVERYONE: Self = Self::new(
        "Alles bleibt für alle kostenlos.",
        "Everything stays free for everyone.",
    );
    pub const STORE_THANK_YOU_GIFTS: Self = Self::new(
        "Als Dankeschön bekommst du ein Herz in „Über“ und zusätzliche App-Icons.",
        "As a thank-you, you get a heart in About and extra app icons.",
    );
    pub const SUPPORT_WITH_PRICE: Self = Self::new("Mit %@ unterstützen", "Support with %@");
    pub const ONE_TIME_PURCHASE: Self = Self::new(
        "Einmaliger Kauf über deinen App-Store. Nichts verlängert sich.",
        "One-time purchase through your app store. Nothing renews.",
    );
    pub const ONE_TIME_PURCHASE_APP_STORE: Self = Self::new(
        "Einmaliger Kauf über den App Store. Nichts verlängert sich.",
        "One-time purchase through the App Store. Nothing renews.",
    );
    pub const MAYBE_LATER: Self = Self::new("Vielleicht später", "Maybe later");
    pub const RESTORE_PURCHASES: Self = Self::new("Käufe wiederherstellen", "Restore Purchases");
    pub const TIP_COFFEE: Self = Self::new("Ein Kaffee", "A coffee");
    pub const TIP_CAKE: Self = Self::new("Kaffee und Kuchen", "Coffee and cake");
    pub const TIP_MOVIE: Self = Self::new("Filmabend", "Movie night");
    pub const THANKS_TITLE: Self = Self::new("Danke. Du bist dabei.", "Thank you. You are in.");
    pub const THANKS_BODY: Self = Self::new(
        "Dein Kaffee hilft uns, Swiftly für alle kostenlos zu halten. Das ist neu für dich.",
        "Your coffee helps us keep Swiftly free for everyone. Here is what is new for you.",
    );
    pub const GIFT_ICONS_TITLE: Self = Self::new("Unterstützer-App-Icons", "Supporter app icons");
    pub const GIFT_ICONS_DETAIL: Self =
        Self::new("Neue Icons für die App", "New icons for the app");
    pub const GIFT_HEART_TITLE: Self = Self::new("Ein Herz in „Über“", "A heart in About");
    pub const GIFT_HEART_DETAIL: Self =
        Self::new("Neben deiner Versionsnummer", "Next to your version number");
    pub const CHOOSE_APP_ICON: Self = Self::new("App-Icon wählen", "Choose an app icon");
    pub const DONE: Self = Self::new("Fertig", "Done");
    /// `%lld` is the watched hours; the card only appears from 2 hours on.
    pub const CARD_WATCHED_HOURS: Self = Self::new(
        "Du hast mit Swiftly %lld Stunden geschaut.",
        "You have watched %lld hours with Swiftly.",
    );
    pub const CARD_ASK: Self = Self::new(
        "Wenn es dir einen Kaffee wert ist, freuen wir uns sehr.",
        "If it earns a coffee, we would love that.",
    );
    pub const CARD_SUPPORT: Self = Self::new("Unterstützen", "Support");
    pub const NOT_NOW: Self = Self::new("Nicht jetzt", "Not now");
    pub const DONT_SHOW_AGAIN: Self = Self::new("Nicht mehr zeigen", "Don’t show again");
    pub const SUPPORTER_BADGE: Self = Self::new("Unterstützer", "Supporter");
    pub const THANK_YOU: Self = Self::new("Danke", "Thank you");
    pub const APP_ICON: Self = Self::new("App-Icon", "App icon");
    pub const SUPPORTER_ICONS: Self = Self::new("Unterstützer-Icons", "Supporter icons");

    /// The card names the hours only from here on.
    pub const CARD_MINIMUM_HOURS: i64 = 2;

    /// Every text above, for catalogue checks. Keys are unique.
    pub const ALL: [SupportCopy; 31] = [
        Self::SUPPORT_SWIFTLY,
        Self::SAY_THANKS,
        Self::SAY_THANKS_FREE_FOR_ALL,
        Self::SHEET_INTRO,
        Self::FREE_FOR_EVERYONE,
        Self::STORE_THANK_YOU_GIFTS,
        Self::SUPPORT_WITH_PRICE,
        Self::ONE_TIME_PURCHASE,
        Self::ONE_TIME_PURCHASE_APP_STORE,
        Self::MAYBE_LATER,
        Self::RESTORE_PURCHASES,
        Self::TIP_COFFEE,
        Self::TIP_CAKE,
        Self::TIP_MOVIE,
        Self::THANKS_TITLE,
        Self::THANKS_BODY,
        Self::GIFT_ICONS_TITLE,
        Self::GIFT_ICONS_DETAIL,
        Self::GIFT_HEART_TITLE,
        Self::GIFT_HEART_DETAIL,
        Self::CHOOSE_APP_ICON,
        Self::DONE,
        Self::CARD_WATCHED_HOURS,
        Self::CARD_ASK,
        Self::CARD_SUPPORT,
        Self::NOT_NOW,
        Self::DONT_SHOW_AGAIN,
        Self::SUPPORTER_BADGE,
        Self::THANK_YOU,
        Self::APP_ICON,
        Self::SUPPORTER_ICONS,
    ];
}

/// The three tips, in display order (smallest first). Product ids are the same in App Store
/// Connect and the Play Console; prices come from the store.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SupportTip {
    /// A coffee.
    Coffee,
    /// Coffee and cake.
    Cake,
    /// Movie night.
    Movie,
}

impl SupportTip {
    /// In sheet order.
    pub const ORDERED: [SupportTip; 3] = [Self::Coffee, Self::Cake, Self::Movie];

    /// The store product id.
    pub fn product_id(self) -> &'static str {
        match self {
            Self::Coffee => "de.paulherter.swiftly.tip.coffee",
            Self::Cake => "de.paulherter.swiftly.tip.cake",
            Self::Movie => "de.paulherter.swiftly.tip.movie",
        }
    }

    /// The tip with this product id.
    pub fn from_product_id(id: &str) -> Option<Self> {
        Self::ORDERED.into_iter().find(|t| t.product_id() == id)
    }

    /// The title text.
    pub fn title(self) -> SupportCopy {
        match self {
            Self::Coffee => SupportCopy::TIP_COFFEE,
            Self::Cake => SupportCopy::TIP_CAKE,
            Self::Movie => SupportCopy::TIP_MOVIE,
        }
    }

    /// The symbol in front of the title.
    pub fn emoji(self) -> &'static str {
        match self {
            Self::Coffee => "☕",
            Self::Cake => "🍰",
            Self::Movie => "🎬",
        }
    }
}

/// The Apple product ids of the supporter plans (`SupportProductID`).
pub struct SupportProductId;

impl SupportProductId {
    /// Auto-renewable subscription, group "Swiftly Supporter", one month.
    pub const MONTHLY: &'static str = "de.paulherter.swiftly.supporter.monthly";
    /// Non-consumable, bought once.
    pub const LIFETIME: &'static str = "de.paulherter.swiftly.supporter.lifetime";

    /// Plans and tips, in the order the sheet shows them.
    pub fn all() -> Vec<&'static str> {
        let mut ids = vec![Self::MONTHLY, Self::LIFETIME];
        ids.extend(SupportTip::ORDERED.iter().map(|t| t.product_id()));
        ids
    }

    /// Which plan a product id stands for; `None` for anything that is not ours.
    pub fn plan(id: &str) -> Option<SupportPlan> {
        match id {
            Self::MONTHLY => Some(SupportPlan::Monthly),
            Self::LIFETIME => Some(SupportPlan::Lifetime),
            _ => SupportTip::from_product_id(id).map(|_| SupportPlan::Tip),
        }
    }
}

/// The six supporter icons: the regular play mark in other colours. The raw value is the asset
/// name in the catalogue and of the `.icns` in the Mac bundle; renaming one breaks the icon.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SupporterIcon {
    /// Heart.
    Heart,
    /// Aurora.
    Aurora,
    /// Gold.
    Gold,
    /// Light.
    Light,
    /// Night.
    Night,
    /// Coffee.
    Coffee,
}

impl SupporterIcon {
    /// In picker order.
    pub const ALL: [SupporterIcon; 6] = [
        Self::Heart,
        Self::Aurora,
        Self::Gold,
        Self::Light,
        Self::Night,
        Self::Coffee,
    ];

    /// The asset name (stored in `support.appIcon` on the Mac).
    pub fn raw(self) -> &'static str {
        match self {
            Self::Heart => "AppIcon-Heart",
            Self::Aurora => "AppIcon-Aurora",
            Self::Gold => "AppIcon-Gold",
            Self::Light => "AppIcon-Light",
            Self::Night => "AppIcon-Night",
            Self::Coffee => "AppIcon-Coffee",
        }
    }

    /// The icon with this asset name.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|i| i.raw() == raw)
    }

    /// The German name, also the catalogue key.
    pub fn name_key(self) -> &'static str {
        match self {
            Self::Heart => "Herz",
            Self::Aurora => "Aurora",
            Self::Gold => "Gold",
            Self::Light => "Hell",
            Self::Night => "Nacht",
            Self::Coffee => "Kaffee",
        }
    }
}

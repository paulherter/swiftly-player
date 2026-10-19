import JellyfinKit

/// **Texts and addresses only direct builds show** (Linux, Windows, the Android APK from
/// GitHub). They live in this module so store builds, which never link it, do not contain
/// the website link or the word "supporter key" at all.
public enum DirectSupport {
    public static let websiteURL = "https://swiftlyplayer.com/supporter"
    public static let contactEmail = "info@swiftlyplayer.com"
}

extension SupportCopy {
    public static let keyThankYouGifts = SupportCopy(
        de: "Mit deinem Unterstützer-Schlüssel bekommst du ein Herz in „Über“ und zusätzliche App-Icons.",
        en: "With your supporter key you get a heart in About and extra app icons.")
    public static let supportOnWebsite = SupportCopy(de: "Auf der Website unterstützen",
                                                     en: "Support on the website")
    public static let opensWebsite = SupportCopy(de: "Öffnet swiftlyplayer.com/supporter im Browser.",
                                                 en: "Opens swiftlyplayer.com/supporter in your browser.")
    public static let haveKey = SupportCopy(de: "Ich habe einen Unterstützer-Schlüssel",
                                            en: "I have a supporter key")
    public static let keyTitle = SupportCopy(de: "Unterstützer-Schlüssel", en: "Supporter key")
    public static let keyExplanation = SupportCopy(
        de: "Den Schlüssel bekommst du, nachdem du uns auf der Website unterstützt hast: auf der Danke-Seite und per E-Mail.",
        en: "You get your key after supporting us on the website, on the thank-you page and by email.")
    public static let keyInvalid = SupportCopy(
        de: "Dieser Schlüssel passt nicht. Prüf ihn auf Tippfehler und versuch es noch einmal.",
        en: "This key does not fit. Check it for typos and try again.")
    public static let activate = SupportCopy(de: "Aktivieren", en: "Activate")
    public static let keyAccepted = SupportCopy(de: "Schlüssel angenommen. Danke, du bist dabei.",
                                                en: "Key accepted. Thank you, you are in.")
    /// Followed by `DirectSupport.contactEmail` as a link.
    public static let lostKey = SupportCopy(de: "Schlüssel verloren? Schreib uns an", en: "Lost your key? Write to")
    /// Already in the app catalog (English "Next").
    public static let next = SupportCopy(de: "Weiter", en: "Next")

    /// Every direct-only text, for catalog checks.
    public static let directOnly: [SupportCopy] = [
        keyThankYouGifts, supportOnWebsite, opensWebsite, haveKey, keyTitle, keyExplanation,
        keyInvalid, activate, keyAccepted, lostKey, next,
    ]
}

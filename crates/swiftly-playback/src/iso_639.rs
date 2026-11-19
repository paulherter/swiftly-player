//! The two-letter language codes (ISO 639-1) and their three-letter forms (ISO 639-2: the terminology code `deu` and the
//! bibliographic code `ger`), so a file that spells a language one way matches a wish spelled the other way for every
//! language, not only for those the original-language table lists.

/// (639-1, 639-2/T, 639-2/B); the bibliographic code is the terminology code where they do not differ.
const CODES: &[(&str, &str, &str)] = &[
    ("aa", "aar", "aar"),
    ("ab", "abk", "abk"),
    ("ae", "ave", "ave"),
    ("af", "afr", "afr"),
    ("ak", "aka", "aka"),
    ("am", "amh", "amh"),
    ("an", "arg", "arg"),
    ("ar", "ara", "ara"),
    ("as", "asm", "asm"),
    ("av", "ava", "ava"),
    ("ay", "aym", "aym"),
    ("az", "aze", "aze"),
    ("ba", "bak", "bak"),
    ("be", "bel", "bel"),
    ("bg", "bul", "bul"),
    ("bh", "bih", "bih"),
    ("bi", "bis", "bis"),
    ("bm", "bam", "bam"),
    ("bn", "ben", "ben"),
    ("bo", "bod", "tib"),
    ("br", "bre", "bre"),
    ("bs", "bos", "bos"),
    ("ca", "cat", "cat"),
    ("ce", "che", "che"),
    ("ch", "cha", "cha"),
    ("co", "cos", "cos"),
    ("cr", "cre", "cre"),
    ("cs", "ces", "cze"),
    ("cu", "chu", "chu"),
    ("cv", "chv", "chv"),
    ("cy", "cym", "wel"),
    ("da", "dan", "dan"),
    ("de", "deu", "ger"),
    ("dv", "div", "div"),
    ("dz", "dzo", "dzo"),
    ("ee", "ewe", "ewe"),
    ("el", "ell", "gre"),
    ("en", "eng", "eng"),
    ("eo", "epo", "epo"),
    ("es", "spa", "spa"),
    ("et", "est", "est"),
    ("eu", "eus", "baq"),
    ("fa", "fas", "per"),
    ("ff", "ful", "ful"),
    ("fi", "fin", "fin"),
    ("fj", "fij", "fij"),
    ("fo", "fao", "fao"),
    ("fr", "fra", "fre"),
    ("fy", "fry", "fry"),
    ("ga", "gle", "gle"),
    ("gd", "gla", "gla"),
    ("gl", "glg", "glg"),
    ("gn", "grn", "grn"),
    ("gu", "guj", "guj"),
    ("gv", "glv", "glv"),
    ("ha", "hau", "hau"),
    ("he", "heb", "heb"),
    ("hi", "hin", "hin"),
    ("ho", "hmo", "hmo"),
    ("hr", "hrv", "hrv"),
    ("ht", "hat", "hat"),
    ("hu", "hun", "hun"),
    ("hy", "hye", "arm"),
    ("hz", "her", "her"),
    ("ia", "ina", "ina"),
    ("id", "ind", "ind"),
    ("ie", "ile", "ile"),
    ("ig", "ibo", "ibo"),
    ("ii", "iii", "iii"),
    ("ik", "ipk", "ipk"),
    ("io", "ido", "ido"),
    ("is", "isl", "ice"),
    ("it", "ita", "ita"),
    ("iu", "iku", "iku"),
    ("ja", "jpn", "jpn"),
    ("jv", "jav", "jav"),
    ("ka", "kat", "geo"),
    ("kg", "kon", "kon"),
    ("ki", "kik", "kik"),
    ("kj", "kua", "kua"),
    ("kk", "kaz", "kaz"),
    ("kl", "kal", "kal"),
    ("km", "khm", "khm"),
    ("kn", "kan", "kan"),
    ("ko", "kor", "kor"),
    ("kr", "kau", "kau"),
    ("ks", "kas", "kas"),
    ("ku", "kur", "kur"),
    ("kv", "kom", "kom"),
    ("kw", "cor", "cor"),
    ("ky", "kir", "kir"),
    ("la", "lat", "lat"),
    ("lb", "ltz", "ltz"),
    ("lg", "lug", "lug"),
    ("li", "lim", "lim"),
    ("ln", "lin", "lin"),
    ("lo", "lao", "lao"),
    ("lt", "lit", "lit"),
    ("lu", "lub", "lub"),
    ("lv", "lav", "lav"),
    ("mg", "mlg", "mlg"),
    ("mh", "mah", "mah"),
    ("mi", "mri", "mao"),
    ("mk", "mkd", "mac"),
    ("ml", "mal", "mal"),
    ("mn", "mon", "mon"),
    ("mr", "mar", "mar"),
    ("ms", "msa", "may"),
    ("mt", "mlt", "mlt"),
    ("my", "mya", "bur"),
    ("na", "nau", "nau"),
    ("nb", "nob", "nob"),
    ("nd", "nde", "nde"),
    ("ne", "nep", "nep"),
    ("ng", "ndo", "ndo"),
    ("nl", "nld", "dut"),
    ("nn", "nno", "nno"),
    ("no", "nor", "nor"),
    ("nr", "nbl", "nbl"),
    ("nv", "nav", "nav"),
    ("ny", "nya", "nya"),
    ("oc", "oci", "oci"),
    ("oj", "oji", "oji"),
    ("om", "orm", "orm"),
    ("or", "ori", "ori"),
    ("os", "oss", "oss"),
    ("pa", "pan", "pan"),
    ("pi", "pli", "pli"),
    ("pl", "pol", "pol"),
    ("ps", "pus", "pus"),
    ("pt", "por", "por"),
    ("qu", "que", "que"),
    ("rm", "roh", "roh"),
    ("rn", "run", "run"),
    ("ro", "ron", "rum"),
    ("ru", "rus", "rus"),
    ("rw", "kin", "kin"),
    ("sa", "san", "san"),
    ("sc", "srd", "srd"),
    ("sd", "snd", "snd"),
    ("se", "sme", "sme"),
    ("sg", "sag", "sag"),
    ("si", "sin", "sin"),
    ("sk", "slk", "slo"),
    ("sl", "slv", "slv"),
    ("sm", "smo", "smo"),
    ("sn", "sna", "sna"),
    ("so", "som", "som"),
    ("sq", "sqi", "alb"),
    ("sr", "srp", "srp"),
    ("ss", "ssw", "ssw"),
    ("st", "sot", "sot"),
    ("su", "sun", "sun"),
    ("sv", "swe", "swe"),
    ("sw", "swa", "swa"),
    ("ta", "tam", "tam"),
    ("te", "tel", "tel"),
    ("tg", "tgk", "tgk"),
    ("th", "tha", "tha"),
    ("ti", "tir", "tir"),
    ("tk", "tuk", "tuk"),
    ("tl", "tgl", "tgl"),
    ("tn", "tsn", "tsn"),
    ("to", "ton", "ton"),
    ("tr", "tur", "tur"),
    ("ts", "tso", "tso"),
    ("tt", "tat", "tat"),
    ("tw", "twi", "twi"),
    ("ty", "tah", "tah"),
    ("ug", "uig", "uig"),
    ("uk", "ukr", "ukr"),
    ("ur", "urd", "urd"),
    ("uz", "uzb", "uzb"),
    ("ve", "ven", "ven"),
    ("vi", "vie", "vie"),
    ("vo", "vol", "vol"),
    ("wa", "wln", "wln"),
    ("wo", "wol", "wol"),
    ("xh", "xho", "xho"),
    ("yi", "yid", "yid"),
    ("yo", "yor", "yor"),
    ("za", "zha", "zha"),
    ("zh", "zho", "chi"),
    ("zu", "zul", "zul"),
];

/// Three-letter codes of a language that a two-letter code covers as a macrolanguage: the varieties files name directly
/// (Mandarin and Cantonese for Chinese, Nynorsk for Norwegian, the individual codes of Arabic, Persian, Malay, Estonian,
/// Latvian, Swahili and Uzbek).
const MACROLANGUAGE: &[(&str, &str)] = &[
    ("cmn", "zh"),
    ("yue", "zh"),
    ("nno", "no"),
    ("nn", "no"),
    ("arb", "ar"),
    ("pes", "fa"),
    ("zsm", "ms"),
    ("zlm", "ms"),
    ("ekk", "et"),
    ("lvs", "lv"),
    ("swh", "sw"),
    ("uzn", "uz"),
];

/// The two-letter code for a two- or three-letter code in lower case (`deu`, `ger` and `de` give `de`; `cmn` gives `zh`).
/// `None` for a code the list does not know.
#[must_use]
pub fn two_letter(code: &str) -> Option<&'static str> {
    if let Some((_, two)) = MACROLANGUAGE.iter().find(|(from, _)| *from == code) {
        return Some(two);
    }
    CODES
        .iter()
        .find(|(two, terminology, bibliographic)| {
            *two == code || *terminology == code || *bibliographic == code
        })
        .map(|(two, _, _)| *two)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_language_matches_in_all_its_spellings() {
        for (two, terminology, bibliographic) in CODES {
            for spelling in [two, terminology, bibliographic] {
                let want = if *two == "nn" { "no" } else { *two };
                assert_eq!(two_letter(spelling), Some(want), "{spelling}");
            }
        }
    }

    #[test]
    fn the_list_has_no_duplicate_codes() {
        let mut seen = std::collections::HashSet::new();
        for (two, terminology, bibliographic) in CODES {
            assert!(seen.insert(*two), "{two}");
            assert!(seen.insert(*terminology), "{terminology}");
            if bibliographic != terminology {
                assert!(seen.insert(*bibliographic), "{bibliographic}");
            }
        }
    }

    #[test]
    fn macrolanguages_and_unknown_codes() {
        assert_eq!(two_letter("cmn"), Some("zh"));
        assert_eq!(two_letter("yue"), Some("zh"));
        assert_eq!(two_letter("nno"), Some("no"));
        assert_eq!(two_letter("xyz"), None);
        assert_eq!(two_letter(""), None);
    }
}

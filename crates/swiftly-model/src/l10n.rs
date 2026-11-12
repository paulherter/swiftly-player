/// Hook for the few user-visible strings the derived properties produce.
///
/// The keys are the German source strings of the Swift catalog
/// (`Resources/*.lproj/Localizable.strings`), with `%lld` marking each integer
/// argument in order, e.g. `"S%lld · F%lld"` with `[1, 3]`.
pub trait Localizer {
    /// Translate `key`, substituting each `%lld` with the next entry of `args`.
    fn text(&self, key: &str, args: &[i64]) -> String;

    /// Name of a track language in the interface language
    /// (`TrackLabel.language`, JellyfinKit/TrackLabel.swift:61), `None` if
    /// there is no language.
    fn language_name(&self, raw: Option<&str>) -> Option<String>;
}

/// The German source strings as they are, used when no translation is wanted.
///
/// Language names fall back to the tail of `TrackLabel.language`
/// (TrackLabel.swift:69-70): codes in capitals, words capitalised.
#[derive(Debug, Clone, Copy, Default)]
pub struct Source;

/// Replace each `%lld` in `key` with the next argument.
pub(crate) fn fill(key: &str, args: &[i64]) -> String {
    let mut out = String::with_capacity(key.len() + 4);
    let mut rest = key;
    let mut args = args.iter();
    while let Some(at) = rest.find("%lld") {
        out.push_str(&rest[..at]);
        match args.next() {
            Some(n) => out.push_str(&n.to_string()),
            None => out.push_str("%lld"),
        }
        rest = &rest[at + 4..];
    }
    out.push_str(rest);
    out
}

fn looks_like_code(text: &str) -> bool {
    let mut parts = text.split(['-', '_']).filter(|p| !p.is_empty());
    let Some(first) = parts.next() else {
        return false;
    };
    (2..=3).contains(&first.chars().count())
        && text
            .chars()
            .all(|c| (c.is_ascii() && c.is_alphabetic()) || c == '-' || c == '_')
        && parts.all(|p| p.chars().all(|c| c.is_ascii() && c.is_alphanumeric()))
}

fn capitalised(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

impl Localizer for Source {
    fn text(&self, key: &str, args: &[i64]) -> String {
        fill(key, args)
    }

    fn language_name(&self, raw: Option<&str>) -> Option<String> {
        let raw = raw?.trim();
        if raw.is_empty() {
            return None;
        }
        Some(if looks_like_code(raw) {
            raw.to_uppercase()
        } else {
            capitalised(raw)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fills_in_order() {
        assert_eq!(fill("S%lld · F%lld", &[1, 3]), "S1 · F3");
        assert_eq!(fill("%lld neue Folgen", &[8]), "8 neue Folgen");
        assert_eq!(fill("Stereo", &[]), "Stereo");
    }

    #[test]
    fn language_fallback() {
        assert_eq!(Source.language_name(Some("ger")).as_deref(), Some("GER"));
        assert_eq!(
            Source.language_name(Some("deutsch")).as_deref(),
            Some("Deutsch")
        );
        assert_eq!(Source.language_name(Some("  ")), None);
        assert_eq!(Source.language_name(None), None);
    }
}

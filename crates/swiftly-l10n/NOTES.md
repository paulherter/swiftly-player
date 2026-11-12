# swiftly-l10n notes

## Findings in the translation sources (as of this commit)

Placeholder mismatches between languages: **none**. Plural categories missing for the language's CLDR
needs: **none**.

Source conflicts (same key and language in two sources with different text; the first rule that
applies is kept):

- `"%lld Filme"` de, en and `"%lld Serien"` de, en and `"%lld Staffeln"` de, en: the app
  `Localizable.xcstrings` holds a plain string (`"%lld Filme"`, so "1 Filme") while the package
  `.stringsdict` has one/other. The Rust catalogue keeps the plural form. **The Swift app shows
  "1 Filme"/"1 Serien"/"1 Staffeln" in German and English for a count of 1** if the xcstrings entry is
  what the view resolves; worth fixing in the xcstrings (left for the maintainer, not touched here).
- `"Normal"` ru: app says "Обычный", package says "Обычная" (grammatical gender of the thing it
  describes). Same German key, two meanings. The catalogue keeps the app value; the package one is
  lost in the merge. A context key would be needed to carry both.

Shape differences (German is plain, Russian is plural, or the reverse); harmless, listed so nobody is
surprised: `%lld Min` (de plural, ru plain), `%lld Staffeln anfragen`, `%lld Titel auf diesem Gerät`,
`%lld Titel auf diesem Mac`, `%lld Titel bleiben auf dem Gerät`, `%lld Titel bleiben auf diesem Mac`,
`%lld Titel spielbar`, `%lld Treffer` (en and ru), `Du hast mit Swiftly %lld Stunden geschaut.` (ru).
German and English strings for these are plain, so "1 Titel spielbar" style output is what the app
shows today.

`stale` entries in the xcstrings (9) are kept; their keys are unused in the Swift code but cost nothing.

## Not done / leftovers

- Only de/en/ru exist in the sources. Plural rules for the other 10+ languages are verified by tests
  but have no catalogue text yet.
- `ErrorText` and `WhatsNew` (mentioned for this crate in ARCHITECTURE D3) are not ported here.
- `Text::Plural` supports the `%#@var@` stringsdict form with a single variable only; the generator
  fails loudly on anything else (none exists today).
- Device variations in xcstrings (iPhone/Mac wording) are not supported; the generator errors if one
  appears (none today).
- `%@` with a number prints the number with Rust formatting (no locale grouping); `%g` is the shortest form.

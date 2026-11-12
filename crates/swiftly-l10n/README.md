# swiftly-l10n

Localisation for the Swiftly Rust rebuild. **German wording is the key**, like Swift's `String(localized:)`.

## Catalogue

`src/catalog_data.rs` is generated and committed. Sources:

| Source | Keys per language (de / en / ru) |
|---|---|
| `Sources/Shared/Localizable.xcstrings` | 996 / 996 / 996 (20 keys with plural variations) |
| `Sources/Shared/InfoPlist.xcstrings` | 3 / 3 / 3 (kept apart: `Catalog::info_plist`) |
| JellyfinKit `*.lproj/Localizable.strings` | 139 / 139 / 139 |
| JellyfinKit `*.lproj/Localizable.stringsdict` | 4 / 4 / 5 |

Merged: 1074 keys, 1074 per language (935 only in the app, 73 only in the package, 66 in both).
Merge rule: app first; a plural variation beats a plain string of the same key; differences are listed
by `--report` and in `NOTES.md`.

```sh
export PATH=$HOME/.cargo/bin:$PATH
cargo run -p swiftly-l10n --bin gen_catalog             # regenerate
cargo run -p swiftly-l10n --bin gen_catalog -- --check  # CI: fails when the file differs from the sources
cargo run -p swiftly-l10n --bin gen_catalog -- --report # source conflicts and translation findings
```

(`gen_catalog` is a bin rather than a `build.rs` so the generated file is reviewable in diffs and the
crate builds without the Apple sources present.)

## Runtime

```rust
use swiftly_l10n::{Arg, Locale, Translator};
let ru = Translator::new(Locale::parse("ru-RU"));
ru.t("Abbrechen");
ru.t_args("%1$@ von %2$@", &["3".into(), "5".into()]);       // positional placeholders
ru.plural("%lld Folgen", 22, &[]);                            // "22 эпизода"; n is argument 1
ru.lookup("Unbekannt").resolution;                            // Resolution::Missing, never a panic
```

- Fallback chain: language, then English, then German; a key that is not in the catalogue returns the
  key itself (the German text) and is reported by `lookup` / `try_*`.
- The plural rule follows the language of the text actually used.
- Plural rules (CLDR 44, integers): de en nl sv tr and most others (`one`/`other`), fr pt (0 and 1 are
  `one`, millions `many`), pt-PT, es it ca, ru uk be, pl, cs sk, hr sr bs, sl, lt, lv, ro, ar (all six),
  he, hi bn, ja zh ko vi th id (`other` only). Tests: `tests/plural.rs`.
- Placeholders: `%@ %s %d %i %u %lld %ld %f %.2f %05d %x %c %%` and `%1$@`; a missing argument stays
  visible as written.
- Free functions `t`, `t_args`, `plural` use a process-wide locale (`set_locale`, German by default).

## Checks

`check::findings` compares every language with German: placeholder positions and classes, plural shape
(plain vs plural) and the plural categories each language needs. Violations are reported, not hidden.

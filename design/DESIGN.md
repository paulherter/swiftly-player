# Swiftly design system: tokens

One source of truth: `design/tokens.json`. Everything named here is a token named by its role, never by its value. Swift (`Sources/Shared/Tokens.generated.swift`), Kotlin (`Android/shared/.../Tokens.kt`) and Rust (`crates/swiftly-design/src/tokens_generated.rs`) are generated from it:

```sh
cargo run -p swiftly-design --bin gen_tokens -- --semantic          # write
cargo run -p swiftly-design --bin gen_tokens -- --semantic --check  # CI: exits 1 when a generated file differs
```

Never edit a generated file by hand; change `tokens.json`, regenerate, commit all of it together.

Values are what the apps use today (no redesign). The iPhone value is the base; where platforms differed for the same role, the iPhone value won (see "Conflicts"). Layout sets: **touch** (iPhone, iPad, Android phone and tablet), **desktop** (Mac, Windows, Linux), **tv** (Apple TV in points; Android TV uses half of every tv value in dp). A set shown as `-` does not have that token. The app is dark only, so `light` equals `dark`.

Rules that apply to every token:
1. Use a token or add one with its role; never type a raw colour, radius, spacing or font size in a view.
2. Neutral is structure, colour is meaning: the accent carries state only (chosen, progress, links, Direct Play proof).
3. Flat: surface on base, no card in a card, shadows only for things that float above a picture.
4. Every interactive part has all states (normal, hover on desktop, pressed, focus, selected, disabled, loading); a state changes surface, scale or opacity, never layout or weight.
5. Motion is sparse: transform and opacity only, exits faster than entries, frequent things do not animate, Reduce Motion turns movement into `motion.reduced`.

Font: Inter Variable (free font; never SF Pro). Icons are a separate system (`design/icons/`).

## Colour

| Token | Value | Use | Avoid |
|---|---|---|---|
| `surface.base` | #0A0A0B | Page background of every screen; gradients run out into this colour. | Cards or controls: those sit one level up. |
| `surface.group` | #1E1E1E | Settings groups and cards that lie directly on surface.base. | A card inside a card. |
| `surface.control` | #262626 | Anything you can touch: buttons, fields, chips, sheets, desktop sidebar. | Page background; text-only rows. |
| `surface.raised` | #303030 | What lies on a control: active chip, hover on a control, hint strip. | As the main surface of a page (too faint at 3 m). |
| `surface.pressed` | #3A3A3A | Pressed secondary button (touch). | Rest state of anything. |
| `surface.selected` | #FFFFFF at 8% | Selected or playing row. | Accent-coloured fills: the selected state stays neutral, the accent sits in the glyph. |
| `surface.translucent` | #FFFFFF at 8% | Buttons and highlighted rows over image colour: picks up the colour beneath. | On a flat page without image colour (use surface.control). |
| `surface.hover` | #FFFFFF at 6% | Pointer hover and keyboard-focus surface on desktop. | Touch and TV (no hover there). |
| `surface.focus` | #FFFFFF at 12% | TV focus surface on rows and chips, readable at 3 m. | Touch and desktop. |
| `surface.overlay` | #000000 at 72% | Dimming layer behind a modal overlay. | As a card or control surface. Not yet used by name in app code (design-file colour `shade`); adopt when the next overlay is built. |
| `surface.mark` | #17181B | Plate under the service marks. | Anything else. |
| `text.primary` | #FFFFFF | Everything that is read, icons, text on translucent surfaces. | Hints and metadata (use secondary or tertiary). |
| `text.secondary` | #CCCCCC | Running text, values, descriptions. | Replacing it with white 80%: opacity changes its look on image colour. |
| `text.tertiary` | #989898 | Third line, placeholders, shortcuts, group titles, disabled text. | Anything the user must read to act. |
| `text.on-accent` | #061212 | Text on an accent surface. | Text on any neutral surface. |
| `accent.selection` | #50D5DA | State only: chosen, progress, links, Direct Play proof. Default of the Look; a Look may replace it at runtime. | Rank, decoration, surfaces, labels. |
| `accent.selection-light` | #7AE6EA | Selected filter chip while focused, TV only. | Everywhere else. |
| `accent.selection-quiet` | #113435 | Surface under accent text: Direct Play chip. | Large areas. |
| `border.hairline` | #FFFFFF at 7% | Separator between rows; alpha because it also lies over posters. | Buttons, fields, pills. |
| `border.edge` | #FFFFFF at 12% | 1 pt edge of panels and menus; toggle track when off. | Buttons, fields, pills, tiles. |
| `border.tile` | #FFFFFF at 8% | Hairline around a tile in the look picker. | Content tiles (they carry no edge). |
| `state.warning` | #E8833A | Something waits for someone. | Errors. |
| `state.error` | #EF6567 | Something went wrong. | Warnings. |
| `state.focus-fill` | #FFFFFF | TV: the one focused thing (buttons, tabs, keys, player icons), dark text on it. | Touch and desktop. |
| `scrim.button` | #000000 at 40% | Dark round button over an image. | On flat surfaces. |
| `scrim.glass` | #000000 at 18% | Quiet glass behind the player bar buttons. | Anywhere without a material under it. |
| `scrim.glass-edge` | #FFFFFF at 10% | Hairline on the quiet glass. | Elsewhere. |
| `ring.track` | #FFFFFF at 30% | Light track of the download ring. | Progress bars. |
| `ring.progress` | #FFFFFF at 18% | Progress ring on episode cards. | Download ring. |
| `badge.resolution` | #7E3BB7 | Resolution badge. | Other badges. |
| `badge.range` | #784C28 | Dynamic range badge. | Other badges. |
| `badge.video` | #3F4C9D | Video codec badge. | Other badges. |
| `badge.audio` | #3B3B40 | Audio badge. | Other badges. |

## Type

Size / weight / tracking in points. Base = touch.

| Token | touch | desktop | tv | Use | Avoid |
|---|---|---|---|---|---|
| `title.large` | 34 bold -0.7 | 30 bold -0.5 | 56 bold -1.176 | Large page title, scrolls away. | Section titles. |
| `title.subpage` | 28 bold -0.4 | 28 bold -0.6 | 44 semibold -0.616 | Title of a subpage. | Page titles. |
| `title.detail` | - | 44 extrabold -1.2 | - | Desktop film and series title over the wide hero. | Phones (they use a logo or title.large). |
| `title.player` | - | - | 56 bold -1.2 | TV player title. | Other sets. |
| `heading.section` | 22 bold -0.308 | 22 bold -0.484 | 44 bold -0.528 | Rail titles on Start, group titles. | Row titles. |
| `heading.rail` | 20 semibold -0.24 | 20 semibold -0.24 | 44 bold -0.528 | Rail headings inside pages. | Section titles. |
| `heading.category` | 17 semibold -0.136 | 17 semibold -0.136 | 34 semibold -0.272 | Category and card headings. | Body text. |
| `label.row-title` | 15 semibold | 15 semibold | 30 semibold | Row titles and button text. | Running text. |
| `label.button` | 15 semibold | 15 semibold | 30 semibold | Button text. | Long text. |
| `body.default` | 15 regular | 15 regular | 30 regular | Running text. | Titles. |
| `label.tile` | 13 medium | 13 medium | 26 medium | Text on and under tiles. | Titles. |
| `label.tile-caption` | - | 14 semibold | - | Desktop tile caption. | Touch and TV. |
| `label.tile-focused` | - | - | 26 semibold | Tile caption while focused on TV. | Other sets. |
| `label.bar-title` | - | 14 semibold | - | Desktop toolbar title after scrolling. | Other sets. |
| `caption.small` | 12 regular | 12 regular | 24 regular | Small notes and metadata. | Anything the user must act on. |
| `overline.group` | 11 semibold 1.54 caps | 11 semibold 1.54 caps | 22 semibold 3.08 caps | Group title in capitals. | Long labels. |
| `overline.badge` | 10 semibold 1 | 10 semibold 1 | 20 semibold 2 | Badge text. | Anything longer than a word. |

## Spacing scale

`space.xs` 4 · `space.sm` 8 · `space.md` 12 · `space.lg` 16 · `space.xl` 24

The scale is for new work. Roles below carry the exact values the apps use (18 and 20 are not on a 4 pt grid; they stay as they are).

## Spacing roles

| Token | touch | desktop | tv | Use | Avoid |
|---|---|---|---|---|---|
| `space.page` | 18 | 36 | 80 | Horizontal page margin. | Inside cards. |
| `space.page-wide` | 28 | - | - | Page margin on wide touch layouts (tablet). | Phones. |
| `space.header-top` | 28 | - | 60 | Space above the page header. | Below the header. |
| `space.content-top` | - | 58 | 196 | Desktop content start under the toolbar; TV under the top bar. | Touch. |
| `space.sidebar-top` | - | 52 | - | Gap between the top edge of the desktop sidebar (window buttons area on the Mac) and the first sidebar row, no wordmark above it. The macOS unified-toolbar band: the window buttons sit 19 to 33 pt from the top (measured on macOS 26), the first row starts 19 pt under them. | Content start (space.content-top); touch, TV. |
| `space.tile-gap` | 12 | 16 | 40 | Gap between tiles in a row or grid. | Between rails. |
| `space.rail-gap` | 40 | 40 | 72 | Vertical gap between rails. | Between tiles. |
| `space.value-gap` | 44 | 44 | 44 | Gap between a value and its rail. | Other gaps. |
| `space.sheet-inset` | 24 | 24 | 24 | Inner margin of a sheet. | Page margin. |
| `space.grid-row` | 32 | 24 | 58 | Vertical gap in a poster grid. | Rails. |
| `space.group-top` | 48 | 18 | 36 | Space above a settings group. | Between cards. |
| `space.card-gap` | 32 | 14 | - | Space between settings cards. | Inside a card. |
| `space.block-gap` | 20 | - | - | Gap between blocks on the detail page. | Rails. |
| `space.action-gap` | 16 | - | - | Gap between action buttons. | Tiles. |
| `space.settings-columns` | - | - | 72 | Gap between the two settings columns on TV. | Touch. |
| `space.title-gap` | - | - | 28 | Gap under a TV title. | Touch. |

## Radius

| Token | touch | desktop | tv | Use | Avoid |
|---|---|---|---|---|---|
| `radius.small` | 8 | 8 | 14 | Small chips, badges. | Cards. |
| `radius.control` | 10 | 10 | 16 | Buttons. | Cards and sheets. |
| `radius.tile` | 10 | 10 | 18 | Poster and landscape tiles. | Cards. |
| `radius.field` | 10 | 12 | - | Text fields (desktop: matches menus). | Buttons. |
| `radius.panel` | - | 12 | - | Desktop menus, popups, episode row, setting row. | Touch. |
| `radius.card` | 16 | 14 | 16 | Cards. | Controls. |
| `radius.area` | 16 | 16 | 24 | Settings groups. | Controls. |
| `radius.sheet` | 28 | 28 | 28 | Sheets from the bottom. | Cards. |
| `radius.pill` | 999 | 999 | 999 | Capsules: fully round ends. | Rectangles. |

## Size

| Token | touch | desktop | tv | Use | Avoid |
|---|---|---|---|---|---|
| `size.control-height` | 56 | 40 | 56 | Field and button height. | Tap targets under 44 on touch. |
| `size.primary-height` | 56 | 48 | 76 | Primary action button height. | Secondary buttons. |
| `size.row-height` | 60 | 52 | 84 | List row height. | Rows with a subtitle on desktop (60). |
| `size.chip-height` | 30 | 30 | 56 | Filter chip height. | Buttons. |
| `size.poster-width` | 116 | 150 | 208 | Poster tile width. | Landscape tiles. |
| `size.poster-height` | 174 | 225 | 312 | Poster tile height. | Landscape tiles. |
| `size.landscape-width` | 280 | 280 | 448 | Landscape tile width. | Posters. |
| `size.landscape-height` | 158 | 158 | 252 | Landscape tile height. | Posters. |
| `size.hero-height` | 350 | 454 | 510 | Hero image height. | Rails. |
| `size.progress-height` | 4 | 4 | 8 | Progress bar on tiles. | Player seek bar. |
| `size.read-width` | 700 | 700 | 700 | Max width of running text. | Forms. |
| `size.form-width` | 420 | 420 | 420 | Width of forms. | Reading text. |

## State

| Token | touch | desktop | tv | Use | Avoid |
|---|---|---|---|---|---|
| `state.pressed-scale` | 0.97 | 0.97 | 0.97 | Press on buttons and tiles. | Full-width rows: they dim, they do not shrink. |
| `state.pressed-opacity` | 0.85 | 0.85 | 1 | Press on buttons (touch, desktop). | TV (opacity stays 1). |
| `state.hover-scale` | - | 1.04 | - | Tile picture on pointer hover, no ring. | Touch and TV. |
| `state.disabled-opacity` | 0.4 | 0.4 | 0.4 | Disabled form buttons; nav arrows use 0.35. | Rest state. |
| `state.focus-scale` | - | - | 1.06 | TV focus scale for tiles, buttons, tabs, chips (1.10 small icons, 1.03 wide rows). | Touch and desktop. |

## Motion

Durations in seconds. `smooth` and `snappy` are SwiftUI's curves (Android: tween with a soft easing; springs map response to stiffness (2π / response)²).

| Token | touch | desktop | tv | Use | Avoid |
|---|---|---|---|---|---|
| `motion.instant` | none | none | none | Press down: the finger gets no delay. | Release (use quick). |
| `motion.quick` | ease-out 0.12 | ease-out 0.12 | linear 0.12 | Release after press, hover. | Page changes. |
| `motion.toggle` | ease-out 0.1 | ease-out 0.1 | ease-out 0.15 | Switch thumb and track. | Pages. |
| `motion.leap` | snappy 0.22 | snappy 0.22 | snappy 0.22 | Expanding rows, chevrons. | Sheets. |
| `motion.select` | smooth 0.25 | smooth 0.25 | smooth 0.25 | Selection change. | Press. |
| `motion.standard` | smooth 0.28 | smooth 0.28 | smooth 0.28 | Content arriving, state changes (reveal, change). | Press feedback. |
| `motion.section` | snappy 0.2, scale 0.995 | ease-out 0.2, scale 0.996 | snappy 0.2, scale 0.995 | Switching a top-level section on touch: arrives from 0.995. | Scale below 0.99: the edge becomes visible. |
| `motion.emphasized` | spring 0.35 / 0.86 | spring 0.35 / 0.86 | spring 0.35 / 0.86 | Sheets sliding in from the bottom. | Small controls. |
| `motion.emphasized-land` | spring 0.45 / 0.86 | spring 0.45 / 0.86 | spring 0.45 / 0.86 | Something landing in place (cards). | Press feedback. |
| `motion.reduced` | linear 0.14 | linear 0.14 | linear 0.14 | Replaces every movement under Reduce Motion. | Normal motion. |
| `motion.focus` | - | - | ease-out 0.14 | TV focus moves (frequent, so short). | Touch and desktop. |
| `motion.page` | - | ease-out 0.18 | - | Desktop page change. | Touch. |
| `motion.push` | - | ease-in-out 0.45 | - | Desktop push: page below moves -30% and dims. | Touch. |
| `motion.tabs` | - | - | ease-in-out 0.25 | TV tab change. | Other sets. |
| `motion.backdrop` | - | - | ease-in-out 0.4 | TV backdrop fade in; ambient colour never before the picture. | Other sets. |
| `motion.controls-fade` | - | - | ease-in-out 0.2 | TV player controls fade; they hide after 8 s while playing. | Other sets. |

## Shadow

Tiles, cards, groups, sidebar and menus have no shadow: a 1 pt `border.edge` separates them.

| Token | Colour | Blur | y | Use | Avoid |
|---|---|---|---|---|---|
| `shadow.tooltip` | #000000 at 50% | 9 | 6 | Tooltip over the player. | Tiles, cards, groups. |
| `shadow.small` | #000000 at 25% | 6 | 4 | Small floating chip. | Flat surfaces. |
| `shadow.card` | #000000 at 60% x rest | 17 | 14 | Episode card over the player; colour, blur and offset scale with how far it rests. | Cards on a page. |
| `shadow.sheet` | #000000 at 50% | 20 | 18 | Sheet over the page. | Inline cards. |
| `shadow.gift` | #101010 at 50% | 28 | 12 | The look gift sheet. | Anything else. |
| `shadow.lift` | #000000 at 12% | 6 | 2 | TV focus lift, only while focused. | Resting TV parts. |

## Conflicts found (same role, different value per platform) and how they were resolved

Compared: Swift `Sources/Shared/Style.swift` + `Colors.swift` (iPhone), `Sources/macOS/Style.swift`, `Sources/tvOS/Style.swift`, Android `shared/.../Style.kt` and `phone/.../tv/TvStyle.kt`, the Rust `swiftly-design` tokens (`crates/swiftly-design/data/system.json`).

1. `heading.section` tracking: iPhone -0.308, Mac -0.484, **Android phone -0.484** (`Style.kt` `section`). Resolved to the iPhone value -0.308 in the base; desktop keeps -0.484 on purpose (`data/system.json`). Android phone must move to -0.308 when it adopts the tokens.
2. Android TV sizes are exactly half of the tvOS values (poster 104x156 vs 208x312, tab 34 vs 68, rail gap 36 vs 72). Not a conflict but a unit difference (dp at 960x540 vs points at 1920x1080). The `tv` set is stored in tvOS points; Android applies the factor 0.5.
3. `radius.card` differs by design between iPhone (16) and Mac (14); `radius.field` 10 vs 12. Kept as per-set values, the iPhone value is the base.
4. `surface.overlay` exists only in the design source (`colour/shade`, black 72%); no Swift or Kotlin code names it. Kept so the role exists; adopt it when the next overlay is built.
5. Android has a few phone-only sizes with no iPhone token (`pillsHeight`, `stillHeight`, `characterColumn`, `characterBar`, `characterEmpty`, `circleEmpty`, `symbolText`). Not in the token file yet; they are component sizes and now sit with their component as `local_sizes` in the catalogue.
6. Colours are identical on Swift, Kotlin and Rust (checked value by value). The accent is a Look at runtime on Apple and Android (`Theme.accent`); `accent.selection` is the original teal. Runtime Looks are not part of the token file yet.
7. Android TV draws resting chips with an inline white 10% (`TvStyle.kt:480`, `:659`), tvOS uses `surface.focus` 12% for the focus surface only. Different roles, but the 10% is a raw value outside the tokens; the token lint exempts style files, so it is fixed when the TV styles adopt the tokens.
8. The older generated set (`crates/swiftly-design/src/tokens.rs`, `generated/Tokens.swift`, from the original design file) names values after its (`JerkKind`, `BodyShell`, `PressButton` groups). It stays untouched. The semantic files replace it once app code uses them.

## Components

The catalogue of what the apps use today (no redesign). Source: `components` in `tokens.json` (per component: tokens by name, states, implementing type per platform, deviations seen). One usage doc each in `design/components/`. `cargo test -p swiftly-design` fails when a component names an unknown token, lacks its doc, or is missing from this list. New component: add it to `tokens.json`, write its doc, list it here; never build a one-off look when one of these fits.

| Component | Use | Swift | Kotlin | Rust |
|---|---|---|---|---|
| [`button.primary`](components/button.primary.md) | The one filled action of a page or sheet: white surface, dark text (Abspielen, Anmelden). | yes | yes | yes |
| [`button.secondary`](components/button.secondary.md) | Neutral action next to or below the primary one (Abbrechen, Schnellverbindung). | yes | yes | yes |
| [`button.quiet`](components/button.quiet.md) | Text-only action in the accent, no surface (second action of an empty state or error notice). | yes | yes | - |
| [`button.press`](components/button.press.md) | Press feedback for every other tappable thing: icon buttons, rows, text (scale 0.97 or dim, no layout change). | yes | yes | yes |
| [`button.icon`](components/button.icon.md) | Round or square icon-only button, often dark over an image (back, close, more). | yes | yes | - |
| [`button.tv`](components/button.tv.md) | TV button: focus fills it white with dark text, small lift. | yes | yes | yes |
| [`card.poster`](components/card.poster.md) | Poster tile: picture 2:3, title and second line below, optional progress and badge. | yes | yes | yes |
| [`card.landscape`](components/card.landscape.md) | Landscape tile 16:9: continue-watching, episodes, extras. | yes | yes | yes |
| [`tile.placeholder`](components/tile.placeholder.md) | Grey placeholder while pictures and rails load (shimmer-free). | yes | yes | yes |
| [`rail.horizontal`](components/rail.horizontal.md) | Titled horizontal rail of tiles that scrolls sideways and keeps the page margin. | yes | yes | yes |
| [`rail.value`](components/rail.value.md) | Horizontal strip of value pills / chips under a header; fades with scroll. | yes | yes | - |
| [`rail.alphabet`](components/rail.alphabet.md) | Letter index at the screen edge for long lists. | yes | yes | - |
| [`chip.filter`](components/chip.filter.md) | Capsule filter or choice chip (genre, sort, language). | yes | yes | yes |
| [`pill.value`](components/pill.value.md) | Small capsule with a glyph and a value (Abspielen, sort order, season). | yes | yes | yes |
| [`pill.offering`](components/pill.offering.md) | Skip intro / next episode pill over the player. | yes | yes | - |
| [`badge.tile`](components/badge.tile.md) | Corner badge on a tile: watched check or unwatched count. | yes | yes | yes |
| [`badge.tech`](components/badge.tech.md) | Colour-coded technical badge (resolution, dynamic range, video codec, audio). | yes | yes | - |
| [`badge.request`](components/badge.request.md) | Capsule that names the state of a request (verfügbar, wartet, abgelehnt). | yes | yes | - |
| [`card.group`](components/card.group.md) | Rounded surface that holds settings rows (a group). | yes | yes | yes |
| [`row.settings`](components/row.settings.md) | Row in a settings group: glyph, title, optional second line, trailing value, toggle or chevron. | yes | yes | yes |
| [`toggle.switch`](components/toggle.switch.md) | On/off switch with a white thumb. | yes | yes | yes |
| [`field.input`](components/field.input.md) | Text field: surface.control, one line, clear button. | yes | yes | yes |
| [`sheet.standard`](components/sheet.standard.md) | Bottom sheet (centred card on wide layouts) with title, lines and a cancel row. | yes | yes | yes |
| [`menu.player`](components/menu.player.md) | Player menu layer: audio, subtitles, speed, episodes. | yes | yes | yes |
| [`bar.player`](components/bar.player.md) | Glass capsule with the player's bar buttons. | yes | yes | - |
| [`bar.tab`](components/bar.tab.md) | Navigation between sections: bottom bar (touch), sidebar (desktop), top tabs (TV). | yes | yes | yes |
| [`header.subpage`](components/header.subpage.md) | Subpage header: back button, centred title. | yes | yes | - |
| [`header.detail`](components/header.detail.md) | Detail header: hero picture, title, proof line and action buttons. | yes | yes | yes |
| [`toast.hint`](components/toast.hint.md) | Short message strip at the bottom of the screen; closes itself after 3 to 6 s and is announced to VoiceOver. | yes | yes | yes |
| [`banner.arrival`](components/banner.arrival.md) | Card for a request that has arrived: poster, line, play button and close; several stack. | yes | yes | yes |
| [`empty.state`](components/empty.state.md) | Empty or failed page: disc with glyph, headline, text, optional button. | yes | yes | yes |
| [`progress.bar`](components/progress.bar.md) | Thin progress bar on tiles and rows. | yes | yes | yes |
| [`progress.ring`](components/progress.ring.md) | Ring for downloads and countdowns. | yes | yes | yes |
| [`spinner.loading`](components/spinner.loading.md) | Indeterminate loader. | yes | yes | yes |
| [`slider.time`](components/slider.time.md) | Player seek bar with time labels. | yes | yes | yes |
| [`row.media`](components/row.media.md) | Row with a picture: episode, file, download. | yes | yes | - |
| [`card.episode`](components/card.episode.md) | Episode card over the player picture (cards stack and rest at different depths). | yes | yes | yes |
| [`swipe.row`](components/swipe.row.md) | Row that reveals an action when swiped sideways (touch). | yes | yes | - |
| [`focus.tv`](components/focus.tv.md) | Shared TV focus treatment: scale, white fill or surface, small lift. | yes | yes | yes |

## Not covered yet

Runtime Looks, the mark sets, switching app code to the generated tokens, and tokens for component-only sizes (primary button fill and pressed fill, progress track, toggle track 46x28, the 78% tile-badge plate, the 10% resting TV pill) that the catalogue lists as deviations.

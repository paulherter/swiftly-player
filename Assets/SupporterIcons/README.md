# Supporter icons

Six alternate app icons for people who support Swiftly Player. Each one is the
regular play mark, same path and same position as `Website/symbol.svg`; only
colour, light and one detail change, so all six read as the same app. The
regular icon is not touched.

| Name | Idea |
|---|---|
| Heart | the regular turquoise mark with a rose heart set into it |
| Aurora | white mark on a turquoise to blue glow, like the website's light |
| Gold | gold mark with a warm glow on near black |
| Light | the mark in dark on a light ground |
| Night | near black ground, the mark glows turquoise from its centre |
| Coffee | cream mark on espresso brown |

Open `preview.html` to see all six on dark and light, at 180/120/60/40 px, on
the tvOS tile and in the Android circle mask.

## Rebuild

```bash
python3 build-icons.py            # everything (about 50 s)
python3 build-icons.py Heart Gold # only these, existing output is kept
python3 build-icons.py --svg-only # sources and Android vectors, no PNGs
```

Needs Python 3 with Pillow, Google Chrome (headless, SVG to PNG) and
`iconutil` (macOS). All colours, gradients and the heart live in the `ICONS`
table at the top of the script; change them there, never in the outputs.

Every icon is three layers: **back** (opaque ground), **middle** (glow or soft
shadow) and **front** (the mark). Only plain paths with solid fills and
linear/radial gradients are used, no blur filters, so the same description
becomes SVG, PNG and Android vector drawables without drift.

## Layout

```
svg/<Name>.svg                    1024 master, full bleed, no rounding
svg/<Name>/0-back … 2-front.svg   layers at 1024 (Icon Composer, if wanted)
svg/<Name>/tv-*.svg               layers on the 800 x 480 tvOS canvas
svg/<Name>/android-*.svg          adaptive layers on the 108 dp grid
ios/AppIcon-<Name>.appiconset     1024 universal, same format as Sources/iOS AppIcon
ios/previews/AppIconPreview-<Name>.imageset   120/180 px for an in-app picker
macos/AppIcon-<Name>.appiconset   ten sizes, same format as Sources/macOS AppIcon
macos/AppIcon-<Name>.icns         from iconutil
tvos/AppIcon-<Name>.imagestack    Front / Middle / Back, 400 x 240 @1x and @2x
android/res/drawable/ic_launcher_<name>_{background,foreground,monochrome}.xml
android/res/mipmap-anydpi-v26/ic_launcher_<name>{,_round}.xml
preview/                          composites used by preview.html only
```

## Wiring it up

**iOS / iPadOS.** Copy the `AppIcon-*.appiconset` folders and the preview
image sets into `Sources/iOS/Assets.xcassets`, then in `project.yml`:

```yaml
ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: "AppIcon-Heart AppIcon-Aurora AppIcon-Gold AppIcon-Light AppIcon-Night AppIcon-Coffee"
```

Switch with `UIApplication.shared.setAlternateIconName("AppIcon-Heart")`, back
with `nil`. Alternate icons cannot be loaded as images, hence the
`AppIconPreview-*` sets for the picker.

**tvOS.** Copy the `AppIcon-*.imagestack` folders into
`Sources/tvOS/Assets.xcassets`, **next to** `AppIcon.brandassets`, not inside
it, and set the same build setting. Checked with `actool`: all six end up in
`CFBundleAlternateIcons`. Inside a `.brandassets` of their own, actool reports
"No applicable image stack found".

**macOS.** There is no system API for alternate icons. Set the Dock icon at
runtime with `NSApp.applicationIconImage`, from the `.icns` or the 1024 PNG
copied into the bundle.

**Android.** Copy `android/res` into `Android/phone/src/main/res` and add one
`<activity-alias>` per icon, each with `android:icon="@mipmap/ic_launcher_<name>"`,
toggled with `PackageManager.setComponentEnabledSetting`. The foreground maps
the 1024 tile onto the inner 72 dp exactly like `ic_launcher_foreground.xml`;
the monochrome layer is the plain silhouette for themed icons.

## Checks done

- `actool` compiles the iOS, tvOS and macOS catalogs without errors or warnings.
- `aapt2 compile` accepts all Android resources.
- `preview.html` was looked at twice in headless Chrome and corrected (heart
  enlarged for 40 px, Aurora shifted towards turquoise, Light ground darkened
  at the bottom so it separates from light backgrounds).

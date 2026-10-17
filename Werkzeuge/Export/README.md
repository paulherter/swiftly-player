# Ausfuhr

The three `ExportOptions.plist` files for the App Store build.

**Why they live here and not in `build/`.** `build/` is in `.gitignore` and may be wiped at any time, but these are not build output. They are hand-written settings: team, signing style, symbol upload and, above all, `manageAppVersionAndBuildNumber: false`. Without that entry Xcode assigns the build number itself on export and overwrites the one in `project.yml`.

Deleting `build/` would otherwise lose them, and you would only notice when the next build no longer uploads.

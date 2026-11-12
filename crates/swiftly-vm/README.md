# swiftly-vm

View models of the Swiftly core (ARCHITECTURE.md D3). A view model is made of versioned *parts*
(`Arc` records, each with the version at which it was replaced), takes *intents* through `send`
(never blocks, effects run on a [`Spawner`]) and tells observers what changed through
`changed(seen)`. No UI, no idiom, no UniFFI: `swiftly-uniffi` exports the objects.

Screens so far: `HomeVm` (home rails over `swiftly-library`'s `HomeState` and `HomeLoader`).

Tests: `cargo test -p swiftly-vm` (mock transport, no network). The fixtures in `tests/fixtures`
are also served by the Swift tests of `Packages/SwiftlyCore`.

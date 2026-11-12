# swiftly-uniffi

The only exported surface of the Swiftly core (UniFFI proc-macros, library mode). `cargo run -p xtask -- apple`
builds the staticlibs, generates the Swift bindings and assembles `Packages/SwiftlyCore`.

Exported: `Core` (`new(platform, secrets, store)`, `ping`, `home_vm`, `home_vm_with`, `has_secret`), the view model
`HomeVm` and the records of its parts (declared in `swiftly-vm`, shaped here with `#[uniffi::remote]`), the foreign
traits `Platform`, `SecretStore`, `KeyValueStore`, `EngineProbe`, and the slice 1 probes (`HelloVm`, `PlayerProbe`).

Rules:
- Every exported async fn returns `Result<_, CoreError>`: a cancelled Swift `Task` throws `CancellationError`
  (xtask patches the generated Swift to cancel the Rust future; it refuses to run when an async export cannot throw).
- Foreign traits are synchronous and callable from any thread; Swift implements them as nonisolated `Sendable` classes.
- HTTP is the core's: reqwest through `swiftly-net` with the system trust store. The host passes the access token in
  `AccountRef`; the core never stores it. Logs and errors never contain it.

## Runtime (decided in GU slice 2)

UniFFI's `tokio` feature wraps every exported async fn in `async_compat::Compat`: futures are polled on the foreign
executor, and `Compat` makes one small tokio runtime (a current-thread scheduler on a single background thread
"async-compat/tokio-1") the current one while it polls. That is all reqwest needs. `tests/runtime.rs` measures it:

| Case | Result |
|---|---|
| reqwest request polled with no tokio context | panics: "there is no reactor running" |
| the same inside `Compat` | works, first request 1.2 ms on loopback |
| 12 requests at once inside `Compat` (about a home load) | 2.2 ms on loopback |
| a task spawned on the `Compat` runtime's `Handle` | works without any wrapper |

So no own multi-thread runtime is created. `Core` takes the `Handle` of the async-compat runtime once
(`Compat::new(async { Handle::current() })`) and uses it as the `Spawner` of the view models, so effects (the home
load) run on that one thread too: no second runtime, no extra thread. If a later VM does CPU-heavy work (decoding
big lists, image work), enable `async-compat/multi-thread` (a cargo feature, no code change) or move that work to a
worker pool; the single thread is a measured choice for I/O-bound loads, not a promise.

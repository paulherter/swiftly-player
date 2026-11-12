# swiftly-downloads

Download rules and the download-manager state machine of the Swiftly core, ported 1:1 from Swift
(`Downloads.swift`, `DownloadTask.swift`, `DownloadManager.swift`, `LoadSelection.swift`).
Quality, permission and audio choice stay in `swiftly-rules` and are re-exported.

| Module | Content |
|---|---|
| `item` | `DownloadItem` (serde = Swift `Codable` keys), `Art`, `PathPart` |
| `state` / `group` | `DownloadState`, `DownloadGroup` (single or series row) |
| `rules` | `DownloadRules` (next one, Wi-Fi rule, space padding and slot, grouping, offline episodes), `ProgressEstimator` |
| `list` | `liste.json` read/merge/write rules; dates are Swift reference-date numbers |
| `load_selection` | the series download sheet's selection logic |
| `manager` | `DownloadManagerState`: `handle(Intent) -> Vec<Effect>`, no I/O, no clock |
| `transport` | `DownloadTransport` trait and `TransferEvent` |
| `task` | transfer description string and generations |

## State machine in one picture

```
platform ----Intent----> DownloadManagerState::handle ----Vec<Effect>----> platform
 (UI, network monitor,                                  (Persist, RequestAddress, StartTransfer,
  transport callbacks)                                   CancelTransfer, DeleteFile, FetchImage, Report ...)
```

* One transfer at a time; the tick is the only place a download starts.
* Every pause, put-back, removal and start advances the title's generation; callbacks with an old
  generation are ignored (a pause is not an error).
* With "Wi-Fi only" nothing starts or stops until the first network report; cellular puts a
  running title back to *waiting* (not paused) and Wi-Fi resumes it with its resume data.
* Saving is coalesced: one `Persist` (the whole list, all accounts) at the end of each intent.
* Time arrives in the intents (`f64` Unix seconds); the generation counter is seeded by the caller.

## Platform glue

Implement `DownloadTransport` (iOS: native background `URLSession`; Android/desktop: `reqwest`
in-process), feed `TransferEvent::into_intent()` back, run the other effects (file store, image
fetch, address request through the server client), and read/write the list with
`list::load_list` / `encode_list`. A list that cannot be decoded is reported in
`LoadedList::broken`; copy the file aside before writing.

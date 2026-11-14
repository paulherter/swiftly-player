# Changes against souvlaki 0.9.3 (MIT, Aldo Acevedo)

- Playback rate: `MediaControls::set_rate`, `MediaControls::set_rate_range` and `MediaControlEvent::SetRate`.
  - MPRIS (zbus back end): the `Rate`, `MinimumRate` and `MaximumRate` properties follow the values the app sets
    (they were fixed at 1.0); a client writing `Rate` becomes a `SetRate` event.
  - Windows: SMTC `PlaybackRate`, and `PlaybackRateChangeRequested` becomes a `SetRate` event.
  - Other back ends accept the calls and ignore them.
- MPRIS: `MediaMetadata::track_id` names the track (`mpris:trackid`) with an object path of the app's choosing; the
  property was a constant `/`, which the specification does not allow. Without a valid path it is the spec's `NoTrack`.
- Examples, tests, docs and the CI folder are left out.
- Windows `set_metadata` replaces the whole card: the display updater is cleared first (a field the new title lacks, such
  as the cover, no longer keeps the previous value, and empty metadata clears the card). A `file://` cover address is
  turned into a Windows path (drive letter, percent-decoding, backslashes) and a cover that cannot be read no longer
  aborts the rest of the update.

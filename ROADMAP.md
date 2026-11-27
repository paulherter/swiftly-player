# Roadmap

Swiftly Player is a free, native Jellyfin client for iPhone, iPad, Mac, Apple TV, Android, Android TV, Windows and Linux.
This page lists everything that is planned or still to do, small things included, in one table sorted by priority.
It has no dates and no version numbers: things ship when they work.

Last reviewed: 2026-11-28

## How to read the table

Items are sorted by priority, then by rank inside a priority. Finished items sit at the end of their priority group.
The priorities are:

1. Playback and reliability: subtitles, buffering, crashes and everything that must simply work.
2. Home, library and navigation.
3. Settings and languages.
4. Requests through Seerr.
5. Platform work: desktop, Android TV, Apple TV and distribution.
6. Wanted, not scheduled yet.
7. Later: low priority.

Status is one of `in progress`, `not started` or `done`. The app collects no data; progress goes only to your own server.

## Give feedback

- Bugs: [open an issue](https://github.com/paulherter/swiftly-player/issues/new/choose).
- Ideas: post them in [Discord](https://discord.gg/MeGwfv3UwN). Describe the problem you have before the solution you want.
- Questions and chat: [Discord](https://discord.gg/MeGwfv3UwN).
- To build something yourself, open an issue first so nobody works twice on the same thing, then follow
  [CONTRIBUTING.md](CONTRIBUTING.md).

## The list

| ID | Priority | Area | Item | Status |
| --- | --- | --- | --- | --- |
| SP-001 | 1 | Subtitles | Subtitles move up while the player controls are showing, so the controls never cover them. | in progress |
| SP-002 | 1 | Playback | The buffer size can be set on every device, and the buffer keeps filling while a video is paused. | in progress |
| SP-003 | 1 | Playback | Picture in Picture on the Mac uses the native system player window. | in progress |
| SP-004 | 1 | Playback | Pressing and holding plays at double speed on every platform, with picture and sound in sync. | in progress |
| SP-005 | 1 | Subtitles | Subtitles are sharp and always appear when selected. | not started |
| SP-006 | 1 | Subtitles | Subtitles that follow each other directly show without a gap or flicker in between. | not started |
| SP-007 | 1 | Reliability | Leaving the player while a downloaded film plays offline and other downloads are running no longer crashes. | not started |
| SP-008 | 1 | Apple TV | Autoplay stops when the Apple TV goes to sleep, so it no longer starts the next episode and wakes the TV. | not started |
| SP-009 | 1 | Apple TV | Sound from another app does not start again inside Swiftly Player after an episode ends. | not started |
| SP-010 | 1 | Android | The Next Episode button starts the episode and does not mark it as watched. | not started |
| SP-011 | 1 | Android | Opening a large series no longer crashes on Android TV devices with little memory. | not started |
| SP-012 | 1 | Apple | Handoff and AirPlay show up right away instead of after 10 to 60 seconds. | not started |
| SP-013 | 1 | Playback | Chapters and more subtitle languages are available in the player. | done |
| SP-014 | 2 | Home | Next Up shows one entry per series. | in progress |
| SP-015 | 2 | Library | Libraries can be switched off in the Appearance settings, so they no longer show up in the app. | in progress |
| SP-016 | 2 | Home | Next Up includes series you watch again, with a maximum-days setting like Jellyfin Web. | not started |
| SP-017 | 2 | Home | Pinned libraries and collections on Home show posters instead of placeholders. | not started |
| SP-018 | 2 | Library | The Watched by list shows profile pictures instead of initials. | not started |
| SP-019 | 2 | Library | The alphabet index is available on the iPhone again, controlled by its setting. | not started |
| SP-020 | 2 | Admin | The server administration screen opens at once and loads the slow library details afterwards. | not started |
| SP-021 | 2 | Apple TV | Page transitions on Apple TV are smooth, for example from Home to a series page. | in progress |
| SP-022 | 2 | Home | On a cold start the visible rows (Continue Watching, Next Up, newest series) are ready with their pictures before the first frame. | not started |
| SP-023 | 2 | Library | Filter by year and language, hide empty series and delete from the server are available. | done |
| SP-024 | 3 | Settings | The Home settings are cleaner and easier to find. | in progress |
| SP-025 | 3 | Languages | The audio and subtitle language you picked for a series is remembered across devices, with one rule shared by every platform. | not started |
| SP-026 | 3 | Languages | Times, durations and ratings follow the chosen app language on every platform, and the Russian remaining-time text reads correctly. | not started |
| SP-027 | 3 | Settings | The End time in the player setting stays in sync between devices when settings sync is on. | not started |
| SP-028 | 3 | Settings | The player options (settings, episode list, subtitles and audio) are simpler. | not started |
| SP-029 | 4 | Seerr | Seerr signs in with your Jellyfin account without asking again. | in progress |
| SP-030 | 4 | Seerr | The season picker sheet has even spacing and clean rounded corners at the bottom, also on phones. | not started |
| SP-031 | 5 | Windows | Fullscreen on Windows covers the whole screen, without taskbar or border. | not started |
| SP-032 | 5 | Desktop | On the detail page of a series or film the description has room below it and More can be clicked, on Linux and Windows. | not started |
| SP-033 | 5 | Linux | Search and request pages scroll smoothly on Linux. | not started |
| SP-034 | 5 | Desktop | The interface can be scrolled by touch on Linux. | not started |
| SP-035 | 5 | Desktop | The desktop player menu matches the Mac, with the same groups, Watch Together and Report a Problem. | not started |
| SP-036 | 5 | Android TV | The focus highlight on Android TV and Apple TV is clearer, without a white border. | not started |
| SP-037 | 5 | Admin | Server administration for admins works on Mac, iPad, Apple TV and Android. | not started |
| SP-038 | 5 | Distribution | The new app is available in every store on all platforms. | not started |
| SP-039 | 6 | Subtitles | Subtitle font, background and colors can be styled. | not started |
| SP-040 | 6 | Library | Mac, Windows and Linux let you choose and reorder the libraries in the sidebar by dragging. | not started |
| SP-041 | 6 | Playback | The Next Episode button in the player can be hidden in the settings. | not started |
| SP-042 | 6 | Library | A switch shows missing episodes. | not started |
| SP-043 | 6 | Home | New in Series and New in Anime are separate rows on Home. | not started |
| SP-044 | 6 | Apple TV | Apple TV and Android TV can share the app log, for example through a QR code. | not started |
| SP-045 | 6 | Android | After a crash the app offers to share the report. | not started |
| SP-046 | 6 | Library | Theme music plays quietly on the series page on Apple TV and Android TV. | not started |
| SP-047 | 6 | Settings | Custom HTTP headers can be set per server, for example for Cloudflare Access or Authelia. | not started |
| SP-048 | 6 | Settings | The quality can depend on the network, and the Home sections can be chosen and ordered. | not started |
| SP-049 | 6 | Library | Collections can use landscape covers, and each episode shows its own description and rating. | not started |
| SP-050 | 6 | Home | Continue Watching and Next Up can be shown as one row. | not started |
| SP-051 | 7 | Home | A media bar at the top of Home shows featured titles, possibly with Seerr. | not started |
| SP-052 | 7 | Languages | More app languages: German and English stay first-class, French comes next, then the most used languages. | not started |
| SP-053 | 7 | Linux | An AUR package for Arch Linux and CachyOS. | not started |
| SP-054 | 7 | Subtitles | Subtitles can be searched and downloaded inside the app. | not started |
| SP-055 | 7 | Subtitles | The subtitle offset can be adjusted during playback. | not started |

## Not planned

- A music page in Swiftly Player. Swiftly Music is its own app.
- Trakt.
- Subscriptions, accounts with us and telemetry: never.

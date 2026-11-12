import Foundation

// Usage: oracle <oracle dir> [domain ...]
// Reads <dir>/<domain>.in.json, runs the Swift function of that domain on every case and writes
// <dir>/<domain>.swift.json = {"domain": ..., "results": [...]} (same order as the cases).
//
// To add a domain: write `Domain_<Name>.swift` with `let domainName = Domain("name") { case in ... }`
// and add it to `allDomains` below (small additive edit, re-read the file first).

let allDomains: [Domain] = [
    domainNaturalOrder,
    domainAlphabetIndex,
    domainAgeRating,
    domainWholeNumber,
    domainResumePoint,
    domainDownloadQuality,
    domainDisplayRules,
    domainEpisodeEnd,
    domainChapterBar,
    domainDownloadTask,
    domainTermTrim,
    domainLanguageRules,
    domainTrackLanguage, domainPlayDisplay,
    domainOriginalAudio,
    domainColorSelection,
    domainTrackRule,
    domainTrackMapping,
    domainModelDecode,
    domainImageAddress, domainImageStoreKey, domainImageSelection,
    domainPluralCategory, domainVersionCompare, domainTimestamp,
    domainDelay, domainBufferLevel, domainTimeAssumption, domainFadeTimes, domainPausePrebuffer,
    domainServerURL, domainServerRelative, domainAddressSecret, domainOwnHeadersClean, domainOwnHeadersTable, domainServerDiscovery, domainStandardCompareDe, domainStandardCompareEn, domainStandardCompareRu,
    domainStartRails, domainStartLibraries, domainSearchHistory, domainLibraryGenre, domainLibraryFilter, domainListRules, domainTitleFilter, domainSectionLogic,
    domainDeviceProfile, domainDownloadRight, domainBitratesLimit, domainPlayTime, domainTrailerChoice, domainPlaybackPlan,
    domainEpisodeCard, domainSeasonChoice, domainWatcherRing, domainMediaVersions, domainStopLock,
    domainSettingsSync,
    domainSyncPlayRead, domainSyncPlayMisc, domainSyncPlayClock, domainSyncPlayBuffer, domainSyncPlayTime,
    domainPlaybackTick, domainDownloadAudio, domainDownloadRules, domainServerFactory,
    domainLoginError, domainLoginQuick, domainLoginHttp, domainLoginAccounts, domainLoginKind,
    domainDescription, domainCounter, domainTitleMarks, domainSearchKeys, domainEpisodeSwitch,
    domainRequestsHttp,
    domainRequestsPlex,
    domainLogRedaction,
]

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: oracle <dir> [domain...]\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
// `-AppleLanguages (ru)` and `-AppleLocale ru_RU` are for Foundation (standard_compare_*), not domain names.
var wantedList: [String] = []
var skipNext = false
for a in args.dropFirst(2) {
    if skipNext { skipNext = false; continue }
    if a.hasPrefix("-Apple") { skipNext = true; continue }
    wantedList.append(a)
}
let wanted = Set(wantedList)
var failed = false
for domain in allDomains where wanted.isEmpty || wanted.contains(domain.name) {
    do {
        try domain.run(in: dir)
        print("oracle: \(domain.name) ok")
    } catch {
        failed = true
        FileHandle.standardError.write(Data("oracle: \(domain.name) FAILED: \(error)\n".utf8))
    }
}
exit(failed ? 1 : 0)

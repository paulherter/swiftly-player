package de.paulherter.swiftly

import de.paulherter.swiftly.rustcore.*
import de.paulherter.swiftly.shared.Texts

/**
 * **The pure `Kern` rules from the Rust core**, with the names and argument types of the old static calls
 * (`Kern.startRails`, `Kern.searchKeyTyped`, `Kern.downloadSpace`, ...). Texts follow the app language. Each answer is
 * compared with the Swift one by the golden tests.
 */
object KernRules {
    private val language get() = Texts.language

    // Home
    fun startRails(stored: Array<String>, disconnected: Boolean): String = legacyStartRails(stored.toList(), disconnected)
    fun startRailShifted(was: String, step: Long, stored: Array<String>, disconnected: Boolean): String =
        legacyStartRailShifted(was, step, stored.toList(), disconnected)
    fun refreshDue(lastMs: Long): Boolean = legacyRefreshDue(lastMs)

    // Subtitle look (settings)
    fun subtitleLookNormalise(json: String): String = legacySubtitleLookNormalise(json)
    fun subtitleLookStandard(): String = legacySubtitleLookStandard()
    fun subtitleLookChange(json: String, field: String, value: String): String = legacySubtitleLookChange(json, field, value)
    fun subtitleLookFacts(json: String, baseScale: Double): String = legacySubtitleLookFacts(json, baseScale)

    // Account bundles (sign-in group)
    fun bundleRecord(session: String, bundle: String): String = legacyBundleRecord(session, bundle)
    fun bundleSwitch(bundle: String, identifier: String): String = legacyBundleSwitch(bundle, identifier)
    fun bundleRemoved(bundle: String, identifier: String): String = legacyBundleRemoved(bundle, identifier)
    fun bundleActive(bundle: String): String = legacyBundleActive(bundle)
    fun bundleActiveId(bundle: String): String = legacyBundleActiveId(bundle)
    fun bundleActiveKind(bundle: String): String = legacyBundleActiveKind(bundle)
    fun bundleKinds(bundle: String): String = legacyBundleKinds(bundle)
    fun bundleServers(bundle: String): String = legacyBundleServers(bundle)
    fun bundleFromSession(session: String): String = legacyBundleFromSession(session)
    fun bundleOverview(bundle: String): String = legacyBundleOverview(bundle)
    fun accountSwitchCurve(fromX: Double, fromY: Double, size: Double, toX: Double, toY: Double, targetSize: Double): String =
        legacyAccountSwitchCurve(fromX, fromY, size, toX, toY, targetSize)
    fun quickConnectDeadline(): String = legacyQuickConnectDeadline()
    // Looks (support)
    /** The device's offset east of UTC in seconds at [ms]: the seasons run on the wall clock. */
    private fun offset(ms: Long): Long = java.util.TimeZone.getDefault().getOffset(ms) / 1000L
    fun looksCatalog(): String = legacyLooksCatalog()
    fun looksNormalize(selection: String): String = legacyLooksNormalize(selection)
    fun looksPalette(selection: String): String = legacyLooksPalette(selection)
    fun looksSwitch(lookID: String): String = legacyLooksSwitch(lookID)
    fun looksTryOn(state: String, op: String, arg: String): String = legacyLooksTryOn(state, op, arg)
    fun looksGiftDue(nowMs: Long, homeReady: Boolean, playing: Boolean, askedThisSession: Boolean, secondsOnHome: Double, owned: String, offered: String): String =
        legacyLooksGiftDue(nowMs, homeReady, playing, askedThisSession, secondsOnHome, owned, offered, offset(nowMs))
    fun looksGiftOfferID(lookID: String, nowMs: Long): String = legacyLooksGiftOfferId(lookID, nowMs, offset(nowMs))
    fun looksGiftAvailable(lookID: String, owned: String, nowMs: Long): Boolean = legacyLooksGiftAvailable(lookID, owned, nowMs, offset(nowMs))
    fun looksAnyGiftAvailable(owned: String, nowMs: Long): Boolean = legacyLooksAnyGiftAvailable(owned, nowMs, offset(nowMs))
    fun looksEffects(lookID: String, nowMs: Long, switchOn: Boolean, playing: Boolean, reduceMotion: Boolean, lowPower: Boolean, foreground: Boolean): String =
        legacyLooksEffects(lookID, nowMs, switchOn, playing, reduceMotion, lowPower, foreground, offset(nowMs))
    fun looksProfileEntry(supporterFeatures: Boolean, isSupporter: Boolean, ownsLook: Boolean, giftAvailable: Boolean): String =
        legacyLooksProfileEntry(supporterFeatures, isSupporter, ownsLook, giftAvailable)

    // Library
    fun labels(): String = legacyLabels(language)
    fun savedGenres(): String = legacySavedGenres(language)
    fun collectionCountText(art: String, count: Long): String = legacyCollectionCountText(art, count, language)

    // Search
    fun searchTermFits(term: String): Boolean = legacySearchTermFits(term)
    fun searchHistoryKey(): String = legacySearchHistoryKey()
    fun searchHistoryKeyAccount(account: String): String = legacySearchHistoryKeyAccount(account)
    fun searchHistoryRemember(word: String, raw: String): String = legacySearchHistoryRemember(word, raw)
    fun searchHistoryList(raw: String): String = legacySearchHistoryList(raw)
    fun searchKeyRows(speech: Boolean): String = legacySearchKeyRows(speech)
    fun searchKeyTyped(character: String, term: String): String = legacySearchKeyTyped(character, term)
    fun searchKeySpace(term: String): String = legacySearchKeySpace(term)
    fun searchKeySpaceFits(term: String): Boolean = legacySearchKeySpaceFits(term)
    fun searchKeyDelete(term: String): String = legacySearchKeyDelete(term)
    fun searchKeyHardware(text: String, term: String): String = legacySearchKeyHardware(text, term)
    fun searchTitlesShown(series: Long, films: Long, requests: Long): Boolean = legacySearchTitlesShown(series, films, requests)
    fun searchScreen(term: String, historyCount: Long, hasHits: Boolean, answered: Boolean, disrupted: Boolean, waited: Boolean): String =
        legacySearchScreen(term, historyCount, hasHits, answered, disrupted, waited)

    // Downloads
    fun downloadQualities(selectable: Boolean, files: String): String = legacyDownloadQualities(selectable, files, language)
    fun downloadEstimated(quality: String, bytes: Long, ticks: Long): Long = legacyDownloadEstimated(quality, bytes, ticks)
    fun downloadBadge(quality: String): String = legacyDownloadBadge(quality, language)
    fun downloadQualityName(quality: String): String = legacyDownloadQualityName(quality, language)
    fun downloadInQuality(list: String, quality: String): String = legacyDownloadInQuality(list, quality)
    fun downloadShared(list: String): String = legacyDownloadShared(list, language)
    fun downloadNext(list: String, wLAN: Boolean, onlyOverWLAN: Boolean): String = legacyDownloadNext(list, wLAN, onlyOverWLAN)
    fun downloadMayLoad(wLAN: Boolean, onlyOverWLAN: Boolean): Boolean = legacyDownloadMayLoad(wLAN, onlyOverWLAN)
    fun downloadErrorText(status: Long): String = legacyDownloadErrorText(status, language)
    fun downloadSpace(bytes: Long, free: Long, list: String): String = legacyDownloadSpace(bytes, free, list)
    fun downloadGroups(list: String): String = legacyDownloadGroups(list)
    fun downloadSize(bytes: Long): String = legacyDownloadSize(bytes, language)
    fun downloadFooterSpace(bytes: Long, free: Long): String = legacyDownloadFooterSpace(bytes, free)
    fun downloadProgress(loaded: Long, total: Long): String = legacyDownloadProgress(loaded, total, language)
    fun downloadProgressShow(loaded: Long, total: Long, before: Long, elapsed: Double): Boolean = legacyDownloadProgressShow(loaded, total, before, elapsed)
    fun downloadResumeFrom(entries: String): Double = legacyDownloadResumeFrom(entries)
    fun downloadNextEpisode(list: String): String = legacyDownloadNextEpisode(list, language)
    fun downloadButtonShow(rights: String, functionOn: Boolean): Boolean = legacyDownloadButtonShow(rights, functionOn)
    fun downloadEstimatorReport(id: String, loaded: Long, total: Long) = legacyDownloadEstimatorReport(id, loaded, total)
    fun downloadEstimatorHalt(id: String) = legacyDownloadEstimatorHalt(id)
    fun downloadEstimatorValue(id: String, loaded: Long): Long = legacyDownloadEstimatorValue(id, loaded)
    fun downloadEstimatorForget(id: String) = legacyDownloadEstimatorForget(id)

    // Player: delay
    fun delayState(milliseconds: Long, language: String): String = legacyDelayState(milliseconds, language, Texts.language)
    fun delayShifted(milliseconds: Long, bearing: Long, steps: Long): Long = legacyDelayShifted(milliseconds, bearing, steps)
    fun delayForNewTitle(milliseconds: Long, oldTitle: String, oldSeries: String, newTitle: String, addedSeries: String): Long =
        legacyDelayForNewTitle(milliseconds, oldTitle, oldSeries, newTitle, addedSeries)
    fun delayMicroseconds(milliseconds: Long): Long = legacyDelayMicroseconds(milliseconds)
    fun delaySoftFrom(milliseconds: Long, readMicroseconds: Long): Boolean = legacyDelaySoftFrom(milliseconds, readMicroseconds)

    // Player: first frame
    fun firstFrameRat(hasVideoTrack: Boolean, excluded: Boolean, shown: Long, runtime: Double, untilFrom: Long): String =
        legacyFirstFrameRat(hasVideoTrack, excluded, shown, runtime, untilFrom)
    fun firstFrameNext(rat: String, untilFrom: Long): Long = legacyFirstFrameNext(rat, untilFrom)
    fun firstFrameGrowth(before: Double, now: Double): Double = legacyFirstFrameGrowth(before, now)
    fun firstFrameHint(rung: Long): String = legacyFirstFrameHint(rung, language)
    fun firstFrameSoftwareOption(): String = legacyFirstFrameSoftwareOption()

    // Player: stream watch
    fun streamWatchRat(standstillSince: Double, networkChangeForward: Double, jumpOpen: Boolean, lastJumpForward: Double, bufferGrewPre: Double): String =
        legacyStreamWatchRat(standstillSince, networkChangeForward, jumpOpen, lastJumpForward, bufferGrewPre)
    fun streamWatchImagesState(before: Long, now: Long): Boolean = legacyStreamWatchImagesState(before, now)
    fun streamWatchNetworkChangeDeadline(): Double = legacyStreamWatchNetworkChangeDeadline()

    // Rating and community
    fun ratingCounts(position: Double, duration: Double): Boolean = legacyRatingCounts(position, duration)
    fun ratingDue(done: Long, lastAsked: String, version: String): Boolean = legacyRatingDue(done, lastAsked, version)
    fun communityTrigger(done: Long, lastAsked: String, version: String, discordShown: Boolean, ratingPossible: Boolean): String =
        legacyCommunityTrigger(done, lastAsked, version, discordShown, ratingPossible)
    fun communityAddress(art: String, version: String, platform: String): String = legacyCommunityAddress(art, version, platform)

    // Next episode, notches, settings lists
    fun nextAutomaticApplies(choice: String, account: String): Boolean = legacyNextAutomaticApplies(choice, account)
    fun notch(value: Double, until: Double, marks: DoubleArray, width: Double): Double = legacyNotch(value, until, marks.toList(), width)
    fun bitrateLevels(): String = legacyBitrateLevels(language)
    fun span(): String = legacySpan()
    fun languages(from: String): String = legacyLanguages(from, language)
    fun bufferLevels(): String = legacyBufferLevels(language)

    // Pending reports
    fun pendingReportRecord(store: String, message: String): String = legacyPendingReportRecord(store, message)
    fun pendingDone(store: String, completed: String): String = legacyPendingDone(store, completed)

    // Support and what's new
    fun supportRecordLaunch(usage: String, nowMs: Long): String = legacySupportRecordLaunch(usage, nowMs)
    fun supportDecide(status: String, usage: String, history: String, isPlaying: Boolean, secondsSinceLaunch: Double, tv: Boolean, nowMs: Long): String =
        legacySupportDecide(status, usage, history, isPlaying, secondsSinceLaunch, tv, nowMs, offset(nowMs))
    fun supportHistoryAfter(history: String, answer: String, nowMs: Long): String = legacySupportHistoryAfter(history, answer, nowMs)
    fun supportStoreStatus(sinceMs: Long): String = legacySupportStoreStatus(sinceMs)
    fun supportSource(status: String): String = legacySupportSource(status)
    fun supportTips(): String = legacySupportTips()
    fun whatsNewDecide(lastSeen: String, usedBefore: Boolean, current: String, hasEntry: Boolean): String =
        legacyWhatsNewDecide(lastSeen, usedBefore, current, hasEntry)
    fun whatsNewCheck(json: String): String = legacyWhatsNewCheck(json)
    fun versionIsNewer(version: String, than: String): Boolean = de.paulherter.swiftly.rustcore.versionIsNewer(version, than)

    // Handover card
    fun handoffStates(width: Double, height: Double, tv: Boolean): String = legacyHandoffStates(width, height, tv)
    fun handoffToTop(from: String, to: String): Boolean = legacyHandoffToTop(from, to)
    fun handoffLane(typedInput: String): String = legacyHandoffLane(typedInput)
}

import Foundation
import JellyfinKit
import class SwiftlyCore.Core
import enum SwiftlyCore.PlanOnly
import enum SwiftlyCore.PlayFailure
import struct SwiftlyCore.AccountRef

/// **The plan for a title, asked from the core** (`playPlanOnly`; the Rust port of `JellyfinClient.playbackPlan` +
/// `PlaybackPlan.make`: one request, the version, direct play or stream or conversion, the session and the
/// address), turned back into the `PlaybackPlan` the screens already read. The version's `MediaSource` comes as
/// the server's own JSON and decodes to the same value; a failure becomes the `JellyfinError` the old call threw,
/// so ``readableError(_:)`` words it exactly as before.
enum PlanFromCore {
    enum Outcome {
        case plan(PlaybackPlan)
        /// The server names no source (a series or a season).
        case noSource
        case failed(any Error)
    }

    static func plan(
        core: Core, account: AccountRef, itemID: String, sourceID: String?, maxBitrate: Int, locale: String,
        subtitle: Int64? = nil
    ) async -> Outcome {
        let answer: PlanOnly
        do {
            answer = try await core.playPlanOnly(
                account: account, locale: locale, itemId: itemID, sourceId: sourceID, hardwareAv1: HardwareAV1.isSupported,
                maxBitrate: Int64(maxBitrate), subtitle: subtitle)
        } catch {
            return .failed(error)
        }
        switch answer {
        case .ready(let url, let method, let mediaSourceId, let playSessionId, let sourceJson):
            guard let sourceJson, let source = try? JSONDecoder().decode(MediaSource.self, from: Data(sourceJson.utf8)),
                  let address = URL(string: url)
            else { return .failed(JellyfinError.decoding("plan")) }
            let delivery: DeliveryMethod
            switch method {
            case .directPlay: delivery = .directPlay
            case .directStream: delivery = .directStream
            case .transcode: delivery = .transcode
            }
            return .plan(PlaybackPlan.assembled(
                url: address, method: delivery, mediaSourceID: mediaSourceId, playSessionID: playSessionId,
                source: source, itemID: itemID, profile: .vlc(maxBitrate: maxBitrate)))
        case .noSource:
            return .noSource
        case .failed(let message, let failure):
            return .failed(error(failure, message: message))
        }
    }

    /// The error the old client would have thrown for this failure.
    static func error(_ failure: PlayFailure, message: String) -> JellyfinError {
        switch failure {
        case .network(let code): .network(code: Int(code))
        case .http(let status, let body): .http(status: Int(status), body: body)
        case .notAuthenticated: .notAuthenticated
        case .twoFactor: .twoFactor
        case .invalidServerUrl: .invalidServerURL
        case .decoding(let text): .decoding(text)
        case .noPlayableSource: .noPlayableSource
        case .playbackRejected(let reason): .playbackRejected(reason)
        case .other: .transport(message)
        }
    }
}

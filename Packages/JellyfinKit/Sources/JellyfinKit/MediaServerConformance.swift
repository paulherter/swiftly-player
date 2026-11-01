import Foundation

extension JellyfinClient: MediaServer {
    public nonisolated var kind: ServerKind { serverKind }
    public nonisolated var capabilities: Set<ServerCapability> { serverKind.capabilities }
    public nonisolated func signedOutCopy() -> any MediaServer { withoutAccount() }
}

extension JellyfinClient: QuickSignIn {}
extension JellyfinClient: RemoteSessionServer {}
extension JellyfinClient: DisplayPreferencesServer {}
extension JellyfinClient: ActiveEncodingServer {}

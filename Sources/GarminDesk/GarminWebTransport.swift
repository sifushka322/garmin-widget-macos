import Foundation

/// Narrow transport boundary for deterministic lifecycle tests without WebKit,
/// browsing data, credentials, or a running macOS application.
@MainActor
protocol GarminWebTransport: AnyObject {
    var onConnectPageReady: (() -> Void)? { get set }
    var onSignInClosed: (() -> Void)? { get set }
    var onDiagnostic: ((BridgeDiagnostic) -> Void)? { get set }
    var savedLogin: String? { get }
    /// Changes whenever website restoration may have selected another account.
    var sessionGeneration: UInt64 { get }
    func saveLogin(username: String, password: String) throws
    func forgetLogin() throws
    func beginBatch()
    func openSignIn(title: String)
    func closeSignIn()
    func prepare(forceReload: Bool) async throws
    func get(path: String, stage: String) async throws -> Any
    func cancel()
    func disconnect() async
}

extension GarminWebTransport {
    // Synthetic preview transports never replace their account session.
    var sessionGeneration: UInt64 { 0 }
}

/// A renewed session must have its profile checked before account-bound reads.
enum GarminWebSessionInvalidated: Error { case renewed }

extension GarminWebSession: GarminWebTransport {}

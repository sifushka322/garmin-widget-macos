import Foundation

/// Narrow transport boundary for deterministic lifecycle tests without WebKit,
/// browsing data, credentials, or a running macOS application.
@MainActor
protocol GarminWebTransport: AnyObject {
    var onConnectPageReady: (() -> Void)? { get set }
    var onSignInClosed: (() -> Void)? { get set }
    var onDiagnostic: ((BridgeDiagnostic) -> Void)? { get set }
    func beginBatch()
    func openSignIn(title: String)
    func closeSignIn()
    func prepare(forceReload: Bool) async throws
    func get(path: String, stage: String) async throws -> Any
    func cancel()
    func disconnect() async
}

extension GarminWebSession: GarminWebTransport {}

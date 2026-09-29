import AppKit
import Combine
import WebKit

enum GarminWebError: Error {
    case signInRequired
    case forbidden
    case rateLimited(TimeInterval?)
    case challenge
    case network
    case invalidResponse
    case cancelled
    case keychain

    var code: String {
        switch self {
        case .signInRequired: return "auth"
        case .forbidden: return "access_denied"
        case .rateLimited: return "rate_limit"
        case .challenge: return "security_challenge"
        case .network: return "network"
        case .invalidResponse: return "protocol"
        case .cancelled: return "cancelled"
        case .keychain: return "keychain"
        }
    }
}

/// A completed SSO document can still redirect using JavaScript. Only a ready
/// Connect document, or a stable visible sign-in form, ends session preparation.
enum GarminNavigationDecision: Equatable {
    case wait, ready, signInRequired

    static func isAllowedSite(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "garmin.com" || host.hasSuffix(".garmin.com")
    }

    static func isConnect(_ url: URL?) -> Bool {
        guard isAllowedSite(url), let url, url.host?.lowercased() == "connect.garmin.com" else { return false }
        return url.path == "/app" || url.path.hasPrefix("/app/") || url.path == "/modern" || url.path.hasPrefix("/modern/")
    }

    static func evaluate(url: URL?, connectReady: Bool, visibleSignIn: Bool, signInVisibleFor: TimeInterval) -> Self {
        guard isAllowedSite(url), let url else { return .wait }
        if isConnect(url) && connectReady { return .ready }
        let path = url.path.lowercased()
        let authenticationPage = url.host?.lowercased() == "sso.garmin.com" || path.contains("sign-in") || path.contains("signin") || path.contains("login")
        if authenticationPage && visibleSignIn && signInVisibleFor >= 3 { return .signInRequired }
        return .wait
    }
}

/// A normal, persistent Garmin website session owned by this application.
/// Authentication stays in Garmin's web UI, including MFA and security checks.
/// Browser credentials, tickets and cookies are never sent to the native bridge.
@MainActor
final class GarminWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    @Published private(set) var isShowingSignIn = false
    @Published private(set) var visibleHost = ""
    var onConnectPageReady: (() -> Void)?
    var onSignInClosed: (() -> Void)?
    var onDiagnostic: ((BridgeDiagnostic) -> Void)?

    private(set) var webView: WKWebView
    private var window: NSWindow?
    private var navigationWaiter: CheckedContinuation<Void, Error>?
    private var navigationTimeout: Task<Void, Never>?
    private var navigationReadinessTask: Task<Void, Never>?
    private var navigationReadinessID: UUID?
    private var navigationRequestID: UUID?
    private var expectedNavigation: WKNavigation?
    private var currentNavigation: WKNavigation?
    private var retiredNavigations: [WKNavigation] = []
    private var navigationChainHasCommitted = false
    private var hasLiveDocument = false
    private var hasReadyConnectDocument = false
    private var isDisconnecting = false
    private var requestCount = 0
    private var requestGeneration = 0
    private var processGeneration = 0
    private var activeFetchID: String?
    private var attemptedRenewal = false
    private(set) var sessionGeneration: UInt64 = 0
    private let credentialStore: any GarminCredentialStore
    private var autoLogin = GarminAutoLoginPolicy()
    private var credentialSubmissionAt: TimeInterval?
    private var frameSignInRequired = false
    private var credentialsEnabled = true
    private var reloadSignInOnOpen = false
    private enum SessionFailure: Error { case unauthorized, documentNotReady }
    private let connectHost = "connect.garmin.com"
    private let startURL = URL(string: "https://connect.garmin.com/app/home")!

    init(credentialStore: any GarminCredentialStore = GarminKeychain()) {
        self.credentialStore = credentialStore
        let configuration = WKWebViewConfiguration()
        // WebKit's persistent default store belongs to this application. It is
        // separate from Safari/Chrome and is cleared only on explicit disconnect.
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1040, height: 760), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        let controller = configuration.userContentController
        controller.add(GarminLoginFrameHandler(owner: self), contentWorld: .defaultClient, name: "garminLoginForm")
        controller.addUserScript(WKUserScript(source: Self.loginFormObserverScript, injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: false, in: .defaultClient))
    }

    var savedLogin: String? { credentialsEnabled ? (try? credentialStore.load())?.username : nil }

    func saveLogin(username: String, password: String) throws {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username.count <= 320, !password.isEmpty, password.count <= 4096 else {
            throw GarminWebError.invalidResponse
        }
        try credentialStore.save(.init(username: username, password: password))
        credentialsEnabled = true
        autoLogin.reset()
        reloadSignInOnOpen = true
    }

    func forgetLogin() throws {
        credentialsEnabled = false
        try credentialStore.delete()
    }

    var isOnConnectPage: Bool {
        hasLiveDocument && hasReadyConnectDocument && !isDisconnecting && GarminNavigationDecision.isConnect(webView.url)
    }

    func openSignIn(title: String) {
        guard !isDisconnecting else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.minSize = NSSize(width: 700, height: 600)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = title + " · " + (webView.url?.host ?? connectHost)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.unhide(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isShowingSignIn = true
        if !webView.isLoading && (!hasLiveDocument || reloadSignInOnOpen) {
            reloadSignInOnOpen = false
            autoLogin.reset(); credentialSubmissionAt = nil; frameSignInRequired = false
            currentNavigation = webView.load(URLRequest(url: startURL))
        }
        else if isOnConnectPage { onConnectPageReady?() }
        else if let currentNavigation, hasLiveDocument { checkDocumentReadiness(for: currentNavigation) }
    }

    func closeSignIn() {
        isShowingSignIn = false
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        isShowingSignIn = false
        cancelNavigation()
        onSignInClosed?()
    }

    /// Loading the normal site lets Garmin resume or renew its own session.
    /// If cookies expire, a saved Keychain login can submit the normal SSO form
    /// once. MFA, challenges and rejected credentials still require the user.
    func prepare(forceReload: Bool = false) async throws {
        try Task.checkCancellation()
        guard !isDisconnecting else { throw GarminWebError.cancelled }
        if isOnConnectPage && !forceReload { return }
        sessionGeneration &+= 1
        cancelNavigation()
        retireCurrentNavigation()
        let requestID = UUID()
        reloadSignInOnOpen = false
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                navigationRequestID = requestID
                navigationWaiter = continuation
                hasLiveDocument = false
                hasReadyConnectDocument = false
                navigationChainHasCommitted = false
                expectedNavigation = webView.load(URLRequest(url: startURL))
                currentNavigation = expectedNavigation
                guard expectedNavigation != nil else {
                    finishNavigation(.failure(GarminWebError.network), requestID: requestID)
                    return
                }
                navigationTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finishNavigation(.failure(GarminWebError.network), requestID: requestID, stopLoading: true)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelNavigation(requestID: requestID) }
        }
        try Task.checkCancellation()
        guard isOnConnectPage else { throw GarminWebError.signInRequired }
    }

    func beginBatch() {
        requestCount = 0; attemptedRenewal = false
        autoLogin.reset(); credentialSubmissionAt = nil; frameSignInRequired = false
    }

    /// Relative read-only API routes are checked both in Swift and in the page.
    /// WebKit attaches its own HttpOnly cookies; native code never reads them.
    func get(path: String, stage: String) async throws -> Any {
        do { return try await performGet(path: path, stage: stage) }
        catch is SessionFailure {
            guard !attemptedRenewal else { throw GarminWebError.signInRequired }
            attemptedRenewal = true
            try await prepare(forceReload: true)
            // Saved credentials can belong to a different account. A profile
            // read is safe to repeat; all other paths need host verification
            // before being rebuilt with the restored account's display name.
            guard path == GarminWebAPI.profilePath else { throw GarminWebSessionInvalidated.renewed }
            do { return try await performGet(path: path, stage: stage) }
            catch is SessionFailure { throw GarminWebError.signInRequired }
        }
    }

    private func performGet(path: String, stage: String) async throws -> Any {
        guard isOnConnectPage else { throw SessionFailure.documentNotReady }
        guard Self.isAllowedAPIPath(path) else { throw GarminWebError.invalidResponse }
        try Task.checkCancellation()
        let generation = requestGeneration
        let process = processGeneration
        let fetchID = UUID().uuidString
        activeFetchID = fetchID
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Synchronizing Garmin data")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            if activeFetchID == fetchID { activeFetchID = nil }
        }
        let result: Any?
        do {
            result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await webView.callAsyncJavaScript(Self.readScript, arguments: ["path": path, "fetchID": fetchID], in: nil, contentWorld: .defaultClient)
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.abortFetch(id: fetchID) }
            }
        } catch {
            if Task.isCancelled || generation != requestGeneration { throw GarminWebError.cancelled }
            throw GarminWebError.network
        }
        guard generation == requestGeneration else { throw GarminWebError.cancelled }
        try Task.checkCancellation()
        guard process == processGeneration else { throw GarminWebError.network }
        guard let response = result as? [String: Any], let status = response["status"] as? Int else { throw GarminWebError.invalidResponse }
        if response["sessionNotReady"] as? Bool == true {
            hasReadyConnectDocument = false
            throw SessionFailure.documentNotReady
        }
        requestCount += 1
        let apiError = ((response["body"] as? [String: Any])?["error"] as? [String: Any])?["status-code"]
        let apiStatus = (apiError as? Int) ?? (apiError as? String).flatMap(Int.init)
        let retryAfter = Self.retryAfter(response["retryAfter"] as? String)
        let challenge = response["challenge"] as? Bool == true
        onDiagnostic?(BridgeDiagnostic(stage: stage, httpStatus: status, apiErrorStatus: apiStatus,
                                       retryAfterSeconds: retryAfter.map { Int($0.rounded(.up)) },
                                       responseKind: response["kind"] as? String, requestCount: requestCount, challenge: challenge))
        if status == 429 || apiStatus == 429 { throw GarminWebError.rateLimited(retryAfter) }
        if challenge { throw GarminWebError.challenge }
        if status == 401 || apiStatus == 401 { throw SessionFailure.unauthorized }
        if response["signInRedirect"] as? Bool == true { throw SessionFailure.unauthorized }
        if status == 403 || apiStatus == 403 { throw GarminWebError.forbidden }
        return try Self.successfulPayload(from: response, status: status)
    }

    static func successfulPayload(from response: [String: Any], status: Int) throws -> Any {
        // Garmin uses 204 for valid absence (including HRV before daily data
        // exists). A bodyless success must reach group schema normalization.
        if status == 204 { return NSNull() }
        guard (200..<300).contains(status), response["kind"] as? String == "json",
              response["jsonValid"] as? Bool == true, let body = response["body"] else {
            if status >= 500 { throw GarminWebError.network }
            throw GarminWebError.invalidResponse
        }
        return body
    }

    func cancel() {
        requestGeneration += 1
        cancelNavigation()
        if let activeFetchID { abortFetch(id: activeFetchID) }
        activeFetchID = nil
    }

    private func abortFetch(id: String) {
        Task { [weak self] in
            _ = try? await self?.webView.callAsyncJavaScript("globalThis.garminDeskRequests?.[fetchID]?.abort(); return null;",
                                                           arguments: ["fetchID": id], in: nil, contentWorld: .defaultClient)
        }
    }

    func disconnect() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        defer { isDisconnecting = false }
        cancel()
        closeSignIn()
        credentialsEnabled = false
        // AppStore also reports deletion errors before disconnecting. Retry here
        // so no transport caller can forget to remove the saved login.
        try? credentialStore.delete()
        hasLiveDocument = false
        currentNavigation = nil
        webView.stopLoading()
        let store = webView.configuration.websiteDataStore
        // This dedicated app data store contains only Garmin browsing data.
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        currentNavigation = webView.loadHTMLString("", baseURL: nil)
    }

    private func cancelNavigation(requestID: UUID? = nil) {
        if let requestID, requestID != navigationRequestID { return }
        stopReadinessCheck()
        if navigationWaiter != nil {
            finishNavigation(.failure(GarminWebError.cancelled), requestID: requestID, stopLoading: true)
        } else {
            // Interactive openSignIn loads have no prepare() continuation.
            // They still need their document, readiness probe and load retired.
            navigationTimeout?.cancel(); navigationTimeout = nil
            retireCurrentNavigation()
            currentNavigation = nil; expectedNavigation = nil; navigationRequestID = nil
            hasLiveDocument = false; hasReadyConnectDocument = false
            webView.stopLoading()
        }
    }
    private func finishNavigation(_ result: Result<Void, Error>, requestID: UUID? = nil, navigation: WKNavigation? = nil, stopLoading: Bool = false) {
        if let requestID, requestID != navigationRequestID { return }
        if let navigation, navigation !== expectedNavigation { return }
        guard navigationWaiter != nil else { return }
        navigationTimeout?.cancel(); navigationTimeout = nil
        stopReadinessCheck()
        let waiter = navigationWaiter; navigationWaiter = nil
        navigationRequestID = nil; expectedNavigation = nil
        if stopLoading { retireCurrentNavigation(); currentNavigation = nil; hasLiveDocument = false; hasReadyConnectDocument = false; webView.stopLoading() }
        waiter?.resume(with: result)
    }

    private func retireCurrentNavigation() {
        guard let currentNavigation, !retiredNavigations.contains(where: { $0 === currentNavigation }) else { return }
        retiredNavigations.append(currentNavigation)
        if retiredNavigations.count > 32 { retiredNavigations.removeFirst() }
    }

    private func stopReadinessCheck() {
        navigationReadinessTask?.cancel(); navigationReadinessTask = nil
        navigationReadinessID = nil
    }

    private func checkDocumentReadiness(for navigation: WKNavigation) {
        stopReadinessCheck()
        let checkID = UUID()
        let requestID = navigationRequestID
        navigationReadinessID = checkID
        navigationReadinessTask = Task { [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 45
            var visibleSince: TimeInterval?
            while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
                guard let self, self.navigationReadinessID == checkID,
                      self.currentNavigation === navigation, self.navigationRequestID == requestID,
                      !self.isDisconnecting else { return }
                // Only booleans cross this boundary: no input values, page text,
                // CSRF value, account details, or cookies are inspected by Swift.
                let result = try? await self.webView.callAsyncJavaScript(Self.navigationReadinessScript, arguments: [:], in: nil, contentWorld: .defaultClient)
                guard !Task.isCancelled, self.navigationReadinessID == checkID,
                      self.currentNavigation === navigation, self.navigationRequestID == requestID else { return }
                let flags = result as? [String: Bool] ?? [:]
                let now = ProcessInfo.processInfo.systemUptime
                let visibleSignIn = flags["visibleSignIn"] == true || self.frameSignInRequired
                if visibleSignIn { visibleSince = visibleSince ?? now } else { visibleSince = nil }
                // Give a submitted form time to redirect or reveal an MFA step.
                let connectReady = flags["connectReady"] == true && GarminNavigationDecision.isConnect(self.webView.url)
                if let submitted = self.credentialSubmissionAt, now - submitted < 10, !connectReady {
                    visibleSince = nil
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                if self.frameSignInRequired, !connectReady, let visibleSince, now - visibleSince >= 3 {
                    self.finishNavigation(.failure(GarminWebError.signInRequired), requestID: requestID, navigation: navigation)
                    return
                }
                switch GarminNavigationDecision.evaluate(url: self.webView.url, connectReady: flags["connectReady"] == true,
                                                         visibleSignIn: visibleSignIn,
                                                         signInVisibleFor: visibleSince.map { now - $0 } ?? 0) {
                case .ready:
                    self.hasReadyConnectDocument = true
                    self.finishNavigation(.success(()), requestID: requestID, navigation: navigation)
                    if self.isShowingSignIn { self.onConnectPageReady?() }
                    return
                case .signInRequired:
                    self.finishNavigation(.failure(GarminWebError.signInRequired), requestID: requestID, navigation: navigation)
                    return
                case .wait: break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, !isDisconnecting else { return }
        guard !retiredNavigations.contains(where: { $0 === navigation }) else { return }
        if let expectedNavigation, navigation !== expectedNavigation {
            // A committed Garmin page may start the next ordinary SSO hop.
            // Old callbacks still cannot finish a newer preparation request.
            guard navigationChainHasCommitted else { return }
            retireCurrentNavigation()
            self.expectedNavigation = navigation
        } else if navigation !== currentNavigation { retireCurrentNavigation() }
        stopReadinessCheck()
        currentNavigation = navigation
        hasLiveDocument = false
        hasReadyConnectDocument = false
        frameSignInRequired = false
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let navigation, navigation === currentNavigation, !isDisconnecting else { return }
        navigationChainHasCommitted = true
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === currentNavigation, !isDisconnecting else { return }
        hasLiveDocument = true
        navigationChainHasCommitted = true
        visibleHost = webView.url?.host ?? ""
        window?.title = "Garmin Connect · " + visibleHost
        checkDocumentReadiness(for: navigation)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }
    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard let navigation, navigation === currentNavigation else { return }
        stopReadinessCheck()
        hasLiveDocument = false
        hasReadyConnectDocument = false
        let failure: GarminWebError = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled ? .cancelled : .network
        // JavaScript navigation can cancel its predecessor before the next
        // didStart arrives. Explicit user/task cancellation is handled above.
        if case .cancelled = failure, navigationWaiter != nil {
            navigationChainHasCommitted = true
            return
        }
        retireCurrentNavigation()
        currentNavigation = nil
        finishNavigation(.failure(failure), navigation: navigation)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processGeneration += 1
        stopReadinessCheck()
        retireCurrentNavigation()
        hasLiveDocument = false
        hasReadyConnectDocument = false
        currentNavigation = nil
        activeFetchID = nil
        finishNavigation(.failure(GarminWebError.network))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        decisionHandler(GarminNavigationDecision.isAllowedSite(url) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse,
           GarminAutoLoginPolicy.allows(response.url), [403, 429].contains(response.statusCode) {
            // Do not submit a password from a rate-limit or access-denied page.
            let failure: GarminWebError = response.statusCode == 429
                ? .rateLimited(Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))) : .forbidden
            _ = autoLogin.begin()
            finishNavigation(.failure(failure), stopLoading: true)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    static func isAllowedAPIPath(_ path: String) -> Bool {
        // Check traversal before URL resolves dot segments and hides the original input.
        let encodedPath = String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard let decodedPath = encodedPath.removingPercentEncoding,
              !decodedPath.contains("\\"),
              !decodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        guard path.hasPrefix("/gc-api/") || path.hasPrefix("/atp-api/"),
              !path.contains("\\"), !path.contains("#"),
              let url = URL(string: path, relativeTo: URL(string: "https://connect.garmin.com")!),
              url.host == "connect.garmin.com", url.user == nil, url.password == nil else { return false }
        return !url.path.split(separator: "/").contains("..")
    }
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        if let delay = TimeInterval(header), delay.isFinite, delay >= 0 { return min(delay, 604800) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), 604800)
    }

    fileprivate func loginFormAppeared(_ message: WKScriptMessage) {
        guard message.webView === webView, !isDisconnecting,
              navigationWaiter != nil || isShowingSignIn,
              GarminNavigationDecision.isAllowedSite(webView.url),
              GarminAutoLoginPolicy.allows(message.frameInfo.request.url),
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "sso.garmin.com",
              [0, 443].contains(message.frameInfo.securityOrigin.port),
              let state = message.body as? String, ["form", "verification"].contains(state) else { return }
        frameSignInRequired = true
        guard state == "form", credentialsEnabled, !autoLogin.attempted else { return }
        let credentials: GarminCredentials
        do {
            guard let saved = try credentialStore.load() else { return }
            credentials = saved
        } catch {
            // A locked Keychain is temporary, not an expired Garmin account.
            // Keep the normal sync backoff so unlocking the Mac can recover it.
            finishNavigation(.failure(GarminWebError.keychain))
            return
        }
        guard autoLogin.begin() else { return }
        sessionGeneration &+= 1
        let generation = requestGeneration
        let navigation = currentNavigation
        credentialSubmissionAt = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            guard let self, generation == self.requestGeneration, navigation === self.currentNavigation,
                  !self.isDisconnecting, self.credentialsEnabled else { return }
            // Values are arguments, never interpolated into JavaScript or logged.
            _ = try? await self.webView.callAsyncJavaScript(Self.loginSubmitScript,
                arguments: ["username": credentials.username, "password": credentials.password],
                in: message.frameInfo, contentWorld: .defaultClient)
        }
    }

    private static let loginFormScript = #"""
    globalThis.garminDeskLoginForm = () => {
        if (location.origin !== 'https://sso.garmin.com') return {state: 'untrusted'};
        const visible = element => {
            const style = getComputedStyle(element);
            return !element.disabled && style.display !== 'none' && style.visibility !== 'hidden' && element.getClientRects().length > 0;
        };
        const verification = Array.from(document.querySelectorAll('input[autocomplete="one-time-code"], input[name="verificationCode"], input[name="mfa-code"], .g-recaptcha, .h-captcha, .cf-turnstile, iframe[src*="recaptcha"], iframe[src*="hcaptcha"]')).some(visible);
        if (verification) return {state: 'verification'};
        const passwords = Array.from(document.querySelectorAll('input[type="password"]')).filter(visible);
        if (passwords.length !== 1 || passwords[0].autocomplete === 'new-password') return {state: 'waiting'};
        const password = passwords[0], form = password.form;
        if (!form || new URL(form.action || location.href, location.href).origin !== 'https://sso.garmin.com') return {state: 'untrusted'};
        const username = Array.from(form.querySelectorAll('input[autocomplete="username"], input[type="email"], input[name="username"], input[name="email"], input#username')).find(visible);
        const submit = Array.from(form.querySelectorAll('button[type="submit"], input[type="submit"], button:not([type])')).find(visible);
        if (submit?.hasAttribute('formaction') && new URL(submit.formAction, location.href).origin !== 'https://sso.garmin.com') return {state: 'untrusted'};
        return username && submit ? {state: 'form', form, username, password, submit} : {state: 'waiting'};
    };
    """#

    private static let loginFormObserverScript = loginFormScript + #"""
    (() => {
        if (location.origin !== 'https://sso.garmin.com') return;
        let previous;
        const inspect = () => {
            const {state} = globalThis.garminDeskLoginForm();
            if (state !== previous && (state === 'form' || state === 'verification')) {
                window.webkit.messageHandlers.garminLoginForm.postMessage(state);
            }
            previous = state;
        };
        inspect();
        const observer = new MutationObserver(inspect);
        observer.observe(document.documentElement, {childList: true, subtree: true, attributes: true, attributeFilter: ['disabled', 'style', 'class', 'type']});
        setTimeout(() => observer.disconnect(), 45000);
        window.addEventListener('pagehide', () => observer.disconnect(), {once: true});
    })();
    """#

    private static let loginSubmitScript = #"""
    if (location.origin !== 'https://sso.garmin.com' || globalThis.garminDeskLoginSubmitted) return false;
    const fields = globalThis.garminDeskLoginForm?.();
    if (fields?.state !== 'form') return false;
    globalThis.garminDeskLoginSubmitted = true;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    for (const [element, value] of [[fields.username, username], [fields.password, password]]) {
        setter.call(element, value);
        element.dispatchEvent(new Event('input', {bubbles: true}));
        element.dispatchEvent(new Event('change', {bubbles: true}));
    }
    // Honor the site's validation and submit handler, including its normal MFA.
    fields.submit.click();
    return true;
    """#

    private static let navigationReadinessScript = #"""
    const visible = element => {
        const style = getComputedStyle(element);
        return !element.disabled && style.display !== 'none' && style.visibility !== 'hidden' &&
            element.getClientRects().length > 0;
    };
    const visibleSignIn = Array.from(document.querySelectorAll('input[type="password"], input[autocomplete="one-time-code"], input[autocomplete="username"], input[type="email"]')).some(visible);
    const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
    return {visibleSignIn, connectReady: typeof csrf === 'string' && csrf.length > 0 && csrf.length <= 4096 && !/[\r\n]/.test(csrf)};
    """#

    private static let readScript = #"""
    const target = new URL(path, location.origin);
    if (location.origin !== 'https://connect.garmin.com' || target.origin !== location.origin ||
        !(target.pathname.startsWith('/gc-api/') || target.pathname.startsWith('/atp-api/'))) throw new Error('Invalid source');
    const controller = new AbortController();
    globalThis.garminDeskRequests ??= Object.create(null);
    globalThis.garminDeskRequests[fetchID] = controller;
    const timer = setTimeout(() => controller.abort(), 25000);
    let reader;
    try {
        // Garmin publishes this anti-CSRF value in the page for same-origin API
        // calls. Keep it entirely inside WebKit; never return or persist it.
        const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
        if (typeof csrf !== 'string' || !csrf || csrf.length > 4096 || /[\r\n]/.test(csrf)) {
            return {status:0, sessionNotReady:true, body:null, jsonValid:false, kind:'other'};
        }
        const response = await fetch(target.href, {method:'GET', credentials:'same-origin', cache:'no-store',
            headers:{'Accept':'application/json', 'NK':'NT', 'connect-csrf-token':csrf}, signal:controller.signal});
        const contentType = response.headers.get('content-type') || '';
        const kind = contentType.includes('json') ? 'json' : (contentType.includes('html') ? 'html' : 'other');
        const responseURL = new URL(response.url);
        const garminHost = responseURL.hostname === 'garmin.com' || responseURL.hostname.endsWith('.garmin.com');
        const authenticationPath = /(?:^|\/)(?:sign-in|signin|login)(?:\/|$)/i.test(responseURL.pathname);
        const metadata = {status:response.status, kind, retryAfter:response.headers.get('retry-after'),
            challenge:response.headers.get('cf-mitigated') === 'challenge',
            signInRedirect:response.redirected && responseURL.protocol === 'https:' && garminHost &&
                (responseURL.hostname === 'sso.garmin.com' || authenticationPath)};
        // A broken, huge or stalled error body cannot conceal a server pause,
        // challenge or sign-in result. Do not read its body before acting.
        if ([401,403,429].includes(response.status) || metadata.challenge || metadata.signInRedirect) {
            return {...metadata, body:null, jsonValid:false};
        }
        const length = Number(response.headers.get('content-length') || 0);
        if (length > 4000000) throw new Error('Response too large');
        reader = response.body?.getReader();
        let text = '', bytes = 0;
        const decoder = new TextDecoder();
        if (reader) {
            while (true) {
                const chunk = await reader.read();
                if (chunk.done) break;
                bytes += chunk.value.byteLength;
                if (bytes > 4000000) throw new Error('Response too large');
                text += decoder.decode(chunk.value, {stream:true});
            }
            text += decoder.decode();
        }
        let body = null, jsonValid = false;
        if (kind === 'json' && text) { try { body = JSON.parse(text); jsonValid = true; } catch {} }
        return {...metadata, body, jsonValid};
    } finally {
        clearTimeout(timer);
        controller.abort();
        delete globalThis.garminDeskRequests[fetchID];
        if (reader) {
            try { await reader.cancel(); } catch {}
            try { reader.releaseLock(); } catch {}
        }
    }
    """#
}

/// WKUserContentController retains handlers; the proxy must not retain its owner.
@MainActor
private final class GarminLoginFrameHandler: NSObject, WKScriptMessageHandler {
    weak var owner: GarminWebSession?
    init(owner: GarminWebSession) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.loginFormAppeared(message)
    }
}

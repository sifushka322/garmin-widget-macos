import Foundation

@main
@MainActor
struct GarminWebBoundaryTests {
    static var count = 0
    static func check(_ value: Bool, _ message: String) {
        count += 1
        if !value { fatalError(message) }
    }
    static func main() {
        for value in ["2026-02-30", "2025-02-29", "2026-13-01", "2026-09-00", "26-09-15", "2026-09-15?x=1"] {
            check(!GarminWebAPI.validDay(value), "Invalid calendar dates must never become network paths")
        }
        check(GarminWebAPI.validDay("2024-02-29"), "Valid leap day is supported")
        check(GarminWebAPI.calendarPaths(sourceDay: "2026-12-31") == ["/gc-api/calendar-service/year/2026/month/11", "/gc-api/calendar-service/year/2027/month/0"], "Upcoming calendar crosses the year without losing January")
        check(GarminWebAPI.calendarPaths(sourceDay: "2026-02-30").isEmpty, "Invalid calendar date cannot fetch a different normalized day")
        let escaped = GarminWebAPI.path(group: .stats, sourceDay: "2026-09-15", displayName: "profile/a?date=other#fragment")!
        check(escaped.contains("profile%2Fa%3Fdate%3Dother%23fragment"), "Profile names cannot alter the endpoint, query, or fragment")
        check(GarminWebAPI.path(group: .stats, sourceDay: "2026-02-30", displayName: "sample") == nil, "Bad source day is rejected")
        let groups = GarminWebAPI.requiredGroups(metricIDs: ["steps", "stress", "restingHeartRate", "calories", "sleepDuration", "sleepScore"])
        check(groups == [.profile, .devices, .stats, .sleep], "Shared metric groups coalesce into four requests instead of one per metric")
        check(!groups.contains(.activities) && !groups.contains(.plannedWorkouts), "Training history is fetched only when explicitly included")
        for path in ["https://example.com/gc-api/a", "//example.com/gc-api/a", "/app/home", "/gc-api/a#fragment", "/gc-api/../private", "/gc-api/%2e%2e/private", "/gc-api/\\evil"] {
            check(!GarminWebSession.isAllowedAPIPath(path), "API path must stay within read-only Garmin service routes: \(path)")
        }
        check(GarminWebSession.isAllowedAPIPath("/gc-api/hrv-service/hrv/2026-09-15"), "Known service route is accepted")
        check(GarminWebSession.retryAfter("-1") == nil, "Negative delay is invalid")
        check(GarminWebSession.retryAfter("nan") == nil, "Nonfinite delay is invalid")
        check(GarminWebSession.retryAfter("6048000") == 604800, "Server delay is bounded to seven days")
        check(GarminWebSession.retryAfter("0") == 0, "Valid zero is preserved for policy to apply its minimum")
        let now = ISO8601DateFormatter().date(from: "2026-09-15T16:00:00Z")!
        check(GarminWebSession.retryAfter("Tue, 15 Sep 2026 16:30:00 GMT", now: now) == 1800, "HTTP-date wait is interpreted in GMT")
        check(GarminWebSession.retryAfter("Tue, 15 Sep 2026 15:00:00 GMT", now: now) == 0, "Past server date does not produce a negative pause")
        func navigation(_ address: String, ready: Bool = false, signIn: Bool = false, elapsed: TimeInterval = 0) -> GarminNavigationDecision {
            GarminNavigationDecision.evaluate(url: URL(string: address), connectReady: ready, visibleSignIn: signIn, signInVisibleFor: elapsed)
        }
        let connect = "https://connect.garmin.com/app/home"
        let sso = "https://sso.garmin.com/portal/sso/embed?service=connect"
        check(navigation(sso) == .wait, "A finished SSO document is an intermediate hop, not expired authentication")
        check(navigation(sso, elapsed: 40) == .wait, "A redirect-only SSO document never invents a sign-in requirement")
        check(navigation("https://sso.garmin.com/portal/signin") == .wait, "A sign-in URL alone does not prove credentials are required")
        check(navigation(sso, ready: true) == .wait, "SSO metadata cannot authorize Connect API calls")
        check(navigation(connect) == .wait, "Connect must finish preparing its CSRF metadata before API calls")
        check(navigation(connect, ready: true) == .ready, "Persisted session completes without another login action")
        check(navigation("https://connect.garmin.com/modern/", ready: true) == .ready, "Legacy normal Connect landing route is supported")
        check(navigation("https://connect.garmin.com/app-error", ready: true) == .wait, "Only exact app route prefixes qualify")
        check(navigation(sso, signIn: true, elapsed: 2.9) == .wait, "Briefly displayed sign-in UI can still redirect automatically")
        check(navigation(sso, signIn: true, elapsed: 3) == .signInRequired, "A stable visible authentication form can request user sign-in")
        check(navigation(sso, signIn: false, elapsed: 10) == .wait, "Hidden sign-in controls never terminate preparation")
        check(navigation(connect, signIn: true, elapsed: 10) == .wait, "An unrelated editable Connect form is not a login page")
        for address in ["https://connect.garmin.com.evil.example/app/home", "http://connect.garmin.com/app/home", "https://connect.garmin.com:8443/app/home", "about:blank"] {
            check(navigation(address, ready: true, signIn: true, elapsed: 10) == .wait, "Untrusted documents cannot complete session preparation")
        }
        let emptyResponse: [String: Any] = ["status": 204, "kind": "other", "jsonValid": false, "body": NSNull()]
        check((try? GarminWebSession.successfulPayload(from: emptyResponse, status: 204)) is NSNull, "HTTP 204 is valid absence without a JSON body")
        check((try? GarminWebSession.successfulPayload(from: emptyResponse, status: 200)) == nil, "Bodyless HTTP 200 is still an invalid response")
        let nullJSON: [String: Any] = ["kind": "json", "jsonValid": true, "body": NSNull()]
        check((try? GarminWebSession.successfulPayload(from: nullJSON, status: 200)) is NSNull, "Explicit JSON null remains valid absence")
        let arbitraryJSON: [String: Any] = ["kind": "json", "jsonValid": true, "body": ["unexpected": true]]
        let arbitraryPayload = try! GarminWebSession.successfulPayload(from: arbitraryJSON, status: 200)
        check(!GarminPayloadNormalizer.isRecognizedPayload(group: "hrv", payload: arbitraryPayload), "HTTP 200 arbitrary dictionaries remain schema mismatches")
        check(GarminPayloadNormalizer.isRecognizedPayload(group: "hrv", payload: NSNull()), "No-content HRV clears unavailable daily data truthfully")
        print("GarminWebBoundaryTests: \(count) checks passed")
    }
}

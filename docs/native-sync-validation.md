# Native website sync: lifecycle validation

## Implemented host contract

`AppStore` owns the persistent `SyncPolicy` checkpoint and a `GarminWebTransport` instance. The production conformance is `GarminWebSession`. Tests inject a fake transport, continuous clock, in-memory preferences, temporary support directory, and an inert legacy Keychain remover. They disable widget publication and real timers.

1. The host reserves a policy request **before** `prepare` or a profile read. `.wait` and blocked session states perform no website I/O.
2. A previously connected but unverified cookie store uses `beginSessionVerification`. Starting verification does not mark it connected. Profile proof makes the session available; failures can be recorded even before the profile endpoint succeeds.
3. Expired, forbidden and challenge states persist and require a completed user sign-in. Automatic launch/wake/refresh does not reopen sign-in.
4. A batch fetches only due groups. A missing display name needs one profile prerequisite; a genuinely due profile group always performs a real profile read.
5. Completion recomputes the desired groups from current profiles. A newly selected group gets one follow-up; freshly received groups retain their cadence.
6. Scheduling uses a single cancellable task with a relative delay. The next deadline is the earliest due group or local date boundary, subject to server/transient pauses. Wake, system clock and time-zone changes must call `store.sync(trigger: .wake)` to re-evaluate dates and continuous time.
7. A user cancellation invalidates the current generation, rejects late responses, and schedules future unattended work after the configured refresh interval. Disconnect also blocks a new sign-in until cookie cleanup has completed.
8. Successful metric groups replace their own cache entries, including an explicit empty response. Failed same-day groups keep their own older retrieval times. Yesterday's measurements never become today's fallback.
9. The health group cache is written before the policy checkpoint. If cache writing fails, persisted group freshness is removed, while authentication and rate-limit states are still saved when possible. On launch, absent/day-mismatched group caches invalidate their cadence stamps.

The existing default initializer and UI methods remain available. `cancelLogin(resumeAutomatic: false)` is for teardown/demo/disconnect; UI cancellation uses its default `true`.

## Verified locally

- `Tests/AppStoreSyncTests.swift`: **48 checks passed**. Covers gated bootstrap, persisted expiration and explicit recovery, cadence with real profile reads, fresh relaunch, profile changes during a held response, rate-limit clock rollback, partial failure and empty days, cancellation, cache/checkpoint write ordering, and asynchronous disconnect/reconnect races.
- `Tests/SyncPolicyTests.swift`: **206 checks passed**. Covers pure group cadence, coalescing, bounded retry/backoff, Retry-After, continuous clock/reboot behavior, expired states, date changes, checkpoint metadata, and tracked session verification.
- Direct Swift compiler typecheck covers all host and shared sources using the macOS 26.5 SDK and the macOS 14 deployment target.

These tests exercise failure paths independently of Garmin endpoint availability. Live website sign-in, saved-session restoration, several hours of unattended refresh and actual WidgetKit gallery execution are now separately confirmed in the [live validation report](native-web-live-validation.md).

## Reproduce

The local default SDK points at a different compiler generation. Select the installed 26.5 SDK explicitly:

```sh
swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -module-cache-path /tmp/garmindesk-ui-module-cache \
  Sources/Shared/*.swift Sources/GarminDesk/AppStore.swift \
  Sources/GarminDesk/GarminWebTransport.swift Sources/GarminDesk/GarminWebSession.swift \
  Sources/GarminDesk/PythonBridge.swift Sources/GarminDesk/Localization.swift \
  Tests/AppStoreSyncTests.swift -o /tmp/garmindesk-host-tests
/tmp/garmindesk-host-tests

swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -module-cache-path /tmp/garmindesk-ui-module-cache \
  Sources/Shared/SyncPolicy.swift Tests/SyncPolicyTests.swift \
  -o /tmp/garmindesk-sync-policy-tests
/tmp/garmindesk-sync-policy-tests
```

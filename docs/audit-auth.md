# Authentication audit — 15 September 2026

## Conclusion

The current connector is an unofficial, best-effort Garmin Connect adapter. A local Mac interface, Keychain and an embedded Python runtime do not make Garmin's private login service a supported personal API. The initial `rate_limit` result does **not** establish an ordinary account quota, an IP block, invalid credentials, a Cloudflare challenge, or a recovery time. Thirty minutes is an application backoff policy, not a verified Garmin reset interval.

The pinned client is current, but our single-mobile-strategy configuration deliberately removes upstream's fallback-based recovery. Keep the stop-on-429 guard. Do not promise that waiting or upgrading will restore this route. First obtain safe stage/status diagnostics, preserve successful sessions independently of metric downloads, and validate a real session restore before declaring the connection complete.

This audit read public sources and local code and exercised synthetic mocks only. It did not read Keychain, use account credentials, or send authenticated network requests. Findings describe `Connector/bridge.py` before the parent's concurrent diagnostic changes; function names remain the durable references.

## Audited artifacts

| Item | Evidence |
| --- | --- |
| Runtime | `garminconnect==0.3.15`, `curl_cffi==0.16.3`, Python 3.12.14; no `garth` dependency in the bridge |
| Current upstream release | PyPI lists 0.3.15, released 12 September 2026, as the newest release when inspected. There is no verified newer release to upgrade to. [PyPI](https://pypi.org/project/garminconnect/) |
| Exact client source | `.venv/lib/python3.12/site-packages/garminconnect/client.py`; SHA-256 `9f0d3bdc5389cfef2a8cac33bddb121b80e083f86c9023906c05c709c749fc90`. The frozen helper and app copy were previously checked against this hash. |
| Source authority | Installed pinned source is authoritative for this build. The public README describes Android SSO while the installed first strategy uses iOS constants. Search/raw-file caches can also lag. [Upstream source](https://github.com/cyberjunky/python-garminconnect/blob/master/garminconnect/client.py), [README](https://github.com/cyberjunky/python-garminconnect/blob/master/README.md) |

## What the authentication flow actually does

1. `make_api` constructs `Garmin(retry_attempts=0, verify_login=False)` and excludes every outer strategy except `mobile+cffi` (`Connector/bridge.py:402`). Our override invokes the dependency's first default TLS profile once.
2. Upstream `_do_mobile_login` sends credentials to `/mobile/api/login` using `GCM_IOS_DARK` and the iOS service URL (`client.py:650`). A requested MFA code goes to the matching mobile verification endpoint. The bridge prevents resubmission to the alternative MFA endpoint.
3. A service ticket is exchanged at `diauth.garmin.com/di-oauth2-service/oauth/token`. Upstream contains four Garmin mobile DI client IDs and tries them sequentially on non-429 failure (`client.py:174`, `client.py:1313`). These are dependency constants, not an OAuth client registered to GarminDesk. The exchange uses a fixed upstream Chrome profile; it does not use the login session's iOS profile.
4. The upstream code can fall back to `JWT_WEB` cookie authentication after DI failure (`client.py:1265`). Our terminal rate-limit sentinel prevents that fallback after a 429, but other exchange failures can still reach it.
5. The bridge independently reads `/userprofile-service/socialProfile` before fetching measurements (`Connector/bridge.py:489`). Consequently `verify_login=False` does not mean that arbitrary issued tokens are accepted as a successful connection. The tradeoff is that API rejection no longer triggers upstream's alternate login strategies.
6. Subsequent `sync` restores DI fields from the Keychain-provided envelope. Upstream refreshes expiring tokens and may refresh/replay an API request once after 401. `retry_attempts=0` does not remove those protocol behaviors.

This is an implementation of Garmin's private mobile/web authentication, separate from Garmin's approved Developer Program OAuth integration.

## Evidence about 429 and current upstream limitations

| Observation | Supported conclusion and limits |
| --- | --- |
| The parent reported one native app sign-in action ending in `rate_limit`, without MFA or a snapshot. | The original build could perform several inner login requests. There is no recorded endpoint, status header or body category from that attempt. Credential validity remains unknown. |
| Installed `_do_mobile_login` distinguishes HTTP 403, HTTP 429, and JSON `error.status-code == "429"` (`client.py:678`, `client.py:683`, `client.py:721`). | The original `rate_limit` was not a generic mapping of 403. It indicates an upstream 429-class result, but does not prove whether the HTTP status itself was 429. |
| Synthetic unguarded upstream sequences: 403/403/403 → connection error; 429/429/429 → rate-limit error; 403/403/429 → rate-limit error; 429/429/403 → connection error. | Before our guard, the last fallback error could replace earlier evidence. One app action was not equivalent to one HTTP request. These are mock results, not the actual server history. |
| HTTP 429 semantics leave request counting and client identification to the server; `Retry-After` is optional. | The status alone cannot identify the scope or duration of throttling. Upstream exception prose asserting an IP limit is an interpretation. [RFC 6585 §4](https://www.rfc-editor.org/rfc/rfc6585#section-4) |
| In discussion #387, the maintainer wrote on 11 August that the first two mobile strategies commonly fail and that later strategies are expected to succeed. Another participant reported repeated credential logins causing prolonged failures. | Session reuse matters and upstream depends on fallback. This discussion predates the current September release; it does not prove that today's iOS implementation fails for every account. [Maintainer discussion](https://github.com/cyberjunky/python-garminconnect/discussions/387) |
| Issue #344 describes April experiments on two accounts suggesting account/client-ID-dependent throttling. | This differs from the IP attribution in other reports. It is a reporter's limited experiment, not Garmin's specification and not this account's diagnosis. We do not adopt its proposed restriction-bypass strategy. [Issue #344](https://github.com/cyberjunky/python-garminconnect/issues/344) |
| Issue #369 reports DI token issuance/refresh followed by API 401, on 0.3.3/master in June. | Issuance and API acceptance are distinct checks. It is a different failure stage/status from the reported initial 429; no evidence establishes a shared cause. The issue is closed, but this audit did not verify a definitive Garmin-side root cause. [Issue #369](https://github.com/cyberjunky/python-garminconnect/issues/369) |

Possible explanations for the present refusal include throttling, a challenge policy, or incompatibility of the selected private client flow. The available observation cannot rank those explanations reliably. A successful ordinary browser login would establish browser account access, not DI API compatibility.

## Concrete code findings

### P1 — Cookie-only success cannot be restored

Upstream sets `jwt_web` after its cookie fallback (`client.py:1292`), but `dumps()` only serializes `di_token`, `di_refresh_token`, and `di_client_id` (`client.py:1504`). `loads()` restores only those fields (`client.py:1578`). Our `unpack_session` requires a nonempty DI token (`Connector/bridge.py:387`). Thus a cookie-only session may appear authenticated and fetch in one helper process, then produce an unusable saved session.

Offline reproduction using the real client: `is_authenticated == True` with a synthetic JWT cookie; serialized keys contain only the three DI fields; `unpack_session` raises `auth`.

Recommendation: require a resumable DI session for this bridge's declared success, or design and test an explicit versioned cookie session format. Merely copying a JWT string into the existing envelope is insufficient. For the current bounded design, fail clearly before presenting a non-restorable connection as complete.

### P1 — A later metric error can discard newly issued or rotated tokens

`execute` calls `fetch_snapshot` before `client.dumps()` (`Connector/bridge.py:496`). Terminal auth/rate-limit errors, a deadline, or failure of all metric groups prevent any session event. A successful login is then lost to the caller. A refresh token rotated during a request can also remain unsaved; whether Garmin invalidates the previous token on rotation was not established.

Offline reproduction: synthetic login and social-profile read completed; `fetch_snapshot` raised `rate_limit`; `dumps()` was never called and no event was emitted.

Recommendation: emit a dedicated sensitive session-update event after validated login and after token changes, with immediate Keychain handling by the host, independently of snapshot success. Preserve known-good measurements on download failure and distinguish “connected, update failed” from “sign-in failed”. Cover refresh-then-download-failure with a mock test.

### P2 — API authentication rejection is currently displayed as a network problem

After an API 401 and its normal refresh/replay, upstream raises `GarminConnectConnectionError` without a structured response (`client.py:1682`, `client.py:1734`). Our `error_code` sees that class and returns `network` (`Connector/bridge.py:303`). This can obscure API-tier rejection such as the failure reported in #369. Login's explicit invalid-password response still maps separately to `auth`.

Offline reproduction against the real client's request method: two mocked 401 responses, one mocked refresh; final exception `GarminConnectConnectionError`; bridge classification `network`.

Recommendation: retain allowlisted structured HTTP/stage metadata at the transport boundary; let the standard first 401 refresh occur, then classify final API 401 as authentication rejection. Avoid parsing raw server messages or blanket-classifying every login 403 as an incorrect password.

### P2 — Private overrides need an explicit compatibility contract

The bridge replaces `_mobile_login_cffi`, `_http_post`, `_api_session` and `cs` (`Connector/bridge.py:402`). Its `AuthFlowStopped(BaseException)` intentionally escapes upstream `except Exception` blocks (`Connector/bridge.py:43`). This is narrowly effective for the pinned client and transport tests, but is not a public extension API.

The first-profile override reduces request volume; it does not repair unsupported client IDs, provide a challenge solution, or guarantee mobile login. Remaining non-429 DI client-ID fallback also means the complete login exchange is not literally one HTTP request.

Recommendation: keep the version pin and terminal 429 behavior; test the adapter against any upgrade before replacing the embedded helper. Prefer an upstream supported no-fallback policy or a small explicitly maintained adapter over accumulating monkey patches. Do not re-enable TLS/profile rotation, proxy switching, alternate client-ID selection or alternate login endpoints to work around an active restriction.

## Browser sign-in and alternatives

- **Garth downgrade:** not a reliable recovery path. Its maintainer's final v0.8.0 release on 28 March 2026 declares the project deprecated after Garmin authentication changes. New logins are not supported; previously obtained OAuth1 tokens may outlive the change. That is different from creating a new session now. [Garth final release](https://github.com/matin/garth/releases/tag/v0.8.0)
- **Browser-assisted third-party examples:** the inspected `garmin-mcp-server` helper takes a browser service ticket and calls legacy `garth.sso.get_oauth1_token` / `exchange`, producing an OAuth1/OAuth2 store. It does not establish compatibility with this bridge's DI store, and its existence does not override Garth's maintenance notice. [Actual helper source](https://github.com/bmccarn/garmin-mcp-server/blob/main/garmin_browser_auth.py)
- **Ordinary Garmin website:** the user can sign in through Garmin's normal interface and use Garmin's supported personal-data export. That provides a legitimate manual path to download account data without changing the connector's network identity. A local importer can consume that archive, but does not supply live synchronization or guarantee all 26 fields until its actual schema is checked. [Garmin support: personal data access](https://support.garmin.com/en-IE/?faq=q22kMdCbU23NUT2Wmspz16)
- **Supported OAuth integration:** Garmin's Developer Program requires application approval, is for business use, and uses OAuth 2.0. Its documented integration is cloud-to-cloud. This is a stronger support contract but does not match a personal local-only application automatically. No public approved personal desktop OAuth bootstrap was found in the reviewed documentation. [Program FAQ](https://developer.garmin.com/gc-developer-program/program-faq/), [Overview](https://developer.garmin.com/gc-developer-program/overview/)

Opening a browser or embedding a web sign-in view is not by itself a working session transfer. A production implementation would need a documented authorization callback/client, or a separately evaluated session adapter. Do not promise that a web view will solve the current server refusal.

## Recommended next verification

The parent owns the authorized live attempt. Record only a stable stage (`sso_login`, `mfa`, `di_exchange`, `profile`, `metrics`), numeric HTTP status, a small allowlist of response-status categories, bounded `Retry-After`, and whether a challenge marker is present. Exclude credentials, authorization headers, cookies, tickets, URLs with query strings, response bodies and health/profile identifiers.

Stop on the first explicit rate limit or challenge. Respect any server-provided wait time; keep local backoff without treating it as a promised recovery time. Do not use automated fallback experiments to infer the rate-limit key.

Connection acceptance should require: successful API validation, a real non-demo measurement snapshot with absent data preserved as absent, a saved resumable session, and a subsequent fresh helper process restoring it without credential login. Until those checks pass, describe the application as implemented with online connectivity still unverified or blocked. If the selected private route remains refused, a user-driven Garmin export plus local import is the concrete fallback for obtaining personal data.

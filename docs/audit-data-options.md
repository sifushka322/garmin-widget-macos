# Audit of Garmin data sources for macOS

Reviewed on September 15, 2026. This is research into public documentation, not confirmation of login or data retrieval for a particular account. Sources are Garmin, Apple, and the libraries' own repositories. No account logins or secret reads were performed during this review. Findings describe the sources as reviewed on that date.

## Conclusion

For a personal Mac app with Body Battery, sleep, stress, and Training Readiness, a local Garmin Connect client with a cache is a practical automatic route. It needs no developer-operated server, but still depends on Garmin's cloud and unofficial authentication. Public interfaces do not establish a fully offline route, without cloud services, a phone, or licenses, that guarantees this complete data set from a fēnix 8 to a Mac.

A supported fallback for real data is a manual **daily Wellness Export**, followed by local FIT parsing. This is separate from exporting a workout. Garmin documents steps, sleep, stress, and HRV; Body Battery and Training Readiness must be verified in the specific archive. [Garmin export instructions](https://support.garmin.com/en-IE/marine/faq/W1TvTPW8JZ6LfJSfK512Q8/)

## Comparison

| Source | Daily metrics | Workouts | Requirements | Suitability |
|---|---|---|---|---|
| Health API + Activity API | Health API confirms Body Battery, sleep, stress, steps, and heart rate; the public list does not promise Training Readiness | Activity API provides details and FIT/TCX/GPX | Garmin business approval, OAuth 2.0, integration with Garmin's cloud | Supported route for a commercial platform; not guaranteed access for a personal widget |
| Local `python-garminconnect` | Methods for Body Battery, sleep, stress, HRV, and readiness; availability depends on the account/device | Yes | User Garmin login, sometimes MFA; a valid session; internet | Broad practical coverage for a personal app, without guaranteed Garmin stability |
| Daily Wellness Export → FIT | Garmin explicitly lists steps, sleep, stress, and HRV; other fields need verification | A separate activity export | Manual Garmin Connect export and a local decoder | Real data for validation and backup import; no background synchronization |
| Activity FIT | Daily summary not guaranteed | Sensor data, events, laps, and summary of a recorded activity | A device file or Export Original | Suitable for workouts; not a substitute for daily wellness data |
| USB/MTP from fēnix 8 | Depends on available files, with no public guarantee of a complete set | Available files may be imported | USB and functioning MTP access; standard Finder does not provide this | A separate experiment, not a ready reliable Mac route |
| Garmin Connect → Apple Health | Steps, sleep, energy, heart rate, and some other data; Body Battery, Garmin stress, and readiness are not listed | Available without GPS tracks; activity heart rate limited to min/max | Garmin Connect on iPhone, Health permissions, and an additional iPhone → Mac channel | Does not cover the full Garmin data set or work directly through HealthKit on Mac |
| Garmin Health Standard/Companion SDK | Standard: daily metrics; Companion: current values and streams, with history supplied by Health API | Depends on SDK/model | Enterprise access, Android/iOS, confirmed model support and licensing | Not a public SDK for an ordinary Mac app |

## Findings supported by the sources

### Official APIs and direct SDK

The Garmin Connect Developer Program is intended for business/enterprise use. Its FAQ does not promise individual access; the APIs use OAuth 2.0. Free program access does not mean everyone is eligible. When checked in a browser, the public application form displayed only “Stay tuned for more updates on the program.” The FAQ's approval timeline therefore cannot be treated as a promise of immediate access. [FAQ](https://developer.garmin.com/gc-developer-program/program-faq/), [application form](https://www.garmin.com/en-US/forms/GarminConnectDeveloperAccess/)

Health API receives data after the watch uploads it to Garmin Connect. Body Battery, sleep, stress, heart rate, steps, SpO₂, and respiration are explicitly listed. The public page does not confirm the complete Training Readiness/HRV Status set; this requires checking the provided specification and available subscriptions. Activity API describes recorded workout data, not an equivalent of all wellness metrics. [Health API](https://developer.garmin.com/gc-developer-program/health-api/), [Activity API](https://developer.garmin.com/gc-developer-program/activity-api/)

Health SDK is offered to enterprise partners for Android/iOS. Standard SDK can collect daily data without Garmin servers, but the comparison table lists it as incompatible with Garmin Connect. Companion preserves Connect compatibility and provides current values/streams; daily history comes through Health API. The Fenix family is listed, but exact fēnix 8 and mode support must be confirmed with Garmin. No public macOS SDK is advertised here. [Garmin Health SDK](https://developer.garmin.com/health-sdk/)

### Files, USB, and backup import

Garmin distinguishes activity exports from daily wellness exports. For wellness: profile → Account Settings → Account Information → date → Export. The result is a ZIP containing the day's original FIT files. A full account export is a separate request followed by an emailed link; Garmin states a typical 48 hours but allows up to 30 days. It is suitable for archiving, not a current widget. [Garmin instructions](https://support.garmin.com/en-IE/marine/faq/W1TvTPW8JZ6LfJSfK512Q8/)

FIT is a message container, not a promise of a fixed data set. Activity FIT stores an active session; the FIT SDK decodes present messages but cannot create missing metrics. Even a wellness FIT file does not establish that our parser supports every proprietary field. [FIT file types](https://developer.garmin.com/fit/file-types/), [official Python FIT SDK](https://github.com/garmin/fit-python-sdk)

fēnix 8 AMOLED/Solar is explicitly listed among MTP devices. Garmin does not promise access to their system files through macOS and recommends Windows; only one Garmin application can use a device at a time. Garmin Express on Mac supports syncing watches with a Garmin Connect account, but is not a documented local API for our app. [Garmin MTP](https://support.garmin.com/en-US/?faq=CZqibgTHMb0dAYEaj2UiU7), [fēnix 8 manual](https://www8.garmin.com/manuals/webhelp/GUID-EECCAC99-90D6-4AB1-9A3A-EC433D3365E2/EN-US/fenix_8_Series_OM_EN-US.pdf)

### Apple Health

Garmin lists active/resting energy, body fat/BMI, flights climbed, heart rate, sleep, steps, distance, water, weight, and workouts. Body Battery, Garmin stress, and Training Readiness are absent from the list. To transfer data, Connect must be in the foreground after successful watch synchronization. This introduces another delay; activity data omits GPS tracks and limits heart rate to min/max. [Garmin → Apple Health](https://support.garmin.com/sv-SE/?faq=lK5FPB9iPF5PXFkIpFlFPA)

macOS has no HealthKit store: the framework's presence does not enable reading Health data. A separate iPhone app would therefore need to read permitted records and send them to the Mac. Local transfer without our own cloud is possible as custom development, but does not provide a ready path to the full Garmin data set. [Apple: HealthKit](https://developer.apple.com/documentation/healthkit/about-the-healthkit-framework)

### Unofficial client and Connect IQ

`python-garminconnect` is maintained and uses its own SSO client, tokens, and MFA. It accesses Garmin services rather than connecting directly to the watch. The older `garth` was discontinued after Garmin authentication changes; its author warns that new logins no longer work. Neither an indefinite session nor a guaranteed request interval can be promised. [python-garminconnect](https://github.com/cyberjunky/python-garminconnect), [Garth](https://github.com/matin/garth)

Connect IQ lets a watch app read sources such as SensorHistory, including Body Battery. History depth depends on the model. This is a reason to investigate a separate watch companion, not proof of access to every sleep/readiness field or a ready direct macOS channel. [Garmin SensorHistory](https://developer.garmin.com/connect-iq/api-docs/Toybox/SensorHistory.html)

## Recommendations for the app at the time of review

These are engineering conclusions drawn from the limitations above:

1. Primary route: local connector → Garmin Connect → normalized local cache → UI and WidgetKit. Treat the connection as working only after successfully reading nonempty account data, not merely receiving a token.
2. Before promising each card, compare its value and timestamp with Garmin Connect/the watch. Distinguish the last measurement, watch sync time, and HTTP check time. Do not label average daily stress as current stress.
3. If one metric fails, preserve valid others; an unavailable value means `no data`, not `0`. Require session recovery after 401 and pause after 429; do not repeatedly attempt login at short intervals.
4. Fallback: import a user-provided wellness ZIP/FIT. First inspect a real archive and its recognized fields; clearly show the import date and data source. Do not imply automatic refresh.
5. The repository may contain our complete client, normalization, UI, and import code, but no user tokens, passwords, real FIT/JSON files, or server keys. “No developer-operated server” means no infrastructure of our own; internet access and Garmin remain necessary for the automatic Connect route.
6. Ship a pinned, verified connector version and update it separately from the UI. GitHub Actions is unnecessary for synchronization: it should run on the user's Mac, with secrets and health data kept outside the repository.

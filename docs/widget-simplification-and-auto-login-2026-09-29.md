# Widget simplification and automatic sign-in — 29 September 2026

Local version: 0.7.1 (17).

The main measurement keeps one labeled scale. Supporting values use equal-size
numbers and at most one short assessment; they no longer repeat scales or generic
explanations. Duplicate assessments and matching historical dates are suppressed.
Sleep and its stages use hours:minutes, while help and VoiceOver retain localized
units and the full interpretation. Primary values reserve their height so dense
supporting content cannot compress their font.

Account settings now offer optional automatic sign-in. The user enters their
login and password once in the app; existing web cookies do not reveal a password.
Credentials are stored only in the device-local, non-synchronizing macOS Keychain
under `com.mikhail.garmindesk` / `garmin-auto-login`. They never enter preferences,
widget snapshots, diagnostics or the app bundle. Forgetting the saved login keeps
the current website session; disconnect removes both.

Session restoration first reuses WebKit cookies. API 401 responses, missing
Connect documents, and Garmin sign-in redirects all take the same bounded renewal
path. If a normal SSO form is required, the saved login can submit it once per
connection attempt. Swift validates the exact HTTPS SSO origin and frame; the
isolated page script revalidates the origin, form action and submit-button action.
It ignores password-change forms, OTP controls and visible CAPTCHA/challenge UI.
A rejected password or verification requirement pauses unattended work. Locked
Keychain access remains a transient sync failure so a later unlock can recover.
Normal Garmin MFA stays in its website window. The app does not read cookies or
extract passwords entered in that window.

Initial local validation uses synthetic accounts and data, not the owner's credentials. The publication report records the final CI checks after the account-isolation review:

- 255 AppStore lifecycle/cache checks, including saved-login storage failure,
  removal, disconnection and exclusion from preferences.
- 59 web-boundary checks, including exact SSO origins and one-attempt policy.
- 84 existing API JavaScript checks and 24 new form-submission checks: literal
  credential arguments, React-compatible input events, wrong origins, external
  form/submit destinations, disabled/missing fields, OTP and challenge states.
- 18,653 localization checks across all twelve languages and 118 widget-selection
  checks.
- 1,254 synthetic widget renders and 12 connection-settings renders. Russian
  small/medium/large day, sport and sleep widgets and light/dark settings reviewed.
- Native release app and all five WidgetKit kinds built for arm64 / macOS 14 using
  SDK 26.5. Packaging verifies versions, system-only dependencies and signatures.

Local outputs are in `build/audit/simplify-login/`. Actual password-based recovery
against Garmin cannot be verified until the user saves credentials; no password
was requested in chat, inspected from another app or used during these tests.

The verified 0.7.1 app was installed in `/Applications/GarminDesk.app`; the previous
0.7.0 bundle is backed up under `build/backups/`. Installed host and extension
hashes match the candidate. Preferences were unchanged during installation. The
reopened app retained its connected Garmin session; the new automatic-sign-in
settings and empty secure password field were verified in the installed UI and
left open for the user. No saved account password was available for a live
credential-recovery test.

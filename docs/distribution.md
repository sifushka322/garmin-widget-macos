# Installation and distribution

GarminDesk is distributed through [GitHub Releases](https://github.com/sifushka322/garmin-widget-macos/releases) as a ready-to-use app. Users do not need Python, Homebrew, Xcode, or additional libraries.

## Version 0.6.0

Apple Silicon (`arm64`) packages are listed below. Equivalent Intel packages use the `x86_64` suffix:

- `GarminDesk-0.6.0-arm64.dmg` — the app, an Applications shortcut, and installation instructions.
- `GarminDesk-0.6.0-arm64.zip` — an alternative archive of the same app.
- `GarminDesk-0.6.0-arm64-SHA256.txt` — archive checksums.

Packages target macOS 14+. The exact build, package checks, CI results and on-device observations are recorded in the [final validation report](releases/validation/0.6.0-final-audit.md).

## Installation without a paid signing certificate

1. Open the DMG, drag GarminDesk.app onto Applications, then eject the disk. For a ZIP, extract the archive and move the app to Applications.
2. Open GarminDesk. It runs from a monochrome watch icon in the menu bar, without a Dock icon. Use this menu for refresh, settings and Quit.
3. Sign in to Garmin Connect under **Garmin account**. Under **Widgets**, choose Colorful, Light, or Dark and preview the five widget types. No profile setup is needed.
4. Right-click the desktop → **Edit Widgets → GarminDesk**. Add the kind and size you want.

Clicking a widget opens its corresponding view in the app. Closing the window keeps background synchronization running; **⌘Q** quits the app. New readings require the app to be running, internet access, and a watch synced with Garmin Connect.

The package uses ad-hoc signing without an Apple Account, paid Developer ID certificate, or notarization. This does not grant automatic Gatekeeper trust. If macOS reports an unidentified developer or missing notarization, first try opening your trusted app, then use **System Settings → Privacy & Security → Open Anyway**. Enter your Mac password only in the system prompt. These instructions do not apply to malware or damaged-app warnings; managed Macs may not allow this confirmation. [Apple's instructions](https://support.apple.com/102445).

## Package contents and privacy

The standard bundle contains a native Swift executable, `GarminDeskWidgets.appex`, the selected icon, and localized resources. The Garmin connection uses system WebKit. User caches, website sessions, passwords, and cookies are not copied into the bundle.

The host stores data locally in Application Support. The sandboxed extension reads only the dedicated `Widgets/widget-data.json` snapshot through a narrowly scoped read-only permission. The snapshot contains no passwords or cookies. The selected local configuration does not require an App Group.

The standard build uses five StaticConfiguration kinds: Summary, Day, Sport, Sleep, and Training calendar. Existing four kind identifiers are preserved; Day is added. There are no user profiles or assignments. The former optional App Intents profile prototype is retired, and requesting its old build flags fails explicitly instead of changing the widget model based on the installed toolchain. Custom installations of that unreleased prototype require removing/re-adding widgets.

App preferences store language, app appearance, widget appearance, Summary’s ordered measurement selection, and refresh interval. During the transition, the private widget snapshot includes a fixed compatibility projection for older running extensions; it is not an editable profile feature. See the [migration audit](widget-simplification-audit.md).

## For developers

A Mac with a compatible Swift compiler and macOS SDK is required. The script compiles native code directly using `xcrun swiftc`, without Swift Package Manager.

```bash
APP_VERSION=0.6.0 APP_BUILD=15 CONFIGURATION=release bash scripts/build-app.sh
bash scripts/verify-release.sh build/GarminDesk.app
bash scripts/package-release.sh
```

`build-app.sh` builds the app and extension, generates the icon, applies ad-hoc signatures, and verifies the bundle. `package-release.sh` packages the built app into ZIP/DMG files with SHA-256 checksums; it does not install the app or publish a release.

The current source and published release are **0.6.0 build 15**.

| Variable | Purpose |
| --- | --- |
| `GARMIN_SDK_PATH` | Explicit path to an SDK compatible with the compiler |
| `CONFIGURATION` | `release` by default; `debug` for development |
| `GARMIN_CREATE_DMG=0` | Create only a ZIP and its checksum |
| `GARMIN_SIGNING_IDENTITY` | Defaults to `-`: ad-hoc signing without a paid certificate |
| `GARMIN_APP_GROUP` | Unused by the selected release; a separate configuration with a real Apple Team |
| `INCLUDE_LEGACY_CONNECTOR=1` | Explicitly build and embed the previous Python connector; disabled by default |

The legacy connector requires Python only on the build machine. When enabled, its standalone runtime and required dependency licenses are included in the app. The standard package neither builds nor includes it.

The workflow in `.github/workflows/build.yml` reads the version from `Resources/Info.plist` and checks that it matches the extension. A normal push runs checks and builds. A commit in `main` with the exact message `release: vX.Y.Z` also prepares a **draft release** after all jobs succeed; the manual workflow has a separate `publish_release` flag with the same result. Neither a public release nor `latest` is assigned automatically. Builds with the legacy connector are excluded from releases. Existing releases are not overwritten.

## Before publication

Release evidence and the owner's publication authorization are recorded in the [validation report](releases/validation/0.6.0-final-audit.md). The following is the standard validation process.

Verify the exact app and archives being released: versions, nested signatures, architecture, system dependencies, checksums, and absence of private runtime files. Then download the packages from the draft and complete the [upgrade validation from the previous release](widget-upgrade-validation.md) on a Mac with a graphical session, including existing widgets and the gallery. A separate test machine can be used; the owner's Mac does not need to be changed. Only after validation succeeds should the same draft be published and marked `latest`; a rebuild requires another validation run. Details: [publication checklist](publication-checklist.md), [source file list](source-publication-files.txt).

The current source is available for noncommercial use under the [PolyForm Noncommercial License 1.0.0](../LICENSE.md), with [required notices](../NOTICE.md). Commercial use requires separate permission. Retain license notices for third-party dependencies actually included in the package. These terms are documented for the current source; this statement does not retrospectively describe the contents of previously published packages.

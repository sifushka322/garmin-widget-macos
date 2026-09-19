# Publication checklist

The owner has authorized publishing the repository and ready-to-use app on GitHub. This checklist verifies the content and exact release; it does not introduce another approval requirement.

## 0.6.0 publication record

The [final validation report](releases/validation/0.6.0-final-audit.md) records the exact build, CI run, package hashes, on-device observations and the owner's informed publication instruction. The report and public notes are hash-bound to the release approval; the publication guard verifies the same six packages from the successful candidate run.

## 0.5.0 publication record

Normal upgrade validation: NOT RUN

Published at the owner’s explicit request after disclosure that normal system-widget upgrade validation remains unverified; desktop/gallery automation was unavailable.

The [publication record](releases/validation/0.5.0-publication.md) documents the approved exception and exact tested build. This exception does not constitute a passing upgrade report. The steps below remain the standard validation process.

## Source files

- Use the [verified file list](source-publication-files.txt) and [audit report](source-publication-audit-2026-09-16.md). Compare staged files with the list before committing: `.gitignore` does not exclude files that are already tracked.
- Publication includes Swift/Python source, synthetic tests, scripts, Resources, documentation, and the workflow. Including the legacy connector's source does not mean its Python runtime is included in the standard app.
- Exclude `build/`, `.venv/`, personal exports, runtime caches, WebKit storage, credentials, and local tool configuration.
- Include the selected [PolyForm Noncommercial License 1.0.0](../LICENSE.md) and [required notices](../NOTICE.md). Describe the source as available for noncommercial use; commercial use requires separate permission. Do not describe this license as OSI-approved open source. Retain notices for third-party dependencies actually included in the package.

## Package and draft release

1. Verify the version and build in the source plists and built host/widget bundles. Every candidate must have its own matching version/build; the previous public baseline for 0.6.0 is 0.5.0 build 11.
2. Wait for successful CI on Apple Silicon and Intel, including native and web contracts, rendering, sandbox isolation, signatures, and system dependencies.
3. Use the ZIP/DMG files and SHA-256 checksums from that exact run. Packages must contain no Python runtime, user data, or developer home paths.
4. Prepare a **draft** for the exact verified commit, upload the packages, and compare SHA-256 checksums of all six uploaded files against the verified packages. Successful CI and matching files do not yet permit publishing the draft or marking it latest.

## Required upgrade validation

5. On a test Mac with a graphical session, install the previous public release and place its widgets on the desktop. A separate test Mac can be used; the owner's Mac is not required.
6. Download the signed candidate from the draft, verify its checksum, and perform a normal Finder upgrade: quit the app, replace it in Applications using the DMG, and reopen it. Test the downloaded package, not a separate local build.
7. Complete the [WidgetKit upgrade validation](widget-upgrade-validation.md): the new gallery icon, all five kinds in all three sizes, existing widgets, preserved Summary selection from 0.5.0 (or migration from older profile preferences), distinct appearances, and content refresh. Do not clear caches, re-register bundles, terminate system services, restart the extension, remove widgets, or reboot the Mac before these checks.
8. Save a report containing before/after versions, macOS/architecture, candidate commit, downloaded package SHA-256, installed host/widget signatures and versions, and screenshots without personal data. Record results separately for each claimed configuration. Do not extrapolate success on one OS/architecture to others.
9. Any old logo, old snapshot, or broken existing widget blocks publishing the draft. Recovery using service commands does not turn a failed upgrade into a passing acceptance result. After changing the candidate, repeat validation with the new package.
10. Only after upgrade validation passes, publish **the same verified draft** and mark it latest. Release notes must state actual results and remaining validation limits, or link the exact public validation report that records them. Synthetic tests do not verify live Garmin sign-in, system-widget upgrades, or compatibility with every macOS version.

Packages remain ad-hoc signed without Developer ID/notarization. The previous 0.4.0 workflow published immediately after CI; the upgrade failure discovered on September 16, 2026 showed that this was insufficient. By default, the new process retains CI output as a draft until validation on a real Mac. The published release descriptions were later translated to English; their downloadable assets remain unchanged. Validation of [0.3.0](releases/0.3.0.md) and [0.2.0](validation.md) remains historical evidence.

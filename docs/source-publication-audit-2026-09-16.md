# Source publication audit — 16 September 2026

Scope: the source tree prepared for the authorized public GarminDesk repository and version 0.3.0. The audit did not publish, initialize Git, launch the app or inspect the user's stored Garmin data. Git initialization was performed separately by the parent task; staging is still a separate final step.

## Candidate set

The exact relative paths are in [source-publication-files.txt](source-publication-files.txt). The allowlist covers `Sources/`, `Connector/`, `Tests/`, `scripts/`, `Resources/`, `docs/`, `.github/`, `Package.swift`, `README.md` and `.gitignore`. Generated build outputs, development environments and ignored files are excluded. The list records the reviewed file set, not a hash freeze of files still being edited for the release.

- Swift app/WidgetKit source, legacy connector source and synthetic tests are included.
- The selected round-watch app icon and its source artwork are included. Earlier branding/UI concept images are generated design illustrations with documented demo data, not captures of the user's Garmin account.
- Historical authentication, data-format and runtime reports are retained as history. They record structural results and validation outcomes without personal measurement values, account IDs or original personal export filenames.
- No runtime cache/session JSON, FIT/GPX/TCX/HAR export, certificate, key, browser-cookie dump, app bundle or virtual environment is in the candidate set. Personal exports remain outside the source set.

## Read-only scan

All candidate bytes, including image assets, were checked for literal developer home paths, private-key headers, recognizable GitHub credentials, JWT-shaped literals, email literals and quoted password/access/refresh-token assignments. No real secret or developer home path was found. The email matches were classified without recording addresses: nine test matches use the reserved `example.invalid` domain; one branding match is a Retina asset's `@2x.png` filename.

Source review confirmed that the native runtime uses system paths and app-owned WebKit storage; the old embedded `#filePath` development fallback has been removed. Optional development fallback requires `GARMIN_DESK_DEVELOPMENT_ROOT`. Widget snapshots do not contain passwords or cookies.

The ignore rules include `build/`, `.venv/`, local tool configuration, secret/certificate formats, Garmin exports and browser captures. This audit added the current `metric-groups.json` and `sync-policy.json` cache filenames, a training-cache filename, SQLite/browser-storage patterns and `.codex/`/`.agents/` to reduce accidental inclusion.

## Recheck at staging

The parent should compare the final staged paths against the manifest, inspect unexpected additions, and review the staged diff. File content can change between this audit and commit. No history audit or guarantee about future files is implied. Review of `.github/workflows/build.yml` behavior belongs to the separate workflow audit; inclusion in this file list is only a source/privacy check.

No source LICENSE is present. The owner explicitly authorized public source without selecting a license; this audit does not invent a license or make it a publication blocker. A public source tree is not described here as licensed open source.

## Release boundary

Source privacy checks do not substitute for inspection of the exact built app and archives. Version 0.3.0 build 9 checks belong in [release notes](releases/0.3.0.md). Build 7 artifacts and runtime results remain historical and are not reported as build 9 validation.

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Explicitly keep compilation/rendering off the owner's Mac by default.
if [[ "${GITHUB_ACTIONS:-false}" != true && "${GARMIN_ALLOW_LOCAL_TESTS:-0}" != 1 ]]; then
    printf 'Run this suite in GitHub Actions. Local execution requires GARMIN_ALLOW_LOCAL_TESTS=1.\n' >&2
    exit 1
fi
mkdir -p build/audit/module-cache
options=(-parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0"
    -module-cache-path build/audit/module-cache)
shared=(Sources/Shared/*.swift Sources/GarminDesk/Localization.swift)
frameworks=(-framework SwiftUI -framework AppKit -framework WidgetKit -framework WebKit -framework Security -framework ServiceManagement)
for suite in SharedModelTests TrainingPresentationTests SyncPolicyTests GarminPayloadNormalizerTests TrainingModelsTests; do
    xcrun swiftc "${options[@]}" -module-name "$suite" "${shared[@]}" "Tests/$suite.swift" "${frameworks[@]}" -o "build/audit/$suite"
    "build/audit/$suite"
done
host=(Sources/GarminDesk/AppStore.swift Sources/GarminDesk/PythonBridge.swift
    Sources/GarminDesk/GarminWebSession.swift Sources/GarminDesk/GarminWebTransport.swift)
for suite in GarminWebBoundaryTests AppStoreSyncTests; do
    xcrun swiftc "${options[@]}" -module-name "$suite" "${shared[@]}" "${host[@]}" "Tests/$suite.swift" "${frameworks[@]}" -o "build/audit/$suite"
    "build/audit/$suite"
done
xcrun swiftc "${options[@]}" -module-name RenderWidgets "${shared[@]}" Tests/RenderWidgets.swift "${frameworks[@]}" -o build/audit/render-widgets
build/audit/render-widgets build/audit/widgets
xcrun swiftc "${options[@]}" -module-name RenderApp "${shared[@]}" "${host[@]}" \
    Sources/GarminDesk/Views.swift Sources/GarminDesk/TrainingTimelineView.swift Tests/RenderApp.swift \
    "${frameworks[@]}" -o build/audit/render-app
build/audit/render-app build/audit/app

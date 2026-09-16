#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Explicitly keep compilation/rendering off the owner's Mac by default.
if [[ "${GITHUB_ACTIONS:-false}" != true && "${GARMIN_ALLOW_LOCAL_TESTS:-0}" != 1 ]]; then
    printf 'Run this suite in GitHub Actions. Local execution requires GARMIN_ALLOW_LOCAL_TESTS=1.\n' >&2
    exit 1
fi
mkdir -p build/audit build/module-cache
options=(-parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0"
    -module-cache-path build/module-cache)
if [[ -n "${GARMIN_SDK_PATH:-}" ]]; then options+=(-sdk "$GARMIN_SDK_PATH"); fi
xcrun swiftc "${options[@]}" -module-name BrandIconTests Tests/BrandIconTests.swift \
    -framework CoreGraphics -framework ImageIO -o build/audit/BrandIconTests
build/audit/BrandIconTests
shared=(Sources/Shared/*.swift Sources/GarminDesk/Localization.swift)
# Data contracts do not need SwiftUI renderer bodies typechecked repeatedly.
# WidgetConfigurationTests also exercises GarminEntry, so it keeps the full set.
# All three visual executables continue to compile every shared source.
model_sources=()
for source in "${shared[@]}"; do
    case "$source" in
        Sources/Shared/GarminWidgetView.swift|Sources/Shared/SummaryWidgetView.swift|Sources/Shared/TrainingCalendarWidgetView.swift|Sources/Shared/GarminDeskBrandMark.swift|Sources/Shared/GarminDeskBrandGeometry.swift) continue ;;
    esac
    model_sources+=("$source")
done
frameworks=(-framework SwiftUI -framework AppKit -framework WidgetKit -framework WebKit -framework Security -framework ServiceManagement)
for suite in SharedModelTests WidgetConfigurationTests WidgetMetricPolicyTests TrainingCalendarTests TrainingPresentationTests LocalizationTests SyncPolicyTests GarminPayloadNormalizerTests TrainingModelsTests; do
    suite_sources=("${model_sources[@]}")
    if [[ "$suite" == WidgetConfigurationTests ]]; then suite_sources=("${shared[@]}"); fi
    printf 'Compiling and running %s\n' "$suite"
    xcrun swiftc "${options[@]}" -module-name "$suite" "${suite_sources[@]}" "Tests/$suite.swift" "${frameworks[@]}" -o "build/audit/$suite"
    "build/audit/$suite"
done
host=(Sources/GarminDesk/AppStore.swift Sources/GarminDesk/PythonBridge.swift
    Sources/GarminDesk/GarminWebSession.swift Sources/GarminDesk/GarminWebTransport.swift)
for suite in GarminWebBoundaryTests AppStoreSyncTests; do
    printf 'Compiling and running %s\n' "$suite"
    xcrun swiftc "${options[@]}" -module-name "$suite" "${model_sources[@]}" "${host[@]}" "Tests/$suite.swift" "${frameworks[@]}" -o "build/audit/$suite"
    "build/audit/$suite"
done
printf 'Compiling widget visual fixtures\n'
xcrun swiftc "${options[@]}" -module-name RenderWidgets "${shared[@]}" Tests/RenderWidgets.swift "${frameworks[@]}" -o build/audit/render-widgets
printf 'Rendering widget visual fixtures\n'
build/audit/render-widgets build/audit/widgets
printf 'Compiling app visual fixtures\n'
xcrun swiftc "${options[@]}" -module-name RenderApp "${shared[@]}" "${host[@]}" \
    Sources/GarminDesk/Views.swift Sources/GarminDesk/TrainingTimelineView.swift Tests/RenderApp.swift \
    "${frameworks[@]}" -o build/audit/render-app
printf 'Rendering app visual fixtures\n'
build/audit/render-app build/audit/app
printf 'Compiling calendar visual fixtures\n'
xcrun swiftc "${options[@]}" -module-name RenderTrainingCalendar "${shared[@]}" Tests/RenderTrainingCalendar.swift \
    "${frameworks[@]}" -o build/audit/render-training-calendar
printf 'Rendering calendar visual fixtures\n'
build/audit/render-training-calendar build/audit/calendar

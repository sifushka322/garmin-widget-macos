#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
configuration="${CONFIGURATION:-release}"
target_arch="$(uname -m)"
app_version="${APP_VERSION:-0.1.0}"
app_build="${APP_BUILD:-1}"
app_group="${GARMIN_APP_GROUP:-}"
signing_identity="${GARMIN_SIGNING_IDENTITY:--}"
sdk_path="${GARMIN_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
metadata_required="${GARMIN_REQUIRE_APPINTENTS_METADATA:-0}"
if [[ "$signing_identity" != "-" ]]; then metadata_required=1; fi

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    printf 'CONFIGURATION must be debug or release.\n' >&2; exit 1
fi
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$app_build" =~ ^[0-9]+$ ]]; then
    printf 'APP_VERSION must be X.Y.Z; APP_BUILD must be an integer.\n' >&2; exit 1
fi
if [[ "$(uname -s)" != "Darwin" || ( "$target_arch" != "arm64" && "$target_arch" != "x86_64" ) ]]; then
    printf 'Build on an Apple Silicon or Intel Mac.\n' >&2; exit 1
fi
if [[ -n "$app_group" && ! "$app_group" =~ ^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$ ]]; then
    printf 'GARMIN_APP_GROUP must use your actual macOS TeamID.group-name.\n' >&2; exit 1
fi
if [[ -n "$app_group" && "$signing_identity" == "-" ]]; then
    printf 'A team-based App Group requires a real signing identity, not ad-hoc signing.\n' >&2; exit 1
fi

metadata_processor="${GARMIN_APPINTENTS_PROCESSOR:-}"
if [[ -z "$metadata_processor" ]]; then
    metadata_processor="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
fi
if [[ -n "$metadata_processor" && ! -x "$metadata_processor" ]]; then
    printf 'App Intents metadata processor is not executable: %s\n' "$metadata_processor" >&2; exit 1
fi
if [[ -z "$metadata_processor" && "$metadata_required" == "1" ]]; then
    printf 'Full widget configuration needs appintentsmetadataprocessor from a matching Xcode toolchain.\n' >&2
    printf 'Command Line Tools alone do not contain it. No complete widget build was produced.\n' >&2
    exit 1
fi

mkdir -p "$project_dir/build/native/$configuration" "$project_dir/build/module-cache"
staging_dir="$(mktemp -d "$project_dir/build/.widgets.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
widget_bundle="$staging_dir/GarminDeskWidgets.appex"
mkdir -p "$widget_bundle/Contents/MacOS" "$widget_bundle/Contents/Resources"
widget_binary="$widget_bundle/Contents/MacOS/GarminDeskWidgets"
const_values="$project_dir/build/native/$configuration/GarminDeskWidgets.swiftconstvalues"
sources=("$project_dir"/Sources/Shared/*.swift
    "$project_dir/Sources/GarminDesk/Localization.swift"
    "$project_dir"/Sources/GarminDeskWidgets/*.swift)
swift_options=(-parse-as-library -application-extension -swift-version 5
    -module-name GarminDeskWidgets -target "$target_arch-apple-macos14.0"
    -sdk "$sdk_path" -module-cache-path "$project_dir/build/module-cache"
    -whole-module-optimization
    -emit-const-values-path "$const_values"
    -Xfrontend -const-gather-protocols-file
    -Xfrontend "$project_dir/Resources/AppIntentsProtocols.json")
if [[ "$configuration" == "debug" ]]; then swift_options+=(-g -Onone); else swift_options+=(-O); fi
if [[ -z "$metadata_processor" ]]; then
    swift_options+=(-D GARMIN_WIDGET_STATIC_CONFIGURATION)
    widget_configuration_mode="static"
else
    widget_configuration_mode="profile-intents"
fi
# App extensions enter Foundation's XPC lifecycle, not a plain executable main.
# Without this entry point WidgetBundle.main can return immediately on macOS 26.
xcrun swiftc "${swift_options[@]}" "${sources[@]}" \
    -framework SwiftUI -framework WidgetKit -framework AppIntents \
    -framework Foundation -framework Security \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$widget_binary"
/usr/bin/lipo "$widget_binary" -verify_arch "$target_arch"
cp "$project_dir/Resources/Widgets-Info.plist" "$widget_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$widget_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_build" "$widget_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GARMIN_APP_GROUP $app_group" "$widget_bundle/Contents/Info.plist"

if [[ -d "$project_dir/Resources/Widgets" ]]; then
    /usr/bin/ditto "$project_dir/Resources/Widgets" "$widget_bundle/Contents/Resources"
fi
if [[ -n "$metadata_processor" ]]; then
    swiftc_path="$(xcrun --find swiftc)"
    toolchain_dir="$(cd -- "$(dirname -- "$swiftc_path")/../.." && pwd)"
    xcode_build="$(xcodebuild -version | awk '/Build version/ {print $3}')"
    metadata_arguments=(--toolchain-dir "$toolchain_dir"
        --module-name GarminDeskWidgets --output "$widget_bundle/Contents/Resources"
        --sdk-root "$sdk_path" --xcode-version "$xcode_build"
        --platform-family macOS --deployment-target 14.0
        --target-triple "$target_arch-apple-macos14.0"
        --binary-file "$widget_binary" --swift-const-vals "$const_values"
        --compile-time-extraction)
    for source in "${sources[@]}"; do metadata_arguments+=(--source-files "$source"); done
    "$metadata_processor" "${metadata_arguments[@]}"
    if [[ ! -s "$widget_bundle/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]; then
        printf 'App Intents extraction produced no metadata; widget build is incomplete.\n' >&2; exit 1
    fi
    /usr/libexec/PlistBuddy -c 'Set :GARMIN_APPINTENTS_METADATA_AVAILABLE true' "$widget_bundle/Contents/Info.plist"
else
    printf 'Static widget variant compiled: Overview, Sport, Sleep, and Training use profiles assigned in GarminDesk.\n'
    printf 'Per-instance App Intents selection needs a full Xcode toolchain. Validate gallery runtime for each release.\n'
fi
/usr/libexec/PlistBuddy -c 'Set :GARMIN_WIDGET_CONFIGURATION_AVAILABLE true' "$widget_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GARMIN_WIDGET_CONFIGURATION_MODE $widget_configuration_mode" "$widget_bundle/Contents/Info.plist"

/usr/bin/plutil -lint "$widget_bundle/Contents/Info.plist"
if [[ -e "$project_dir/build/GarminDeskWidgets.appex" ]]; then
    mv "$project_dir/build/GarminDeskWidgets.appex" "$staging_dir/previous.appex"
fi
mv "$widget_bundle" "$project_dir/build/GarminDeskWidgets.appex"
printf 'Widget extension: %s\n' "$project_dir/build/GarminDeskWidgets.appex"

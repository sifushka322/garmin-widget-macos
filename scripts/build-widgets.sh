#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
configuration="${CONFIGURATION:-release}"
target_arch="$(uname -m)"
app_version="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")}"
app_build="${APP_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$project_dir/Resources/Info.plist")}"
app_group="${GARMIN_APP_GROUP:-}"
signing_identity="${GARMIN_SIGNING_IDENTITY:--}"
sdk_path="${GARMIN_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
metadata_required="${GARMIN_REQUIRE_APPINTENTS_METADATA:-0}"
if [[ "$metadata_required" == "1" || -n "${GARMIN_APPINTENTS_PROCESSOR:-}" ]]; then
    printf 'Profile-based App Intents builds are retired. GarminDesk now ships five fixed StaticConfiguration widgets.\n' >&2
    exit 1
fi

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

mkdir -p "$project_dir/build/native/$configuration" "$project_dir/build/module-cache"
staging_dir="$(mktemp -d "$project_dir/build/.widgets.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
widget_bundle="$staging_dir/GarminDeskWidgets.appex"
mkdir -p "$widget_bundle/Contents/MacOS" "$widget_bundle/Contents/Resources"
widget_binary="$widget_bundle/Contents/MacOS/GarminDeskWidgets"
sources=("$project_dir"/Sources/Shared/*.swift
    "$project_dir/Sources/GarminDesk/Localization.swift"
    "$project_dir"/Sources/GarminDeskWidgets/*.swift)
swift_options=(-parse-as-library -application-extension -swift-version 5
    -module-name GarminDeskWidgets -target "$target_arch-apple-macos14.0"
    -sdk "$sdk_path" -module-cache-path "$project_dir/build/module-cache"
    -whole-module-optimization)
if [[ "$configuration" == "debug" ]]; then swift_options+=(-g -Onone); else swift_options+=(-O); fi
widget_configuration_mode="static"
# App extensions enter Foundation's XPC lifecycle, not a plain executable main.
# Without this entry point WidgetBundle.main can return immediately on macOS 26.
xcrun swiftc "${swift_options[@]}" "${sources[@]}" \
    -framework SwiftUI -framework WidgetKit \
    -framework Foundation -framework Security \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$widget_binary"
/usr/bin/lipo "$widget_binary" -verify_arch "$target_arch"
cp "$project_dir/Resources/Widgets-Info.plist" "$widget_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$widget_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_build" "$widget_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GARMIN_APP_GROUP $app_group" "$widget_bundle/Contents/Info.plist"

/usr/libexec/PlistBuddy -c 'Set :GARMIN_APPINTENTS_METADATA_AVAILABLE false' "$widget_bundle/Contents/Info.plist"
printf 'Five fixed widgets compiled: Summary, Day, Sport, Sleep, and Training calendar.\n'
/usr/libexec/PlistBuddy -c 'Set :GARMIN_WIDGET_CONFIGURATION_AVAILABLE true' "$widget_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GARMIN_WIDGET_CONFIGURATION_MODE $widget_configuration_mode" "$widget_bundle/Contents/Info.plist"

/usr/bin/plutil -lint "$widget_bundle/Contents/Info.plist"
if [[ -e "$project_dir/build/GarminDeskWidgets.appex" ]]; then
    mv "$project_dir/build/GarminDeskWidgets.appex" "$staging_dir/previous.appex"
fi
mv "$widget_bundle" "$project_dir/build/GarminDeskWidgets.appex"
printf 'Widget extension: %s\n' "$project_dir/build/GarminDeskWidgets.appex"

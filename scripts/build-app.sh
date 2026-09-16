#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
cd "$project_dir"

configuration="${CONFIGURATION:-release}"
app_version="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")}"
app_build="${APP_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$project_dir/Resources/Info.plist")}"
target_arch="$(uname -m)"
connector_dir="${CONNECTOR_DIST_DIR:-$project_dir/build/connector-dist/garmin-bridge}"
app_group="${GARMIN_APP_GROUP:-}"
signing_identity="${GARMIN_SIGNING_IDENTITY:--}"
include_legacy_connector="${INCLUDE_LEGACY_CONNECTOR:-0}"
if [[ "$include_legacy_connector" != "0" && "$include_legacy_connector" != "1" ]]; then
    printf 'INCLUDE_LEGACY_CONNECTOR must be 0 or 1.\n' >&2; exit 1
fi

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    printf 'CONFIGURATION must be debug or release.\n' >&2
    exit 1
fi
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$app_build" =~ ^[0-9]+$ ]]; then
    printf 'APP_VERSION must be X.Y.Z; APP_BUILD must be an integer.\n' >&2
    exit 1
fi
if [[ "$(uname -s)" != "Darwin" || ( "$target_arch" != "arm64" && "$target_arch" != "x86_64" ) ]]; then
    printf 'Build on an Apple Silicon or Intel Mac.\n' >&2
    exit 1
fi

if [[ "$include_legacy_connector" == "1" ]]; then
    if [[ "${SKIP_BRIDGE_BUILD:-0}" != "1" ]]; then bash "$script_dir/build-connector.sh"; fi
    if [[ ! -x "$connector_dir/garmin-bridge" || ! -d "$connector_dir/_internal" ]]; then
        printf 'Standalone connector missing at %s. Run scripts/build-connector.sh first.\n' "$connector_dir" >&2
        exit 1
    fi
    /usr/bin/lipo "$connector_dir/garmin-bridge" -verify_arch "$target_arch"
    connector_notices="${CONNECTOR_NOTICES_FILE:-$(dirname -- "$connector_dir")/THIRD_PARTY_NOTICES.txt}"
    if [[ ! -s "$connector_notices" ]]; then
        printf 'Legacy connector redistribution notices are missing: %s\n' "$connector_notices" >&2; exit 1
    fi
fi

bash "$script_dir/generate-icon.sh"

if [[ "${SKIP_WIDGET_BUILD:-0}" != "1" ]]; then
    bash "$script_dir/build-widgets.sh"
fi
widget_bundle="$project_dir/build/GarminDeskWidgets.appex"
if [[ ! -x "$widget_bundle/Contents/MacOS/GarminDeskWidgets" ]]; then
    printf 'Widget extension missing. Run scripts/build-widgets.sh first.\n' >&2; exit 1
fi
/usr/bin/lipo "$widget_bundle/Contents/MacOS/GarminDeskWidgets" -verify_arch "$target_arch"
widget_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$widget_bundle/Contents/Info.plist")"
widget_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$widget_bundle/Contents/Info.plist")"
if [[ "$widget_version" != "$app_version" || "$widget_build" != "$app_build" ]]; then
    printf 'Widget and app versions differ. Rebuild without SKIP_WIDGET_BUILD=1.\n' >&2; exit 1
fi

swift_bin_dir="$project_dir/build/native/$configuration"
if [[ "${SKIP_SWIFT_BUILD:-0}" != "1" ]]; then
    mkdir -p "$swift_bin_dir" "$project_dir/build/module-cache"
    swift_options=(-parse-as-library -swift-version 5 -module-name GarminDesk
        -target "$target_arch-apple-macos14.0"
        -module-cache-path "$project_dir/build/module-cache")
    if [[ -n "${GARMIN_SDK_PATH:-}" ]]; then
        if [[ ! -d "$GARMIN_SDK_PATH" ]]; then
            printf 'GARMIN_SDK_PATH does not exist: %s\n' "$GARMIN_SDK_PATH" >&2
            exit 1
        fi
        swift_options+=(-sdk "$GARMIN_SDK_PATH")
    fi
    if [[ "$configuration" == "debug" ]]; then
        swift_options+=(-g -Onone)
    else
        swift_options+=(-O)
    fi
    # The app uses system frameworks only. Invoke the compiler directly so
    # packaging does not depend on SwiftPM or its BuildServerProtocol runtime.
    xcrun swiftc "${swift_options[@]}" "$project_dir"/Sources/Shared/*.swift "$project_dir"/Sources/GarminDesk/*.swift \
        -framework SwiftUI -framework AppKit -framework Security \
        -framework ServiceManagement -framework WidgetKit -o "$swift_bin_dir/GarminDesk"
fi
if [[ ! -x "$swift_bin_dir/GarminDesk" ]]; then
    printf 'Swift executable missing at %s.\n' "$swift_bin_dir/GarminDesk" >&2
    exit 1
fi
/usr/bin/lipo "$swift_bin_dir/GarminDesk" -verify_arch "$target_arch"

mkdir -p "$project_dir/build"
staging_dir="$(mktemp -d "$project_dir/build/.bundle.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
staged_app="$staging_dir/GarminDesk.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$staged_app/Contents/PlugIns"
cp "$swift_bin_dir/GarminDesk" "$staged_app/Contents/MacOS/GarminDesk"
cp "$project_dir/Resources/Info.plist" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_build" "$staged_app/Contents/Info.plist"
legacy_included=false
if [[ "$include_legacy_connector" == "1" ]]; then legacy_included=true; fi
/usr/libexec/PlistBuddy -c "Set :GARMIN_LEGACY_CONNECTOR_INCLUDED $legacy_included" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GARMIN_APP_GROUP $app_group" "$staged_app/Contents/Info.plist"
metadata_available="$(/usr/libexec/PlistBuddy -c 'Print :GARMIN_APPINTENTS_METADATA_AVAILABLE' "$widget_bundle/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :GARMIN_APPINTENTS_METADATA_AVAILABLE $metadata_available" "$staged_app/Contents/Info.plist"
widget_configuration_available="$(/usr/libexec/PlistBuddy -c 'Print :GARMIN_WIDGET_CONFIGURATION_AVAILABLE' "$widget_bundle/Contents/Info.plist")"
widget_configuration_mode="$(/usr/libexec/PlistBuddy -c 'Print :GARMIN_WIDGET_CONFIGURATION_MODE' "$widget_bundle/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :GARMIN_WIDGET_CONFIGURATION_AVAILABLE $widget_configuration_available" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GARMIN_WIDGET_CONFIGURATION_MODE $widget_configuration_mode" "$staged_app/Contents/Info.plist"
/usr/bin/ditto "$widget_bundle" "$staged_app/Contents/PlugIns/GarminDeskWidgets.appex"
if [[ -f "$project_dir/Resources/AppIcon.icns" ]]; then
    cp "$project_dir/Resources/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
else
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$staged_app/Contents/Info.plist"
fi
# Never copy source directories, caches, credentials, virtualenvs, or user data.
if [[ "$include_legacy_connector" == "1" ]]; then
    mkdir -p "$staged_app/Contents/Resources/Connector"
    /usr/bin/ditto "$connector_dir" "$staged_app/Contents/Resources/Connector/garmin-bridge"
    cp "$connector_notices" "$staged_app/Contents/Resources/THIRD_PARTY_NOTICES.txt"
fi

/usr/bin/plutil -lint "$staged_app/Contents/Info.plist"
bash "$script_dir/sign-release.sh" "$staged_app" "$signing_identity"
bash "$script_dir/verify-release.sh" "$staged_app"

app_path="$project_dir/build/GarminDesk.app"
archive_path="$project_dir/build/GarminDesk-$app_version-$target_arch.zip"
# Only replace this script's own fixed output, after the staged app validates.
if [[ -e "$app_path" ]]; then
    mv "$app_path" "$staging_dir/previous-GarminDesk.app"
fi
mv "$staged_app" "$app_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staging_dir/app.zip"
mv -f "$staging_dir/app.zip" "$archive_path"
printf '\nApp: %s\nArchive: %s\n' "$app_path" "$archive_path"
if [[ "$include_legacy_connector" == "1" ]]; then
    printf 'Includes the optional legacy connector and Python runtime.\n'
else
    printf 'Native Swift + system WebKit only; no Python or third-party runtime is bundled.\n'
fi
if [[ "$signing_identity" == "-" ]]; then
    printf 'Ad-hoc build. Widget extension has read-only access to its dedicated local snapshot directory.\n'
fi
printf 'Widget configuration variant: %s. Gallery runtime must be validated separately.\n' "$widget_configuration_mode"
printf 'App Intents metadata included: %s. This script does not notarize or publish.\n' "$metadata_available"

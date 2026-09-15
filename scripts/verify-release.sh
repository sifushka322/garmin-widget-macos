#!/bin/bash
# Structural validation only: no app launch, network, credentials, or user data.
set -euo pipefail
app_path="${1:?Usage: bash scripts/verify-release.sh /path/GarminDesk.app}"
info="$app_path/Contents/Info.plist"
widget="$app_path/Contents/PlugIns/GarminDeskWidgets.appex"
/usr/bin/plutil -lint "$info" "$widget/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$app_path"
architecture="$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/GarminDesk")"
if [[ "$architecture" != "arm64" && "$architecture" != "x86_64" ]]; then
    printf 'Expected a single supported app architecture.\n' >&2; exit 1
fi
/usr/bin/lipo "$widget/Contents/MacOS/GarminDeskWidgets" -verify_arch "$architecture"
for binary in "$app_path/Contents/MacOS/GarminDesk" "$widget/Contents/MacOS/GarminDeskWidgets"; do
    dependencies="$(/usr/bin/otool -L "$binary" | /usr/bin/awk 'NR > 1 { print $1 }')"
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*) ;;
            *) printf 'Unexpected non-system dependency: %s\n' "$dependency" >&2; exit 1 ;;
        esac
    done <<< "$dependencies"
done
if ! /usr/bin/nm -u "$widget/Contents/MacOS/GarminDeskWidgets" | /usr/bin/grep '_NSExtensionMain$' >/dev/null; then
    printf 'Widget binary is missing the system app-extension entry point.\n' >&2; exit 1
fi
legacy="$(/usr/libexec/PlistBuddy -c 'Print :GARMIN_LEGACY_CONNECTOR_INCLUDED' "$info")"
case "$legacy" in
    true)
        connector="$app_path/Contents/Resources/Connector/garmin-bridge"
        test -x "$connector/garmin-bridge"
        test -d "$connector/_internal"
        test -s "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.txt"
        /usr/bin/lipo "$connector/garmin-bridge" -verify_arch "$architecture"
        printf 'PASS: optional legacy connector and its notices are included.\n'
        ;;
    false)
        if [[ -e "$app_path/Contents/Resources/Connector" ]]; then
            printf 'Native-only bundle unexpectedly contains a legacy Connector directory.\n' >&2; exit 1
        fi
        printf 'PASS: native-only bundle; no legacy connector is included.\n'
        ;;
    *) printf 'Legacy connector flag is not a boolean.\n' >&2; exit 1 ;;
esac
for key in CFBundleShortVersionString CFBundleVersion GARMIN_WIDGET_CONFIGURATION_MODE GARMIN_WIDGET_CONFIGURATION_AVAILABLE GARMIN_APPINTENTS_METADATA_AVAILABLE GARMIN_APP_GROUP; do
    host_value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$info")"
    widget_value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$widget/Contents/Info.plist")"
    if [[ "$host_value" != "$widget_value" ]]; then
        printf 'Host/widget mismatch for %s.\n' "$key" >&2; exit 1
    fi
done
mode="$(/usr/libexec/PlistBuddy -c 'Print :GARMIN_WIDGET_CONFIGURATION_MODE' "$info")"
metadata="$(/usr/libexec/PlistBuddy -c 'Print :GARMIN_APPINTENTS_METADATA_AVAILABLE' "$info")"
case "$mode" in
    profile-intents)
        test "$metadata" == "true"
        test -s "$widget/Contents/Resources/Metadata.appintents/extract.actionsdata"
        /usr/bin/plutil -lint "$widget/Contents/Resources/Metadata.appintents/extract.actionsdata" "$widget/Contents/Resources/Metadata.appintents/version.json"
        ;;
    static) test "$metadata" == "false" ;;
    *) printf 'Unknown compiled widget configuration mode.\n' >&2; exit 1 ;;
esac
printf 'PASS: system-only native dependencies, bundle architecture, versions, configuration flags, and signatures.\n'

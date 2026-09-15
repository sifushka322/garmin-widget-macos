#!/bin/bash
# Sign code from the inside out. This script never uploads to Apple.
set -euo pipefail

app_path="${1:?Usage: bash scripts/sign-release.sh /path/GarminDesk.app [signing-identity]}"
signing_identity="${2:-${GARMIN_SIGNING_IDENTITY:--}}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
if [[ ! -d "$app_path/Contents" || ! -f "$app_path/Contents/Info.plist" ]]; then
    printf 'Not an application bundle: %s\n' "$app_path" >&2
    exit 1
fi

app_group="$(/usr/libexec/PlistBuddy -c 'Print :GARMIN_APP_GROUP' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
host_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
host_code_path="$app_path/Contents/MacOS/$host_executable"
widget_path="$app_path/Contents/PlugIns/GarminDeskWidgets.appex"
if [[ -n "$app_group" && ( ! "$app_group" =~ ^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$ || "$signing_identity" == "-" ) ]]; then
    printf 'App Group sharing needs a real signing identity and its TeamID.group-name.\n' >&2; exit 1
fi
if [[ -d "$widget_path" ]]; then
    widget_group="$(/usr/libexec/PlistBuddy -c 'Print :GARMIN_APP_GROUP' "$widget_path/Contents/Info.plist")"
    if [[ "$app_group" != "$widget_group" ]]; then
        printf 'Host and widget App Group identifiers differ; rebuild both bundles.\n' >&2; exit 1
    fi
    if [[ "$signing_identity" != "-" && -z "$app_group" ]]; then
        printf 'Configure GARMIN_APP_GROUP and rebuild before signing the complete widget product.\n' >&2; exit 1
    fi
    metadata_available="$(/usr/libexec/PlistBuddy -c 'Print :GARMIN_APPINTENTS_METADATA_AVAILABLE' "$widget_path/Contents/Info.plist")"
    if [[ "$signing_identity" != "-" && "$metadata_available" != "true" ]]; then
        printf 'Full App Intents metadata must be included before release signing.\n' >&2; exit 1
    fi
fi

entitlements_dir="$(mktemp -d /private/tmp/garmin-signing.XXXXXX)"
trap 'rm -rf -- "$entitlements_dir"' EXIT
cp "$project_dir/Resources/Host.entitlements" "$entitlements_dir/host.plist"
cp "$project_dir/Resources/Widgets.entitlements" "$entitlements_dir/widgets.plist"
if [[ -n "$app_group" ]]; then
    for entitlements in "$entitlements_dir/host.plist" "$entitlements_dir/widgets.plist"; do
        /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$entitlements"
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $app_group" "$entitlements"
    done
fi

signing_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
    signing_options+=(--options runtime --timestamp)
fi

# PyInstaller bundles CPython and compiled extensions. Sign each real binary;
# do not follow its framework symlinks or use --deep to apply signatures.
while IFS= read -r -d '' code_path; do
    # Signing the host executable also seals its bundle. Defer it until the
    # nested widget has a signature; Intel compiler output starts unsigned.
    if [[ "$code_path" == "$host_code_path" ]]; then continue; fi
    if /usr/bin/file -b "$code_path" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign "${signing_options[@]}" "$code_path"
    fi
done < <(/usr/bin/find "$app_path/Contents" -type f -print0)

# Seal nested framework/bundle resources after their code has been signed.
while IFS= read -r -d '' nested_bundle; do
    if [[ "$nested_bundle" == *.appex ]]; then
        /usr/bin/codesign "${signing_options[@]}" --entitlements "$entitlements_dir/widgets.plist" "$nested_bundle"
    else
        /usr/bin/codesign "${signing_options[@]}" "$nested_bundle"
    fi
done < <(/usr/bin/find "$app_path/Contents" -depth -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' \) -print0)

/usr/bin/codesign "${signing_options[@]}" --entitlements "$entitlements_dir/host.plist" "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
if [[ -n "$app_group" ]]; then
    signature_team="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
    if [[ "$signature_team" != "${app_group%%.*}" ]]; then
        printf 'App Group prefix does not match the actual signature TeamIdentifier.\n' >&2; exit 1
    fi
fi

if [[ "$signing_identity" == "-" ]]; then
    printf 'Ad-hoc signature verified. This build is not notarized.\n'
else
    printf 'Signing identity verified. Notarization is a separate publisher step.\n'
fi

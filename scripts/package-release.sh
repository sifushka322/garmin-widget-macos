#!/bin/bash
# Package an existing app. No compilation, installation, signing, or publishing.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
app_path="${1:-$project_dir/build/GarminDesk.app}"
create_dmg="${GARMIN_CREATE_DMG:-1}"
if [[ "$(uname -s)" != "Darwin" || ( "$create_dmg" != "0" && "$create_dmg" != "1" ) ]]; then
    printf 'Run on macOS; GARMIN_CREATE_DMG must be 0 or 1.\n' >&2; exit 1
fi
if [[ ! -f "$app_path/Contents/Info.plist" || ! -x "$app_path/Contents/MacOS/GarminDesk" ]]; then
    printf 'Built GarminDesk.app required: %s\n' "$app_path" >&2; exit 1
fi
app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
target_arch="$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/GarminDesk")"
if [[ "$app_id" != "com.mikhail.garmindesk" || ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ( "$target_arch" != "arm64" && "$target_arch" != "x86_64" ) ]]; then
    printf 'Unexpected bundle ID, version, or architecture; refusing ambiguous package.\n' >&2; exit 1
fi
bash "$script_dir/verify-release.sh" "$app_path"
mkdir -p "$project_dir/build"
staging_dir="$(mktemp -d "$project_dir/build/.package.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
package_name="GarminDesk-$app_version-$target_arch"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staging_dir/$package_name.zip"

if [[ "$create_dmg" == "1" ]]; then
    mkdir -p "$staging_dir/disk"
    /usr/bin/ditto "$app_path" "$staging_dir/disk/GarminDesk.app"
    ln -s /Applications "$staging_dir/disk/Applications"
    cp "$project_dir/Resources/INSTALL.txt" "$staging_dir/disk/INSTALL.txt"
    /usr/bin/codesign --verify --deep --strict "$staging_dir/disk/GarminDesk.app"
    /usr/bin/hdiutil create -volname GarminDesk -fs HFS+ -format UDZO \
        -srcfolder "$staging_dir/disk" "$staging_dir/$package_name.dmg"
    /usr/bin/hdiutil verify "$staging_dir/$package_name.dmg"
fi

(
    cd "$staging_dir"
    /usr/bin/shasum -a 256 "$package_name.zip"
    if [[ "$create_dmg" == "1" ]]; then /usr/bin/shasum -a 256 "$package_name.dmg"; fi
) > "$staging_dir/$package_name-SHA256.txt"
mv -f "$staging_dir/$package_name.zip" "$project_dir/build/$package_name.zip"
if [[ "$create_dmg" == "1" ]]; then
    mv -f "$staging_dir/$package_name.dmg" "$project_dir/build/$package_name.dmg"
fi
mv -f "$staging_dir/$package_name-SHA256.txt" "$project_dir/build/$package_name-SHA256.txt"
printf 'Packages: %s/build/%s.{zip%s}\n' "$project_dir" "$package_name" "$(if [[ "$create_dmg" == "1" ]]; then printf ',dmg'; fi)"
printf 'Checksums: %s/build/%s-SHA256.txt\n' "$project_dir" "$package_name"
printf 'The app was not changed, installed, notarized, or published.\n'

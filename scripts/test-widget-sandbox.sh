#!/bin/bash
# Creates only UUID-scoped synthetic fixtures, never opens widget-data.json
# from the real application directory, and never reads credentials or Keychain.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_dir="$project_dir/build/widget-sandbox-test"
reader_app="$test_dir/WidgetSandboxReader.app"
mkdir -p "$test_dir" "$project_dir/build/module-cache" "$reader_app/Contents/MacOS"
swift_options=(-parse-as-library -swift-version 5 -module-name GarminDeskWidgetSandboxProbe
    -target "$(uname -m)-apple-macos14.0" -module-cache-path "$project_dir/build/module-cache")
if [[ -n "${GARMIN_SDK_PATH:-}" ]]; then swift_options+=(-sdk "$GARMIN_SDK_PATH"); fi
xcrun swiftc "${swift_options[@]}" "$project_dir"/Sources/Shared/*.swift \
    "$project_dir/Sources/GarminDesk/Localization.swift" "$project_dir/Tests/WidgetSandboxProbe.swift" \
    -framework SwiftUI -framework Security -o "$test_dir/widget-sandbox-host"
cp "$test_dir/widget-sandbox-host" "$reader_app/Contents/MacOS/widget-sandbox-reader"
# libsecinit requires bundle identity for a sandbox process. This bundle contains
# a command-line main only; execute it directly without Launch Services or GUI.
cat > "$reader_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.mikhail.garmindesk.sandbox-probe.reader</string>
<key>CFBundleExecutable</key><string>widget-sandbox-reader</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>WidgetSandboxReader</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --identifier com.mikhail.garmindesk.sandbox-probe.host "$test_dir/widget-sandbox-host"
/usr/bin/codesign --force --sign - --identifier com.mikhail.garmindesk.sandbox-probe.reader \
    --entitlements "$project_dir/Resources/Widgets.entitlements" "$reader_app"
/usr/bin/codesign --verify --strict "$test_dir/widget-sandbox-host"
/usr/bin/codesign --verify --strict "$reader_app"
probe_id="$(/usr/bin/uuidgen)"
cleanup() { "$test_dir/widget-sandbox-host" cleanup "$probe_id"; }
trap cleanup EXIT
"$test_dir/widget-sandbox-host" prepare "$probe_id"
"$reader_app/Contents/MacOS/widget-sandbox-reader" verify "$probe_id"

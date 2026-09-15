#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
sdk_path="${GARMIN_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$project_dir/build/icon-module-cache"
xcrun swiftc -parse-as-library -sdk "$sdk_path" \
    -module-cache-path "$project_dir/build/icon-module-cache" \
    "$script_dir/generate-icon.swift" \
    "$project_dir/Sources/Shared/GarminDeskBrandGeometry.swift" \
    -framework AppKit -o "$project_dir/build/generate-icon"
"$project_dir/build/generate-icon"

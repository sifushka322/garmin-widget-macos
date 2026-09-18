#!/bin/bash
# Fresh hosted-runner smoke of the exact packaged application. No sign-in,
# user account, installation, widget gallery reset or system-cache intervention.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-false}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted || "$(uname -s)" != Darwin ]]; then
    printf 'Runtime smoke requires a fresh GitHub-hosted macOS runner.\n' >&2; exit 1
fi
expected_arch="${GARMIN_RUNTIME_ARCH:?Expected architecture required}"
expected_os="${GARMIN_RUNTIME_OS_MAJOR:?Expected macOS major version required}"
: "${APP_VERSION:?Expected app version required}" "${APP_BUILD:?Expected app build required}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$APP_BUILD" =~ ^[1-9][0-9]*$ ||
      ( "$expected_arch" != arm64 && "$expected_arch" != x86_64 ) || ! "$expected_os" =~ ^[0-9]+$ ]]; then
    printf 'Invalid runtime package identity.\n' >&2; exit 1
fi
test "$(uname -m)" = "$expected_arch"
os_version="$(/usr/bin/sw_vers -productVersion)"
test "${os_version%%.*}" = "$expected_os"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
artifact_dir="$(cd -- "${1:?Downloaded package directory required}" && pwd)"
package_name="GarminDesk-$APP_VERSION-$expected_arch"
# Validate exact names before reading paths or extracting the known CI archive.
python3 - "$artifact_dir" "$APP_VERSION" "$expected_arch" <<'PY_ASSETS'
import hashlib
from pathlib import Path, PurePosixPath
import re
import sys
import zipfile

root, version, arch = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
prefix = f"GarminDesk-{version}-{arch}"
expected = {prefix + ".zip", prefix + ".dmg"}
manifest = root / (prefix + "-SHA256.txt")
entries = {}
if manifest.is_symlink() or not manifest.is_file():
    raise SystemExit("Checksum manifest must be an ordinary file")
for line in manifest.read_text("utf-8").splitlines():
    match = re.fullmatch(r"([a-f0-9]{64}) [ *]([^/\\\s]+)", line)
    if match is None or match[2] in entries:
        raise SystemExit("Malformed or duplicate checksum manifest entry")
    entries[match[2]] = match[1]
if set(entries) != expected or {p.name for p in root.iterdir()} != expected | {manifest.name}:
    raise SystemExit("Artifact must contain exactly the expected ZIP, DMG and manifest")
for name, digest in entries.items():
    path = root / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit("Package member must be an ordinary file")
    actual = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            actual.update(block)
    if actual.hexdigest() != digest:
        raise SystemExit("Package bytes differ from the same-run manifest")
with zipfile.ZipFile(root / (prefix + ".zip")) as archive:
    members = archive.infolist()
    for item in members:
        path = PurePosixPath(item.filename)
        if path.is_absolute() or ".." in path.parts or "\\" in item.filename:
            raise SystemExit("Unsafe package archive path")
        app_member = path.parts and path.parts[0] == "GarminDesk.app"
        resource_member = ((path.parts == ("__MACOSX",) and item.is_dir()) or
                           path.parts == ("__MACOSX", "._GarminDesk.app") or
                           (len(path.parts) >= 2 and path.parts[:2] == ("__MACOSX", "GarminDesk.app")))
        if not app_member and not resource_member:
            raise SystemExit("Unexpected top-level package archive member")
    if "GarminDesk.app/Contents/MacOS/GarminDesk" not in archive.namelist():
        raise SystemExit("Package archive has no application executable")
print("PASS: exact package names and SHA-256 bytes verified before extraction.")
PY_ASSETS

# Do not erase existing state to manufacture a clean-install result.
if [[ -e "$HOME/Library/Application Support/GarminDesk" ||
      -e "$HOME/Library/Preferences/com.mikhail.garmindesk.plist" ]] ||
      /usr/bin/pgrep -x GarminDesk >/dev/null; then
    printf 'Runner is not fresh; refusing to read, clear or reuse existing application state.\n' >&2; exit 1
fi
work_dir="$(/usr/bin/mktemp -d "${RUNNER_TEMP:?}/garmindesk-runtime.XXXXXX")"
audit_dir="$project_dir/build/audit/runtime"
mkdir -p "$audit_dir"
app_pid=""
cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid" 2>/dev/null || true
        /bin/sleep 1
        if kill -0 "$app_pid" 2>/dev/null; then kill -KILL "$app_pid" 2>/dev/null || true; fi
        wait "$app_pid" 2>/dev/null || true
    fi
    rm -rf -- "$work_dir"
}
trap cleanup EXIT
/usr/bin/ditto -x -k "$artifact_dir/$package_name.zip" "$work_dir"
app="$work_dir/GarminDesk.app"
info="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/GarminDesk"
bash "$script_dir/verify-release.sh" "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" = "$APP_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" = "$APP_BUILD"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" = com.mikhail.garmindesk
test "$(/usr/bin/lipo -archs "$binary")" = "$expected_arch"
printf 'macOS: %s\nArchitecture: %s\nVersion: %s\nBuild: %s\nCommit: %s\nRun: %s\n' \
    "$os_version" "$expected_arch" "$APP_VERSION" "$APP_BUILD" "$GITHUB_SHA" "$GITHUB_RUN_ID" > "$audit_dir/identity.txt"

# Launch the verified bundle executable itself, not a rebuild for this OS.
/usr/bin/env -u GH_TOKEN -u GITHUB_TOKEN "$binary" > "$audit_dir/application.log" 2>&1 &
app_pid=$!
for second in {1..10}; do
    /bin/sleep 1
    if ! kill -0 "$app_pid" 2>/dev/null; then
        wait "$app_pid" 2>/dev/null || true
        printf 'Packaged application exited during its ten-second startup smoke.\n' >&2; exit 1
    fi
done
kill -TERM "$app_pid"
for attempt in {1..10}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    /bin/sleep 0.5
done
if kill -0 "$app_pid" 2>/dev/null; then
    printf 'Packaged application did not terminate after SIGTERM.\n' >&2; exit 1
fi
app_exit_status=0
wait "$app_pid" 2>/dev/null || app_exit_status=$?
if [[ "$app_exit_status" != 0 && "$app_exit_status" != 143 ]]; then
    printf 'Packaged application exited unexpectedly during termination.\n' >&2; exit 1
fi
app_pid=""
printf 'PASS: exact packaged application stayed alive for 10 seconds on macOS %s (%s).\n' "$os_version" "$expected_arch" | tee "$audit_dir/result.txt"
printf 'Coverage: fresh-process startup only; no live Garmin, widget gallery or upgrade validation.\n' | tee -a "$audit_dir/result.txt"

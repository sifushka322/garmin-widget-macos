#!/bin/bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-false}" != true || "${GITHUB_REF:-}" != refs/heads/main ]]; then
    printf 'Release publication runs only in GitHub Actions on main.\n' >&2; exit 1
fi
: "${APP_VERSION:?}" "${APP_BUILD:?}" "${GITHUB_SHA:?}" "${GH_REPO:?}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$APP_BUILD" =~ ^[0-9]+$ || ! "$GITHUB_SHA" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'Invalid release identity.\n' >&2; exit 1
fi
asset_dir="$(cd -- "${1:?Asset directory required}" && pwd)"
notes="docs/releases/$APP_VERSION.md"
test -s "$notes"
tag="v$APP_VERSION"
assets=()
for arch in arm64 x86_64; do
    for suffix in .zip .dmg -SHA256.txt; do
        asset="$asset_dir/GarminDesk-$APP_VERSION-$arch$suffix"
        test -s "$asset"
        assets+=("$asset")
    done
    (cd "$asset_dir" && sha256sum --strict --check "GarminDesk-$APP_VERSION-$arch-SHA256.txt")
done

# Never replace an existing public release or silently change a tag.
existing="$(gh api "repos/$GH_REPO/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .id")"
if [[ -n "$existing" ]]; then
    printf 'Release %s already exists; inspect it before retrying publication.\n' "$tag" >&2; exit 1
fi
gh release create "$tag" --draft --target "$GITHUB_SHA" \
    --title "GarminDesk $APP_VERSION" --notes-file "$notes"
gh release upload "$tag" "${assets[@]}"
release_id="$(gh api "repos/$GH_REPO/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .id")"
[[ "$release_id" =~ ^[0-9]+$ ]]
gh api "repos/$GH_REPO/releases/$release_id" > "$asset_dir/release.json"

# Compare GitHub's uploaded asset digests before exposing the release publicly.
python3 - "$asset_dir" "$APP_VERSION" "$GITHUB_SHA" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
version, commit = sys.argv[2:]
release = json.loads((root / "release.json").read_text())
assert release["draft"] and release["target_commitish"] == commit
expected = {f"GarminDesk-{version}-{arch}{suffix}" for arch in ("arm64", "x86_64")
            for suffix in (".zip", ".dmg", "-SHA256.txt")}
actual = {asset["name"]: asset for asset in release["assets"]}
assert set(actual) == expected, "Unexpected or missing release assets"
for name in expected:
    data = (root / name).read_bytes()
    assert actual[name]["size"] == len(data), name
    assert actual[name]["digest"] == "sha256:" + hashlib.sha256(data).hexdigest(), name
print("PASS: all six uploaded assets match the verified packages")
PY
gh release edit "$tag" --draft=false --latest
printf 'Published https://github.com/%s/releases/tag/%s from %s\n' "$GH_REPO" "$tag" "$GITHUB_SHA"

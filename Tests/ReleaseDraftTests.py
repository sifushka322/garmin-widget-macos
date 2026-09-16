"""Exercise the real release script with a local GitHub fixture; no network."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.4.0"
COMMIT = "a" * 40

GH_FIXTURE = r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["RELEASE_FIXTURE"])
state_file = root / "state.json"
state = json.loads(state_file.read_text())
args = sys.argv[1:]
if args[0] == "api":
    if "?per_page=" in args[1]:
        print("42" if state["exists"] else "")
    else:
        print(json.dumps(dict(state, target_commitish=os.environ["GITHUB_SHA"],
                             assets=json.loads((root / "assets.json").read_text()))))
elif args[:2] == ["release", "create"]:
    state.update(exists=True, draft="--draft" in args)
elif args[:2] == ["release", "upload"]:
    state["uploaded"] = True
elif args[:2] == ["release", "edit"]:
    if "--draft=false" in args: state["draft"] = False
    if "--latest" in args: state["latest"] = True
else:
    sys.exit("Unexpected gh call: " + repr(args))
state_file.write_text(json.dumps(state))
'''


class ReleaseDraftTests(unittest.TestCase):
    def run_release(self, *, existing=False, bad_digest=False, branch="main"):
        with tempfile.TemporaryDirectory(prefix="garmindesk-release-test-") as temporary:
            root = Path(temporary)
            assets = root / "packages"
            assets.mkdir()
            for arch in ("arm64", "x86_64"):
                checksums = []
                for suffix in (".zip", ".dmg"):
                    package = assets / f"GarminDesk-{VERSION}-{arch}{suffix}"
                    package.write_bytes((arch + suffix).encode())
                    checksums.append(f"{hashlib.sha256(package.read_bytes()).hexdigest()}  {package.name}\n")
                (assets / f"GarminDesk-{VERSION}-{arch}-SHA256.txt").write_text("".join(checksums))
            metadata = [dict(name=p.name, size=p.stat().st_size,
                             digest="sha256:" + hashlib.sha256(p.read_bytes()).hexdigest())
                        for p in assets.iterdir()]
            if bad_digest:
                metadata[0]["digest"] = "sha256:" + "0" * 64
            (root / "assets.json").write_text(json.dumps(metadata))
            state_file = root / "state.json"
            state_file.write_text(json.dumps(dict(exists=existing, draft=True, latest=False, uploaded=False)))
            executable = root / "gh"
            executable.write_text(f"#!{sys.executable}\n" + GH_FIXTURE)
            executable.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       RELEASE_FIXTURE=str(root), GITHUB_ACTIONS="true",
                       GITHUB_REF=f"refs/heads/{branch}", GITHUB_SHA=COMMIT,
                       APP_VERSION=VERSION, APP_BUILD="10", GH_REPO="test/fixture")
            result = subprocess.run(["bash", "scripts/publish-release.sh", str(assets)],
                                    cwd=ROOT, env=env, text=True, capture_output=True)
            return result, json.loads(state_file.read_text())

    def test_verified_assets_stay_unpublished(self):
        result, state = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(state["uploaded"])
        self.assertTrue(state["draft"])
        self.assertFalse(state["latest"])

    def test_uploaded_digest_mismatch_fails_without_publishing(self):
        result, state = self.run_release(bad_digest=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(state["draft"])
        self.assertFalse(state["latest"])

    def test_existing_release_is_not_modified(self):
        result, state = self.run_release(existing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(state["uploaded"])

    def test_other_branch_cannot_create_release(self):
        result, state = self.run_release(branch="feature")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(state["exists"])


if __name__ == "__main__":
    unittest.main()

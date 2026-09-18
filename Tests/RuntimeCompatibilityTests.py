"""Validate the real runtime package checker with synthetic offline artifacts."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SMOKE = (ROOT / "scripts/ci-runtime-smoke.sh").read_text()
CHECKER = SMOKE.split("<<'PY_ASSETS'\n", 1)[1].split("\nPY_ASSETS\n", 1)[0]
VERSION = "0.6.0"
PREFIX = "GarminDesk-" + VERSION + "-arm64"


class RuntimeCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="garmin-runtime-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.write_archive({"GarminDesk.app/Contents/MacOS/GarminDesk": b"synthetic-binary"})
        (self.root / (PREFIX + ".dmg")).write_bytes(b"synthetic-disk-image")
        self.write_manifest()

    def write_archive(self, members):
        with zipfile.ZipFile(self.root / (PREFIX + ".zip"), "w") as archive:
            for name, data in members.items():
                archive.writestr(name, data)

    def write_manifest(self):
        text = ""
        for suffix in (".zip", ".dmg"):
            name = PREFIX + suffix
            text += hashlib.sha256((self.root / name).read_bytes()).hexdigest() + "  " + name + "\n"
        (self.root / (PREFIX + "-SHA256.txt")).write_text(text)

    def run_check(self, succeeds):
        result = subprocess.run([sys.executable, "-c", CHECKER, str(self.root), VERSION, "arm64"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

    def test_expected_artifact_and_ditto_resource_members_are_accepted(self):
        self.write_archive({"GarminDesk.app/Contents/MacOS/GarminDesk": b"synthetic-binary",
                            "__MACOSX/": b"", "__MACOSX/._GarminDesk.app": b"metadata",
                            "__MACOSX/GarminDesk.app/Contents/._Info.plist": b"metadata"})
        self.write_manifest()
        self.run_check(True)

    def test_changed_zip_or_dmg_bytes_are_rejected(self):
        for suffix in (".zip", ".dmg"):
            with self.subTest(suffix=suffix):
                path = self.root / (PREFIX + suffix)
                original = path.read_bytes()
                path.write_bytes(original + b"changed")
                self.run_check(False)
                path.write_bytes(original)

    def test_missing_extra_and_symlinked_packages_are_rejected(self):
        extra = self.root / "unrelated.txt"
        extra.write_text("synthetic")
        self.run_check(False)
        extra.unlink()
        path = self.root / (PREFIX + ".dmg")
        original = path.read_bytes()
        path.unlink()
        self.run_check(False)
        path.symlink_to(self.root / (PREFIX + ".zip"))
        self.run_check(False)
        path.unlink()
        path.write_bytes(original)

    def test_manifest_cannot_omit_duplicate_or_redirect_an_asset(self):
        path = self.root / (PREFIX + "-SHA256.txt")
        original = path.read_text()
        for changed in (original.splitlines()[0] + "\n", original + original.splitlines()[0] + "\n",
                        original.replace(PREFIX + ".zip", "../outside.zip")):
            path.write_text(changed)
            self.run_check(False)
        path.write_text(original)

    def test_matching_hashes_do_not_allow_unsafe_or_unexpected_zip_paths(self):
        for name in ("../outside", "/absolute", "GarminDesk.app/../outside", "other.app/file"):
            with self.subTest(name=name):
                self.write_archive({"GarminDesk.app/Contents/MacOS/GarminDesk": b"synthetic-binary", name: b"bad"})
                self.write_manifest()
                self.run_check(False)

    def test_matching_hashes_require_the_application_executable(self):
        self.write_archive({"GarminDesk.app/Contents/Info.plist": b"synthetic"})
        self.write_manifest()
        self.run_check(False)

    def test_release_requires_both_standard_runtime_lanes(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        native = workflow.split("  native-compat:\n", 1)[1].split("  runtime-compat:\n", 1)[0]
        runtime = workflow.split("  runtime-compat:\n", 1)[1].split("  release:\n", 1)[0]
        release = workflow.split("  release:\n", 1)[1]
        self.assertIn("needs: [version, build]", runtime)
        self.assertIn("needs: [version, protocol, build, native-compat, runtime-compat]", release)
        self.assertRegex(runtime, r"runner: macos-14\s+os_major: '14'\s+arch: arm64")
        self.assertRegex(runtime, r"runner: macos-15-intel\s+os_major: '15'\s+arch: x86_64")
        self.assertNotRegex(runtime, r"macos-[^\s]*(?:large|xlarge)")
        self.assertIn('gh run download "$GITHUB_RUN_ID"', runtime)
        self.assertIn('build$APP_BUILD-$GARMIN_RUNTIME_ARCH-development', runtime)
        self.assertIn("bash scripts/ci-runtime-smoke.sh runtime-packages", runtime)
        # Source/SDK checks start before packaging; exact-package launch checks
        # remain separate. Both pairs are mandatory release dependencies.
        self.assertIn("needs: version", native)
        self.assertNotIn("needs: [version, build]", native)
        self.assertIn("bash scripts/test-offline.sh", native)
        self.assertIn("bash scripts/test-widget-sandbox.sh", native)
        self.assertNotIn("bash scripts/test-offline.sh", runtime)
        for lane in (native, runtime):
            self.assertRegex(lane, r"runner: macos-14\s+os_major: '14'\s+arch: arm64")
            self.assertRegex(lane, r"runner: macos-15-intel\s+os_major: '15'\s+arch: x86_64")
            self.assertNotRegex(lane, r"macos-[^\s]*(?:large|xlarge)")


if __name__ == "__main__":
    unittest.main()

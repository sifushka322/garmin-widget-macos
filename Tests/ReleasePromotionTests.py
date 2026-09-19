"""Exercise release-promotion gates with local Git and an in-memory GitHub fixture.

No network, token, approval in the source tree, or real publication is used.
"""
import copy
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("promotion", ROOT / "scripts/promote-release.py")
promotion = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(promotion)


class FakeGitHub:
    def __init__(self, approval, head, payloads):
        self.approval = approval
        self.head = head
        self.payloads = payloads
        self.published = []
        self.downloaded = []
        self.corrupt_download = False
        self.changed_on_recheck = False
        self.advance_after_download = False
        self.retag_after_download = False
        self.corrupt_artifact = False
        self.unsafe_artifact_member = False
        self.artifact_downloaded = []
        self.tag_target = None
        self.workflow = {"id": 20, "name": "Build macOS app", "path": ".github/workflows/build.yml"}
        self.run = {"id": 30, "workflow_id": 20, "name": "Build macOS app", "status": "completed", "conclusion": "success",
                    "head_sha": approval["commit"], "head_branch": "main", "event": "push",
                    "repository": {"full_name": "fixture/repo"}, "head_repository": {"full_name": "fixture/repo"}}
        self.jobs = [{"name": name, "status": "completed", "conclusion": "success"} for name in
                     ("Validate release version", "Offline JavaScript and Python contracts", "macOS arm64", "macOS x86_64", "Native macOS 14 arm64", "Native macOS 15 x86_64", "Runtime macOS 14 arm64", "Runtime macOS 15 x86_64", "Prepare verified release draft")]
        self.release = {"id": 40, "tag_name": "v0.5.0", "target_commitish": approval["commit"], "draft": True, "prerelease": False}
        self.assets = [{"id": index + 1, "name": name, "size": len(data), "state": "uploaded", "digest": "sha256:" + digest(data)}
                       for index, (name, data) in enumerate(sorted(payloads.items()))]
        self.artifacts = [{"id": index + 100, "name": f"GarminDesk-0.5.0-build11-{arch}-development", "expired": False,
                           "workflow_run": {"id": 30, "head_sha": approval["commit"], "head_branch": "main"}}
                          for index, arch in enumerate(("arm64", "x86_64"))]

    def api(self, path, pages=False):
        if path == "git/ref/heads/main":
            return {"object": {"sha": "b" * 40 if self.advance_after_download and self.downloaded else self.head}}
        if path == "actions/workflows/build.yml":
            return copy.deepcopy(self.workflow)
        if path == "actions/runs/30":
            return copy.deepcopy(self.run)
        if path == "actions/runs/30/jobs?filter=latest&per_page=100":
            return {"jobs": copy.deepcopy(self.jobs)}
        if path == "actions/runs/30/artifacts?per_page=100":
            return {"total_count": len(self.artifacts), "artifacts": copy.deepcopy(self.artifacts)}
        if path == "git/matching-refs/tags/v0.5.0":
            target = "b" * 40 if self.retag_after_download and self.downloaded else self.tag_target
            return [] if target is None else [{"ref": "refs/tags/v0.5.0", "object": {"type": "commit", "sha": target}}]
        if path == "releases?per_page=100":
            return [copy.deepcopy(self.release)]
        if path == "releases/40/assets?per_page=100":
            result = copy.deepcopy(self.assets)
            if self.changed_on_recheck and self.downloaded:
                result[0]["id"] += 100
            return result
        if path in ("releases/40", "releases/latest"):
            return copy.deepcopy(self.release)
        raise AssertionError("Unexpected fixture API path: " + path)

    def download(self, asset, path):
        self.downloaded.append(asset["name"])
        path.write_bytes(self.payloads[asset["name"]] + (b"tampered" if self.corrupt_download else b""))

    def publish(self, tag, notes):
        self.published.append(tag)
        self.release["draft"] = False
        self.release["body"] = notes.decode("utf-8")

    def download_artifact(self, artifact, path):
        arch = "arm64" if "-arm64-" in artifact["name"] else "x86_64"
        self.artifact_downloaded.append(arch)
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in self.payloads.items():
                if f"-{arch}" not in name:
                    continue
                # Same-size replacement exercises byte binding, not just size checks.
                if self.corrupt_artifact and name.endswith(".dmg"):
                    data = bytes([data[0] ^ 1]) + data[1:]
                archive.writestr(name, data)
            if self.unsafe_artifact_member:
                archive.writestr("../unexpected.txt", b"Synthetic unsafe extra member")


def digest(data):
    return hashlib.sha256(data).hexdigest()


class ReleasePromotionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="garmin-promotion-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Synthetic Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        for name in ("Info.plist", "Widgets-Info.plist"):
            self.write("Resources/" + name, plistlib.dumps({"CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "11"}))
        self.commit = self.commit_files("Synthetic tested candidate")
        self.payloads = {}
        for arch in ("arm64", "x86_64"):
            lines = []
            for suffix in (".zip", ".dmg"):
                name = f"GarminDesk-0.5.0-{arch}{suffix}"
                self.payloads[name] = ("Synthetic package " + name).encode()
                lines.append(digest(self.payloads[name]) + "  " + name)
            self.payloads[f"GarminDesk-0.5.0-{arch}-SHA256.txt"] = ("\n".join(lines) + "\n").encode()
        self.report_path = "docs/releases/validation/0.5.0-upgrade.md"
        self.report = (f"Version: v0.5.0\nBuild: 11\nCandidate commit: {self.commit}\nOverall result: PASS\nNormal upgrade: PASS\n"
                       "Service intervention before completing checks: none\n\nSynthetic test fixture, never evidence of a real upgrade.\n").encode()
        self.notes_path = "docs/releases/public-notes/v0.5.0.md"
        self.notes = b"# GarminDesk 0.5.0\n\nSynthetic public notes used only for local guard tests. These notes do not approve a real release.\n"
        self.approval = {"schema_version": 1, "version": "0.5.0", "build": "11", "commit": self.commit,
                         "build_run_id": 30, "upgrade_result": "passed", "report": self.report_path,
                         "release_notes_path": self.notes_path, "release_notes_sha256": digest(self.notes),
                         "report_sha256": digest(self.report), "asset_sha256": {n: digest(b) for n, b in self.payloads.items()}}
        self.approval_path = "docs/releases/approvals/v0.5.0.json"
        self.save_approval()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.DEVNULL).decode().strip()

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def commit_files(self, message):
        self.git("add", ".")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def save_approval(self):
        self.write(self.report_path, self.report)
        self.write(self.notes_path, self.notes)
        self.write(self.approval_path, json.dumps(self.approval).encode())
        if hasattr(self, "head"):
            self.git("add", ".")
            self.git("commit", "-q", "--amend", "--no-edit")
            self.head = self.git("rev-parse", "HEAD")
        else:
            self.head = self.commit_files("Synthetic approval fixture")
        event = {"ref": "refs/heads/main", "before": self.commit, "after": self.head, "forced": False, "deleted": False,
                 "repository": {"full_name": "fixture/repo", "default_branch": "main"}}
        event_path = self.root.parent / (self.root.name + "-event.json")
        event_path.write_text(json.dumps(event))
        self.addCleanup(lambda: event_path.unlink(missing_ok=True))
        self.environment = dict(GITHUB_ACTIONS="true", GITHUB_REF="refs/heads/main", GITHUB_EVENT_NAME="push",
                                GITHUB_REPOSITORY="fixture/repo", GH_REPO="fixture/repo", GITHUB_SHA=self.head,
                                GITHUB_EVENT_PATH=str(event_path))
        self.github = FakeGitHub(self.approval, self.head, self.payloads)

    def reject(self):
        with self.assertRaises((promotion.Rejected, subprocess.CalledProcessError)):
            promotion.promote(self.root, self.environment, self.github)
        self.assertEqual(self.github.published, [])

    def test_exact_tested_draft_is_published_once_after_all_downloads(self):
        with contextlib.redirect_stdout(io.StringIO()):
            promotion.promote(self.root, self.environment, self.github)
        self.assertEqual(self.github.published, ["v0.5.0"])
        self.assertEqual(set(self.github.downloaded), set(self.payloads))
        self.assertEqual(self.github.artifact_downloaded, ["arm64", "x86_64"])
        self.assertEqual(self.github.release["body"], self.notes.decode())

    def make_override(self):
        reason = "Published following an explicit informed owner request despite unavailable normal widget upgrade testing."
        self.approval.update(upgrade_result="not_run", owner_override=True, override_reason=reason)
        self.report = (f"Version: v0.5.0\nBuild: 11\nCandidate commit: {self.commit}\nOverall result: NOT RUN\nNormal upgrade: NOT RUN\n"
                       "Owner override: explicit release request after disclosure\nOverride reason: " + reason +
                       "\nUnverified coverage: existing system widgets and gallery after normal package replacement.\n").encode()
        self.notes = ("# GarminDesk 0.5.0\n\nNormal upgrade validation: NOT RUN\n\n" + reason + "\n").encode()
        self.approval.update(report_sha256=digest(self.report), release_notes_sha256=digest(self.notes))
        self.save_approval()

    def test_explicit_informed_not_run_override_publishes_disclosed_notes(self):
        self.make_override()
        with contextlib.redirect_stdout(io.StringIO()):
            promotion.promote(self.root, self.environment, self.github)
        self.assertEqual(self.github.published, ["v0.5.0"])
        self.assertIn("Normal upgrade validation: NOT RUN", self.github.release["body"])

    def test_informed_override_can_link_the_exact_public_audit_record(self):
        self.make_override()
        self.report += b"\nAutomated checks: PASS.\n"
        self.approval["report_sha256"] = digest(self.report)
        self.notes = ("# GarminDesk 0.5.0\n\nFinal release with completed product changes.\n\n"
                      "[Validation report](https://github.com/fixture/repo/blob/main/" + self.report_path + ")\n"
                      "Automated checks: PASS.\n").encode()
        self.approval["release_notes_sha256"] = digest(self.notes)
        self.save_approval()
        with contextlib.redirect_stdout(io.StringIO()):
            promotion.promote(self.root, self.environment, self.github)
        self.assertEqual(self.github.published, ["v0.5.0"])
        self.assertIn("Normal upgrade: NOT RUN", self.report.decode())

    def test_linked_override_cannot_reference_another_repository_or_report(self):
        self.make_override()
        for target in ("https://github.com/other/repo/blob/main/" + self.report_path,
                       "https://github.com/fixture/repo/blob/main/docs/unrelated.md"):
            with self.subTest(target=target):
                self.notes = ("# GarminDesk 0.5.0\n\nFinal release with product changes. "
                              "See the [Validation report](" + target + ").\n").encode()
                self.approval["release_notes_sha256"] = digest(self.notes)
                self.save_approval()
                self.reject()

    def test_override_report_rejects_pass_claims_despite_markdown_or_spacing(self):
        self.make_override()
        original_report = self.report
        claims = (
            "**Normal upgrade: PASS**",
            "- **Normal upgrade validation:** **PASS**",
            "normal \tupgrade :\n pass",
            "**Overall result: PASS**",
            "- Overall result: __PASS__",
            "overall\tRESULT \t:\n\tpAsS",
        )
        for claim in claims:
            with self.subTest(claim=claim):
                self.report = original_report + ("\n" + claim + "\n").encode()
                self.approval["report_sha256"] = digest(self.report)
                self.save_approval()
                self.reject()

    def test_override_notes_reject_pass_claims_despite_markdown_or_spacing(self):
        self.make_override()
        disclosures = (
            self.notes,
            ("# GarminDesk 0.5.0\n\nFinal release with completed product changes.\n\n"
             "[Validation report](https://github.com/fixture/repo/blob/main/" + self.report_path + ")\n").encode(),
        )
        claims = (
            "Normal upgrade: PASS",
            "**Normal upgrade: PASS**",
            "**Normal upgrade:** **PASS**",
            "- Normal upgrade: PASS",
            "- **Normal upgrade validation:** **PASS**",
            "normal UPGRADE validation: pAsS",
            "Normal\tupgrade  validation \t: \n\tPASS",
            "Normal upgrade: __PASS__",
        )
        for disclosure in disclosures:
            for claim in claims:
                with self.subTest(disclosure=disclosure, claim=claim):
                    self.notes = disclosure + ("\n" + claim + "\n").encode()
                    self.approval["release_notes_sha256"] = digest(self.notes)
                    self.save_approval()
                    self.reject()

    def test_not_run_without_explicit_owner_override_is_rejected(self):
        self.make_override(); self.approval["owner_override"] = False
        self.save_approval(); self.reject()

    def test_override_does_not_accept_failed_unknown_or_empty_reason(self):
        self.make_override()
        for value in ["failed", "unknown"]:
            self.approval["upgrade_result"] = value
            self.save_approval(); self.reject()
        self.approval.update(upgrade_result="not_run", override_reason="")
        self.save_approval(); self.reject()

    def test_override_report_cannot_claim_pass_or_hide_unchecked_coverage(self):
        self.make_override()
        self.report += b"Normal upgrade: PASS\n"
        self.approval["report_sha256"] = digest(self.report)
        self.save_approval(); self.reject()

    def test_override_notes_must_disclose_limitation(self):
        self.make_override()
        self.notes = b"# GarminDesk 0.5.0\n\nSynthetic notes that omit the required unverified-upgrade limitation despite an override.\n"
        self.approval["release_notes_sha256"] = digest(self.notes)
        self.save_approval(); self.reject()

    def test_public_notes_must_match_approved_digest(self):
        self.notes += b"Unapproved edit\n"
        self.save_approval(); self.reject()

    def test_other_branch_or_manual_dispatch_cannot_publish(self):
        for key, value in [("GITHUB_REF", "refs/heads/feature"), ("GITHUB_EVENT_NAME", "workflow_dispatch")]:
            with self.subTest(key=key):
                old = self.environment[key]; self.environment[key] = value
                self.reject(); self.environment[key] = old

    def test_pending_upgrade_is_rejected(self):
        self.approval["upgrade_result"] = "pending"
        self.save_approval(); self.reject()

    def test_report_must_match_digest_identity_and_normal_upgrade(self):
        self.report = self.report.replace(b"Normal upgrade: PASS", b"Normal upgrade: FAIL")
        self.approval["report_sha256"] = digest(self.report)
        self.save_approval(); self.reject()

    def test_contradictory_report_outcomes_are_rejected(self):
        self.report += b"Overall result: FAIL\n"
        self.approval["report_sha256"] = digest(self.report)
        self.save_approval(); self.reject()

    def test_modified_report_bytes_are_rejected(self):
        self.report += b"unapproved edit\n"
        self.save_approval(); self.reject()

    def test_report_private_home_path_is_rejected(self):
        self.report += b"Synthetic forbidden path: /Users/test-user/private/\n"
        self.approval["report_sha256"] = digest(self.report)
        self.save_approval(); self.reject()

    def test_report_path_cannot_escape_validation_directory(self):
        self.approval["report"] = "../outside.md"
        self.save_approval(); self.reject()

    def test_post_candidate_code_change_is_rejected(self):
        self.write("Sources/unrelated.swift", b"// Synthetic code change\n")
        self.save_approval(); self.reject()

    def test_reviewed_publication_bootstrap_and_status_files_are_allowed(self):
        for name in promotion.publication_files("0.5.0"):
            self.write(name, b"Synthetic publication-only fixture.\n")
        self.save_approval()
        with contextlib.redirect_stdout(io.StringIO()):
            promotion.promote(self.root, self.environment, self.github)
        self.assertEqual(self.github.published, ["v0.5.0"])

    def test_build_workflow_changes_after_candidate_are_rejected(self):
        self.write(".github/workflows/build.yml", b"Synthetic changed build workflow.\n")
        self.save_approval(); self.reject()

    def test_version_or_build_mismatch_is_rejected(self):
        self.approval["build"] = "12"
        self.save_approval(); self.reject()

    def test_build_must_be_successful_same_repo_main_commit(self):
        for key, value in [("conclusion", "failure"), ("status", "in_progress"), ("head_branch", "feature"),
                           ("head_sha", "b" * 40), ("workflow_id", 99), ("event", "pull_request"),
                           ("head_repository", {"full_name": "other/fork"})]:
            with self.subTest(key=key):
                original = self.github.run[key]; self.github.run[key] = value
                self.reject(); self.github.run[key] = original

    def test_both_architectures_and_draft_job_must_pass(self):
        for job in self.github.jobs:
            with self.subTest(job=job["name"]):
                job["conclusion"] = "skipped"; self.reject(); job["conclusion"] = "success"

    def test_missing_runtime_compatibility_job_prevents_publication(self):
        for name in ("Native macOS 14 arm64", "Native macOS 15 x86_64", "Runtime macOS 14 arm64", "Runtime macOS 15 x86_64"):
            with self.subTest(job=name):
                original = self.github.jobs
                self.github.jobs = [job for job in original if job["name"] != name]
                self.reject()
                self.github.jobs = original

    def test_main_must_not_advance(self):
        self.github.head = "b" * 40
        self.reject()

    def test_existing_tag_must_match_tested_commit(self):
        self.github.tag_target = "b" * 40
        self.reject()

    def test_published_or_retargeted_release_is_rejected(self):
        for key, value in [("draft", False), ("prerelease", True), ("target_commitish", "main")]:
            with self.subTest(key=key):
                original = self.github.release[key]; self.github.release[key] = value
                self.reject(); self.github.release[key] = original

    def test_missing_extra_or_changed_assets_are_rejected(self):
        original = copy.deepcopy(self.github.assets)
        self.github.assets.pop(); self.reject()
        self.github.assets = copy.deepcopy(original) + [dict(original[0], name="unexpected.zip", id=99)]; self.reject()
        self.github.assets = copy.deepcopy(original); self.github.assets[0]["digest"] = "sha256:" + "0" * 64; self.reject()

    def test_downloaded_bytes_must_match_approved_hashes(self):
        self.github.corrupt_download = True
        self.reject()

    def test_checksum_manifest_cannot_omit_or_redirect_packages(self):
        name = "GarminDesk-0.5.0-arm64-SHA256.txt"
        self.payloads[name] = ("0" * 64 + "  ../elsewhere.zip\n").encode()
        self.approval["asset_sha256"][name] = digest(self.payloads[name])
        self.save_approval(); self.reject()

    def test_remote_assets_cannot_change_during_verification(self):
        self.github.changed_on_recheck = True
        self.reject()

    def test_draft_bytes_must_match_same_run_artifact_bytes(self):
        self.github.corrupt_artifact = True
        self.reject()

    def test_ci_artifact_cannot_add_paths_or_extra_members(self):
        self.github.unsafe_artifact_member = True
        self.reject()

    def test_ci_artifact_identity_and_availability_are_required(self):
        artifact = self.github.artifacts[0]
        artifact["expired"] = True; self.reject(); artifact["expired"] = False
        artifact["workflow_run"]["head_sha"] = "b" * 40; self.reject()
        artifact["workflow_run"]["head_sha"] = self.commit
        self.github.artifacts.pop(); self.reject()

    def test_main_and_tag_are_rechecked_after_downloads(self):
        for attribute in ["advance_after_download", "retag_after_download"]:
            with self.subTest(attribute=attribute):
                self.github.downloaded.clear()
                setattr(self.github, attribute, True)
                self.reject()
                setattr(self.github, attribute, False)

    def test_duplicate_json_keys_are_rejected(self):
        with self.assertRaises(promotion.Rejected):
            promotion.json_bytes(b'{"upgrade_result":"pending","upgrade_result":"passed"}')


if __name__ == "__main__":
    unittest.main()

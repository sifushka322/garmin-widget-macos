"""Publish only an explicitly approved, tested draft. No approval is generated.

The trigger file is docs/releases/approvals/v<VERSION>.json with exactly:
schema_version (1), version, build (string), commit (40 lowercase hex),
build_run_id (positive integer), upgrade_result, report, report_sha256,
release_notes_path, release_notes_sha256, and asset_sha256 (all six filename
-> SHA-256 mappings). The public notes must be a hash-bound source Markdown
file, supplied to the final publication call instead of stale draft notes.

report must be a sanitized docs/releases/validation/*.md file containing these
standalone lines, populated only after real normal-upgrade validation:
Version: v<VERSION>
Build: <BUILD>
Candidate commit: <COMMIT>
Overall result: PASS
Normal upgrade: PASS
Service intervention before completing checks: none

upgrade_result="not_run" is allowed only with owner_override=true and a
substantive override_reason after an explicit, informed owner release request.
That report instead uses Overall result: NOT RUN, Normal upgrade: NOT RUN,
Owner override: explicit release request after disclosure, Override reason:
<the exact reason>, and Unverified coverage: <the exact unchecked coverage>.
Public notes must then include Normal upgrade validation: NOT RUN and the same
reason. Failed/unknown results are never eligible for this exception.

The report must document the environment and every check required by
docs/widget-upgrade-validation.md. The workflow verifies the recorded approval
and exact package identity; it cannot perform or attest the human GUI test.
Only approval/report/notes and the explicitly enumerated publication workflow,
guard tests, and status documents may change after the tested candidate. App,
build, packaging, dependency, and runtime source changes are never exempted.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


class Rejected(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON key")
        result[key] = value
    return result


def json_bytes(data):
    return json.loads(data, object_pairs_hook=unique_object)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root)


def identity(root, commit):
    plists = [plistlib.loads(git(root, "show", f"{commit}:Resources/{name}"))
              for name in ("Info.plist", "Widgets-Info.plist")]
    values = [(p["CFBundleShortVersionString"], p["CFBundleVersion"]) for p in plists]
    require(values[0] == values[1], "Host/widget version mismatch")
    version, build = values[0]
    require(isinstance(version, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Invalid version")
    require(isinstance(build, str) and re.fullmatch(r"[1-9][0-9]*", build), "Invalid build")
    return version, build


def expected_names(version):
    return {f"GarminDesk-{version}-{arch}{suffix}" for arch in ("arm64", "x86_64")
            for suffix in (".dmg", ".zip", "-SHA256.txt")}


def publication_files(version):
    """Narrow bootstrap/status exceptions; never a whole source directory."""
    return {".github/workflows/promote-release.yml", "scripts/promote-release.py", "Tests/ReleasePromotionTests.py",
            "README.md", "docs/distribution.md", f"docs/releases/{version}.md", "docs/native-contract.md",
            "docs/branding/README.md", "docs/publication-checklist.md", "docs/source-publication-files.txt"}


def validate_approval(value, version, build):
    keys = {"schema_version", "version", "build", "commit", "build_run_id", "upgrade_result",
            "report", "report_sha256", "release_notes_path", "release_notes_sha256", "asset_sha256"}
    require(isinstance(value, dict) and value.get("upgrade_result") in ("passed", "not_run"), "Upgrade result is neither passed nor explicitly not run")
    if value["upgrade_result"] == "not_run":
        keys |= {"owner_override", "override_reason"}
        require(value.get("owner_override") is True, "Untested upgrade needs explicit informed owner override")
        reason = value.get("override_reason")
        require(isinstance(reason, str) and 30 <= len(reason) <= 1000 and reason.strip() == reason
                and "\n" not in reason and "\r" not in reason, "Owner override needs a substantive single-line reason")
    require(isinstance(value, dict) and set(value) == keys, "Approval schema differs")
    require(type(value["schema_version"]) is int and value["schema_version"] == 1, "Unknown approval schema")
    require(value["version"] == version and value["build"] == build, "Approval version/build mismatch")
    require(isinstance(value["commit"], str) and re.fullmatch(r"[a-f0-9]{40}", value["commit"]), "Invalid tested commit")
    require(type(value["build_run_id"]) is int and value["build_run_id"] > 0, "Invalid build run")
    require(isinstance(value["report"], str) and re.fullmatch(r"docs/releases/validation/[A-Za-z0-9][A-Za-z0-9_.-]*\.md", value["report"]), "Invalid report path")
    require(isinstance(value["report_sha256"], str) and re.fullmatch(r"[a-f0-9]{64}", value["report_sha256"]), "Invalid report digest")
    notes = value["release_notes_path"]
    require(isinstance(notes, str) and (notes == f"docs/releases/{version}.md"
            or re.fullmatch(r"docs/releases/public-notes/[A-Za-z0-9][A-Za-z0-9_.-]*\.md", notes)), "Invalid public notes path")
    require(isinstance(value["release_notes_sha256"], str) and re.fullmatch(r"[a-f0-9]{64}", value["release_notes_sha256"]), "Invalid public notes digest")
    hashes = value["asset_sha256"]
    require(isinstance(hashes, dict) and set(hashes) == expected_names(version), "Approval must bind exactly six assets")
    require(all(isinstance(x, str) and re.fullmatch(r"[a-f0-9]{64}", x) for x in hashes.values()), "Invalid approved asset digest")


def validate_report(data, approval):
    require(sha256(data) == approval["report_sha256"], "Upgrade report digest differs")
    text = data.decode("utf-8")
    lines = set(text.splitlines())
    fields = ("Version", "Build", "Candidate commit", "Overall result", "Normal upgrade",
              "Service intervention before completing checks", "Owner override", "Override reason", "Unverified coverage")
    for field in fields:
        require(sum(line.startswith(field + ":") for line in text.splitlines()) <= 1,
                "Duplicate or contradictory report field: " + field)
    required = {f"Version: v{approval['version']}", f"Build: {approval['build']}", f"Candidate commit: {approval['commit']}"}
    if approval["upgrade_result"] == "passed":
        required |= {"Overall result: PASS", "Normal upgrade: PASS", "Service intervention before completing checks: none"}
    else:
        required |= {"Overall result: NOT RUN", "Normal upgrade: NOT RUN", "Owner override: explicit release request after disclosure",
                     "Override reason: " + approval["override_reason"]}
        require(any(line.startswith("Unverified coverage: ") and len(line) > 40 for line in lines), "Override report must document unchecked coverage")
        require("Overall result: PASS" not in lines and "Normal upgrade: PASS" not in lines, "An untested report must not claim a pass")
    require(required <= lines, "Report lacks matching identity or required upgrade outcome evidence")
    sanitized_text(text)


def sanitized_text(text):
    # Do not publish paths or recognizable secrets from a GUI test machine.
    forbidden = r"/Users/[^/\s]+/|/home/[^/\s]+/|/var/folders/|-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}"
    require(not re.search(forbidden, text), "Report contains a private path, address, or credential-shaped literal")


def validate_public_notes(data, approval):
    require(sha256(data) == approval["release_notes_sha256"], "Public notes digest differs")
    text = data.decode("utf-8")
    require(approval["version"] in text and len(text.strip()) >= 80, "Public notes lack release identity or content")
    sanitized_text(text)
    if approval["upgrade_result"] == "not_run":
        require("Normal upgrade validation: NOT RUN" in text.splitlines() and approval["override_reason"] in text,
                "Public notes must explicitly disclose unverified normal upgrade and the informed owner override")
        require(not {"Normal upgrade validation: PASS", "Normal upgrade: PASS"}.intersection(text.splitlines()),
                "Public notes must not claim an unperformed normal upgrade passed")


def validate_run(run, workflow, jobs, approval, repository):
    require(workflow.get("name") == "Build macOS app" and workflow.get("path") == ".github/workflows/build.yml", "Unexpected build workflow")
    require(run.get("workflow_id") == workflow.get("id") and run.get("name") == "Build macOS app", "Build run belongs to another workflow")
    require(run.get("status") == "completed" and run.get("conclusion") == "success", "Build run did not finish successfully")
    require(run.get("head_sha") == approval["commit"] and run.get("head_branch") == "main", "Build run did not test the exact main commit")
    require(run.get("event") in ("push", "workflow_dispatch"), "A pull-request run cannot authorize publication")
    require(run.get("repository", {}).get("full_name") == repository and run.get("head_repository", {}).get("full_name") == repository, "Build run repository differs")
    required = {"Validate release version", "Offline JavaScript and Python contracts", "macOS arm64", "macOS x86_64", "Native macOS 14 arm64", "Native macOS 15 x86_64", "Runtime macOS 14 arm64", "Runtime macOS 15 x86_64", "Prepare verified release draft"}
    for name in required:
        matches = [job for job in jobs if job.get("name") == name]
        require(len(matches) == 1 and matches[0].get("status") == "completed" and matches[0].get("conclusion") == "success", "A required build/draft job did not pass: " + name)


def validate_release(release, assets, approval):
    require(release.get("draft") is True and release.get("prerelease") is False, "Release must still be a non-prerelease draft")
    require(release.get("tag_name") == "v" + approval["version"] and release.get("target_commitish") == approval["commit"], "Draft tag or target differs from tested commit")
    require(len(assets) == 6 and {a.get("name") for a in assets} == expected_names(approval["version"]), "Draft must contain exactly the six expected assets")
    require(len({a.get("id") for a in assets}) == 6, "Duplicate asset identity")
    for asset in assets:
        require(type(asset.get("id")) is int and asset["id"] > 0 and type(asset.get("size")) is int and asset["size"] > 0, "Invalid asset metadata")
        require(asset.get("state") == "uploaded", "Asset upload is incomplete")
        require(asset.get("digest") == "sha256:" + approval["asset_sha256"][asset["name"]], "Draft assets changed since manual testing")
    return sorted((a["id"], a["name"], a["size"], a["digest"]) for a in assets)


def validate_downloads(directory, assets, approval):
    for asset in assets:
        data = (directory / asset["name"]).read_bytes()
        require(len(data) == asset["size"] and sha256(data) == approval["asset_sha256"][asset["name"]], "Downloaded asset differs from approved bytes")
    for arch in ("arm64", "x86_64"):
        prefix = f"GarminDesk-{approval['version']}-{arch}"
        manifest = (directory / (prefix + "-SHA256.txt")).read_text("utf-8")
        entries = {}
        for line in manifest.splitlines():
            match = re.fullmatch(r"([a-f0-9]{64}) [ *]([^/\\\s]+)", line)
            require(match is not None, "Malformed checksum manifest")
            digest, name = match.groups()
            require(name not in entries, "Duplicate checksum entry")
            entries[name] = digest
        require(set(entries) == {prefix + ".dmg", prefix + ".zip"}, "Checksum manifest names unexpected assets")
        require(all(approval["asset_sha256"][name] == digest for name, digest in entries.items()), "Checksum manifest differs from downloaded packages")


def package_artifacts(response, approval):
    artifacts = response.get("artifacts", [])
    require(response.get("total_count") == len(artifacts), "Incomplete CI artifact listing")
    result = {}
    for arch in ("arm64", "x86_64"):
        name = f"GarminDesk-{approval['version']}-build{approval['build']}-{arch}-development"
        matches = [item for item in artifacts if item.get("name") == name]
        require(len(matches) == 1, "Missing or duplicate tested package artifact: " + arch)
        artifact = matches[0]
        require(type(artifact.get("id")) is int and artifact["id"] > 0 and artifact.get("expired") is False,
                "Tested package artifact is invalid or expired")
        run = artifact.get("workflow_run", {})
        require(run.get("id") == approval["build_run_id"] and run.get("head_sha") == approval["commit"]
                and run.get("head_branch") == "main", "Package artifact belongs to another run or commit")
        result[arch] = artifact
    return result


def validate_artifact_archive(path, arch, assets, approval):
    expected = {f"GarminDesk-{approval['version']}-{arch}{suffix}" for suffix in (".dmg", ".zip", "-SHA256.txt")}
    sizes = {asset["name"]: asset["size"] for asset in assets}
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            require(len(members) == 3 and {item.filename for item in members} == expected,
                    "CI package artifact must contain exactly its three expected files")
            for item in members:
                require(not item.is_dir() and item.file_size == sizes[item.filename] and not item.flag_bits & 1,
                        "CI package member metadata differs from the approved draft")
                # Read only known members. Never extract paths from an artifact ZIP.
                require(sha256(archive.read(item)) == approval["asset_sha256"][item.filename],
                        "Draft package bytes differ from the approved CI run artifact")
    except zipfile.BadZipFile as error:
        raise Rejected("Invalid CI artifact ZIP") from error


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def api(self, path, pages=False):
        args = ["gh", "api", f"repos/{self.repository}/{path}"]
        if pages:
            args += ["--paginate", "--slurp"]
        value = json_bytes(subprocess.check_output(args))
        return [item for page in value for item in page] if pages else value

    def download(self, asset, path):
        with path.open("wb") as stream:
            subprocess.run(["gh", "api", f"repos/{self.repository}/releases/assets/{asset['id']}",
                            "-H", "Accept: application/octet-stream"], stdout=stream, check=True)

    def download_artifact(self, artifact, path):
        with path.open("wb") as stream:
            subprocess.run(["gh", "api", f"repos/{self.repository}/actions/artifacts/{artifact['id']}/zip"],
                           stdout=stream, check=True)

    def publish(self, tag, notes):
        with tempfile.TemporaryDirectory(prefix="garmin-release-notes-") as temporary:
            path = Path(temporary) / "notes.md"
            path.write_bytes(notes)
            subprocess.run(["gh", "release", "edit", tag, "--notes-file", str(path),
                            "--draft=false", "--latest", "--repo", self.repository], check=True)


def promote(root, environment, github=None):
    require(environment.get("GITHUB_ACTIONS") == "true" and environment.get("GITHUB_REF") == "refs/heads/main"
            and environment.get("GITHUB_EVENT_NAME") == "push", "Promotion runs only on a main push in GitHub Actions")
    repository = environment.get("GITHUB_REPOSITORY", "")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) and environment.get("GH_REPO") == repository, "Invalid repository context")
    head = environment.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[a-f0-9]{40}", head), "Invalid approval commit")
    require(git(root, "rev-parse", "HEAD").decode().strip() == head, "Checkout differs from approval push")
    event = json_bytes(Path(environment["GITHUB_EVENT_PATH"]).read_bytes())
    require(event.get("ref") == "refs/heads/main" and event.get("after") == head and not event.get("forced") and not event.get("deleted"), "Unexpected push event")
    require(event.get("repository", {}).get("full_name") == repository and event.get("repository", {}).get("default_branch") == "main", "Approval is not on repository main")
    before = event.get("before", "")
    require(re.fullmatch(r"[a-f0-9]{40}", before) and before != "0" * 40, "Approval needs an existing main history")
    version, build = identity(root, head)
    approval_path = f"docs/releases/approvals/v{version}.json"
    changed = set(git(root, "diff", "--name-only", before, head).decode().splitlines())
    require(approval_path in changed, "This push did not change the current release approval")
    approval = json_bytes(git(root, "show", f"{head}:{approval_path}"))
    validate_approval(approval, version, build)
    require(identity(root, approval["commit"]) == (version, build), "Tested commit has another version/build")
    subprocess.run(["git", "merge-base", "--is-ancestor", approval["commit"], head], cwd=root, check=True)
    evidence_files = {approval_path, approval["report"], approval["release_notes_path"]}
    allowed = evidence_files | publication_files(version)
    require(changed <= allowed and set(git(root, "diff", "--name-only", approval["commit"], head).decode().splitlines()) <= allowed,
            "Code or unrelated files changed after the tested candidate")
    for path in evidence_files:
        require(git(root, "ls-tree", head, "--", path).decode().startswith("100644 blob "), "Approval/report must be ordinary tracked files")
    validate_report(git(root, "show", f"{head}:{approval['report']}"), approval)
    notes = git(root, "show", f"{head}:{approval['release_notes_path']}")
    validate_public_notes(notes, approval)

    github = github or GitHub(repository)
    require(github.api("git/ref/heads/main")["object"]["sha"] == head, "Main advanced beyond the approval commit")
    workflow = github.api("actions/workflows/build.yml")
    run = github.api(f"actions/runs/{approval['build_run_id']}")
    jobs = github.api(f"actions/runs/{approval['build_run_id']}/jobs?filter=latest&per_page=100")["jobs"]
    validate_run(run, workflow, jobs, approval, repository)
    tag = "v" + version
    def check_tag():
        refs = github.api("git/matching-refs/tags/" + tag)
        for ref in refs:
            if ref.get("ref") != "refs/tags/" + tag:
                continue
            target = ref["object"]
            if target["type"] == "tag":
                target = github.api("git/tags/" + target["sha"])["object"]
            require(target["type"] == "commit" and target["sha"] == approval["commit"], "Existing release tag points elsewhere")
    check_tag()
    releases = [r for r in github.api("releases?per_page=100", pages=True) if r.get("tag_name") == tag]
    require(len(releases) == 1, "Expected exactly one release for the approved tag")
    release = releases[0]
    require(type(release.get("id")) is int and release["id"] > 0, "Invalid release identity")
    asset_path = f"releases/{release['id']}/assets?per_page=100"
    assets = github.api(asset_path, pages=True)
    fingerprint = validate_release(release, assets, approval)
    artifacts = package_artifacts(github.api(f"actions/runs/{approval['build_run_id']}/artifacts?per_page=100"), approval)
    with tempfile.TemporaryDirectory(prefix="garmin-release-promotion-") as temporary:
        directory = Path(temporary)
        for asset in assets:
            github.download(asset, directory / asset["name"])
        validate_downloads(directory, assets, approval)
        for arch, artifact in artifacts.items():
            archive = directory / ("ci-" + arch + ".zip")
            github.download_artifact(artifact, archive)
            validate_artifact_archive(archive, arch, assets, approval)
    # Recheck both remote identities immediately before the only write operation.
    current = github.api(f"releases/{release['id']}")
    require(validate_release(current, github.api(asset_path, pages=True), approval) == fingerprint, "Draft changed during verification")
    require(github.api("git/ref/heads/main")["object"]["sha"] == head, "Main advanced during verification")
    check_tag()
    github.publish(tag, notes)
    published = github.api(f"releases/{release['id']}")
    require(published.get("draft") is False and published.get("target_commitish") == approval["commit"], "Publication result could not be verified")
    require(published.get("body", "").strip() == notes.decode("utf-8").strip(), "Published body differs from the approved public notes")
    require(github.api("releases/latest").get("id") == release["id"], "Latest-release status could not be verified")
    print(f"Published verified {tag} from {approval['commit']}; six approved assets retained.")


if __name__ == "__main__":
    try:
        promote(Path(__file__).resolve().parent.parent, os.environ)
    except (Rejected, KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit("Release promotion stopped: " + str(error)) from None

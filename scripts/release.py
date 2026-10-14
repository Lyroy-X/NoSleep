"""Version validation and retryable GitHub publication; stdlib only.

Publication is intentionally separate from build/test and is only allowed by the
CLI in a GitHub Actions push to main. Tests inject a fake API; local checks never
need credentials or publish anything.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib import error, parse, request

ROOT = Path(__file__).resolve().parents[1]
DMG = "NoSleep-universal.dmg"
CHECKSUM = "SHA256SUMS.txt"
MANIFEST = "release.json"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")


class ReleaseError(RuntimeError):
    pass


class APIError(ReleaseError):
    def __init__(self, status, method, path):
        self.status = status
        super().__init__(f"GitHub API {method} {path}: HTTP {status}")


def version_tuple(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ReleaseError("Version must be MAJOR.MINOR.PATCH without leading zeros")
    return tuple(map(int, value.split(".")))


def bundle_version(content, legacy=False):
    info = plistlib.loads(content)
    version = info.get("CFBundleShortVersionString")
    # The published historical main uses 3.0; only comparison of old inputs accepts it.
    if legacy and isinstance(version, str) and re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        version += ".0"
    version_tuple(version)
    build = info.get("CFBundleVersion")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ReleaseError("CFBundleVersion must be a positive integer string")
    return version, int(build)


def validate_versions(current, previous=None):
    version, build = bundle_version(current)
    if previous is not None:
        old_version, old_build = bundle_version(previous, legacy=True)
        if version_tuple(version) <= version_tuple(old_version):
            raise ReleaseError(f"Version {version} must exceed {old_version}; update Info.plist before merge")
        if build <= old_build:
            raise ReleaseError(f"Build {build} must exceed {old_build}; update Info.plist before merge")
    return version, build


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=False)
    if result.returncode:
        raise ReleaseError("Cannot read the requested Git input; full history is required")
    return result.stdout


def checked_sha(value):
    if not isinstance(value, str) or not SHA.fullmatch(value) or value == "0" * 40:
        raise ReleaseError("Expected a nonzero, full commit SHA")
    return value


def validate_source(root, base):
    previous = None
    if base:
        checked_sha(base)
        previous = git(root, "show", f"{base}:Resources/Info.plist")
    return validate_versions((root / "Resources/Info.plist").read_bytes(), previous)


def prepare(root, source_sha, base_sha, directory):
    checked_sha(source_sha)
    checked_sha(base_sha)
    if git(root, "rev-parse", "HEAD").decode().strip() != source_sha:
        raise ReleaseError("Checkout does not match the release event SHA")
    if git(root, "status", "--porcelain", "--untracked-files=no").strip():
        raise ReleaseError("Release source has tracked changes; build the exact event SHA")
    if subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", base_sha, source_sha],
                      capture_output=True).returncode:
        raise ReleaseError("Previous main SHA is not an ancestor; refusing a rewritten release history")
    version, build = validate_source(root, base_sha)
    directory.mkdir(parents=True, exist_ok=True)
    metadata = {"version": version, "build": build, "tag": f"v{version}",
                "source_sha": source_sha, "previous_sha": base_sha, "asset": DMG}
    (directory / MANIFEST).write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def metadata_at(directory):
    metadata = json.loads((directory / MANIFEST).read_text())
    version_tuple(metadata.get("version"))
    if metadata.get("tag") != "v" + metadata["version"] or metadata.get("asset") != DMG:
        raise ReleaseError("Invalid release tag or asset name")
    if type(metadata.get("build")) is not int or metadata["build"] < 1:
        raise ReleaseError("Invalid release build number")
    checked_sha(metadata.get("source_sha"))
    checked_sha(metadata.get("previous_sha"))
    return metadata


def finalize(directory, app):
    metadata = metadata_at(directory)
    version, build = bundle_version((app / "Contents/Info.plist").read_bytes())
    if (version, build) != (metadata["version"], metadata["build"]):
        raise ReleaseError("Packaged application version differs from release metadata")
    digest = hashlib.sha256((directory / DMG).read_bytes()).hexdigest()
    (directory / CHECKSUM).write_text(f"{digest}  {DMG}\n")
    metadata["sha256"] = digest
    (directory / MANIFEST).write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def verify_files(directory, source_sha, root):
    metadata = metadata_at(directory)
    if metadata["source_sha"] != checked_sha(source_sha):
        raise ReleaseError("Artifact SHA differs from the release event")
    if git(root, "rev-parse", "HEAD").decode().strip() != source_sha:
        raise ReleaseError("Publisher checkout differs from the release event")
    if bundle_version((root / "Resources/Info.plist").read_bytes()) != (metadata["version"], metadata["build"]):
        raise ReleaseError("Artifact version differs from the event source")
    digest = metadata.get("sha256")
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
        raise ReleaseError("Artifact has no valid SHA-256")
    for name in (DMG, CHECKSUM, MANIFEST):
        if (directory / name).is_symlink() or not (directory / name).is_file():
            raise ReleaseError("Release artifact must contain regular files")
    if hashlib.sha256((directory / DMG).read_bytes()).hexdigest() != digest:
        raise ReleaseError("DMG checksum mismatch")
    if (directory / CHECKSUM).read_text() != f"{digest}  {DMG}\n":
        raise ReleaseError("Checksum file differs from the release metadata")
    return metadata


class GitHub:
    def __init__(self, token):
        if not token:
            raise ReleaseError("GH_TOKEN is required in the publisher job")
        self.token = token

    def call(self, method, path, body=None, data=None):
        host = "https://uploads.github.com" if data is not None else "https://api.github.com"
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "NoSleep-release"}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        elif data is not None:
            headers["Content-Type"] = "application/octet-stream"
        try:
            with request.urlopen(request.Request(host + path, data=data, headers=headers, method=method), timeout=120) as response:
                content = response.read()
                return json.loads(content) if content else None
        except error.HTTPError as failure:
            # Do not echo API bodies, auth headers or URLs containing credentials.
            raise APIError(failure.code, method, path) from None
        except (error.URLError, TimeoutError):
            raise ReleaseError(f"GitHub transport failed during {method}; rerun this workflow") from None

    def optional(self, path):
        try:
            return self.call("GET", path)
        except APIError as failure:
            if failure.status == 404:
                return None
            raise


def tag_sha(api, prefix, tag):
    ref = api.optional(prefix + "/git/ref/tags/" + tag)
    if ref is None:
        return None
    target = ref["object"]
    for _ in range(4):
        if target["type"] == "commit":
            return checked_sha(target["sha"])
        if target["type"] != "tag":
            break
        target = api.call("GET", prefix + "/git/tags/" + target["sha"])["object"]
    raise ReleaseError("Release tag does not resolve to a commit")


def asset_matches(asset, content):
    return (asset.get("state") == "uploaded" and asset.get("size") == len(content)
            and asset.get("digest") == "sha256:" + hashlib.sha256(content).hexdigest())


def published_matches(release, metadata):
    """A rebuild of one SHA can have different DMG bytes; retain the first release."""
    marker = f"Version {metadata['version']}, build {metadata['build']}. Source: {metadata['source_sha']}.\n"
    body = release.get("body", "")
    if marker not in body:
        raise ReleaseError("Published release has no matching version/build/source receipt")
    match = re.search(r"^DMG SHA-256: ([0-9a-f]{64})\.$", body, re.MULTILINE)
    if match is None:
        raise ReleaseError("Published release has no checksum receipt")
    digest = match.group(1)
    dmg = next((item for item in release["assets"] if item["name"] == DMG), None)
    checksum = next((item for item in release["assets"] if item["name"] == CHECKSUM), None)
    if (dmg is None or dmg.get("state") != "uploaded" or dmg.get("size", 0) <= 0
            or dmg.get("digest") != "sha256:" + digest
            or checksum is None or not asset_matches(checksum, f"{digest}  {DMG}\n".encode())):
        raise ReleaseError("Published release is incomplete or its checksum receipt differs")


def publish(directory, repository, source_sha, api, root=ROOT):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ReleaseError("Repository must be owner/name")
    metadata = verify_files(directory, source_sha, root)
    prefix = "/repos/" + repository
    tag = metadata["tag"]
    target = tag_sha(api, prefix, tag)
    if target is not None and target != source_sha:
        raise ReleaseError("This version tag already belongs to another SHA; do not reuse it")
    release = api.optional(prefix + "/releases/tags/" + tag)
    payloads = {name: (directory / name).read_bytes() for name in (DMG, CHECKSUM)}
    if release is None:
        notes = api.call("POST", prefix + "/releases/generate-notes",
                         body={"tag_name": tag, "target_commitish": source_sha})
        body = ("Universal DMG for Apple Silicon and Intel, macOS 14+.\n"
                "Current ad-hoc signature: macOS may require Open Anyway.\n\n"
                f"Version {metadata['version']}, build {metadata['build']}. Source: {source_sha}.\n"
                f"DMG SHA-256: {metadata['sha256']}.\n\n"
                + notes.get("body", ""))
        release = api.call("POST", prefix + "/releases", body={"tag_name": tag,
                           "target_commitish": source_sha, "name": "NoSleep " + metadata["version"],
                           "body": body, "draft": True, "prerelease": False})
    elif release.get("prerelease"):
        raise ReleaseError("Existing version is a prerelease; refusing to repurpose it")
    if release["draft"] and release.get("target_commitish") != source_sha:
        raise ReleaseError("Existing draft belongs to a different source")
    if not release["draft"] and target != source_sha:
        raise ReleaseError("Published release tag cannot be verified")
    if not release["draft"]:
        published_matches(release, metadata)
        return release["html_url"]
    release_path = prefix + "/releases/" + str(release["id"])
    # Refresh the receipt when a failed run rebuilds the exact source into new DMG bytes.
    if not re.search(r"^DMG SHA-256: [0-9a-f]{64}\.$", release.get("body", ""), re.MULTILINE):
        raise ReleaseError("Existing draft has no managed checksum receipt")
    new_body = re.sub(r"^DMG SHA-256: [0-9a-f]{64}\.$", f"DMG SHA-256: {metadata['sha256']}.",
                      release["body"], count=1, flags=re.MULTILINE)
    if new_body != release["body"]:
        release = api.call("PATCH", release_path, body={"body": new_body})
    for name, content in payloads.items():
        existing = next((asset for asset in release["assets"] if asset["name"] == name), None)
        if existing is not None and asset_matches(existing, content):
            continue
        if not release["draft"]:
            raise ReleaseError("Published release assets differ; never overwrite a published release")
        if existing is not None:
            api.call("DELETE", prefix + "/releases/assets/" + str(existing["id"]))
        api.call("POST", release_path + "/assets?name=" + parse.quote(name), data=content)
    release = api.call("GET", release_path)
    for name, content in payloads.items():
        asset = next((asset for asset in release["assets"] if asset["name"] == name), None)
        if asset is None or not asset_matches(asset, content):
            raise ReleaseError("Uploaded assets are incomplete or differ; keep the release unpublished")
    if release["draft"]:
        release = api.call("PATCH", release_path, body={"draft": False, "make_latest": "legacy"})
    if release["draft"] or tag_sha(api, prefix, tag) != source_sha:
        raise ReleaseError("Cannot verify the published release and its exact source tag")
    return release["html_url"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--base", default="")
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--sha", required=True)
    prepare_parser.add_argument("--base", required=True)
    prepare_parser.add_argument("--directory", type=Path, required=True)
    finalize_parser = commands.add_parser("finalize")
    finalize_parser.add_argument("--directory", type=Path, required=True)
    finalize_parser.add_argument("--app", type=Path, required=True)
    publisher = commands.add_parser("publish")
    publisher.add_argument("--directory", type=Path, required=True)
    publisher.add_argument("--sha", required=True)
    publisher.add_argument("--repository", required=True)
    args = parser.parse_args()
    try:
        if args.command == "validate":
            print("PASS: release version/build", *validate_source(ROOT, args.base))
        elif args.command == "prepare":
            print(json.dumps(prepare(ROOT, args.sha, args.base, args.directory)))
        elif args.command == "finalize":
            print(json.dumps(finalize(args.directory, args.app)))
        else:
            if (os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_EVENT_NAME") != "push"
                    or os.environ.get("GITHUB_REF") != "refs/heads/main"
                    or os.environ.get("GITHUB_SHA") != args.sha
                    or os.environ.get("GITHUB_REPOSITORY") != args.repository):
                raise ReleaseError("Publication is only allowed in the matching Actions push to main")
            print(publish(args.directory, args.repository, args.sha, GitHub(os.environ.get("GH_TOKEN"))))
    except (ReleaseError, OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as failure:
        print(f"Release failed: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

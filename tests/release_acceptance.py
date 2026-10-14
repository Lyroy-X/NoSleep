"""Exercise release policy, exact-source publication and recovery without GitHub writes."""
import copy
import hashlib
import importlib.util
import json
import io
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SOURCE = "a" * 40
BASE = "b" * 40


def plist(version="3.4.1", build="12"):
    return plistlib.dumps({key: value for key, value in
                          {"CFBundleShortVersionString": version, "CFBundleVersion": build}.items()
                          if value is not None})


class FakeGitHub:
    def __init__(self):
        self.release = None
        self.tag = None
        self.calls = []
        self.fail_asset = None
        self.corrupt_asset = None
        self.fail_publish = False
        self.failed_after_publish = False
        self.tags = {}
        self.next_asset_id = 1
        self.wrong_published_tag = False
        self.stay_draft = False
        self.publish_on_get = False
        self.publish_on_body_patch = False

    def optional(self, path):
        self.calls.append(("GET", path, None))
        if "/git/ref/tags/" in path:
            return {"object": self.tag} if self.tag else None
        return copy.deepcopy(self.release)

    def call(self, method, path, body=None, data=None):
        self.calls.append((method, path, body))
        if "/git/tags/" in path:
            return {"object": self.tags[path.rsplit("/", 1)[-1]]}
        if path.endswith("/generate-notes"):
            return {"body": "Changes since the previous release."}
        if method == "POST" and path.endswith("/releases"):
            self.release = {**body, "id": 42, "assets": [], "html_url": "https://github.com/owner/repo/releases/tag/v3.4.1"}
            return copy.deepcopy(self.release)
        if method == "POST" and "/assets?name=" in path:
            name = path.split("name=", 1)[1]
            if name == self.fail_asset:
                raise release.APIError(503, method, path)
            asset = {"id": self.next_asset_id, "name": name, "state": "uploaded",
                     "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
            self.next_asset_id += 1
            if name == self.corrupt_asset:
                asset["digest"] = "sha256:" + "0" * 64
            self.release["assets"].append(asset)
            return copy.deepcopy(asset)
        if method == "DELETE":
            asset_id = int(path.rsplit("/", 1)[-1])
            self.release["assets"] = [item for item in self.release["assets"] if item["id"] != asset_id]
            return None
        if method == "PATCH":
            if body.get("draft") is False:
                if self.fail_publish:
                    raise release.APIError(503, method, path)
                self.tag = {"type": "commit", "sha": self.release["target_commitish"]}
                if self.wrong_published_tag:
                    self.tag["sha"] = BASE
            self.release.update(body)
            if self.publish_on_body_patch and "body" in body:
                self.release["draft"] = False
            if self.stay_draft and body.get("draft") is False:
                self.release["draft"] = True
            if body.get("draft") is False and self.failed_after_publish:
                raise release.APIError(503, method, path)
            return copy.deepcopy(self.release)
        if self.publish_on_get:
            self.release["draft"] = False
            self.tag = {"type": "commit", "sha": self.release["target_commitish"]}
        return copy.deepcopy(self.release)


class VersionTests(unittest.TestCase):
    def test_semver_and_build_increment(self):
        for old, new in [("3.4.0", "3.4.1"), ("3.4.9", "3.5.0"), ("3.9.9", "4.0.0"), ("3.0", "3.4.1")]:
            with self.subTest(old=old):
                self.assertEqual(release.validate_versions(plist(new), plist(old, "11")), (new, 12))

    def test_equal_lower_and_invalid_versions_fail(self):
        for value in ["3.4.0", "3.3.99", "03.5.0", "3.5", "3.5.0-beta", "3.5.0;touch x", None]:
            with self.subTest(value=value), self.assertRaises(release.ReleaseError):
                release.validate_versions(plist(value), plist("3.4.0", "11"))

    def test_build_is_independent_positive_integer(self):
        for build in ["11", "10", "0", "01", "1.0", 12, None]:
            with self.subTest(build=build), self.assertRaises(release.ReleaseError):
                release.validate_versions(plist(build=build), plist("3.4.0", "11"))

    def test_bad_base_sha_never_reaches_git(self):
        for value in ["main", "0" * 40, "a" * 39, "a" * 40 + ";bad", None]:
            with self.subTest(value=value), self.assertRaises(release.ReleaseError):
                release.checked_sha(value)

    def test_git_error_is_not_treated_as_empty_history(self):
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"", b"private")):
            with self.assertRaisesRegex(release.ReleaseError, "full history"):
                release.git(ROOT, "show", "missing")
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"read-only result", b"")):
            self.assertEqual(release.git(ROOT, "show", "valid"), b"read-only result")
        self.assertEqual(release.validate_versions(plist()), ("3.4.1", 12))

    def test_prepare_requires_exact_clean_ancestor_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Resources").mkdir()
            (root / "Resources/Info.plist").write_bytes(plist())
            for head, dirty, ancestry in [(BASE, b"", 0), (SOURCE, b" M code", 0), (SOURCE, b"", 1)]:
                with self.subTest(head=head, dirty=dirty, ancestry=ancestry):
                    def read_git(_, *args):
                        if args[0] == "rev-parse":
                            return head.encode()
                        return dirty
                    with patch.object(release, "git", side_effect=read_git), patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], ancestry)):
                        with self.assertRaises(release.ReleaseError):
                            release.prepare(root, SOURCE, BASE, root / "out")
                        self.assertFalse((root / "out").exists())
            def good_git(_, *args):
                return SOURCE.encode() if args[0] == "rev-parse" else plist("3.4.0", "11") if args[0] == "show" else b""
            with patch.object(release, "git", side_effect=good_git), patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
                result = release.prepare(root, SOURCE, BASE, root / "out")
                self.assertEqual(result["tag"], "v3.4.1")
                self.assertEqual(result["previous_sha"], BASE)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Resources").mkdir()
        (self.root / "Resources/Info.plist").write_bytes(plist())
        self.directory = self.root / "out"
        self.directory.mkdir()
        self.app = self.root / "Fixture.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plist())
        (self.directory / release.DMG).write_bytes(b"owned inert DMG fixture")
        self.metadata = {"version": "3.4.1", "build": 12, "tag": "v3.4.1", "source_sha": SOURCE, "previous_sha": BASE, "asset": release.DMG}
        (self.directory / release.MANIFEST).write_text(json.dumps(self.metadata))
        release.finalize(self.directory, self.app)
        self.api = FakeGitHub()
        self.git_patch = patch.object(release, "git", return_value=SOURCE.encode())
        self.git_patch.start()
        self.addCleanup(self.git_patch.stop)

    def publish(self):
        return release.publish(self.directory, "owner/repo", SOURCE, self.api, self.root)

    def test_fresh_release_publishes_after_both_verified_assets(self):
        self.assertIn("/releases/tag/v3.4.1", self.publish())
        self.assertFalse(self.api.release["draft"])
        self.assertEqual(self.api.release["make_latest"], "legacy")
        self.assertEqual(self.api.tag["sha"], SOURCE)
        self.assertEqual({item["name"] for item in self.api.release["assets"]}, {release.DMG, release.CHECKSUM})
        self.assertEqual(sum(method == "POST" and path.endswith("/releases") for method, path, _ in self.api.calls), 1)

    def test_rerun_of_published_source_performs_no_writes_even_after_rebuild(self):
        self.publish()
        assets = copy.deepcopy(self.api.release["assets"])
        (self.directory / release.DMG).write_bytes(b"rebuilt DMG with new container timestamps")
        release.finalize(self.directory, self.app)
        self.api.calls.clear()
        self.publish()
        self.assertTrue(all(method == "GET" for method, _, _ in self.api.calls))
        self.assertEqual(self.api.release["assets"], assets)

    def test_upload_failure_leaves_draft_and_retry_resumes_it(self):
        self.api.fail_asset = release.CHECKSUM
        with self.assertRaises(release.APIError):
            self.publish()
        self.assertTrue(self.api.release["draft"])
        self.assertEqual(len(self.api.release["assets"]), 1)
        self.api.fail_asset = None
        self.publish()
        self.assertFalse(self.api.release["draft"])
        self.assertEqual(sum(method == "POST" and path.endswith("/releases") for method, path, _ in self.api.calls), 1)

    def test_rebuilt_draft_replaces_only_draft_assets_and_refreshes_receipt(self):
        self.api.fail_publish = True
        with self.assertRaises(release.APIError):
            self.publish()
        (self.directory / release.DMG).write_bytes(b"new draft package")
        release.finalize(self.directory, self.app)
        self.api.fail_publish = False
        self.publish()
        self.assertTrue(any(method == "DELETE" for method, _, _ in self.api.calls))
        release.published_matches(self.api.release, release.metadata_at(self.directory))

    def test_lost_publication_response_can_be_retried_without_duplication(self):
        self.api.failed_after_publish = True
        with self.assertRaises(release.APIError):
            self.publish()
        self.api.calls.clear()
        self.publish()
        self.assertTrue(all(method == "GET" for method, _, _ in self.api.calls))

    def test_different_sha_tag_and_wrong_draft_are_never_reused(self):
        self.api.tag = {"type": "commit", "sha": BASE}
        with self.assertRaisesRegex(release.ReleaseError, "another SHA"):
            self.publish()
        self.assertTrue(all(method == "GET" for method, _, _ in self.api.calls))
        self.api.tag = None
        self.api.fail_publish = True
        with self.assertRaises(release.APIError):
            self.publish()
        self.api.release["target_commitish"] = BASE
        with self.assertRaisesRegex(release.ReleaseError, "different source"):
            self.publish()

    def test_published_incomplete_corrupt_or_unmanaged_releases_are_not_modified(self):
        self.publish()
        good = copy.deepcopy(self.api.release)
        for field, value in [("assets", []), ("body", "manual release"), ("body", "Version 3.4.1, build 12. Source: " + SOURCE + ".\n")]:
            with self.subTest(field=field, value=value):
                self.api.release = {**good, field: value}
                self.api.calls.clear()
                with self.assertRaises(release.ReleaseError):
                    self.publish()
                self.assertTrue(all(method == "GET" for method, _, _ in self.api.calls))

    def test_corrupt_uploaded_asset_is_never_published(self):
        self.api.corrupt_asset = release.DMG
        with self.assertRaisesRegex(release.ReleaseError, "incomplete"):
            self.publish()
        self.assertTrue(self.api.release["draft"])
        self.assertFalse(any(method == "PATCH" and body.get("draft") is False for method, _, body in self.api.calls))

    def test_published_tag_response_must_match_exact_source(self):
        self.api.wrong_published_tag = True
        with self.assertRaisesRegex(release.ReleaseError, "exact source"):
            self.publish()

    def test_local_artifact_tampering_fails_before_api(self):
        for name in [release.DMG, release.CHECKSUM]:
            path = self.directory / name
            original = path.read_bytes()
            path.write_bytes(b"tampered")
            with self.subTest(name=name), self.assertRaises(release.ReleaseError):
                self.publish()
            self.assertEqual(self.api.calls, [])
            path.write_bytes(original)
        with self.assertRaisesRegex(release.ReleaseError, "event"):
            release.verify_files(self.directory, BASE, self.root)
        with self.assertRaisesRegex(release.ReleaseError, "owner/name"):
            release.publish(self.directory, "bad/path/extra", SOURCE, self.api, self.root)

    def test_bundle_metadata_mismatch_fails(self):
        (self.app / "Contents/Info.plist").write_bytes(plist("3.5.0"))
        with self.assertRaisesRegex(release.ReleaseError, "differs"):
            release.finalize(self.directory, self.app)
        (self.root / "Resources/Info.plist").write_bytes(plist(build="13"))
        with self.assertRaisesRegex(release.ReleaseError, "version differs"):
            self.publish()

    def test_bad_manifest_digest_files_and_publisher_checkout_are_rejected(self):
        original = (self.directory / release.MANIFEST).read_text()
        for field, value in [("tag", "v9.0.0"), ("asset", "../other.dmg"), ("build", "12"),
                             ("build", 0), ("sha256", None), ("sha256", "bad")]:
            with self.subTest(field=field, value=value):
                metadata = json.loads(original)
                metadata[field] = value
                (self.directory / release.MANIFEST).write_text(json.dumps(metadata))
                with self.assertRaises(release.ReleaseError):
                    self.publish()
        (self.directory / release.MANIFEST).write_text(original)
        with patch.object(release, "git", return_value=BASE.encode()), self.assertRaisesRegex(release.ReleaseError, "checkout"):
            self.publish()
        for name in (release.DMG, release.CHECKSUM):
            path = self.directory / name
            content = path.read_bytes()
            path.unlink()
            with self.subTest(name=name), self.assertRaisesRegex(release.ReleaseError, "regular files"):
                self.publish()
            target = self.root / "owned-file"
            target.write_bytes(content)
            path.symlink_to(target)
            with self.assertRaisesRegex(release.ReleaseError, "regular files"):
                self.publish()
            path.unlink()
            path.write_bytes(content)

    def test_prerelease_unmanaged_draft_and_missing_published_tag_fail(self):
        self.publish()
        saved = copy.deepcopy(self.api.release)
        self.api.release["prerelease"] = True
        with self.assertRaisesRegex(release.ReleaseError, "prerelease"):
            self.publish()
        self.api.release = saved
        self.api.tag = None
        with self.assertRaisesRegex(release.ReleaseError, "tag cannot"):
            self.publish()
        self.api.release = {**saved, "draft": True, "body": "Unmanaged draft"}
        with self.assertRaisesRegex(release.ReleaseError, "managed checksum"):
            self.publish()

    def test_publication_race_never_overwrites_newly_published_assets(self):
        self.api.fail_publish = True
        with self.assertRaises(release.APIError):
            self.publish()
        (self.directory / release.DMG).write_bytes(b"rebuilt package")
        release.finalize(self.directory, self.app)
        self.api.publish_on_body_patch = True
        self.api.calls.clear()
        with self.assertRaisesRegex(release.ReleaseError, "never overwrite"):
            self.publish()
        self.assertFalse(any(method in ("POST", "DELETE") for method, _, _ in self.api.calls))

    def test_complete_release_published_by_another_actor_is_verified(self):
        self.api.publish_on_get = True
        self.publish()
        self.assertFalse(any(method == "PATCH" and body.get("draft") is False for method, _, body in self.api.calls))

    def test_server_staying_draft_after_publish_is_not_success(self):
        self.api.stay_draft = True
        with self.assertRaisesRegex(release.ReleaseError, "Cannot verify"):
            self.publish()

    def test_annotated_tag_is_peeled_and_noncommit_tag_refused(self):
        self.api.tag = {"type": "tag", "sha": BASE}
        self.api.tags[BASE] = {"type": "commit", "sha": SOURCE}
        self.assertEqual(release.tag_sha(self.api, "/repos/owner/repo", "v3.4.1"), SOURCE)
        self.api.tags[BASE] = {"type": "tree", "sha": SOURCE}
        with self.assertRaisesRegex(release.ReleaseError, "resolve"):
            release.tag_sha(self.api, "/repos/owner/repo", "v3.4.1")
        self.api.tags[BASE] = {"type": "tag", "sha": BASE}
        with self.assertRaisesRegex(release.ReleaseError, "resolve"):
            release.tag_sha(self.api, "/repos/owner/repo", "v3.4.1")

    def test_api_errors_fail_closed_and_do_not_expose_secrets(self):
        api = release.GitHub("secret-fixture-do-not-print")
        with patch.object(api, "call", side_effect=release.APIError(403, "GET", "/test")):
            with self.assertRaises(release.APIError):
                api.optional("/test")
        with patch.object(api, "call", side_effect=release.APIError(404, "GET", "/test")):
            self.assertIsNone(api.optional("/test"))
        with patch.object(release.request, "urlopen", side_effect=release.error.URLError("private payload")):
            with self.assertRaises(release.ReleaseError) as caught:
                api.call("POST", "/test", body={"value": 1})
            self.assertNotIn("private", str(caught.exception))
            self.assertNotIn(api.token, str(caught.exception))
        with self.assertRaises(release.ReleaseError):
            release.GitHub("")

    def test_http_json_binary_and_empty_responses_use_the_correct_host(self):
        api = release.GitHub("owned-fixture")
        for method, body, data, content, host in [("GET", None, None, b'{"id":1}', "api"),
                                                ("POST", {"a": 1}, None, b'{"id":2}', "api"),
                                                ("POST", None, b"image", b'{"id":3}', "uploads"),
                                                ("DELETE", None, None, b"", "api")]:
            with self.subTest(method=method, host=host):
                response = unittest.mock.MagicMock()
                response.__enter__.return_value.read.return_value = content
                with patch.object(release.request, "urlopen", return_value=response) as transport:
                    result = api.call(method, "/repos/owner/repo/test", body=body, data=data)
                    self.assertEqual(result, json.loads(content) if content else None)
                    sent = transport.call_args.args[0]
                    self.assertTrue(sent.full_url.startswith(f"https://{host}.github.com/"))
                    self.assertEqual(sent.method, method)
        failure = release.error.HTTPError("https://api.github.com/test", 403, "Private response", {}, None)
        with patch.object(release.request, "urlopen", side_effect=failure), self.assertRaises(release.APIError) as caught:
            api.call("GET", "/test")
        self.assertNotIn("Private", str(caught.exception))

    def test_cli_routes_validation_preparation_finalization_and_gated_publication(self):
        commands = [(["validate"], "validate_source", ("3.4.1", 12)),
                    (["prepare", "--sha", SOURCE, "--base", BASE, "--directory", str(self.directory)], "prepare", self.metadata),
                    (["finalize", "--directory", str(self.directory), "--app", str(self.app)], "finalize", self.metadata),
                    (["publish", "--sha", SOURCE, "--repository", "owner/repo", "--directory", str(self.directory)], "publish", "owned-url")]
        environment = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_SHA": SOURCE, "GITHUB_REPOSITORY": "owner/repo", "GH_TOKEN": "owned-fixture"}
        for arguments, function, result in commands:
            with self.subTest(command=arguments[0]), patch.object(sys, "argv", ["release.py", *arguments]), \
                    patch.dict(os.environ, environment, clear=True), patch.object(release, function, return_value=result) as routed, \
                    patch.object(sys, "stdout", new_callable=io.StringIO):
                self.assertEqual(release.main(), 0)
                routed.assert_called_once()
        for name in ["GITHUB_ACTIONS", "GITHUB_EVENT_NAME", "GITHUB_REF", "GITHUB_SHA", "GITHUB_REPOSITORY"]:
            with self.subTest(name=name), patch.object(sys, "argv", ["release.py", *commands[-1][0]]), \
                    patch.dict(os.environ, {**environment, name: "wrong"}, clear=True), \
                    patch.object(release, "GitHub") as client, patch.object(sys, "stderr", new_callable=io.StringIO):
                self.assertEqual(release.main(), 1)
                client.assert_not_called()

    def test_real_cli_entrypoint_validates_without_any_external_effects(self):
        with patch.object(sys, "argv", ["release.py", "validate"]), patch.object(sys, "stdout", new_callable=io.StringIO), \
                self.assertRaises(SystemExit) as caught:
            runpy.run_path(str(ROOT / "scripts/release.py"), run_name="__main__")
        self.assertEqual(caught.exception.code, 0)

    def test_cli_refuses_local_publication_before_token_or_network(self):
        environment = dict(os.environ)
        for name in list(environment):
            if name.startswith("GITHUB_") or name == "GH_TOKEN":
                environment.pop(name)
        process = subprocess.run([sys.executable, str(ROOT / "scripts/release.py"), "publish",
                                  "--directory", str(self.directory), "--repository", "owner/repo", "--sha", SOURCE],
                                 env=environment, capture_output=True, text=True)
        self.assertEqual(process.returncode, 1)
        self.assertIn("only allowed", process.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Regression tests for release authorization, exact artifacts and signing checks."""

import hashlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release
import release_android
import release_apple
import release_linux


class ReleasePlanTests(unittest.TestCase):
    def setUp(self):
        self.version = mock.patch.object(release, "versions", return_value=("1.2.3", "42"))
        self.version.start()
        self.addCleanup(self.version.stop)

    def test_main_and_pr_never_publish_or_build_signed_apks(self):
        for event, ref in (("push", "refs/heads/main"), ("pull_request", "refs/pull/1/merge")):
            plan = release.make_plan(event, ref, "", False, False)
            self.assertFalse(plan["publish"])
            self.assertFalse(plan["build_apps"])
        self.assertTrue(plan["build_windows"])

    def test_release_tag_matches_checkout_and_ignores_manual_skip_flags(self):
        plan = release.make_plan("push", "refs/tags/v1.2.3", "", True, True)
        self.assertTrue(plan["publish"])
        self.assertTrue(plan["ios_enabled"])
        self.assertTrue(plan["docker_enabled"])
        self.assertEqual(plan["tag"], "v1.2.3")
        self.assertEqual(plan["build_number"], "42")

    def test_manual_skip_is_explicit_and_empty_tag_is_build_only(self):
        plan = release.make_plan("workflow_dispatch", "refs/heads/main", "", True, True)
        self.assertFalse(plan["publish"])
        self.assertTrue(plan["build_apps"])
        self.assertFalse(plan["ios_enabled"])
        self.assertFalse(plan["docker_enabled"])
        plan = release.make_plan("workflow_dispatch", "refs/heads/main", "v1.2.3", True, True)
        self.assertTrue(plan["publish"])

    def test_invalid_or_mismatched_release_tags_cannot_publish(self):
        for tag in ("v1.2.4", "v01.2.3", "v1.2.3-rc.1", "v1.2.3; echo secret", "v1.2.3\n"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.make_plan("workflow_dispatch", "refs/heads/main", tag, False, False)

    def test_existing_tag_must_point_to_built_commit_including_annotated_tags(self):
        commit = "a" * 40
        ref = "refs/tags/v1.2.3"
        for result in (f"{commit}\t{ref}\n", f"{'b' * 40}\t{ref}\n{commit}\t{ref}^{{}}\n"):
            with mock.patch.object(release.subprocess, "check_output", return_value=result):
                self.assertTrue(release.verify_tag("v1.2.3", commit, allow_missing=True))
        with mock.patch.object(release.subprocess, "check_output", return_value=f"{'b' * 40}\t{ref}\n"):
            with self.assertRaises(ValueError):
                release.verify_tag("v1.2.3", commit, allow_missing=True)

    def test_only_manual_release_can_plan_to_create_a_missing_tag(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            env = {"GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "workflow_dispatch",
                   "MANUAL_TAG": "v1.2.3", "GITHUB_OUTPUT": str(output)}
            missing = subprocess.CalledProcessError(2, "git ls-remote")
            with mock.patch.object(sys, "argv", ["release.py", "plan"]), mock.patch.dict(os.environ, env), \
                    mock.patch("sys.stdout", new_callable=io.StringIO), \
                    mock.patch.object(subprocess, "check_output", side_effect=["a" * 40, missing] * 2):
                release.main()
                self.assertIn("create_tag=true", output.read_text().splitlines())
                os.environ.update(GITHUB_EVENT_NAME="push", GITHUB_REF="refs/tags/v1.2.3")
                with self.assertRaisesRegex(ValueError, "does not exist"):
                    release.main()

    def test_remote_access_failure_is_never_treated_as_a_missing_tag(self):
        failure = subprocess.CalledProcessError(128, "git ls-remote")
        with mock.patch.object(subprocess, "check_output", side_effect=failure), \
                self.assertRaises(subprocess.CalledProcessError):
            release.verify_tag("v1.2.3", "a" * 40, allow_missing=True)

    def test_gate_rejects_every_failure_and_unintended_skip(self):
        passed = {name: {"result": "success"} for name in release.REQUIRED_JOBS}
        passed["build-ios"] = {"result": "success"}
        release.check_gate(passed, True)
        for name in (*release.REQUIRED_JOBS, "build-ios"):
            for result in ("failure", "cancelled", "skipped"):
                invalid = dict(passed, **{name: {"result": result}})
                with self.subTest(name=name, result=result), self.assertRaises(ValueError):
                    release.check_gate(invalid, True)
        release.check_gate(dict(passed, **{"build-ios": {"result": "skipped"}}), False)
        with self.assertRaises(ValueError):
            release.check_gate(passed, False)
        with self.assertRaises(ValueError):
            release.check_gate({}, True)


class AssetTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.destination = self.root / "release"
        self.version = mock.patch.object(release, "versions", return_value=("1.2.3", "42"))
        self.version.start()
        self.addCleanup(self.version.stop)
        for name in release.asset_names(False):
            (self.source / name).write_bytes(("artifact:" + name).encode())

    def stage(self):
        return release.stage_assets(self.source, self.destination, False, "v1.2.3", False, "blueokanna/Segmeris")

    def test_stage_hashes_exact_assets_and_manifest_with_real_build_metadata(self):
        self.stage()
        names = release.validate_staged(self.destination, False)
        self.assertEqual(set(names), set(release.BASE_ASSETS) | {"SHA256SUMS", "release-manifest.json"})
        checksums = (self.destination / "SHA256SUMS").read_text()
        for name in names:
            if name != "SHA256SUMS":
                self.assertIn(f"{release.digest(self.destination / name)}  {name}\n", checksums)
        metadata = json.loads((self.destination / "release-manifest.json").read_text())
        self.assertEqual(metadata["version"], "1.2.3")
        self.assertEqual(metadata["build_number"], 42)
        self.assertIn('<!-- segmeris-release {"version":"1.2.3","build_number":42} -->',
                      (self.destination / "RELEASE_NOTES.md").read_text())

    def test_missing_duplicate_unknown_and_empty_artifacts_are_rejected(self):
        name = release.BASE_ASSETS[0]
        path = self.source / name
        original = path.read_bytes()
        path.unlink()
        with self.assertRaises(ValueError):
            self.stage()
        path.write_bytes(b"")
        with self.assertRaises(ValueError):
            self.stage()
        path.write_bytes(original)
        extra = self.source / "secret.jks"
        extra.write_bytes(b"must not publish")
        with self.assertRaises(ValueError):
            self.stage()
        extra.unlink()
        duplicate = self.source / "duplicate"
        duplicate.mkdir()
        (duplicate / name).write_bytes(original)
        with self.assertRaises(ValueError):
            self.stage()

    def test_tampering_and_wrong_manifest_metadata_cannot_publish(self):
        self.stage()
        asset = self.destination / release.BASE_ASSETS[0]
        original = asset.read_bytes()
        asset.write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            release.validate_staged(self.destination, False)
        asset.write_bytes(original)
        manifest = self.destination / "release-manifest.json"
        payload = json.loads(manifest.read_text())
        payload["version"] = "9.9.9"
        manifest.write_text(json.dumps(payload))
        names = sorted([*release.asset_names(False), "release-manifest.json"])
        (self.destination / "SHA256SUMS").write_text(
            "".join(f"{release.digest(self.destination / name)}  {name}\n" for name in names))
        with self.assertRaises(ValueError):
            release.validate_staged(self.destination, False)

    def test_nonempty_destination_never_gets_overwritten(self):
        self.destination.mkdir()
        protected = self.destination / "existing.txt"
        protected.write_text("keep")
        with self.assertRaises(ValueError):
            self.stage()
        self.assertEqual(protected.read_text(), "keep")

    def test_publication_streams_all_assets_into_draft_then_verifies_before_public(self):
        self.stage()
        calls = []
        def api(method, url, token, body=None, content_type="application/json", content_length=None):
            calls.append((method, url, body))
            if method == "GET":
                raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
            if url.endswith("/releases"):
                self.assertTrue(body["draft"])
                return {"id": 7, "upload_url": "https://uploads.github.com/repos/blueokanna/Segmeris/releases/7/assets{?name,label}"}
            if "uploads.github.com" in url:
                self.assertTrue(hasattr(body, "read"), "Uploads must not load the entire archive into RAM")
                payload = body.read()
                self.assertEqual(content_length, len(payload))
                return {"state": "uploaded", "size": len(payload), "digest": "sha256:" + hashlib.sha256(payload).hexdigest()}
            self.assertEqual(method, "PATCH")
            self.assertFalse(body["draft"])
            return {"draft": False, "html_url": "https://github.com/blueokanna/Segmeris/releases/tag/v1.2.3"}
        with mock.patch.dict(os.environ, {"GH_TOKEN": "test-token"}), mock.patch.object(release, "api", side_effect=api), mock.patch.object(release, "verify_tag") as verify:
            release.publish(self.destination, "v1.2.3", "a" * 40, "blueokanna/Segmeris", False)
        self.assertEqual(verify.call_count, 2)
        self.assertEqual(calls[-1][0], "PATCH")
        self.assertEqual(len([entry for entry in calls if "uploads.github.com" in entry[1]]), len(release.BASE_ASSETS) + 2)

    def test_failed_upload_never_publishes_partial_release(self):
        self.stage()
        calls = []
        def api(method, url, token, body=None, *args):
            calls.append(method)
            if method == "GET":
                raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
            if url.endswith("/releases"):
                return {"id": 7, "upload_url": "https://uploads.github.com/repos/blueokanna/Segmeris/releases/7/assets{?name,label}"}
            return {"state": "uploaded", "size": -1}
        with mock.patch.dict(os.environ, {"GH_TOKEN": "test-token"}), mock.patch.object(release, "api", side_effect=api), mock.patch.object(release, "verify_tag"):
            with self.assertRaises(ValueError):
                release.publish(self.destination, "v1.2.3", "a" * 40, "blueokanna/Segmeris", False)
        self.assertNotIn("PATCH", calls)


class SigningAndBinaryTests(unittest.TestCase):
    def test_java_properties_preserve_secrets_without_line_injection(self):
        escaped = release_android.java_property(" a=b:c\\d\n雪🚀")
        self.assertEqual(escaped, r"\ a\=b\:c\\d\n\u96ea\ud83d\ude80")
        self.assertNotIn("\n", escaped)

    def test_missing_or_invalid_keystore_never_configures_debug_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                release_android.configure(root, {})
            with self.assertRaises(ValueError):
                release_android.configure(root, {name: "!!!" for name in release_android.SECRET_NAMES})
            self.assertFalse((root / "android/key.properties").exists())

    def test_apk_identity_version_build_and_debuggable_flag_are_checked(self):
        valid = "package: name='com.blue.segmeris' versionCode='42' versionName='1.2.3'\n"
        release_android.verify_metadata(valid, "1.2.3", "42")
        for document in (valid.replace("1.2.3", "1.0.8"), valid.replace("42", "1"), valid.replace("com.blue.segmeris", "evil.app"), valid + "application-debuggable\n"):
            with self.assertRaises(ValueError):
                release_android.verify_metadata(document, "1.2.3", "42")

    def test_signing_certificate_must_match_and_never_be_android_debug(self):
        fingerprint = "a" * 64
        report = f"Signer #1 certificate SHA-256 digest: {fingerprint}\nSigner #1 certificate DN: CN=Segmeris\n"
        release_android.verify_signer(report, fingerprint)
        for value in (report.replace(fingerprint, "b" * 64), report.replace("CN=Segmeris", "CN=Android Debug"), report + f"Signer #2 certificate SHA-256 digest: {'b' * 64}\n"):
            with self.assertRaises(ValueError):
                release_android.verify_signer(value, fingerprint)

    def test_build_tools_37_signers_and_source_stamps(self):
        release_cert, other = "ab" * 32, "cd" * 32
        stamp = f"Source Stamp Signer: certificate SHA-256 digest: {other}\n"
        for label in ("V1 Signer:", "V2 Signer:", "V2 Signer #1:", "V3.0 Signer:",
                      "V3.1 Signer: (minSdkVersion=33, maxSdkVersion=2147483647)",
                      "V3.2 Hybrid Classical Signer: (minSdkVersion=37 (dev release=true), maxSdkVersion=2147483647)",
                      "V3.2 Hybrid PQC Signer: (minSdkVersion=37, maxSdkVersion=2147483647)"):
            with self.subTest(label=label):
                release_android.verify_signer(f"{label} certificate SHA-256 digest: {release_cert}\n" + stamp,
                                              release_cert)
        signer = f"V2 Signer #1: certificate SHA-256 digest: {release_cert}\n"
        for invalid in (stamp, signer.replace(release_cert, other) + stamp.replace(other, release_cert),
                        signer + f"V2 Signer #2: certificate SHA-256 digest: {other}",
                        signer + f"Unknown Signer: certificate SHA-256 digest: {release_cert}",
                        signer.replace("certificate SHA-256", "public key SHA-256")):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                release_android.verify_signer(invalid, release_cert)

    def test_linux_unresolved_dependencies_fail(self):
        parsed = release_linux.parse_ldd("libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x123)\n/lib64/ld-linux-x86-64.so.2 (0x456)")
        self.assertEqual(len(parsed), 2)
        with self.assertRaises(ValueError):
            release_linux.parse_ldd("libsecret.so => not found")

    def test_apple_unsigned_archive_requires_payload_and_explicit_notice(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "app.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Segmeris.app/Info.plist", "plist")
                archive.writestr("UNSIGNED-README.txt", "Signing is required")
            release_apple.verify_ipa(path)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Runner.app/Info.plist", "plist")
            with self.assertRaises(ValueError):
                release_apple.verify_ipa(path)

    def test_authenticated_publication_rejects_redirects_and_non_github_hosts(self):
        for url in ("http://api.github.com/repos/example", "https://github.com.evil.test/api", "https://token@api.github.com/repos/example", "https://api.github.com:444/repos/example"):
            with self.assertRaises(ValueError):
                release.api("GET", url, "must-not-be-sent")
        with self.assertRaises(ValueError):
            release.NoRedirect().redirect_request(None, None, 302, "Moved", {}, "https://evil.test")


if __name__ == "__main__":
    unittest.main()

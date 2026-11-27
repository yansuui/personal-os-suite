"""Isolated tests of snapshot integrity and the native-build driver, not XCTest."""
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import ios_source as tool


class IOSSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / "repo"
        for name in tool.FILES:
            self.put(name, "fixture\n")
        self.put("apps/iphone/Config/Release.xcconfig", "BUNDLE_ID = com.personalos.ios\n")
        self.put("apps/iphone/Sources/POSCore/Value.swift", "struct Value {}\n")
        self.put("apps/iphone/Tests/POSCoreTests/ValueTests.swift", "import XCTest\n")
        self.put("apps/iphone/Resources/Assets.xcassets/Contents.json", "{}\n")

    def put(self, name, text):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return target

    def snapshot(self):
        output = self.directory / "source.zip"
        packed = tool.pack(self.root, output)
        extracted = self.directory / "extracted"
        with zipfile.ZipFile(output) as archive:
            archive.extractall(extracted)
        return packed, extracted

    def test_pack_round_trip_includes_uncommitted_inputs_and_excludes_runtime_data(self):
        self.put("apps/iphone/Sources/POSFeatures/Uncommitted.swift", "struct NewSource {}\n")
        self.put("apps/iphone/Sources/POSApp/Info.plist", "generated plist\n")
        for name in (".env", "apps/cloud/data/private.sqlite", "apps/iphone/build/old.ipa", "apps/iphone/.cache/token"):
            self.put(name, "private runtime fixture\n")
        packed, extracted = self.snapshot()
        checked = tool.check(extracted)
        self.assertEqual(packed["sourceHash"], checked["sourceHash"])
        self.assertTrue((extracted / "apps/iphone/Sources/POSFeatures/Uncommitted.swift").is_file())
        self.assertFalse((extracted / "apps/cloud").exists())
        self.assertFalse((extracted / "apps/iphone/Sources/POSApp/Info.plist").exists())
        self.assertFalse((extracted / ".env").exists())

    def test_source_hash_is_stable_and_sensitive_to_exact_bytes(self):
        original = tool.source_hash(tool.records(tool.collect(self.root)))
        self.assertEqual(original, tool.source_hash(tool.records(tool.collect(self.root))))
        self.put("apps/iphone/Sources/POSCore/Value.swift", "struct Changed {}\r\n")
        self.assertNotEqual(original, tool.source_hash(tool.records(tool.collect(self.root))))

    def test_check_rejects_changed_missing_or_added_build_inputs(self):
        _, extracted = self.snapshot()
        source = extracted / "apps/iphone/Sources/POSCore/Value.swift"
        original = source.read_bytes()
        source.write_bytes(b"changed\n")
        with self.assertRaisesRegex(ValueError, "source differs"):
            tool.check(extracted)
        source.unlink()
        with self.assertRaisesRegex(ValueError, "source differs"):
            tool.check(extracted)
        source.write_bytes(original)
        added = extracted / "apps/iphone/Sources/POSCore/Extra.swift"
        added.write_bytes(b"extra\n")
        with self.assertRaisesRegex(ValueError, "source differs"):
            tool.check(extracted)

    def test_check_rejects_manifest_traversal_and_duplicates(self):
        _, extracted = self.snapshot()
        target = extracted / tool.MANIFEST
        manifest = json.loads(target.read_text(encoding="utf-8"))
        original = list(manifest["files"])
        manifest["files"] = [{"path": "../outside", "size": 0, "sha256": tool.digest(b"")}]
        manifest["sourceHash"] = tool.source_hash(manifest["files"])
        target.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "invalid source path"):
            tool.check(extracted)
        manifest["files"] = sorted(original + [original[0]], key=lambda item: item["path"])
        manifest["sourceHash"] = tool.source_hash(manifest["files"])
        target.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "inconsistent"):
            tool.check(extracted)

    def test_check_rejects_non_object_manifests_cleanly(self):
        _, extracted = self.snapshot()
        (extracted / tool.MANIFEST).write_text("[]", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "invalid source manifest"):
            tool.check(extracted)

    def test_safe_path_rejects_resolved_directory_escape(self):
        # Models a Windows junction/reparse point even when is_symlink is false.
        with patch.object(Path, "resolve", return_value=self.directory / "outside"):
            with self.assertRaisesRegex(ValueError, "outside source root"):
                tool.safe_path(self.root, "apps/iphone/Sources")

    def test_pack_refuses_existing_outputs_and_unknown_source_types(self):
        output = self.directory / "exists.zip"
        output.write_bytes(b"preserve me")
        with self.assertRaisesRegex(ValueError, "already exists"):
            tool.pack(self.root, output)
        self.assertEqual(output.read_bytes(), b"preserve me")
        self.put("apps/iphone/Config/private.env", "not a build setting\n")
        with self.assertRaisesRegex(ValueError, "unexpected build input"):
            tool.pack(self.root, self.directory / "rejected.zip")
        self.assertFalse((self.directory / "rejected.zip").exists())

    def test_pack_rejects_symlinked_source_without_reading_target(self):
        outside = self.directory / "outside.swift"
        outside.write_text("outside\n", encoding="utf-8")
        link = self.root / "apps/iphone/Sources/POSCore/Link.swift"
        try:
            link.symlink_to(outside)
        except OSError as error:
            self.skipTest("OS does not permit symlink creation: " + str(error))
        with self.assertRaisesRegex(ValueError, "symlink"):
            tool.collect(self.root)

    def test_pack_detects_source_changes_before_writing_an_archive(self):
        inputs = tool.collect(self.root)
        changed = dict(inputs)
        changed["apps/iphone/project.yml"] += b"changed"
        output = self.directory / "race.zip"
        with patch.object(tool, "collect", side_effect=[inputs, changed]):
            with self.assertRaisesRegex(ValueError, "source changed"):
                tool.pack(self.root, output)
        self.assertFalse(output.exists())

    def test_native_command_refuses_non_macos_before_creating_output(self):
        output = self.directory / "native"
        with patch.object(sys, "platform", "win32"):
            with self.assertRaisesRegex(ValueError, "requires macOS"):
                tool.validate_macos(self.root, output, "platform=iOS Simulator,id=fixture")
        self.assertFalse(output.exists())

    def native_mocks(self):
        return patch.object(sys, "platform", "darwin"), patch.object(tool.shutil, "which", side_effect=lambda name: "/tools/" + name)

    def test_failed_native_tests_stop_before_release_and_leave_failed_receipt(self):
        _, extracted = self.snapshot()
        output = self.directory / "native"
        platform, tools = self.native_mocks()
        commands = []

        def execute(command, **kwargs):
            commands.append(command)
            return subprocess.CompletedProcess(command, 65 if "test" in command else 0)

        with platform, tools, patch.object(tool.subprocess, "run", side_effect=execute):
            with self.assertRaisesRegex(ValueError, "test failed"):
                tool.validate_macos(extracted, output, "platform=iOS Simulator,id=fixture")
        result = json.loads((output / "validation-result.json").read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "FAILED")
        self.assertEqual(result["steps"][-1]["exitCode"], 65)
        self.assertIn("test failed", result["error"])
        self.assertFalse(any("-sdk" in command for command in commands))
        self.assertFalse((output / "POSApp-unsigned.ipa").exists())

    def test_success_driver_stages_source_and_binds_ipa_to_hash_using_fake_tools(self):
        packed, extracted = self.snapshot()
        output = self.directory / "native"
        platform, tools = self.native_mocks()

        def execute(command, **kwargs):
            if "-sdk" in command:
                app = output / "release-derived/Build/Products/Release-iphoneos/POSApp.app"
                app.mkdir(parents=True)
                (app / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": "com.personalos.ios", "CFBundleExecutable": "POSApp",
                    "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "4"}))
                (app / "POSApp").write_bytes(b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01" + b"\0" * 24)
                for name in ("POSCore", "POSFeatures"):
                    binary = app / ("Frameworks/{0}.framework/{0}".format(name))
                    binary.parent.mkdir(parents=True)
                    binary.write_bytes(b"framework fixture")
            return subprocess.CompletedProcess(command, 0)

        with platform, tools, patch.object(tool.subprocess, "run", side_effect=execute):
            result = tool.validate_macos(extracted, output, "platform=iOS Simulator,id=fixture")
        self.assertEqual(result["status"], "BUILT_NOT_INSTALLED")
        self.assertEqual(result["sourceHash"], packed["sourceHash"])
        self.assertEqual(result["ipa"]["build"], "4")
        self.assertTrue((output / "POSApp-unsigned.ipa").is_file())
        self.assertEqual(tool.check(extracted)["sourceHash"], packed["sourceHash"])
        release = result["steps"][-1]["command"]
        self.assertIn("CODE_SIGNING_ALLOWED=NO", release)
        self.assertIn("CODE_SIGNING_REQUIRED=NO", release)

    def test_ipa_inspection_rejects_text_in_place_of_a_device_executable(self):
        ipa = self.directory / "invalid.ipa"
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("Payload/POSApp.app/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "com.personalos.ios", "CFBundleExecutable": "POSApp"}))
            archive.writestr("Payload/POSApp.app/POSApp", b"not an executable")
        with self.assertRaisesRegex(ValueError, "Mach-O"):
            tool.inspect_ipa(ipa)


if __name__ == "__main__":
    unittest.main()

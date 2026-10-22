import importlib.util
import io
import json
import plistlib
import struct
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("handtodo_package", Path(__file__).resolve().parents[1] / "package.py")
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)

class PackagingTests(unittest.TestCase):
    def test_macos_icon_requires_bundle_configuration_and_exact_asset(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            app = root / "HandTodo.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            expected = root / "expected.icns"
            expected.write_bytes(b"icns-confirmed-hi-logo")
            info = app / "Contents/Info.plist"
            info.write_bytes(plistlib.dumps({}))
            (resources / "HandTodo.icns").write_bytes(expected.read_bytes())
            with self.assertRaises(pkg.PackageError):
                pkg.verify_macos_icon(app, expected)
            info.write_bytes(plistlib.dumps({"CFBundleIconFile": "HandTodo"}))
            self.assertEqual(pkg.verify_macos_icon(app, expected)["status"], "passed")
            (resources / "HandTodo.icns").write_bytes(b"old icon")
            with self.assertRaises(pkg.PackageError):
                pkg.verify_macos_icon(app, expected)

    @staticmethod
    def icon_pe_fixture():
        # A minimal PE32+ file with one native RT_ICON and RT_GROUP_ICON.
        # The icon also occurs outside .rsrc, so matching arbitrary file bytes is insufficient.
        payload = b"fixture image payload"
        header = struct.pack("<HHH", 0, 1, 1)
        entry = struct.pack("<BBBBHHI", 32, 32, 0, 0, 1, 32, len(payload))
        ico = header + entry + struct.pack("<I", 22) + payload
        group = header + entry + struct.pack("<H", 1)
        data = bytearray(0x700)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 0x3c, 0x80)
        data[0x80:0x84] = b"PE\0\0"
        struct.pack_into("<H", data, 0x86, 1)
        struct.pack_into("<H", data, 0x94, 0xf0)
        struct.pack_into("<H", data, 0x98, 0x20b)
        struct.pack_into("<II", data, 0x118, 0x1000, 0x400)
        struct.pack_into("<IIII", data, 0x190, 0x400, 0x1000, 0x400, 0x200)
        def directory(relative, entries):
            start = 0x200+relative
            struct.pack_into("<HH", data, start+12, 0, len(entries))
            for i, (key, child) in enumerate(entries):
                struct.pack_into("<II", data, start+16+8*i, key, child)
        directory(0, [(3, 0x80000020), (14, 0x80000038)])
        directory(32, [(1, 0x80000050)])
        directory(56, [(32512, 0x80000068)])
        directory(80, [(0, 128)])
        directory(104, [(0, 144)])
        struct.pack_into("<IIII", data, 0x280, 0x10a0, len(payload), 0, 0)
        struct.pack_into("<IIII", data, 0x290, 0x1100, len(group), 0, 0)
        data[0x2a0:0x2a0+len(payload)] = payload
        data[0x300:0x300+len(group)] = group
        data[0x600:0x600+len(ico)] = ico
        return data, ico

    def test_windows_icon_checks_native_resource_payload(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            data, ico = self.icon_pe_fixture()
            exe, icon = root / "HandTodo.exe", root / "HandTodo.ico"
            exe.write_bytes(data)
            icon.write_bytes(ico)
            self.assertEqual(pkg.verify_windows_icon(exe, icon)["sizes"], [32])
            data[0x2a0] ^= 1
            exe.write_bytes(data)
            with self.assertRaises(pkg.PackageError):
                pkg.verify_windows_icon(exe, icon)

    def test_windows_icon_rejects_asset_without_native_icon_registration(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            data, ico = self.icon_pe_fixture()
            # Only register a different resource type. The complete ICO remains in the file.
            struct.pack_into("<I", data, 0x210, 10)
            exe, icon = root / "HandTodo.exe", root / "HandTodo.ico"
            exe.write_bytes(data)
            icon.write_bytes(ico)
            with self.assertRaises(pkg.PackageError):
                pkg.verify_windows_icon(exe, icon)

    def test_finder_metadata_does_not_change_source_fingerprint(self):
        with tempfile.TemporaryDirectory() as d, patch.object(pkg, "ROOT", Path(d)):
            root = Path(d)
            resources = root / "Resources"
            (resources / "Brand").mkdir(parents=True)
            asset = resources / "hand.png"
            asset.write_bytes(b"original asset")
            original = pkg.source_fingerprint()
            (resources / ".DS_Store").write_bytes(b"Finder state")
            nested = resources / "Brand/.DS_Store"
            nested.write_bytes(b"folder layout")
            self.assertEqual(pkg.source_fingerprint(), original)
            nested.write_bytes(b"updated folder layout")
            self.assertEqual(pkg.source_fingerprint(), original)
            asset.write_bytes(b"changed asset")
            self.assertNotEqual(pkg.source_fingerprint(), original)

    def test_unrelated_documents_do_not_mark_build_sources_dirty(self):
        def git(*args, **kwargs):
            if args[0] == "status":
                return "" if "--" in args else "?? personal-notes/"
            return "main" if args[0:2] == ("rev-parse", "--abbrev-ref") else "abc"
        with patch.object(pkg, "git", git):
            source = pkg.source_info()
            self.assertFalse(source["dirty"])
            self.assertTrue(source["other_changes_present"])

    def test_bad_version_rejected_before_running_tools(self):
        for version in ["../escape", "0.2", "0.2.0;bad", "0.2.0\n"]:
            with self.assertRaises(pkg.PackageError):
                pkg.version_value(version)

    def test_report_requires_pass_and_does_not_extract_paths(self):
        def archive(result):
            data = io.BytesIO()
            with zipfile.ZipFile(data, "w") as z:
                z.writestr("result.txt", result)
                z.writestr("../../not-extracted.txt", "not allowed")
            return data.getvalue()
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "report"
            pkg.check_windows_report(archive("PASS: native tests"), out)
            self.assertEqual([p.name for p in out.iterdir()], ["result.txt"])
            with self.assertRaises(pkg.PackageError):
                pkg.check_windows_report(archive("FAILED"), out)

    def test_failed_run_preserves_previous_latest_and_manifest(self):
        with tempfile.TemporaryDirectory() as d, patch.object(pkg, "ROOT", Path(d)):
            root = Path(d)
            (root / "VERSION").write_text("0.2.0")
            output = root / "Distribution/output"
            output.mkdir(parents=True)
            pointer = output / "latest.json"
            pointer.write_text('{"output":"previous-success"}')
            with patch.object(pkg, "source_info", return_value={"commit": "abc", "dirty": False}), patch.object(pkg.Pipeline, "preflight", return_value={}), patch.object(pkg.Pipeline, "macos", side_effect=pkg.PackageError("build failed")):
                pipeline = pkg.Pipeline(pkg.parser().parse_args(["macos"]))
                with self.assertRaises(pkg.PackageError):
                    pipeline.execute()
                self.assertEqual(json.loads(pointer.read_text())["output"], "previous-success")
                self.assertEqual(json.loads((pipeline.output / "manifest.json").read_text())["status"], "failed")

    def test_source_change_prevents_marking_run_complete(self):
        with tempfile.TemporaryDirectory() as d, patch.object(pkg, "ROOT", Path(d)):
            root = Path(d)
            (root / "VERSION").write_text("0.2.0")
            def mutate(pipeline):
                (root / "VERSION").write_text("0.2.1")
            with patch.object(pkg, "source_info", return_value={"commit": "abc", "dirty": False}), patch.object(pkg.Pipeline, "preflight", return_value={}), patch.object(pkg.Pipeline, "macos", mutate):
                pipeline = pkg.Pipeline(pkg.parser().parse_args(["macos"]))
                with self.assertRaises(pkg.PackageError):
                    pipeline.execute()
                self.assertFalse((root / "Distribution/output/latest.json").exists())

    def test_success_and_explicit_unverified_status_are_distinct(self):
        for verification, status in [("passed", "completed"), ("not-run", "completed-unverified")]:
            with tempfile.TemporaryDirectory() as d, patch.object(pkg, "ROOT", Path(d)):
                root = Path(d)
                (root / "VERSION").write_text("0.2.0")
                def fake_build(pipeline):
                    artifact = pipeline.output / "test.zip"
                    artifact.write_bytes(b"fixture")
                    pipeline.add_artifact("windows", artifact)
                    pipeline.manifest["verification"]["windows"] = {"status": verification}
                with patch.object(pkg, "source_info", return_value={"commit": "abc", "dirty": False}), patch.object(pkg.Pipeline, "preflight", return_value={}), patch.object(pkg.Pipeline, "windows", fake_build):
                    pipeline = pkg.Pipeline(pkg.parser().parse_args(["windows"]))
                    pipeline.execute()
                    manifest = json.loads((pipeline.output / "manifest.json").read_text())
                    self.assertEqual(manifest["status"], status)
                    self.assertEqual(manifest["artifacts"][0]["sha256"], pkg.digest(pipeline.output / "test.zip"))

if __name__ == "__main__":
    unittest.main()

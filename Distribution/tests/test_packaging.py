import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("handtodo_package", Path(__file__).resolve().parents[1] / "package.py")
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)

class PackagingTests(unittest.TestCase):
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

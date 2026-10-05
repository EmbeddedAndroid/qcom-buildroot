import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SourceSelection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.target = self.workspace / "linux"
        self.bundles = self.root / "bundles"
        self.bundles.mkdir()
        self.git(self.root, "init", "-q", str(self.source))
        self.git(self.source, "config", "user.name", "Test")
        self.git(self.source, "config", "user.email", "test@example.invalid")
        (self.source / "file").write_text("base\n")
        self.git(self.source, "add", "file")
        self.git(self.source, "commit", "-qm", "base")
        self.base = self.git(self.source, "rev-parse", "HEAD")
        self.git(self.root, "clone", "-q", str(self.source), str(self.target))
        self.git(self.source, "checkout", "-qb", "integration-20261005-sr")
        (self.source / "file").write_text("fixed\n")
        self.git(self.source, "commit", "-qam", "fix")
        self.tip = self.git(self.source, "rev-parse", "HEAD")
        self.git(self.source, "bundle", "create",
                 str(self.bundles / "linux-test.bundle"),
                 "integration-20261005-sr", "^" + self.base)
        shutil.copyfile(Path(__file__).with_name("prepare.py"),
                        self.root / "prepare.py")

    @staticmethod
    def git(repo, *args):
        return subprocess.check_output(["git", "-C", str(repo), *args],
                                       text=True).strip()

    def run_prepare(self, revision):
        pins = {"test": {"linux": {"source": "linux-test",
                                    "revision": revision}}}
        (self.root / "sources.json").write_text(json.dumps(pins))
        return subprocess.run(["python3", str(self.root / "prepare.py"),
                               "test", str(self.workspace), str(self.bundles)],
                              capture_output=True, text=True)

    def test_selects_exact_source(self):
        result = self.run_prepare(self.tip)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.tip)
        self.assertEqual((self.target / "file").read_text(), "fixed\n")

    def test_rejects_wrong_revision_without_checkout(self):
        result = self.run_prepare("0" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundle revision mismatch", result.stderr)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.base)

    def test_rejects_missing_bundle(self):
        (self.bundles / "linux-test.bundle").unlink()
        result = self.run_prepare(self.tip)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.base)


if __name__ == "__main__":
    unittest.main()

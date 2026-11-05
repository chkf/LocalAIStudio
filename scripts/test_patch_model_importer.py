import hashlib
from pathlib import Path
import tempfile
import stat
import unittest
from unittest.mock import patch

import patch_model_importer as importer


class ModelImporterPatchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.checkouts = Path(self.directory.name)
        self.source = self.checkouts / "draw-things-community" / importer.SOURCE
        self.source.parent.mkdir(parents=True)
        self.original = b"func importWeights() throws {\n  " + importer.BEFORE + b"\n}\n"
        self.expected = self.original.replace(importer.BEFORE, importer.AFTER)
        self.source.write_bytes(self.original)
        for name, value in [
            ("ORIGINAL_SHA256", hashlib.sha256(self.original).hexdigest()),
            ("PATCHED_SHA256", hashlib.sha256(self.expected).hexdigest()),
        ]:
            handle = patch.object(importer, name, value)
            handle.start()
            self.addCleanup(handle.stop)
        self.git = patch.object(importer.subprocess, "check_output", return_value=importer.REVISION + "\n")
        self.git_output = self.git.start()
        self.addCleanup(self.git.stop)

    def test_patches_only_reader_and_is_idempotent(self):
        self.assertTrue(importer.patch_importer(self.checkouts))
        self.assertEqual(self.source.read_bytes(), self.expected)
        self.assertFalse(importer.patch_importer(self.checkouts))
        self.assertEqual(self.source.read_bytes(), self.expected)

    def test_unknown_revision_leaves_source_intact(self):
        self.git_output.return_value = "different-revision\n"
        with self.assertRaisesRegex(ValueError, "revision changed"):
            importer.patch_importer(self.checkouts)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_read_only_swiftpm_source_is_patched_and_permissions_restored(self):
        self.source.chmod(0o444)
        self.assertTrue(importer.patch_importer(self.checkouts))
        self.assertEqual(self.source.read_bytes(), self.expected)
        self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), 0o444)
        self.assertFalse(importer.patch_importer(self.checkouts))
        self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), 0o444)

    def test_unknown_source_leaves_source_intact(self):
        edited = self.original + b"// unreviewed edit\n"
        self.source.write_bytes(edited)
        with self.assertRaisesRegex(ValueError, "source changed"):
            importer.patch_importer(self.checkouts)
        self.assertEqual(self.source.read_bytes(), edited)

    def test_unexpected_result_leaves_source_intact(self):
        with patch.object(importer, "PATCHED_SHA256", "invalid"):
            with self.assertRaisesRegex(ValueError, "checksum"):
                importer.patch_importer(self.checkouts)
        self.assertEqual(self.source.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()

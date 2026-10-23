#!/usr/bin/env python3
"""Real Foundation file-presenter regressions; no app, simulator or GUI required."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class LocalImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="margined-image-regression-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.runner = Path(cls.temp.name) / "local-images"
        command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                   str(ROOT / "Shared/MarkdownSource.swift"), str(ROOT / "Shared/LocalImageData.swift"),
                   str(ROOT / "script/tests/LocalImageDataProbe.swift"), "-o", str(cls.runner)]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    def check(self, case):
        result = subprocess.run([str(self.runner), case], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_image_read_waits_for_presenter_contents(self): self.check("coordination")
    def test_oversized_image_is_rejected(self): self.check("bounded")
    def test_directory_is_rejected(self): self.check("directory")
    def test_cancelled_image_request_is_not_read(self): self.check("cancelled")

if __name__ == "__main__": unittest.main(verbosity=2)

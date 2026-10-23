#!/usr/bin/env python3
"""CPU-only Apex regression; first build optimized products per Benchmarks/README.md."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from html.parser import HTMLParser

ROOT = Path(__file__).resolve().parents[2]
PRODUCTS = Path(os.environ.get("MARGINED_BENCHMARK_PRODUCTS", "/tmp/Margined-benchmarks/Build/Products/Release"))

class Tables(HTMLParser):
    def __init__(self, html):
        super().__init__(); self.tags = []; self.feed(html)
    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))

class ApexTableTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="margined-table-regression-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.runner = Path(cls.temp.name) / "table-convert"
        vendor = ROOT / "Vendor/Apex"
        objects = [PRODUCTS / (name + ".o") for name in ("ApexC", "CcmarkGFM", "CcmarkGFMExtensions", "CcmarkGFMSupport", "CYaml")]
        if not all(path.is_file() for path in objects):
            raise RuntimeError("Build optimized Margined products first; see Benchmarks/README.md")
        command = ["xcrun", "clang", "-O2", "-I", str(vendor / "include"), "-I", str(vendor / "vendor/cmark-gfm/src"),
                   "-I", str(vendor / "PackageSupport/cmark-gfm"), str(ROOT / "Benchmarks/Support/table-convert.c"),
                   *map(str, objects), "-o", str(cls.runner)]
        subprocess.run(command, check=True, capture_output=True)

    def convert(self, markdown, timeout=2):
        try:
            result = subprocess.run([str(self.runner)], input=markdown, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            self.fail("A 240-row table exceeded the generous 2-second conversion guard")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    @staticmethod
    def ordinary(rows=240):
        return "| Task | Owner | Status | Notes |\n| --- | --- | --- | --- |\n" + "".join(
            f"| Task {i} | Reader | Ready | Verify a rendered table with ordinary wrapping content. |\n" for i in range(rows))

    def test_ordinary_tables_do_not_pay_for_rowspan_lookback(self):
        html = self.convert(self.ordinary())
        self.assertEqual(sum(tag == "tr" for tag, _ in Tables(html).tags), 241)
        self.assertIn("Task 239", html)

    def test_separate_rowspan_table_does_not_slow_plain_table(self):
        html = self.convert(self.ordinary() + "\n\n| Item | Count |\n| --- | --- |\n| Alpha | 1 |\n| ^^ | 2 |\n")
        self.assertTrue(any(attrs.get("rowspan") == "2" for _, attrs in Tables(html).tags))
        self.assertIn("Task 239", html)
        self.assertIn("Alpha", html)

    def test_caption_and_column_span_are_preserved(self):
        html = self.convert("| Item | Count |\n| --- | --- |\n| Alpha | << |\n\n[Inventory]\n")
        tags = Tables(html).tags
        self.assertTrue(any(attrs.get("colspan") == "2" for _, attrs in tags))
        self.assertTrue(any(tag == "figcaption" for tag, _ in tags))
        self.assertIn("Inventory", html)
        self.assertIn("Alpha", html)

if __name__ == "__main__":
    unittest.main(verbosity=2)

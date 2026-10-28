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
        if supplied := os.environ.get("MARGINED_TABLE_RUNNER"):
            cls.runner = Path(supplied)
            if not cls.runner.is_file():
                raise RuntimeError("MARGINED_TABLE_RUNNER must name a compiled regression caller")
            return
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

    def test_row_headers_and_column_alignment_are_preserved(self):
        html = self.convert("| | Left | Right |\n| --- | :--- | ---: |\n| Row A | One | Two |\n| Row B | Three | Four |\n")
        tags = Tables(html).tags
        self.assertTrue(any(tag == "th" and attrs.get("scope") == "row" for tag, attrs in tags))
        self.assertTrue(any(attrs.get("align") == "right" or "right" in attrs.get("style", "") for _, attrs in tags))
        self.assertIn("Row B", html)

    def test_footer_after_removed_separator_preserves_body_and_footer(self):
        html = self.convert("| Item | Count |\n| --- | --- |\n| Alpha | 1 |\n| Beta | 2 |\n| === | === |\n| Total | 3 |\n")
        self.assertTrue(any(tag == "tfoot" for tag, _ in Tables(html).tags))
        self.assertIn("Alpha", html)
        self.assertIn("Beta", html)
        self.assertIn("Total", html)

    def test_raw_span_text_and_unicode_are_not_removed(self):
        html = self.convert("| Item | Notes |\n| --- | --- |\n| 日本語 | raw << |\n| Café | `<<` and **text** |\n")
        self.assertEqual(sum(tag == "td" for tag, _ in Tables(html).tags), 4)
        self.assertIn("日本語", html)
        self.assertIn("raw &lt;&lt;", html)

    def test_code_and_escaped_span_markers_stay_literal(self):
        html = self.convert("| Item | Notes |\n| --- | --- |\n| Code | `<<` |\n| Escape | \\<< |\n")
        self.assertEqual(sum(tag == "td" for tag, _ in Tables(html).tags), 4)
        self.assertIn("<code>&lt;&lt;</code>", html)
        self.assertIn("Escape", html)

if __name__ == "__main__":
    unittest.main(verbosity=2)

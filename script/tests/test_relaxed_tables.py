#!/usr/bin/env python3
"""Exercise the real relaxed-table preprocessor without launching an app."""
import ctypes
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
MARKER = "<!--apex-relaxed-table-->"


class RelaxedTableTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="margined-relaxed-tables-")
        cls.addClassCleanup(cls.temp.cleanup)
        library = Path(cls.temp.name) / "relaxed-tables.dylib"
        subprocess.run(["xcrun", "clang", "-O2", "-dynamiclib",
                        str(ROOT / "Vendor/Apex/src/extensions/relaxed_tables.c"),
                        "-o", str(library)], check=True, capture_output=True)
        cls.library = ctypes.CDLL(str(library))
        cls.libc = ctypes.CDLL(None)
        cls.libc.free.argtypes = [ctypes.c_void_p]
        cls.libc.free.restype = None
        for name in ("apex_process_relaxed_tables", "apex_process_headerless_tables"):
            function = getattr(cls.library, name)
            function.argtypes = [ctypes.c_char_p]
            function.restype = ctypes.c_void_p

    def preprocess(self, source, headerless=False):
        function = (self.library.apex_process_headerless_tables if headerless
                    else self.library.apex_process_relaxed_tables)
        pointer = function(source.encode("utf-8"))
        if not pointer:
            return source
        try:
            return ctypes.string_at(pointer).decode("utf-8")
        finally:
            self.libc.free(pointer)

    def test_adjacent_pipeline_tasks_are_byte_identical(self):
        for source in ["- [ ] One `echo a | cat`.\n- [x] Two `echo b | cat`.\n",
                       "# Café 日本語\n\n- [ ] One `echo a | cat`.\n\n- [x] Two `echo b | cat`.\n"]:
            with self.subTest(source=source):
                self.assertEqual(self.preprocess(source), source)

    def test_exact_backtick_runs_can_contain_other_runs(self):
        for code in ["`a | b`", "``a ` | b``", "```a `` | b```", "``a \\` | b``"]:
            source = f"- [ ] One {code}.\n- [ ] Two {code}.\n"
            with self.subTest(code=code):
                self.assertEqual(self.preprocess(source), source)

    def test_escaped_pipes_are_not_cell_delimiters(self):
        for cell in [r"a \| b", r"a \\\| b"]:
            source = f"{cell}\n{cell}\n"
            with self.subTest(cell=cell):
                self.assertEqual(self.preprocess(source), source)

    def test_even_backslashes_leave_a_real_delimiter(self):
        self.assertIn(MARKER, self.preprocess("a \\\\| b\nc \\\\| d\n"))

    def test_unmatched_and_escaped_backticks_do_not_hide_delimiters(self):
        for row in ["a `literal | b", "a ``literal ` | b", r"a \`literal | b\`"]:
            with self.subTest(row=row):
                self.assertIn(MARKER, self.preprocess(f"{row}\n{row}\n"))

    def test_genuine_relaxed_tables_keep_their_column_structure(self):
        for source in ["A | B\n1 | 2\n", "| A | B |\n| 1 | 2 |\n"]:
            with self.subTest(source=source):
                result = self.preprocess(source)
                self.assertEqual(result.count(MARKER), 1)
                self.assertIn(source.splitlines()[0], result)
                self.assertIn(source.splitlines()[1], result)

    def test_explicit_tables_fences_and_wiki_links_stay_unchanged(self):
        for source in ["| A | B |\n| --- | --- |\n| 1 | 2 |\n",
                       "```sh\necho a | cat\necho b | cat\n```\n",
                       "[[one|label]]\n[[two|label]]\n"]:
            with self.subTest(source=source):
                self.assertEqual(self.preprocess(source), source)

    def test_headerless_table_after_pipeline_prose_gets_a_header(self):
        source = "A `command | output`\n| --- | --- |\n| One | Two |\n"
        result = self.preprocess(source, headerless=True)
        self.assertNotEqual(result, source)
        self.assertIn("A `command | output`\n", result)
        self.assertIn("| One | Two |", result)

    def test_pathological_unmatched_backticks_preserve_source_with_bounded_work(self):
        runs = " ".join("`" * width for width in range(1, 513))
        source = f"- [ ] {runs} | literal\n- [ ] {runs} | literal\n"
        started = time.monotonic()
        self.assertEqual(self.preprocess(source), source)
        self.assertLess(time.monotonic() - started, 1.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

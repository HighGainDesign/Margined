import importlib.util
import pathlib
import re
import tempfile
import xml.etree.ElementTree as ET
import unittest

MODULE = pathlib.Path(__file__).resolve().parents[1] / "benchmark-viewing.py"
spec = importlib.util.spec_from_file_location("benchmark_viewing", MODULE)
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class ViewingBenchmarkTests(unittest.TestCase):
    def rows(self, kind="warm", count=20):
        return [{"index": i, "pid": 123 if kind != "cold" else 123+i,
                 "request_ns": 1_000_000_000,
                 "geometry": {"windowWidth": 920, "windowHeight": 760, "viewportWidth": 920, "viewportHeight": 700, "backingScale": 2, "imageWidth": 1840, "imageHeight": 1400},
                 "render_ready_ns": 1_000_000_000 + (i+1)*500_000,
                 "frame_ns": 1_000_000_000 + (i+1)*1_000_000}
                for i in range(count)]

    def test_complete_cohort_uses_median_and_nearest_rank_p95(self):
        value = benchmark.summarize(self.rows(), 20, "warm")
        self.assertEqual(value["frame_ms"], {"median": 10.5, "p95": 19.0})
        self.assertEqual(value["render_ms"], {"median": 5.25, "p95": 9.5})
        self.assertEqual(value["samples"], 20)

    def test_partial_or_invalid_cohorts_are_rejected(self):
        valid = self.rows()
        cases = [valid[:-1], valid+[valid[-1]], [dict(r, index=0) for r in valid],
                 [dict(r, frame_ns=1) for r in valid],
                 [dict(r, request_ns=0) for r in valid],
                 [dict(r, pid=True) for r in valid],
                 [dict(r, index=float(r["index"])) for r in valid],
                 [dict(r, render_ready_ns=float("nan")) for r in valid]]
        for rows in cases:
            with self.subTest(rows=rows[:1]), self.assertRaises(ValueError):
                benchmark.summarize(rows, 20, "warm")

    def test_incomplete_or_changed_geometry_cannot_be_aggregated(self):
        for geometry in ({}, {"windowWidth": 0}, dict(self.rows()[0]["geometry"], viewportWidth=0),
                         dict(self.rows()[0]["geometry"], backingScale=float("nan"))):
            rows = self.rows()
            rows[0] = dict(rows[0], geometry=geometry)
            with self.subTest(geometry=geometry), self.assertRaises(ValueError):
                benchmark.summarize(rows, 20, "warm")
        rows = self.rows()
        rows[0] = dict(rows[0], geometry=dict(rows[0]["geometry"], viewportWidth=800))
        with self.assertRaises(ValueError):
            benchmark.summarize(rows, 20, "warm")

    def test_cold_requires_separate_processes_and_warm_reuses_one(self):
        self.assertEqual(benchmark.summarize(self.rows("cold"), 20, "cold")["samples"], 20)
        with self.assertRaises(ValueError):
            benchmark.summarize(self.rows("warm"), 20, "cold")
        with self.assertRaises(ValueError):
            benchmark.summarize(self.rows("cold"), 20, "warm")

    def test_fixture_corpus_is_repeatable_and_exercises_each_renderer(self):
        fixtures = benchmark.fixtures()
        self.assertEqual(set(fixtures), {"short", "prose", "long", "tables", "images", "math", "mermaid", "annotated", "long-discussion"})
        self.assertEqual(fixtures, benchmark.fixtures())
        for name, text in fixtures.items():
            self.assertTrue(text.startswith("# MARGINED-BENCHMARK-"))
            self.assertIn("-000", text.splitlines()[0])
            self.assertGreater(len(text.encode()), 100)
            self.assertNotIn("https://", text)
        self.assertIn("| ---", fixtures["tables"])
        self.assertIn("$", fixtures["math"])
        self.assertIn("```mermaid", fixtures["mermaid"])

    def test_annotated_cohort_keeps_matching_prose_and_exercises_multiple_authors(self):
        fixtures = benchmark.fixtures()
        self.assertIn("annotated", set(fixtures), "The benchmark must include the cost of saved discussions")
        annotated = fixtures["annotated"]
        prose = re.sub(r"<!-- margined:thread v1\n.*?\n-->\n?", "", annotated, flags=re.S)
        self.assertEqual(prose.strip(), fixtures["prose"].replace("BENCHMARK-PROSE", "BENCHMARK-ANNOTATED").strip())
        self.assertEqual(len(re.findall(r"^id: t-benchmark-", annotated, re.M)), 20)
        self.assertEqual(len(re.findall(r"^    author:", annotated, re.M)), 80)
        self.assertIn('author: "Alex"', annotated)
        self.assertIn('author: "Sam"', annotated)

    def test_local_image_cohort_stages_real_assets_in_multiple_directories(self):
        self.assertTrue(callable(getattr(benchmark, "write_fixture", None)),
                        "Native benchmark sessions must stage their fixture resources")
        fixtures = benchmark.fixtures()
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            source = benchmark.write_fixture(folder, fixtures["images"], benchmark.fixture_assets("images"))
            self.assertEqual(source.read_text(), fixtures["images"])
            images = re.findall(r"!\[[^]]*\]\(([^)]+)\)", source.read_text())
            self.assertEqual(len(images), 12)
            self.assertGreaterEqual(len({str(pathlib.Path(image).parent) for image in images}), 2)
            for image in images:
                asset = folder / image
                self.assertTrue(asset.is_file())
                root = ET.fromstring(asset.read_bytes())
                self.assertEqual(root.tag, "{http://www.w3.org/2000/svg}svg")
                self.assertEqual(root.attrib["viewBox"], "0 0 320 180")
            self.assertEqual(benchmark.fixture_assets("prose"), {})
            with self.assertRaises(ValueError):
                benchmark.write_fixture(folder, "# Escaping asset", {"../outside.svg": b"outside"})
            self.assertFalse((folder.parent / "outside.svg").exists())

    def test_corpus_separates_short_long_and_long_conversation_loads(self):
        fixtures = benchmark.fixtures()
        self.assertTrue({"short", "long", "long-discussion"}.issubset(fixtures),
                        "Short viewing and long-document/history costs need distinct cohorts")
        self.assertLess(len(fixtures["short"].encode()), 1000)
        self.assertGreater(len(fixtures["long"].encode()), 50000)
        self.assertEqual(len(re.findall(r"^id: t-benchmark-", fixtures["long-discussion"], re.M)), 1)
        self.assertEqual(len(re.findall(r"^    author:", fixtures["long-discussion"], re.M)), 120)

    def test_valid_child_result_preserves_raw_samples(self):
        payload = {"schema": 1, "status": "ok", "kind": "warm", "samples": self.rows(),
                   "configuration": "Release", "boundary": "verified-frame-v1"}
        self.assertEqual(benchmark.read_result(payload, "warm", 20), self.rows())

    def test_report_rejects_failed_child_instead_of_summarizing_its_rows(self):
        with self.assertRaises(ValueError):
            benchmark.read_result({"schema": 1, "status": "error", "samples": self.rows()}, "warm", 20)
        with self.assertRaises(ValueError):
            benchmark.read_result({"schema": 2, "status": "ok", "kind": "warm", "samples": self.rows()}, "warm", 20)
        with self.assertRaises(ValueError):
            benchmark.read_result({"schema": 1, "status": "ok", "kind": "refresh", "samples": self.rows()}, "warm", 20)


if __name__ == "__main__":
    unittest.main()

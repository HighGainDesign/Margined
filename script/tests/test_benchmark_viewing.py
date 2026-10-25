import importlib.util
import contextlib
import io
import hashlib
import json
import plistlib
import subprocess
import pathlib
import re
import tempfile
import xml.etree.ElementTree as ET
import unittest
from unittest import mock

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

    def modern_payload(self, count=1):
        rows = self.rows(count=count)
        for index, row in enumerate(rows):
            row["render_phases"] = {key: 10_000 * (index + 1) for key in (
                "note_parse_ns", "markdown_parse_ns", "projection_ns", "anchor_ns",
                "reading_metadata_ns", "review_tasks_ns", "artwork_ns", "serialization_ns")}
            row["renderer_total_ns"] = 100_000 * (index + 1)
            row["layout_ready_ns"] = row["request_ns"] + 750_000 * (index + 1)
            row["discussion_layout"] = {"thread_count": 0, "message_count": 0,
                "attached_count": 0, "laid_out_cards": 0, "history_messages": 0}
        return {"schema": 1, "status": "ok", "kind": "warm", "samples": rows,
                "configuration": "Release", "boundary": "verified-frame-v1", "presentation": "collapsed",
                "expected_discussions": {"thread_count": 0, "message_count": 0, "attached_count": 0}}

    def test_render_phase_and_layout_timestamps_cannot_claim_impossible_speed(self):
        for field, value in [("renderer_total_ns", 1), ("layout_ready_ns", 1),
                             ("layout_ready_ns", 9_000_000_000)]:
            payload = self.modern_payload()
            payload["samples"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                benchmark.read_result(payload, "warm", 1)
        for value in (-1, True, float("nan")):
            payload = self.modern_payload()
            payload["samples"][0]["render_phases"]["anchor_ns"] = value
            with self.subTest(stage=value), self.assertRaises(ValueError):
                benchmark.read_result(payload, "warm", 1)
        payload = self.modern_payload()
        self.assertEqual(benchmark.read_result(payload, "warm", 1), payload["samples"])

    def test_expanded_result_requires_a_real_sidebar_and_complete_selected_history(self):
        payload = self.modern_payload()
        payload["presentation"] = "expanded"
        with self.assertRaises(ValueError): benchmark.read_result(payload, "warm", 1)
        payload["boundary"] = "verified-discussion-frame-v1"
        payload["expected_discussions"] = {"thread_count": 20, "message_count": 80, "attached_count": 20}
        row = payload["samples"][0]
        row["geometry"].update(viewportWidth=540, imageWidth=1080)
        row["discussion_layout"] = {"thread_count": 20, "message_count": 80, "attached_count": 20,
            "laid_out_cards": 20, "history_thread": "t-benchmark-0", "history_messages": 4,
            "history_geometry": {"windowWidth": 920, "windowHeight": 760, "viewportWidth": 370,
                                 "viewportHeight": 240, "backingScale": 2}}
        self.assertEqual(benchmark.read_result(payload, "warm", 1), [row])
        import copy
        for field, value in [("laid_out_cards", 19), ("history_messages", 0), ("history_thread", None)]:
            broken = copy.deepcopy(payload); broken["samples"][0]["discussion_layout"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): benchmark.read_result(broken, "warm", 1)
        broken = copy.deepcopy(payload); broken["samples"][0]["geometry"]["viewportWidth"] = 920
        with self.assertRaises(ValueError): benchmark.read_result(broken, "warm", 1)

    def test_wrong_conversation_census_is_rejected_before_aggregation(self):
        payload = self.modern_payload()
        payload["expected_discussions"] = {"thread_count": 20, "message_count": 80, "attached_count": 20}
        payload["samples"][0]["discussion_layout"].update(thread_count=19, message_count=80, attached_count=19)
        with self.assertRaises(ValueError): benchmark.read_result(payload, "warm", 1)

    def test_complete_phase_cohort_retains_separate_costs(self):
        value = benchmark.summarize(self.modern_payload(count=2)["samples"], 2, "warm")
        self.assertEqual(value.get("phases_ms", {}).get("anchor"), {"median": 0.015, "p95": 0.02})
        self.assertEqual(value.get("renderer_ms"), {"median": 0.15000000000000002, "p95": 0.2})
        self.assertEqual(value.get("layout_wait_ms"), {"median": 0.375, "p95": 0.5})

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

    def test_native_contract_uses_the_actual_timed_conversation_inputs(self):
        resources = MODULE.parents[1] / "Benchmarks" / "Fixtures"
        for name in ("annotated", "long-discussion"):
            with self.subTest(fixture=name):
                self.assertEqual((resources / (name + "-benchmark.md")).read_text(), benchmark.fixtures()[name],
                                 "Native anchor acceptance must exercise the inputs the timer actually opens")

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

    def provenance_fixture(self, temporary):
        folder = pathlib.Path(temporary)
        source = folder / "Source"; source.mkdir()
        (source / "reader.swift").write_text("initial source", encoding="utf-8")
        (source / ".gitignore").write_text("cache/\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "add", "."], check=True)
        subprocess.run(["git", "-C", str(source), "-c", "core.hooksPath=/dev/null",
                        "-c", "commit.gpgsign=false", "-c", "user.name=Benchmark Test",
                        "-c", "user.email=benchmark@example.invalid", "commit", "-qm", "fixture"], check=True)
        app = folder / "Margined.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Margined", "CFBundleVersion": "1"}))
        (app / "Contents/MacOS/Margined").write_bytes(b"executable fixture one")
        (app / "Contents/Resources/reader.css").write_text("body { color: black; }", encoding="utf-8")
        return source, app

    def test_provenance_records_exact_source_and_bundle_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, app = self.provenance_fixture(temporary)
            (source / "new.md").write_text("uncommitted source", encoding="utf-8")
            captured = benchmark.capture_provenance(app, source)
            self.assertTrue({"working_source", "app_bundle"}.issubset(captured),
                            "Viewing reports must identify the source tree and exact measured bundle")
            self.assertEqual(captured["working_source"]["base"],
                             subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip())
            for name in ("reader.swift", "new.md"):
                self.assertEqual(captured["working_source"]["files"][name], hashlib.sha256((source / name).read_bytes()).hexdigest())
            self.assertEqual(captured["app_bundle"]["files"]["Contents/MacOS/Margined"],
                             hashlib.sha256((app / "Contents/MacOS/Margined").read_bytes()).hexdigest())
            self.assertEqual(captured, benchmark.capture_provenance(app, source))

    def test_binary_and_resource_changes_cannot_share_an_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, app = self.provenance_fixture(temporary)
            initial = benchmark.capture_provenance(app, source)
            (app / "Contents/MacOS/Margined").write_bytes(b"different executable, same version")
            binary = benchmark.capture_provenance(app, source)
            self.assertNotEqual(initial, binary, "A version number alone cannot identify the measured executable")
            (app / "Contents/Resources/reader.css").write_text("body { color: blue; }", encoding="utf-8")
            self.assertNotEqual(binary, benchmark.capture_provenance(app, source),
                                "Rendering resources are part of the measured app")

    def test_source_changes_are_detected_while_ignored_build_files_are_excluded(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, app = self.provenance_fixture(temporary)
            initial = benchmark.capture_provenance(app, source)
            (source / "cache").mkdir(); (source / "cache/generated").write_bytes(b"ignored")
            self.assertEqual(initial, benchmark.capture_provenance(app, source))
            (source / "reader.swift").write_text("changed source at the same HEAD", encoding="utf-8")
            self.assertNotEqual(initial, benchmark.capture_provenance(app, source),
                                "A Git revision alone does not identify uncommitted benchmark source")

    def test_provenance_rejects_a_bundle_with_no_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, app = self.provenance_fixture(temporary)
            (app / "Contents/MacOS/Margined").unlink()
            with self.assertRaises(ValueError): benchmark.capture_provenance(app, source)

    def test_report_records_provenance_and_rejects_an_app_changed_during_measurement(self):
        original_output = subprocess.check_output
        def system_output(command, **kwargs):
            if command == ["sysctl", "-n", "hw.model"]: return "Test Mac\n"
            return original_output(command, **kwargs)
        for changed in (False, True):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                _, app = self.provenance_fixture(temporary)
                output = pathlib.Path(temporary) / "report"
                def native_session(*args, **kwargs):
                    if changed: (app / "Contents/MacOS/Margined").write_bytes(b"replaced while measuring")
                    return {"schema": 1, "status": "ok", "kind": "warm", "samples": self.rows(count=1),
                            "configuration": "Release", "boundary": "verified-frame-v1"}
                argv = [str(MODULE), "--app", str(app), "--output", str(output),
                        "--samples", "1", "--fixtures", "short", "--cases", "warm"]
                with mock.patch.object(benchmark.sys, "argv", argv), mock.patch.object(benchmark.sys, "platform", "darwin"), \
                     mock.patch.object(benchmark, "run_session", side_effect=native_session), \
                     mock.patch.object(benchmark.subprocess, "check_output", side_effect=system_output), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    result = benchmark.main()
                report = json.loads((output / "report.json").read_text())
                self.assertEqual(result, 1 if changed else 0)
                if changed:
                    self.assertNotEqual(report["status"], "ok", "Changed inputs cannot yield an accepted viewing report")
                    self.assertIn("changed", report.get("error", "").lower())
                else:
                    self.assertIn("provenance", report)

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

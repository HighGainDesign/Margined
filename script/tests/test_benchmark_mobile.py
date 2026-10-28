import importlib.util
import pathlib
import subprocess
from unittest import mock
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "benchmark-mobile.py"
spec = importlib.util.spec_from_file_location("benchmark_mobile", SCRIPT)
mobile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mobile)


class MobileBenchmarkTests(unittest.TestCase):
    def payload(self):
        row = {"index": 0, "pid": 321, "request_ns": 1_000_000_000,
               "render_ready_ns": 1_001_000_000, "frame_ns": 1_002_000_000,
               "geometry": {"windowWidth": 402, "windowHeight": 874,
                   "viewportWidth": 402, "viewportHeight": 693, "backingScale": 3,
                   "imageWidth": 1206, "imageHeight": 2079},
               "render_phases": {k: 10_000 for k in mobile.canonical.PHASE_KEYS},
               "renderer_total_ns": 100_000, "layout_ready_ns": 1_001_500_000,
               "discussion_layout": {"thread_count": 0, "message_count": 0,
                   "attached_count": 0, "laid_out_cards": 0, "history_messages": 0}}
        return {"schema": 1, "status": "ok", "platform": "iOS Simulator",
                "configuration": "Release", "kind": "cold", "presentation": "collapsed",
                "boundary": "verified-frame-v1", "expected_discussions":
                {"thread_count": 0, "message_count": 0, "attached_count": 0}, "samples": [row]}

    def test_production_apps_are_rejected_before_any_device_access(self):
        device = "7098FA6B-0C0E-4037-8BB5-963D31BCD6D7"
        self.assertEqual(mobile.validate_target(device, "design.highgain.margined.benchmark.test"), device)
        for identifier in ("design.highgain.margined", "design.highgain.margined.quicklook",
                           "other.benchmark.test", "design.highgain.margined.benchmark.",
                           "design.highgain.margined.benchmark.test/unsafe"):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                mobile.validate_target(device, identifier)
        with self.assertRaises(ValueError):
            mobile.validate_target("booted", "design.highgain.margined.benchmark.test")

    def test_expected_corpus_census_is_not_inferred_from_result(self):
        self.assertEqual(mobile.discussion_counts("annotated"), (20, 80, 20))
        self.assertEqual(mobile.discussion_counts("long-discussion"), (1, 120, 1))
        self.assertEqual(mobile.discussion_counts("prose"), (0, 0, 0))
        with self.assertRaises(ValueError):
            mobile.accept_result(self.payload(), "cold", 1, 321, (20, 80, 20),
                                 1_000_000_000, 1_003_000_000)

    def test_cold_result_requires_actual_launched_pid_and_exact_external_start(self):
        payload = self.payload()
        rows = mobile.accept_result(payload, "cold", 1, 321, (0, 0, 0),
                                    1_000_000_000, 1_003_000_000)
        self.assertEqual(rows, payload["samples"])
        with self.assertRaises(ValueError):
            mobile.accept_result(payload, "cold", 1, 322, (0, 0, 0),
                                 1_000_000_000, 1_003_000_000)
        with self.assertRaises(ValueError):
            mobile.accept_result(payload, "cold", 1, 321, (0, 0, 0),
                                 999_000_000, 1_003_000_000)

    def test_native_timestamps_cannot_precede_launch_or_follow_observation(self):
        payload = self.payload()
        payload["kind"] = "warm"
        for start, observed in ((1_000_000_001, 1_003_000_000),
                                (999_000_000, 1_001_999_999)):
            with self.subTest(start=start, observed=observed), self.assertRaises(ValueError):
                mobile.accept_result(payload, "warm", 1, 321, (0, 0, 0), start, observed)
        self.assertEqual(len(mobile.accept_result(payload, "warm", 1, 321, (0, 0, 0),
                             999_000_000, 1_003_000_000)), 1)

    def test_failed_non_simulator_or_unfinished_payload_is_never_summarized(self):
        for field, value in (("status", "error"), ("platform", "iOS device"),
                             ("presentation", "expanded"), ("configuration", "Debug")):
            payload = self.payload(); payload[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                mobile.accept_result(payload, "cold", 1, 321, (0, 0, 0),
                                     1_000_000_000, 1_003_000_000)
        payload = self.payload(); payload["samples"] = []
        with self.assertRaises(ValueError):
            mobile.accept_result(payload, "cold", 1, 321, (0, 0, 0),
                                 1_000_000_000, 1_003_000_000)


    def test_launch_timeout_reconciles_and_stops_only_its_exact_new_executable(self):
        attempt = {}
        executable = pathlib.Path("/private/test/MarginediOS.app/MarginediOS")
        owned = {"pid": 321, "started": "new", "executable": str(executable)}
        with mock.patch.object(mobile, "matching_processes", side_effect=[[], [321]]), \
             mock.patch.object(mobile, "identity", return_value=owned), \
             mock.patch.object(mobile, "stop_owned") as stop, \
             mock.patch.object(mobile, "run", side_effect=subprocess.TimeoutExpired("simctl", 30)), \
             mock.patch.object(mobile.canonical, "monotonic_ns", side_effect=[1000, 2000]):
            with self.assertRaises(subprocess.TimeoutExpired):
                mobile.launch_private("device", "identifier", executable,
                                      pathlib.Path("/private/test/session"), attempt)
        stop.assert_called_once_with("device", "identifier", owned)
        self.assertEqual(attempt["hostLaunchStartNS"], 1000)
        self.assertEqual(attempt["hostLaunchReturnNS"], 2000)
        self.assertEqual(attempt["reconciledIdentities"], [owned])
        self.assertTrue(attempt["ownedProcessJoined"])
        self.assertIn("TimeoutExpired", attempt["launchError"])

    def test_malformed_launch_response_is_retained_even_when_session_fails(self):
        attempt = {}
        executable = pathlib.Path("/private/test/MarginediOS.app/MarginediOS")
        owned = {"pid": 321, "started": "new", "executable": str(executable)}
        with mock.patch.object(mobile, "matching_processes", side_effect=[[], [321]]), \
             mock.patch.object(mobile, "identity", return_value=owned), \
             mock.patch.object(mobile, "stop_owned") as stop, \
             mock.patch.object(mobile, "run", return_value="malformed launch reply"), \
             mock.patch.object(mobile.canonical, "monotonic_ns", side_effect=[1000, 2000]):
            with self.assertRaises(ValueError):
                mobile.launch_private("device", "identifier", executable,
                                      pathlib.Path("/private/test/session"), attempt)
        self.assertEqual(attempt["launchResponse"], "malformed launch reply")
        self.assertEqual(attempt["hostLaunchReturnNS"], 2000)
        stop.assert_called_once_with("device", "identifier", owned)

    def test_an_existing_private_process_is_never_claimed_or_stopped(self):
        attempt = {}
        with mock.patch.object(mobile, "matching_processes", return_value=[321]), \
             mock.patch.object(mobile, "stop_owned") as stop, \
             mock.patch.object(mobile, "run") as run:
            with self.assertRaises(ValueError):
                mobile.launch_private("device", "identifier", pathlib.Path("/test/app"),
                                      pathlib.Path("/test/session"), attempt)
        run.assert_not_called()
        stop.assert_not_called()
        self.assertNotIn("hostLaunchStartNS", attempt)


if __name__ == "__main__":
    unittest.main()

import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("native_diagnostic", Path(__file__).parents[1] / "verify-native-resize-diagnostic.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def case(report, passed=True, pid=111):
    name = module.TARGET
    return (f"Test Case '{name}' started.\nEMULATED-NATIVE-FEEDBACK-PROCESS {pid}\n"
            + module.MARKER + json.dumps({**report, "processID": pid}) + "\n"
            + f"Test Case '{name}' {'passed' if passed else 'failed'} (1.0 seconds).\n")


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.report = {"nativeSetterAccepted": True, "capture": {
            "nativeY": 5968, "domY": 3498, "virtualTop": 0.1875, "markedReadingPassage": True}}

    def test_every_relaunched_case_needs_its_own_divergent_capture(self):
        self.assertEqual(module.verify(case(self.report, pid=111) + case(self.report, pid=222)), {
            "replayCases": 2, "acceptedDivergentCaptures": [1, 1], "processIDs": [111, 222]})
        ordinary = {"nativeSetterAccepted": True, "capture": {**self.report["capture"], "domY": 5968}}
        with self.assertRaisesRegex(ValueError, "Case 2 lacks"):
            module.verify(case(self.report, pid=111) + case(ordinary, pid=222))

    def test_wrong_anchor_or_rejected_setter_cannot_prove_preservation(self):
        for report in [{**self.report, "nativeSetterAccepted": False},
                       {**self.report, "capture": {**self.report["capture"], "markedReadingPassage": False}}]:
            with self.assertRaisesRegex(ValueError, "lacks an accepted"):
                module.verify(case(report, pid=111) + case(report, pid=222))

    def test_capture_receipt_alone_cannot_replace_behavior_outcome(self):
        with self.assertRaisesRegex(ValueError, "did not pass"):
            module.verify(case(self.report, passed=False, pid=111) + case(self.report, passed=False, pid=222))
        with self.assertRaisesRegex(ValueError, "No emulated"):
            module.verify(module.MARKER + json.dumps(self.report))

    def test_corrupt_or_nonfinite_receipts_are_not_accepted(self):
        with self.assertRaises(json.JSONDecodeError):
            module.verify(case(self.report).replace(module.MARKER + "{", module.MARKER + "{truncated"))
        invalid = {**self.report, "capture": {**self.report["capture"], "nativeY": float("nan")}}
        with self.assertRaisesRegex(ValueError, "lacks an accepted"):
            module.verify(case(invalid, pid=111) + case(invalid, pid=222))

    def test_missing_second_iteration_is_not_complete_evidence(self):
        with self.assertRaisesRegex(ValueError, "Expected 2"):
            module.verify(case(self.report))

    def test_two_cases_in_one_process_do_not_prove_fresh_relaunches(self):
        with self.assertRaisesRegex(ValueError, "distinct processes"):
            module.verify(case(self.report) * 2)

    def test_capture_from_another_process_cannot_satisfy_the_case(self):
        log = case(self.report, pid=111) + case(self.report, pid=222)
        with self.assertRaisesRegex(ValueError, "Case 1 lacks"):
            module.verify(log.replace('"processID": 111', '"processID": 999', 1))

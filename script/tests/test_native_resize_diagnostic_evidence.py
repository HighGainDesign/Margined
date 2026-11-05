import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("native_diagnostic", Path(__file__).parents[1] / "verify-native-resize-diagnostic.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def case(report, passed=True):
    name = module.TARGET
    return (f"Test Case '{name}' started.\n" + module.MARKER + json.dumps(report) + "\n"
            + f"Test Case '{name}' {'passed' if passed else 'failed'} (1.0 seconds).\n")


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.report = {"nativeSetterAccepted": True, "capture": {
            "nativeY": 5968, "domY": 3498, "virtualTop": 0.1875, "markedReadingPassage": True}}

    def test_every_relaunched_case_needs_its_own_divergent_capture(self):
        self.assertEqual(module.verify(case(self.report) * 2), {
            "replayCases": 2, "acceptedDivergentCaptures": [1, 1]})
        ordinary = {"nativeSetterAccepted": True, "capture": {**self.report["capture"], "domY": 5968}}
        with self.assertRaisesRegex(ValueError, "Case 2 lacks"):
            module.verify(case(self.report) + case(ordinary))

    def test_wrong_anchor_or_rejected_setter_cannot_prove_preservation(self):
        for report in [{**self.report, "nativeSetterAccepted": False},
                       {**self.report, "capture": {**self.report["capture"], "markedReadingPassage": False}}]:
            with self.assertRaisesRegex(ValueError, "lacks an accepted"):
                module.verify(case(report))

    def test_capture_receipt_alone_cannot_replace_behavior_outcome(self):
        with self.assertRaisesRegex(ValueError, "did not pass"):
            module.verify(case(self.report, passed=False))
        with self.assertRaisesRegex(ValueError, "No emulated"):
            module.verify(module.MARKER + json.dumps(self.report))

    def test_corrupt_or_nonfinite_receipts_are_not_accepted(self):
        with self.assertRaises(json.JSONDecodeError):
            module.verify(case(self.report).replace(json.dumps(self.report), "{truncated"))
        invalid = {**self.report, "capture": {**self.report["capture"], "nativeY": float("nan")}}
        with self.assertRaisesRegex(ValueError, "lacks an accepted"):
            module.verify(case(invalid))

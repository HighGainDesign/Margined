import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_version import metadata


class ReleaseVersionTests(unittest.TestCase):
    def test_stable_release_keeps_latest_eligibility(self):
        self.assertEqual(metadata("v1.7.1", "1.7.1"),
                         {"version": "1.7.1", "notes_version": "1.7.1", "prerelease": "false"})

    def test_beta_tag_uses_numeric_bundle_version_and_beta_notes(self):
        self.assertEqual(metadata("v2.0-beta.1", "2.0"),
                         {"version": "2.0", "notes_version": "2.0-beta.1", "prerelease": "true"})

    def test_three_component_beta_and_release_candidate_are_prereleases(self):
        for tag in ("v2.0.0-beta.2", "v2.0.0-rc.1"):
            self.assertEqual(metadata(tag, "2.0.0")["prerelease"], "true")

    def test_zero_series_remains_a_prerelease(self):
        self.assertEqual(metadata("v0.2.6", "0.2.6")["prerelease"], "true")

    def test_bundle_version_mismatch_is_rejected(self):
        with self.assertRaises(ValueError):
            metadata("v2.0-beta.1", "1.7.1")

    def test_invalid_or_unexpected_tag_is_rejected(self):
        for tag in ("2.0", "v2", "v2.0-beta", "v2.0-beta.0", "v2.0-beta.1.extra", "v2.0\nlatest=true"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                metadata(tag, "2.0")


if __name__ == "__main__":
    unittest.main()

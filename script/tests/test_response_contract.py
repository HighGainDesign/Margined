"""Check the local Build 17 delivery contract before a release is prepared."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ResponseContractTests(unittest.TestCase):
    def test_all_configurations_use_the_same_build_number(self):
        project = (ROOT / 'project.yml').read_text()
        versions = re.findall(r'^\s+CURRENT_PROJECT_VERSION:\s*(\d+)\s*$', project, re.M)
        self.assertGreaterEqual(len(versions), 4, 'Check app-store and mobile overrides as well as the base')
        self.assertEqual(len(set(versions)), 1, 'Mac, iOS and embedded extensions must report the same build')
        self.assertGreaterEqual(int(versions[0]), 17, 'Response controls require Build 17 or later')
        self.assertIn("macOS: '14.0'", project)
        self.assertIn("iOS: '17.0'", project)

    def test_authoring_example_and_public_reference_ship_with_the_source(self):
        self.assertTrue((ROOT / 'RESPONSES.md').is_file())
        self.assertTrue((ROOT / 'skills/margined-markdown/assets/responses-example.md').is_file())


if __name__ == '__main__':
    unittest.main(verbosity=2)

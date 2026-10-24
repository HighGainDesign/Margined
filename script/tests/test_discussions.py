#!/usr/bin/env python3
"""Run the real shared discussion tests without registering or launching an app."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRODUCTS = Path(os.environ.get("MARGINED_DISCUSSION_PRODUCTS", "/tmp/Margined-preview-mac/Build/Products/Debug"))
MAPS = PRODUCTS.parents[1] / "Intermediates.noindex/GeneratedModuleMaps"

class DiscussionTests(unittest.TestCase):
    def test_portable_discussion_contract(self):
        with tempfile.TemporaryDirectory(prefix="margined-discussion-tests-") as td:
            runner = Path(td) / "discussion-tests"
            developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
            frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
            command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-D", "MARGINED_DISCUSSION_PROBE",
                       "-I", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib"), "-L", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib"), "-Xlinker", "-rpath", "-Xlinker", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib"), "-I", str(ROOT / "Vendor/Apex/PackageSupport/cmark-gfm"), "-I", str(PRODUCTS), str(PRODUCTS / "SwiftSoup.o"), "-F", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks)]
            for name in ("CcmarkGFM", "CcmarkGFMSupport", "CYaml"):
                command += ["-Xcc", "-fmodule-map-file=" + str(MAPS / (name + ".modulemap")), str(PRODUCTS / (name + ".o"))]
            command += [str(ROOT / "Shared/MarkdownSource.swift"), str(ROOT / "Shared/MarkdownSourceEdits.swift"), str(ROOT / "Shared/SourceFileEdit.swift"), str(ROOT / "Shared/SourceFileGate.swift"), str(ROOT / "Shared/MathSyntax.swift")]
            command += [str(p) for p in sorted((ROOT / "Shared/Discussions").glob("*.swift"))]
            command += [str(ROOT / "Tests/MarkdownSourceEditsTests.swift"), str(ROOT / "Tests/SourceFileEditTests.swift"), str(ROOT / "Tests/SourceFileGateTests.swift"), str(ROOT / "Tests/DiscussionSessionTests.swift"), str(ROOT / "Tests/DiscussionCodecTests.swift"), str(ROOT / "Tests/DiscussionReconciliationTests.swift"), str(ROOT / "Tests/DiscussionAnchorTests.swift"), str(ROOT / "Tests/DiscussionMarginTests.swift"), str(ROOT / "script/tests/DiscussionProbe.swift"), "-o", str(runner)]
            build = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(runner)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout + result.stderr)

if __name__ == "__main__": unittest.main(verbosity=2)

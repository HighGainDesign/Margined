#!/usr/bin/env python3
"""Check real reader/task objects without the foreground application entrypoint.

Build the Mac test products with build-for-testing first. Set
MARGINED_TASK_PRODUCTS to Build/Products/Debug and, optionally,
MARGINED_TASK_PARSER_PRODUCTS to separately built Apex C products.
"""
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRODUCTS = Path(os.environ.get("MARGINED_TASK_PRODUCTS", "/tmp/Margined-preview-mac/Build/Products/Debug"))
PARSER_PRODUCTS = Path(os.environ.get("MARGINED_TASK_PARSER_PRODUCTS", str(PRODUCTS)))
READER_STATE = os.environ.get("MARGINED_READER_STATE_PROBE") == "1"


class MarkdownTaskTests(unittest.TestCase):
    def test_exact_task_mappings_and_authoring_example(self):
        build = PRODUCTS.parents[1]
        maps = build / "Intermediates.noindex/GeneratedModuleMaps"
        object_dir = (build / f"Intermediates.noindex/Margined.build/{PRODUCTS.name}/Margined.build/Objects-normal"
                      / platform.machine())
        objects = sorted(p for p in object_dir.glob("*.o") if p.name != "MarginedApp.o")
        self.assertTrue(objects, "Build the Mac test products before running this CPU regression")
        with tempfile.TemporaryDirectory(prefix="margined-task-probe-") as td:
            bundle = Path(td) / "TaskProbe.bundle"
            executable = bundle / "Contents/MacOS/task-probe"
            executable.parent.mkdir(parents=True)
            shutil.copytree(ROOT / "Shared/Resources", bundle / "Contents/Resources")
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "design.highgain.margined.tests.cpu",
                "CFBundleExecutable": "task-probe", "CFBundlePackageType": "BNDL"}))
            vendor = ROOT / "Vendor/Apex"
            developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
            frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
            command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                       "-module-cache-path", str(Path(td) / "modules"), "-I", str(PRODUCTS),
                       "-F", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                       "-I", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib"),
                       "-L", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib"),
                       "-Xlinker", "-rpath", "-Xlinker", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib")]
            if READER_STATE:
                command += ["-D", "MARGINED_READER_STATE_PROBE", str(ROOT / "Tests/ChecklistStateTests.swift"),
                            str(ROOT / "Tests/ResponseStateTests.swift"), str(ROOT / "Tests/ResponseEditorTests.swift")]
            for relative in ("include", "vendor/cmark-gfm/src", "vendor/cmark-gfm/extensions",
                             "PackageSupport/cmark-gfm", "vendor/libyaml/include"):
                command += ["-I", str(vendor / relative)]
            command += ["-Xcc", "-fmodule-map-file=" + str(vendor / "include/apex/module.modulemap"),
                        str(ROOT / "script/tests/MarkdownTaskProbe.swift"),
                        str(ROOT / "Tests/MarkdownTaskTests.swift"),
                        str(ROOT / "Tests/MarkdownResponseTests.swift"),
                        *map(str, objects), str(PRODUCTS / "SwiftSoup.o")]
            for name in ("ApexC", "CcmarkGFM", "CcmarkGFMExtensions", "CcmarkGFMSupport", "CYaml"):
                modulemap = vendor / "include/module.modulemap" if name == "ApexC" else maps / (name + ".modulemap")
                command += ["-Xcc", "-fmodule-map-file=" + str(modulemap), str(PARSER_PRODUCTS / (name + ".o"))]
            command += ["-o", str(executable)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            samples = [ROOT / "skills/margined-markdown/assets/review-example.md",
                       ROOT / "skills/margined-markdown/assets/build14-checklist.md"]
            if authored := os.environ.get("MARGINED_AUTHORING_FIXTURE"):
                samples.append(Path(authored))
            result = subprocess.run([str(executable), *map(str, samples)],
                                    capture_output=True, text=True, timeout=120 if READER_STATE else 20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout + result.stderr, end="")


if __name__ == "__main__":
    unittest.main(verbosity=2)

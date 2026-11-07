#!/usr/bin/env python3
"""Exercise native response message validation without an application process."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ResponseBridgeTests(unittest.TestCase):
    def test_native_response_validation(self):
        developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
        platform = developer / "Platforms/MacOSX.platform/Developer"
        with tempfile.TemporaryDirectory(prefix="margined-response-bridge-") as directory:
            directory = Path(directory)
            main = directory / "main.swift"
            main.write_text("""import XCTest
@main struct Probe {
    static func main() {
        let suite = ResponseControlBridgeTests.defaultTestSuite
        guard suite.testCaseCount > 0 else { exit(2) }
        suite.run()
        if suite.testRun?.hasSucceeded != true { exit(1) }
    }
}
""")
            runner = directory / "bridge-tests"
            command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                       "-D", "MARGINED_RESPONSE_BRIDGE_PROBE", "-module-cache-path", str(directory / "modules"),
                       "-F", str(platform / "Library/Frameworks"),
                       "-Xlinker", "-rpath", "-Xlinker", str(platform / "Library/Frameworks"),
                       "-I", str(platform / "usr/lib"), "-L", str(platform / "usr/lib"),
                       "-Xlinker", "-rpath", "-Xlinker", str(platform / "usr/lib"),
                       str(ROOT / "Shared/ResponseControlBridge.swift"),
                       str(ROOT / "Tests/ResponseControlBridgeTests.swift"), str(main), "-o", str(runner)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(runner)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

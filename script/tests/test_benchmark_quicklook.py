import copy
import importlib.util
from pathlib import Path
import unittest
import tempfile
import subprocess
import sys
import os
from unittest import mock

spec = importlib.util.spec_from_file_location("benchmark_quicklook", Path(__file__).resolve().parents[1] / "benchmark-quicklook.py")
ql = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ql)


class QuickLookBenchmarkTests(unittest.TestCase):
    def metadata(self):
        host = {"CFBundleIdentifier": ql.HOST_ID, "CFBundleExecutable": "ScopeHost",
                "CFBundleDocumentTypes": [{"LSItemContentTypes": [ql.UTI]}],
                "UTImportedTypeDeclarations": [{"UTTypeIdentifier": ql.UTI,
                    "UTTypeTagSpecification": {"public.filename-extension": [ql.EXTENSION]}}]}
        provider = {"CFBundleIdentifier": ql.PROVIDER_ID, "CFBundleExecutable": "MarginedQuickLook",
                    "NSExtension": {"NSExtensionPointIdentifier": "com.apple.quicklook.preview",
                        "NSExtensionAttributes": {"QLIsDataBasedPreview": True, "QLSupportedContentTypes": [ql.UTI]}}}
        return host, provider

    def test_only_the_private_host_and_provider_may_be_registered(self):
        host, provider = self.metadata()
        ql.validate_metadata(host, provider)
        for metadata in (host, provider):
            saved = metadata["CFBundleIdentifier"]
            metadata["CFBundleIdentifier"] = "design.highgain.margined"
            with self.assertRaises(ValueError): ql.validate_metadata(host, provider)
            metadata["CFBundleIdentifier"] = saved

    def test_standard_markdown_or_plaintext_type_claims_are_refused(self):
        for content_type in ("public.plain-text", "net.daringfireball.markdown"):
            host, provider = self.metadata()
            host["CFBundleDocumentTypes"][0]["LSItemContentTypes"].append(content_type)
            with self.assertRaises(ValueError): ql.validate_metadata(host, provider)
            host, provider = self.metadata()
            provider["NSExtension"]["NSExtensionAttributes"]["QLSupportedContentTypes"].append(content_type)
            with self.assertRaises(ValueError): ql.validate_metadata(host, provider)
        host, provider = self.metadata()
        host["UTImportedTypeDeclarations"][0]["UTTypeTagSpecification"]["public.filename-extension"] = ["md"]
        with self.assertRaises(ValueError): ql.validate_metadata(host, provider)

    def test_registration_timeout_still_unregisters_the_exact_owned_paths(self):
        command=mock.Mock(side_effect=[TimeoutError("register response lost"), b"", b"", b""])
        registration=ql.PrivateRegistration(command,Path("/private/test/ScopeHost.app"),Path("/private/test/ScopeHost.app/Contents/PlugIns/MarginedQuickLook.appex"))
        with self.assertRaises(TimeoutError): registration.open()
        registration.close()
        calls=command.call_args_list
        self.assertEqual(len(calls),4)
        self.assertEqual(calls[-1].args[0][-2:],["-u","/private/test/ScopeHost.app"])
        self.assertTrue(all(call.kwargs.get("cleanup") is True for call in calls[1:]))

    def test_registration_cleanup_attempts_every_action_after_one_fails(self):
        command=mock.Mock()
        registration=ql.PrivateRegistration(command,Path("/private/test/ScopeHost.app"),Path("/private/test/ScopeHost.app/Contents/PlugIns/MarginedQuickLook.appex"))
        registration.open(); command.reset_mock(); command.side_effect=[RuntimeError("disabled"),b"",b""]
        with self.assertRaises(RuntimeError): registration.close()
        self.assertEqual(command.call_count,3)

    def test_staged_ocr_helper_keeps_its_executable_mode_and_source_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);host=root/'source/ScopeHost.app';host.mkdir(parents=True)
            (host/'Info.plist').write_bytes(b'host metadata')
            helper=root/'source/recognize';helper.write_bytes(b'qualified executable');helper.chmod(0o755)
            fixtures=root/'fixtures';fixtures.mkdir();(fixtures/'fixture.md').write_text('fixture')
            runtime=root/'runtime'
            ql.stage_runtime(host,helper,fixtures,runtime)
            self.assertTrue(os.access(runtime/'recognize',os.X_OK))
            self.assertEqual((runtime/'recognize').read_bytes(),helper.read_bytes())
            self.assertEqual((runtime/'ScopeHost.app/Info.plist').read_bytes(),b'host metadata')
            self.assertEqual((runtime/'fixtures/fixture.md').read_text(),'fixture')
            with self.assertRaises(FileExistsError): ql.stage_runtime(host,helper,fixtures,runtime)

    def test_reports_must_be_outside_source_or_in_a_gitignored_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();source=root/'source';source.mkdir()
            subprocess.run(['git','init','-q',str(source)],check=True)
            (source/'.gitignore').write_text('dist/\n')
            self.assertEqual(ql.validate_output(root/'external',source),root/'external')
            self.assertEqual(ql.validate_output(source/'dist/new-report',source),source/'dist/new-report')
            with self.assertRaises(ValueError): ql.validate_output(source/'new-report',source)
            self.assertFalse((source/'new-report').exists())

    def test_termination_signal_runs_finally_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            proof=Path(directory)/'cleanup'
            code="""import importlib.util,signal,os,sys
s=importlib.util.spec_from_file_location('ql',sys.argv[1]);q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
signal.signal(signal.SIGTERM,q.interrupt_on_termination)
try:os.kill(os.getpid(),signal.SIGTERM)
finally:open(sys.argv[2],'w').write('cleaned')
"""
            result=subprocess.run([sys.executable,'-c',code,str(Path(ql.__file__)),str(proof)],capture_output=True,timeout=10)
            self.assertNotEqual(result.returncode,0)
            self.assertTrue(proof.exists(),result.stderr.decode())
            self.assertEqual(proof.read_text(),'cleaned')

    def test_stale_marker_blank_or_missing_image_pixels_cannot_count_as_rendered(self):
        row = {"text": "Preview ALPHA", "colors": {"green": 1200, "blue": 1200}}
        self.assertTrue(ql.accepted_frame(row, "ALPHA"))
        self.assertFalse(ql.accepted_frame(row, "BRAVO"))
        self.assertFalse(ql.accepted_frame(dict(row, text="Preview ALPHABET"), "ALPHA"))
        for color in ("green", "blue"):
            bad = copy.deepcopy(row); bad["colors"][color] = 0
            self.assertFalse(ql.accepted_frame(bad, "ALPHA"))
        self.assertFalse(ql.accepted_frame({"text": "", "colors": {"green": 0, "blue": 0}}, "ALPHA"))

    def rows(self, mode="warm", count=20):
        return [{"mode": mode, "index": i, "hostPID": 100 + i if mode == "cold" else 100,
                 "providerPID": 200 + i if mode == "cold" else 200,
                 "request_ns": 1_000_000, "observed_ns": 1_000_000 + (i+1)*1_000_000,
                 "events": [{"stage": stage, "pid": 200+i if mode == "cold" else 200,
                             "uptime_ns": 1_100_000 + n*1000} for n, stage in enumerate(("request", "ready", "deliver"))]}
                for i in range(count)]

    def test_cohorts_are_complete_and_warm_reuses_the_actual_provider(self):
        rows = self.rows()
        self.assertEqual(ql.summarize(rows, "warm", 20), {"count": 20, "median_ms": 10.5, "p95_ms": 19.0, "maximum_ms": 20.0})
        for bad in (rows[:-1], [dict(row, index=0) for row in rows], self.rows("cold")):
            with self.assertRaises(ValueError): ql.summarize(bad, "warm", 20)
        self.assertEqual(ql.summarize(self.rows("cold"), "cold", 20)["count"], 20)
        with self.assertRaises(ValueError): ql.summarize(rows, "cold", 20)

    def test_missing_or_out_of_interval_provider_events_reject_a_cohort(self):
        for field, value in (("events", []), ("observed_ns", 1), ("providerPID", 999)):
            rows = self.rows(); rows[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): ql.summarize(rows, "warm", 20)
        rows = self.rows(); rows[0]["events"][0]["uptime_ns"] = 999_999
        with self.assertRaises(ValueError): ql.summarize(rows, "warm", 20)


if __name__ == "__main__":
    unittest.main()

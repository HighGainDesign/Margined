"""Exercise the real optimized app's expanded-view and timing acceptance boundary."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import statistics
import time
import unittest


class NativeObserverContract(unittest.TestCase):
    app = None
    output = None
    benchmark = None

    def launch(self, presentation, threads=20, require_ready=True, fixture="annotated", kind="cold", samples=1):
        directory = self.output / self._testMethodName
        directory.mkdir()
        text = self.benchmark.fixtures()[fixture]
        (directory / 'fixture.md').write_text(text)
        request = {'version': 1, 'kind': kind, 'sourceFile': 'fixture.md',
                   'expectedMarker': text.splitlines()[0][2:], 'sampleCount': samples,
                   'expectedMath': 0, 'expectedDiagrams': 0,
                   'presentation': presentation, 'expectedThreads': threads,
                   'expectedMessages': 80 if fixture == 'annotated' else 0, 'expectedAttached': threads}
        manifest = directory / 'request.json'
        manifest.write_text(json.dumps(request))
        info = plistlib.loads((self.app / 'Contents/Info.plist').read_bytes())
        executable = self.app / 'Contents/MacOS' / info['CFBundleExecutable']
        env = dict(os.environ, MARGINED_TEST_PREFERENCES='1',
                   MARGINED_BENCHMARK_REQUEST=str(manifest),
                   MARGINED_BENCHMARK_START_NS=str(self.benchmark.monotonic_ns()))
        with (directory / 'process.log').open('wb') as log:
            child = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=log)
            try:
                code = child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                child.terminate()
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
                raise RuntimeError('Native positive control did not finish; this is not a behavior RED')
        result = directory / 'result.json'
        if not result.is_file():
            raise RuntimeError('Native app produced no result; inspect the process log')
        payload = json.loads(result.read_text())
        if require_ready and (code != 0 or payload.get('status') != 'ok'):
            raise RuntimeError('Native readiness failed: ' + str(payload.get('error', code)))
        return code, payload, directory

    def test_expanded_conversation_has_real_native_layout_and_rendered_history(self):
        _, payload, folder = self.launch('expanded')
        row = payload['samples'][0]
        geometry = row['geometry']
        self.assertLessEqual(geometry['viewportWidth'], geometry['windowWidth'] - 300,
                             'The discussion panel must actually occupy native window space')
        self.assertEqual(payload.get('presentation'), 'expanded')
        layout = row.get('discussion_layout', {})
        self.assertEqual(layout.get('thread_count'), 20)
        self.assertEqual(layout.get('message_count'), 80)
        self.assertEqual(layout.get('attached_count'), 20)
        self.assertEqual(layout.get('laid_out_cards'), 20)
        self.assertEqual(layout.get('history_thread'), 't-benchmark-0')
        self.assertEqual(layout.get('history_messages'), 4)
        self.assertTrue((folder / 'history-frame-0.png').is_file())

    def test_real_render_records_parse_anchor_and_layout_stages(self):
        _, payload, _ = self.launch('collapsed')
        row = payload['samples'][0]
        phases = row.get('render_phases')
        self.assertIsInstance(phases, dict, 'Actual renderer phase timings must accompany the sample')
        for key in ['note_parse_ns', 'markdown_parse_ns', 'projection_ns', 'anchor_ns',
                    'reading_metadata_ns', 'review_tasks_ns', 'artwork_ns', 'serialization_ns']:
            self.assertIs(type(phases.get(key)), int, key)
            self.assertGreaterEqual(phases[key], 0, key)
        self.assertGreater(phases['note_parse_ns'], 0)
        self.assertGreater(phases['anchor_ns'], 0)
        self.assertGreaterEqual(row['renderer_total_ns'], sum(phases.values()))
        self.assertLessEqual(row['renderer_total_ns'], row['render_ready_ns'] - row['request_ns'])
        self.assertGreaterEqual(row['layout_ready_ns'], row['render_ready_ns'])
        self.assertLessEqual(row['layout_ready_ns'], row['frame_ns'])

    def test_opening_lifecycle_locates_window_and_webkit_costs(self):
        _, payload, _ = self.launch('collapsed')
        row = payload['samples'][0]
        stages = row.get('opening_lifecycle')
        self.assertIsInstance(stages, dict,
                              'Real opening needs read, window, task and WebKit timestamps')
        names = ['read_started_ns', 'read_finished_ns', 'window_started_ns',
                 'window_finished_ns', 'watch_started_ns', 'render_enqueued_ns',
                 'render_task_started_ns', 'renderer_requested_ns', 'webview_started_ns',
                 'webview_created_ns', 'navigation_requested_ns', 'navigation_finished_ns']
        for name in names:
            self.assertIs(type(stages.get(name)), int, name)
            self.assertGreaterEqual(stages[name], row['request_ns'], name)
            self.assertLessEqual(stages[name], row['frame_ns'], name)
        for before, after in [('read_started_ns', 'read_finished_ns'),
                              ('read_finished_ns', 'window_started_ns'),
                              ('window_started_ns', 'window_finished_ns'),
                              ('watch_started_ns', 'render_enqueued_ns'),
                              ('render_enqueued_ns', 'render_task_started_ns'),
                              ('render_task_started_ns', 'renderer_requested_ns'),
                              ('webview_started_ns', 'webview_created_ns'),
                              ('webview_created_ns', 'navigation_requested_ns'),
                              ('navigation_requested_ns', 'navigation_finished_ns')]:
            self.assertLessEqual(stages[before], stages[after], (before, after))
        self.assertLessEqual(stages['renderer_requested_ns'], row['render_ready_ns'])
        self.assertGreaterEqual(stages['webview_started_ns'], row['render_ready_ns'])

    def test_warm_prose_opening_avoids_fresh_webkit_startup(self):
        _, payload, _ = self.launch('collapsed', threads=0, fixture='prose', kind='warm', samples=20)
        rows = payload['samples']
        self.assertEqual(len(rows), 20)
        self.assertEqual(len({row['pid'] for row in rows}), 1, 'Warm opening must reuse the process')
        frame_ms = [(row['frame_ns'] - row['request_ns']) / 1_000_000 for row in rows]
        navigation_ms = [(row['opening_lifecycle']['navigation_finished_ns']
                          - row['opening_lifecycle']['navigation_requested_ns']) / 1_000_000 for row in rows]
        self.assertLess(statistics.median(frame_ms), 175,
                        'Complete warm opening must improve, not just an internal stage: ' + str(statistics.median(frame_ms)))
        self.assertLess(statistics.median(navigation_ms), 20,
                        'Warm documents should avoid fresh WebKit startup: ' + str(statistics.median(navigation_ms)))

    def test_warm_window_opening_avoids_initial_fitting(self):
        _, payload, _ = self.launch('collapsed', threads=0, fixture='prose', kind='warm', samples=20)
        rows = payload['samples']
        self.assertEqual(len(rows), 20)
        self.assertEqual(len({row['pid'] for row in rows}), 1)
        frame_ms = [(row['frame_ns'] - row['request_ns']) / 1_000_000 for row in rows]
        window_ms = [(row['opening_lifecycle']['window_finished_ns']
                      - row['opening_lifecycle']['window_started_ns']) / 1_000_000 for row in rows]
        self.assertLess(statistics.median(frame_ms), 140,
                        'Window sizing must improve complete warm opening: ' + str(statistics.median(frame_ms)))
        self.assertLess(statistics.median(window_ms), 20,
                        'Initial window setup should avoid content fitting: ' + str(statistics.median(window_ms)))

    def test_wrong_discussion_expectation_cannot_yield_a_fast_success(self):
        code, payload, _ = self.launch('expanded', threads=19, require_ready=False)
        self.assertNotEqual(code, 0, 'A wrong note count must reject the sample')
        self.assertEqual(payload.get('status'), 'error')
        self.assertIn('expectation', str(payload.get('error', '')).lower())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('benchmark_under_test', args.source_root / 'script/benchmark-viewing.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    NativeObserverContract.app = args.app.resolve()
    NativeObserverContract.output = args.output.resolve()
    NativeObserverContract.benchmark = module
    started = time.monotonic()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(NativeObserverContract))
    receipt = {'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
               'skipped': len(result.skipped), 'elapsedSeconds': time.monotonic() - started,
               'failureDetails': [{'test': str(test), 'detail': detail} for test, detail in result.failures],
               'errorDetails': [{'test': str(test), 'detail': detail} for test, detail in result.errors]}
    (args.output / 'contract-result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == '__main__':
    main()

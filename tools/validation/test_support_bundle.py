"""Support archives never include local paths, text, keys or arbitrary fields."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'diagnostics'))
import support_bundle as bundle

PRIVATE = 'SENSITIVE_SENTINEL_DO_NOT_EXPORT'


class SupportBundleTests(unittest.TestCase):
    def route(self, engine='google_gtx', failed=1, kind='tls'):
        return f'[2026-11-22 08:00:00] engine-route id=42 engine={engine} calls=1 failed={failed} cached=0 skipped=0 elapsed_ms=5029 kind={kind}'

    def test_engine_routes_keep_failures_separate_from_latest_success(self):
        tail = '\n'.join([self.route(), self.route('mymemory', 0, 'none'), self.route(failed=0, kind='none'),
                         self.route(kind=PRIVATE), 'detail=' + self.route()])
        result = bundle.engine_routes(tail)
        self.assertEqual(0, result['lastEngineRoutes']['google_gtx']['failed'])
        self.assertEqual('tls', result['lastEngineFailures']['google_gtx']['kind'])
        self.assertNotIn('mymemory', result['lastEngineFailures'])
        self.assertNotIn(PRIVATE, json.dumps(result))

    def test_engine_route_counts_are_typed_and_bounded(self):
        for line in (self.route(failed=2), self.route().replace('calls=1', 'calls=201'),
                     self.route().replace('elapsed_ms=5029', 'elapsed_ms=7200001')):
            self.assertEqual({}, bundle.engine_routes(line)['lastEngineRoutes'])
        metadata = {'logs': {'translate': {'lastEngineFailures': {
            'google_gtx': {'calls': 1, 'failed': 1, 'cached': 0, 'skipped': 0, 'elapsedMs': 2, 'kind': 'tls',
                           'path': PRIVATE, 'message': PRIVATE, 'requestId': 42},
            PRIVATE: {'calls': 1}, 'tencent': {'kind': [PRIVATE]}}}}}
        safe = bundle.redact_report(metadata)
        serialized = json.dumps(safe)
        self.assertNotIn(PRIVATE, serialized)
        self.assertNotIn('requestId', serialized)
        self.assertEqual('tls', safe['logs']['translate']['lastEngineFailures']['google_gtx']['kind'])

    def metric(self, status='ok', elapsed=100, cached=0, fallback='none', completed=1, failed=0, total=1, resumed=0):
        return (f'[2026-11-22 08:00:00] metric id=42 status={status} elapsed_ms={elapsed} engine=google_gtx '
                f'cached={cached} fallback={fallback} total={total} completed={completed} failed={failed} resumed={resumed}')

    def test_statistics_count_only_strict_records_and_keep_denominators(self):
        tail = '\n'.join([self.metric(elapsed=100, cached=1), self.metric(elapsed=300, fallback='auth'),
                         self.metric(status='partial', elapsed=200, total=3, completed=2, failed=1, resumed=1),
                         self.metric(status='cancelled', elapsed=400, completed=0, failed=1),
                         'detail=' + self.metric(), self.metric() + ' secret=' + PRIVATE])
        stats = bundle.translation_statistics(tail)
        self.assertEqual(4, stats['samples'])
        self.assertEqual({'ok': 2, 'partial': 1, 'failed': 0, 'cancelled': 1, 'timeout': 0}, stats['statusCounts'])
        self.assertEqual({'average': 250, 'p95': 400, 'maximum': 400}, stats['elapsedMs'])
        self.assertEqual((1, 1, 1), (stats['cacheHits'], stats['fallbackRequests'], stats['resumedSegments']))

    def test_invalid_and_out_of_range_metrics_are_ignored(self):
        lines = [self.metric(elapsed=7200001), self.metric(completed=2, total=1), self.metric(resumed=2),
                 self.metric(total=201), self.metric(status=PRIVATE)]
        stats = bundle.translation_statistics('\n'.join(lines))
        self.assertEqual(0, stats['samples'])
        self.assertEqual({'average': None, 'p95': None, 'maximum': None}, stats['elapsedMs'])

    def test_archive_reconstructs_only_typed_allowlisted_metadata(self):
        report = {
            'repo': PRIVATE, 'status': 'ok', 'commandLine': PRIVATE, 'secret_key': PRIVATE,
            'residents': {'ahk': {'status': 'running', 'pids': [123], 'path': PRIVATE}, PRIVATE: {'status': 'running'}},
            'configs': {'translate': {'status': 'ok', 'engine': 'tencent', 'target_language': 'zh', 'source_language': PRIVATE,
                                      'fallback_on_auth_error': True, 'long_text_enabled': True, 'secret_key': PRIVATE},
                        'tts': {'status': 'ok', 'engine': 'auto', 'zh_voice': PRIVATE}},
            'modules': {'tts': {'status': 'ok', 'pythonVersion': '3.14.0', 'selectedPythonW': PRIVATE,
                                'packages': {'edge-tts': '7.2.7', 'private-package': PRIVATE, 'aiohttp': PRIVATE},
                                'integrity': 'medium', 'tempWritable': True}},
            'logs': {'translate': {'status': 'available', 'path': PRIVATE, 'raw': PRIVATE,
                                   'lastFailure': {'status': 'fail', 'kind': 'network', 'detail': PRIVATE, 'atLocal': PRIVATE},
                                   'lastTerminalEvent': {'status': 'ok', 'engine': 'google_gtx', 'cached': True, 'text': PRIVATE},
                                   'statistics': {**bundle.translation_statistics(self.metric()), 'private': PRIVATE}},
                     'startup': {'raw': PRIVATE}},
        }
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / 'support.zip'
            bundle.write_bundle(destination, report)
            with zipfile.ZipFile(destination) as archive:
                self.assertEqual({'summary.json', 'README.txt'}, set(archive.namelist()))
                exported = ''.join(archive.read(name).decode('utf-8') for name in archive.namelist())
                self.assertNotIn(PRIVATE, exported)
                safe = json.loads(archive.read('summary.json'))
                self.assertEqual({'status': 'running'}, safe['residents']['ahk'])
                self.assertEqual({'edge-tts': '7.2.7'}, safe['modules']['tts']['packages'])
                self.assertEqual('network', safe['logs']['translate']['lastFailure']['kind'])
                self.assertEqual(1, safe['logs']['translate']['statistics']['samples'])

    def test_existing_destination_is_never_overwritten_or_deleted(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'existing.zip'; path.write_bytes(b'keep this')
            with self.assertRaises(FileExistsError):
                bundle.write_bundle(path, {})
            self.assertEqual(b'keep this', path.read_bytes())

    def test_malformed_nested_values_do_not_escape_to_the_bundle(self):
        safe = bundle.redact_report({'configs': ['private'], 'modules': {'tts': True}, 'logs': {'translate': {'statistics': ['private']}}})
        self.assertNotIn('private', json.dumps(safe))


if __name__ == '__main__':
    unittest.main()

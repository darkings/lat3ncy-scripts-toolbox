"""Real fallback decisions retain bounded metadata for each attempted engine."""
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import ssl
import unittest
import urllib.error
from unittest import mock

import engine_trace as et
import probe_google as probe
import translate as tr
from test_translate import TranslateTestBase


class EngineTraceTests(TranslateTestBase):
    def trace_cfg(self, **extra):
        self.trace_file = self.work_dir / 'request.trace'
        cfg = {'fallback_without_credentials': True, '_engine_trace': et.EngineTrace(str(self.trace_file), '42')}
        cfg.update(extra)
        return cfg

    def read_trace(self):
        return dict(line.split('=', 1) for line in self.trace_file.read_text('utf-8').splitlines())

    def test_wrapped_failure_types_are_classified_without_messages(self):
        http = ValueError('PRIVATE_HTTP_BODY')
        http.__cause__ = urllib.error.HTTPError('https://private/?q=SOURCE', 429, 'PRIVATE', {}, None)
        self.addCleanup(http.__cause__.close)
        for error, expected in ((urllib.error.URLError(ssl.SSLEOFError('PRIVATE')), 'tls'),
                                (ssl.SSLCertVerificationError('PRIVATE'), 'tls'),
                                (urllib.error.URLError(TimeoutError('PRIVATE')), 'timeout'),
                                (http, 'http'), (OSError('PRIVATE'), 'network'),
                                (ValueError('PRIVATE'), 'response'), (RuntimeError('PRIVATE'), 'internal')):
            self.assertEqual(expected, et.failure_kind(error))
        cycle = RuntimeError('PRIVATE'); cycle.__cause__ = cycle
        self.assertEqual('internal', et.failure_kind(cycle))

    def test_google_tls_failure_is_visible_after_missing_tencent_credentials(self):
        cfg = self.trace_cfg()
        def fake(name, *args):
            if name == 'google_gtx':
                raise urllib.error.URLError(ssl.SSLEOFError('PRIVATE_KEY_AND_SOURCE'))
            return '译文'
        with mock.patch.object(tr, 'call_engine', side_effect=fake):
            result = tr.translate_with_cache('tencent', 'PRIVATE_SOURCE', 'en-zh', 4, cfg)
        self.assertEqual(('mymemory', 'credentials'), (result.engine, result.fallback_reason))
        trace = self.read_trace()
        self.assertEqual('0,0,0,1,0,credentials', trace['route_tencent'])
        self.assertTrue(trace['route_google_gtx'].startswith('1,1,0,0,'))
        self.assertTrue(trace['route_google_gtx'].endswith(',tls'))
        self.assertTrue(trace['route_mymemory'].startswith('1,0,0,0,'))
        self.assertNotIn('PRIVATE', self.trace_file.read_text('utf-8'))

    def test_strict_auth_failure_is_recorded_without_enabling_fallback(self):
        cfg = self.trace_cfg(**self.tencent_cfg())
        with mock.patch.object(tr, 'call_engine', side_effect=tr.AuthError('PRIVATE')) as call:
            with self.assertRaises(tr.AuthError):
                tr.translate_with_cache('tencent', 'hello', 'en-zh', 4, cfg)
        self.assertEqual(1, call.call_count)
        self.assertTrue(self.read_trace()['route_tencent'].endswith(',auth'))

    def test_cooldown_skip_does_not_erase_the_actual_auth_failure(self):
        cfg = self.trace_cfg(**self.tencent_cfg(), fallback_on_auth_error=True)
        def fake(name, *args):
            if name == 'tencent': raise tr.AuthError('PRIVATE')
            return '译文'
        with mock.patch.object(tr, 'call_engine', side_effect=fake):
            tr.translate_with_cache('tencent', 'one', 'en-zh', 4, cfg)
            tr.translate_with_cache('tencent', 'two', 'en-zh', 4, cfg)
        values = self.read_trace()['route_tencent'].split(',')
        self.assertEqual(['1', '1', '0', '1'], values[:4])
        self.assertEqual('auth', values[-1])

    def test_cache_hit_is_not_counted_as_a_network_attempt(self):
        cfg = self.trace_cfg()
        tr.cache_put('google_gtx', 'en-zh', 'hello', 'cached translation', cfg)
        with mock.patch.object(tr, 'call_engine', side_effect=AssertionError('cache must win')):
            result = tr.translate_with_cache('google_gtx', 'hello', 'en-zh', 4, cfg)
        self.assertTrue(result.cached)
        self.assertEqual('0,0,1,0,0,none', self.read_trace()['route_google_gtx'])

    def test_trace_write_failure_cannot_fail_a_usable_translation(self):
        cfg = self.trace_cfg()
        with mock.patch.object(et.os, 'replace', side_effect=PermissionError('PRIVATE')), mock.patch.object(tr, 'call_engine', return_value='译文'):
            result = tr.translate_with_cache('google_gtx', 'hello', 'en-zh', 4, cfg)
        self.assertEqual('译文', result.text)
        self.assertEqual([], list(self.work_dir.glob('*.tmp')))

    def test_long_segments_share_one_bounded_trace(self):
        trace = self.work_dir / 'long.trace'
        def fake(name, text, *args):
            if name == 'google_gtx' and text.startswith('B'):
                raise ssl.SSLEOFError('PRIVATE')
            return '译文'
        _, fields, _, _ = self.invoke('A' * 40 + 'B' * 40, self.config_body(engine='google_gtx', max_chars=40), fake,
            extra_args=('--long-text', '--request-id', '42', '--trace-file', str(trace)))
        self.assertEqual('ok', fields['status'])
        raw = trace.read_text('utf-8')
        self.assertIn('route_google_gtx=2,1,0,0,', raw)
        self.assertIn('route_mymemory=1,0,0,0,', raw)
        self.assertNotIn('PRIVATE', raw)

    def test_trace_requires_valid_owner_and_cannot_overwrite_task_or_config(self):
        trace = self.work_dir / 'invalid.trace'
        with mock.patch.object(tr, 'call_engine') as call:
            _, fields, _, _ = self.invoke('hello', self.config_body(engine='google_gtx'),
                                          extra_args=('--trace-file', str(trace)))
        self.assertEqual('config', fields['code']); call.assert_not_called()
        self.assertFalse(trace.exists())
        config = self.write_config(self.config_body(engine='google_gtx'))
        before = config.read_bytes()
        output = self.work_dir / 'result.txt'
        self.assertEqual(0, tr.main(['--text', 'hello', '--config', str(config), '--output-file', str(output),
                                    '--request-id', '42', '--trace-file', str(config)]))
        self.assertEqual(before, config.read_bytes())
        self.assertIn('code=config', output.read_text('utf-8'))

    def test_trace_keys_counts_and_file_size_are_bounded(self):
        cfg = self.trace_cfg(); trace = cfg['_engine_trace']
        for _ in range(205):
            trace.record('google_gtx', 'failed', kind='tls', elapsed_ms=7200000)
        before = self.trace_file.read_bytes()
        trace.record('PRIVATE_ENGINE', 'failed', kind='tls')
        trace.record('google_gtx', 'failed', kind='PRIVATE_KIND')
        self.assertEqual(before, self.trace_file.read_bytes())
        self.assertLess(len(before), 1024)
        self.assertIn('route_google_gtx=200,200,0,0,7200000,tls', before.decode())
        with self.assertRaises(ValueError):
            et.EngineTrace(str(self.work_dir/'other'), '42\nPRIVATE')


class GoogleProbeTests(TranslateTestBase):
    def test_network_requires_explicit_flag_and_valid_timeout(self):
        for args in ([], ['--online', '--timeout', 'nan'], ['--online', '--timeout', '99']):
            with mock.patch.object(probe, 'run_probe') as call, redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                probe.main(args)
            call.assert_not_called()

    def test_existing_report_is_rejected_before_any_network(self):
        path = self.work_dir / 'existing.json'; path.write_text('keep')
        with mock.patch.object(probe, 'run_probe') as call, redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            probe.main(['--online', '--output', str(path)])
        call.assert_not_called(); self.assertEqual('keep', path.read_text())

    def test_probe_retains_only_safe_failure_metadata_and_does_not_load_keys(self):
        output = self.work_dir / 'probe.json'
        with mock.patch.object(tr, 'translate_google_gtx', side_effect=['译文', urllib.error.URLError(ssl.SSLEOFError('PRIVATE_SOURCE_KEY_URL'))]), \
             mock.patch.object(probe.urllib.request, 'getproxies', return_value={'https': 'http://PRIVATE_SOURCE_KEY_URL'}), \
             mock.patch.object(tr, 'load_config', side_effect=AssertionError('no private configs')), \
             mock.patch.object(tr, 'read_user_env', side_effect=AssertionError('no credentials')), redirect_stdout(io.StringIO()):
            result = probe.main(['--online', '--output', str(output)])
        report = json.loads(output.read_text('utf-8'))
        self.assertEqual(1, result)
        self.assertEqual('intermittent', report['status'])
        self.assertEqual('tls', report['attempts'][1]['kind'])
        self.assertTrue(report['proxyConfigured'])
        self.assertNotIn('PRIVATE', output.read_text('utf-8'))


if __name__ == '__main__':
    unittest.main()

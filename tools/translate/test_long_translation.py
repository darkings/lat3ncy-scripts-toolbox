"""Long translation behavior: lossless limits, progress, bounded retries, privacy."""
import json
import random
import unittest
import urllib.error
from unittest import mock

from test_translate import TranslateTestBase
import translate as tr
import long_translation as lt


class LongTranslationTests(TranslateTestBase):
    def test_split_is_lossless_and_honors_unicode_budgets(self):
        randomizer = random.Random(42)
        samples = ['第一段。\r\n\r\n第二段😀末尾', 'hello world.\nnext sentence! ' * 50,
                   ''.join(randomizer.choice('中ab😀\n\t 。，') for _ in range(2000))]
        for text in samples:
            for chars, byte_limit in ((7, 12), (100, 480), (2000, 4000)):
                with self.subTest(chars=chars, bytes=byte_limit):
                    pieces = lt.split_segments(text, max_chars=chars, max_bytes=byte_limit)
                    self.assertEqual(text, ''.join(pieces))
                    self.assertTrue(all(0 < len(piece) <= chars and len(piece.encode('utf-8')) <= byte_limit for piece in pieces))

    def test_paragraph_boundaries_and_whitespace_only_pieces_survive(self):
        text = 'Hello\n\n' + ' ' * 12 + '\nWorld'
        result = lt.join_results([text[:7], text[7:19], text[19:]],
                                 [{'text': '你好'}, {'text': ' '}, {'text': '世界'}])
        self.assertEqual('你好\n\n' + ' ' * 12 + '\n世界', result)

    def test_hard_splits_do_not_glue_english_words_or_modify_identity_text(self):
        _, fields, _, _ = self.invoke('中' * 80, self.config_body(engine='google_gtx', max_chars=40), lambda *args: 'English words',
            extra_args=('--long-text',))
        self.assertEqual('English words English words', fields['text'])
        _, fields, _, _ = self.invoke('a' * 80, 'source_language="en"\ntarget_language="en"\n' + self.config_body(engine='google_gtx', max_chars=40),
            extra_args=('--long-text',))
        self.assertEqual('a' * 80, fields['text'])

    def test_progress_is_metadata_only_and_terminal_text_is_complete(self):
        events = []
        original = tr.write_output
        def observe(path, status, **fields):
            events.append((status, fields.copy()))
            original(path, status, **fields)
        with mock.patch.object(tr, 'write_output', side_effect=observe):
            rc, fields, raw, _ = self.invoke('A' * 40 + 'B' * 40,
                self.config_body(engine='google_gtx', max_chars=40), lambda *args: '完整译文😀',
                extra_args=('--long-text', '--request-id', '42'))
        self.assertEqual(0, rc)
        self.assertEqual(('ok', '2', '2', '0'), (fields['status'], fields['completed'], fields['total'], fields['failed']))
        self.assertEqual('完整译文😀完整译文😀', fields['text'])
        self.assertTrue(raw.endswith('text=完整译文😀完整译文😀\n'))
        progress = [item for status, item in events if status == 'progress']
        self.assertEqual(['0', '1', '2'], [item['completed'] for item in progress])
        self.assertTrue(all(item['request_id'] == '42' and 'text' not in item for item in progress))
        self.assertNotIn('A' * 40, json.dumps(progress))

    def test_retry_only_failed_segment_even_without_translation_cache(self):
        source = 'A' * 40 + 'B' * 40 + 'C' * 40
        checkpoint = self.work_dir / 'request.resume.json'
        options = ('--long-text', '--resume-file', str(checkpoint))
        calls = []
        def first(name, text, *args):
            calls.append((name, text))
            if text.startswith('B'):
                raise urllib.error.URLError('PRIVATE_PROVIDER_RESPONSE')
            return '第一译文' if text.startswith('A') else '第三译文'
        _, fields, raw, _ = self.invoke(source, self.config_body(engine='google_gtx', max_chars=40), first, extra_args=options)
        self.assertEqual(('partial', '2', '1'), (fields['status'], fields['completed'], fields['failed']))
        self.assertIn('第 2 段翻译失败', fields['text'])
        self.assertNotIn('PRIVATE_PROVIDER_RESPONSE', raw)
        self.assertNotIn(source, checkpoint.read_text())
        calls.clear()
        def second(name, text, *args):
            calls.append((name, text))
            return '第二译文'
        with mock.patch.object(tr, 'cache_get', return_value=None):
            _, fields, _, _ = self.invoke(source, self.config_body(engine='google_gtx', max_chars=40), second, extra_args=options)
        self.assertEqual([('google_gtx', 'B' * 40)], calls)
        self.assertEqual(('ok', '2', '第一译文第二译文第三译文'), (fields['status'], fields['resumed'], fields['text']))

    def test_target_change_rejects_old_checkpoint(self):
        path = self.work_dir / 'resume.json'
        lt.save_checkpoint(str(path), 'old-direction', [{'text': '旧译文', 'engine': 'google_gtx', 'cached': False, 'fallback_reason': ''}])
        _, fields, _, _ = self.invoke('hello', self.config_body(engine='google_gtx'), lambda *args: '新译文',
            extra_args=('--long-text', '--resume-file', str(path)))
        self.assertEqual(('0', '新译文'), (fields['resumed'], fields['text']))

    def test_free_fallback_uses_its_own_byte_limit(self):
        calls = []
        def fake(name, text, *args):
            calls.append((name, len(text.encode('utf-8'))))
            if name == 'google_gtx':
                raise TimeoutError('private')
            self.assertLessEqual(len(text.encode('utf-8')), 480)
            return '保底译文'
        _, fields, _, _ = self.invoke('x' * 1200, self.config_body(engine='google_gtx'), fake, extra_args=('--long-text',))
        self.assertEqual('ok', fields['status'])
        self.assertEqual('mymemory', fields['engine'])
        self.assertEqual([('google_gtx', 1200), ('mymemory', 480), ('mymemory', 480), ('mymemory', 240)], calls)

    def test_total_deadline_leaves_unfinished_segments_retryable(self):
        clock = [100.0]
        def fake(*args):
            clock[0] = 221.0
            return '首段完成'
        with mock.patch.object(tr.time, 'monotonic', side_effect=lambda: clock[0]):
            _, fields, _, _ = self.invoke('A' * 40 + 'B' * 40, self.config_body(engine='google_gtx', max_chars=40), fake,
                extra_args=('--long-text',))
        self.assertEqual(('partial', 'timeout', '1', '1'), (fields['status'], fields['code'], fields['completed'], fields['failed']))

    def test_total_input_and_segment_count_are_bounded_before_network(self):
        for text, max_chars in (('x' * 20001, 2000), ('x' * 201, 1)):
            with mock.patch.object(tr, 'call_engine') as call:
                _, fields, _, _ = self.invoke(text, self.config_body(engine='google_gtx', max_chars=max_chars), extra_args=('--long-text',))
            self.assertEqual('too_long', fields['code']); call.assert_not_called()

    def test_long_mode_is_explicit_and_invalid_flag_is_a_config_error(self):
        _, fields, _, _ = self.invoke('x' * 41, self.config_body(engine='google_gtx', max_chars=40))
        self.assertEqual('too_long', fields['code'])
        _, fields, _, _ = self.invoke('hello', 'long_text_enabled="true"\n' + self.config_body(engine='google_gtx'))
        self.assertEqual('config', fields['code'])

    def test_malformed_or_oversized_checkpoint_is_not_trusted(self):
        path = self.work_dir / 'resume.json'
        for raw in ('{', '[]', 'x' * (lt.MAX_CHECKPOINT_BYTES + 1), json.dumps({'version': 1, 'key': 'key', 'results': [{'text': 'private', 'engine': 'arbitrary'}]})):
            path.write_text(raw)
            self.assertEqual([None], lt.load_checkpoint(str(path), 'key', 1))


if __name__ == '__main__':
    unittest.main()

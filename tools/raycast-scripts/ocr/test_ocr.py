"""Offline notification/error tests; OCR models and optional image packages are stubbed."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("toolbox_ocr", Path(__file__).with_name("ocr.py"))
ocr = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {
    "PIL": types.SimpleNamespace(Image=types.SimpleNamespace(Image=object), ImageGrab=Mock()),
    "tkinter": types.SimpleNamespace(TclError=type("TclError", (Exception,), {})),
}):
    spec.loader.exec_module(ocr)


class NotificationTests(unittest.TestCase):
    def test_text_extraction_has_no_clipboard_notification_or_file_delivery(self):
        image = types.SimpleNamespace(size=(320, 100))
        engine = Mock(return_value=([([], 'fixed OCR', .99), ([], '中文|😀', .99)], None))
        with patch.dict(sys.modules, {'numpy': types.SimpleNamespace(array=lambda value: value)}), \
             patch.object(ocr, '_debug'), patch.object(ocr, 'copy_to_clipboard') as copy, \
             patch.object(ocr, 'notify') as notify, patch.object(ocr, 'write_result') as write:
            self.assertEqual('fixed OCR\n中文|😀', ocr.extract_text(engine, image))
        copy.assert_not_called(); notify.assert_not_called(); write.assert_not_called()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.patches = [patch.object(ocr, "SCRIPT_DIR", self.temp.name),
                        patch.object(ocr, "_debug"),
                        patch.object(ocr, "_resolve_toast_script", return_value=Path("toast.ps1"))]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def test_detached_runner_is_owned_by_child_and_unique(self):
        runners = []
        def start(args, **kwargs):
            path = Path(args[args.index("-File") + 1])
            self.assertTrue(path.is_file())
            self.assertEqual(subprocess.DEVNULL, kwargs["stdout"])
            runners.append(path)
            return types.SimpleNamespace(pid=123)
        with patch.object(ocr.subprocess, "Popen", side_effect=start):
            ocr.notify("progress", "first", wait=False)
            ocr.notify("progress", "second", wait=False)
        self.assertNotEqual(*runners)
        for path in runners:
            self.assertTrue(path.is_file())
            self.assertIn("Remove-Item -LiteralPath $PSCommandPath", path.read_text())

    def test_failed_spawn_cleans_runner(self):
        with patch.object(ocr.subprocess, "Popen", side_effect=OSError("spawn failed")):
            ocr.notify("title", "message", wait=False)
        self.assertEqual([], list(Path(self.temp.name).glob(".toast-*.ps1")))

    def test_synchronous_notification_cleans_runner(self):
        proc = Mock(pid=123, returncode=0)
        proc.communicate.return_value = (b"", b"")
        with patch.object(ocr.subprocess, "Popen", return_value=proc):
            ocr.notify("title", "message")
        self.assertEqual([], list(Path(self.temp.name).glob(".toast-*.ps1")))

    def test_result_write_failure_does_not_suppress_error_toast(self):
        with patch.object(sys, "argv", ["ocr.py", "--result-file", "result.txt", "--notify-on-done"]), \
                patch.object(ocr, "run_ocr_from_clipboard", side_effect=RuntimeError("model unavailable")), \
                patch.object(ocr, "write_result", side_effect=PermissionError("denied")), \
                patch.object(ocr, "notify") as notify:
            self.assertEqual(1, ocr.main())
        notify.assert_called_once()
        self.assertIn("model unavailable", notify.call_args.args[1])

    def test_success_notification_follows_copy_even_when_diagnostic_write_fails(self):
        events = []
        image = types.SimpleNamespace(size=(320, 100))
        engine = Mock(return_value=([([], "fixed OCR text", .99)], None))
        def notify(title, message, **kwargs):
            self.assertIn("已复制", title)
            self.assertEqual(["copy"], events)
            events.append("notify")
        def write(*args):
            events.append("write")
            raise PermissionError("diagnostic path unavailable")
        with patch.dict(sys.modules, {"numpy": types.SimpleNamespace(array=lambda value: value)}), \
             patch.object(ocr, "copy_to_clipboard", side_effect=lambda text: events.append("copy")), \
             patch.object(ocr, "notify", side_effect=notify), patch.object(ocr, "write_result", side_effect=write):
            self.assertEqual(0, ocr.recognize(engine, image, "result.txt", notify_on_done=True))
        self.assertEqual(["copy", "notify", "write"], events)

    def test_copy_failure_reports_only_error_and_returns_nonzero(self):
        image = types.SimpleNamespace(size=(320, 100))
        engine = Mock(return_value=([([], "fixed OCR text", .99)], None))
        result = Path(self.temp.name)/"result.txt"
        def run(**kwargs):
            return ocr.recognize(engine, image, kwargs["result_file"], notify_on_done=kwargs["notify_on_done"])
        with patch.dict(sys.modules, {"numpy": types.SimpleNamespace(array=lambda value: value)}), \
             patch.object(sys, "argv", ["ocr.py", "--no-screenshot", "--result-file", str(result), "--notify-on-done"]), \
             patch.object(ocr, "run_ocr_from_clipboard", side_effect=run), \
             patch.object(ocr, "copy_to_clipboard", side_effect=RuntimeError("clipboard unavailable")), \
             patch.object(ocr, "notify") as notify:
            self.assertEqual(1, ocr.main())
        notify.assert_called_once()
        self.assertNotIn("已复制", notify.call_args.args[0])
        self.assertIn("clipboard unavailable", notify.call_args.args[1])
        self.assertTrue(result.read_text("utf-8").startswith("ERROR:"))


if __name__ == "__main__":
    unittest.main()

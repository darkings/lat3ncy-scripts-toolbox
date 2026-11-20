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


if __name__ == "__main__":
    unittest.main()

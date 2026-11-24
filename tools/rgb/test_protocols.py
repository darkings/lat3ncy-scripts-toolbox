"""Offline subprocess/TCP tests. Never enumerate HID, capture screens or connect to SDK."""
import importlib.util
import argparse
from contextlib import nullcontext, redirect_stderr
import io
import json
import tempfile
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import time
import types
import unittest
from unittest.mock import MagicMock, Mock, patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("toolbox_ambient", ROOT / "ambient.py")
ambient = importlib.util.module_from_spec(spec)
fake_hid = types.SimpleNamespace(**{name: Mock() for name in (
    "build_direct_report", "enumerate_hi75", "open_hi75", "send_feature_reports")})
with patch.dict(sys.modules, {"numpy": types.SimpleNamespace(), "hi75": fake_hid}):
    spec.loader.exec_module(ambient)
from openrgb.network import NetworkClient
from openrgb import utils


class EntryGuardTests(unittest.TestCase):
    def test_disabled_feature_starts_no_writer_or_controller(self):
        with patch.object(sys, 'argv', ['ambient.py']), patch.object(ambient, 'module_enabled', return_value=False), patch.object(ambient, 'hardware_writer') as writer, patch.object(ambient, '_run') as run:
            self.assertEqual(0, ambient.main()); writer.assert_not_called(); run.assert_not_called()

    def test_busy_or_unverified_writer_never_reaches_capture_or_controllers(self):
        RgbBusy = ambient.RgbBusy
        with patch.object(sys, 'argv', ['ambient.py']), patch.object(ambient, 'module_enabled', return_value=True), patch.object(ambient, 'hardware_writer', side_effect=RgbBusy('rgb-writer-busy')), patch.object(ambient, '_run') as run:
            self.assertEqual(2, ambient.main()); run.assert_not_called()
        with patch.object(sys, 'argv', ['ambient.py']), patch.object(ambient, 'module_enabled', return_value=True), patch.object(ambient, 'hardware_writer', return_value=nullcontext()), patch.object(ambient, 'verify_hardware_admission', side_effect=RgbBusy('rgb-owner-unavailable')), patch.object(ambient, '_run') as run:
            self.assertEqual(2, ambient.main()); run.assert_not_called()

    def test_conflicting_modes_fail_before_any_hardware_guard(self):
        for flags in (['--dry-run','--lights-off'], ['--bench','0','--list-devices'], ['--lights-off','--list-devices'], ['--bench-capture']):
            with patch.object(sys, 'argv', ['ambient.py', *flags]), patch.object(ambient, 'hardware_writer') as writer, patch.object(ambient, '_run') as run, redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error: ambient.main()
                self.assertEqual(2, error.exception.code); writer.assert_not_called(); run.assert_not_called()

    def test_zero_benchmark_is_synthetic_without_capture_or_devices(self):
        args=argparse.Namespace(config='isolated-missing.toml',fps=None,no_openrgb=False,no_hi75=False,list_devices=False,lights_off=False,bench=0,bench_capture=False)
        with patch.object(ambient, 'load_config', return_value={}), patch.object(ambient, 'np', types.SimpleNamespace(zeros=Mock(return_value=MagicMock()), uint8='unused')), patch.object(ambient, 'process_frame', return_value=(None,(1,2,3),1)), patch.object(ambient.time, 'perf_counter', side_effect=[0,1]), patch.object(ambient, 'create_capture') as capture, patch.object(ambient, '_build_controllers') as controllers:
            self.assertEqual(0, ambient._run(args)); capture.assert_not_called(); controllers.assert_not_called()
        with patch.object(sys, 'argv', ['ambient.py','--bench','0']), patch.object(ambient, 'hardware_writer', return_value=nullcontext()) as writer, patch.object(ambient, 'verify_hardware_admission') as admission, patch.object(ambient, '_run', return_value=0):
            self.assertEqual(0, ambient.main()); writer.assert_called_once_with(enabled=False); admission.assert_not_called()

    def test_own_quit_request_does_not_consume_legacy_or_foreign_flags(self):
        from rgb_runtime import quit_flag_name
        reader=ambient.quit_requested
        with tempfile.TemporaryDirectory() as directory, patch.object(ambient, '_state_dir', return_value=Path(directory)):
            state=Path(directory); legacy=state/'rgb-quit.flag';foreign=state/quit_flag_name(state/'other-rgb')
            legacy.write_text('keep');foreign.write_text('keep')
            self.assertFalse(ambient.consume_quit_request())
            data={'version':1,'id':'a'*32,'expires_utc':int(time.time())+10,'targets':[{'pid':81001,'start_ticks':'123456'}]}
            ambient.quit_request_flag().write_text(json.dumps(data))
            with patch.object(ambient, 'quit_requested', side_effect=lambda path: reader(path,identity=(81001,'123456'))):
                self.assertTrue(ambient.consume_quit_request())
            self.assertTrue(legacy.exists());self.assertTrue(foreign.exists());self.assertTrue(ambient.quit_request_flag().exists())


class HelperProtocolTests(unittest.TestCase):
    def helper(self, code):
        wrapper = ambient.Hi75Wrap(enabled=False)
        wrapper.proc = subprocess.Popen([sys.executable, "-u", "-c", code],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
        wrapper._start_stdout_reader(wrapper.proc)
        self.addCleanup(wrapper._kill_exe)
        return wrapper

    def test_incomplete_line_obeys_deadline(self):
        wrapper = self.helper("import sys,time;sys.stdout.write('READY');sys.stdout.flush();time.sleep(60)")
        # A blocked reader thread must not block the caller's deadline.
        started = time.monotonic()
        self.assertIsNone(wrapper._read_until("READY", 0.05))
        self.assertLess(time.monotonic() - started, 1.5)
        self.assertIsNone(wrapper.proc.poll())

    def test_ready_then_rpc_and_eof(self):
        wrapper = self.helper("import sys;print('noise');print('READY');sys.stdin.readline();print('OK color')")
        self.assertEqual("READY", wrapper._read_until("READY", 5))
        self.assertEqual("OK color", wrapper._rpc("SET ff0000"))
        self.assertIsNone(wrapper._read_until("OK", 5))

    def test_rpc_timeout_discards_process_and_late_replies(self):
        wrapper = self.helper("import time;time.sleep(60)")
        process = wrapper.proc
        with patch.object(wrapper, "_read_until", return_value=None):
            with self.assertRaises(TimeoutError):
                wrapper._rpc("OFF")
        self.assertIsNone(wrapper.proc)
        self.assertIsNotNone(process.poll())
        self.assertIsNone(wrapper._stdout_lines)


class SdkProtocolTests(unittest.TestCase):
    def client(self):
        reader, writer = socket.socketpair()
        self.addCleanup(reader.close)
        self.addCleanup(writer.close)
        client = NetworkClient.__new__(NetworkClient)
        client.sock = reader
        client.lock = threading.Lock()
        client.lock.acquire()
        client._protocol_version = 4
        client.callback = Mock()
        return client, writer

    def test_header_and_body_accept_fragmented_reads(self):
        client, writer = self.client()
        raw = struct.pack('ccccIII', b'O', b'R', b'G', b'B', 0,
                          utils.PacketType.REQUEST_CONTROLLER_COUNT, 4) + struct.pack('I', 3)
        class Fragments:
            def recv(self, count):
                return source.recv(min(count, 1))
            def close(self):
                source.close()
        source = client.sock
        client.sock = Fragments()
        writer.sendall(raw)
        client.read()
        client.callback.assert_called_once_with(0, utils.PacketType.REQUEST_CONTROLLER_COUNT, 3)
        self.assertFalse(client.lock.locked())

    def test_eof_in_each_body_type_disconnects_without_spinning(self):
        for kind in (utils.PacketType.REQUEST_CONTROLLER_COUNT, utils.PacketType.REQUEST_CONTROLLER_DATA,
                     utils.PacketType.REQUEST_PROTOCOL_VERSION, utils.PacketType.REQUEST_PROFILE_LIST,
                     utils.PacketType.REQUEST_PLUGIN_LIST, utils.PacketType.PLUGIN_SPECIFIC):
            with self.subTest(kind=kind):
                client, writer = self.client()
                writer.sendall(struct.pack('ccccIII', b'O', b'R', b'G', b'B', 0, kind, 4) + b'\x01')
                writer.close()
                with self.assertRaises(utils.OpenRGBDisconnected):
                    client.read()
                self.assertFalse(client.connected)
                self.assertFalse(client.lock.locked())

    def test_eof_in_header_disconnects(self):
        client, writer = self.client()
        writer.sendall(b'OR')
        writer.close()
        with self.assertRaises(utils.OpenRGBDisconnected):
            client.read()
        self.assertFalse(client.connected)


if __name__ == "__main__":
    unittest.main()

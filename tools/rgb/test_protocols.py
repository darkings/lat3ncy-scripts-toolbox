"""Offline subprocess/TCP tests. Never enumerate HID, capture screens or connect to SDK."""
import importlib.util
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("toolbox_ambient", ROOT / "ambient.py")
ambient = importlib.util.module_from_spec(spec)
fake_hid = types.SimpleNamespace(**{name: Mock() for name in (
    "build_direct_report", "enumerate_hi75", "open_hi75", "send_feature_reports")})
with patch.dict(sys.modules, {"numpy": types.SimpleNamespace(), "hi75": fake_hid}):
    spec.loader.exec_module(ambient)
from openrgb.network import NetworkClient
from openrgb import utils


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

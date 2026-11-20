"""Opt-in real OCR / TTS probes using synthetic fixtures, never desktop content.

Run OCR with its dedicated interpreter. TTS writes files without audio playback;
the separate playback mode explicitly exercises MCI using silent PCM fixtures.
The guarded ocr-clipboard mode explicitly uses synthetic clipboard data.
No resident, task, power setting or device connection is changed.
"""
from __future__ import annotations

import argparse
import asyncio
import ctypes
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str((ROOT / relative).parent))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


def versions(names: list[str]) -> dict:
    result = {}
    for name in names:
        try:
            result[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            result[name] = None
    return result


def ocr_probe(output: Path) -> dict:
    from PIL import Image, ImageDraw, ImageFont
    ocr = load_module('toolbox_real_ocr', 'tools/raycast-scripts/ocr/ocr.py')
    ocr._debug = lambda *_: None
    ocr._SILENT_MODE = True
    handoffs = []
    ocr.copy_to_clipboard = handoffs.append  # Only clipboard delivery is replaced.
    image = Image.new('RGB', (1100, 230), 'white')
    font = ImageFont.truetype(str(Path(os.environ['SystemRoot']) / 'Fonts/arial.ttf'), 48)
    ImageDraw.Draw(image).multiline_text((35, 35), 'Toolbox OCR 2026\nLatency test 12345', font=font, fill='black', spacing=20)
    image.save(output / 'ocr-fixture.png')
    start = time.monotonic()
    engine = ocr.load_engine()
    result_file = output / 'ocr-result.txt'
    code = ocr.recognize(engine, image, result_file=str(result_file))
    text = result_file.read_text('utf-8')
    compact = ''.join(text.lower().split())
    recognized = code == 0 and all(token in compact for token in ('toolbox', 'ocr', '2026', 'latency', '12345')) and handoffs == [text]
    blank = output / 'ocr-blank.txt'
    handoffs.clear()
    blank_code = ocr.recognize(engine, Image.new('RGB', (600, 200), 'white'), result_file=str(blank))
    blank_ok = blank_code == 0 and blank.read_text('utf-8') == '' and not handoffs
    return {'status': 'passed' if recognized and blank_ok else 'failed', 'realModel': True,
            'recognizedFixture': recognized, 'blankImage': blank_ok,
            'clipboard': 'adapter captured handoff; real clipboard not touched',
            'seconds': round(time.monotonic()-start, 2),
            'packages': versions(['rapidocr-onnxruntime', 'onnxruntime', 'Pillow', 'numpy', 'pyperclip'])}


def ocr_clipboard_probe(output: Path) -> dict:
    """Guarded opt-in: real clipboard image -> real OCR -> real copied text."""
    from PIL import Image, ImageDraw, ImageFont
    import pyperclip
    from clipboard_fixture import copy_image, record_sequence, sequence
    ocr = load_module('toolbox_clipboard_ocr', 'tools/raycast-scripts/ocr/ocr.py')
    ocr._SILENT_MODE = True
    lease = output/'clipboard-sequence.txt'
    image = Image.new('RGB', (1100, 230), 'white')
    font = ImageFont.truetype(str(Path(os.environ['SystemRoot'])/'Fonts/arial.ttf'), 48)
    ImageDraw.Draw(image).multiline_text((35, 35), 'Toolbox OCR 2026\nLatency test 12345', font=font, fill='black', spacing=20)
    image.save(output/'input.png')
    ready, stopped = threading.Event(), threading.Event()
    errors, notifications, copies, engines = [], [], [], []
    real_copy = ocr.copy_to_clipboard
    real_load = ocr.load_engine
    real_grab = ocr.ImageGrab.grabclipboard
    def fixed_image_only():
        if not lease.exists():
            return None
        value = real_grab()
        if isinstance(value, Image.Image) and (value.size != image.size or value.convert('RGB').tobytes() != image.tobytes()):
            raise RuntimeError('Clipboard image no longer belongs to this fixture')
        return value
    ocr.ImageGrab.grabclipboard = fixed_image_only
    def audited_load():
        engine = real_load()
        engines.append(engine)
        return engine
    ocr.load_engine = audited_load
    def audited_copy(text):
        if sequence() != int(lease.read_text('ascii')):
            raise RuntimeError('Clipboard changed outside this fixture')
        real_copy(text)
        copies.append(text)
        record_sequence(lease)
    ocr.copy_to_clipboard = audited_copy
    ocr._debug = lambda message: ready.set() if message.startswith('baseline_seq=') else None
    def notification(title, message, **kwargs):
        if '已复制' in title:
            notifications.append(bool(copies) and pyperclip.paste() == copies[-1])
    ocr.notify = notification
    def inject():
        while not ready.wait(.05):
            if stopped.is_set():
                return
        if not stopped.is_set():
            try:
                copy_image(image, lease)
            except Exception as error:
                errors.append(type(error).__name__)
    thread = threading.Thread(target=inject, daemon=True)
    thread.start()
    try:
        code = ocr.run_ocr_from_clipboard(timeout_seconds=3, inject_screenshot=False,
            result_file=str(output/'result.txt'), notify_on_done=True)
    finally:
        stopped.set()
        thread.join(2)
    text = (output/'result.txt').read_text('utf-8') if (output/'result.txt').exists() else ''
    compact = ''.join(text.lower().split())
    delivered = code == 0 and not errors and all(token in compact for token in ('toolbox', '2026', '12345')) and pyperclip.paste() == text
    before = sequence()
    engine = engines[0]
    blank = ocr.recognize(engine, Image.new('RGB', (600, 200), 'white'), result_file=str(output/'blank.txt'))
    blank_ok = blank == 0 and (output/'blank.txt').read_text('utf-8') == '' and sequence() == before
    ocr.load_engine = lambda: engine
    cancel = ocr.run_ocr_from_clipboard(timeout_seconds=.3, inject_screenshot=False,
        result_file=str(output/'cancel.txt'))
    cancelled = cancel == 0 and not (output/'cancel.txt').exists() and sequence() == before
    notified = bool(notifications) and all(notifications)
    ocr.ImageGrab.grabclipboard = real_grab
    return {'status': 'passed' if delivered and blank_ok and cancelled and notified else 'failed',
        'realClipboard': True, 'imageToText': delivered, 'blankPreservedClipboard': blank_ok,
        'cancelPreservedClipboard': cancelled, 'completionAfterCopy': notified,
        'workerRestore': 'external ClipboardAll guard required', 'errors': errors}


def audio_length(path: Path) -> int:
    alias = f'toolbox_validation_{os.getpid()}'
    send = ctypes.windll.winmm.mciSendStringW
    code = send(f'open "{path}" type mpegvideo alias {alias}', None, 0, None)
    if code:
        raise RuntimeError(f'MCI open failed: {code}')
    try:
        if send(f'set {alias} time format milliseconds', None, 0, None):
            raise RuntimeError('MCI time format failed')
        result = ctypes.create_unicode_buffer(128)
        code = send(f'status {alias} length', result, len(result), None)
        if code:
            raise RuntimeError(f'MCI metadata query failed: {code}')
        return int(result.value)
    finally:
        send(f'close {alias}', None, 0, None)


def playback_probe(output: Path) -> dict:
    """Exercise real MCI with silence, then cancel a process during playback."""
    script = output/'player.py'
    script.write_text('''import sys
sys.path.insert(0, sys.argv[1])
import tts_player as tts
logger=tts.configure_logging(sys.argv[3], log_text=False)
try: code=0 if tts.play_audio_file(sys.argv[2]) else 1
finally: tts.close_logger(logger)
raise SystemExit(code)
''', encoding='ascii')
    def fixture(name, seconds):
        path = output/name
        with wave.open(str(path), 'wb') as audio:
            audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(22050)
            audio.writeframes(b'\0'*(22050*2*seconds))
        return path
    short = fixture('short-silence.wav', 1)
    command = [sys.executable, str(script), str(ROOT/'tools/tts')]
    normal = subprocess.run(command+[str(short), str(output/'normal.log')], capture_output=True,
                            timeout=10, creationflags=subprocess.CREATE_NO_WINDOW)
    long = fixture('long-silence.wav', 20)
    log = output/'cancel.log'
    child = subprocess.Popen(command+[str(long), str(log)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             creationflags=subprocess.CREATE_NO_WINDOW)
    started = False
    try:
        deadline = time.monotonic()+5
        while time.monotonic() < deadline and child.poll() is None:
            if log.exists() and '播放片段音频 (MCI)' in log.read_text('utf-8'):
                started = True; break
            time.sleep(0.025)
        was_playing = started and child.poll() is None
        if child.poll() is None:
            child.terminate()
        child.wait(timeout=5)
    finally:
        if child.poll() is None:
            child.kill(); child.wait(timeout=5)
    return {'status': 'passed' if normal.returncode == 0 and was_playing else 'failed',
            'normalPlayback': normal.returncode == 0, 'cancelledDuringPlayback': was_playing,
            'processExited': child.poll() is not None, 'audio': 'silent PCM fixtures; no speech or volume changes'}


def tts_probe(output: Path) -> dict:
    tts = load_module('toolbox_real_tts', 'tools/tts/tts_player.py')
    logger = tts.configure_logging(str(output / 'tts.log'), log_text=False)
    results = {'packages': versions(['edge-tts', 'winsdk']), 'playback': 'not performed',
               'winrt': 'installed' if importlib.util.find_spec('winsdk') or importlib.util.find_spec('winrt') else 'unavailable'}
    if results['winrt'] == 'installed':
        try:
            local = output / 'winrt.wav'
            ok = asyncio.run(asyncio.wait_for(tts.synthesize_winrt_segment(
                'Microsoft Zira', 'Toolbox validation, one two three.', str(local)), timeout=20))
            duration = 0
            if ok:
                with wave.open(str(local), 'rb') as audio:
                    duration = round(audio.getnframes()*1000/audio.getframerate())
            results['winrtFile'] = {'status': 'passed' if duration > 0 else 'failed', 'durationMs': duration}
        except Exception as error:
            results['winrtFile'] = {'status': 'failed', 'errorType': type(error).__name__}
    mp3 = output / 'edge.mp3'
    try:
        async def synthesize():
            return await asyncio.wait_for(tts.synthesize_edge_segment(
                'en-US-AriaNeural', 'Toolbox validation, one two three.',
                '+0%', '+0Hz', '+0%', str(mp3)), timeout=25)
        edge_ok = asyncio.run(synthesize())
        duration = audio_length(mp3) if edge_ok else 0
        results['edge'] = {'status': 'passed' if duration > 0 else 'failed', 'durationMs': duration,
                           'temporaryFiles': len(list(output.glob('*.tmp.*')))}
    except Exception as error:
        results['edge'] = {'status': 'failed', 'errorType': type(error).__name__,
                           'temporaryFiles': len(list(output.glob('*.tmp.*')))}
    # Exercise the actual auto routing, not just the direct online backend.
    try:
        async def auto(language='en', text='Toolbox recovery validation.', voice='Microsoft Zira'):
            events, files = [asyncio.Event()], [None]
            cache = Path(tts.get_default_cache_dir())
            await asyncio.wait_for(tts.synthesize_one_segment(
                0, language, text, voice,
                '+0%', '+0Hz', '+0%', str(cache/f'validation-auto-{language}.wav'), 'auto', events, files), timeout=30)
            return files[0], events[0].is_set()
        path, delivered = asyncio.run(auto())
        duration = audio_length(Path(path)) if path else 0
        results['autoRecovery'] = {'status': 'passed' if duration > 0 and delivered else 'failed',
                                   'format': Path(path).suffix if path else None, 'durationMs': duration,
                                   'cacheDirectory': str(Path(path).parent) if path else None}
        zh_path, zh_delivered = asyncio.run(auto('zh', '工具箱语音回退测试。', 'Microsoft Yaoyao'))
        zh_duration = audio_length(Path(zh_path)) if zh_path else 0
        results['autoRecoveryChinese'] = {'status': 'passed' if zh_duration > 0 and zh_delivered else 'failed',
                                          'format': Path(zh_path).suffix if zh_path else None, 'durationMs': zh_duration}
        # Run the real CLI orchestration/result writer, replacing only device
        # playback with a real file decoder so the probe remains inaudible.
        request_id = 'validation-' + uuid.uuid4().hex
        report = output/'managed-result.txt'
        prior_argv, prior_player, prior_sapi = sys.argv, tts.play_audio_file, tts.play_sapi_fallback
        try:
            tts.play_audio_file = lambda path: audio_length(Path(path)) > 0
            tts.play_sapi_fallback = lambda *a, **k: False
            sys.argv = [str(ROOT/'tools/tts/tts_player.py'), '--text', 'Toolbox managed recovery validation.',
                        '--request-id', request_id, '--result-file', str(report), '--task-timeout', '45']
            code = tts.main()
            record = dict(line.split('=', 1) for line in report.read_text('utf-8').splitlines())
            results['managedPipeline'] = {'status': 'passed' if code == 0 and record.get('request_id') == request_id and record.get('status') == 'success' else 'failed',
                                          'exitCode': code, 'resultVersion': record.get('version'),
                                          'playback': 'file decode adapter; no device playback'}
        finally:
            sys.argv, tts.play_audio_file, tts.play_sapi_fallback = prior_argv, prior_player, prior_sapi
            tts._TASK = None
    except Exception as error:
        results['autoRecovery'] = {'status': 'failed', 'errorType': type(error).__name__}
    finally:
        tts.close_logger(logger)
    # Exercise the same System.Speech platform used by the player's fallback,
    # directing output to a WAV rather than the user's audio endpoint.
    script = output / 'sapi-file.ps1'
    script.write_text('''param([string]$OutputPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Speech
$voice=New-Object System.Speech.Synthesis.SpeechSynthesizer
$installed=@($voice.GetInstalledVoices() | Where-Object {$_.Enabled})
[Console]::Out.WriteLine(('Enabled voices: '+$installed.Count))
try {$voice.SetOutputToWaveFile($OutputPath);$voice.Speak('Toolbox validation, one two three.')} finally {$voice.Dispose()}
''', encoding='ascii')
    wav = output / 'sapi.wav'
    host = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    try:
        environment = os.environ.copy()
        environment['PSMODULEPATH'] = ';'.join([
            str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/Modules'),
            str(Path(os.environ['ProgramFiles']) / 'WindowsPowerShell/Modules')])
        run = subprocess.run([str(host), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script), str(wav)],
                             capture_output=True, timeout=20, env=environment, creationflags=subprocess.CREATE_NO_WINDOW)
        (output / 'sapi-process.log').write_bytes(run.stdout + run.stderr)
        if run.returncode:
            raise RuntimeError('SAPI synthesis process failed')
        with wave.open(str(wav), 'rb') as audio:
            duration = round(audio.getnframes()*1000/audio.getframerate())
        results['sapiFile'] = {'status': 'passed' if duration > 0 else 'failed', 'durationMs': duration}
    except Exception as error:
        results['sapiFile'] = {'status': 'failed', 'errorType': type(error).__name__}
    results['status'] = 'passed' if results['edge']['status'] == results['sapiFile']['status'] == 'passed' else 'partial'
    return results


def local_tts_probe(output: Path) -> dict:
    """Real offline SAPI and auto pipeline; online/device playback are denied."""
    tts = load_module('toolbox_local_tts', 'tools/tts/tts_player.py')
    logger = tts.configure_logging(str(output/'tts.log'), log_text=False)
    calls = []
    async def denied(*args, **kwargs):
        calls.append(True)
        raise RuntimeError('Online synthesis is forbidden by this probe')
    results = {'playback': 'file decode adapter; no device playback'}
    prior = (sys.argv, tts.play_audio_file, tts.play_sapi_fallback, tts.get_default_cache_dir, tts.synthesize_edge_segment)
    try:
        for lang, text, voice in [('en', 'Toolbox local validation, one two three.', 'Microsoft Zira'),
                                  ('zh', '工具箱本地语音验证，一二三。', 'Microsoft Yaoyao')]:
            path = output/f'{lang}.wav'
            ok = asyncio.run(asyncio.wait_for(tts.synthesize_sapi_segment(
                voice, text, lang, '+0%', '+0Hz', '+0%', str(path)), 20))
            duration = audio_length(path) if ok else 0
            results[lang] = {'status': 'passed' if duration > 0 else 'failed', 'durationMs': duration}
        adjusted = output/'adjusted.wav'
        ok = asyncio.run(asyncio.wait_for(tts.synthesize_sapi_segment('Microsoft Zira',
            'This fixed text includes <markup> & quotes.', 'en', '-10%', '+10Hz', '-20%', str(adjusted)), 20))
        results['prosodyAndEscaping'] = {'status': 'passed' if ok and audio_length(adjusted) > 0 else 'failed'}
        cache = output/'cache'; cache.mkdir()
        config = output/'config.toml'; config.write_text('engine="auto"\nconcurrency=1\n', encoding='ascii')
        report = output/'result.txt'
        tts.synthesize_edge_segment = denied
        tts.play_audio_file = lambda path: audio_length(Path(path)) > 0
        tts.play_sapi_fallback = lambda *args, **kwargs: False
        tts.get_default_cache_dir = lambda: str(cache)
        sys.argv = ['tts_player.py', '--text', 'Local pipeline validation. 本地流水线验证。',
            '--config', str(config), '--request-id', 'local-pipeline', '--result-file', str(report)]
        code = tts.main()
        terminal = dict(line.split('=', 1) for line in report.read_text('utf-8').splitlines())
        files = list(cache.iterdir())
        results['autoPipeline'] = {'status': 'passed' if code == 0 and terminal.get('status') == 'success'
            and len(files) == 2 and all(path.suffix == '.wav' for path in files) and not calls else 'failed',
            'exitCode': code, 'onlineCalls': len(calls), 'wavFiles': len(files)}
        results['status'] = 'passed' if all(results[key]['status'] == 'passed'
            for key in ('en', 'zh', 'prosodyAndEscaping', 'autoPipeline')) else 'failed'
    finally:
        sys.argv, tts.play_audio_file, tts.play_sapi_fallback, tts.get_default_cache_dir, tts.synthesize_edge_segment = prior
        tts._TASK = None
        tts.close_logger(logger)
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('component', choices=['ocr', 'ocr-clipboard', 'tts', 'playback', 'local-tts'])
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.component == 'ocr-clipboard' and os.environ.get('TOOLBOX_CLIPBOARD_GUARD') != '1':
        parser.error('Use desktop-fixture.ahk --ocr-clipboard-smoke to preserve the clipboard')
    output = (args.output or ROOT / '.tmp/integration' / uuid.uuid4().hex).resolve()
    output.mkdir(parents=True, exist_ok=False)
    result = {'component': args.component, 'python': sys.version, 'executable': sys.executable,
              'scope': 'synthetic fixture; no UI, clipboard, playback or device-state changes'}
    try:
        probes = {'ocr': ocr_probe, 'ocr-clipboard': ocr_clipboard_probe, 'tts': tts_probe, 'playback': playback_probe, 'local-tts': local_tts_probe}
        if args.component == 'ocr-clipboard':
            result['scope'] = 'synthetic image and real clipboard; ClipboardAll guarded by the parent fixture'
        if args.component == 'playback':
            result['scope'] = 'real MCI playback/cancellation with silent PCM; no speech or device setting changes'
        result.update(probes[args.component](output))
    except Exception as error:
        result.update({'status': 'failed', 'errorType': type(error).__name__})
    (output / 'report.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())

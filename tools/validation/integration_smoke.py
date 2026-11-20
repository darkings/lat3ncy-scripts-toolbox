"""Opt-in real OCR / TTS probes using synthetic fixtures, never desktop content.

Run OCR with its dedicated interpreter. TTS writes files and never plays audio.
No clipboard, resident, task, power setting or device connection is changed.
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
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('component', choices=['ocr', 'tts'])
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = (args.output or ROOT / '.tmp/integration' / uuid.uuid4().hex).resolve()
    output.mkdir(parents=True, exist_ok=False)
    result = {'component': args.component, 'python': sys.version, 'executable': sys.executable,
              'scope': 'synthetic fixture; no UI, clipboard, playback or device-state changes'}
    try:
        result.update(ocr_probe(output) if args.component == 'ocr' else tts_probe(output))
    except Exception as error:
        result.update({'status': 'failed', 'errorType': type(error).__name__})
    (output / 'report.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())

"""Owned OCR stage. Screenshot is opened by the caller; text never touches clipboard."""
import argparse
import os
from pathlib import Path
import re
import sys
import time


def write_result(path: Path, request_id: str, status: str, text: str = '', kind: str = 'none') -> None:
    temporary = path.with_name(path.name+f'.{os.getpid()}.tmp')
    try:
        temporary.write_text(f'version=1\nrequest_id={request_id}\nstatus={status}\nerror_kind={kind}\ntext={text}', encoding='utf-8', newline='\n')
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def capture_text(baseline: int, timeout: float, *, image_file: str = '', progress=None) -> tuple[str, str]:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from toolbox_controls import module_enabled
    if not module_enabled('ocr'):
        return 'cancelled', ''
    import ocr
    from PIL import Image, ImageGrab
    engine = ocr.load_engine()
    if image_file:
        with Image.open(image_file) as image:
            if progress:
                progress()
            text = ocr.extract_text(engine, image.convert('RGB'))
        return ('ok' if text else 'empty'), text
    deadline = time.monotonic()+timeout
    while time.monotonic() < deadline:
        image = ImageGrab.grabclipboard()
        if isinstance(image, Image.Image) and ocr._clipboard_sequence() != baseline:
            try:
                if progress:
                    progress()
                text = ocr.extract_text(engine, image)
            finally:
                image.close()
            return ('ok' if text else 'empty'), text
        if isinstance(image, Image.Image):
            image.close()
        time.sleep(.15)
    return 'cancelled', ''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request-id', required=True)
    parser.add_argument('--result-file', required=True, type=Path)
    parser.add_argument('--baseline-sequence', required=True, type=int)
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--image-file', default='', help='Explicit fixed-image integration probe; bypasses clipboard capture')
    args = parser.parse_args()
    if (not re.fullmatch(r'[A-Za-z0-9_-]{1,120}', args.request_id) or not 0 < args.timeout <= 60
            or args.baseline_sequence < 0 or (args.baseline_sequence == 0 and not args.image_file)):
        return 1
    try:
        status, text = capture_text(args.baseline_sequence, args.timeout, image_file=args.image_file,
                                    progress=lambda: write_result(args.result_file, args.request_id, 'recognizing'))
        write_result(args.result_file, args.request_id, status, text)
        return 0
    except Exception:
        # A screenshot or exception may contain private text: fixed error only.
        try:
            write_result(args.result_file, args.request_id, 'error', kind='recognition')
        except OSError:
            pass
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

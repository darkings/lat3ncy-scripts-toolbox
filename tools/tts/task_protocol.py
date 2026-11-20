"""Bounded, text-free terminal result contract shared with the AHK client."""
import os
from pathlib import Path
import re


class TaskFailure(RuntimeError):
    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


class RequestState:
    def __init__(self, request_id: str = '', result_file: str = ''):
        if bool(request_id) != bool(result_file):
            raise ValueError('request-id and result-file must be supplied together')
        if request_id and not re.fullmatch(r'[A-Za-z0-9_-]{1,120}', request_id):
            raise ValueError('Invalid request-id')
        self.request_id = request_id
        self.result_file = result_file
        self.stage = 'input'

    def finish(self, status: str, kind: str = 'none') -> None:
        if not self.result_file:
            return
        if status not in {'success', 'failed', 'timeout', 'cancelled'}:
            raise ValueError('Invalid terminal status')
        if kind not in {'none', 'input', 'synthesis', 'playback', 'timeout', 'internal', 'cancelled'}:
            raise ValueError('Invalid error kind')
        path = Path(self.result_file)
        temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
        text = f'version=1\nrequest_id={self.request_id}\nstatus={status}\nerror_kind={kind}\nstage={self.stage}\n'
        try:
            temporary.write_text(text, encoding='utf-8', newline='\n')
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

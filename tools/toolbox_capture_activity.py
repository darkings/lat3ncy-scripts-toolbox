"""Read-only last capture receipts; never exports paths, file names or content."""
from __future__ import annotations
import json
from pathlib import Path
import re
import sys
from datetime import datetime, timezone

ROOT=Path(__file__).resolve().parents[1]
STATES={'waiting','processing','completed','partial','failed','timeout','stopped','processing_disabled'}
REASONS={'none','launch_failed','watcher_failed','no_file','file_not_ready','module_disabled','internal'}
OUTCOMES={'pending','off','success','failed','not_attempted'}


def read_document(path: Path, limit: int) -> dict | None:
    try:
        with path.open('rb') as stream:raw=stream.read(limit+1)
    except FileNotFoundError:return None
    if len(raw)>limit:raise ValueError('invalid_state')
    value=json.loads(raw.decode('utf-8-sig'))
    if not isinstance(value,dict):raise ValueError('invalid_state')
    return value


def instant(value: object) -> datetime:
    if not isinstance(value,str) or len(value)>64:raise ValueError('invalid_time')
    result=datetime.fromisoformat(value.replace('Z','+00:00'))
    if result.tzinfo is None:raise ValueError('invalid_time')
    return result.astimezone(timezone.utc)


def recording_state(root: Path, now: datetime | None = None) -> str:
    now=now or datetime.now(timezone.utc)
    try:
        directory=root/'.toolbox-state'
        session=read_document(directory/'capture-record.json',16384)
        if session is None:return 'idle'
        if session.get('version')!=1 or session.get('mode')!='Record' or not re.fullmatch('[0-9a-f]{32}',str(session.get('id',''))):return 'unknown'
        deadline=instant(session.get('deadlineUtc'))
        if now>=deadline:return 'idle'
        result=read_document(directory/'capture-result-record.json',8192)
        if result and result.get('version')==1 and result.get('id')==session['id'] and result.get('mode')=='Record' and result.get('state') in STATES-{'waiting','processing'}:return 'idle'
        return 'active'
    except (OSError,ValueError,TypeError):return 'unknown'


def snapshot(now: datetime | None = None) -> dict:
    now=now or datetime.now(timezone.utc)
    items=[]
    for mode in ('Screenshot','Record'):
        item={'mode':mode,'state':'none','reason':'none','clipboard':'not_attempted','extra_copy':'not_attempted','updated_utc':''}
        try:
            directory=ROOT/'.toolbox-state'
            session=read_document(directory/('capture-'+mode.lower()+'.json'),16384)
            result=read_document(directory/('capture-result-'+mode.lower()+'.json'),8192)
            if session is not None:
                token=session.get('id')
                if session.get('version')!=1 or session.get('mode')!=mode or not isinstance(token,str) or not re.fullmatch('[0-9a-f]{32}',token):raise ValueError('invalid_session')
                deadline=instant(session.get('deadlineUtc'))
                if result is None or result.get('id')!=token:
                    item.update(state='waiting' if now<deadline else 'interrupted',reason='no_result')
                else:
                    if result.get('version')!=1 or result.get('mode')!=mode or result.get('state') not in STATES or result.get('reason') not in REASONS:raise ValueError('invalid_result')
                    if any(result.get(key) not in OUTCOMES for key in ('clipboard','extra_copy')):raise ValueError('invalid_result')
                    updated=instant(result.get('updated_utc'))
                    if (updated-now).total_seconds()>5:raise ValueError('future_result')
                    item.update({key:result[key] for key in ('state','reason','clipboard','extra_copy')})
                    item['updated_utc']=updated.isoformat()
                    if now>=deadline and item['state'] in {'waiting','processing'}:item.update(state='interrupted',reason='no_result')
        except (OSError,ValueError,TypeError,KeyError):item.update(state='unavailable',reason='unavailable')
        items.append(item)
    return {'version':1,'status':'ok','items':items}


def main() -> int:
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8')
    print(json.dumps(snapshot(),ensure_ascii=False));return 0

if __name__=='__main__':raise SystemExit(main())

"""Codex Pacer's Codex hook: one identifier-only spool row per event.

Codex runs it asynchronously for every event Pacer registers, and SessionEnd
synchronously within three seconds. It reads stdin, never writes stdout, so it
can never change a decision, and it exits 0 whatever happens. Prompts, tool
input and output and assistant messages are dropped here and never stored.

Python 3.6+ and the standard library only; `-S` keeps startup short. On Windows
the Claude hook bootstrap provides fcntl.flock and replaces private_open, then
calls main(); keep every file access behind private_open and every lock on
fcntl.flock(fd, fcntl.LOCK_EX).
"""
import fcntl, json, os, sys, time

HOOK = 1
SPOOL = 1
MAX_INPUT = 32*1024*1024
MAX_SPOOL = 2*1024*1024
MAX_PATH = 4096
EVENTS = {'UserPromptSubmit','Stop','Interrupt','PermissionRequest','SubagentStart','SubagentStop','SessionEnd','PreCompact','PostCompact'}
CANONICAL = {name[0].lower()+name[1:]:name for name in EVENTS}

HEX = frozenset('0123456789abcdefABCDEF')
ALNUM = frozenset('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789')
def ident(value):
    # ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ without re; a bare 32-digit hex ID becomes a lowercase UUID.
    if not isinstance(value,str) or not 0<len(value)<=256 or value[0] not in ALNUM:return None
    if not all(ch in ALNUM or ch in '._-' for ch in value):return None
    compact=value.replace('-','')
    if len(compact)==32 and all(ch in HEX for ch in compact):
        compact=compact.lower();return compact[:8]+'-'+compact[8:12]+'-'+compact[12:16]+'-'+compact[16:20]+'-'+compact[20:]
    return value

def private_open(path,flags):
    fd=os.open(path,flags|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_CLOEXEC',0),0o600)
    if os.fstat(fd).st_uid!=os.getuid():os.close(fd);raise OSError('owner')
    return fd

def transcript(value):
    # Absolute only; Pacer itself accepts only rollouts inside this Codex home.
    if not isinstance(value,str) or not 0<len(value)<=MAX_PATH or '\0' in value:return None
    return value if os.path.isabs(value) else None

def approval(tool):
    if not isinstance(tool,str):return 'file'
    if tool=='Bash':return 'exec'
    return 'mcp' if tool.startswith('mcp__') else 'file'

def row(payload):
    if not isinstance(payload,dict):return None
    event=payload.get('hook_event_name')
    event=CANONICAL.get(event,event)
    thread=ident(payload.get('session_id'))
    if event not in EVENTS or thread is None:return None
    return {'v':SPOOL,'hook':HOOK,'at':time.time(),'event':event,'thread':thread,
            'turn':ident(payload.get('turn_id')),'agent':ident(payload.get('agent_id')),
            'agentType':ident(payload.get('agent_type')),'transcript':transcript(payload.get('transcript_path')),
            'agentTranscript':transcript(payload.get('agent_transcript_path')),
            'approval':approval(payload.get('tool_name')) if event=='PermissionRequest' else None,
            'reason':ident(payload.get('reason')) if event=='SessionEnd' else None}

def append(home,value):
    folder=os.path.join(home,'pacer','hooks')
    if not os.path.isdir(folder):os.makedirs(folder,0o700)
    current=os.path.join(folder,'events.jsonl')
    line=(json.dumps(value,separators=(',',':'))+'\n').encode()
    lockfd=private_open(os.path.join(folder,'events.lock'),os.O_CREAT|os.O_RDWR)
    try:
        fcntl.flock(lockfd,fcntl.LOCK_EX)
        try:
            if os.stat(current).st_size+len(line)>MAX_SPOOL:
                os.replace(current,os.path.join(folder,'events.previous.jsonl'))
        except OSError:pass
        fd=private_open(current,os.O_CREAT|os.O_APPEND|os.O_WRONLY)
        try:os.write(fd,line)
        finally:os.close(fd)
    finally:os.close(lockfd)

def main():
    try:
        if len(sys.argv)!=3 or sys.argv[1]!='hook' or not os.path.isabs(sys.argv[2]):return
        raw=sys.stdin.buffer.read(MAX_INPUT+1)
        if len(raw)>MAX_INPUT:return
        value=row(json.loads(raw.decode('utf-8')))
        if value:append(sys.argv[2],value)
    except Exception:pass

if __name__=='__main__':
    main()
    sys.exit(0)

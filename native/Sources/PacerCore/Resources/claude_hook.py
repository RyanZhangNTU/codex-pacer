"""Opt-in Claude hook/statusline adapter. Stdout never changes hook decisions.

Claude Code waits for most hooks, so this file imports only what every call
needs; slower modules load on the paths that use them.
"""
import fcntl, json, os, pathlib, sys, time

HEX = frozenset('0123456789abcdefABCDEF')
ALNUM = frozenset('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789')
def ident(value):
    # Same grammar as ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ without loading re;
    # Python 3.6 hosts run this file too, so avoid str.isascii().
    if not isinstance(value,str) or not 0<len(value)<=256 or value[0] not in ALNUM:return None
    if not all(ch in ALNUM or ch in '._-' for ch in value):return None
    compact=value.replace('-','')
    if len(compact)==32 and all(ch in HEX for ch in compact):
        compact=compact.lower();return compact[:8]+'-'+compact[8:12]+'-'+compact[12:16]+'-'+compact[16:20]+'-'+compact[20:]
    return value
def new_id():
    raw=bytearray(os.urandom(16));raw[6]=(raw[6]&15)|64;raw[8]=(raw[8]&63)|128;value=raw.hex()
    return value[:8]+'-'+value[8:12]+'-'+value[12:16]+'-'+value[16:20]+'-'+value[20:]
def private_open(path,flags):
    fd=os.open(str(path),flags|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    if os.fstat(fd).st_uid!=os.getuid():os.close(fd);raise OSError('owner')
    return fd
def write_object(path,value):
    temp=path.with_name(path.name+'.'+os.urandom(16).hex()+'.tmp')
    fd=private_open(temp,os.O_CREAT|os.O_EXCL|os.O_WRONLY)
    try:os.write(fd,json.dumps(value,separators=(',',':')).encode())
    finally:os.close(fd)
    os.replace(str(temp),str(path))
def write_locked(path,value):
    # Callers hold events.lock. Rewriting in place avoids a directory entry
    # change, so Pacer's spool-folder watch is not woken on every event.
    fd=private_open(path,os.O_CREAT|os.O_WRONLY|os.O_TRUNC)
    try:os.write(fd,json.dumps(value,separators=(',',':')).encode())
    finally:os.close(fd)
def read_object(path):
    try:
        fd=private_open(path,os.O_RDONLY)
        with os.fdopen(fd,'rb') as handle:raw=handle.read(2*1024*1024+1)
        if len(raw)>2*1024*1024:return {}
        value=json.loads(raw);return value if isinstance(value,dict) else {}
    except (OSError,ValueError):return {}
def statusline(home,value,raw):
    import math
    rates=value.get('rate_limits');payload={}
    if isinstance(rates,dict):
        for key in ('five_hour','seven_day'):
            source=rates.get(key)
            if not isinstance(source,dict):continue
            row={}
            for field in ('used_percentage','resets_at'):
                item=source.get(field)
                if isinstance(item,(float,int)) and not isinstance(item,bool) and math.isfinite(item):row[field]=item
                elif field=='resets_at' and isinstance(item,str) and len(item)<=80:row[field]=item
            if row:payload[key]=row
    if payload:
        cache=home/'pacer'/'claude-statusline.json';previous=read_object(cache);captured=previous.get('captured_at')
        # Claude refreshes the status line many times per minute. An unchanged
        # sample stays fresh for Pacer, so rewrite it at most every 30 seconds.
        unchanged=previous.get('payload')=={'rate_limits':payload} and isinstance(captured,(int,float)) and 0<=time.time()-captured<30
        if not unchanged:
            import hashlib
            envelope={'captured_at':time.time(),'payload':{'rate_limits':payload}}
            identity_file=home.parent/'.claude.json' if home==pathlib.Path(os.path.expanduser('~/.claude')) else home/'.claude.json'
            account=read_object(identity_file).get('oauthAccount',{}) if not os.environ.get('CLAUDE_CODE_OAUTH_TOKEN') else {}
            if isinstance(account,dict) and isinstance(account.get('accountUuid'),str) and isinstance(account.get('organizationUuid'),str):
                envelope['account_scope']=hashlib.sha256(('claude|'+account['accountUuid'].lower()+'|'+account['organizationUuid'].lower()).encode()).hexdigest()
            write_object(cache,envelope)
    previous=read_object(home/'pacer'/'installation.json').get('previousStatusLine')
    # The user's pre-existing renderer receives the original stdin and stdout;
    # Pacer's cache contains only quota numbers and a hashed account scope.
    if isinstance(previous,dict) and previous.get('type')=='command' and isinstance(previous.get('command'),str):
        import subprocess
        try:subprocess.run(previous['command'],shell=True,input=raw,stdout=sys.stdout,stderr=subprocess.DEVNULL,timeout=10)
        except subprocess.SubprocessError:pass
def hook(home,value):
    session=ident(value.get('session_id'));event=value.get('hook_event_name')
    if not session or not isinstance(event,str):return
    agent=ident(value.get('agent_id'));thread=agent or session;at=time.time();folder=home/'pacer'
    if value.get('agent_id') is not None and not agent:return
    if event in ('SubagentStart','SubagentStop') and not agent:return
    for key in ('prompt_id','tool_use_id','elicitation_id'):
        if value.get(key) is not None and not ident(value[key]):return
    display=None
    if event=='MessageDisplay':
        message=ident(value.get('message_id'));display_turn=ident(value.get('turn_id'));index=value.get('index')
        # This observer only uses the first non-final text batch. SDK/final
        # calls and subsequent batches cannot prove first display; do not lock
        # or rewrite metadata/state for them while Claude waits to render.
        # An async callback can run after the next UserPromptSubmit. Its input
        # must own a prompt; the current stored prompt is not that evidence.
        if not (ident(value.get('prompt_id')) and message and display_turn and value.get('final') is False and isinstance(index,int) and not isinstance(index,bool) and index==0 and isinstance(value.get('delta'),str) and bool(value['delta'])):return
        display=(message,display_turn)
    statefile=folder/'hook-state.json';lockfd=private_open(folder/'events.lock',os.O_CREAT|os.O_RDWR)
    try:
        fcntl.flock(lockfd,fcntl.LOCK_EX);states=read_object(statefile)
        key=thread;state=states.get(key,{});state=state if isinstance(state,dict) else {}
        if display and state.get('promptId')!=ident(value.get('prompt_id')):return
        # Prompt suggestions and other internal agents emit tool/stop hooks
        # without SubagentStart. They are not user task children.
        if agent and event!='SubagentStart' and state.get('spawned') is not True:return
        if event=='SubagentStart':state['spawned']=True
        prompt=ident(value.get('prompt_id')) or state.get('promptId')
        if display and not prompt:return
        if event=='UserPromptSubmit':prompt=ident(value.get('prompt_id')) or new_id()
        if event=='SubagentStart':prompt=ident(value.get('prompt_id')) or states.get(session,{}).get('promptId') or new_id()
        if prompt:state['promptId']=prompt
        state['at']=at;states[key]=state
        if len(states)>128:states=dict(sorted(states.items(),key=lambda row:row[1].get('at',0),reverse=True)[:128])
        row={'origin':'hook','sessionId':thread,'at':at};rows=[]
        if prompt:row['promptId']=prompt
        if agent:row['parentId']=session
        cwd=value.get('cwd')
        if isinstance(cwd,str) and len(cwd)<=4096:row['project']=os.path.basename(cwd.rstrip('/'))[:240]
        meta=dict(row,kind='metadata')
        if event=='SessionStart':
            if isinstance(value.get('model'),str):meta['model']=value['model'][:256]
            if isinstance(value.get('session_title'),str):meta['title']=value['session_title'][:240]
        # Every event row already carries routing; repeat display metadata only
        # when it changes or a new turn begins, halving routine spool writes.
        signature=json.dumps([meta.get(name) for name in ('project','parentId','model','title')])
        if event in ('SessionStart','UserPromptSubmit','SubagentStart') or state.get('meta')!=signature:
            rows.append(meta);state['meta']=signature
        item=ident(value.get('tool_use_id')) or ident(value.get('elicitation_id')) or 'attention'
        if event=='PreToolUse':state['lastToolId']=item
        if event=='PermissionRequest':state['permissionToolId']=item
        if event=='Elicitation':state['elicitationId']=item
        if event=='Notification':
            notification=value.get('notification_type')
            if notification=='permission_prompt':item=state.get('permissionToolId') or state.get('lastToolId') or item
            elif notification in ('elicitation_dialog','elicitation_url_dialog','elicitation_complete','elicitation_response'):item=state.get('elicitationId') or item
        if event in ('PostToolUse','PostToolUseFailure','PermissionDenied') and state.get('permissionToolId')==item:state.pop('permissionToolId',None)
        if event=='ElicitationResult' and state.get('elicitationId')==item:state.pop('elicitationId',None)
        row['itemId']=item
        mapping={'UserPromptSubmit':'prompt','PreToolUse':'toolStart','PostToolUse':'toolEnd','PostToolUseFailure':'toolEnd','PermissionDenied':'toolEnd','PermissionRequest':'approval','Stop':'stopRequested','StopFailure':'failure','SubagentStart':'subagentStart','SubagentStop':'stopRequested','SessionEnd':'unavailable','Elicitation':'input','ElicitationResult':'attentionCleared'}
        kind=mapping.get(event)
        if display:
            kind='responseDelta';row.update(itemId=display[0],displayTurnId=display[1],partial=True,index=0,hasText=True,promptOwned=True)
        if event=='Notification':
            notification=value.get('notification_type')
            kind='approval' if notification=='permission_prompt' else 'input' if notification in ('elicitation_dialog','elicitation_url_dialog','agent_needs_input') else 'attentionCleared' if notification in ('elicitation_complete','elicitation_response') else None
        if kind:
            row['kind']=kind
            if kind=='prompt' and value.get('prompt') in ('[Request interrupted by user]','[Request interrupted by user for tool use]'):row['typedInterruptMarker']=True
            if kind=='toolStart':row['attention']='input' if value.get('tool_name')=='AskUserQuestion' else 'approval' if value.get('tool_name')=='ExitPlanMode' else 'none'
            if kind=='toolStart' and value.get('tool_name')=='Agent':row['agentTool']=True
            rows.append(row)
        response=value.get('tool_response')
        if event=='PostToolUse' and value.get('tool_name')=='Agent' and ident(value.get('tool_use_id')) and isinstance(response,dict) and response.get('status') in ('completed','async_launched'):
            child=ident(response.get('agentId'))
            if child and child!=thread:rows.append(dict(row,kind='agentResult',agentId=child,agentStatus=response['status']))
        write_locked(statefile,states)
        path=folder/'events.jsonl'
        if path.exists() and path.stat().st_size>2*1024*1024:
            previous=folder/'events.previous.jsonl'
            if previous.exists():previous.unlink()
            os.replace(str(path),str(previous))
        if rows:
            fd=private_open(path,os.O_CREAT|os.O_APPEND|os.O_WRONLY)
            try:os.write(fd,b''.join(json.dumps(row,separators=(',',':'),ensure_ascii=True).encode()+b'\n' for row in rows))
            finally:os.close(fd)
    finally:os.close(lockfd)
def main():
    if len(sys.argv)<3:return
    raw=sys.stdin.buffer.read(1024*1024+1)
    if len(raw)>1024*1024:return
    home=pathlib.Path(sys.argv[2]).expanduser();value=json.loads(raw)
    if not isinstance(value,dict):return
    if sys.argv[1]=='statusline':statusline(home,value,raw)
    elif sys.argv[1]=='hook':hook(home,value)
if __name__=='__main__':
    try:main()
    except (OSError,ValueError,ImportError):pass

"""Opt-in Claude hook/statusline adapter. Stdout never changes hook decisions.

Claude Code waits for most hooks, so this file imports only what every call
needs; slower modules load on the paths that use them. While Pacer's progress
ring is switched on, a typed UserPromptSubmit adds one fixed line of model
context, and a Stop that leaves background work running is recorded as a wait.
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
# The progress ring's switch is pacer/progress-ring; "tool" in it asks for the
# report_progress tool of Pacer's Claude Code plugin instead of a leading
# marker, and "tool N" for a new estimate after a change of N points. The
# lines are worded as the user's request; only each estimate's number comes back.
OPEN,CLOSE=chr(0x27e6),chr(0x27e7);TOOL='mcp__plugin_pacer_pacer__report_progress'
TOOLS=(TOOL,'mcp__pacer__report_progress')
ASK="The user turned on Pacer's progress ring and asks that "
WAKE=('<task-notification>','<side-sessions-event>','[SYSTEM NOTIFICATION','<agent-message')
# Background work a stopped turn waits on is any task but long-lived monitors
# and Claude Code's own memory and scan work; new task kinds count.
IDLE=('monitor','dream','auto-mode scan','memory import','memory save')
def ring_on(home):
    try:fd=private_open(home/'pacer'/'progress-ring',os.O_RDONLY)
    except OSError:return None
    try:words=os.read(fd,16).split()
    finally:os.close(fd)
    if words[:1]!=[b'tool']:return 'marker'
    return 'tool '+str(int(words[1])) if len(words)>1 and words[1].isdigit() and 0<int(words[1])<=50 else 'tool'
def machine_prompt(value):
    # Background reports, scheduled wakes and other sessions' messages also
    # start turns; they continue the request the user typed.
    source=value.get('source')
    if source is not None:return source not in ('user','sdk')
    prompt=value.get('prompt');return isinstance(prompt,str) and prompt.lstrip().startswith(WAKE)
def progress_prompt(mode):
    if mode=='marker':return ASK+"every message you write start with "+OPEN+"NN%"+CLOSE+", your best estimate of how much of their current request is done. Always give a number."
    when=" after it moves "+mode[5:]+" points or more" if mode[5:] else " whenever you make progress"
    return ASK+"you report your best estimate of how much of their current request is done with "+TOOL+": with your first tool calls,"+when+", and before you stop to wait for background work, in the same batch as your other tool calls. Always give a number."
def spool(home,rows,session=None,change=None):
    # Appends rows and updates the session's request state under events.lock.
    folder=home/'pacer';lockfd=private_open(folder/'events.lock',os.O_CREAT|os.O_RDWR);result=None
    try:
        fcntl.flock(lockfd,fcntl.LOCK_EX)
        if change:
            path=folder/'progress-state.json';states=read_object(path)
            state=states.get(session) if isinstance(states.get(session),dict) else {}
            result=change(state);state['at']=time.time();states[session]=state
            for old in sorted(states,key=lambda k:states[k].get('at',0) if isinstance(states[k],dict) else 0)[:max(0,len(states)-64)]:del states[old]
            write_locked(path,states)
        if rows:
            fd=private_open(folder/'events.jsonl',os.O_CREAT|os.O_APPEND|os.O_WRONLY)
            try:os.write(fd,b''.join(json.dumps(row,separators=(',',':')).encode()+b'\n' for row in rows))
            finally:os.close(fd)
    finally:os.close(lockfd)
    return result
def plugin_enabled(home):
    plugins=read_object(home/'settings.json').get('enabledPlugins');return isinstance(plugins,dict) and plugins.get('pacer@pacer') is True
def plugin_live(home,mode):
    # Claude Code loads plugins when a session starts; Claude Desktop also
    # adds a newly enabled plugin to sessions that are already running.
    return mode!='marker' and os.environ.get('CLAUDE_CODE_ENTRYPOINT')=='claude-desktop' and plugin_enabled(home)
def progress_context(home,value):
    # A typed prompt starts a request; compaction can drop the earlier line.
    # Only a session that has Pacer's plugin is asked to use its tool.
    event=value.get('hook_event_name');session=ident(value.get('session_id'));mode=ring_on(home)
    if value.get('agent_id') is not None or not session or not mode:return
    if event=='SessionStart' and value.get('source')!='compact':
        ready=mode!='marker' and plugin_enabled(home);spool(home,[],session,lambda state:state.update(ready=ready));return
    typed=event=='UserPromptSubmit' and not machine_prompt(value)
    if not typed and not (event=='SessionStart' and value.get('source')=='compact'):return
    live=plugin_live(home,mode)
    def begin(state):
        if live:state['ready']=True
        return mode=='marker' or state.get('ready') is True
    if spool(home,[],session,begin):sys.stdout.write(json.dumps({'hookSpecificOutput':{'hookEventName':event,'additionalContext':progress_prompt(mode)}},separators=(',',':')));sys.stdout.flush()
def progress_marker(text):
    # ProgressMarker.percent's grammar: a leading marker holding 0-100.
    text=text.lstrip()
    if text[:1]!=OPEN or CLOSE not in text[:16]:return None
    inner=text[1:text.index(CLOSE)].strip(' ');digits=inner[:-1].rstrip(' ')
    if inner[-1:]!='%' or not 1<=len(digits)<=3 or any(c not in '0123456789' for c in digits) or int(digits)>100:return None
    return int(digits)
def progress_display(home,value):
    # Desktop transcripts can omit text written between tool calls, so each
    # message's first displayed lines are read live, as is the tool's input;
    # only the number is kept.
    event=value.get('hook_event_name');delta=value.get('delta');session=ident(value.get('session_id'))
    if value.get('agent_id') is not None or not session:return
    if event=='PreToolUse' and value.get('tool_name') in TOOLS and isinstance(value.get('tool_input'),dict):
        percent=value['tool_input'].get('percent')
        if type(percent) is not int or not 0<=percent<=100 or not ring_on(home):return
    else:
        if event!='MessageDisplay' or type(value.get('index')) is not int or value['index']!=0 or not isinstance(delta,str):return
        percent=progress_marker(delta[:64])
        if percent is None or not ring_on(home):return
        # The marker is hidden on screen; the stored message keeps it.
        lead=delta.lstrip();sys.stdout.write(json.dumps({'hookSpecificOutput':{'hookEventName':'MessageDisplay','displayContent':lead[lead.index(CLOSE)+1:].lstrip()}}));sys.stdout.flush()
    row={'origin':'hook','sessionId':session,'at':time.time(),'kind':'progress','progress':percent}
    if ident(value.get('prompt_id')):row['promptId']=ident(value.get('prompt_id'))
    # A session that called the tool has it.
    spool(home,[row],session,(lambda state:state.update(ready=True)) if event=='PreToolUse' else None)
def progress_stop(home,value):
    # A turn that stops while its background work runs is waiting, not done.
    # A stop with nothing left running ends the request; Pacer fills the ring
    # then, so the turn is never held for a final estimate.
    session=ident(value.get('session_id'));mode=ring_on(home)
    if value.get('hook_event_name')!='Stop' or value.get('agent_id') is not None or not session or not mode:return
    tasks=value.get('background_tasks');crons=value.get('session_crons')
    waited=[str(task.get('type'))[:24] for task in tasks if isinstance(task,dict) and isinstance(task.get('type'),str) and task.get('type') not in IDLE][:16] if isinstance(tasks,list) else []
    wakeups=min(len(crons),16) if isinstance(crons,list) else 0
    # An empty snapshot clears a previous attempted Stop that another hook
    # continued. It must not leave the request waiting after its final Stop.
    row={'origin':'hook','sessionId':session,'at':time.time(),'kind':'waiting','background':waited,'wakeups':wakeups}
    if ident(value.get('prompt_id')):row['promptId']=ident(value.get('prompt_id'))
    spool(home,[row])
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
        # Hooks inherit Claude Code's launch source; apps embedding it through
        # the Agent SDK use sdk-*. Only that yes/no is recorded.
        entry=os.environ.get('CLAUDE_CODE_ENTRYPOINT')
        if entry:meta['embedded']=entry.startswith('sdk-')
        # Every event row already carries routing; repeat display metadata only
        # when it changes or a new turn begins, halving routine spool writes.
        signature=json.dumps([meta.get(name) for name in ('project','parentId','model','title','embedded')])
        if event in ('SessionStart','UserPromptSubmit','SubagentStart') or state.get('meta')!=signature:
            rows.append(meta);state['meta']=signature
        item=ident(value.get('tool_use_id')) or ident(value.get('elicitation_id')) or 'attention'
        # PermissionRequest carries no tool_use_id. Match the started tool by a
        # checksum of its name/input, so that tool's own end clears the request.
        # A question asks for a reply, not an approval.
        pending=[entry for entry in state.get('pendingTools',[]) if isinstance(entry,list) and len(entry)==4]
        if event in ('PreToolUse','PermissionRequest'):
            import zlib
            name=value.get('tool_name') if isinstance(value.get('tool_name'),str) else ''
            named=zlib.crc32(name.encode('utf-8','replace'))
            try:inputs=zlib.crc32(json.dumps([name,value.get('tool_input')],sort_keys=True,default=str).encode('utf-8','replace'))
            except (TypeError,ValueError):inputs=None
        if event=='PreToolUse' and item!='attention':
            pending=[entry for entry in pending if entry[0]!=item][-15:]+[[item,named,inputs,'input' if name=='AskUserQuestion' else 'approval']]
        if event=='PermissionRequest' and item=='attention':
            match=[entry for entry in pending if inputs is not None and entry[2]==inputs] or [entry for entry in pending if entry[1]==named] or [entry for entry in pending if entry[0]==state.get('lastToolId')]
            if match:item=match[-1][0]
            state['permissionKind']=match[-1][3] if match else 'approval'
        elif event=='PermissionRequest':state['permissionKind']=next((entry[3] for entry in pending if entry[0]==item),'approval')
        if event in ('PostToolUse','PostToolUseFailure','PermissionDenied'):pending=[entry for entry in pending if entry[0]!=item]
        if event in ('UserPromptSubmit','Stop','StopFailure'):
            pending=[];state.pop('permissionToolId',None);state.pop('permissionKind',None)
        if pending:state['pendingTools']=pending
        else:state.pop('pendingTools',None)
        if event=='PreToolUse':state['lastToolId']=item
        if event=='PermissionRequest':state['permissionToolId']=item
        if event=='Elicitation':state['elicitationId']=item
        if event=='Notification':
            notification=value.get('notification_type')
            # Claude may send this seconds after the prompt; one already answered
            # must not flag its ended tool again.
            if notification=='permission_prompt':
                owner=state.get('permissionToolId')
                item=owner if owner=='attention' or any(entry[0]==owner for entry in pending) else None
            elif notification in ('elicitation_dialog','elicitation_url_dialog','elicitation_complete','elicitation_response'):item=state.get('elicitationId') or item
        permission=state.get('permissionKind','approval') if event=='PermissionRequest' or (event=='Notification' and state.get('permissionToolId')==item) else 'approval'
        if event in ('PostToolUse','PostToolUseFailure','PermissionDenied') and state.get('permissionToolId')==item:
            state.pop('permissionToolId',None);state.pop('permissionKind',None)
        if event=='ElicitationResult' and state.get('elicitationId')==item:state.pop('elicitationId',None)
        row['itemId']=item
        mapping={'UserPromptSubmit':'prompt','PreToolUse':'toolStart','PostToolUse':'toolEnd','PostToolUseFailure':'toolEnd','PermissionDenied':'toolEnd','PermissionRequest':'approval','Stop':'stopRequested','StopFailure':'failure','SubagentStart':'subagentStart','SubagentStop':'stopRequested','SessionEnd':'unavailable','Elicitation':'input','ElicitationResult':'attentionCleared'}
        kind=mapping.get(event)
        if event=='PermissionRequest':kind=permission
        if display:
            kind='responseDelta';row.update(itemId=display[0],displayTurnId=display[1],partial=True,index=0,hasText=True,promptOwned=True)
        if event=='Notification':
            notification=value.get('notification_type')
            kind=permission if notification=='permission_prompt' else 'input' if notification in ('elicitation_dialog','elicitation_url_dialog','agent_needs_input') else 'attentionCleared' if notification in ('elicitation_complete','elicitation_response') else None
            if item is None:kind=None
        if kind:
            row['kind']=kind
            if kind=='prompt' and value.get('prompt') in ('[Request interrupted by user]','[Request interrupted by user for tool use]'):row['typedInterruptMarker']=True
            if kind=='prompt' and machine_prompt(value):row['wake']=True
            if kind=='toolStart':row['attention']='input' if value.get('tool_name')=='AskUserQuestion' else 'approval' if value.get('tool_name')=='ExitPlanMode' else 'none'
            if kind=='toolStart' and value.get('tool_name') in ('Agent','Skill','SendMessage'):row['agentTool']=True
            rows.append(row)
        response=value.get('tool_response')
        # A forked Skill such as /code-review runs in a sub-agent and reports
        # 'forked'; 'background' marks a launch whose outcome arrives later.
        status=response.get('status') if isinstance(response,dict) else None
        if status=='forked':status='async_launched' if response.get('background') is True else 'completed' if response.get('success') is True else None
        child=ident(response.get('agentId')) if isinstance(response,dict) else None
        # A SendMessage that revives a stopped agent reports only its ID; the
        # revived run works in the background and its notification names this call.
        if value.get('tool_name')=='SendMessage' and isinstance(response,dict) and 'status' not in response and response.get('success') is True:
            status='async_launched';child=ident(response.get('revivedAgentId',response.get('resumedAgentId')))
        if event=='PostToolUse' and value.get('tool_name') in ('Agent','Skill','SendMessage') and ident(value.get('tool_use_id')) and status in ('completed','async_launched'):
            if child and child!=thread:rows.append(dict(row,kind='agentResult',agentId=child,agentStatus=status))
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
    elif sys.argv[1]=='hook':
        # The spool and the progress paths are independent: a busy spool lock
        # or a full disk must not drop the progress instruction or estimate.
        try:hook(home,value)
        finally:
            for extra in (progress_context,progress_display,progress_stop):
                try:extra(home,value)
                except OSError:pass
if __name__=='__main__':
    try:main()
    except (OSError,ValueError,ImportError):pass

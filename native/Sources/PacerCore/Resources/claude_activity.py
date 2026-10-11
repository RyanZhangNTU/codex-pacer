"""Pacer-owned, read-only Claude activity transport (Python 3.6+).

No prompts, messages, tool arguments/output, account data or absolute paths are
emitted. The owner's stdin EOF stops watches/listener without a heartbeat wait.
"""
import base64, datetime, json, math, os, pathlib, re, select, socket, struct, sys, time

MAX_FRAME = 1024 * 1024
ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$')

def ident(value):
    if not isinstance(value, str) or not ID.fullmatch(value): return None
    import uuid
    try: return str(uuid.UUID(value))
    except ValueError: return value

def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else None

def stamp(value):
    if not isinstance(value, str) or len(value) > 80: return None
    # datetime.fromisoformat is absent in Python 3.6.
    value = value.replace('Z', '+0000')
    if len(value) >= 6 and value[-3] == ':' and value[-6] in '+-': value = value[:-3] + value[-2:]
    for fmt in ('%Y-%m-%dT%H:%M:%S.%f%z', '%Y-%m-%dT%H:%M:%S%z'):
        try: return datetime.datetime.strptime(value, fmt).timestamp()
        except ValueError: pass
    return None

def transcript(raw, owner, parent=None, prompt=None):
    try: value = json.loads(raw)
    except (ValueError, UnicodeError): return []
    return transcript_record(value, owner, parent, prompt)

def agent_notification(text):
    if not isinstance(text,str) or len(text.encode('utf-8'))>65536 or not text.startswith('<task-notification>\n') or not text.endswith('\n</task-notification>') or '<!' in text or '<?' in text:return None
    remaining=[text[len('<task-notification>\n'):]]
    def field(name):
        start='<'+name+'>';end='</'+name+'>'
        if not remaining[0].startswith(start):return None
        index=remaining[0].find(end)
        if index<0:return None
        value=remaining[0][len(start):index]
        if '<' in value or '>' in value or re.search('[\x00-\x1f\x7f-\x9f]',value):return None
        tail=remaining[0][index+len(end):]
        if not tail.startswith('\n'):return None
        remaining[0]=tail[1:];return value
    agent=ident(field('task-id'));item=ident(field('tool-use-id'))
    if not agent or not item:return None
    if remaining[0].startswith('<task-type>') and field('task-type')!='local_agent':return None
    if remaining[0].startswith('<output-file>') and field('output-file') is None:return None
    status=field('status')
    if status not in ('completed','failed','killed') or not remaining[0].startswith('<summary>'):return None
    end=remaining[0].find('</summary>')
    if end<0:return None
    summary=remaining[0][len('<summary>'):end];tail=remaining[0][end+len('</summary>'):]
    if '<' in summary or '>' in summary or not tail.endswith('\n</task-notification>'):return None
    report=tail[:-len('\n</task-notification>')]
    if '</task-notification>' in report:return None
    return agent,item,status

def transcript_record(value, owner, parent=None, prompt=None):
    # The tailer shares this one decoded line with its ID-only parent context.
    # No parsed record is stored on a cursor; only IDs enter its context.
    if not isinstance(value, dict): return []
    session = ident(value.get('sessionId',owner))
    if session != (parent or owner): return []
    agent=ident(value.get('agentId')) if parent else None
    if parent and 'agentId' in value and agent is None:return []
    if agent and agent not in (owner,'agent-'+owner):return []
    if value.get('type')=='custom-title' and isinstance(value.get('customTitle'),str):
        return [{'origin':'transcript','sessionId':owner,'at':time.time(),'kind':'metadata','title':value['customTitle'][:240]}]
    at = stamp(value.get('timestamp'))
    if at is None: return []
    if value.get('serverClassifierRequest') is True:return []
    base = {'origin': 'transcript', 'sessionId': owner, 'at': at}
    owned_prompt=ident(value.get('promptId')) or prompt
    if owned_prompt:base['promptId']=owned_prompt
    else:base['unownedTurn']=True
    if parent: base['parentId'] = parent
    cwd = value.get('cwd')
    if isinstance(cwd, str) and len(cwd) < 4096: base['project'] = os.path.basename(cwd.rstrip('/'))[:240]
    message = value.get('message'); message = message if isinstance(message, dict) else {}
    meta = dict(base, kind='metadata')
    model = message.get('model')
    if isinstance(model, str): meta['model'] = model[:256]
    title = value.get('sessionTitle')
    if isinstance(title, str): meta['title'] = title[:240]
    rows = [meta]; starts = []; ends = []; model_kinds = set()
    content = message.get('content')
    kind = value.get('type')
    origin=value.get('origin');origin=origin if isinstance(origin,dict) else {}
    human=origin.get('kind')=='human' and origin.get('producer')!='session-task'
    legacy='origin' not in value and 'promptSource' not in value and 'turnOrigin' not in value
    if kind=='user' and message.get('role')=='user' and origin.get('kind')=='task-notification' and origin.get('producer')=='session-task' and ('runId' not in origin or ident(origin['runId'])) and value.get('turnOrigin')!='human':
        text=content if isinstance(content,str) else content[0].get('text') if isinstance(content,list) and len(content)==1 and isinstance(content[0],dict) and content[0].get('type')=='text' else None
        notification=agent_notification(text)
        return [dict(base,kind='agentNotification',agentId=notification[0],itemId=notification[1],agentStatus=notification[2])] if notification else []
    if kind=='user' and not human and not legacy:return []
    if kind=='user' and 'origin' not in value and 'promptSource' not in value and 'turnOrigin' not in value and value.get('isMeta') is not False and value.get('isSynthetic') is not False and ident(value.get('promptId')) and isinstance(content,list) and len(content)==1:
        marker=content[0]
        if isinstance(marker,dict) and marker.get('type')=='text' and marker.get('text') in ('[Request interrupted by user]','[Request interrupted by user for tool use]'):
            rows.append(dict(base,kind='interrupt',promptId=ident(value['promptId']),engineInterrupt=True));return rows
    if isinstance(content, list):
        for item in content[:128]:
            if not isinstance(item, dict): continue
            block_kind = item.get('type')
            if block_kind == 'tool_use' and ident(item.get('id')): starts.append((ident(item['id']), item.get('name')))
            elif block_kind == 'tool_result' and ident(item.get('tool_use_id')): ends.append(ident(item['tool_use_id']))
            elif block_kind in ('text', 'thinking'): model_kinds.add(block_kind)
    if kind == 'user' and not ends and not value.get('isMeta') and not value.get('isSynthetic'):
        prompt = ident(value.get('promptId')) or ident(value.get('uuid'))
        if prompt: rows.append(dict(base, kind='prompt', promptId=prompt))
    for item in ends: rows.append(dict(base, kind='toolEnd', itemId=item))
    response=value.get('toolUseResult')
    if kind=='user' and len(ends)==1 and isinstance(response,dict) and response.get('status') in ('completed','async_launched'):
        child=ident(response.get('agentId'))
        if child and child!=owner:rows.append(dict(base,kind='agentResult',itemId=ends[0],agentId=child,agentStatus=response['status']))
    if kind == 'assistant':
        item = ident(value.get('uuid')) or ident(message.get('id')) or 'assistant'
        request=ident(value.get('requestId')) or ident(message.get('id'));message_id=ident(message.get('id'));usage=message.get('usage',{});usage=usage if isinstance(usage,dict) else {};output=usage.get('output_tokens')
        if request and message_id and isinstance(output,int) and not isinstance(output,bool) and 0<output<=1000000000000:
            rows.append(dict(base,kind='modelBlock',requestId=request,messageId=message_id,outputTokens=output,toolIds=[item for item,_ in starts]))
        for model_kind in sorted(model_kinds): rows.append(dict(base, kind='thinking' if model_kind == 'thinking' else 'response', itemId=item))
        for item, name in starts:
            row=dict(base, kind='toolStart', itemId=item, attention='input' if name == 'AskUserQuestion' else 'approval' if name == 'ExitPlanMode' else 'none')
            if name=='Agent':row['agentTool']=True
            rows.append(row)
        if message.get('stop_reason', value.get('stop_reason')) in ('end_turn', 'stop_sequence', 'refusal'): rows.append(dict(base, kind='stopRequested'))
    if kind == 'result' and value.get('subtype') in ('success', 'error_during_execution', 'error_max_turns', 'interrupted'):
        subtype = value['subtype']; rows.append(dict(base, kind='stop' if subtype == 'success' else 'interrupt' if subtype == 'interrupted' else 'failure'))
    if kind=='system' and value.get('subtype')=='stop_hook_summary' and value.get('preventedContinuation') is False and value.get('hookErrors')==[] and value.get('hookAdditionalContext')==[]:rows.append(dict(base,kind='stopVerified'))
    return rows

ALLOWED_RECORD = {'kind','origin','sessionId','promptId','parentId','itemId','at','project','title','model','attention','agentId','parentAgentId','agentTool','agentStatus','requestId','messageId','toolIds','startedAt','outputTokens','durationMs','ttftMs','firstContentMs','partial','index','displayTurnId','hasText','promptOwned','engineInterrupt','typedInterruptMarker','unownedTurn'}
KINDS = {'metadata','prompt','toolStart','toolEnd','thinking','response','responseDelta','modelBlock','agentResult','agentNotification','approval','input','attentionCleared','stop','stopVerified','stopRequested','failure','interrupt','subagentStart','subagentStop','unavailable','request'}

def sanitized(raw):
    try: value = json.loads(raw)
    except (ValueError, UnicodeError): return []
    if not isinstance(value, dict) or value.get('kind') not in KINDS or not ident(value.get('sessionId')) or number(value.get('at')) is None: return []
    out = {k:v for k,v in value.items() if k in ALLOWED_RECORD}
    for key in ('sessionId','promptId','parentId','itemId','agentId','parentAgentId','requestId','messageId','displayTurnId'):
        if key in out:
            valid = ident(out[key])
            if valid: out[key] = valid
            else: out.pop(key)
    for key in ('project','title','model'):
        if key in out:
            if isinstance(out[key], str): out[key] = out[key][:256]
            else: out.pop(key)
    if 'agentTool' in out and out['agentTool'] is not True:out.pop('agentTool')
    if 'promptOwned' in out and out['promptOwned'] is not True:out.pop('promptOwned')
    if 'agentStatus' in out and out['agentStatus'] not in ('completed','async_launched','failed','killed'):out.pop('agentStatus')
    return [out]

OTEL_ATTRS = {'session.id','prompt.id','llm_request.context','agent_id','parent_agent_id','request_id','gen_ai.response.id','output_tokens','duration_ms','ttft_ms','first_content_ms','model','gen_ai.request.model','success'}
OTEL_VALUE_FIELDS = {'stringValue','intValue','doubleValue','boolValue','arrayValue','kvlistValue','bytesValue'}
OTEL_DECIMAL = re.compile(r'^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z')

class OTLPFailure(ValueError):
    def __init__(self,status):self.status=status

def otel_scalar(value):
    if not isinstance(value,dict):return None,None
    keys=OTEL_VALUE_FIELDS.intersection(value)
    if len(keys)!=1:return None,None
    key=next(iter(keys));return key,value[key]

def otel_integer(value,minimum,maximum):
    import decimal
    if isinstance(value,bool):return None
    if isinstance(value,str):
        if len(value)>128 or not OTEL_DECIMAL.fullmatch(value):return None
        try:value=decimal.Decimal(value)
        except decimal.InvalidOperation:return None
    if not isinstance(value,(int,decimal.Decimal)):return None
    try:
        if isinstance(value,decimal.Decimal) and not value.is_finite():return None
        if not minimum<=value<=maximum or value!=int(value):return None
        return int(value)
    except (ValueError,OverflowError,decimal.InvalidOperation):return None

def otel_number(value):
    import decimal
    kind,raw=otel_scalar(value)
    if kind=='intValue':
        result=otel_integer(raw,-9223372036854775808,9223372036854775807)
        return float(result) if result is not None else None
    if kind!='doubleValue' or isinstance(raw,bool):return None
    if isinstance(raw,str) and (len(raw)>64 or not OTEL_DECIMAL.fullmatch(raw)):return None
    if not isinstance(raw,(str,int,float,decimal.Decimal)):return None
    try:result=float(raw)
    except (ValueError,OverflowError):return None
    return result if math.isfinite(result) else None

def otel_string(value):
    kind,raw=otel_scalar(value)
    return raw if kind=='stringValue' and isinstance(raw,str) else None

def otel_identifier(value):
    raw=otel_string(value)
    return ident(raw) if isinstance(raw,str) and ID.fullmatch(raw) else None

def attributes(rows):
    out = {}
    if rows is None:return out
    if not isinstance(rows,list) or len(rows)>256:raise OTLPFailure(400)
    for item in rows:
        if not isinstance(item,dict):raise OTLPFailure(400)
        key=item.get('key')
        if isinstance(key,str) and key in OTEL_ATTRS and 'value' in item:out[key]=item['value']
    return out

def otlp_records(raw):
    import decimal
    if len(raw)>MAX_FRAME:raise OTLPFailure(413)
    def parsed_number(text):
        if len(text)>128:raise OTLPFailure(400)
        try:return decimal.Decimal(text)
        except decimal.InvalidOperation:raise OTLPFailure(400)
    def invalid_constant(text):raise OTLPFailure(400)
    try:value=json.loads(raw,parse_int=parsed_number,parse_float=parsed_number,parse_constant=invalid_constant)
    except (ValueError,UnicodeError,RecursionError):raise OTLPFailure(400)
    # Match native JSON validation, including skipped private strings.
    pending=[(value,0)]
    while pending:
        item,depth=pending.pop()
        if depth>128:raise OTLPFailure(400)
        if isinstance(item,str) and re.search('[\ud800-\udfff]',item):raise OTLPFailure(400)
        if isinstance(item,dict):
            pending.extend((v,depth+1) for v in item.values());pending.extend((key,depth) for key in item)
        elif isinstance(item,list):pending.extend((v,depth+1) for v in item)
    if not isinstance(value,dict):raise OTLPFailure(400)
    result = [];span_count=0
    resources=value.get('resourceSpans',[])
    if not isinstance(resources,list) or len(resources)>64:raise OTLPFailure(400)
    for resource in resources:
        if not isinstance(resource,dict):raise OTLPFailure(400)
        common=resource.get('resource',{})
        if not isinstance(common,dict):raise OTLPFailure(400)
        base=attributes(common.get('attributes'))
        scopes=resource.get('scopeSpans',[])
        if not isinstance(scopes,list) or len(scopes)>128:raise OTLPFailure(400)
        for scope in scopes:
            if not isinstance(scope,dict):raise OTLPFailure(400)
            spans=scope.get('spans',[])
            if not isinstance(spans,list) or len(spans)>512:raise OTLPFailure(400)
            for span in spans:
                span_count+=1
                if span_count>512 or not isinstance(span,dict):raise OTLPFailure(400)
                if span.get('name') != 'claude_code.llm_request': continue
                a = dict(base); a.update(attributes(span.get('attributes')))
                status=span.get('status');status={} if status is None else status
                if not isinstance(status,dict):continue
                code=status.get('code')
                if code is not None and (isinstance(code,str) or otel_integer(code,0,1) is None):continue
                success=None
                if 'success' in a:
                    kind,success=otel_scalar(a['success'])
                    if kind=='stringValue' and isinstance(success,str) and success.lower() in ('true','false'):success=success.lower()=='true'
                    elif kind!='boolValue' or not isinstance(success,bool):continue
                    if success is not True:continue
                session,prompt=otel_identifier(a.get('session.id')),otel_identifier(a.get('prompt.id'))
                if 'prompt.id' in a and not prompt:continue
                # Current Claude Code omits prompt.id on request spans. Only a
                # main-conversation request may bind to the session's current turn.
                if not prompt and otel_string(a.get('llm_request.context'))!='interaction':continue
                request=otel_identifier(a.get('request_id') if 'request_id' in a else a.get('gen_ai.response.id'))
                start=otel_integer(span.get('startTimeUnixNano'),1,18446744073709551615)
                end=otel_integer(span.get('endTimeUnixNano'),1,18446744073709551615)
                output=otel_number(a.get('output_tokens'));duration=otel_number(a.get('duration_ms'))
                if not session or not request or start is None or end is None or end<=start or duration is None or not 10<=duration<=3600000 or output is None or not 0<output<=1000000000000 or output!=int(output):continue
                row = {'kind':'request','sessionId':session,'requestId':request,'at':end/1e9,'startedAt':start/1e9,'outputTokens':int(output),'durationMs':duration}
                if prompt:row['promptId']=prompt
                for key, target in (('agent_id','agentId'),('parent_agent_id','parentAgentId')):
                    agent=otel_identifier(a.get(key))
                    if agent:row[target]=agent
                for key, target in (('ttft_ms','ttftMs'),('first_content_ms','firstContentMs')):
                    metric=otel_number(a.get(key))
                    if metric is not None and 0<=metric<=duration:row[target]=metric
                model=otel_string(a.get('model') if 'model' in a else a.get('gen_ai.request.model'))
                if isinstance(model,str) and re.fullmatch('[A-Za-z0-9._:-]{1,128}',model):row['model']=model
                if success is True:row['success']=True
                result.append(row)
    return result

def otlp_request_header(raw):
    if len(raw)+4>16384:raise OTLPFailure(431)
    try:
        lines=raw.decode('utf-8').split('\r\n');first=lines.pop(0).split(' ');fields={}
        if len(first)!=3 or first[2] not in ('HTTP/1.0','HTTP/1.1'):raise OTLPFailure(400)
        if first[0]!='POST':raise OTLPFailure(405)
        if first[1]!='/v1/traces':raise OTLPFailure(404)
        for line in lines:
            if not line or line[0] in ' \t' or ':' not in line:raise OTLPFailure(400)
            name,value=line.split(':',1);name=name.lower()
            if not name:raise OTLPFailure(400)
            if name not in ('content-length','content-type','content-encoding','transfer-encoding'):continue
            if name in fields:raise OTLPFailure(400)
            fields[name]=value.strip()
        if 'transfer-encoding' in fields:raise OTLPFailure(400)
        encoding=fields.get('content-encoding','identity').lower()
        if encoding not in ('identity','gzip') or fields.get('content-type','').split(';')[0].strip().lower()!='application/json':raise OTLPFailure(415)
        if 'content-length' not in fields:raise OTLPFailure(411)
        length=fields['content-length']
        if not re.fullmatch('[0-9]{1,8}',length):raise OTLPFailure(400)
        length=int(length)
        if not 0<length<=MAX_FRAME:raise OTLPFailure(413)
        return length,encoding
    except OTLPFailure:raise
    except (ValueError,UnicodeError):raise OTLPFailure(400)

def otlp_decoded_body(raw,encoding):
    if not 0<len(raw)<=MAX_FRAME:raise OTLPFailure(413)
    if encoding=='identity':return raw
    if encoding!='gzip':raise OTLPFailure(415)
    try:
        import zlib
        decoder=zlib.decompressobj(16+zlib.MAX_WBITS)
        value=decoder.decompress(raw,MAX_FRAME+1)
        if len(value)>MAX_FRAME:raise OTLPFailure(413)
        if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or not value:raise OTLPFailure(400)
        return value
    except ImportError:raise OTLPFailure(415)
    except zlib.error:raise OTLPFailure(400)

def otlp_respond(stream,status):
    reasons={200:'OK',400:'Bad Request',404:'Not Found',405:'Method Not Allowed',408:'Request Timeout',411:'Length Required',413:'Content Too Large',415:'Unsupported Media Type',431:'Request Header Fields Too Large'}
    try:stream.send(('HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}'%(status,reasons[status])).encode())
    except OSError:pass

class Tailer:
    def __init__(self, home):
        self.home = home; self.cursors = {}; self.watches = {}; self.dirty = set(); self.fd = -1; self.scans = 0
        if sys.platform.startswith('linux'):
            try:
                import ctypes
                self.libc = ctypes.CDLL(None, use_errno=True); self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
            except (OSError, AttributeError): pass
    def entries(self, path, limit):
        try:
            with os.scandir(str(path)) as items:
                rows = []
                for item in items:
                    if len(rows) >= limit: break
                    if item.is_symlink(): continue
                    rows.append(pathlib.Path(item.path))
                return rows
        except OSError: return []
    def modified(self, path):
        try: return path.stat().st_mtime
        except OSError: return 0
    def discover(self):
        self.scans += 1; root = self.home / 'projects'; candidates = []; dirs = [self.home, root, self.home/'pacer']
        for project in sorted(self.entries(root, 256), key=self.modified, reverse=True)[:64]:
            if not project.is_dir(): continue
            dirs.append(project)
            for file in self.entries(project, 256):
                session = ident(file.stem)
                if file.suffix != '.jsonl' or not session: continue
                candidates.append((file, session, None, False))
                for agent in self.entries(project/session/'subagents',64):
                    if agent.suffix != '.jsonl' or not agent.stem.startswith('agent-'): continue
                    aid = ident(agent.stem[6:])
                    if aid: candidates.append((agent,aid,session,False))
        events = self.home/'pacer'/'events.jsonl'
        if events.is_file(): candidates.append((events,'hooks',None,True))
        selected = sorted(candidates,key=lambda row:self.modified(row[0]),reverse=True)[:32]
        desired = {row[0] for row in selected}
        for file in list(self.cursors):
            if file not in desired: self.cursors.pop(file,None)
        for file, session, parent, owned in selected:
            if file not in self.cursors: self.cursors[file] = {'inode':0,'offset':0,'fragment':b'','session':session,'parent':parent,'owned':owned,'historicalEnd':None};self.dirty.add(file)
        watches = desired.union(dirs[:4])
        for wd,path in list(self.watches.items()):
            if path not in watches:
                self.watches.pop(wd,None)
                if self.fd >= 0: self.libc.inotify_rm_watch(self.fd,wd)
        if self.fd >= 0:
            existing = set(self.watches.values())
            for path in watches-existing:
                wd = self.libc.inotify_add_watch(self.fd,os.fsencode(str(path)),0x2|0x8|0x40|0x80|0x100|0x200|0x400|0x800)
                if wd >= 0: self.watches[wd] = path
    def drain(self):
        discover = False
        for _ in range(8):
            try: data = os.read(self.fd,65536)
            except (BlockingIOError,OSError): break
            if not data: break
            offset = 0
            while offset+16 <= len(data):
                wd,mask,_,length = struct.unpack_from('iIII',data,offset)
                end = offset+16+length
                if end > len(data):
                    self.dirty.update(self.cursors);discover = True;break
                name = data[offset+16:end].split(b'\0',1)[0];offset = end
                path = self.watches.get(wd)
                if mask&0x4000: self.dirty.update(self.cursors);discover = True
                if path in self.cursors: self.dirty.add(path)
                elif path is not None:
                    # Directory notifications duplicate a known file's append.
                    # Only a pure modify/close of that exact cursor skips the
                    # full project inventory. Creation, rotation, deletion and
                    # ambiguous events still reconcile discovery immediately.
                    ordinary = mask != 0 and mask&~(0x2|0x8) == 0
                    child = path/os.fsdecode(name) if name and name not in (b'.',b'..') and b'/' not in name else None
                    known = child in self.cursors
                    if known: self.dirty.add(child)
                    if not ordinary or not known: discover = True
                if mask&(0x400|0x800|0x8000): self.watches.pop(wd,None)
        return discover
    def poll(self):
        for file,cursor in list(self.cursors.items()):
            try:
                s=file.stat()
                if s.st_ino != cursor['inode'] or s.st_size != cursor['offset'] or b'\n' in cursor['fragment']: self.dirty.add(file)
            except OSError: self.cursors.pop(file,None)
    def read(self):
        rows = [];owned_backlog=False
        # Explicit hooks establish the current turn before transcript fallback
        # endings are correlated. Set iteration otherwise changes cold replay
        # semantics, especially for nonhuman engine continuation prompts.
        for file in sorted(self.dirty,key=lambda path:(not self.cursors.get(path,{}).get('owned',False),str(path))):
            cursor=self.cursors.get(file)
            if owned_backlog and cursor is not None and not cursor['owned']:continue
            self.dirty.discard(file)
            if cursor is None: continue
            try:
                s=file.stat();reset=s.st_ino!=cursor['inode'] or cursor['offset']>s.st_size
                if reset: cursor.update(inode=s.st_ino,offset=0,fragment=b'',historicalEnd=s.st_size,context={},contextOrder=[],discardingOversize=False)
                budget=512*1024 if cursor['offset']==0 else 128*1024
                # Large normal attachment appends must drain sequentially;
                # the per-read budget is not an actual missing-data boundary.
                gap=s.st_size-cursor['offset']>(budget if cursor['offset']==0 else 8*1024*1024)
                if gap:
                    cursor.update(offset=s.st_size-budget,fragment=b'',context={},contextOrder=[],discardingOversize=False)
                    if not cursor['owned']:rows.append({'kind':'discontinuity','origin':'reader','sessionId':cursor['session'],'at':time.time()})
                fragment_start=cursor['offset']-len(cursor['fragment'])
                with file.open('rb') as handle: handle.seek(cursor['offset']);data=handle.read(budget)
                cursor['offset']+=len(data);fragment=cursor['fragment']+data
                if gap:
                    dropped,sep,fragment=fragment.partition(b'\n');fragment_start+=len(dropped)+len(sep)
                    if not sep: fragment=b''
                if cursor.get('discardingOversize'):
                    dropped,sep,fragment=fragment.partition(b'\n');fragment_start+=len(dropped)+len(sep)
                    if sep:cursor['discardingOversize']=False
                    else:fragment=b''
                lines=fragment.split(b'\n');fragment=lines.pop()
                rest=lines[512:];lines=lines[:512]
                if rest: fragment=b'\n'.join(rest)+b'\n'+fragment;self.dirty.add(file)
                cursor['fragment']=fragment
                for line in lines:
                    historical=cursor['historicalEnd'] is not None and fragment_start<cursor['historicalEnd'];fragment_start+=len(line)+1
                    if len(line)>MAX_FRAME:
                        cursor.update(context={},contextOrder=[])
                        if not cursor['owned']:rows.append({'kind':'discontinuity','origin':'reader','sessionId':cursor['session'],'at':time.time()})
                        continue
                    if cursor['owned']: values=sanitized(line)
                    else:
                        try: value=json.loads(line)
                        except (ValueError,UnicodeError): continue
                        prompt=self.prompt_context_record(value,cursor)
                        values=transcript_record(value,cursor['session'],cursor['parent'],prompt)
                    rows.extend(dict(row,historical=historical) for row in values)
                if len(cursor['fragment'])>MAX_FRAME:
                    cursor.update(fragment=b'',context={},contextOrder=[],discardingOversize=True)
                    if not cursor['owned']:rows.append({'kind':'discontinuity','origin':'reader','sessionId':cursor['session'],'at':time.time()})
                if cursor['offset']<s.st_size:self.dirty.add(file)
                # Keep both byte/line budgets. Complete owned records must
                # catch up before fallback logs; an unfinished EOF fragment
                # alone must neither starve logs nor create a polling loop.
                if cursor['owned'] and (cursor['offset']<s.st_size or b'\n' in cursor['fragment']):owned_backlog=True
                if cursor['historicalEnd'] is not None and cursor['offset']>=cursor['historicalEnd'] and (not cursor['fragment'] or cursor['offset']-len(cursor['fragment'])>=cursor['historicalEnd']):cursor['historicalEnd']=None
            except OSError:self.cursors.pop(file,None)
        return rows
    def prompt_context(self,raw,cursor):
        try:value=json.loads(raw)
        except (ValueError,UnicodeError):return None
        return self.prompt_context_record(value,cursor)
    def prompt_context_record(self,value,cursor):
        if not isinstance(value,dict) or (ident(value.get('sessionId')) or cursor['session'])!=(cursor['parent'] or cursor['session']):return None
        context=cursor.setdefault('context',{});order=cursor.setdefault('contextOrder',[])
        prompt=ident(value.get('promptId')) or context.get(ident(value.get('parentUuid')))
        origin=value.get('origin',{})
        if prompt is None and value.get('type')=='user' and isinstance(origin,dict) and origin.get('kind')=='human':prompt=ident(value.get('uuid'))
        node=ident(value.get('uuid'))
        if node and prompt:
            if node not in context:order.append(node)
            context[node]=prompt
            if len(order)>512:context.pop(order.pop(0),None)
        return prompt
    def close(self):
        if self.fd >= 0: os.close(self.fd);self.fd=-1

def main():
    home = pathlib.Path(os.path.expanduser(base64.b64decode(sys.argv[1]).decode()))
    tailer=Tailer(home);tailer.discover();rows=tailer.read();clients={};listener=None
    try:
        listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind(('127.0.0.1',4319));listener.listen(8);listener.setblocking(False)
    except OSError:
        if listener:listener.close()
        listener=None
    def emit(value):
        try: sys.stdout.write(json.dumps(value,separators=(',',':'),ensure_ascii=True)+'\n');sys.stdout.flush()
        except (BrokenPipeError,OSError): raise SystemExit(0)
    def publish(rows,attached=False):
        for i in range(0,len(rows),512):emit({'kind':'claudeBatch','attaching':attached,'baselineFinal':i+512>=len(rows) and not tailer.dirty,'records':rows[i:i+512]})
    try:interval=min(5,max(.1,float(sys.argv[2])))
    except (IndexError,ValueError):interval=5
    pending=[];pending_due=None
    urgent={'prompt','responseDelta','toolStart','toolEnd','agentResult','agentNotification','approval','input','attentionCleared','stop','stopVerified','failure','interrupt','subagentStart','subagentStop','unavailable'}
    def queue_rows(rows):
        nonlocal pending,pending_due
        if not rows:return
        pending.extend(rows)
        if any(row.get('kind') in urgent or row.get('historical') for row in rows) or len(pending)>=512:
            publish(pending);pending=[];pending_due=None
        elif pending_due is None:pending_due=time.monotonic()+interval
    publish(rows);next_scan=time.monotonic()+60;next_poll=time.monotonic()+2;heartbeat=0;loops=0;stdin=b''
    try:
        while True:
            now=time.monotonic();loops+=1
            if pending_due is not None and now>=pending_due:publish(pending);pending=[];pending_due=None
            if now>=heartbeat:
                heartbeat=now+15;emit({'kind':'status','connected':True,'claudeHome':home.is_dir(),'watchingLogs':bool(tailer.cursors),'scans':tailer.scans,'cpuSeconds':time.process_time(),'loopIterations':loops,'telemetry':listener is not None})
            if now>=next_scan:tailer.discover();next_scan=now+60
            if now>=next_poll:tailer.poll();next_poll=now+(30 if tailer.fd>=0 else 2)
            if tailer.dirty:queue_rows(tailer.read())
            for client,state in list(clients.items()):
                if now>state['deadline']:otlp_respond(client,408);client.close();clients.pop(client,None)
            inputs=[sys.stdin.fileno()]+list(clients)
            if listener:inputs.append(listener)
            if tailer.fd>=0:inputs.append(tailer.fd)
            deadlines=[heartbeat,next_scan,next_poll]+[s['deadline'] for s in clients.values()]
            if pending_due is not None:deadlines.append(pending_due)
            if tailer.dirty:deadlines.append(now+.1)
            timeout=max(0,min(deadlines)-now)
            ready,_,_=select.select(inputs,[],[],timeout)
            for stream in ready:
                if stream==sys.stdin.fileno():
                    data=os.read(stream,65536)
                    if not data:
                        if pending:publish(pending)
                        return
                    stdin+=data
                    if len(stdin)>65536:stdin=b''
                    while b'\n' in stdin:
                        line,stdin=stdin.split(b'\n',1)
                        try:settings=json.loads(line)
                        except ValueError:continue
                        if isinstance(settings,dict):
                            value=number(settings.get('batchInterval'))
                            if value is not None:interval=min(5,max(.1,value))
                            if settings.get('flushPending'):
                                if pending:publish(pending);pending=[];pending_due=None
                                tailer.poll()
                elif tailer.fd>=0 and stream==tailer.fd:
                    if tailer.drain():tailer.discover()
                elif stream is listener:
                    client,_=listener.accept();client.setblocking(False)
                    if len(clients)>=8:client.close()
                    else:clients[client]={'buffer':b'','header':None,'length':0,'deadline':time.monotonic()+5}
                else:
                    state=clients.get(stream)
                    if state is None:continue
                    try:data=stream.recv(65536)
                    except OSError:data=b''
                    if not data:stream.close();clients.pop(stream,None);continue
                    try:
                        state['buffer']+=data
                        if state['header'] is None:
                            if b'\r\n\r\n' in state['buffer']:
                                header,body=state['buffer'].split(b'\r\n\r\n',1)
                                length,encoding=otlp_request_header(header)
                                state.update(header=True,length=length,encoding=encoding,buffer=body)
                            elif len(state['buffer'])>16384:raise OTLPFailure(431)
                        if state['header']:
                            if len(state['buffer'])>state['length']:raise OTLPFailure(400)
                            if len(state['buffer'])==state['length']:
                                body=otlp_decoded_body(state['buffer'],state['encoding'])
                                queue_rows(otlp_records(body));otlp_respond(stream,200)
                                stream.close();clients.pop(stream,None)
                    except OTLPFailure as error:
                        otlp_respond(stream,error.status);stream.close();clients.pop(stream,None)
    finally:
        tailer.close()
        if listener:listener.close()
        for client in clients:client.close()

if __name__=='__main__':
    try:main()
    except (BrokenPipeError,OSError):pass

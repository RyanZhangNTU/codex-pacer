import Foundation

enum RealtimeProbe {
    static let library = SessionLogProbe.library + "\n" + #"""
    import socket, struct, select, hashlib, secrets, stat, uuid, re
    from collections import OrderedDict
    MAX=4*1024*1024
    def valid_id(v):
        try: return isinstance(v,str) and str(uuid.UUID(v))==v.lower()
        except (ValueError,AttributeError): return False
    class RuntimeIndexChanges:
        # Discovery must also work when no Desktop window owns the remote
        # thread. Observe index metadata only; never open the SQLite contents.
        pattern=re.compile(r'^state(?:_\d+)?\.sqlite(?:-(?:wal|journal))?$')
        def __init__(self,path):
            self.path=path;self.fd=-1;self.next_check=0;self.previous=self.fingerprint()
            if sys.platform.startswith('linux'):
                try:
                    import ctypes
                    libc=ctypes.CDLL(None,use_errno=True)
                    fd=libc.inotify_init1(os.O_NONBLOCK|os.O_CLOEXEC)
                    if fd>=0:
                        if libc.inotify_add_watch(fd,os.fsencode(path),0x2|0x80|0x100|0x200|0x400|0x800)>=0:self.fd=fd
                        else:os.close(fd)
                except (OSError,AttributeError):pass
        def fingerprint(self):
            values=[]
            try:
                for entry in self.path.iterdir():
                    if self.pattern.fullmatch(entry.name):
                        try:
                            s=entry.stat();values.append((entry.name,s.st_ino,s.st_mtime_ns,s.st_size))
                        except OSError:pass
            except OSError:pass
            return tuple(sorted(values)[-16:])
        def check(self,now):
            if now<self.next_check:return False
            self.next_check=now+(60 if self.fd>=0 else 2)
            current=self.fingerprint();changed=current!=self.previous;self.previous=current
            return changed
        def drain(self):
            changed=False
            for _ in range(8):
                try:data=os.read(self.fd,65536)
                except BlockingIOError:break
                if not data:break
                offset=0
                while offset+16<=len(data):
                    _,mask,_,length=struct.unpack_from('iIII',data,offset);offset+=16
                    name=os.fsdecode(data[offset:offset+length].split(b'\0',1)[0]);offset+=length
                    if mask&0x4000 or self.pattern.fullmatch(name):changed=True
                    if mask&(0x400|0x800|0x8000):self.close();self.next_check=0;changed=True
                if self.fd<0:break
            return changed
        def close(self):
            if self.fd>=0:os.close(self.fd);self.fd=-1
    def is_review(t):
        source=str(t.get('threadSource') or '').lower().replace('_','')
        model=str(t.get('model') or '').lower()
        s=t.get('source') or {}; sub=s.get('subAgent',s.get('subagent',{})) if isinstance(s,dict) else {}
        return source in ('guardianreview','autoreview','subagentreview') or model.startswith('codex-auto-review') or sub=='review' or isinstance(sub,dict) and (sub.get('other') in ('guardian','autoreview','auto_review') or 'review' in sub)
    def is_excluded_thread(t):
        return t.get('ephemeral') is True or is_review(t)
    class WebSocket:
        def __init__(self,path):
            uid=os.getuid(); parent=path.parent.stat(); link=path.lstat(); target=path.stat(); actual_parent=path.resolve().parent.stat()
            if parent.st_uid!=uid or parent.st_mode&0o022 or link.st_uid!=uid or target.st_uid!=uid or not stat.S_ISSOCK(target.st_mode) or target.st_mode&0o077 or actual_parent.st_uid!=uid or actual_parent.st_mode&0o022: raise OSError('unsafe endpoint')
            self.s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); self.s.settimeout(2); self.buf=b''; self.fragment=b''; self.op=None; self.last_receive=time.monotonic()
            try:
                self.s.connect(str(path)); key=base64.b64encode(secrets.token_bytes(16)).decode()
                self.s.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: '+key+'\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
                while b'\r\n\r\n' not in self.buf:
                    chunk=self.s.recv(4096)
                    if not chunk: raise EOFError()
                    self.buf+=chunk
                    if len(self.buf)>16384: raise ValueError('header bound')
                header,self.buf=self.buf.split(b'\r\n\r\n',1)
                values={}
                for row in header.split(b'\r\n')[1:]:
                    if b':' in row:
                        k,v=row.split(b':',1); values[k.strip().lower()]=v.strip()
                expected=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
                if b' 101 ' not in header.split(b'\r\n')[0] or values.get(b'sec-websocket-accept')!=expected: raise ValueError('upgrade failed')
            except Exception:
                self.s.close(); raise
        def send_frame(self,op,data):
            mask=secrets.token_bytes(4); n=len(data)
            head=bytes([128|op,128|n]) if n<126 else bytes([128|op,254])+struct.pack('!H',n) if n<65536 else bytes([128|op,255])+struct.pack('!Q',n)
            self.s.sendall(head+mask+bytes(c^mask[i%4] for i,c in enumerate(data)))
        def send(self,obj): self.send_frame(1,json.dumps(obj,separators=(',',':')).encode())
        def readn(self,n):
            while len(self.buf)<n:
                data=self.s.recv(65536)
                if not data: raise EOFError()
                self.buf+=data
                if len(self.buf)>MAX+65536: raise ValueError('buffer bound')
            result,self.buf=self.buf[:n],self.buf[n:]; return result
        def receive(self):
            h=self.readn(2); final=bool(h[0]&128); op=h[0]&15; n=h[1]&127
            if h[0]&112 or h[1]&128: raise ValueError('unsupported frame')
            if n==126: n=struct.unpack('!H',self.readn(2))[0]
            elif n==127: n=struct.unpack('!Q',self.readn(8))[0]
            if n>MAX or len(self.fragment)+n>MAX: raise ValueError('frame bound')
            data=self.readn(n); self.last_receive=time.monotonic()
            if op==8: raise EOFError()
            if op==9:
                if not final or n>125: raise ValueError('invalid ping')
                self.send_frame(10,data); return None
            if op==10: return None
            if op==1:
                if self.op is not None: raise ValueError('nested fragment')
                self.op=op; self.fragment=data
            elif op==0 and self.op==1: self.fragment+=data
            else: raise ValueError('unsupported opcode')
            if not final: return None
            result=json.loads(self.fragment); self.fragment=b''; self.op=None
            return result if isinstance(result,dict) else None
        def close(self): self.s.close()
    import os
    def event(method,p):
        tid=p.get('threadId')
        if not valid_id(tid): return None
        now=time.time(); e={'method':method,'threadId':tid.lower(),'at':now}
        if isinstance(p.get('turnId'),str): e['turnId']=p['turnId'][:256]
        if method in ('item/started','item/completed'):
            item=p.get('item') or {}
            if not isinstance(item,dict): return None
            if isinstance(item.get('type'),str): e['itemType']=item['type'][:80]
            if isinstance(item.get('id'),str): e['itemId']=item['id'][:256]
            if item.get('type') in ('collabAgentToolCall','collabToolCall'):
                ids=item.get('receiverThreadIds') or []
                if isinstance(ids,list):e['receiverThreadIds']=[v.lower() for v in ids[:64] if valid_id(v)]
            stamp=p.get('startedAtMs') if method=='item/started' else p.get('completedAtMs')
            if isinstance(stamp,(int,float)) and 0<stamp<=now*1000+5000: e['at']=stamp/1000
        elif method in ('turn/started','turn/completed'):
            turn=p.get('turn') or {}
            if not isinstance(turn,dict) or not isinstance(turn.get('id'),str): return None
            e['turnId']=turn['id'][:256]; e['status']=str(turn.get('status',''))[:32]
        elif method=='thread/tokenUsage/updated':
            usage=p.get('tokenUsage') or {}; total=usage.get('total') or {}; last=usage.get('last') or {}
            if not isinstance(total.get('outputTokens'),int) or total['outputTokens']<0: return None
            e['outputTokens']=total['outputTokens']
            if isinstance(last.get('outputTokens'),int) and last['outputTokens']>=0: e['lastOutputTokens']=last['outputTokens']
            if isinstance(last.get('reasoningOutputTokens'),int) and last['reasoningOutputTokens']>=0: e['lastReasoningTokens']=last['reasoningOutputTokens']
        elif method=='thread/status/changed':
            status=p.get('status') or {}
            e['status']=str(status.get('type',''))[:32]
            e['flags']=[f for f in status.get('activeFlags',[]) if f in ('waitingOnApproval','waitingOnUserInput')]
        elif method=='thread/name/updated':
            if 'threadName' not in p:return None
            name=p.get('threadName')
            if name is not None and not isinstance(name,str):return None
            e['name']=name[:240] if name is not None else None
        elif method in ('item/agentMessage/delta','item/plan/delta','item/reasoning/summaryTextDelta','item/reasoning/textDelta'):
            if isinstance(p.get('itemId'),str): e['itemId']=p['itemId'][:256]
            # Only presence crosses the host boundary, never text or tokenization.
            e['hasText']=isinstance(p.get('delta'),str) and bool(p['delta'])
        else: return None
        return e
    class Session:
        def __init__(self,ws):
            self.ws=ws; self.ready=False; self.pending={}; self.next_id=1; self.known=OrderedDict(); self.excluded=set(); self.attached=set(); self.attaching=set(); self.evidenced=set(); self.queue=[]; self.buffered={}; self.notices=0; self.last_rpc=time.monotonic(); self.last_list=0
            self.read_queue=OrderedDict();self.listing=False;self.list_cursor=None;self.list_cursors=set();self.first_text=set();self.rollout_paths=OrderedDict()
            self.request('initialize',{'clientInfo':{'name':'codex-pacer-events','version':'2.3.1'},'capabilities':{'experimentalApi':True}},'initialize')
        def request(self,method,params,kind,tid=None):
            # This allowlist prevents a monitor from sending task input/config changes.
            if method not in ('initialize','thread/loaded/list','thread/read','thread/resume'): raise ValueError('request not allowed')
            rid=self.next_id; self.next_id+=1; self.pending[rid]=(kind,tid,time.monotonic())
            self.ws.send({'id':rid,'method':method,'params':params})
        def queue_thread(self,tid,priority=False):
            if not valid_id(tid):return
            tid=tid.lower()
            if tid in self.excluded or tid in self.attached or tid in self.attaching or any(v[0]=='read' and v[1]==tid for v in self.pending.values()):return
            if tid not in self.read_queue and len(self.read_queue)>=128:return
            self.read_queue[tid]=None
            if priority:self.read_queue.move_to_end(tid,last=False)
        def read_thread(self,tid):
            self.queue_thread(tid,priority=True);self.pump_discovery()
        def request_loaded(self):
            if self.listing:return False
            self.listing=True;self.list_cursor=None;self.list_cursors=set()
            self.request('thread/loaded/list',{'limit':64},'list');self.last_list=time.monotonic()
            return True
        def pump_discovery(self):
            if not self.ready:return
            reads=sum(v[0]=='read' for v in self.pending.values())
            # Reserve an active slot for every outstanding metadata read, so
            # concurrent active replies cannot exceed the subscription budget.
            while self.read_queue and reads<8 and len(self.pending)<64 and len(self.attached|self.attaching)+reads<32:
                tid,_=self.read_queue.popitem(last=False)
                if tid in self.excluded or tid in self.attached or tid in self.attaching or any(v[0]=='read' and v[1]==tid for v in self.pending.values()):continue
                self.request('thread/read',{'threadId':tid,'includeTurns':False},'read',tid);reads+=1
            if self.listing and not self.read_queue and not any(v[0] in ('read','resume','list') for v in self.pending.values()):
                if self.list_cursor is not None:
                    cursor=self.list_cursor;self.list_cursor=None
                    if cursor in self.list_cursors or len(self.list_cursors)>=256:raise ValueError('loaded cursor loop')
                    self.list_cursors.add(cursor)
                    self.request('thread/loaded/list',{'limit':64,'cursor':cursor},'list')
                else:self.listing=False
        def queue_event(self,e):
            if e is None:return
            for child in e.get('receiverThreadIds',[]):self.queue_thread(child,priority=True)
            if e.get('turnId'):self.evidenced.add(e['threadId'])
            if e.get('method')=='turn/started':self.first_text.discard(e['threadId'])
            first=e.get('hasText') is True and e['threadId'] not in self.first_text
            if first:self.first_text.add(e['threadId']);e['firstTextDelta']=True
            if self.queue and ('Delta' in e['method'] or e['method'].endswith('/delta')) and self.queue[-1].get('method')==e['method'] and self.queue[-1].get('itemId')==e.get('itemId') and self.queue[-1].get('threadId')==e['threadId']:
                previous=self.queue[-1]
                if previous.get('hasText'):
                    e['hasText']=True;e['firstDeltaAt']=previous.get('firstDeltaAt',previous['at'])
                self.queue[-1]=e
            else: self.queue.append(e)
            tool_boundary=e['method'] in ('item/started','item/completed') and e.get('itemType') in ('commandExecution','fileChange','mcpToolCall','dynamicToolCall','collabToolCall','collabAgentToolCall','webSearch','imageView')
            if len(self.queue)>=512 or tool_boundary or first or e['method'] in ('turn/started','turn/completed','thread/status/changed'):flush_events(self)
        def release(self,tid):
            self.queue_event({'method':'stream/released','threadId':tid,'at':time.time()})
            self.attached.discard(tid);self.attaching.discard(tid);self.evidenced.discard(tid)
            self.known.pop(tid,None);self.buffered.pop(tid,None);self.read_queue.pop(tid,None);self.first_text.discard(tid)
            if tid in self.rollout_paths:self.rollout_paths[tid]=(self.rollout_paths[tid][0],time.monotonic()+30)
            for rid,value in list(self.pending.items()):
                if value[1]==tid and value[0] in ('read','resume'):self.pending.pop(rid,None)
        def trim_metadata(self):
            for tid in list(self.known):
                if len(self.known)<=64:break
                if tid not in self.attached and tid not in self.attaching:self.known.pop(tid,None)
        def exclude_thread(self,tid):
            if len(self.excluded)<1024:self.excluded.add(tid)
            self.rollout_paths.pop(tid,None)
            self.known.pop(tid,None);self.buffered.pop(tid,None);self.read_queue.pop(tid,None);self.first_text.discard(tid)
            self.attached.discard(tid);self.attaching.discard(tid);self.evidenced.discard(tid)
            self.queue=[e for e in self.queue if e.get('threadId')!=tid]
            for rid,value in list(self.pending.items()):
                if value[1]==tid and value[0] in ('read','resume'):self.pending.pop(rid,None)
        def receive(self,v):
            try:self.receive_message(v)
            finally:self.pump_discovery()
        def receive_message(self,v):
            if v is None:return
            if 'id' in v and v['id'] in self.pending:
                kind,tid,_=self.pending.pop(v['id'])
                if 'error' in v:
                    if kind=='initialize': raise ValueError('initialize rejected')
                    self.attaching.discard(tid); return
                result=v.get('result') or {}
                if kind=='initialize':
                    self.ws.send({'method':'initialized'}); self.ready=True
                    self.request_loaded()
                elif kind=='list':
                    threads=result.get('data',[]);cursor=result.get('nextCursor')
                    if not isinstance(threads,list) or len(threads)>64:raise ValueError('loaded page bound')
                    if cursor is not None and (not isinstance(cursor,str) or not cursor or len(cursor)>2048 or cursor in self.list_cursors):raise ValueError('loaded cursor')
                    self.list_cursor=cursor
                    for thread in threads:self.queue_thread(thread)
                elif kind in ('read','resume'):
                    thread=result.get('thread') or {}
                    if not isinstance(thread,dict) or thread.get('id')!=tid or is_excluded_thread(thread):
                        self.exclude_thread(tid);return
                    self.known[tid]=thread.get('status') or {}
                    self.known.move_to_end(tid)
                    meta={'method':'metadata','threadId':tid.lower(),'at':time.time(),'source':thread.get('threadSource') if isinstance(thread.get('threadSource'),str) else ''}
                    parent=parent_thread(thread)
                    if parent and parent!=tid:
                        meta['parentThreadId']=parent
                        self.queue_thread(parent,priority=True)
                    for k,bound in (('name',240),('cwd',2048),('model',256)):
                        if isinstance(thread.get(k),str):meta[k]=thread[k][:bound]
                    self.queue_event(meta)
                    status=self.known[tid]
                    self.queue_event({'method':'thread/observed','threadId':tid.lower(),'at':time.time(),
                        'status':status.get('type',''),'flags':[f for f in status.get('activeFlags',[]) if f in ('waitingOnApproval','waitingOnUserInput')]})
                    if status.get('type')=='active':
                        self.evidenced.add(tid)
                        if isinstance(thread.get('path'),str):
                            self.rollout_paths[tid]=(thread['path'],float('inf'));self.rollout_paths.move_to_end(tid)
                            while len(self.rollout_paths)>64:self.rollout_paths.popitem(last=False)
                    if kind=='resume':
                        self.attaching.discard(tid); self.attached.add(tid)
                    elif self.known[tid].get('type')=='active' and tid not in self.attached and tid not in self.attaching:
                        self.attaching.add(tid)
                        # The versioned protocol rejoins an already running thread.
                        # Never resume an idle/unloaded thread or pass config overrides.
                        self.request('thread/resume',{'threadId':tid,'excludeTurns':True},'resume',tid)
                    buffered=self.buffered.pop(tid,[]);ended=False
                    for queued in buffered:
                        self.queue_event(queued)
                        if queued.get('method')=='turn/completed' or queued.get('status')=='notLoaded':ended=True
                        elif queued.get('method')=='turn/started':ended=False
                    # Buffered terminal evidence must free the slot too.
                    if ended:self.release(tid)
                    self.trim_metadata()
                return
            method=v.get('method');p=v.get('params') or {}
            if not isinstance(method,str) or not isinstance(p,dict):return
            self.notices+=1;self.last_rpc=time.monotonic()
            if method=='thread/started':
                thread=p.get('thread') or {}
                if not isinstance(thread,dict):return
                tid=thread.get('id')
                if valid_id(tid) and is_excluded_thread(thread):self.exclude_thread(tid.lower());return
                self.read_thread(tid);return
            e=event(method,p)
            if e is None:return
            tid=e['threadId']
            if tid in self.excluded:return
            if method=='thread/status/changed':
                if e.get('status')=='active' and tid not in self.attached:self.read_thread(tid)
                if e.get('status')!='active' and tid not in self.known:return
            if tid in self.known:
                self.queue_event(e)
                if method=='turn/completed' or method=='thread/status/changed' and e.get('status')=='notLoaded':self.release(tid)
            else:
                self.read_thread(tid)
                if tid not in self.buffered and len(self.buffered)>=64:return
                q=self.buffered.setdefault(tid,[])
                if len(q)<64:q.append(e)
    import resource
    """# + "\n" + RequestLogProbe.library + "\n" + #"""
    def emit(obj):
        data=obj if isinstance(obj,bytes) else (json.dumps(obj,separators=(',',':'))+'\n').encode()
        while data:
            written=os.write(1,data);data=data[written:]
    def flush_events(session):
        if session and session.queue:
            events=session.queue;session.queue=[]
            for offset in range(0,len(events),512):
                emit({'kind':'runtimeBatch','events':events[offset:offset+512]})
    def emit_snapshot(frame):
        # Serialize each batch once; encoded fragments stay within the wire
        # bound without re-encoding every record or an already encoded frame.
        budget=1024*1024
        if sum(len(row.get('records',())) for row in frame['sessions'])<=64:
            data=(json.dumps(frame,separators=(',',':'))+'\n').encode()
            if len(data)<=budget:emit(data);return
        token=uuid.uuid4().hex;index=0;pending=None
        def publish(row,final):
            nonlocal index
            header=json.dumps({'kind':'fallbackChunk','snapshotId':token,'part':index,'final':final},separators=(',',':')).encode()
            emit(header[:-1]+b',"sessions":['+row+b']}\n');index+=1
        def stage(row):
            nonlocal pending
            if pending is not None:publish(pending,False)
            pending=row
        def encoded_groups(records):
            for offset in range(0,len(records),64):
                batch=records[offset:offset+64]
                encoded=json.dumps(batch,separators=(',',':')).encode()[1:-1]
                if len(encoded)<budget-4096:yield encoded
                else:
                    for record in batch:
                        encoded=json.dumps(record,separators=(',',':')).encode()
                        if len(encoded)>=budget-4096:raise ValueError('fallback record bound')
                        yield encoded
        for row in frame['sessions']:
            base={k:v for k,v in row.items() if k!='records'}
            base['continuation']=False
            prefix=json.dumps(base,separators=(',',':')).encode()[:-1]+b',"records":['
            groups=[];size=len(prefix)+1024
            for group in encoded_groups(row['records']):
                if groups and size+len(group)+1>budget:
                    stage(prefix+b','.join(groups)+b']}')
                    base.update(continuation=True,reset=False,partial=False,preludeCount=0)
                    prefix=json.dumps(base,separators=(',',':')).encode()[:-1]+b',"records":['
                    groups=[];size=len(prefix)+1024
                if size+len(group)+1>budget:raise ValueError('fallback record bound')
                groups.append(group);size+=len(group)+1
            stage(prefix+b','.join(groups)+b']}')
        if pending is None:
            emit({'kind':'fallbackChunk','snapshotId':token,'part':0,'final':True,'sessions':[]})
        else:publish(pending,True)
    def stats(session,scans):
        usage=resource.getrusage(resource.RUSAGE_SELF)
        return {'kind':'status','connected':bool(session and session.ready),'attached':len(session.attached) if session else 0,'notifications':session.notices if session else 0,'fallbackScans':scans,'watchingLogs':bool(globals().get('request_logs')),'helperCpuSeconds':round(usage.ru_utime+usage.ru_stime,6),'helperLoopIterations':loop_iterations}
    """#
    static let script = library + "\n" + #"""
    ws=None; session=None; reconnect_at=0; next_scan=0; next_status=0; next_ping=0; flush_at=0; last_flush=-1e9; scans=0; last_scan=-1e9; latest_snapshot=None; status_stamp=None; once_deadline=time.monotonic()+6; quiet_since=None; loop_iterations=0
    once=len(sys.argv)>2 and sys.argv[2]=='once'
    local_only=len(sys.argv)>2 and sys.argv[2]=='socket-only'
    ssh_lifetime=len(sys.argv)>2 and sys.argv[2]=='ssh-lifetime'
    controlled_input=ssh_lifetime or local_only and len(sys.argv)>4 and sys.argv[4]=='control'
    batch_interval=min(5,max(.1,float(sys.argv[3]))) if len(sys.argv)>3 else 5
    index_changes=RuntimeIndexChanges(home) if ssh_lifetime else None
    request_logs=RequestLogTailer() if ssh_lifetime else None
    discovery_dirty=False;next_discovery=0;index_rechecks=0
    hint_buffer=b'';hints=OrderedDict()
    def read_hints():
        global hint_buffer,batch_interval,flush_at
        data=os.read(0,4096)
        if not data:return False
        hint_buffer+=data
        if len(hint_buffer)>8192:raise ValueError('hint buffer bound')
        while b'\n' in hint_buffer:
            line,hint_buffer=hint_buffer.split(b'\n',1)
            try:value=json.loads(line)
            except ValueError:continue
            if isinstance(value,dict) and value.get('kind')=='settings':
                interval=value.get('batchInterval')
                if type(interval) in (int,float) and interval in (1,5):
                    batch_interval=interval;now=time.monotonic()
                    flush=value.get('flushPending') is True
                    flush_at=now if flush else last_flush+interval
                    if request_logs:request_logs.reschedule(now,interval,flush)
                continue
            ids=value.get('threadIds') if isinstance(value,dict) and value.get('kind')=='discover' else None
            if not isinstance(ids,list) or len(ids)>32:continue
            for tid in ids:
                if valid_id(tid):hints[tid]=(0,time.monotonic())
            while len(hints)>64:hints.popitem(last=False)
        return True
    while True:
        loop_iterations+=1
        try:
            now=time.monotonic()
            if index_changes and index_changes.check(now):discovery_dirty=True;index_rechecks=2
            if controlled_input and select.select([0],[],[],0)[0] and not read_hints():break
            if ws is None and now>=reconnect_at:
                try:
                    ws=WebSocket(home/'app-server-control'/'app-server-control.sock');session=Session(ws);next_status=now
                except (OSError,ValueError,EOFError):
                    if ws:ws.close()
                    ws=None;session=None;reconnect_at=now+30
            if session and (any(now-v[2]>5 for v in session.pending.values()) or now-ws.last_receive>45):raise TimeoutError()
            if session and session.ready and (now-session.last_list>=60 or discovery_dirty and now>=next_discovery):
                if session.request_loaded():
                    # The index can be committed before the runtime becomes
                    # active. Recheck twice, bounded and coalesced with writes.
                    discovery_dirty=index_rechecks>0
                    if index_rechecks:index_rechecks-=1
                    next_discovery=now+(2 if index_rechecks==0 else 1)
            if session and session.ready:
                for tid,(attempt,due) in list(hints.items()):
                    if tid in session.attached or session.known.get(tid,{}).get('type')=='active':hints.pop(tid,None)
                    elif now>=due:
                        session.read_thread(tid)
                        if attempt>=3:hints.pop(tid,None)
                        else:hints[tid]=(attempt+1,now+[.5,1,2,5][attempt])
            if now>=next_scan and not local_only:
                latest_snapshot=snapshot(excluding=session.evidenced if session and session.ready else ());scans+=1;emit_snapshot(latest_snapshot);last_scan=time.monotonic()
                next_scan=now+(120 if session and session.ready else 60)
            if request_logs:
                request_logs.sync(session.rollout_paths if session else {},now,batch_interval)
                request_logs.read(now,batch_interval)
            if session and session.queue and now>=flush_at:
                flush_events(session);last_flush=now;flush_at=now+batch_interval
            stamp=(bool(session and session.ready),len(session.attached) if session else 0)
            if stamp!=status_stamp and last_scan>-1e8:
                next_scan=last_scan+(120 if session and session.ready else 60)
            if now>=next_status or stamp!=status_stamp:
                emit(stats(session,scans))
                next_status=now+15; status_stamp=stamp
            if session and session.ready and not session.pending:
                if quiet_since is None:quiet_since=now
            else:quiet_since=None
            if once and (ws is None or now>=once_deadline or quiet_since is not None and now-quiet_since>=.3 and not ws.buf):
                flush_events(session)
                emit(stats(session,scans))
                break
            if session and session.ready and now>=next_ping:
                ws.send_frame(9,b'pacer');next_ping=now+15
            delay=max(.01,min(flush_at-now if session and session.queue else 15,next_status-now,next_scan-now if not local_only else 15,(reconnect_at-now) if ws is None else 15))
            if session and session.pending:delay=min(delay,max(.01,min(5-(now-v[2]) for v in session.pending.values())))
            if session and session.ready and hints:delay=min(delay,max(.01,min(due-now for _,due in hints.values())))
            if index_changes:delay=min(delay,max(.01,index_changes.next_check-now))
            if request_logs:
                delay=min(delay,max(.01,request_logs.next_poll-now))
                if request_logs.due is not None:delay=min(delay,max(.01,request_logs.due-now))
            if session and session.ready and discovery_dirty and not session.listing:delay=min(delay,max(.01,next_discovery-now))
            if once:delay=min(delay,.1,max(.01,once_deadline-now))
            readers=([ws.s] if ws else [])+([0] if controlled_input else [])
            if index_changes and index_changes.fd>=0:readers.append(index_changes.fd)
            if request_logs and request_logs.fd>=0:readers.append(request_logs.fd)
            if readers:
                ready=select.select(readers,[],[],0 if ws and ws.buf else delay)[0]
                if index_changes and index_changes.fd in ready and index_changes.drain():discovery_dirty=True;index_rechecks=2
                if request_logs and request_logs.fd in ready:request_logs.drain(time.monotonic(),batch_interval)
                if controlled_input and 0 in ready and not read_hints():break
                if ws and (ws.buf or ws.s in ready):session.receive(ws.receive())
            else:time.sleep(delay)
        except (BrokenPipeError,KeyboardInterrupt):break
        except (OSError,ValueError,EOFError,TimeoutError,TypeError,AttributeError,KeyError,struct.error):
            # Valid endings may still be waiting for the batch deadline.
            # Deliver them before a disconnected status can revoke live state.
            try:flush_events(session)
            except BrokenPipeError:break
            if ws:ws.close()
            ws=None;session=None;reconnect_at=time.monotonic()+30;next_status=0
            if once:emit({'kind':'status','connected':False,'attached':0,'notifications':0,'fallbackScans':scans});break
    try:flush_events(session)
    except BrokenPipeError:pass
    if ws:ws.close()
    if index_changes:index_changes.close()
    if request_logs:request_logs.close()
    """#
}

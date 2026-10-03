import Foundation

enum RealtimeProbe {
    static let library = SessionLogProbe.library + "\n" + #"""
    import socket, struct, select, hashlib, secrets, stat, uuid
    MAX=4*1024*1024
    def valid_id(v):
        try: return isinstance(v,str) and str(uuid.UUID(v))==v.lower()
        except (ValueError,AttributeError): return False
    def is_review(t):
        source=str(t.get('threadSource') or '').lower().replace('_','')
        model=str(t.get('model') or '').lower()
        s=t.get('source') or {}; sub=s.get('subAgent',s.get('subagent',{})) if isinstance(s,dict) else {}
        return source in ('guardianreview','autoreview','subagentreview') or model.startswith('codex-auto-review') or sub=='review' or isinstance(sub,dict) and (sub.get('other') in ('guardian','autoreview','auto_review') or 'review' in sub)
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
        elif method=='thread/status/changed':
            status=p.get('status') or {}
            e['status']=str(status.get('type',''))[:32]
            e['flags']=[f for f in status.get('activeFlags',[]) if f in ('waitingOnApproval','waitingOnUserInput')]
        elif method in ('item/agentMessage/delta','item/plan/delta','item/reasoning/summaryTextDelta','item/reasoning/textDelta'):
            if isinstance(p.get('itemId'),str): e['itemId']=p['itemId'][:256]
            # Text content is deliberately never forwarded or tokenized.
        else: return None
        return e
    class Session:
        def __init__(self,ws):
            self.ws=ws; self.ready=False; self.pending={}; self.next_id=1; self.known={}; self.excluded=set(); self.attached=set(); self.attaching=set(); self.evidenced=set(); self.queue=[]; self.buffered={}; self.notices=0; self.last_rpc=time.monotonic(); self.last_list=0
            self.request('initialize',{'clientInfo':{'name':'codex-pacer-events','version':'2.0.1'},'capabilities':{'experimentalApi':True}},'initialize')
        def request(self,method,params,kind,tid=None):
            # This allowlist prevents a monitor from sending task input/config changes.
            if method not in ('initialize','thread/loaded/list','thread/read','thread/resume'): raise ValueError('request not allowed')
            rid=self.next_id; self.next_id+=1; self.pending[rid]=(kind,tid,time.monotonic())
            self.ws.send({'id':rid,'method':method,'params':params})
        def read_thread(self,tid):
            if not valid_id(tid) or tid in self.excluded or any(v[0]=='read' and v[1]==tid for v in self.pending.values()): return
            if len(self.pending)>=64 or len(self.attached)>=32: return
            self.request('thread/read',{'threadId':tid,'includeTurns':False},'read',tid)
        def queue_event(self,e):
            if e is None:return
            if e.get('turnId'):self.evidenced.add(e['threadId'])
            if self.queue and ('Delta' in e['method'] or e['method'].endswith('/delta')) and self.queue[-1].get('method')==e['method'] and self.queue[-1].get('itemId')==e.get('itemId') and self.queue[-1].get('threadId')==e['threadId']:
                self.queue[-1]=e
            else: self.queue.append(e)
            if len(self.queue)>512: raise ValueError('event queue bound')
        def receive(self,v):
            if v is None:return
            if 'id' in v and v['id'] in self.pending:
                kind,tid,_=self.pending.pop(v['id'])
                if 'error' in v:
                    if kind=='initialize': raise ValueError('initialize rejected')
                    self.attaching.discard(tid); return
                result=v.get('result') or {}
                if kind=='initialize':
                    self.ws.send({'method':'initialized'}); self.ready=True
                    self.request('thread/loaded/list',{},'list'); self.last_list=time.monotonic()
                elif kind=='list':
                    for thread in result.get('data',[])[:32]: self.read_thread(thread)
                elif kind in ('read','resume'):
                    thread=result.get('thread') or {}
                    if not isinstance(thread,dict) or thread.get('id')!=tid or is_review(thread):
                        if len(self.excluded)<1024:self.excluded.add(tid)
                        self.known.pop(tid,None);self.buffered.pop(tid,None);self.attached.discard(tid);self.attaching.discard(tid);return
                    self.known[tid]=thread.get('status') or {}
                    meta={'method':'metadata','threadId':tid.lower(),'at':time.time(),'source':thread.get('threadSource') if isinstance(thread.get('threadSource'),str) else ''}
                    for k,bound in (('name',240),('cwd',2048),('model',256)):
                        if isinstance(thread.get(k),str):meta[k]=thread[k][:bound]
                    self.queue_event(meta)
                    if kind=='resume':
                        self.attaching.discard(tid); self.attached.add(tid)
                    elif self.known[tid].get('type')=='active' and tid not in self.attached and tid not in self.attaching:
                        self.attaching.add(tid)
                        # The versioned protocol rejoins an already running thread.
                        # Never resume an idle/unloaded thread or pass config overrides.
                        self.request('thread/resume',{'threadId':tid,'excludeTurns':True},'resume',tid)
                    for queued in self.buffered.pop(tid,[]): self.queue_event(queued)
                return
            method=v.get('method');p=v.get('params') or {}
            if not isinstance(method,str) or not isinstance(p,dict):return
            self.notices+=1;self.last_rpc=time.monotonic()
            if method=='thread/started':
                tid=(p.get('thread') or {}).get('id');self.read_thread(tid);return
            e=event(method,p)
            if e is None:return
            tid=e['threadId']
            if tid in self.excluded:return
            if method=='thread/status/changed':
                if e.get('status')=='active' and tid not in self.attached:self.read_thread(tid)
                if e.get('status')=='notLoaded':self.attached.discard(tid);self.attaching.discard(tid);self.evidenced.discard(tid)
            if tid in self.known:self.queue_event(e)
            else:
                self.read_thread(tid)
                if tid not in self.buffered and len(self.buffered)>=64:return
                q=self.buffered.setdefault(tid,[])
                if len(q)<64:q.append(e)
    import resource
    def emit(obj):
        data=(json.dumps(obj,separators=(',',':'))+'\n').encode()
        while data:
            written=os.write(1,data);data=data[written:]
    def stats(session,scans):
        usage=resource.getrusage(resource.RUSAGE_SELF)
        return {'kind':'status','connected':bool(session and session.ready),'attached':len(session.attached) if session else 0,'notifications':session.notices if session else 0,'fallbackScans':scans,'watchingLogs':False,'helperCpuSeconds':round(usage.ru_utime+usage.ru_stime,6),'helperLoopIterations':loop_iterations}
    """#
    static let script = library + "\n" + #"""
    ws=None; session=None; reconnect_at=0; next_scan=0; next_status=0; next_ping=0; flush_at=0; scans=0; last_scan=-1e9; latest_snapshot=None; status_stamp=None; once_deadline=time.monotonic()+6; quiet_since=None; loop_iterations=0
    once=len(sys.argv)>2 and sys.argv[2]=='once'
    local_only=len(sys.argv)>2 and sys.argv[2]=='socket-only'
    ssh_lifetime=len(sys.argv)>2 and sys.argv[2]=='ssh-lifetime'
    while True:
        loop_iterations+=1
        try:
            now=time.monotonic()
            if ssh_lifetime and select.select([0],[],[],0)[0] and not os.read(0,4096):break
            if ws is None and now>=reconnect_at:
                try:
                    ws=WebSocket(home/'app-server-control'/'app-server-control.sock');session=Session(ws);next_status=now
                except (OSError,ValueError,EOFError):
                    if ws:ws.close()
                    ws=None;session=None;reconnect_at=now+30
            if session and (any(now-v[2]>5 for v in session.pending.values()) or now-ws.last_receive>45):raise TimeoutError()
            if session and session.ready and now-session.last_list>=60:
                session.request('thread/loaded/list',{},'list');session.last_list=now
            if now>=next_scan and not local_only:
                latest_snapshot=snapshot(excluding=session.evidenced if session and session.ready else ());scans+=1;emit(latest_snapshot);last_scan=time.monotonic()
                next_scan=now+(120 if session and session.ready else 60)
            if session and session.queue and now>=flush_at:
                emit({'kind':'runtimeBatch','events':session.queue});session.queue=[];flush_at=now+.25
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
                if session and session.queue: emit({'kind':'runtimeBatch','events':session.queue});session.queue=[]
                emit(stats(session,scans))
                break
            if session and session.ready and now>=next_ping:
                ws.send_frame(9,b'pacer');next_ping=now+15
            delay=max(.01,min(.25 if session and session.queue else 15,next_status-now,next_scan-now if not local_only else 15,(reconnect_at-now) if ws is None else 15))
            if session and session.pending:delay=min(delay,max(.01,min(5-(now-v[2]) for v in session.pending.values())))
            if once:delay=min(delay,.1,max(.01,once_deadline-now))
            if ws:
                ready=select.select([ws.s]+([0] if ssh_lifetime else []),[],[],0 if ws.buf else delay)[0]
                if ssh_lifetime and 0 in ready and not os.read(0,4096):break
                if ws.buf or ws.s in ready:session.receive(ws.receive())
            elif ssh_lifetime:
                if select.select([0],[],[],delay)[0] and not os.read(0,4096):break
            else:time.sleep(delay)
        except (BrokenPipeError,KeyboardInterrupt):break
        except (OSError,ValueError,EOFError,TimeoutError,TypeError,AttributeError,KeyError,struct.error):
            if ws:ws.close()
            ws=None;session=None;reconnect_at=time.monotonic()+30;next_status=0
            if once:emit({'kind':'status','connected':False,'attached':0,'notifications':0,'fallbackScans':scans});break
    if ws:ws.close()
    """#
}

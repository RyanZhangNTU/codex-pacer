import Foundation

/// Desktop IPC v11 adapter. Retains a metadata projection, never transcripts.
enum DesktopEventProbe {
    static let library = RealtimeProbe.library + "\n" + #"""
    import copy, math, signal
    IPC_MAX=16*1024*1024
    TOOL_TYPES={'commandExecution','mcpToolCall','fileChange','dynamicToolCall','collabAgentToolCall','webSearch','imageView'}
    MODEL_TYPES={'reasoning','agentMessage','plan'}
    TERMINAL={'completed','failed','interrupted'}
    def text(v,bound):return v[:bound] if isinstance(v,str) else None
    def number(v):return v if type(v) in (int,float) and math.isfinite(v) else None
    def item_projection(v):
        if not isinstance(v,dict):return {}
        return {k:text(v[k],256 if k=='id' else 80) for k in ('id','type','status') if isinstance(v.get(k),str)}
    def turn_projection(v):
        if not isinstance(v,dict):return {}
        out={k:text(v[k],256) for k in ('turnId','status') if isinstance(v.get(k),str)}
        if number(v.get('turnStartedAtMs')) is not None:out['turnStartedAtMs']=v['turnStartedAtMs']
        items=v.get('items') or []
        if not isinstance(items,list) or len(items)>8192:raise ValueError('item bound')
        out['items']=[item_projection(i) for i in items]
        return out
    def usage_projection(v):
        if not isinstance(v,dict):return {}
        return {k:{'outputTokens':v[k]['outputTokens']} for k in ('total','last') if isinstance(v.get(k),dict) and type(v[k].get('outputTokens')) is int and v[k]['outputTokens']>=0}
    def runtime_projection(v):
        if not isinstance(v,dict):return {}
        return {'type':text(v.get('type'),32),'activeFlags':[f for f in v.get('activeFlags',[]) if f in ('waitingOnApproval','waitingOnUserInput')]}
    def snapshot_projection(v):
        out={k:text(v[k],2048 if k=='cwd' else 256) for k in ('title','cwd','latestModel','threadSource') if isinstance(v.get(k),str)}
        out['latestTokenUsageInfo']=usage_projection(v.get('latestTokenUsageInfo'))
        out['threadRuntimeStatus']=runtime_projection(v.get('threadRuntimeStatus'))
        turns=v.get('turns') or []
        if len(turns)>512:raise ValueError('turn bound')
        out['turns']=[turn_projection(t) for t in turns]
        history=v.get('turnHistory') or {}
        if history.get('kind')=='canonical':
            entities=(history.get('history') or {}).get('entitiesByKey') or {}
            if not isinstance(entities,dict) or len(entities)>512:raise ValueError('history bound')
            out['turnHistory']={'kind':'canonical','history':{'entitiesByKey':{k:turn_projection(t) for k,t in entities.items()}}}
        return out
    def project_patch(path,v):
        # Return only values used by status/rate; drop arbitrary body fields.
        if not path:return False,None
        root=path[0]
        if root in ('title','cwd','latestModel','threadSource') and len(path)==1:return True,text(v,2048 if root=='cwd' else 256)
        if root=='latestTokenUsageInfo':
            if len(path)==1:return True,usage_projection(v)
            if len(path)==2 and path[1] in ('total','last'):return True,usage_projection({path[1]:v}).get(path[1],{})
            if len(path)==3 and path[1] in ('total','last') and path[2]=='outputTokens':return True,v if type(v) is int and v>=0 else None
            return False,None
        if root=='threadRuntimeStatus':
            if len(path)==1:return True,runtime_projection(v)
            if path[1:]==['type']:return True,text(v,32)
            if path[1:]==['activeFlags']:return True,[f for f in (v or []) if f in ('waitingOnApproval','waitingOnUserInput')]
            return False,None
        if root=='turnHistory':
            if len(path)==1:return True,snapshot_projection({'turnHistory':v}).get('turnHistory',{})
            if path[1:]==['kind']:return True,text(v,32)
            if path[1:3]!=['history','entitiesByKey']:return False,None
            if len(path)==3:
                if not isinstance(v,dict) or len(v)>512:raise ValueError('history bound')
                return True,{k:turn_projection(t) for k,t in v.items()}
            suffix=path[4:]
        elif root=='turns':
            if len(path)==1:
                if not isinstance(v,list) or len(v)>512:raise ValueError('turn bound')
                return True,[turn_projection(t) for t in v]
            suffix=path[2:]
        else:return False,None
        if not suffix:return True,turn_projection(v)
        if suffix in (['turnId'],['status']):return True,text(v,256)
        if suffix==['turnStartedAtMs']:return True,number(v)
        if suffix[0]!='items':return False,None
        if len(suffix)==1:
            if not isinstance(v,list) or len(v)>8192:raise ValueError('item bound')
            return True,[item_projection(i) for i in v]
        if type(suffix[1]) is not int or not 0<=suffix[1]<8192:raise ValueError('item index bound')
        if len(suffix)==2:return True,item_projection(v)
        if len(suffix)==3 and suffix[2] in ('id','type','status'):return True,text(v,256)
        return False,None
    def prepare_patch(patch):
        if not isinstance(patch,dict):raise ValueError('patch shape')
        path=patch.get('path');op=patch.get('op')
        if not isinstance(path,list) or len(path)>12 or op not in ('add','replace','remove'):raise ValueError('patch shape')
        keep,value=project_patch(path,patch.get('value'))
        return (path,op,value) if keep else None
    def apply_patch(tree,patch):
        path,op,value=patch
        node=tree
        for i,key in enumerate(path[:-1]):
            if isinstance(node,list):
                if type(key) is not int or not 0<=key<len(node):raise ValueError('patch gap')
                node=node[key]
            elif isinstance(node,dict):
                if key not in node:node[key]=[] if type(path[i+1]) is int else {}
                node=node[key]
            else:raise ValueError('patch gap')
        key=path[-1]
        if isinstance(node,list):
            if type(key) is not int or not 0<=key<=len(node):raise ValueError('patch gap')
            if op=='remove':
                if key>=len(node):raise ValueError('patch gap')
                node.pop(key)
            elif op=='add':node.insert(key,value)
            else:
                if key>=len(node):raise ValueError('patch gap')
                node[key]=value
        elif isinstance(node,dict):
            if op=='remove':node.pop(key,None)
            else:node[key]=value
        else:raise ValueError('patch gap')
    class Projection:
        def __init__(self,tid):
            self.tid=tid;self.owner=None;self.revision=None;self.tree={};self.turn=None;self.items={};self.usage=None
        def current(self):
            history=self.tree.get('turnHistory') or {}
            turns=list((history.get('history',{}).get('entitiesByKey') or {}).values()) if history.get('kind')=='canonical' else self.tree.get('turns',[])
            candidates=[t for t in turns if isinstance(t,dict) and isinstance(t.get('turnId'),str)]
            return max(candidates,key=lambda t:t.get('turnStartedAtMs') or 0,default=None)
        def consume(self,change,owner):
            snapshot=change.get('type')=='snapshot'
            revision=change.get('revision')
            if type(revision) is not int or revision<0:raise ValueError('revision shape')
            if snapshot:
                raw=change.get('conversationState')
                if not isinstance(raw,dict) or is_review({'source':raw.get('source'),'threadSource':raw.get('threadSource'),'model':raw.get('latestModel')}):raise ValueError('excluded review')
                self.tree=snapshot_projection(raw);self.owner=owner;self.revision=revision
            else:
                if change.get('type')!='patches' or owner!=self.owner or change.get('baseRevision')!=self.revision or revision!=self.revision+1:raise ValueError('revision gap')
                patches=change.get('patches') or []
                if not isinstance(patches,list) or len(patches)>4096:raise ValueError('patch bound')
                # Validate the entire batch before touching state. Text deltas
                # still produce activity events below, but do not copy history.
                projected=[]
                for patch in patches:
                    prepared=prepare_patch(patch)
                    if prepared is not None:projected.append(prepared)
                if projected:
                    # Apply atomically: malformed patches never manufacture a terminal turn.
                    tree=copy.deepcopy(self.tree)
                    for patch in projected:apply_patch(tree,patch)
                    self.tree=tree
                self.revision=revision
            now=time.time();events=[]
            def add(method,**values):events.append(dict(method=method,threadId=self.tid,at=now,**values))
            meta={'method':'metadata','threadId':self.tid,'at':now}
            for src,dst in (('title','name'),('cwd','cwd'),('latestModel','model'),('threadSource','source')):
                if isinstance(self.tree.get(src),str):meta[dst]=self.tree[src]
            if snapshot or any(p.get('path',[None])[0] in ('title','cwd','latestModel') for p in change.get('patches',[]) if p.get('path')):events.append(meta)
            current=self.current()
            if current is None:return events
            tid=current['turnId'];status=current.get('status');previous=self.turn
            changed=previous is None or previous['turnId']!=tid
            if changed:
                self.items={};self.usage=None
                if status=='inProgress':
                    started=number(current.get('turnStartedAtMs'))
                    add('turn/attached' if snapshot else 'turn/started',turnId=tid,startedAt=started/1000 if started and 0<started<=now*1000+5000 else now)
            elif previous.get('status')=='inProgress' and status in TERMINAL:
                add('turn/completed',turnId=tid,status=status)
            active=status=='inProgress'
            items={i['id']:i for i in current.get('items',[]) if isinstance(i,dict) and isinstance(i.get('id'),str)}
            if active:
                for iid,item in items.items():
                    kind=item.get('type');old=self.items.get(iid,{})
                    if kind in TOOL_TYPES:
                        if item.get('status')=='inProgress' and old.get('status')!='inProgress':add('item/started',turnId=tid,itemId=iid,itemType='collabToolCall' if kind=='collabAgentToolCall' else kind)
                        elif old.get('status')=='inProgress' and item.get('status') in TERMINAL:add('item/completed',turnId=tid,itemId=iid,itemType=kind)
                if not snapshot:
                    for patch in change.get('patches',[]):
                        path=patch.get('path') or []
                        if 'items' not in path:continue
                        prefix=path[:path.index('items')]
                        # Ignore updates to historical turns or other canonical islands.
                        node=self.tree
                        try:
                            for key in prefix:node=node[key]
                            if node.get('turnId')!=tid:continue
                            index=path[path.index('items')+1];item=node['items'][index]
                            kind=item.get('type');iid=item.get('id')
                            if kind in MODEL_TYPES and iid:
                                add('item/reasoning/textDelta' if kind=='reasoning' else 'item/agentMessage/delta',turnId=tid,itemId=iid)
                        except (KeyError,IndexError,TypeError,AttributeError):continue
                runtime=self.tree.get('threadRuntimeStatus') or {}
                add('thread/status/changed',status=runtime.get('type'),flags=runtime.get('activeFlags',[]))
                usage=self.tree.get('latestTokenUsageInfo') or {}
                count=(usage.get('total') or {}).get('outputTokens')
                if type(count) is int and count!=self.usage:
                    values={'turnId':tid,'outputTokens':count};last=(usage.get('last') or {}).get('outputTokens')
                    if type(last) is int:values['lastOutputTokens']=last
                    add('thread/tokenUsage/updated',**values);self.usage=count
            self.turn={k:current.get(k) for k in ('turnId','status','turnStartedAtMs')};self.items=items
            return events
    class IPC:
        def __init__(self):
            path=home/'ipc'/'ipc.sock'
            for p,test in ((path.parent,stat.S_ISDIR),(path,stat.S_ISSOCK)):
                info=p.lstat()
                if info.st_uid!=os.getuid() or info.st_mode&0o077 or not test(info.st_mode):raise OSError('unsafe IPC')
            self.s=socket.socket(socket.AF_UNIX);self.s.settimeout(2);self.buf=b''
            try:self.s.connect(str(path))
            except Exception:self.s.close();raise
        def send(self,v):
            b=json.dumps(v,separators=(',',':')).encode();self.s.sendall(struct.pack('<I',len(b))+b)
        def readn(self,n):
            while len(self.buf)<n:
                b=self.s.recv(65536)
                if not b:raise EOFError()
                self.buf+=b
            b,self.buf=self.buf[:n],self.buf[n:];return b
        def receive(self):
            n=struct.unpack('<I',self.readn(4))[0]
            if not 0<n<=IPC_MAX:raise ValueError('IPC frame bound')
            v=json.loads(self.readn(n))
            if not isinstance(v,dict):raise ValueError('IPC envelope')
            return v
        def close(self):self.s.close()
    class DesktopSession:
        def __init__(self,ipc):
            self.ws=ipc;self.ready=False;self.client=None;self.pending_follow={};self.streams={};self.attached=set();self.followed=set();self.waiting=OrderedDict();self.excluded=set();self.queue=[];self.notices=0;self.opened=time.monotonic();self.last_receive=self.opened;self.resync={}
            ipc.send({'type':'request','method':'initialize','requestId':str(uuid.uuid4()),'sourceClientId':'initializing-client','version':0,'params':{'clientType':'codex-pacer-events'}})
        def follow(self,tid,value):
            self.ws.send({'type':'broadcast','method':'thread-stream-following-changed','sourceClientId':self.client,'version':1,'params':{'conversationId':tid,'hostId':'local','following':value}})
            if value:self.followed.add(tid)
            else:self.followed.discard(tid)
        def drain_waiting(self):
            while self.waiting and len(self.followed)<32:
                tid,_=self.waiting.popitem(last=False)
                if tid not in self.excluded and tid not in self.followed:self.follow(tid,True)
        def release(self,tid):
            self.queue_event({'method':'stream/released','threadId':tid,'at':time.time()})
            self.follow(tid,False);self.streams.pop(tid,None);self.attached.discard(tid);self.resync.pop(tid,None)
            self.waiting.pop(tid,None);self.drain_waiting()
        def queue_event(self,e):
            if self.queue and ('Delta' in e['method'] or e['method'].endswith('/delta')) and self.queue[-1].get('method')==e['method'] and self.queue[-1].get('itemId')==e.get('itemId') and self.queue[-1].get('threadId')==e['threadId']:self.queue[-1]=e
            else:self.queue.append(e)
            if len(self.queue)>512:raise ValueError('event queue bound')
        def receive(self,v):
            self.last_receive=time.monotonic()
            kind=v.get('type');method=v.get('method')
            if kind=='client-discovery-request':self.ws.send({'type':'client-discovery-response','requestId':v.get('requestId'),'response':{'canHandle':False}});return
            if kind=='request':self.ws.send({'type':'response','requestId':v.get('requestId'),'resultType':'error','error':'no-handler-for-request'});return
            if kind=='response' and method=='initialize':
                client=(v.get('result') or {}).get('clientId')
                if v.get('resultType')!='success' or not valid_id(client):raise ValueError('initialize rejected')
                self.client=client;self.ready=True
                pending,self.pending_follow=self.pending_follow,{}
                for message in pending.values():self.receive(message)
                return
            if kind!='broadcast':return
            p=v.get('params') or {};tid=p.get('conversationId')
            if p.get('hostId')!='local' or not valid_id(tid):return
            if not self.ready:
                if len(self.pending_follow)<32 and method in ('thread-stream-following-changed','thread-stream-following-status-requested'):
                    self.pending_follow[tid]={'type':'broadcast','method':method,'version':v.get('version'),'targetClientIds':v.get('targetClientIds'),'params':{'hostId':'local','conversationId':tid,'following':p.get('following')}}
                return
            targets=v.get('targetClientIds')
            if targets is not None and self.client not in targets:return
            if method in ('thread-stream-following-changed','thread-stream-following-status-requested') and v.get('version')==1:
                if (method.endswith('status-requested') or p.get('following') is True) and tid not in self.excluded and tid not in self.followed:
                    if len(self.waiting)<64:self.waiting[tid]=True
                    self.drain_waiting()
                elif p.get('following') is False:self.waiting.pop(tid,None)
                return
            if method!='thread-stream-state-changed' or tid not in self.followed:return
            if v.get('version')!=11:raise ValueError('IPC version changed')
            owner=v.get('sourceClientId')
            if not valid_id(owner):raise ValueError('invalid owner')
            self.notices+=1;change=p.get('change') or {}
            projection=self.streams.get(tid) or Projection(tid)
            try:
                events=projection.consume(change,owner);self.streams[tid]=projection
            except ValueError as error:
                self.streams.pop(tid,None);self.attached.discard(tid);self.queue=[e for e in self.queue if e.get('threadId')!=tid]
                emit({'kind':'streamInvalidated','threadId':tid})
                if str(error)=='excluded review':
                    self.excluded.add(tid);self.follow(tid,False)
                    self.waiting.pop(tid,None);self.drain_waiting()
                elif time.monotonic()>=self.resync.get(tid,0):
                    self.resync[tid]=time.monotonic()+30;self.follow(tid,True)
                return
            if projection.turn and projection.turn.get('status')=='inProgress':self.attached.add(tid)
            else:self.attached.discard(tid)
            for e in events:self.queue_event(e)
            if projection.turn and projection.turn.get('status') in TERMINAL:self.release(tid)
    """#
    static let script = library + "\n" + #"""
    ipc=None;session=None;reconnect_at=0;next_status=0;flush_at=0;status_stamp=None;loop_iterations=0;scans=0
    once=len(sys.argv)>2 and sys.argv[2]=='once';deadline=time.monotonic()+6;quiet_since=None
    def stop(*args):raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,stop)
    while True:
        loop_iterations+=1
        try:
            now=time.monotonic()
            if ipc is None and now>=reconnect_at:
                ipc=IPC();session=DesktopSession(ipc);next_status=now
            if session and not session.ready and now-session.opened>5:raise TimeoutError()
            if session and session.queue and now>=flush_at:
                emit({'kind':'runtimeBatch','events':session.queue});session.queue=[];flush_at=now+.25
            stamp=(bool(session and session.ready),len(session.attached) if session else 0)
            if now>=next_status or stamp!=status_stamp:
                emit(stats(session,0));next_status=now+15;status_stamp=stamp
            if once and (now>=deadline or session and session.ready and (session.streams or session.excluded) and now-session.last_receive>=.3 and not ipc.buf):
                if session and session.queue:emit({'kind':'runtimeBatch','events':session.queue});session.queue=[]
                emit(stats(session,0));break
            delay=max(.01,min(.25 if session and session.queue else 15,next_status-now,reconnect_at-now if ipc is None else 15,deadline-now if once else 15))
            if once:delay=min(delay,.1)
            if ipc:
                if ipc.buf or select.select([ipc.s],[],[],delay)[0]:session.receive(ipc.receive())
            else:time.sleep(delay)
        except (BrokenPipeError,KeyboardInterrupt):break
        except (OSError,ValueError,EOFError,TimeoutError,TypeError,AttributeError,KeyError,IndexError,struct.error,RecursionError):
            if ipc:ipc.close()
            ipc=None;session=None;reconnect_at=time.monotonic()+30;next_status=0
            if once:emit({'kind':'status','connected':False,'attached':0,'watchingLogs':False,'fallbackScans':0});break
    if ipc:
        if session and session.ready:
            for tid in list(session.followed):
                try:session.follow(tid,False)
                except OSError:break
        ipc.close()
    """#
}

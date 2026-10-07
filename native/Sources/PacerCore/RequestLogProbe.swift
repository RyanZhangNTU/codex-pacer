import Foundation

/// Supplements live lifecycle events with settled per-request usage. Reads only
/// runtime-provided rollout paths, incrementally, with bounded watches/cursors.
enum RequestLogProbe {
    static let library = #"""
    class RequestLogTailer:
        def __init__(self):
            self.entries={};self.watches={};self.dirty=set();self.fd=-1;self.next_poll=0;self.due=None
            if sys.platform.startswith('linux'):
                try:
                    import ctypes
                    self.libc=ctypes.CDLL(None,use_errno=True)
                    self.fd=self.libc.inotify_init1(os.O_NONBLOCK|os.O_CLOEXEC)
                except (OSError,AttributeError):pass
        def sync(self,paths,now,interval):
            desired={}
            for tid,(raw,expiry) in list(paths.items())[:64]:
                if expiry<now or not valid_id(tid) or not isinstance(raw,str) or len(raw)>4096:continue
                try:
                    path=pathlib.Path(raw).resolve();path.relative_to((home/'sessions').resolve())
                    if path.suffix!='.jsonl' or path.stem[-36:].lower()!=tid.lower():continue
                    desired[tid]=path
                except (ValueError,OSError):continue
            for tid in list(self.entries):
                if tid not in desired or self.entries[tid]['path']!=desired[tid]:
                    self.entries.pop(tid);self.dirty.discard(tid)
                    for wd,value in list(self.watches.items()):
                        if value==tid:
                            self.watches.pop(wd)
                            if self.fd>=0:self.libc.inotify_rm_watch(self.fd,wd)
            for tid,path in desired.items():
                if tid in self.entries:continue
                self.entries[tid]={'path':path,'cursor':None};self.dirty.add(tid)
                if self.fd>=0:
                    wd=self.libc.inotify_add_watch(self.fd,os.fsencode(path),0x2|0x8|0x400|0x800)
                    if wd>=0:self.watches[wd]=tid
            if self.dirty and self.due is None:self.due=now+interval
        def drain(self,now,interval):
            for _ in range(8):
                try:data=os.read(self.fd,65536)
                except BlockingIOError:break
                if not data:break
                offset=0
                while offset+16<=len(data):
                    wd,mask,_,length=struct.unpack_from('iIII',data,offset);offset+=16+length
                    if mask&0x4000:self.dirty.update(self.entries)
                    tid=self.watches.get(wd)
                    if tid:
                        self.dirty.add(tid)
                        if mask&(0x400|0x800|0x8000):
                            self.watches.pop(wd,None);self.entries.pop(tid,None)
            if self.dirty and self.due is None:self.due=now+interval
        def read(self,now,interval):
            # Fallback stat checks concern at most 64 known files, never a glob.
            if now>=self.next_poll:
                self.next_poll=now+(30 if self.fd>=0 and len(self.watches)==len(self.entries) else 2)
                for tid,entry in self.entries.items():
                    try:
                        stat=entry['path'].stat();old=entry['cursor']
                        if old is None or old[:2]!=(stat.st_ino,stat.st_size):self.dirty.add(tid)
                    except OSError:pass
                if self.dirty and self.due is None:self.due=now+interval
            if self.due is None or now<self.due:return
            pending=self.dirty;self.dirty=set();self.due=None
            for tid in pending:
                entry=self.entries.get(tid)
                if entry is None:continue
                try:
                    stat=entry['path'].stat();old=entry['cursor'];reset=old is None or old[0]!=stat.st_ino or old[1]>stat.st_size
                    offset=0 if reset else old[1];fragment=b'' if reset else old[2]
                    budget=512*1024 if reset else 128*1024;gap=stat.st_size-offset>budget;records=[]
                    with entry['path'].open('rb') as f:
                        if gap:
                            meta=header(f)
                            if meta:records.append(meta)
                            seed=anchor(f,stat.st_size)
                            if seed:records.append(seed)
                            offset=max(0,stat.st_size-budget);fragment=b'';reset=True
                        prelude=len(records);f.seek(offset);data=f.read(budget);fragment+=data;offset+=len(data)
                    if gap:
                        _,sep,fragment=fragment.partition(b'\n')
                        if not sep:fragment=b''
                    lines=fragment.split(b'\n');fragment=lines.pop()
                    for line in lines:
                        if len(line)>1024*1024:continue
                        value=parse(line)
                        if value:records.append(value)
                    if len(fragment)>1024*1024:fragment=b''
                    entry['cursor']=(stat.st_ino,offset,fragment)
                    for start in range(0,len(records),512):
                        emit({'kind':'performance','sessions':[{'threadId':tid,'reset':reset and start==0,
                            'partial':gap,'preludeCount':prelude if start==0 else 0,'records':records[start:start+512]}]})
                    if offset<stat.st_size:self.dirty.add(tid)
                except OSError:continue
            if self.dirty:self.due=now+interval
        def close(self):
            if self.fd>=0:os.close(self.fd);self.fd=-1
    """#
}

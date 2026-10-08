import Foundation

enum SessionLogProbe {
    // Only sanitized lifecycle and counters leave the remote host.
    static let library = #"""
    import base64, datetime, json, pathlib, sqlite3, sys, time, uuid
    home = pathlib.Path(base64.b64decode(sys.argv[1]).decode()).expanduser()
    cursors = {}
    headers = {}
    titles = {}
    def parent_thread(meta):
        source=meta.get('source');sub=(source.get('subAgent',source.get('subagent')) if isinstance(source,dict) else None)
        spawn=sub.get('thread_spawn',sub.get('threadSpawn')) if isinstance(sub,dict) else None
        raw=meta.get('parentThreadId',meta.get('parent_thread_id'))
        if raw is None and isinstance(spawn,dict):raw=spawn.get('parent_thread_id',spawn.get('parentThreadId'))
        try:
            return str(uuid.UUID(raw)) if isinstance(raw,str) and len(raw)==36 else None
        except (ValueError,AttributeError):return None
    def sanitize(o):
        outer, p = o.get('type'), o.get('payload', {})
        if not isinstance(p, dict): return None
        kind = p.get('type'); q = {}
        if outer == 'session_meta':
            parent=parent_thread(p)
            if parent and parent!=p.get('id'):q['parent_thread_id']=parent
            for k in ('id','cwd','thread_source'):
                if isinstance(p.get(k),str): q[k] = p[k][:2048]
            source = p.get('source')
            if isinstance(source,str): q['source'] = source[:80]
            elif isinstance(source,dict):
                sub=source.get('subagent',source.get('subAgent'))
                role=sub.get('other') if isinstance(sub,dict) else None
                if sub=='review' or isinstance(sub,dict) and 'review' in sub:q['source']={'subagent':'review'}
                elif isinstance(role,str):q['source']={'subagent':{'other':role[:80]}}
        elif outer == 'turn_context':
            for k in ('turn_id','model'):
                if isinstance(p.get(k),str): q[k] = p[k][:256]
        elif outer == 'event_msg' and kind in ('task_started','task_complete','turn_aborted','token_count'):
            q['type'] = kind
            if isinstance(p.get('turn_id'),str): q['turn_id'] = p['turn_id'][:256]
            if kind == 'token_count':
                total = (p.get('info') or {}).get('total_token_usage') or {}
                output = total.get('output_tokens')
                if isinstance(output,int) and output >= 0:
                    q['info'] = {'total_token_usage':{'output_tokens':output}}
                    last=(p.get('info') or {}).get('last_token_usage') or {}
                    if isinstance(last.get('output_tokens'),int):
                        q['info']['last_token_usage']={'output_tokens':last['output_tokens']}
                        if isinstance(last.get('reasoning_output_tokens'),int):q['info']['last_token_usage']['reasoning_output_tokens']=last['reasoning_output_tokens']
        elif outer == 'token_usage_record':
            usage=p.get('usage') or {}
            if not isinstance(usage,dict) or not isinstance(usage.get('output_tokens'),int) or isinstance(usage.get('output_tokens'),bool) or usage['output_tokens']<0:return None
            for k in ('response_id','thread_id','turn_id'):
                if not isinstance(p.get(k),str) or not p[k] or len(p[k])>256:return None
                q[k]=p[k]
            q['usage']={'output_tokens':usage['output_tokens']}
            if isinstance(usage.get('reasoning_output_tokens'),int) and not isinstance(usage.get('reasoning_output_tokens'),bool):q['usage']['reasoning_output_tokens']=usage['reasoning_output_tokens']
        elif outer == 'response_item' and kind in ('function_call','custom_tool_call','function_call_output','custom_tool_call_output','reasoning','message'):
            if kind == 'message' and p.get('role') != 'assistant': return None
            q['type'] = kind
            for k in ('call_id','name','role','phase'):
                if isinstance(p.get(k),str): q[k] = p[k][:256]
        else: return None
        return {'timestamp':str(o.get('timestamp',''))[:80], 'type':outer, 'payload':q}
    def parse(line):
        try: return sanitize(json.loads(line))
        except (ValueError,TypeError,AttributeError): return None
    def header(f):
        f.seek(0); return parse(f.readline(1024*1024))
    def anchor(f,size):
        offset, floor, fragment = size, max(0,size-8*1024*1024), b''
        while offset > floor:
            start = max(floor,offset-128*1024); f.seek(start)
            data = f.read(offset-start) + fragment; lines = data.split(b'\n')
            for line in reversed(lines[1:]):
                if len(line) <= 1024*1024 and (b'turn_context' in line or b'task_started' in line):
                    v = parse(line)
                    if v and v['payload'].get('turn_id') and (v['type']=='turn_context' or v['payload'].get('type')=='task_started'): return v
            fragment = lines[0] if len(lines[0]) <= 1024*1024 else b''; offset=start
        return None
    def candidates():
        paths = set(cursors)
        titles.clear()
        for dbfile in sorted((p for p in home.glob('state_*.sqlite') if p.stem[6:].isdigit()), key=lambda p:int(p.stem[6:]), reverse=True):
            try:
                db = sqlite3.connect('file:'+str(dbfile)+'?mode=ro', uri=True, timeout=.05)
                cols = {r[1] for r in db.execute('pragma table_info(threads)')}
                order = next((c for c in ('recency_at_ms','updated_at_ms','updated_at','created_at') if c in cols),'rowid')
                filters=['rollout_path IS NOT NULL']
                if 'archived' in cols: filters.append('archived=0')
                if 'thread_source' in cols: filters.append("COALESCE(thread_source,'') NOT IN ('guardian_review','auto_review','autoreview')")
                if 'model' in cols: filters.append("COALESCE(model,'') NOT LIKE 'codex-auto-review%'")
                if 'rollout_path' in cols:
                    title_col = "COALESCE(NULLIF(TRIM(name),''),title)" if 'name' in cols and 'title' in cols else ('name' if 'name' in cols else ('title' if 'title' in cols else 'NULL'))
                    for row in db.execute('SELECT rollout_path,'+title_col+' FROM threads WHERE '+' AND '.join(filters)+' ORDER BY '+order+' DESC LIMIT 128'):
                        p=pathlib.Path(row[0])
                        if str(p).startswith(str(home/'sessions')+'/'): paths.add(p); titles[p]=row[1][:240] if isinstance(row[1],str) else None
                db.close(); break
            except (sqlite3.Error,OSError,ValueError): continue
        today = datetime.datetime.now()
        for delta in (0,1): paths.update((home/'sessions'/(today-datetime.timedelta(days=delta)).strftime('%Y/%m/%d')).glob('*.jsonl'))
        existing=[]
        for p in paths:
            try: existing.append((p,p.stat().st_mtime))
            except OSError: pass
        selected=[p for p,_ in sorted(existing,key=lambda r:r[1],reverse=True)[:128]]
        for p in list(headers):
            if p not in selected: del headers[p]
        return selected
    def snapshot(excluding=()):
        rows=[]; selected=[]
        for p in candidates():
            if len(selected)>=32: break
            if p.stem[-36:].lower() in excluding:
                selected.append(p);continue
            try:
                stat=p.stat()
                with p.open('rb') as f:
                    old=cursors.get(p)
                    cached=headers.get(p)
                    meta=cached[1] if cached and cached[0]==stat.st_ino else header(f)
                    headers[p]=(stat.st_ino,meta)
                    if meta:
                        q=meta['payload'];source=q.get('source')
                        sub=source.get('subagent',source.get('subAgent')) if isinstance(source,dict) else None
                        role=sub.get('other') if isinstance(sub,dict) else None
                        if q.get('thread_source') in ('guardian_review','auto_review','autoreview') or sub=='review' or isinstance(sub,dict) and 'review' in sub or role in ('guardian','auto_review','autoreview'):continue
                    selected.append(p); old=cursors.get(p); reset=old is None or old[0]!=stat.st_ino or old[1]>stat.st_size
                    offset=0 if reset else old[1]; fragment=b'' if reset else old[2]
                    budget=512*1024 if reset else 128*1024; gap=stat.st_size-offset>budget
                    records=[]
                    if reset or gap:
                        if meta: records.append(meta)
                        seed=anchor(f,stat.st_size)
                        if seed: records.append(seed)
                        offset=max(0,stat.st_size-budget); fragment=b''; reset=True
                    prelude_count=len(records)
                    f.seek(offset); data=f.read(budget); fragment+=data; offset+=len(data)
                    if gap:
                        _,sep,fragment=fragment.partition(b'\n')
                        if not sep: fragment=b''
                    lines=fragment.split(b'\n'); fragment=lines.pop()
                    for line in lines:
                        v=parse(line)
                        if v: records.append(v)
                    if len(fragment)>1024*1024: fragment=b''
                    cursors[p]=(stat.st_ino,offset,fragment,meta)
                    rows.append({'id':p.name,'title':titles.get(p),'reset':reset,'partial':gap,'preludeCount':prelude_count,'records':records})
            except OSError: continue
        for p in list(cursors):
            if p not in selected: del cursors[p]
        return {'sessions':rows}
    """#
}

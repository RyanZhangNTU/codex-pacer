import XCTest
@testable import PacerCore

final class ClaudeCollectorEfficiencyTests: XCTestCase {
    private let support = #"""
import ast,collections,tempfile,uuid

class FakeInotify:
    def __init__(self):self.next=1;self.masks=[]
    def inotify_add_watch(self,fd,path,mask):
        self.masks.append(mask);wd=self.next;self.next+=1;return wd
    def inotify_rm_watch(self,fd,wd):return 0

class FixtureTailer(Tailer):
    def __init__(self,home):
        # Real temporary files; injected notifications, no real host/listener.
        self.home=home;self.cursors={};self.watches={};self.dirty=set();self.scans=0
        self.fd,self.write_fd=os.pipe();os.set_blocking(self.fd,False)
        self.libc=FakeInotify();self.work=collections.Counter()
    def entries(self,path,limit):
        self.work['entries']+=1;return super().entries(path,limit)
    def modified(self,path):
        self.work['modified']+=1;return super().modified(path)
    def notify(self,path,mask,name=b''):
        wd=next(wd for wd,value in self.watches.items() if value==path)
        payload=name+b'\0' if name else b''
        os.write(self.write_fd,struct.pack('iIII',wd,mask,0,len(payload))+payload)
        return self.drain()
    def close(self):
        super().close();os.close(self.write_fd)

def line(value):return json.dumps(value,separators=(',',':')).encode()+b'\n'

def prompt(session,node):
    return {'type':'user','sessionId':session,'uuid':node,'timestamp':'2027-01-15T08:00:00Z',
            'origin':{'kind':'human'},'message':{'content':'PRIVATE synthetic prompt'}}

def append(file,values):
    with file.open('ab') as stream:
        for value in values:stream.write(line(value))

def finish(tailer):
    rows=[]
    for _ in range(80):
        rows.extend(tailer.read())
        if not tailer.dirty:return rows
    raise AssertionError('bounded synthetic append did not drain')
"""#

    private func evaluate(_ body: String) throws -> [String: Any] {
        let program = Data(ClaudeActivityProbe.script.utf8).base64EncodedString()
        let script = "__name__='fixture'\nimport base64,json,sys\nsource=base64.b64decode(sys.argv[1]).decode()\n" +
            "import ast\nast.parse(source,feature_version=(3,6))\nexec(compile(source,'claude_efficiency_fixture','exec'),globals())\n" + support + "\n" + body
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", script, program]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = stdout; child.standardError = stderr
        try child.run()
        let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        let data = stdout.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(child.terminationStatus, 0, error)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testKnownAppendReadsImmediatelyWithoutInventoryAndDiscoveryStillHandlesNewSourcesAndRotation() throws {
        let result = try evaluate(#"""
with tempfile.TemporaryDirectory(prefix='pacer-claude-efficiency-') as temporary:
    home=pathlib.Path(temporary);projects=home/'projects';spool=home/'pacer';spool.mkdir()
    for project_index in range(64):
        project=projects/('project-%02d'%project_index);project.mkdir(parents=True)
        for session_index in range(16):
            session=str(uuid.UUID(int=1+project_index*16+session_index))
            (project/(session+'.jsonl')).write_bytes(b'')
    events=spool/'events.jsonl';events.write_bytes(b'');os.utime(str(events),(1900000000,1900000000))
    tailer=FixtureTailer(home)
    try:
        tailer.discover();finish(tailer)
        assert len(tailer.cursors)==32 and events in tailer.cursors
        assert all(mask&0x40 and mask&0x80 for mask in tailer.libc.masks)
        tailer.work.clear();before=tailer.scans;rows=[]
        for index in range(25):
            value={'kind':'prompt','origin':'hook','sessionId':'synthetic-session','promptId':'prompt-%d'%index,'at':1800000000+index}
            append(events,[value])
            assert tailer.notify(spool,0x2|0x8,b'events.jsonl') is False
            assert events in tailer.dirty
            rows.extend(finish(tailer))
        assert len(rows)==25 and all(row['kind']=='prompt' and row['historical'] is False for row in rows)
        scans=tailer.scans-before;entries=tailer.work['entries'];stats=tailer.work['modified']
        assert scans==0 and entries==0 and stats==0

        # A newly created transcript still reconciles immediately and is history.
        project=next(path for path in tailer.watches.values() if path.parent==projects)
        session='35857527-1d32-4bc3-881a-0259832b7d61';file=project/(session+'.jsonl')
        file.write_bytes(line(prompt(session,'new-prompt')))
        assert tailer.notify(project,0x100,file.name.encode()) is True
        tailer.discover();new_rows=finish(tailer)
        assert file in tailer.cursors and len(tailer.cursors)==32
        assert any(row['kind']=='prompt' and row['promptId']=='new-prompt' and row['historical'] for row in new_rows)

        # Rename notifications cannot be mistaken for ordinary known appends.
        replacement=project/'replacement.tmp';replacement.write_bytes(line(prompt(session,'replacement-prompt')))
        os.replace(str(replacement),str(file))
        assert tailer.notify(project,0x80,file.name.encode()) is True
        tailer.discover();replaced=finish(tailer)
        assert any(row['kind']=='prompt' and row['promptId']=='replacement-prompt' and row['historical'] for row in replaced)
        assert 'new-prompt' not in tailer.cursors[file].get('context',{})
        assert tailer.notify(project,0x40,file.name.encode()) is True
        file.unlink();assert tailer.notify(project,0x200,file.name.encode()) is True
        tailer.discover();finish(tailer);assert file not in tailer.cursors

        assert tailer.notify(spool,0x2,b'unknown.jsonl') is True
        assert tailer.notify(spool,0x2,b'../events.jsonl') is True
        assert tailer.notify(spool,0x2) is True
        tailer.dirty.clear()
        os.write(tailer.write_fd,struct.pack('iIII',-1,0x4000,0,0))
        assert tailer.drain() is True and tailer.dirty==set(tailer.cursors)
        tailer.dirty.clear()
        assert tailer.notify(events,0x8) is False and events in tailer.dirty
        # A truncated event buffer fails closed rather than losing a cursor.
        os.write(tailer.write_fd,struct.pack('iIII',-1,0x2,0,64)+b'x')
        assert tailer.drain() is True and tailer.dirty==set(tailer.cursors)
        print(json.dumps({'records':len(rows),'scans':scans,'entries':entries,'stats':stats,
                          'cursorLimit':32,'creationRotationOverflowPassed':True}))
    finally:tailer.close()
"""#)
        XCTAssertEqual(result["records"] as? Int, 25)
        XCTAssertEqual(result["scans"] as? Int, 0)
        XCTAssertEqual(result["entries"] as? Int, 0)
        XCTAssertEqual(result["stats"] as? Int, 0)
        XCTAssertEqual(result["cursorLimit"] as? Int, 32)
        XCTAssertEqual(result["creationRotationOverflowPassed"] as? Bool, true)
    }

    func testOneDecodePerLineKeepsWrapperOutputOwnedStopAndPrivateContentOutOfCursorContext() throws {
        let result = try evaluate(#"""
with tempfile.TemporaryDirectory(prefix='pacer-claude-decode-') as temporary:
    home=pathlib.Path(temporary);project=home/'projects'/'synthetic';project.mkdir(parents=True)
    session='35857527-1d32-4bc3-881a-0259832b7d61';file=project/(session+'.jsonl')
    file.write_bytes(line(prompt(session,'historical-prompt')))
    tailer=FixtureTailer(home)
    try:
        tailer.discover();finish(tailer)
        base={'sessionId':session,'timestamp':'2027-01-15T08:00:01Z'}
        values=[prompt(session,'live-prompt'),
          dict(base,type='attachment',uuid='attachment-1',parentUuid='live-prompt',attachment={'body':'PRIVATE'+('X'*288000)}),
          dict(base,type='assistant',uuid='answer-1',parentUuid='attachment-1',requestId='request-1',
               message={'id':'message-1','usage':{'output_tokens':180},'stop_reason':'end_turn',
                        'content':[{'type':'text','text':'PRIVATE answer'},{'type':'tool_use','id':'tool-1','name':'Bash','input':{'command':'PRIVATE command'}}]}),
          dict(base,type='system',subtype='stop_hook_summary',uuid='blocked-stop',parentUuid='answer-1',preventedContinuation=False,hookErrors=['PRIVATE error'],hookAdditionalContext=[]),
          dict(base,type='system',subtype='stop_hook_summary',uuid='context-stop',parentUuid='answer-1',preventedContinuation=False,hookErrors=[],hookAdditionalContext=['PRIVATE continuation']),
          dict(base,type='system',subtype='stop_hook_summary',uuid='unowned-stop',parentUuid='missing-parent',preventedContinuation=False,hookErrors=[],hookAdditionalContext=[]),
          dict(base,type='system',subtype='stop_hook_summary',uuid='clean-stop',parentUuid='answer-1',preventedContinuation=False,hookErrors=[],hookAdditionalContext=[]),
          dict(base,type='assistant',sessionId='other-session',uuid='foreign-answer',message={'content':'PRIVATE foreign'})]
        raw=[line(value) for value in values]+[b'{broken\n',b'[]\n',b'null\n']
        # Existing bytes-based callers retain exactly the same projection.
        context={'session':session,'parent':None};expected=[]
        for data in raw:
            owner=tailer.prompt_context(data,context)
            expected.extend(dict(row,historical=False) for row in transcript(data,session,None,owner))
        real_loads=json.loads;calls=[0]
        def counted_loads(data,*args,**kwargs):calls[0]+=1;return real_loads(data,*args,**kwargs)
        json.loads=counted_loads
        try:
            with file.open('ab') as stream:
                for data in raw:stream.write(data)
            tailer.dirty.add(file);rows=finish(tailer)
        finally:json.loads=real_loads
        assert calls[0]==len(raw) and rows==expected
        clean=[row for row in rows if row['kind']=='stopVerified' and row.get('promptId')=='live-prompt']
        unowned=[row for row in rows if row['kind']=='stopVerified' and row.get('unownedTurn')]
        assert len(clean)==1 and len(unowned)==1
        assert not any(row['kind']=='stopVerified' and row.get('promptId') in ('blocked-stop','context-stop') for row in rows)
        context_values=tailer.cursors[file].get('context',{})
        assert context_values['attachment-1']=='live-prompt' and context_values['answer-1']=='live-prompt'
        assert 'PRIVATE' not in json.dumps(rows) and 'PRIVATE' not in json.dumps(context_values)
        assert tailer.cursors[file]['fragment']==b''
        print(json.dumps({'loads':calls[0],'lines':len(raw),'sameOutput':True,'records':rows,
                          'contextOnlyIDs':True,'ownedStops':len(clean),'unownedStops':len(unowned)}))
    finally:tailer.close()
"""#)
        XCTAssertEqual(result["loads"] as? Int, result["lines"] as? Int)
        XCTAssertEqual(result["sameOutput"] as? Bool, true)
        XCTAssertEqual(result["contextOnlyIDs"] as? Bool, true)
        XCTAssertEqual(result["ownedStops"] as? Int, 1)
        XCTAssertEqual(result["unownedStops"] as? Int, 1)
        let rows = try XCTUnwrap(result["records"] as? [[String: Any]])
        var state = ClaudeActivityState(sourceID: "synthetic", sourceName: "Synthetic SSH")
        let payload = try XCTUnwrap(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": rows]))
        state.consume(payload, now: Date(timeIntervalSince1970: 1_800_000_010))
        let activity = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(activity.phase, .completed)
        XCTAssertEqual(activity.turnID, "live-prompt")
        XCTAssertNil(activity.firstTokenLatency)
    }
}

import XCTest
@testable import PacerCore

final class RequestLogProbeTests: XCTestCase {
    func testBoundedIncrementalTailSplitsRecordsAndRejectsOutsidePathsWithoutForwardingText() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-request-tail-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", RealtimeProbe.library + "\n" + Self.simulation, Data(home.path.utf8).base64EncodedString()]
        child.standardOutput = stdout; child.standardError = stderr
        try child.run()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "incremental bounded private")
    }
    private static let simulation = #"""
    tid='019a0000-0000-7000-8000-000000000001';folder=home/'sessions';folder.mkdir()
    path=folder/('rollout-'+tid+'.jsonl');stamp='2026-10-07T00:00:00Z'
    def record(kind,p):return json.dumps({'timestamp':stamp,'type':kind,'payload':p})+'\n'
    initial=record('session_meta',{'id':tid,'instructions':'PRIVATE'})+record('event_msg',{'type':'task_started','turn_id':'turn'})
    initial+=record('response_item',{'type':'message','role':'assistant','content':'PRIVATE'})
    initial+=record('token_usage_record',{'thread_id':tid,'turn_id':'turn','response_id':'r','usage':{'output_tokens':600,'reasoning_output_tokens':200},'PRIVATE':'PRIVATE'})
    path.write_text(initial)
    emitted=[]
    emit=lambda value:emitted.append(value)
    tail=RequestLogTailer();tail.sync({tid:(str(path),float('inf'))},0,.1);tail.read(.1,.1)
    assert emitted and len(emitted[0]['sessions'][0]['records'])==4
    assert 'PRIVATE' not in json.dumps(emitted)
    assert emitted[0]['sessions'][0]['records'][-1]['payload']['usage']['output_tokens']==600
    emitted.clear();tail.read(.3,.1);assert not emitted
    # Collapsed reads retain a five-second deadline; expanding flushes the same
    # cursor immediately, without rediscovery, replay or a second batch delay.
    with path.open('a') as f:f.write(record('token_usage_record',{'thread_id':tid,'turn_id':'turn','response_id':'expanded','usage':{'output_tokens':10}}))
    tail.dirty.add(tid);tail.due=5.3;tail.read(.35,5);assert not emitted
    tail.reschedule(.35,1,True);tail.read(.35,1)
    assert len(emitted)==1 and not emitted[0]['sessions'][0]['reset']
    assert emitted[0]['sessions'][0]['records'][0]['payload']['response_id']=='expanded'
    emitted.clear()
    line=record('token_usage_record',{'thread_id':tid,'turn_id':'turn','response_id':'r2','usage':{'output_tokens':40}})
    with path.open('a') as f:f.write(line[:20])
    tail.dirty.add(tid);tail.due=.4;tail.read(.4,.1);assert not emitted
    with path.open('a') as f:f.write(line[20:])
    tail.dirty.add(tid);tail.due=.5;tail.read(.5,.1)
    assert len(emitted)==1 and len(emitted[0]['sessions'][0]['records'])==1
    assert emitted[0]['sessions'][0]['records'][0]['payload']['response_id']=='r2'
    assert not emitted[0]['sessions'][0]['reset']
    emitted.clear()
    with path.open('a') as f:
        for i in range(600):f.write(record('token_usage_record',{'thread_id':tid,'turn_id':'turn','response_id':'r'+str(i),'usage':{'output_tokens':40}}))
    tail.dirty.add(tid);tail.due=.6;tail.read(.6,.1)
    assert len(emitted)==2 and all(len(frame['sessions'][0]['records'])<=512 for frame in emitted)
    assert sum(len(frame['sessions'][0]['records']) for frame in emitted)==600
    outside=home/('rollout-'+tid+'.jsonl');outside.write_text(initial)
    tail.sync({tid:(str(outside),float('inf'))},1,.1);assert not tail.entries
    tail.sync({tid:(str(path),.5)},1,.1);assert not tail.entries
    assert sanitize({'type':'token_usage_record','payload':{'thread_id':tid,'turn_id':'turn','response_id':'r','usage':{'output_tokens':True}}}) is None
    tail.close();print('incremental bounded private')
    """#
}

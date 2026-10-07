#!/usr/bin/env python3
"""Profile an isolated QA app using synthetic native IPC and request logs.

Requires a QA copy with separate bundle/executable/cache/lock paths. It must
support --energy-fixture to use synthetic quota without live account RPCs.
The sampler measures this process, not WindowServer, SSH hosts or battery drain.
"""
import argparse
import datetime
import json
import os
import pathlib
import plistlib
import select
import socket
import struct
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=pathlib.Path)
    parser.add_argument('--sampler', required=True, type=pathlib.Path)
    parser.add_argument('--mode', choices=['efficient', 'balanced', 'responsive'], default='balanced')
    parser.add_argument('--workload', choices=['idle', 'active'], default='active')
    parser.add_argument('--seconds', type=float, default=30)
    parser.add_argument('--expanded', action='store_true')
    parser.add_argument('--turn-seconds', type=float, default=10, help='Hold completion longer for UI acceptance; ordinary energy runs use 10 s')
    parser.add_argument('--output', required=True, type=pathlib.Path)
    args = parser.parse_args()
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    bundle, executable = info['CFBundleIdentifier'], info['CFBundleExecutable']
    if '.qa' not in bundle or executable == 'CodexPacerIsland':
        parser.error('Use an isolated QA identity, never the production app')
    if args.turn_seconds < 10:
        parser.error('Turn duration must include the eight-second response window')
    if args.seconds < 10:
        parser.error('Use at least a 10-second measurement window')
    for key, kind, value in [('performanceRefreshMode', '-string', args.mode), ('monitorSSH', '-bool', 'false'),
                              ('systemNotifications', '-bool', 'false'), ('appLanguage', '-string', 'en'),
                              ('islandDisplayMode', '-string', 'floating')]:
        subprocess.run(['defaults', 'write', bundle, key, kind, value], check=True)
    with tempfile.TemporaryDirectory(prefix='pacer-energy-', dir='/private/tmp') as root:
        home = pathlib.Path(root); ipc = home / 'ipc'; ipc.mkdir(mode=0o700)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(ipc / 'ipc.sock')); os.chmod(ipc / 'ipc.sock', 0o600); server.listen(1)
        ready, start, stop = threading.Event(), threading.Event(), threading.Event()
        report = {'packets': 0, 'settledRequests': 0}; errors = []
        tid = '019a0000-0000-7000-8000-000000000001'
        day = home / 'sessions' / datetime.datetime.now().strftime('%Y/%m/%d'); day.mkdir(parents=True)
        rollout = day / ('rollout-' + tid + '.jsonl')
        def log(kind, payload):
            record = {'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'), 'type': kind, 'payload': payload}
            with rollout.open('a') as f: f.write(json.dumps(record) + '\n')
        log('session_meta', {'id': tid, 'cwd': '/synthetic', 'title': 'Synthetic performance'})
        def serve():
            connection = None
            try:
                connection, _ = server.accept(); connection.settimeout(5)
                def readn(n):
                    result = b''
                    while len(result) < n:
                        part = connection.recv(n-len(result))
                        if not part: raise EOFError()
                        result += part
                    return result
                def read(): return json.loads(readn(struct.unpack('<I', readn(4))[0]))
                def send(value):
                    data = json.dumps(value, separators=(',', ':')).encode()
                    connection.sendall(struct.pack('<I', len(data)) + data); report['packets'] += 1
                read(); send({'type': 'response', 'method': 'initialize', 'resultType': 'success', 'result': {'clientId': '019a0000-0000-7000-8000-000000000010'}})
                send({'type': 'broadcast', 'method': 'thread-stream-following-status-requested', 'version': 1, 'params': {'hostId': 'local', 'conversationId': tid}})
                while read().get('params', {}).get('following') is not True: pass
                def change(value):
                    send({'type': 'broadcast', 'method': 'thread-stream-state-changed', 'version': 11, 'sourceClientId': '019a0000-0000-7000-8000-000000000020',
                          'params': {'hostId': 'local', 'conversationId': tid, 'change': value}})
                change({'type': 'snapshot', 'revision': 0, 'conversationState': {'title': 'Synthetic performance', 'cwd': '/synthetic', 'threadRuntimeStatus': {'type': 'idle', 'activeFlags': []}, 'turns': [], 'latestTokenUsageInfo': {'total': {'outputTokens': 0}, 'last': {'outputTokens': 0}}}})
                ready.set(); start.wait(); began = time.monotonic(); revision = 0; turn = -1; total = 0; finished = False
                def patches(values):
                    nonlocal revision
                    change({'type': 'patches', 'baseRevision': revision, 'revision': revision+1, 'patches': values}); revision += 1
                def replace(path, value): return {'op': 'replace', 'path': path, 'value': value}
                while not stop.is_set():
                    now = time.monotonic(); cycle = int((now-began)//args.turn_seconds); age = (now-began)%args.turn_seconds
                    if args.workload == 'active':
                        if cycle != turn:
                            turn = cycle; finished = False
                            log('event_msg', {'type': 'task_started', 'turn_id': 'turn-' + str(turn)})
                            patches([replace(['turns'], [{'turnId': 'turn-' + str(turn), 'status': 'inProgress', 'turnStartedAtMs': time.time()*1000,
                                'items': [{'id': 'answer', 'type': 'agentMessage', 'status': 'inProgress', 'text': ''}]}]), replace(['threadRuntimeStatus'], {'type': 'active', 'activeFlags': []})])
                        if 2 <= age < 8:
                            patches([replace(['turns', 0, 'items', 0, 'text'], 'synthetic output')])
                        elif age >= 8 and not finished:
                            total += 600; finished = True; report['settledRequests'] += 1
                            log('response_item', {'type': 'message', 'role': 'assistant'})
                            log('token_usage_record', {'response_id': 'response-' + str(turn), 'thread_id': tid, 'turn_id': 'turn-' + str(turn), 'usage': {'output_tokens': 600, 'reasoning_output_tokens': 200}})
                            log('event_msg', {'type': 'task_complete', 'turn_id': 'turn-' + str(turn)})
                            patches([replace(['turns', 0, 'items', 0, 'status'], 'completed'), replace(['latestTokenUsageInfo'], {'total': {'outputTokens': total}, 'last': {'outputTokens': 600, 'reasoningOutputTokens': 200}}), replace(['turns', 0, 'status'], 'completed')])
                    if select.select([connection], [], [], 0)[0]: read()
                    stop.wait(.05 if args.workload == 'active' else .5)
            except (BrokenPipeError, EOFError, ConnectionResetError): pass
            except Exception as error: errors.append(str(error)); ready.set()
            finally:
                if connection: connection.close()
        thread = threading.Thread(target=serve, daemon=True); thread.start()
        env = os.environ.copy(); env['CODEX_HOME'] = str(home)
        arguments = [str(args.app / 'Contents/MacOS' / executable), '--energy-fixture'] + (['--expanded'] if args.expanded else [])
        process = subprocess.Popen(arguments, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            if not ready.wait(10) or errors: raise RuntimeError(errors or 'IPC did not connect')
            time.sleep(2)
            def sample(): return json.loads(subprocess.check_output([str(args.sampler), str(process.pid)]))
            before = sample(); begin = time.monotonic(); start.set()
            for _ in range(int(args.seconds*10)): time.sleep(.1)
            after = sample(); duration = time.monotonic()-begin
            cpu = (after['user_ns']+after['system_ns']-before['user_ns']-before['system_ns'])/1e9
            energy = (after['energy_nj']-before['energy_nj'])/1e9
            result = {'scope': 'QA main process, synthetic quota and native IPC/logs; excludes WindowServer, other processes, network and remote hosts',
                'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'mode': args.mode, 'workload': args.workload,
                'expanded': args.expanded, 'durationSeconds': duration, 'cpuSeconds': cpu, 'cpuPercentOneCore': cpu/duration*100,
                'wakeupsPerSecond': (after['wakeups']-before['wakeups'])/duration, 'systemEstimatedJoules': energy,
                'systemEstimatedWatts': energy/duration, 'residentBytes': after['rss'],
                'eightHourContinuousWh': energy/duration*8, 'fixture': report, 'errors': errors}
            args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(result, indent=2)+'\n')
            print(json.dumps(result), flush=True)
        finally:
            stop.set(); start.set(); process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
            server.close(); thread.join(timeout=2)
        if errors: raise RuntimeError(errors)


if __name__ == '__main__': main()

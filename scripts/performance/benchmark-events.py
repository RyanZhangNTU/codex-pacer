#!/usr/bin/env python3
"""Compare actual Desktop IPC projection code from two source trees on identical events."""
import argparse
import base64
import hashlib
import json
import pathlib
import re
import statistics
import sys
import textwrap
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True, type=pathlib.Path)
parser.add_argument('--candidate', type=pathlib.Path, default=pathlib.Path('.'))
parser.add_argument('--output', required=True, type=pathlib.Path)
args = parser.parse_args()
sys.argv = ['benchmark-events', base64.b64encode(b'/private/tmp/pacer-replay-no-data').decode()]


def load(root):
    files = [root / 'native/Sources/PacerCore' / name for name in
             ('SessionLogProbe.swift', 'RequestLogProbe.swift', 'RealtimeProbe.swift', 'DesktopEventProbe.swift')]
    source = '\n'.join(textwrap.dedent(block) for p in files if p.exists()
                       for block in re.findall(r'#"""\n(.*?)\n    """#', p.read_text().split('    static let script =')[0], re.S))
    namespace = {}
    exec(compile(source, str(root / 'DesktopEventProbe'), 'exec'), namespace)
    return namespace, hashlib.sha256(source.encode()).hexdigest()


baseline, baseline_hash = load(args.baseline)
candidate, candidate_hash = load(args.candidate)
results = []
for turns, repetitions in [(8, 150), (64, 100), (256, 60)]:
    for workload in ('body', 'body-and-token-count'):
        state = {'threadRuntimeStatus': {'type': 'active', 'activeFlags': []},
                 'latestTokenUsageInfo': {'total': {'outputTokens': 100}},
                 'turnHistory': {'kind': 'canonical', 'history': {'entitiesByKey': {
                     f'turn{i}': {'turnId': f'turn{i}', 'status': 'inProgress' if i == turns - 1 else 'completed',
                                 'turnStartedAtMs': 1000000 + i, 'items': [
                                     {'id': f'item{i}-{j}', 'type': 'agentMessage', 'status': 'completed'}
                                     for j in range(32)]} for i in range(turns)}}}}
        projections = [ns['Projection']('019a0000-0000-7000-8000-000000000001') for ns in (baseline, candidate)]
        for p in projections:
            p.consume({'type': 'snapshot', 'revision': 0, 'conversationState': state}, 'owner')
        timings = [[], []]
        for revision in range(1, repetitions + 1):
            patches = [{'op': 'replace', 'path': ['turnHistory', 'history', 'entitiesByKey', f'turn{turns - 1}', 'items', 0, 'text'], 'value': 'synthetic body delta'}]
            if workload == 'body-and-token-count':
                patches.append({'op': 'replace', 'path': ['latestTokenUsageInfo', 'total', 'outputTokens'], 'value': 100 + revision})
            change = {'type': 'patches', 'baseRevision': revision - 1, 'revision': revision, 'patches': patches}
            emitted = {}
            # Alternate ordering to avoid giving one implementation every warm-cache run.
            for index in ([0, 1] if revision % 2 else [1, 0]):
                start = time.process_time_ns()
                events = projections[index].consume(change, 'owner')
                timings[index].append((time.process_time_ns() - start) / 1e6)
                emitted[index] = [{k: v for k, v in e.items() if k != 'at'} for e in events]
            assert emitted[0] == emitted[1], (turns, workload, revision, 'events diverged')
            assert projections[0].tree == projections[1].tree, (turns, workload, revision, 'state diverged')
        before, after = map(statistics.median, timings)
        results.append({'turns': turns, 'itemsPerTurn': 32, 'workload': workload, 'repetitions': repetitions,
                        'baselineMedianMs': before, 'candidateMedianMs': after,
                        'reductionPercent': (1 - after / before) * 100, 'equivalent': True})
result = {'scope': 'Synthetic valid event replay; component CPU time, not whole-app speedup',
          'pythonVersion': sys.version.split()[0], 'baselineSourceSHA256': baseline_hash,
          'candidateSourceSHA256': candidate_hash, 'results': results}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))

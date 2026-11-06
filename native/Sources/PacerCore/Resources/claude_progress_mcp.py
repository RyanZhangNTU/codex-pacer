"""Pacer's progress tool for Claude Code: a stdio MCP server with one tool.

Pacer's PreToolUse hook reads the estimate from the call's input; this process
only acknowledges it. When the progress-ring switch holds "tool N", each reply
names the estimate at which the next report is due, so the model reports after
a change of N points rather than with every batch. Claude starts one server per
session, so the last estimate kept here belongs to that session.
"""
import json, pathlib, sys

TOOL = {
    'name': 'report_progress',
    'description': "Report your best estimate of how much of the user's current request is done. Pacer shows it as a progress ring.",
    'inputSchema': {'type': 'object', 'properties': {'percent': {'type': 'integer', 'minimum': 0, 'maximum': 100}},
                    'required': ['percent'], 'additionalProperties': False},
    'annotations': {'readOnlyHint': True, 'openWorldHint': False},
}

def step_from_switch(argv):
    # --home <Claude home>; read once, when the session starts.
    if '--home' not in argv[:-1]: return 0
    try: words = (pathlib.Path(argv[argv.index('--home') + 1]).expanduser() / 'pacer' / 'progress-ring').read_bytes()[:16].split()
    except OSError: return 0
    return int(words[1]) if words[:1] == [b'tool'] and len(words) > 1 and words[1].isdigit() and 0 < int(words[1]) <= 50 else 0

STEP = step_from_switch(sys.argv)

def reply(ident, result=None, error=None):
    message = {'jsonrpc': '2.0', 'id': ident}
    message.update({'error': error} if error else {'result': result})
    sys.stdout.write(json.dumps(message, separators=(',', ':')) + '\n'); sys.stdout.flush()

def acknowledgement(percent):
    if not STEP or percent >= 100: return 'ok'
    if percent + STEP >= 100: return 'ok'
    return 'ok. Next report when your estimate reaches %d%%.' % (percent + STEP)

def answer(method, params):
    if method == 'initialize':
        return {'protocolVersion': params.get('protocolVersion') or '2025-06-18', 'capabilities': {'tools': {}},
                'serverInfo': {'name': 'pacer', 'version': '1'}}
    if method == 'ping': return {}
    if method == 'tools/list': return {'tools': [TOOL]}
    if method == 'tools/call':
        value = (params.get('arguments') or {}).get('percent')
        valid = params.get('name') == TOOL['name'] and type(value) is int and 0 <= value <= 100
        text = acknowledgement(value) if valid else 'percent must be a whole number from 0 to 100'
        return {'content': [{'type': 'text', 'text': text}], 'isError': not valid}
    return None

def main():
    for line in sys.stdin.buffer:
        if len(line) > 1024 * 1024: continue
        try: message = json.loads(line)
        except ValueError: continue
        if not isinstance(message, dict) or 'id' not in message: continue
        params = message.get('params') if isinstance(message.get('params'), dict) else {}
        result = answer(message.get('method'), params)
        if result is None: reply(message['id'], error={'code': -32601, 'message': 'method not found'})
        else: reply(message['id'], result)

if __name__ == '__main__':
    try: main()
    except (OSError, KeyboardInterrupt): pass

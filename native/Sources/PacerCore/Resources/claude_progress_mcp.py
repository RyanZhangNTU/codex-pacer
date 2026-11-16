"""Pacer's progress tool for Claude Code: a stdio MCP server with one tool.

Pacer's PreToolUse hook reads the estimate from the call's input; this process
only acknowledges it, in the same words as every other module's reporter.
"""
import json, sys

TOOL = {
    'name': 'report_progress',
    # PacerCore's ProgressPrompt.toolDescription, shared by every module.
    'description': "The user turned on Pacer's progress ring and asks you to report your best estimate of how much of their current request is done with this tool: first, before or with your first other tool call, even if the estimate is still low; again whenever you make progress; and before you stop to wait for background work or for the user. Send each report in the same batch as your other tool calls. Always give a whole number from 0 to 100, and lower it if the work turns out larger. Skip replies that need no tools.",
    'inputSchema': {'type': 'object', 'properties': {'percent': {'type': 'integer', 'minimum': 0, 'maximum': 100}},
                    'required': ['percent'], 'additionalProperties': False},
    'annotations': {'readOnlyHint': True, 'openWorldHint': False},
}
# PacerCore's ProgressPrompt.acknowledgement: a nudge for the next report.
ACCEPTED = "pacer-progress:accepted. Report again as soon as you make more progress."

def reply(ident, result=None, error=None):
    message = {'jsonrpc': '2.0', 'id': ident}
    message.update({'error': error} if error else {'result': result})
    sys.stdout.write(json.dumps(message, separators=(',', ':')) + '\n'); sys.stdout.flush()

def answer(method, params):
    if method == 'initialize':
        return {'protocolVersion': params.get('protocolVersion') or '2025-06-18', 'capabilities': {'tools': {}},
                'serverInfo': {'name': 'pacer', 'version': '1'}}
    if method == 'ping': return {}
    if method == 'tools/list': return {'tools': [TOOL]}
    if method == 'tools/call':
        value = (params.get('arguments') or {}).get('percent')
        valid = params.get('name') == TOOL['name'] and type(value) is int and 0 <= value <= 100
        text = ACCEPTED if valid else 'percent must be a whole number from 0 to 100'
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

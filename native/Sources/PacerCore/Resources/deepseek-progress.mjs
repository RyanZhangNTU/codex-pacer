import { lstatSync, readFileSync } from 'node:fs';

const flag = new URL('enabled', import.meta.url);
const instructions = "Report your best estimate of how much of the user's current request is done. Call this tool with your first useful tool batch, after meaningful progress, and before stopping to wait for background work. Use an integer from 0 to 100 and revise it downward when needed. Skip reports for short replies that need no tools.";
const tool = {
    name: 'report_progress',
    description: instructions,
    inputSchema: {
        type: 'object', properties: { percent: { type: 'integer', minimum: 0, maximum: 100 } },
        required: ['percent'], additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
};

function enabled() {
    try {
        const facts = lstatSync(flag);
        return facts.isFile() && facts.size === 3 && readFileSync(flag, 'utf8') === 'on\n';
    } catch {
        return false;
    }
}

function respond(line) {
    let request;
    try { request = JSON.parse(line); } catch { return; }
    if (request?.jsonrpc !== '2.0' || !['number', 'string'].includes(typeof request.id)) return;
    const reply = { jsonrpc: '2.0', id: request.id };
    const active = enabled();
    switch (request.method) {
        case 'initialize': {
            const version = request.params?.protocolVersion;
            const supported = ['2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25'];
            reply.result = {
                protocolVersion: supported.includes(version) ? version : '2025-06-18',
                capabilities: { tools: {} }, serverInfo: { name: 'pacer_progress', version: '2.0.0' },
                ...(active ? { instructions } : {}),
            };
            break;
        }
        case 'ping': reply.result = {}; break;
        case 'tools/list': reply.result = { tools: active ? [tool] : [] }; break;
        case 'tools/call': {
            const args = request.params?.arguments;
            const valid = active && request.params?.name === tool.name && args && Object.keys(args).length === 1 &&
                Number.isInteger(args.percent) && args.percent >= 0 && args.percent <= 100;
            const message = valid ? 'pacer-progress:accepted' : active ? 'Expected an integer from 0 to 100.' : 'Pacer task progress is disabled.';
            reply.result = { content: [{ type: 'text', text: message }], isError: !valid };
            break;
        }
        default: reply.error = { code: -32601, message: 'Method not found' };
    }
    process.stdout.write(JSON.stringify(reply) + '\n');
}

const limit = 1024 * 1024;
let pending = Buffer.alloc(0);
for await (const chunk of process.stdin) {
    pending = Buffer.concat([pending, chunk]);
    let end;
    while ((end = pending.indexOf(10)) >= 0) {
        if (end > limit) process.exit(1);
        respond(pending.subarray(0, end));
        pending = pending.subarray(end + 1);
    }
    if (pending.length > limit) process.exit(1);
}

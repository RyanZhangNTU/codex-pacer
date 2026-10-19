// Synthetic reproduction of the installed Codex router's startup ordering.
// No Codex data, installed sockets, accounts or processes are accessed.
const net = require('node:net');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');

const root = fs.mkdtempSync('/private/tmp/pacer-ipc-race-');
const endpoint = path.join(root, 'ipc.sock');
const legacy = path.join(root, 'legacy.sock');
const routers = [], clients = [], assignments = new Map();

function canConnect(address) {
  return new Promise(resolve => {
    const socket = net.connect(address, () => { socket.end(); resolve(true); });
    socket.on('error', () => resolve(false));
  });
}

async function getOrStartRouter() {
  // The race is between the async availability checks and unlink/bind.
  // Each manager has its own startup state; no process-wide promise guards it.
  if (await canConnect(endpoint)) return endpoint;
  if (await canConnect(legacy)) return legacy;
  try { fs.unlinkSync(endpoint); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const server = net.createServer(), peers = new Set(), index = routers.length;
  routers.push({ server, peers });
  server.on('connection', socket => {
    peers.add(socket);
    let buffer = '';
    socket.on('data', data => {
      buffer += data.toString();
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const value = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        if (value.startsWith('id:')) assignments.set(value.slice(3), index);
        else for (const peer of peers) if (peer !== socket) peer.write(value + '\n');
      }
    });
    socket.on('close', () => peers.delete(socket));
    socket.on('error', () => {});
  });
  server.on('error', () => {});
  server.listen(endpoint);
  return endpoint; // Does not await the listening callback, matching the race.
}

function connect(id, address) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(address, () => {
      socket.write('id:' + id + '\n');
      clients.push(socket);
      resolve(socket);
    });
    socket.on('error', reject);
  });
}
async function until(condition) {
  const deadline = Date.now() + 2000;
  while (!condition()) {
    assert(Date.now() < deadline, 'Timed out waiting for fixture state');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

async function run() {
  const startup = await Promise.all(Array.from({ length: 5 }, (_, index) => (async () => {
    return connect('startup-' + index, await getOrStartRouter());
  })()));
  await until(() => startup.every((_, i) => assignments.has('startup-' + i)));
  const owner = startup[0];
  let ownerSawFollow = false, snapshot = false, observerEcho = false;
  owner.on('data', data => {
    if (data.toString().includes('follow')) { ownerSawFollow = true; owner.write('snapshot\n'); }
  });
  const observer = await connect('observer', endpoint);
  observer.on('data', data => {
    snapshot ||= data.toString().includes('snapshot');
    observerEcho ||= data.toString().includes('barrier');
  });
  await until(() => assignments.has('observer'));
  const barrier = await connect('barrier', endpoint);
  await until(() => assignments.has('barrier'));
  barrier.on('data', data => { if (data.toString().includes('follow')) barrier.write('barrier\n'); });
  observer.write('follow\n');
  await until(() => observerEcho);
  assert.equal(routers.length, 5);
  assert.notEqual(assignments.get('startup-0'), assignments.get('observer'));
  assert.equal(ownerSawFollow, false);
  assert.equal(snapshot, false);
  console.log(JSON.stringify({ phase: 'split', routers: routers.length,
    ownerRouter: assignments.get('startup-0'), observerRouter: assignments.get('observer'), snapshot }));

  const recovered = await connect('reconnected-owner', endpoint);
  recovered.on('data', data => { if (data.toString().includes('follow')) recovered.write('snapshot\n'); });
  await until(() => assignments.has('reconnected-owner'));
  observer.write('follow\n');
  await until(() => snapshot);
  console.log(JSON.stringify({ phase: 'owner-reconnected',
    ownerRouter: assignments.get('reconnected-owner'), observerRouter: assignments.get('observer'), snapshot }));
}

run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  for (const client of clients) client.destroy();
  for (const { server, peers } of routers) { for (const peer of peers) peer.destroy(); server.close(); }
  fs.rmSync(root, { recursive: true, force: true });
});

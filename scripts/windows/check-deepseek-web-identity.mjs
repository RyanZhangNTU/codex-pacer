import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const summary = new AsyncFunction('localStorage', 'fetch', 'crypto', 'TextEncoder',
  readFileSync(new URL('../../native/Sources/PacerCore/Resources/deepseek-summary.js', import.meta.url), 'utf8'));
const fingerprint = new AsyncFunction('localStorage', 'crypto', 'TextEncoder',
  readFileSync(new URL('../../native/Sources/PacerCore/Resources/deepseek-session-fingerprint.js', import.meta.url), 'utf8'));
const first = 'SYNTHETIC_DEEPSEEK_SESSION_A_中文';
const second = 'SYNTHETIC_DEEPSEEK_SESSION_B';
const response = () => ({ status: 200, headers: { get: () => null }, json: async () => ({
  data: { biz_data: { normal_wallets: [{ currency: 'CNY', balance: '90' }], bonus_wallets: [{ currency: 'CNY', balance: '1' }],
    total_available_token_estimation: 5000 } }
}) });
let checks = 0;
for (const encode of [value => value, JSON.stringify, value => JSON.stringify({ value })]) {
  let stored = encode(first);
  const storage = { getItem: key => key === 'userToken' ? stored : null };
  const original = await fingerprint(storage, webcrypto, TextEncoder);
  const result = await summary(storage, async () => response(), webcrypto, TextEncoder);
  assert.equal(result.state, 'ok');
  assert.equal(result.sessionFingerprint, original);
  assert.deepEqual(result.normal, ['90']);
  assert.deepEqual(result.bonus, ['1']);
  assert.equal(result.estimation, '5000');
  assert.equal(JSON.stringify(result).includes(first), false);
  checks++;
  const duringFetch = await summary(storage, async () => { stored = encode(second); return response(); }, webcrypto, TextEncoder);
  assert.deepEqual(duringFetch, { state: 'invalid' });
  checks++;
  stored = encode(first);
  const changingDigest = { subtle: { digest: async (...arguments_) => {
    const digest = await webcrypto.subtle.digest(...arguments_);
    stored = encode(second);
    return digest;
  } } };
  const duringDigest = await summary(storage, async () => response(), changingDigest, TextEncoder);
  assert.deepEqual(duringDigest, { state: 'invalid' });
  checks++;
}
const storage = { getItem: key => key === 'userToken' ? first : null };
assert.deepEqual(await summary({ getItem: () => null }, () => { throw new Error('must not fetch'); }, webcrypto, TextEncoder), { state: 'signedOut' }); checks++;
assert.deepEqual(await summary(storage, async () => { throw new Error('synthetic offline'); }, webcrypto, TextEncoder), { state: 'offline' }); checks++;
const challenge = response(); challenge.headers.get = () => 'challenge';
assert.deepEqual(await summary(storage, async () => challenge, webcrypto, TextEncoder), { state: 'challenge' }); checks++;
console.log(`PASS ${checks} isolated summary/session identity and token-race checks; wallet numbers preserved, no token output`);

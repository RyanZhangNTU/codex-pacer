import assert from 'node:assert/strict'

import {
  shouldKeepConversationDetail,
  waitForOverlappingScan,
} from '../src/app/dataFreshness.ts'

const summary = {
  rootSessionId: 'root-session',
  updatedAt: '2026-07-10T08:00:00Z',
  apiValueUsd: 12.5,
  subscriptionShare: 0.125,
}

const cachedDetail = {
  rootSessionId: 'root-session',
  updatedAt: summary.updatedAt,
  apiValueUsd: summary.apiValueUsd,
  subscriptionShare: summary.apiValueUsd / 100,
}

assert.equal(
  shouldKeepConversationDetail(
    { ...cachedDetail, updatedAt: '2026-07-10T07:59:59Z' },
    summary,
    100,
  ),
  false,
  'detail cache should reject an older conversation timestamp',
)

assert.equal(
  shouldKeepConversationDetail(
    { ...cachedDetail, apiValueUsd: summary.apiValueUsd - 0.5 },
    summary,
    100,
  ),
  false,
  'detail cache should reject a stale API value',
)

assert.equal(
  shouldKeepConversationDetail(cachedDetail, summary, 200),
  false,
  'detail cache should reject subscription share derived from an older monthly price',
)

assert.equal(
  shouldKeepConversationDetail(
    {
      ...cachedDetail,
      apiValueUsd: summary.apiValueUsd + 1e-10,
      subscriptionShare: summary.apiValueUsd / 100 + 1e-10,
    },
    summary,
    100,
  ),
  true,
  'detail cache should retain matching derived values within floating-point tolerance',
)

let scanChecks = 0
let settleWaits = 0
await waitForOverlappingScan(
  async () => {
    scanChecks += 1
    return true
  },
  async () => {
    settleWaits += 1
  },
)

assert.equal(scanChecks, 1, 'overlapping refresh should check scan state once')
assert.equal(settleWaits, 1, 'overlapping refresh should wait once for an active scan')

settleWaits = 0
await waitForOverlappingScan(
  async () => false,
  async () => {
    settleWaits += 1
  },
)

assert.equal(settleWaits, 0, 'refresh should not wait when no scan is active')

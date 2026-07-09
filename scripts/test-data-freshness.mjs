import assert from 'node:assert/strict'

import {
  refreshDashboardAfterBackgroundScan,
  runScanWithOverlapRetry,
  shouldKeepConversationDetail,
  waitForOverlappingScan,
  waitForScanToSettleUntilCancelled,
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
const settledAfterOverlap = await waitForOverlappingScan(
  async () => {
    scanChecks += 1
    return true
  },
  async () => {
    settleWaits += 1
    return true
  },
)

assert.equal(scanChecks, 1, 'overlapping refresh should check scan state once')
assert.equal(settleWaits, 1, 'overlapping refresh should wait once for an active scan')
assert.equal(settledAfterOverlap, true, 'overlapping refresh should report a settled scan')

const timedOutAfterOverlap = await waitForOverlappingScan(
  async () => true,
  async () => false,
)

assert.equal(timedOutAfterOverlap, false, 'overlapping refresh should report a settle timeout')

settleWaits = 0
const settledWithoutOverlap = await waitForOverlappingScan(
  async () => false,
  async () => {
    settleWaits += 1
    return true
  },
)

assert.equal(settleWaits, 0, 'refresh should not wait when no scan is active')
assert.equal(settledWithoutOverlap, true, 'refresh should be ready when no scan is active')

let scanAttempts = 0
let overlapNotices = 0
const retriedScan = await runScanWithOverlapRetry(
  async () => {
    scanAttempts += 1
    if (scanAttempts === 1) {
      throw new Error('A scan is already running.')
    }
    return { codexHome: '/tmp/new-home' }
  },
  (error) => String(error).includes('already running'),
  async () => true,
  () => {
    overlapNotices += 1
  },
)

assert.deepEqual(retriedScan, { codexHome: '/tmp/new-home' })
assert.equal(scanAttempts, 2, 'source switch should retry a full scan after the old scan settles')
assert.equal(overlapNotices, 1, 'source switch should report one overlapping scan')

scanAttempts = 0
await assert.rejects(
  runScanWithOverlapRetry(
    async () => {
      scanAttempts += 1
      throw new Error('A scan is already running.')
    },
    (error) => String(error).includes('already running'),
    async () => false,
  ),
  /did not finish before the timeout/,
  'source switch should fail instead of reading the dashboard after a settle timeout',
)
assert.equal(scanAttempts, 1, 'source switch should not retry while the old scan is still active')

let dashboardLoads = 0
await refreshDashboardAfterBackgroundScan(
  async () => {
    throw new Error('background refresh failed')
  },
  async () => false,
  async () => true,
  async () => {
    dashboardLoads += 1
  },
)
assert.equal(dashboardLoads, 1, 'background refresh errors should still allow a current dashboard load')

dashboardLoads = 0
await refreshDashboardAfterBackgroundScan(
  async () => null,
  async () => true,
  async () => false,
  async () => {
    dashboardLoads += 1
  },
)
assert.equal(dashboardLoads, 0, 'a settle timeout should skip the current background dashboard load')

let cancelled = false
let releaseWait
let markWaitStarted
const waitStarted = new Promise((resolve) => {
  markWaitStarted = resolve
})
const pendingRefresh = refreshDashboardAfterBackgroundScan(
  async () => null,
  async () => true,
  async () => {
    markWaitStarted()
    return new Promise((resolve) => {
      releaseWait = resolve
    })
  },
  async () => {
    dashboardLoads += 1
  },
  () => cancelled,
)

await waitStarted
cancelled = true
releaseWait(true)
await pendingRefresh
assert.equal(dashboardLoads, 0, 'effect cleanup should cancel a refresh that was waiting on a scan')

await refreshDashboardAfterBackgroundScan(
  async () => null,
  async () => {
    throw new Error('scan state unavailable')
  },
  async () => true,
  async () => {
    dashboardLoads += 1
  },
)
assert.equal(dashboardLoads, 0, 'scan-state errors should not load or reject the interval task')

await refreshDashboardAfterBackgroundScan(
  async () => null,
  async () => true,
  async () => {
    throw new Error('settle state unavailable')
  },
  async () => {
    dashboardLoads += 1
  },
)
assert.equal(dashboardLoads, 0, 'settle errors should not load or reject the interval task')

let bootstrapWaits = 0
const bootstrapSettled = await waitForScanToSettleUntilCancelled(
  async () => {
    bootstrapWaits += 1
    return bootstrapWaits > 1
  },
  () => false,
)
assert.equal(bootstrapSettled, true, 'bootstrap should keep waiting after one settle timeout')
assert.equal(bootstrapWaits, 2, 'bootstrap should retry its settle wait after a timeout')

let bootstrapCancelled = false
const cancelledBootstrapSettled = await waitForScanToSettleUntilCancelled(
  async () => {
    bootstrapCancelled = true
    return false
  },
  () => bootstrapCancelled,
)
assert.equal(cancelledBootstrapSettled, false, 'bootstrap should stop retrying after cleanup')

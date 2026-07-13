import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  loadConversationDetailForGeneration,
  runScanWithOverlapRetry,
  shouldKeepConversationDetail,
} from '../src/app/dataFreshness.ts'

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const appSource = readFileSync(join(repoRoot, 'src/App.tsx'), 'utf8')

const summary = {
  rootSessionId: 'root-session',
  title: 'Current title',
  startedAt: '2026-07-10T07:00:00Z',
  updatedAt: '2026-07-10T08:00:00Z',
  modelIds: ['gpt-5.6-sol', 'gpt-5.6-terra'],
  inputTokens: 100,
  cachedInputTokens: 20,
  outputTokens: 25,
  reasoningOutputTokens: 5,
  totalTokens: 125,
  sessionCount: 2,
  subagentCount: 1,
  hasFastMode: true,
  apiValueUsd: 12.5,
  subscriptionShare: 0.125,
  sourceStates: ['active', 'archived'],
}

const cachedDetail = {
  rootSessionId: 'root-session',
  title: summary.title,
  startedAt: summary.startedAt,
  updatedAt: summary.updatedAt,
  inputTokens: summary.inputTokens,
  cachedInputTokens: summary.cachedInputTokens,
  outputTokens: summary.outputTokens,
  reasoningOutputTokens: summary.reasoningOutputTokens,
  totalTokens: summary.totalTokens,
  apiValueUsd: summary.apiValueUsd,
  subscriptionShare: summary.apiValueUsd / 100,
  multipleAgent: true,
  sourceStates: ['archived', 'active'],
  sessions: [
    { isSubagent: false, fastModeEffective: false },
    { isSubagent: true, fastModeEffective: true },
  ],
  modelBreakdown: [
    { modelId: 'gpt-5.6-terra' },
    { modelId: 'gpt-5.6-sol' },
  ],
}

assert.equal(
  shouldKeepConversationDetail(cachedDetail, summary, 100),
  true,
  'detail cache should retain a detail whose user-visible summary fields still match',
)

let detailGeneration = 1
let releaseStaleDetail
const staleDetailRequest = loadConversationDetailForGeneration(
  () =>
    new Promise((resolve) => {
      releaseStaleDetail = resolve
    }),
  detailGeneration,
  () => detailGeneration,
)
detailGeneration += 1
releaseStaleDetail({ title: 'Stale title' })
assert.equal(
  await staleDetailRequest,
  null,
  'a detail response from before dashboard cache reconciliation should be discarded',
)
assert.match(
  appSource,
  /latestDetailRequestIdRef\.current \+= 1[\s\S]*detailCacheRef\.current = nextDetailCache/,
  'dashboard reconciliation should invalidate in-flight detail requests before replacing the cache',
)
assert.match(
  appSource,
  /setDetail\(\(current\)[\s\S]*nextDetailCache\.get\(current\.rootSessionId\)[\s\S]*\? current : null/,
  'dashboard reconciliation should stop showing a detail that was evicted from the cache',
)

for (const [label, changedSummary] of [
  ['root session', { ...summary, rootSessionId: 'different-root' }],
  ['title', { ...summary, title: 'Updated title' }],
  ['start timestamp', { ...summary, startedAt: '2026-07-10T07:00:01Z' }],
  ['model list', { ...summary, modelIds: ['gpt-5.6-sol'] }],
  ['input tokens', { ...summary, inputTokens: summary.inputTokens + 1 }],
  ['cached input tokens', { ...summary, cachedInputTokens: summary.cachedInputTokens + 1 }],
  ['output tokens', { ...summary, outputTokens: summary.outputTokens + 1 }],
  ['reasoning tokens', { ...summary, reasoningOutputTokens: summary.reasoningOutputTokens + 1 }],
  ['total tokens', { ...summary, totalTokens: summary.totalTokens + 1 }],
  ['session count', { ...summary, sessionCount: summary.sessionCount + 1 }],
  ['subagent count', { ...summary, subagentCount: 0 }],
  ['fast-mode state', { ...summary, hasFastMode: false }],
  ['subscription share', { ...summary, subscriptionShare: summary.subscriptionShare + 0.01 }],
  ['source state', { ...summary, sourceStates: ['archived'] }],
]) {
  assert.equal(
    shouldKeepConversationDetail(cachedDetail, changedSummary, 100),
    false,
    `detail cache should reject a stale ${label}`,
  )
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

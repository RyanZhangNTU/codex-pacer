import type { ConversationDetail, ConversationListItem } from './types.ts'

const FLOAT_EPSILON = 1e-9

function nearlyEqual(left: number, right: number): boolean {
  return Math.abs(left - right) <= FLOAT_EPSILON
}

function sameStringSet(left: readonly string[], right: readonly string[]): boolean {
  if (left.length !== right.length) return false
  const sortedLeft = [...left].sort()
  const sortedRight = [...right].sort()
  return sortedLeft.every((value, index) => value === sortedRight[index])
}

export function shouldKeepConversationDetail(
  cached: ConversationDetail,
  summary: ConversationListItem,
  monthlyPrice: number,
): boolean {
  const expectedSubscriptionShare = monthlyPrice > 0 ? summary.apiValueUsd / monthlyPrice : 0
  const cachedModelIds = cached.modelBreakdown.map((item) => item.modelId)
  const cachedSubagentCount = cached.sessions.filter((session) => session.isSubagent).length
  const cachedHasFastMode = cached.sessions.some((session) => session.fastModeEffective)

  return (
    cached.rootSessionId === summary.rootSessionId &&
    cached.title === summary.title &&
    cached.startedAt === summary.startedAt &&
    cached.updatedAt === summary.updatedAt &&
    sameStringSet(cachedModelIds, summary.modelIds) &&
    cached.inputTokens === summary.inputTokens &&
    cached.cachedInputTokens === summary.cachedInputTokens &&
    cached.outputTokens === summary.outputTokens &&
    cached.reasoningOutputTokens === summary.reasoningOutputTokens &&
    cached.totalTokens === summary.totalTokens &&
    cached.sessions.length === summary.sessionCount &&
    cachedSubagentCount === summary.subagentCount &&
    cached.multipleAgent === (summary.sessionCount > 1) &&
    cachedHasFastMode === summary.hasFastMode &&
    nearlyEqual(cached.apiValueUsd, summary.apiValueUsd) &&
    nearlyEqual(summary.subscriptionShare, expectedSubscriptionShare) &&
    nearlyEqual(cached.subscriptionShare, expectedSubscriptionShare) &&
    sameStringSet(cached.sourceStates, summary.sourceStates)
  )
}

export async function loadConversationDetailForGeneration<T>(
  loadDetail: () => Promise<T>,
  requestGeneration: number,
  getCurrentGeneration: () => number,
): Promise<T | null> {
  const detail = await loadDetail()
  return requestGeneration === getCurrentGeneration() ? detail : null
}

export async function waitForOverlappingScan(
  getScanInProgress: () => Promise<boolean>,
  waitForScanToSettle: () => Promise<boolean>,
): Promise<boolean> {
  if (await getScanInProgress()) {
    return waitForScanToSettle()
  }
  return true
}

export async function runScanWithOverlapRetry<T>(
  runScan: () => Promise<T>,
  isOverlappingScanError: (error: unknown) => boolean,
  waitForScanToSettle: () => Promise<boolean>,
  onOverlap: () => void = () => {},
): Promise<T> {
  try {
    return await runScan()
  } catch (error) {
    if (!isOverlappingScanError(error)) {
      throw error
    }
    onOverlap()
    if (!(await waitForScanToSettle())) {
      throw new Error('The active scan did not finish before the timeout.')
    }
    return runScan()
  }
}

export async function refreshDashboardAfterBackgroundScan(
  refreshBackgroundData: () => Promise<unknown>,
  getScanInProgress: () => Promise<boolean>,
  waitForScanToSettle: () => Promise<boolean>,
  loadDashboard: () => Promise<void>,
  isCancelled: () => boolean = () => false,
): Promise<void> {
  if (isCancelled()) {
    return
  }
  try {
    await refreshBackgroundData()
  } catch {
    // Keep loading persisted data when the background refresh itself fails.
  }
  if (isCancelled()) {
    return
  }

  let settled: boolean
  try {
    settled = await waitForOverlappingScan(getScanInProgress, waitForScanToSettle)
  } catch {
    return
  }
  if (!settled || isCancelled()) {
    return
  }
  await loadDashboard()
}

export async function waitForScanToSettleUntilCancelled(
  waitForScanToSettle: () => Promise<boolean>,
  isCancelled: () => boolean,
): Promise<boolean> {
  while (!isCancelled()) {
    if (await waitForScanToSettle()) {
      return true
    }
  }
  return false
}

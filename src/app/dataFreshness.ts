import type { ConversationDetail, ConversationListItem } from './types.ts'

const FLOAT_EPSILON = 1e-9

function nearlyEqual(left: number, right: number): boolean {
  return Math.abs(left - right) <= FLOAT_EPSILON
}

export function shouldKeepConversationDetail(
  cached: ConversationDetail,
  summary: ConversationListItem,
  monthlyPrice: number,
): boolean {
  const expectedSubscriptionShare = monthlyPrice > 0 ? summary.apiValueUsd / monthlyPrice : 0

  return (
    cached.updatedAt === summary.updatedAt &&
    nearlyEqual(cached.apiValueUsd, summary.apiValueUsd) &&
    nearlyEqual(cached.subscriptionShare, expectedSubscriptionShare)
  )
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

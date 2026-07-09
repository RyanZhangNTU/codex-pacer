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
  waitForScanToSettle: () => Promise<void>,
): Promise<void> {
  if (await getScanInProgress()) {
    await waitForScanToSettle()
  }
}

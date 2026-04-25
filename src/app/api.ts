import { invoke, isTauri } from '@tauri-apps/api/core'

import type {
  ConversationFilters,
  ConversationListItem,
  LiveRateLimitSnapshot,
  MenuBarPopupSnapshot,
  OverviewBucket,
  OverviewResponse,
  SubscriptionProfile,
  SyncSettings,
} from './types'

function bucketUsesAnchor(bucket: OverviewBucket) {
  return !['five_hour', 'seven_day', 'total'].includes(bucket)
}

function nowIso() {
  return new Date().toISOString()
}

function createMockSyncSettings(): SyncSettings {
  return {
    codexHome: null,
    autoScanEnabled: false,
    autoScanIntervalMinutes: 5,
    liveQuotaRefreshIntervalSeconds: 60,
    defaultFastModeForNewGpt54Sessions: true,
    hideDockIconWhenMenuBarVisible: false,
    showMenuBarLogo: true,
    showMenuBarDailyApiValue: true,
    showMenuBarLiveQuotaPercent: false,
    menuBarLiveQuotaMetric: 'remaining_percent',
    menuBarLiveQuotaBucket: 'five_hour',
    menuBarBucket: 'day',
    menuBarSpeedShowEmoji: true,
    menuBarSpeedFastThresholdPercent: 85,
    menuBarSpeedSlowThresholdPercent: 115,
    menuBarSpeedHealthyEmoji: '🟢',
    menuBarSpeedFastEmoji: '🔥',
    menuBarSpeedSlowEmoji: '🐢',
    menuBarPopupEnabled: true,
    menuBarPopupModules: ['api_value', 'scan_freshness'],
    menuBarPopupShowResetTimeline: true,
    menuBarPopupShowActions: true,
    lastScanStartedAt: null,
    lastScanCompletedAt: null,
    updatedAt: nowIso(),
  }
}

function createMockSubscriptionProfile(): SubscriptionProfile {
  return {
    planType: 'plus',
    currency: 'USD',
    monthlyPrice: 20,
    billingAnchorDay: 1,
    updatedAt: nowIso(),
  }
}

function createMockLiveRateLimits(): LiveRateLimitSnapshot {
  return {
    limitId: null,
    limitName: null,
    planType: null,
    primary: null,
    secondary: null,
    fetchedAt: nowIso(),
  }
}

function createMockOverview(bucket: OverviewBucket, anchor?: string | null): OverviewResponse {
  const timestamp = nowIso()
  return {
    bucket,
    anchor: bucketUsesAnchor(bucket) ? anchor ?? timestamp.slice(0, 10) : timestamp.slice(0, 10),
    windowStart: timestamp,
    windowEnd: timestamp,
    liveWindowOffset: 0,
    liveWindowCount: 0,
    stats: {
      apiValueUsd: 0,
      subscriptionCostUsd: 0,
      payoffRatio: 0,
      totalTokens: 0,
      conversationCount: 0,
    },
    trend: [],
    quotaTrend: [],
    modelShares: [],
    compositionShares: [],
    liveRateLimits: createMockLiveRateLimits(),
  }
}

function createMockMenuBarPopupSnapshot(): MenuBarPopupSnapshot {
  const fetchedAt = nowIso()
  return {
    fetchedAt,
    refreshIntervalSeconds: 60,
    selectedBucket: 'day',
    quota5h: {
      usedPercent: 58,
      remainingPercent: 42,
      windowDurationMins: 300,
      resetsAt: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
      windowStart: new Date(Date.now() - 3 * 60 * 60 * 1000).toISOString(),
    },
    quota7d: {
      usedPercent: 32,
      remainingPercent: 68,
      windowDurationMins: 7 * 24 * 60,
      resetsAt: new Date(Date.now() + 4 * 24 * 60 * 60 * 1000).toISOString(),
      windowStart: new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString(),
    },
    suggestedSpeed7d: {
      percent: 82,
      displayValue: '82%',
      emoji: '🔥',
      status: 'fast',
      remainingTimePercent: 83,
      remainingPercent: 68,
    },
    speedFastThresholdPercent: 85,
    speedSlowThresholdPercent: 115,
    apiValueSelectedBucket: 14.3,
    totalTokensSelectedBucket: 182_400,
    conversationCountSelectedBucket: 9,
    payoffRatio: 0.71,
    lastScanCompletedAt: fetchedAt,
    liveQuotaFetchedAt: fetchedAt,
    visibleModules: ['api_value', 'scan_freshness'],
    showResetTimeline: true,
    showActions: true,
  }
}

async function invokeOrMock<T>(
  command: string,
  args: Record<string, unknown>,
  mockFactory: () => T | Promise<T>,
): Promise<T> {
  if (isTauri()) {
    return invoke<T>(command, args)
  }
  return mockFactory()
}

export async function scanCodexUsage(codexHome?: string | null): Promise<import('./types').ScanResult> {
  return invokeOrMock('scanCodexUsage', { codexHome: codexHome ?? null }, () => ({
    codexHome: codexHome ?? '~/.codex',
    scannedFiles: 0,
    importedSessions: 0,
    updatedSessions: 0,
    missingSessions: 0,
    lastCompletedAt: nowIso(),
  }))
}

export async function getScanInProgress() {
  return invokeOrMock('getScanInProgress', {}, () => false)
}

export async function refreshPricing() {
  return invokeOrMock('refreshPricing', {}, () => [])
}

export async function getOverview(bucket: OverviewBucket, anchor?: string | null): Promise<OverviewResponse> {
  return invokeOrMock(
    'getOverview',
    {
      bucket,
      anchor: bucketUsesAnchor(bucket) ? anchor ?? null : null,
      liveWindowOffset: null,
    },
    () => createMockOverview(bucket, anchor),
  )
}

export async function loadDashboard(
  bucket: OverviewBucket,
  anchor?: string | null,
  search?: string | null,
  liveWindowOffset?: number | null,
): Promise<import('./types').DashboardSnapshot> {
  return invokeOrMock(
    'loadDashboard',
    {
      bucket,
      anchor: bucketUsesAnchor(bucket) ? anchor ?? null : null,
      search: search ?? null,
      liveWindowOffset: liveWindowOffset ?? null,
    },
    () => ({
      overview: createMockOverview(bucket, anchor),
      conversations: [] as ConversationListItem[],
      syncSettings: createMockSyncSettings(),
      subscriptionProfile: createMockSubscriptionProfile(),
      liveRateLimits: createMockLiveRateLimits(),
    }),
  )
}

export async function listConversations(filters: ConversationFilters) {
  return invokeOrMock('listConversations', { filters }, () => [] satisfies ConversationListItem[])
}

export async function getLiveRateLimits(): Promise<LiveRateLimitSnapshot> {
  return invokeOrMock('getLiveRateLimits', {}, createMockLiveRateLimits)
}

export async function getConversationDetail(
  rootSessionId: string,
): Promise<import('./types').ConversationDetail> {
  return invokeOrMock('getConversationDetail', { rootSessionId }, () => {
    throw new Error(`Conversation ${rootSessionId} is unavailable in browser preview mode.`)
  })
}

export async function getMenuBarPopupSnapshot(forceRefresh = false): Promise<MenuBarPopupSnapshot> {
  return invokeOrMock('getMenuBarPopupSnapshot', { forceRefresh }, createMockMenuBarPopupSnapshot)
}

export type MenuBarPopupAction = 'open_dashboard' | 'open_settings' | 'hide' | 'refresh'

export async function handleMenuBarPopupAction(action: MenuBarPopupAction) {
  return invokeOrMock('handleMenuBarPopupAction', { action }, () => true)
}

export async function setFastModeOverride(sessionId: string, overrideValue: boolean | null) {
  return invokeOrMock('setFastModeOverride', { sessionId, overrideValue }, () => true)
}

export async function getSyncSettings() {
  return invokeOrMock('getSyncSettings', {}, createMockSyncSettings)
}

export async function updateSyncSettings(payload: SyncSettings) {
  return invokeOrMock('updateSyncSettings', { payload }, () => payload)
}

export async function getSubscriptionProfile() {
  return invokeOrMock('getSubscriptionProfile', {}, createMockSubscriptionProfile)
}

export async function updateSubscriptionProfile(payload: SubscriptionProfile) {
  return invokeOrMock('updateSubscriptionProfile', { payload }, () => ({
    ...payload,
    currency: 'USD',
  }))
}

export type OverviewBucket =
  | 'five_hour'
  | 'day'
  | 'seven_day'
  | 'week'
  | 'subscription_month'
  | 'month'
  | 'year'
  | 'total'

export type ShareMode = 'value' | 'tokens'
export type ShareDimension = 'model' | 'composition'
export type AppView = 'overview' | 'conversations'
export type MenuBarPopupModuleId =
  | 'api_value'
  | 'token_count'
  | 'scan_freshness'
  | 'live_quota_freshness'
  | 'payoff_ratio'
  | 'conversation_count'

export interface SyncSettings {
  codexHome: string | null
  autoScanEnabled: boolean
  autoScanIntervalMinutes: number
  liveQuotaRefreshIntervalSeconds: number
  defaultFastModeForNewGpt54Sessions: boolean
  hideDockIconWhenMenuBarVisible: boolean
  showMenuBarLogo: boolean
  showMenuBarDailyApiValue: boolean
  showMenuBarLiveQuotaPercent: boolean
  menuBarLiveQuotaMetric: 'remaining_percent' | 'suggested_usage_speed'
  menuBarLiveQuotaBucket: 'five_hour' | 'seven_day'
  menuBarBucket: OverviewBucket
  menuBarSpeedShowEmoji: boolean
  menuBarSpeedFastThresholdPercent: number
  menuBarSpeedSlowThresholdPercent: number
  menuBarSpeedHealthyEmoji: string
  menuBarSpeedFastEmoji: string
  menuBarSpeedSlowEmoji: string
  menuBarPopupEnabled: boolean
  menuBarPopupModules: MenuBarPopupModuleId[]
  menuBarPopupShowResetTimeline: boolean
  menuBarPopupShowActions: boolean
  lastScanStartedAt: string | null
  lastScanCompletedAt: string | null
  updatedAt: string
}

export interface SubscriptionProfile {
  planType: string
  currency: string
  monthlyPrice: number
  billingAnchorDay: number
  updatedAt: string
}

export interface ScanResult {
  codexHome: string
  scannedFiles: number
  importedSessions: number
  updatedSessions: number
  missingSessions: number
  lastCompletedAt: string
}

export interface OverviewStats {
  apiValueUsd: number
  subscriptionCostUsd: number
  payoffRatio: number
  totalTokens: number
  conversationCount: number
}

export interface TrendPoint {
  label: string
  timestamp: string
  apiValueUsd: number
  totalTokens: number
}

export interface RateLimitWindowSnapshot {
  usedPercent: number
  remainingPercent: number
  windowDurationMins: number | null
  resetsAt: string | null
  windowStart: string | null
}

export interface LiveRateLimitSnapshot {
  limitId: string | null
  limitName: string | null
  planType: string | null
  primary: RateLimitWindowSnapshot | null
  secondary: RateLimitWindowSnapshot | null
  fetchedAt: string
}

export interface MenuBarPopupQuotaSnapshot {
  usedPercent: number
  remainingPercent: number
  windowDurationMins: number | null
  resetsAt: string | null
  windowStart: string | null
}

export interface MenuBarPopupSuggestedSpeed {
  percent: number
  displayValue: string
  emoji: string
  status: 'fast' | 'healthy' | 'slow'
  remainingTimePercent: number
  remainingPercent: number
}

export interface MenuBarPopupSnapshot {
  fetchedAt: string
  refreshIntervalSeconds: number
  selectedBucket: OverviewBucket
  quota5h: MenuBarPopupQuotaSnapshot | null
  quota7d: MenuBarPopupQuotaSnapshot | null
  quotaTrend7d: QuotaTrendPoint[]
  suggestedSpeed7d: MenuBarPopupSuggestedSpeed | null
  speedFastThresholdPercent: number
  speedSlowThresholdPercent: number
  apiValueSelectedBucket: number
  totalTokensSelectedBucket: number
  conversationCountSelectedBucket: number
  payoffRatio: number
  lastScanCompletedAt: string | null
  liveQuotaFetchedAt: string | null
  visibleModules: MenuBarPopupModuleId[]
  showResetTimeline: boolean
  showActions: boolean
}

export interface QuotaTrendPoint {
  label: string
  timestamp: string
  apiValueUsd: number
  cumulativeApiValueUsd: number
  totalTokens: number
  cumulativeTokens: number
  remainingPercent: number | null
  usedPercent: number | null
}

export interface ModelShare {
  modelId: string
  displayName: string
  apiValueUsd: number
  totalTokens: number
  conversationCount: number
  color: string
}

export interface CompositionShare {
  category: string
  label: string
  apiValueUsd: number
  totalTokens: number
  color: string
}

export interface ShareSlice {
  id: string
  label: string
  secondaryLabel?: string | null
  apiValueUsd: number
  totalTokens: number
  color: string
}

export interface OverviewResponse {
  bucket: OverviewBucket
  anchor: string
  windowStart: string
  windowEnd: string
  liveWindowOffset: number
  liveWindowCount: number
  stats: OverviewStats
  trend: TrendPoint[]
  quotaTrend: QuotaTrendPoint[]
  modelShares: ModelShare[]
  compositionShares: CompositionShare[]
  liveRateLimits: LiveRateLimitSnapshot | null
}

export interface DashboardSnapshot {
  overview: OverviewResponse
  conversations: ConversationListItem[]
  syncSettings: SyncSettings
  subscriptionProfile: SubscriptionProfile
  liveRateLimits: LiveRateLimitSnapshot | null
}

export interface ConversationFilters {
  bucket?: OverviewBucket | null
  anchor?: string | null
  search?: string | null
  liveWindowOffset?: number | null
}

export interface ConversationListItem {
  rootSessionId: string
  title: string
  startedAt: string | null
  updatedAt: string | null
  modelIds: string[]
  inputTokens: number
  cachedInputTokens: number
  outputTokens: number
  reasoningOutputTokens: number
  totalTokens: number
  sessionCount: number
  subagentCount: number
  hasFastMode: boolean
  apiValueUsd: number
  subscriptionShare: number
  sourceStates: string[]
}

export interface ConversationSessionSummary {
  sessionId: string
  parentSessionId: string | null
  agentNickname: string | null
  agentRole: string | null
  modelIds: string[]
  startedAt: string | null
  updatedAt: string | null
  inputTokens: number
  cachedInputTokens: number
  outputTokens: number
  reasoningOutputTokens: number
  totalTokens: number
  apiValueUsd: number
  fastModeAuto: boolean
  fastModeEffective: boolean
  fastModeOverride: boolean | null
  sourceState: string
  sourcePath: string | null
  isSubagent: boolean
}

export interface ConversationTurnPoint {
  sessionId: string
  turnId: string
  startedAt: string | null
  completedAt: string | null
  lastActivityAt: string
  status: string
  userMessage: string | null
  assistantMessage: string | null
  modelIds: string[]
  inputTokens: number
  cachedInputTokens: number
  outputTokens: number
  reasoningOutputTokens: number
  totalTokens: number
  valueUsd: number
  fastModeEffective: boolean
}

export interface ConversationDetail {
  rootSessionId: string
  title: string
  startedAt: string | null
  updatedAt: string | null
  inputTokens: number
  cachedInputTokens: number
  outputTokens: number
  reasoningOutputTokens: number
  totalTokens: number
  apiValueUsd: number
  subscriptionShare: number
  multipleAgent: boolean
  sourceStates: string[]
  sessions: ConversationSessionSummary[]
  turns: ConversationTurnPoint[]
  modelBreakdown: ModelShare[]
  compositionBreakdown: CompositionShare[]
}

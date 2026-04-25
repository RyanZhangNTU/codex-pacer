import { startTransition, useCallback, useDeferredValue, useEffect, useRef, useState } from 'react'
import { isTauri } from '@tauri-apps/api/core'
import { emitTo, listen } from '@tauri-apps/api/event'
import {
  BadgeDollarSign,
  ChartNoAxesCombined,
  ChevronLeft,
  ChevronRight,
  Clock3,
  RefreshCw,
  Settings2,
  Sparkles,
} from 'lucide-react'

import {
  getScanInProgress,
  getConversationDetail,
  getLiveRateLimits,
  loadDashboard,
  refreshPricing,
  scanCodexUsage,
  updateSubscriptionProfile,
  updateSyncSettings,
} from './app/api'
import {
  formatCompactDateTime,
  formatDateTime,
  formatRemainingDuration,
  formatPercent,
  formatShortDate,
  formatTokenCount,
  formatUsd,
  todayInputValue,
} from './app/format'
import type { TranslationSet } from './app/i18n'
import { useI18n } from './app/useI18n'
import type {
  AppView,
  CompositionShare,
  ConversationDetail,
  ConversationListItem,
  ConversationSessionSummary,
  ConversationTurnPoint,
  LiveRateLimitSnapshot,
  ModelShare,
  OverviewBucket,
  OverviewResponse,
  ShareDimension,
  ShareMode,
  ShareSlice,
  SubscriptionProfile,
  SyncSettings,
} from './app/types'
import { ModelShareChart } from './components/ModelShareChart'
import { QuotaTrendChart } from './components/QuotaTrendChart'
import { SettingsPanel } from './components/SettingsPanel'
import { TrendChart } from './components/TrendChart'

const MENU_BAR_POPUP_WINDOW_LABEL = 'menu-bar-popup'
const MENU_BAR_POPUP_REFRESH_EVENT = 'codex-counter://menu-bar-popup-refresh'
const MENU_BAR_POPUP_LANGUAGE_EVENT = 'codex-counter://language-changed'
const PRODUCT_NAME = 'Codex Pacer'

const BUCKETS: OverviewBucket[] = [
  'five_hour',
  'day',
  'seven_day',
  'week',
  'subscription_month',
  'month',
  'year',
  'total',
]

function App() {
  const { language, setLanguage, t } = useI18n()
  const [view, setView] = useState<AppView>('overview')
  const [bucket, setBucket] = useState<OverviewBucket>('subscription_month')
  const [liveWindowOffset, setLiveWindowOffset] = useState(0)
  const [anchor, setAnchor] = useState(todayInputValue())
  const [shareMode, setShareMode] = useState<ShareMode>('value')
  const [shareDimension, setShareDimension] = useState<ShareDimension>('model')
  const [overview, setOverview] = useState<OverviewResponse | null>(null)
  const [conversations, setConversations] = useState<ConversationListItem[]>([])
  const [selectedRootSessionId, setSelectedRootSessionId] = useState<string | null>(null)
  const [detail, setDetail] = useState<ConversationDetail | null>(null)
  const [syncSettings, setSyncSettings] = useState<SyncSettings | null>(null)
  const [subscriptionProfile, setSubscriptionProfile] = useState<SubscriptionProfile | null>(null)
  const [liveRateLimits, setLiveRateLimits] = useState<LiveRateLimitSnapshot | null>(null)
  const [loadedQueryKey, setLoadedQueryKey] = useState<string | null>(null)
  const [dashboardRevision, setDashboardRevision] = useState(0)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [statusMessage, setStatusMessage] = useState(t.status.waitingForFirstScan)
  const [isBusy, setIsBusy] = useState(false)
  const [search, setSearch] = useState('')
  const deferredSearch = useDeferredValue(search)
  const syncSettingsRef = useRef<SyncSettings | null>(null)
  const loadShellRef = useRef<(requestScan?: boolean) => Promise<void>>(async () => {})
  const lastRequestedQueryKeyRef = useRef<string | null>(null)
  const latestLoadRequestIdRef = useRef(0)
  const detailCacheRef = useRef(new Map<string, ConversationDetail>())
  const latestDetailRequestIdRef = useRef(0)
  const [hasBootstrapped, setHasBootstrapped] = useState(false)

  const waitForScanToSettle = useCallback(async () => {
    const startedAt = Date.now()
    while (Date.now() - startedAt < 15000) {
      if (!(await getScanInProgress())) {
        return
      }
      await new Promise((resolve) => window.setTimeout(resolve, 250))
    }
  }, [])

  useEffect(() => {
    syncSettingsRef.current = syncSettings
  }, [syncSettings])

  const loadShell = useCallback(async (requestScan = false) => {
    const requestId = latestLoadRequestIdRef.current + 1
    latestLoadRequestIdRef.current = requestId
    const requestBucket = bucket
    const requestAnchor = bucketUsesAnchor(requestBucket) ? anchor : null
    const requestSearch = deferredSearch || null
    const requestLiveWindowOffset = requestBucket === 'five_hour' || requestBucket === 'seven_day' ? liveWindowOffset : 0
    lastRequestedQueryKeyRef.current = buildQueryKey(
      requestBucket,
      requestAnchor,
      requestSearch,
      requestLiveWindowOffset,
    )
    setIsBusy(true)
    if ((requestBucket === 'five_hour' || requestBucket === 'seven_day') && requestLiveWindowOffset === 0) {
      setStatusMessage(t.status.fetchingLiveQuotaWindow)
    }
    try {
      if (requestScan) {
        try {
          const scan = await scanCodexUsage(syncSettingsRef.current?.codexHome ?? null)
          setStatusMessage(t.status.scannedFiles(scan.scannedFiles, scan.updatedSessions))
        } catch (error) {
          const message = String(error)
          if (!message.includes('already running')) {
            throw error
          }
          setStatusMessage(t.status.backgroundScanAlreadyRunning)
          await waitForScanToSettle()
        }
      }

      const snapshot = await loadDashboard(
        requestBucket,
        requestAnchor,
        requestSearch,
        requestLiveWindowOffset,
      )
      if (requestId !== latestLoadRequestIdRef.current) {
        return
      }

      startTransition(() => {
        const nextDetailCache = new Map<string, ConversationDetail>()
        for (const conversation of snapshot.conversations) {
          const cachedDetail = detailCacheRef.current.get(conversation.rootSessionId)
          if (cachedDetail && cachedDetail.updatedAt === conversation.updatedAt) {
            nextDetailCache.set(conversation.rootSessionId, cachedDetail)
          }
        }

        setOverview(snapshot.overview)
        setConversations(snapshot.conversations)
        setSyncSettings(snapshot.syncSettings)
        setSubscriptionProfile(snapshot.subscriptionProfile)
        setLiveRateLimits(snapshot.liveRateLimits)
        detailCacheRef.current = nextDetailCache
        setDashboardRevision((current) => current + 1)
        setLiveWindowOffset(snapshot.overview.liveWindowOffset)
        setLoadedQueryKey(
          buildQueryKey(
            requestBucket,
            requestAnchor,
            requestSearch,
            snapshot.overview.liveWindowOffset,
          ),
        )
        setSelectedRootSessionId((current) =>
          current && snapshot.conversations.some((item) => item.rootSessionId === current)
            ? current
            : snapshot.conversations[0]?.rootSessionId ?? null,
        )
      })
    } catch (error) {
      if (requestId !== latestLoadRequestIdRef.current) {
        return
      }
      startTransition(() => {
        setLoadedQueryKey(null)
      })
      setStatusMessage(t.status.failedToLoad(t.buckets[requestBucket], String(error)))
    } finally {
      if (requestId === latestLoadRequestIdRef.current) {
        setIsBusy(false)
      }
    }
  }, [anchor, bucket, deferredSearch, liveWindowOffset, t, waitForScanToSettle])

  const currentQueryKey = buildQueryKey(
    bucket,
    bucketUsesAnchor(bucket) ? anchor : null,
    deferredSearch || null,
    bucket === 'five_hour' || bucket === 'seven_day' ? liveWindowOffset : 0,
  )

  useEffect(() => {
    loadShellRef.current = loadShell
  }, [loadShell])

  useEffect(() => {
    setStatusMessage((current) => {
      if (
        current === 'Waiting for first scan…' ||
        current === '等待首次扫描…' ||
        current === t.status.waitingForFirstScan
      ) {
        return t.status.waitingForFirstScan
      }
      if (
        current === 'Fetching live quota window…' ||
        current === '正在获取 live quota 窗口…' ||
        current === t.status.fetchingLiveQuotaWindow
      ) {
        return t.status.fetchingLiveQuotaWindow
      }
      return current
    })
  }, [t])

  useEffect(() => {
    if (!isTauri()) return

    let dispose: (() => void) | undefined
    void listen('codex-counter://open-settings', () => {
      setSettingsOpen(true)
    }).then((unlisten) => {
      dispose = unlisten
    })

    return () => {
      dispose?.()
    }
  }, [])

  useEffect(() => {
    if (!isTauri()) return
    void emitTo(MENU_BAR_POPUP_WINDOW_LABEL, MENU_BAR_POPUP_LANGUAGE_EVENT, { language }).catch(() => {})
  }, [language])

  const loadDetail = useCallback(async (rootSessionId: string | null) => {
    const requestId = latestDetailRequestIdRef.current + 1
    latestDetailRequestIdRef.current = requestId
    if (!rootSessionId) {
      setDetail(null)
      return
    }

    const cachedDetail = detailCacheRef.current.get(rootSessionId)
    if (cachedDetail) {
      setDetail(cachedDetail)
      return
    }

    setDetail(null)
    try {
      const nextDetail = await getConversationDetail(rootSessionId)
      if (requestId !== latestDetailRequestIdRef.current) {
        return
      }
      detailCacheRef.current.set(rootSessionId, nextDetail)
      startTransition(() => {
        setDetail(nextDetail)
      })
    } catch (error) {
      if (requestId !== latestDetailRequestIdRef.current) {
        return
      }
      setStatusMessage(String(error))
    }
  }, [])

  useEffect(() => {
    let cancelled = false

    const bootstrap = async () => {
      await loadShellRef.current(true)
      if (!cancelled) {
        setHasBootstrapped(true)
      }
    }

    void bootstrap()

    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    if (!hasBootstrapped) return
    if (lastRequestedQueryKeyRef.current === currentQueryKey) return
    void loadShell(false)
  }, [currentQueryKey, hasBootstrapped, loadShell])

  useEffect(() => {
    if (!loadedQueryKey && selectedRootSessionId) return
    void loadDetail(selectedRootSessionId)
  }, [dashboardRevision, loadDetail, loadedQueryKey, selectedRootSessionId])

  useEffect(() => {
    if (!hasBootstrapped) return
    const refreshMs =
      bucket === 'five_hour' || bucket === 'seven_day'
        ? (syncSettings?.liveQuotaRefreshIntervalSeconds ?? 300) * 1000
        : 60000
    const interval = window.setInterval(() => {
      void loadShell(false)
    }, Math.max(5000, refreshMs))
    return () => window.clearInterval(interval)
  }, [bucket, hasBootstrapped, loadShell, syncSettings?.liveQuotaRefreshIntervalSeconds])

  useEffect(() => {
    if (!settingsOpen) return
    let cancelled = false
    const refresh = () =>
      void getLiveRateLimits()
        .then((snapshot) => {
          if (!cancelled) {
            setLiveRateLimits(snapshot)
          }
        })
        .catch(() => {})
    refresh()
    const interval = window.setInterval(
      refresh,
      Math.max(60000, (syncSettings?.liveQuotaRefreshIntervalSeconds ?? 300) * 1000),
    )
    return () => {
      cancelled = true
      window.clearInterval(interval)
    }
  }, [settingsOpen, syncSettings?.liveQuotaRefreshIntervalSeconds])

  async function handleRescan() {
    await loadShell(true)
  }

  async function handleRefreshPricing() {
    setIsBusy(true)
    try {
      await refreshPricing()
      await loadShell(false)
      setStatusMessage(t.status.pricingRefreshed)
    } catch (error) {
      setStatusMessage(String(error))
    } finally {
      setIsBusy(false)
    }
  }

  async function handleSaveSettings(payload: {
    syncSettings: SyncSettings
    subscriptionProfile: SubscriptionProfile
  }) {
    const [nextSyncSettings, nextSubscriptionProfile] = await Promise.all([
      updateSyncSettings(payload.syncSettings),
      updateSubscriptionProfile(payload.subscriptionProfile),
    ])
    setSyncSettings(nextSyncSettings)
    setSubscriptionProfile(nextSubscriptionProfile)
    await loadShell(false)
    if (isTauri()) {
      await emitTo(MENU_BAR_POPUP_WINDOW_LABEL, MENU_BAR_POPUP_REFRESH_EVENT, {}).catch(() => {})
    }
    setStatusMessage(t.status.settingsSaved)
  }

  const snapshotIsCurrent = loadedQueryKey === currentQueryKey
  const activeOverview = snapshotIsCurrent ? overview : null
  const activeConversations = snapshotIsCurrent ? conversations : []
  const isLiveBucket = bucket === 'five_hour' || bucket === 'seven_day'
  const activeLiveWindowOffset = activeOverview?.liveWindowOffset ?? liveWindowOffset
  const activeLiveWindowCount = activeOverview?.liveWindowCount ?? (isLiveBucket ? 1 : 0)
  const isHistoricalLiveWindow = isLiveBucket && activeLiveWindowOffset > 0
  const currentBucketLabel =
    activeOverview?.bucket === 'subscription_month' && subscriptionProfile
      ? t.bucketDescriptions.subscriptionMonth(subscriptionProfile.billingAnchorDay)
      : bucket === 'five_hour'
        ? isHistoricalLiveWindow
          ? t.bucketDescriptions.historicalFiveHourWindow
          : t.bucketDescriptions.currentFiveHourWindow
        : bucket === 'seven_day'
          ? isHistoricalLiveWindow
            ? t.bucketDescriptions.historicalSevenDayWindow
            : t.bucketDescriptions.currentSevenDayWindow
      : t.buckets[bucket]
  const shouldShowStatusNotice = /error|invalid|unsupported|failed/i.test(statusMessage)
  const shouldShowLoadingNotice =
    isBusy && !shouldShowStatusNotice && isLiveBucket && liveWindowOffset === 0
  const resolvedBucket = bucket
  const resolvedLiveRateLimits = activeOverview?.liveRateLimits ?? liveRateLimits
  const activeRateLimitWindow = selectActiveRateLimitWindow(resolvedLiveRateLimits, resolvedBucket)
  const overviewShareData = buildShareSlices(
    shareDimension,
    activeOverview?.modelShares ?? [],
    activeOverview?.compositionShares ?? [],
  )
  const activeDetail = snapshotIsCurrent ? detail : null
  const detailShareData = buildShareSlices(
    shareDimension,
    activeDetail?.modelBreakdown ?? [],
    activeDetail?.compositionBreakdown ?? [],
  )
  const sessionSummariesById = new Map(
    (activeDetail?.sessions ?? []).map((session) => [session.sessionId, session] as const),
  )
  const latestQuotaPoint = [...(activeOverview?.quotaTrend ?? [])]
    .reverse()
    .find((point) => point.remainingPercent !== null)
  const currentRemainingPercent = activeRateLimitWindow?.remainingPercent ?? latestQuotaPoint?.remainingPercent ?? 0
  const currentUsedPercent = activeRateLimitWindow?.usedPercent ?? latestQuotaPoint?.usedPercent ?? 0
  const wastedPercent = Math.max(0, 100 - Math.max(...(activeOverview?.quotaTrend ?? []).map((point) => point.usedPercent ?? 0), 0))
  const liveWindowRangeLabel =
    activeOverview && isLiveBucket
      ? `${formatCompactDateTime(activeOverview.windowStart, language)} → ${formatCompactDateTime(activeOverview.windowEnd, language)}`
      : null
  const lastScanLabel = syncSettings?.lastScanCompletedAt
    ? formatCompactDateTime(syncSettings.lastScanCompletedAt, language)
    : t.status.waitingForFirstScan
  const showHeroSummary = view === 'conversations'
  const heroEyebrow = t.nav.conversations
  const heroTitle = t.conversationList.title
  const heroSubtitle = currentBucketLabel
  const anchorInputLabel =
    language === 'zh-CN' ? `${t.buckets[bucket]}统计锚点日期` : `${t.buckets[bucket]} anchor date`
  const heroStatusLabel = language === 'zh-CN' ? '仪表盘状态' : 'Dashboard status'

  return (
    <div className="app-shell">
      <div className="app-frame">
        <aside className="sidebar">
          <div className="brand">
            <h1>{PRODUCT_NAME}</h1>
          </div>

          <div className="nav-stack">
            <button
              className={`nav-button ${view === 'overview' ? 'active' : ''}`}
              onClick={() => setView('overview')}
              type="button"
            >
              <ChartNoAxesCombined size={18} /> {t.nav.overview}
            </button>
            <button
              className={`nav-button ${view === 'conversations' ? 'active' : ''}`}
              onClick={() => setView('conversations')}
              type="button"
            >
              <Sparkles size={18} /> {t.nav.conversations}
            </button>
          </div>

          <div className="action-stack">
            <button className="accent-button" disabled={isBusy} onClick={handleRescan} type="button">
              <RefreshCw size={16} /> {t.actions.rescanNow}
            </button>
            <button className="ghost-button" disabled={isBusy} onClick={handleRefreshPricing} type="button">
              <BadgeDollarSign size={16} /> {t.actions.refreshPricing}
            </button>
          </div>

          <div className="sidebar-footer">
            <button className="ghost-button" onClick={() => setSettingsOpen(true)} type="button">
              <Settings2 size={16} /> {t.actions.settings}
            </button>

            <div className="status-panel sidebar-status-panel">
              <span className="eyebrow">{t.common.autoScan}</span>
              <strong>
                {syncSettings?.autoScanEnabled
                  ? t.common.everyMinutes(syncSettings.autoScanIntervalMinutes)
                  : t.common.disabled}
              </strong>
              <Clock3 size={18} />
            </div>
          </div>
        </aside>

        <main className="main-panel">
          <section className={`hero-panel hero-panel-filters ${showHeroSummary ? '' : 'hero-panel-filters--controls-only'}`}>
            {showHeroSummary ? (
              <div className="hero-toolbar">
                <div className="hero-copy">
                  <p className="eyebrow">{heroEyebrow}</p>
                  <h2>{heroTitle}</h2>
                  <p className="subtitle">{heroSubtitle}</p>
                </div>
                <div className="hero-meta-strip" aria-label={heroStatusLabel}>
                  <div className="hero-meta-pill">
                    <span>{t.common.autoScan}</span>
                    <strong>
                      {syncSettings?.autoScanEnabled
                        ? t.common.everyMinutes(syncSettings.autoScanIntervalMinutes)
                        : t.common.disabled}
                    </strong>
                  </div>
                  <div className="hero-meta-pill">
                    <span>{t.common.updated}</span>
                    <strong>{lastScanLabel}</strong>
                  </div>
                  <div className="hero-meta-pill">
                    <span>{isLiveBucket ? t.common.quotaWindow : t.nav.overview}</span>
                    <strong>{isLiveBucket ? liveWindowRangeLabel ?? currentBucketLabel : currentBucketLabel}</strong>
                  </div>
                </div>
              </div>
            ) : null}

            <div className={`hero-filter-region ${showHeroSummary ? '' : 'hero-filter-region--standalone'}`}>
              <div className="hero-filter-controls">
                <div className="pill-strip">
                  {BUCKETS.map((option) => (
                    <button
                      key={option}
                      className={option === bucket ? 'active' : ''}
                      onClick={() => {
                        setBucket(option)
                        setLiveWindowOffset(0)
                      }}
                      type="button"
                    >
                      {t.buckets[option]}
                    </button>
                  ))}
                </div>
                {bucketUsesAnchor(bucket) ? (
                  <input
                    aria-label={anchorInputLabel}
                    className="anchor-input anchor-input-inline"
                    onChange={(event) => setAnchor(event.target.value)}
                    name="bucketAnchorDate"
                    type="date"
                    value={anchor}
                  />
                ) : isLiveBucket ? (
                  <div className="live-window-nav">
                    <button
                      aria-label={t.common.earlier}
                      className="ghost-button live-window-nav-button"
                      disabled={isBusy || activeLiveWindowOffset >= Math.max(activeLiveWindowCount - 1, 0)}
                      onClick={() => setLiveWindowOffset((current) => current + 1)}
                      title={t.common.earlier}
                      type="button"
                    >
                      <ChevronLeft aria-hidden="true" size={16} />
                    </button>
                    <div className="live-window-nav-copy">
                      <strong>{liveWindowRangeLabel ?? currentBucketLabel}</strong>
                    </div>
                    <button
                      aria-label={t.common.newer}
                      className="ghost-button live-window-nav-button"
                      disabled={isBusy || activeLiveWindowOffset <= 0}
                      onClick={() => setLiveWindowOffset((current) => Math.max(0, current - 1))}
                      title={t.common.newer}
                      type="button"
                    >
                      <ChevronRight aria-hidden="true" size={16} />
                    </button>
                  </div>
                ) : null}
              </div>
            </div>
          </section>

          {shouldShowLoadingNotice ? (
            <div aria-live="polite" className="status-inline status-inline-muted" role="status">
              {t.status.fetchingLiveQuotaWindow}
            </div>
          ) : null}
          {shouldShowStatusNotice ? (
            <div aria-live="polite" className="status-inline" role="status">
              {statusMessage}
            </div>
          ) : null}

          {view === 'overview' ? (
            <>
              <section className="metric-grid">
                {isLiveBucket ? (
                  <>
                    <MetricCard
                      caption={t.metrics.apiValue}
                      featured
                      tone="primary"
                      value={formatUsd(activeOverview?.stats.apiValueUsd ?? 0, language)}
                      note={currentBucketLabel}
                    />
                    <MetricCard
                      caption={isHistoricalLiveWindow ? t.metrics.wastedQuota : t.metrics.remainingQuota}
                      tone="secondary"
                      value={formatPercent(
                        (isHistoricalLiveWindow ? wastedPercent : currentRemainingPercent) / 100,
                        language,
                      )}
                      note={
                        isHistoricalLiveWindow
                          ? t.metrics.peakUsed(formatPercent((100 - wastedPercent) / 100, language))
                          : latestQuotaPoint
                            ? t.metrics.used(formatPercent(currentUsedPercent / 100, language))
                            : t.status.waitingLiveQuota
                      }
                    />
                    <MetricCard
                      caption={isHistoricalLiveWindow ? t.metrics.windowStart : t.metrics.remainingTime}
                      tone="accent"
                      value={
                        isHistoricalLiveWindow
                          ? formatCompactDateTime(activeOverview?.windowStart ?? null, language)
                          : formatRemainingDuration(activeOverview?.windowEnd ?? null, language)
                      }
                      compact
                      note={
                        isHistoricalLiveWindow
                          ? `${t.common.reset} ${formatCompactDateTime(activeOverview?.windowEnd ?? null, language)}`
                          : activeOverview?.windowEnd
                            ? `${t.common.reset} ${formatCompactDateTime(activeOverview.windowEnd, language)}`
                            : undefined
                      }
                    />
                    <MetricCard
                      caption={t.metrics.totalTokens}
                      tone="neutral"
                      value={formatTokenCount(activeOverview?.stats.totalTokens ?? 0, language)}
                    />
                    <MetricCard
                      caption={t.metrics.conversationCount}
                      tone="neutral"
                      value={String(activeOverview?.stats.conversationCount ?? 0)}
                    />
                  </>
                ) : (
                  <>
                    <MetricCard
                      caption={t.metrics.apiValue}
                      featured
                      tone="primary"
                      value={formatUsd(activeOverview?.stats.apiValueUsd ?? 0, language)}
                      note={currentBucketLabel}
                    />
                    <MetricCard
                      caption={t.metrics.subscriptionCost}
                      tone="secondary"
                      value={formatUsd(activeOverview?.stats.subscriptionCostUsd ?? 0, language)}
                      note={
                        subscriptionProfile
                          ? t.metrics.planPerMonth(
                              subscriptionProfile.planType,
                              formatUsd(subscriptionProfile.monthlyPrice, language),
                            )
                          : undefined
                      }
                    />
                    <MetricCard
                      caption={t.metrics.payoffRatio}
                      tone="accent"
                      value={formatPercent(activeOverview?.stats.payoffRatio ?? 0, language)}
                    />
                    <MetricCard
                      caption={t.metrics.totalTokens}
                      tone="neutral"
                      value={formatTokenCount(activeOverview?.stats.totalTokens ?? 0, language)}
                    />
                    <MetricCard
                      caption={t.metrics.conversationCount}
                      tone="neutral"
                      value={String(activeOverview?.stats.conversationCount ?? 0)}
                    />
                  </>
                )}
              </section>

              <section className="overview-grid">
                {isLiveBucket ? (
                  <QuotaTrendChart
                    bucket={resolvedBucket}
                    data={activeOverview?.quotaTrend ?? []}
                    liveRateLimits={resolvedLiveRateLimits}
                    windowStart={activeOverview?.windowStart ?? new Date().toISOString()}
                    windowEnd={activeOverview?.windowEnd ?? new Date().toISOString()}
                    isHistorical={isHistoricalLiveWindow}
                  />
                ) : (
                  <TrendChart data={activeOverview?.trend ?? []} />
                )}
                <ModelShareChart
                  data={overviewShareData}
                  mode={shareMode}
                  onModeChange={setShareMode}
                  dimension={shareDimension}
                  onDimensionChange={setShareDimension}
                  title={shareDimension === 'model' ? t.overview.modelShare : t.overview.costStructure}
                  eyebrow={t.overview.distribution}
                />
              </section>
            </>
          ) : (
            <section className="conversation-layout">
              <aside className="list-panel">
                <div className="list-toolbar">
                  <div className="list-toolbar-head">
                    <div className="list-toolbar-copy">
                      <p className="eyebrow">{t.conversationList.eyebrow}</p>
                      <h3>{t.conversationList.title}</h3>
                    </div>
                    <span className="detail-micro list-toolbar-count">
                      {t.conversationList.shown(activeConversations.length)}
                    </span>
                  </div>
                  <input
                    aria-label={t.common.searchTitleOrSession}
                    className="search-input"
                    name="conversationSearch"
                    onChange={(event) => setSearch(event.target.value)}
                    placeholder={t.common.searchTitleOrSession}
                    value={search}
                  />
                </div>

                <div className="conversation-list">
                  {activeConversations.length === 0 ? (
                    <div className="empty-state">{t.conversationList.empty}</div>
                  ) : (
                    activeConversations.map((conversation) => (
                      <button
                        key={conversation.rootSessionId}
                        className={`conversation-card ${
                          conversation.rootSessionId === selectedRootSessionId ? 'active' : ''
                        }`}
                        onClick={() => setSelectedRootSessionId(conversation.rootSessionId)}
                        type="button"
                        >
                        <div className="card-topline">
                          <span className="card-id">{conversation.rootSessionId.slice(0, 12)}</span>
                          <span>{formatUsd(conversation.apiValueUsd, language)}</span>
                        </div>
                        <h4>{conversation.title}</h4>
                        <div className="badge-row">
                          {conversation.modelIds.map((modelId) => (
                            <span className="model-chip" key={modelId}>
                              {modelId}
                            </span>
                          ))}
                          {conversation.hasFastMode ? <span className="badge fast">{t.common.fast}</span> : null}
                        </div>
                        <div className="token-row">
                          <span>
                            {formatTokenCount(conversation.totalTokens, language)} {t.common.tokens}
                          </span>
                          <span>
                            {conversation.sessionCount} {t.common.sessions}
                          </span>
                        </div>
                        <div className="meta-row">
                          <span>{formatShortDate(conversation.updatedAt, language)}</span>
                          <span>{formatPercent(conversation.subscriptionShare, language)}</span>
                        </div>
                      </button>
                    ))
                  )}
                </div>
              </aside>

              <section className="detail-panel">
                {activeDetail ? (
                  <>
                    <div className="detail-topline">
                      <div>
                        <p className="eyebrow">{t.detail.eyebrow}</p>
                        <h3>{activeDetail.title}</h3>
                        <p className="subtitle mono">{activeDetail.rootSessionId}</p>
                      </div>
                      <div className="badge-row">
                        {activeDetail.sourceStates.map((sourceState) => (
                          <span className="state-chip" key={sourceState}>
                            {sourceState}
                          </span>
                        ))}
                      </div>
                    </div>

                    <div className="detail-metrics">
                      <MiniCard
                        label={t.metrics.apiValue}
                        tone="primary"
                        value={formatUsd(activeDetail.apiValueUsd, language)}
                      />
                      <MiniCard
                        label={t.metrics.monthlyFeeShare}
                        tone="accent"
                        value={formatPercent(activeDetail.subscriptionShare, language)}
                      />
                      <MiniCard
                        label={t.charts.tokens}
                        tone="secondary"
                        value={formatTokenCount(activeDetail.totalTokens, language)}
                      />
                    </div>

                    <ModelShareChart
                      data={detailShareData}
                      mode={shareMode}
                      onModeChange={setShareMode}
                      dimension={shareDimension}
                      onDimensionChange={setShareDimension}
                      title={
                        shareDimension === 'model'
                          ? t.detail.conversationModelBreakdown
                          : t.detail.conversationCostBreakdown
                      }
                      eyebrow={t.detail.modelBreakdown}
                    />

                    <section className="section-card">
                      <div className="chart-heading">
                        <div>
                          <p className="eyebrow">{t.detail.turnTimelineEyebrow}</p>
                          <h3>{t.detail.turnUsage}</h3>
                        </div>
                        <p className="chart-note">
                          {t.detail.latestTurns(Math.min(activeDetail.turns.length, 40))}
                        </p>
                      </div>
                      <div className="timeline-grid">
                        {activeDetail.turns.length === 0 ? (
                          <div className="empty-state">{t.detail.emptyTurns}</div>
                        ) : (
                          activeDetail.turns.slice(-40).reverse().map((turn) => {
                            const session = sessionSummariesById.get(turn.sessionId)
                            const modelSummary = formatModelSummary(turn.modelIds, t)
                            const sessionLabel = formatSessionLabel(session, turn.sessionId, t)
                            const statusLabel = formatTurnStatus(turn.status)
                            const title = turn.userMessage ?? turn.assistantMessage ?? turn.turnId

                            return (
                              <article className="timeline-row" key={`${turn.sessionId}-${turn.turnId}`}>
                                <div className="timeline-head">
                                  <strong title={title}>{formatTurnHeadline(turn, t)}</strong>
                                  <div className="timeline-value-group">
                                    <span className="timeline-metric">
                                      {formatTokenCount(turn.totalTokens, language)} {t.common.tokens}
                                    </span>
                                    <span className="timeline-value">
                                      {formatUsd(turn.valueUsd, language)}
                                    </span>
                                  </div>
                                </div>
                                <div className="timeline-meta">
                                  <span className="timeline-pill">
                                    {formatDateTime(turn.lastActivityAt, language)}
                                  </span>
                                  <span className="timeline-pill">{sessionLabel}</span>
                                  <span className="timeline-pill">{modelSummary}</span>
                                  {turn.fastModeEffective ? (
                                    <span className="timeline-pill timeline-pill-fast">{t.common.fast}</span>
                                  ) : null}
                                  {statusLabel ? <span className="timeline-pill">{statusLabel}</span> : null}
                                </div>
                              </article>
                            )
                          })
                        )}
                      </div>
                    </section>
                  </>
                ) : (
                  <div className="empty-state">{t.detail.emptySelection}</div>
                )}
              </section>
            </section>
          )}
        </main>
      </div>

      <SettingsPanel
        isOpen={settingsOpen}
        language={language}
        liveRateLimits={liveRateLimits}
        onClose={() => setSettingsOpen(false)}
        onLanguageChange={setLanguage}
        onSave={handleSaveSettings}
        subscriptionProfile={subscriptionProfile}
        syncSettings={syncSettings}
      />
    </div>
  )
}

interface MetricCardProps {
  caption: string
  value: string
  note?: string
  compact?: boolean
  tone?: 'primary' | 'secondary' | 'accent' | 'neutral'
  featured?: boolean
}

interface MiniCardProps {
  label: string
  value: string
  tone?: 'primary' | 'secondary' | 'accent'
}

function MetricCard({
  caption,
  value,
  note,
  compact = false,
  tone = 'neutral',
  featured = false,
}: MetricCardProps) {
  return (
    <section
      className={`metric-card metric-card--${tone} ${compact ? 'metric-card--compact' : ''} ${
        featured ? 'metric-card--featured' : ''
      }`}
    >
      <span className="metric-label">{caption}</span>
      <strong>{value}</strong>
      {note ? <span className="stat-caption">{note}</span> : null}
    </section>
  )
}

function MiniCard({ label, value, tone = 'secondary' }: MiniCardProps) {
  return (
    <div className={`detail-mini-card detail-mini-card--${tone}`}>
      <span className="metric-label">{label}</span>
      <strong>{value}</strong>
    </div>
  )
}

export default App

function bucketUsesAnchor(bucket: OverviewBucket) {
  return !['five_hour', 'seven_day', 'total'].includes(bucket)
}

function buildQueryKey(
  bucket: OverviewBucket,
  anchor: string | null,
  search: string | null,
  liveWindowOffset: number,
) {
  return [bucket, anchor ?? '', search ?? '', String(liveWindowOffset)].join('::')
}

function selectActiveRateLimitWindow(
  liveRateLimits: LiveRateLimitSnapshot | null,
  bucket: OverviewBucket,
) {
  if (!liveRateLimits) return null
  if (bucket === 'five_hour') return liveRateLimits.primary
  if (bucket === 'seven_day') return liveRateLimits.secondary
  return null
}

function formatTurnHeadline(turn: ConversationTurnPoint, t: TranslationSet) {
  const content = [turn.userMessage, turn.assistantMessage, turn.turnId]
    .filter((value): value is string => Boolean(value && value.trim()))
    .map((value) => value.replace(/\s+/g, ' ').trim())[0]

  if (!content) return t.detail.untitledTurn
  if (content.length <= 110) return content
  return `${content.slice(0, 109).trimEnd()}…`
}

function formatModelSummary(modelIds: string[], t: TranslationSet) {
  if (modelIds.length === 0) return t.detail.unknownModel
  if (modelIds.length === 1) return modelIds[0]
  return `${modelIds[0]} +${modelIds.length - 1}`
}

function formatSessionLabel(
  session: ConversationSessionSummary | undefined,
  sessionId: string,
  t: TranslationSet,
) {
  if (!session) return t.detail.sessionLabel(sessionId)
  if (session.agentNickname) return session.agentNickname
  return session.isSubagent ? t.detail.subagent : t.detail.mainSession
}

function formatTurnStatus(status: string) {
  if (!status) return null
  if (status === 'completed') return null
  return status.replace(/_/g, ' ')
}

function buildShareSlices(
  dimension: ShareDimension,
  modelShares: ModelShare[],
  compositionShares: CompositionShare[],
): ShareSlice[] {
  if (dimension === 'composition') {
    return compositionShares.map((item) => ({
      id: item.category,
      label: item.label,
      secondaryLabel:
        item.category === 'input'
          ? 'uncached'
          : item.category === 'cache'
            ? 'cached'
            : 'generated',
      apiValueUsd: item.apiValueUsd,
      totalTokens: item.totalTokens,
      color: item.color,
    }))
  }

  return modelShares.map((item) => ({
    id: item.modelId,
    label: item.displayName,
    secondaryLabel: item.modelId,
    apiValueUsd: item.apiValueUsd,
    totalTokens: item.totalTokens,
    color: item.color,
  }))
}

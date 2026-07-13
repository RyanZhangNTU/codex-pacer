import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { isTauri } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { ChartNoAxesCombined, RefreshCw } from 'lucide-react'

import { getMenuBarPopupSnapshot, handleMenuBarPopupAction, resizeMenuBarPopup } from '../app/api'
import {
  formatCompactDateTime,
  formatDateTime,
  formatPercent,
  formatRelative,
  formatRemainingDuration,
  formatTokenCount,
  formatUsd,
} from '../app/format'
import {
  settleRefreshFailure,
  SurfaceRequestController,
  type RefreshSurfaceState,
} from '../app/refreshEvents'
import type { MenuBarPopupModuleId, MenuBarPopupSnapshot } from '../app/types'
import { useI18n } from '../app/useI18n'
import { PopupStatModuleGrid } from '../components/PopupStatModuleGrid'
import { PopupSevenDayUsageChart } from '../components/PopupSevenDayUsageChart'
import { QuotaRingCard } from '../components/QuotaRingCard'

const POPUP_RESIZE_PADDING = 18

function computeRemainingTimePercent(resetsAt: string | null, windowStart: string | null) {
  if (!resetsAt || !windowStart) return null

  const resetTimestamp = new Date(resetsAt).getTime()
  const startTimestamp = new Date(windowStart).getTime()
  const nowTimestamp = Date.now()
  if (!Number.isFinite(resetTimestamp) || !Number.isFinite(startTimestamp) || resetTimestamp <= startTimestamp) {
    return null
  }

  const total = resetTimestamp - startTimestamp
  const remaining = resetTimestamp - nowTimestamp
  return Math.max(0, Math.min(100, Math.round((remaining / total) * 100)))
}

function measuredPopupHeight(panel: HTMLElement) {
  const panelHeight = Math.max(panel.scrollHeight, panel.getBoundingClientRect().height)
  return Math.ceil(panelHeight + POPUP_RESIZE_PADDING)
}

export function MenuBarPopup() {
  const { language, setLanguage, t } = useI18n()
  const panelRef = useRef<HTMLDivElement | null>(null)
  const lastMeasuredHeightRef = useRef<number | null>(null)
  const resizeFrameRef = useRef(0)
  const requestControllerRef = useRef(new SurfaceRequestController())
  const [loadState, setLoadState] = useState<RefreshSurfaceState<MenuBarPopupSnapshot>>({
    data: null,
    loading: true,
    refreshing: false,
    error: null,
  })
  const { data: snapshot, loading, refreshing, error } = loadState

  const loadSnapshot = useCallback(async (forceRefresh = false) => {
    const claim = requestControllerRef.current.claim(forceRefresh ? 'manual' : 'passive')
    if (claim === null) return
    const manualInFlight = requestControllerRef.current.manualInFlight
    setLoadState((current) => {
      return {
        ...current,
        loading: forceRefresh ? current.loading : current.data === null,
        refreshing: manualInFlight,
      }
    })

    let failed = false
    let failure: unknown
    let nextSnapshot: MenuBarPopupSnapshot | null = null
    try {
      nextSnapshot = await getMenuBarPopupSnapshot(forceRefresh)
    } catch (loadError) {
      failed = true
      failure = loadError
    } finally {
      requestControllerRef.current.finish(claim)
      setLoadState((current) => {
        let nextState = current
        if (requestControllerRef.current.isLatest(claim)) {
          if (failed) {
            nextState = settleRefreshFailure(current, failure)
          } else if (nextSnapshot !== null) {
            nextState = {
              ...current,
              data: nextSnapshot,
              loading: false,
              error: null,
            }
          }
        }
        return {
          ...nextState,
          refreshing: requestControllerRef.current.manualInFlight,
        }
      })
    }
  }, [])

  useEffect(() => {
    if (!isTauri()) {
      void loadSnapshot(false)
      return
    }
    void getCurrentWindow()
      .isVisible()
      .then((visible) => {
        if (visible) void loadSnapshot(false)
      })
      .catch(() => {})
  }, [loadSnapshot])

  const schedulePopupResize = useCallback(() => {
    if (!isTauri()) return

    window.cancelAnimationFrame(resizeFrameRef.current)
    resizeFrameRef.current = window.requestAnimationFrame(() => {
      const panel = panelRef.current
      if (!panel) return

      const nextHeight = measuredPopupHeight(panel)
      if (Math.abs((lastMeasuredHeightRef.current ?? 0) - nextHeight) < 2) return

      lastMeasuredHeightRef.current = nextHeight
      void resizeMenuBarPopup(nextHeight).catch(() => {})
    })
  }, [])

  useEffect(() => {
    const handleEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        void handleMenuBarPopupAction('hide')
      }
    }

    window.addEventListener('keydown', handleEscape)
    return () => window.removeEventListener('keydown', handleEscape)
  }, [])

  useEffect(() => {
    if (!isTauri()) return

    let cancelled = false
    const disposers = new Set<() => void>()
    const trackRegistration = (registration: Promise<() => void>) => {
      void registration
        .then((dispose) => {
          if (cancelled) {
            dispose()
          } else {
            disposers.add(dispose)
          }
        })
        .catch(() => {})
    }
    const resizeObserver = new ResizeObserver(() => {
      schedulePopupResize()
    })

    if (panelRef.current) {
      resizeObserver.observe(panelRef.current)
    }
    window.addEventListener('resize', schedulePopupResize)
    schedulePopupResize()

    trackRegistration(
      listen('codex-counter://menu-bar-popup-refresh', () => {
        if (!cancelled) {
          void getCurrentWindow()
            .isVisible()
            .then((visible) => {
              if (!cancelled && visible) void loadSnapshot(false)
            })
            .catch(() => {})
        }
      }),
    )

    trackRegistration(
      listen<{ language?: 'zh-CN' | 'en' }>('codex-counter://language-changed', (event) => {
        if (!cancelled && event.payload?.language) {
          setLanguage(event.payload.language)
        }
      }),
    )

    return () => {
      cancelled = true
      window.cancelAnimationFrame(resizeFrameRef.current)
      window.removeEventListener('resize', schedulePopupResize)
      resizeObserver.disconnect()
      for (const dispose of disposers) {
        dispose()
      }
      disposers.clear()
    }
  }, [loadSnapshot, schedulePopupResize, setLanguage])

  const moduleCards = useMemo(() => {
    if (!snapshot) return []

    const descriptors: Record<MenuBarPopupModuleId, { label: string; value: string; note?: string | null }> = {
      api_value: {
        label: t.popup.modules.apiValue,
        value: formatUsd(snapshot.apiValueSelectedBucket, language),
        note: t.buckets[snapshot.selectedBucket],
      },
      token_count: {
        label: t.popup.modules.tokenCount,
        value: formatTokenCount(snapshot.totalTokensSelectedBucket, language),
        note: t.buckets[snapshot.selectedBucket],
      },
      scan_freshness: {
        label: t.popup.modules.scanFreshness,
        value: formatRelative(snapshot.lastScanCompletedAt, language),
        note: snapshot.lastScanCompletedAt ? formatDateTime(snapshot.lastScanCompletedAt, language) : t.common.noData,
      },
      live_quota_freshness: {
        label: t.popup.modules.liveQuotaFreshness,
        value: formatRelative(snapshot.liveQuotaFetchedAt, language),
        note: snapshot.liveQuotaFetchedAt ? formatDateTime(snapshot.liveQuotaFetchedAt, language) : t.common.noData,
      },
      payoff_ratio: {
        label: t.popup.modules.payoffRatio,
        value: formatPercent(snapshot.payoffRatio, language),
        note: t.metrics.payoffRatio,
      },
      conversation_count: {
        label: t.popup.modules.conversationCount,
        value: String(snapshot.conversationCountSelectedBucket),
        note: t.buckets[snapshot.selectedBucket],
      },
    }

    return snapshot.visibleModules.map((moduleId) => ({
      id: moduleId,
      ...descriptors[moduleId],
    }))
  }, [language, snapshot, t])

  const visibleModuleSignature = snapshot?.visibleModules.join('|') ?? ''
  const showPopupActions = snapshot?.showActions ?? true

  useEffect(() => {
    schedulePopupResize()
  }, [
    error,
    language,
    loading,
    schedulePopupResize,
    snapshot?.showActions,
    snapshot?.showResetTimeline,
    visibleModuleSignature,
  ])

  return (
    <div className="menu-popup-shell">
      <div className="menu-popup-panel" ref={panelRef}>
        <header className="menu-popup-header">
          <span className="brand-badge">{t.appSubtitle}</span>
          {showPopupActions ? (
            <div className="popup-header-actions">
              <button
                aria-label={t.popup.actions.openDashboard}
                className="ghost-button popup-icon-button"
                onClick={() => void handleMenuBarPopupAction('open_dashboard')}
                type="button"
              >
                <ChartNoAxesCombined size={16} />
              </button>
              <button
                aria-label={t.popup.actions.refresh}
                className="ghost-button popup-icon-button"
                disabled={refreshing}
                onClick={() => void loadSnapshot(true)}
                type="button"
              >
                <RefreshCw className={refreshing ? 'spinning' : ''} size={16} />
              </button>
            </div>
          ) : null}
        </header>

        {loading ? (
          <div className="popup-card popup-empty-state">{t.popup.loading}</div>
        ) : error ? (
          <div className="popup-card popup-empty-state">
            <strong>{t.popup.failedTitle}</strong>
            <p>{error}</p>
          </div>
        ) : snapshot ? (
          <>
            <section className="popup-hero-grid">
              <QuotaRingCard
                label={t.buckets.five_hour}
                percent={snapshot.quota5h?.remainingPercent ?? 0}
                timePercent={computeRemainingTimePercent(snapshot.quota5h?.resetsAt ?? null, snapshot.quota5h?.windowStart ?? null)}
                subtitle={
                  snapshot.quota5h?.resetsAt
                    ? t.popup.resetIn(formatRemainingDuration(snapshot.quota5h.resetsAt, language))
                    : t.common.noData
                }
                tone="warm"
              />
              <QuotaRingCard
                label={t.buckets.seven_day}
                percent={snapshot.quota7d?.remainingPercent ?? 0}
                timePercent={computeRemainingTimePercent(snapshot.quota7d?.resetsAt ?? null, snapshot.quota7d?.windowStart ?? null)}
                subtitle={
                  snapshot.quota7d?.resetsAt
                    ? t.popup.resetIn(formatRemainingDuration(snapshot.quota7d.resetsAt, language))
                    : t.common.noData
                }
                tone="cool"
              />
            </section>

            <PopupSevenDayUsageChart
              ariaLabel={t.popup.sevenDayUsageChart}
              data={snapshot.quotaTrend7d}
              fetchedAt={snapshot.liveQuotaFetchedAt ?? snapshot.fetchedAt}
              quota={snapshot.quota7d}
              speed={snapshot.suggestedSpeed7d}
            />

            {snapshot.showResetTimeline ? (
              <section className="popup-reset-row">
                <div className="popup-reset-pill">
                  <span>{t.popup.resetTimeline5h}</span>
                  <strong>
                    {snapshot.quota5h?.resetsAt
                      ? formatCompactDateTime(snapshot.quota5h.resetsAt, language)
                      : t.common.noData}
                  </strong>
                </div>
                <div className="popup-reset-pill">
                  <span>{t.popup.resetTimeline7d}</span>
                  <strong>
                    {snapshot.quota7d?.resetsAt
                      ? formatCompactDateTime(snapshot.quota7d.resetsAt, language)
                      : t.common.noData}
                  </strong>
                </div>
              </section>
            ) : null}

            <PopupStatModuleGrid modules={moduleCards} />
          </>
        ) : null}
      </div>
    </div>
  )
}

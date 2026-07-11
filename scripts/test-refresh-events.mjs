import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { settleRefreshFailure, SurfaceRevisionGate } from '../src/app/refreshEvents.ts'

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const appSource = readFileSync(join(repoRoot, 'src/App.tsx'), 'utf8')
const popupSource = readFileSync(join(repoRoot, 'src/menu-bar-popup/MenuBarPopup.tsx'), 'utf8')
const apiSource = readFileSync(join(repoRoot, 'src/app/api.ts'), 'utf8')
const dataFreshnessSource = readFileSync(join(repoRoot, 'src/app/dataFreshness.ts'), 'utf8')

function completion(refreshRevision, succeeded = true) {
  return {
    refreshRevision,
    lane: 'token',
    generation: refreshRevision,
    usageRevision: refreshRevision,
    quotaRevision: 0,
    sourceGeneration: 1,
    succeeded,
    failure: succeeded ? null : 'refresh failed',
    completedAt: '2026-07-11T00:00:00Z',
  }
}

test('surface_revision_gate_deduplicates_visible_completions', () => {
  const gate = new SurfaceRevisionGate()

  assert.equal(gate.accept(completion(1), true), 'reload')
  assert.equal(gate.accept(completion(1), true), 'ignore')
})

test('surface_revision_gate_keeps_only_latest_hidden_revision_until_visible', () => {
  const gate = new SurfaceRevisionGate()

  assert.equal(gate.accept(completion(1), true), 'reload')
  assert.equal(gate.accept(completion(2), false), 'defer')
  assert.equal(gate.accept(completion(3), false), 'defer')
  assert.equal(gate.onVisible(), 'reload')
  assert.equal(gate.onVisible(), 'ignore')
})

test('failed_completion_does_not_reload_data', () => {
  const gate = new SurfaceRevisionGate()
  const previousData = Object.freeze({ cards: ['existing-card'], sourceTimestamp: '2026-07-10T00:00:00Z' })
  const currentSurface = { data: previousData, reloads: 0 }

  const decision = gate.accept(completion(1, false), true)
  const nextSurface =
    decision === 'reload'
      ? { data: { cards: ['replacement-card'], sourceTimestamp: null }, reloads: 1 }
      : currentSurface

  assert.equal(decision, 'ignore')
  assert.strictEqual(nextSurface.data, previousData)
  assert.equal(nextSurface.reloads, 0)
})

test('manual_waiter_failure_clears_refreshing_and_keeps_previous_data', () => {
  const previousData = Object.freeze({ cards: ['existing-card'], sourceTimestamp: '2026-07-10T00:00:00Z' })
  const failed = settleRefreshFailure(
    {
      data: previousData,
      loading: false,
      refreshing: true,
      error: null,
    },
    new Error('coordinator ticket failed'),
  )

  assert.strictEqual(failed.data, previousData)
  assert.equal(failed.loading, false)
  assert.equal(failed.refreshing, false)
  assert.equal(failed.error, null, 'existing cards should remain the display state instead of an error replacement')

  const firstLoadFailure = settleRefreshFailure(
    {
      data: null,
      loading: true,
      refreshing: false,
      error: null,
    },
    new Error('initial snapshot failed'),
  )
  assert.match(firstLoadFailure.error ?? '', /initial snapshot failed/)
})

test('frontend_refresh_sources_are_event_driven_without_automatic_polling', () => {
  assert.doesNotMatch(appSource, /setInterval/)
  assert.doesNotMatch(popupSource, /setInterval/)
  assert.doesNotMatch(appSource, /refreshBackgroundData/)
  assert.doesNotMatch(apiSource, /refreshBackgroundData/)
  assert.doesNotMatch(dataFreshnessSource, /refreshDashboardAfterBackgroundScan/)
  assert.doesNotMatch(dataFreshnessSource, /waitForScanToSettleUntilCancelled/)
  assert.doesNotMatch(appSource, /getLiveRateLimits/)
  assert.doesNotMatch(appSource, /setLoadedQueryKey\(null\)/)

  assert.match(appSource, /codex-counter:\/\/refresh-completed/)
  assert.match(appSource, /SurfaceRevisionGate/)
  assert.match(appSource, /getCurrentWindow\(\)\.isVisible\(\)/)
  assert.match(appSource, /onFocusChanged/)
  assert.match(appSource, /visibilitychange/)

  assert.equal(
    popupSource.match(/codex-counter:\/\/menu-bar-popup-refresh/g)?.length,
    1,
    'Popup should have one dedicated refresh listener',
  )
  assert.match(
    popupSource,
    /listen\('codex-counter:\/\/menu-bar-popup-refresh'[\s\S]{0,220}loadSnapshot\(false\)/,
  )
  assert.doesNotMatch(popupSource, /codex-counter:\/\/refresh-completed/)
})

test('manual_rescan_waits_for_its_ticket_without_loading_dashboard_twice', () => {
  const handleRescan = appSource.match(/async function handleRescan\(\) \{([\s\S]*?)\n  \}/)?.[1]
  assert.ok(handleRescan, 'App should retain the manual rescan handler')
  assert.match(handleRescan, /scanCodexUsage/)
  assert.doesNotMatch(handleRescan, /loadShell|loadDashboard/)
  assert.match(handleRescan, /finally[\s\S]*setIsBusy\(false\)/)
})

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import * as refreshEvents from '../src/app/refreshEvents.ts'

const { settleRefreshFailure, SurfaceRevisionGate } = refreshEvents

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

function deferred() {
  let resolve
  const promise = new Promise((next) => {
    resolve = next
  })
  return { promise, resolve }
}

function extractFunction(source, signature) {
  const signatureStart = source.indexOf(signature)
  assert.notEqual(signatureStart, -1, `missing function: ${signature}`)
  const bodyStart = source.indexOf(') {', signatureStart) + 2
  assert.ok(bodyStart > 1, `missing function body: ${signature}`)
  let depth = 0
  for (let index = bodyStart; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1
    if (source[index] === '}') depth -= 1
    if (depth === 0) return source.slice(signatureStart, index + 1)
  }
  assert.fail(`unterminated function: ${signature}`)
}

function enclosingEffect(source, needle) {
  const needleIndex = source.indexOf(needle)
  assert.notEqual(needleIndex, -1, `missing effect content: ${needle}`)
  const layoutEffectIndex = source.lastIndexOf('useLayoutEffect(() => {', needleIndex)
  const passiveEffectIndex = source.lastIndexOf('useEffect(() => {', needleIndex)
  return layoutEffectIndex > passiveEffectIndex ? 'layout' : 'passive'
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
  assert.match(appSource, /appWindow\.isVisible\(\)/)
  assert.match(appSource, /appWindow\.isFocused\(\)/)
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
  const handleRescan = extractFunction(appSource, 'async function handleRescan()')
  assert.match(handleRescan, /scanCodexUsage/)
  assert.match(handleRescan, /finally[\s\S]*setIsBusy\(false\)/)
})

test('app_manual_reload_decisions_use_completion_only_when_listener_is_ready', () => {
  const manualDecision = refreshEvents.shouldLoadDashboardAfterManualRefresh
  const settingsDecision = refreshEvents.shouldLoadDashboardAfterSettingsSave

  assert.equal(typeof manualDecision, 'function')
  assert.equal(typeof settingsDecision, 'function')
  assert.equal(manualDecision(true), false, 'a registered listener owns the manual scan reload')
  assert.equal(manualDecision(false), true, 'a missing listener requires one post-ticket fallback')
  assert.equal(settingsDecision(true, true), false, 'a source change with a listener must not read twice')
  assert.equal(settingsDecision(true, false), true, 'a source change without a listener needs a fallback')
  assert.equal(settingsDecision(false, true), true, 'a normal settings save still needs an explicit read')
})

test('app_awaits_listener_readiness_and_does_not_bypass_hidden_source_change_defer', () => {
  const handleRescan = extractFunction(appSource, 'async function handleRescan()')
  const handleSaveSettings = extractFunction(appSource, 'async function handleSaveSettings(')
  const rescanReady = handleRescan.indexOf('await refreshCompletionListenerReadyRef.current')
  const rescanCommand = handleRescan.indexOf('scanCodexUsage(')
  const settingsReady = handleSaveSettings.indexOf('await refreshCompletionListenerReadyRef.current')
  const settingsSave = handleSaveSettings.indexOf('saveSettingsWithCodexHomeRollback(')

  assert.ok(rescanReady >= 0 && rescanReady < rescanCommand)
  assert.ok(settingsReady >= 0 && settingsReady < settingsSave)
  assert.match(
    handleRescan,
    /shouldLoadDashboardAfterManualRefresh\(listenerReady\)[\s\S]*await loadShellRef\.current\(true\)/,
  )
  assert.match(
    handleSaveSettings,
    /shouldLoadDashboardAfterSettingsSave\(saved\.codexHomeChanged, listenerReady\)[\s\S]*await loadShellRef\.current\(true\)/,
  )
  assert.doesNotMatch(handleRescan, /await loadShell\(true\)/)
  assert.doesNotMatch(handleSaveSettings, /await loadShell\(true\)/)
  assert.match(appSource, /const completionRegistration = listen<RefreshCompletedEvent>/)
  assert.match(
    appSource,
    /refreshCompletionListenerReadyRef\.current = completionRegistration[\s\S]*\.then\([\s\S]*return true[\s\S]*\.catch\([\s\S]*false/,
  )
})

test('app_commits_listener_readiness_and_latest_loader_before_browser_interaction', () => {
  assert.equal(
    enclosingEffect(appSource, 'loadShellRef.current = loadShell'),
    'layout',
    'query changes must update the latest loader before paint',
  )
  assert.equal(
    enclosingEffect(appSource, 'const completionRegistration = listen<RefreshCompletedEvent>'),
    'layout',
    'manual actions must see the real registration promise before paint',
  )
})

test('manual_fallback_after_a_pending_ticket_uses_the_latest_loader_once', async () => {
  const handleRescan = extractFunction(appSource, 'async function handleRescan()')
  assert.match(handleRescan, /await loadShellRef\.current\(true\)/)
  const ticket = deferred()
  const calls = []
  const loaderRef = {
    current: async (quiet) => {
      calls.push(['old query', quiet])
    },
  }
  const runManual = async () => {
    const listenerReady = await Promise.resolve(false)
    await ticket.promise
    if (refreshEvents.shouldLoadDashboardAfterManualRefresh(listenerReady)) {
      await loaderRef.current(true)
    }
  }

  const pending = runManual()
  loaderRef.current = async (quiet) => {
    calls.push(['latest query', quiet])
  }
  ticket.resolve()
  await pending

  assert.deepEqual(calls, [['latest query', true]])
})

test('surface_request_controller_ignores_an_older_response_that_finishes_last', async () => {
  const Controller = refreshEvents.SurfaceRequestController
  assert.equal(typeof Controller, 'function')
  const controller = new Controller()
  const older = deferred()
  const newer = deferred()
  let displayed = 'initial'

  const load = async (pending) => {
    const claim = controller.claim('passive')
    const value = await pending
    if (controller.isLatest(claim)) displayed = value
    controller.finish(claim)
  }
  const olderLoad = load(older.promise)
  const newerLoad = load(newer.promise)

  newer.resolve('newer snapshot')
  await newerLoad
  older.resolve('older snapshot')
  await olderLoad

  assert.equal(displayed, 'newer snapshot')
})

test('surface_request_controller_keeps_manual_spinner_single_flight_and_independent', async () => {
  const Controller = refreshEvents.SurfaceRequestController
  assert.equal(typeof Controller, 'function')
  const controller = new Controller()
  const manual = deferred()
  const passive = deferred()
  let displayed = 'existing snapshot'
  let refreshing = false

  const load = async (kind, pending) => {
    const claim = controller.claim(kind)
    if (claim === null) return false
    refreshing = controller.manualInFlight
    try {
      const value = await pending
      if (controller.isLatest(claim)) displayed = value
    } finally {
      controller.finish(claim)
      refreshing = controller.manualInFlight
    }
    return true
  }

  const manualLoad = load('manual', manual.promise)
  await Promise.resolve()
  assert.equal(refreshing, true)
  assert.equal(controller.claim('manual'), null, 'a second manual request must be rejected synchronously')

  const passiveLoad = load('passive', passive.promise)
  passive.resolve('newer passive snapshot')
  await passiveLoad
  assert.equal(displayed, 'newer passive snapshot')
  assert.equal(refreshing, true, 'a passive completion must not clear a manual spinner')

  manual.resolve('older forced snapshot')
  await manualLoad
  assert.equal(displayed, 'newer passive snapshot')
  assert.equal(refreshing, false)
})

test('popup_wires_latest_request_controller_and_disables_duplicate_manual_refresh', () => {
  assert.match(popupSource, /useRef\(new SurfaceRequestController\(\)\)/)
  assert.match(popupSource, /\.claim\(forceRefresh \? 'manual' : 'passive'\)/)
  assert.match(popupSource, /\.isLatest\(claim\)/)
  assert.match(popupSource, /\.finish\(claim\)/)
  assert.match(
    popupSource,
    /aria-label=\{t\.popup\.actions\.refresh\}[\s\S]{0,220}disabled=\{refreshing\}/,
  )
})

test('dashboard_startup_does_not_open_and_parse_the_first_conversation_implicitly', () => {
  assert.equal(refreshEvents.selectionAfterDashboardReload(null, null, 'seven-day-query'), null)
  assert.doesNotMatch(
    appSource,
    /setSelectedRootSessionId\([\s\S]{0,320}conversationPage\.items\[0\]/,
  )
})

test('conversation_entry_load_does_not_repeat_for_query_changes', () => {
  assert.match(
    appSource,
    /if \(!hasBootstrapped \|\| view !== 'conversations'\) return\s+void loadShellRef\.current\(false\)\s+}, \[hasBootstrapped, view\]\)/,
  )
  assert.doesNotMatch(
    appSource,
    /if \(!hasBootstrapped \|\| view !== 'conversations'\) return\s+void loadShell\(false\)/,
  )
})

test('dashboard_reload_preserves_a_later-page_selection_for_the_same_query', () => {
  assert.equal(
    refreshEvents.selectionAfterDashboardReload('root-page-2', 'seven-day-query', 'seven-day-query'),
    'root-page-2',
  )
  assert.equal(
    refreshEvents.selectionAfterDashboardReload('root-page-2', 'seven-day-query', 'month-query'),
    null,
  )
})

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  closeSettingsPanelIfIdle,
  saveSettingsWithCodexHomeRollback,
} from '../src/app/settingsSave.ts'

const previousSyncSettings = { codexHome: '/tmp/codex-home-a', interval: 5 }
const nextSyncSettings = { codexHome: '/tmp/missing-codex-home', interval: 10 }
const previousSubscriptionProfile = { planType: 'plus', monthlyPrice: 20 }
const nextSubscriptionProfile = { planType: 'pro', monthlyPrice: 200 }

let storedSyncSettings = previousSyncSettings
let storedSubscriptionProfile = previousSubscriptionProfile
const calls = []

await assert.rejects(
  saveSettingsWithCodexHomeRollback({
    previousSyncSettings,
    nextSyncSettings,
    previousSubscriptionProfile,
    nextSubscriptionProfile,
    updateSyncSettings: async (settings) => {
      calls.push(`sync:${settings.codexHome}`)
      storedSyncSettings = settings
      return settings
    },
    updateSubscriptionProfile: async (profile) => {
      calls.push(`profile:${profile.planType}`)
      storedSubscriptionProfile = profile
      return profile
    },
    scanCodexHome: async (codexHome) => {
      calls.push(`scan:${codexHome}`)
      if (codexHome === nextSyncSettings.codexHome) {
        throw new Error(`Codex home is not an existing directory: ${codexHome}`)
      }
    },
  }),
  /not an existing directory/,
  'an invalid Codex home should reject the settings save',
)

assert.deepEqual(
  storedSyncSettings,
  previousSyncSettings,
  'an invalid Codex home should restore the previously persisted sync settings',
)
assert.deepEqual(
  storedSubscriptionProfile,
  previousSubscriptionProfile,
  'a failed settings save should restore the previous subscription profile',
)
assert.deepEqual(
  calls,
  [
    'sync:/tmp/missing-codex-home',
    'profile:pro',
    'scan:/tmp/missing-codex-home',
    'sync:/tmp/codex-home-a',
    'profile:plus',
    'scan:/tmp/codex-home-a',
  ],
  'an invalid source should restore both settings and rescan the restored source for freshness',
)

calls.length = 0
const validResult = await saveSettingsWithCodexHomeRollback({
  previousSyncSettings,
  nextSyncSettings: { ...nextSyncSettings, codexHome: '/tmp/codex-home-b' },
  previousSubscriptionProfile,
  nextSubscriptionProfile,
  updateSyncSettings: async (settings) => {
    calls.push(`sync:${settings.codexHome}`)
    return settings
  },
  updateSubscriptionProfile: async (profile) => {
    calls.push(`profile:${profile.planType}`)
    return profile
  },
  scanCodexHome: async (codexHome) => {
    calls.push(`scan:${codexHome}`)
  },
})

assert.equal(validResult.codexHomeChanged, true)
assert.equal(validResult.syncSettings.codexHome, '/tmp/codex-home-b')
assert.deepEqual(
  calls,
  ['sync:/tmp/codex-home-b', 'profile:pro', 'scan:/tmp/codex-home-b'],
  'a valid source change should be scanned after persistence so it is authoritative',
)

calls.length = 0
const unchangedResult = await saveSettingsWithCodexHomeRollback({
  previousSyncSettings,
  nextSyncSettings: { ...previousSyncSettings, interval: 15 },
  previousSubscriptionProfile,
  nextSubscriptionProfile,
  updateSyncSettings: async (settings) => {
    calls.push(`sync:${settings.codexHome}`)
    return settings
  },
  updateSubscriptionProfile: async (profile) => {
    calls.push(`profile:${profile.planType}`)
    return profile
  },
  scanCodexHome: async () => {
    calls.push('unexpected-scan')
  },
})

assert.equal(unchangedResult.codexHomeChanged, false)
assert.deepEqual(
  calls,
  ['sync:/tmp/codex-home-a', 'profile:pro'],
  'saving unrelated settings should not trigger a Codex home scan',
)

calls.length = 0
storedSubscriptionProfile = previousSubscriptionProfile
storedSyncSettings = previousSyncSettings
await assert.rejects(
  saveSettingsWithCodexHomeRollback({
    previousSyncSettings,
    nextSyncSettings: { ...previousSyncSettings, interval: 30 },
    previousSubscriptionProfile,
    nextSubscriptionProfile,
    updateSyncSettings: async (settings) => {
      calls.push(`sync:${settings.interval}`)
      storedSyncSettings = settings
      return settings
    },
    updateSubscriptionProfile: async () => {
      calls.push('profile:failed')
      throw new Error('profile save failed')
    },
    scanCodexHome: async () => {
      calls.push('unexpected-scan')
    },
  }),
  /profile save failed/,
)
assert.deepEqual(storedSyncSettings, previousSyncSettings)
assert.deepEqual(storedSubscriptionProfile, previousSubscriptionProfile)
assert.deepEqual(
  calls,
  ['sync:30', 'profile:failed', 'sync:5'],
  'a later persistence failure should restore sync settings saved earlier in the operation',
)

let closeCount = 0
assert.equal(closeSettingsPanelIfIdle(true, () => (closeCount += 1)), false)
assert.equal(closeCount, 0, 'the settings modal should stay open while validation is pending')
assert.equal(closeSettingsPanelIfIdle(false, () => (closeCount += 1)), true)
assert.equal(closeCount, 1, 'the settings modal should close normally while idle')

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const appSource = readFileSync(join(repoRoot, 'src/App.tsx'), 'utf8')
const panelSource = readFileSync(join(repoRoot, 'src/components/SettingsPanel.tsx'), 'utf8')
const i18nSource = readFileSync(join(repoRoot, 'src/app/i18n.ts'), 'utf8')
const packageMetadata = JSON.parse(readFileSync(join(repoRoot, 'package.json'), 'utf8'))
const readmeSource = readFileSync(join(repoRoot, 'README.md'), 'utf8')
const chineseReadmeSource = readFileSync(join(repoRoot, 'README.zh-CN.md'), 'utf8')
const englishGettingStarted = readFileSync(join(repoRoot, 'docs/en/getting-started.md'), 'utf8')
const chineseGettingStarted = readFileSync(join(repoRoot, 'docs/zh-CN/getting-started.md'), 'utf8')

assert.match(
  appSource,
  /saveSettingsWithCodexHomeRollback\([\s\S]*scanCodexHome:[\s\S]*runScanWithOverlapRetry/,
  'settings save should validate the persisted Codex home through a tracked scan that can reject',
)
assert.doesNotMatch(
  appSource,
  /await loadShell\(codexHomeChanged\)/,
  'settings save should not rely on loadShell, which handles dashboard errors internally, to validate a source',
)
assert.match(
  panelSource,
  /catch \(error\)[\s\S]*setSaveError\(t\.status\.settingsSaveFailed\(String\(error\)\)\)/,
  'the settings panel should keep the modal open and show save failures',
)
assert.match(
  panelSource,
  /const handleClose = \(\) => closeSettingsPanelIfIdle\(saving, onClose\)/,
  'all settings close paths should share the saving guard',
)
assert.match(
  panelSource,
  /modal-backdrop" onClick=\{handleClose\}[\s\S]*disabled=\{saving\}[\s\S]*onClick=\{handleClose\}[\s\S]*disabled=\{saving\}[\s\S]*onClick=\{handleClose\}/,
  'backdrop, Close, and Cancel should keep the modal open while a save is pending',
)
assert.match(
  panelSource,
  /className="settings-save-error" role="alert"/,
  'settings save failures should be exposed as an accessible inline alert',
)
assert.match(i18nSource, /settingsSaveFailed: \(error: string\) => string/)
assert.match(i18nSource, /settingsSaveFailed: \(error\) => `设置未保存：\$\{error\}`/)
assert.match(i18nSource, /settingsSaveFailed: \(error\) => `Settings were not saved: \$\{error\}`/)
assert.equal(
  packageMetadata.engines?.node,
  '>=22.18.0',
  'package metadata should enforce the Node runtime required for direct TypeScript test imports',
)
assert.match(packageMetadata.scripts['test:data-freshness'], /node --experimental-strip-types /)
assert.match(packageMetadata.scripts['test:settings-save'], /node --experimental-strip-types /)
for (const [label, source] of [
  ['README', readmeSource],
  ['Chinese README', chineseReadmeSource],
  ['English getting started guide', englishGettingStarted],
  ['Chinese getting started guide', chineseGettingStarted],
]) {
  assert.match(source, /Node\.js 22\.18\+/, `${label} should document the Node 22.18 minimum`)
  assert.doesNotMatch(source, /Node\.js 20\+/, `${label} should not advertise an incompatible Node 20 runtime`)
}

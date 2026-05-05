import { readFileSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import assert from 'node:assert/strict'
import ts from 'typescript'

const repoRoot = join(import.meta.dirname, '..')
const sourcePath = join(repoRoot, 'src/app/subscriptionDates.ts')
const source = readFileSync(sourcePath, 'utf8')
const output = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ES2022,
    target: ts.ScriptTarget.ES2022,
  },
}).outputText

const tempDir = mkdtempSync(join(tmpdir(), 'codex-pacer-subscription-dates-'))
const modulePath = join(tempDir, 'subscriptionDates.mjs')
writeFileSync(modulePath, output)

try {
  const { addOneCalendarMonth, todayLocalInputValue } = await import(pathToFileURL(modulePath))

  assert.equal(addOneCalendarMonth('2026-01-31'), '2026-02-28')
  assert.equal(addOneCalendarMonth('2028-01-31'), '2028-02-29')
  assert.equal(addOneCalendarMonth('2026-03-31'), '2026-04-30')
  assert.equal(addOneCalendarMonth('2026-12-31'), '2027-01-31')
  assert.equal(addOneCalendarMonth('not-a-date'), 'not-a-date')

  const singaporeLateNight = new Date('2026-05-05T00:30:00+08:00')
  assert.equal(
    todayLocalInputValue(singaporeLateNight),
    '2026-05-05',
    'ledger defaults should use local calendar date, not UTC ISO date',
  )
} finally {
  rmSync(tempDir, { recursive: true, force: true })
}

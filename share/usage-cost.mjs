// Sums the token usage of the local DeepSeek Harness (dsh) sessions for the current month,
// grouped by model family, for dsh-romeo --usage (bash prices the result).
// Source: one persisted projection record per session, in
// <DSH_HOME>/storages/session_projcache/sessions/*.json, where record.rows.modelSelection.val
// .lastUsed names the model and record.rows.tokenUsage.val(.totals) holds the four buckets.
// A record counts when lastUsed.provider is romeo and its lastPromptAt (else identity.createdAt)
// is at or after SINCE_MS. Output, one line per family sorted by name, nothing else on stdout:
//   family<TAB>model<TAB>uncachedInputTokens<TAB>cacheReadTokens<TAB>cacheWriteTokens<TAB>outputTokens
// Usage: node share/usage-cost.mjs <DSH_HOME> <SINCE_MS>
// Only Node built-ins, so it resolves from any directory.

import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const BUCKETS = ['uncachedInputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'outputTokens']
const SESSIONS = join('storages', 'session_projcache', 'sessions')

function bucket(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.round(value) : 0
}

function whenOf(record) {
  const lastPromptAt = record?.rows?.sessionListMetadata?.val?.lastPromptAt
  if (typeof lastPromptAt === 'number' && Number.isFinite(lastPromptAt)) return lastPromptAt
  const createdAt = record?.identity?.createdAt
  return typeof createdAt === 'number' && Number.isFinite(createdAt) ? createdAt : null
}

function tokensOf(record) {
  const val = record?.rows?.tokenUsage?.val
  if (val === null || typeof val !== 'object') return null
  const totals = val.totals !== null && typeof val.totals === 'object' ? val.totals : val
  const counts = BUCKETS.map((key) => bucket(totals[key]))
  return counts.some((count) => count > 0) ? counts : null
}

function main() {
  const [home, sinceArg] = process.argv.slice(2)
  const since = Number(sinceArg)
  if (!home || typeof sinceArg !== 'string' || sinceArg.trim() === '' || !Number.isFinite(since)) {
    console.error('usage: node share/usage-cost.mjs <DSH_HOME> <SINCE_MS>')
    process.exit(2)
  }

  let names
  try {
    names = readdirSync(join(home, SESSIONS)).filter((name) => name.endsWith('.json')).sort()
  } catch {
    return
  }

  const families = new Map()
  for (const name of names) {
    let record
    try {
      record = JSON.parse(readFileSync(join(home, SESSIONS, name), 'utf8'))?.record
    } catch {
      continue
    }
    const lastUsed = record?.rows?.modelSelection?.val?.lastUsed
    if (lastUsed?.provider !== 'romeo') continue
    const model = lastUsed.model
    if (typeof model !== 'string' || model === '') continue
    const at = whenOf(record)
    if (at === null || at < since) continue
    const counts = tokensOf(record)
    if (counts === null) continue
    const family = /kimi/i.test(model) ? 'kimi' : 'deepseek'
    const total = families.get(family)
    if (total === undefined) {
      families.set(family, { model, counts })
    } else {
      for (let i = 0; i < counts.length; i += 1) total.counts[i] += counts[i]
    }
  }

  const lines = [...families.keys()].sort().map((family) => {
    const { model, counts } = families.get(family)
    return [family, model, ...counts].join('\t')
  })
  if (lines.length > 0) process.stdout.write(lines.join('\n') + '\n')
}

main()

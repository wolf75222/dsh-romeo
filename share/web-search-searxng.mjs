// DeepSeek Harness (dsh) Cordis plugin: a SearXNG search provider for ctx.web.
// Registers the search provider `providerId` (default "searxng"); dsh-romeo selects it with
//   - id: web
//     config: { searchProvider: dsh-romeo-searxng, fetchProvider: http }
// No imports, so it resolves from any directory (no @deepseek-ai/* lookup needed).
// baseURL may list several SearXNG instances separated by ";" (tried in order).

export const name = 'dsh-romeo-searxng'
export const inject = ['web']

const DEFAULTS = {
  providerId: 'searxng',
  baseURL: process.env.SEARXNG_URL || 'http://127.0.0.1:8888',
  timeoutMs: 20000,
  language: 'auto',
  safesearch: 0,
  categories: 'general',
  engines: '',
}

const instances = (raw) => String(raw ?? '').split(';').map((s) => s.trim()).filter((s) => URL.canParse(s))

function signalFor(signal, timeoutMs) {
  const timeout = AbortSignal.timeout(timeoutMs)
  return signal ? AbortSignal.any([signal, timeout]) : timeout
}

async function searchOne(base, opts, request, signal) {
  const url = new URL('search', base.replace(/\/*$/u, '/'))
  url.searchParams.set('q', request.query)
  url.searchParams.set('format', 'json')
  url.searchParams.set('language', String(opts.language))
  url.searchParams.set('safesearch', String(opts.safesearch))
  if (opts.categories) url.searchParams.set('categories', String(opts.categories))
  if (opts.engines) url.searchParams.set('engines', String(opts.engines))
  const response = await fetch(url, {
    headers: { accept: 'application/json' },
    redirect: 'error',
    signal: signalFor(signal, opts.timeoutMs),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status} (is its JSON format on? SearXNG: format=json in settings.yml)`)
  const data = await response.json()
  const seen = new Set()
  const sources = []
  for (const r of Array.isArray(data.results) ? data.results : []) {
    if (typeof r?.url !== 'string' || r.url.length === 0 || seen.has(r.url)) continue
    seen.add(r.url)
    sources.push({
      url: r.url,
      ...(typeof r.title === 'string' && r.title ? { title: r.title } : {}),
      ...(typeof r.content === 'string' && r.content ? { snippet: r.content } : {}),
      ...(r.publishedDate ? { publishedAt: String(r.publishedDate) } : {}),
    })
  }
  if (sources.length === 0 && Array.isArray(data.unresponsive_engines) && data.unresponsive_engines.length > 0) {
    const engines = data.unresponsive_engines.map((e) => (Array.isArray(e) ? e.join(': ') : String(e))).join(', ')
    throw new Error(`no results; unresponsive engines: ${engines}`)
  }
  return { sources, truncated: false }
}

export function apply(ctx, config) {
  const opts = { ...DEFAULTS, ...(config ?? {}) }
  ctx.web.registerSearchProvider({
    id: opts.providerId,
    available: () => instances(opts.baseURL).length > 0,
    async search(request, signal) {
      const failures = []
      for (const base of instances(opts.baseURL)) {
        try {
          return await searchOne(base, opts, request, signal)
        } catch (error) {
          if (signal?.aborted) throw error
          failures.push(`${new URL(base).origin}: ${error instanceof Error ? error.message : String(error)}`)
        }
      }
      throw new Error(`SearXNG search failed (${failures.join('; ')}). Retry or rephrase the query.`)
    },
  })
}

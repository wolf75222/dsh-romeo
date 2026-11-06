// DeepSeek Harness (dsh) Cordis plugin: web search through RustXNG on the ROMEO login node
// (dsh-romeo --web on). Each search runs `rustxng mcp` over dsh-romeo's shared SSH connection
// and calls its "search" tool: nothing listens on a port of the login node, which other ROMEO
// users share, and the queries leave from ROMEO, not from this computer.
// Selected by dsh-romeo with
//   - id: web
//     config: { searchProvider: dsh-romeo-rustxng, fetchProvider: http }
// Only node: built-ins, so it resolves from any directory.

import { spawn } from 'node:child_process'

export const name = 'dsh-romeo-rustxng'
export const inject = ['web']

const DEFAULTS = {
  providerId: 'dsh-romeo-rustxng',
  ssh: 'ssh',
  host: 'romeo',
  socket: '',        // dsh-romeo's control socket: never a new login that could ask for a password
  binary: '',        // the RustXNG binary on ROMEO
  timeoutMs: 30000,
  limit: 10,         // RustXNG returns 1 to 10 results per call
}

const fail = (message) => new Error(`web search on ROMEO: ${message}`)

function mcpSearch(opts, args, signal) {
  return new Promise((resolve, reject) => {
    const sshArgs = ['-o', 'BatchMode=yes', '-o', 'ControlMaster=no']
    if (opts.socket) sshArgs.push('-S', String(opts.socket))
    sshArgs.push(String(opts.host), `${opts.binary} mcp`)
    const child = spawn(String(opts.ssh), sshArgs, { stdio: ['pipe', 'pipe', 'pipe'] })
    let out = ''
    let err = ''
    let done = false
    const finish = (error, value) => {
      if (done) return
      done = true
      clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
      child.kill()
      if (error) reject(error)
      else resolve(value)
    }
    const onAbort = () => finish(signal.reason ?? new Error('aborted'))
    if (signal?.aborted) return finish(signal.reason ?? new Error('aborted'))
    signal?.addEventListener('abort', onAbort, { once: true })
    const timer = setTimeout(() => finish(fail(`no answer within ${opts.timeoutMs / 1000} s`)), opts.timeoutMs)
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk) => {
      out += chunk
      let i
      while ((i = out.indexOf('\n')) >= 0) {
        const line = out.slice(0, i)
        out = out.slice(i + 1)
        let msg
        try { msg = JSON.parse(line) } catch { continue }
        if (msg.id !== 2) continue
        if (msg.error) return finish(fail(msg.error.message ?? 'error'))
        const text = msg.result?.content?.find?.((c) => c?.type === 'text')?.text
        if (msg.result?.isError) return finish(fail(text ?? 'error'))
        let data = msg.result?.structuredContent
        if (!data) { try { data = JSON.parse(text ?? '{}') } catch { data = {} } }
        return finish(null, data)
      }
    })
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => { err += chunk })
    child.on('error', (error) => finish(fail(`cannot run ${opts.ssh}: ${error.message}`)))
    child.on('close', (code) => {
      const last = err.split('\n').map((s) => s.trim()).filter((s) => s && !/post-quantum|store now|openssh\.com\/pq|^\*\*/u.test(s)).pop()
      if (code === 255) finish(fail('the SSH connection to ROMEO is closed (sleep or network change): run dsh-romeo again'))
      else if (code === 127) finish(fail('RustXNG is not installed on ROMEO: run dsh-romeo --web on again'))
      else finish(fail(`RustXNG exited (${code}): ${last ?? 'no message'}`))
    })
    child.stdin.on('error', () => {})
    const send = (o) => child.stdin.write(`${JSON.stringify(o)}\n`)
    send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'dsh-romeo', version: '1' } } })
    send({ jsonrpc: '2.0', method: 'notifications/initialized' })
    send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'search', arguments: args } })
  })
}

export function apply(ctx, config) {
  const opts = { ...DEFAULTS, ...(config ?? {}) }
  ctx.web.registerSearchProvider({
    id: opts.providerId,
    available: () => Boolean(opts.binary),
    async search(request, signal) {
      const wanted = Number(request?.maxResults ?? request?.limit ?? opts.limit)
      const limit = Math.max(1, Math.min(10, Number.isFinite(wanted) ? wanted : opts.limit))
      const data = await mcpSearch(opts, { query: String(request.query), limit }, signal)
      const seen = new Set()
      const sources = []
      for (const r of Array.isArray(data.results) ? data.results : []) {
        if (typeof r?.url !== 'string' || r.url.length === 0 || seen.has(r.url)) continue
        seen.add(r.url)
        sources.push({
          url: r.url,
          ...(typeof r.title === 'string' && r.title ? { title: r.title } : {}),
          ...(typeof r.snippet === 'string' && r.snippet ? { snippet: r.snippet } : {}),
        })
      }
      if (sources.length === 0 && Array.isArray(data.unresponsive_engines) && data.unresponsive_engines.length > 0) {
        const engines = data.unresponsive_engines.map((e) => (Array.isArray(e) ? e.join(': ') : String(e))).join(', ')
        throw fail(`no results; unresponsive engines: ${engines}. Retry or rephrase the query.`)
      }
      return { sources, truncated: Boolean(data.truncated) }
    },
  })
}

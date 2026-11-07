// dsh-romeo-status, the host side: GET /dsh-romeo-status -> { items: [{ level, text }] }, what the
// badge beside dsh's input box shows. It reads what dsh-romeo wrote when it started
// (~/.config/dsh-romeo/status.json: the SSH host and control socket, the models, their loading
// times, the idle stop) and asks ROMEO over that same SSH connection, never a new login: the
// model jobs (squeue), dsh-romeo's watcher log, the time of the last request. At most once every
// 20 s, and only while a dsh window asks.
import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { describe } from './describe.mjs'

export const name = 'dsh-romeo-status'
export const inject = ['webServer', 'connection']

const statusFile = () => join(process.env.DSH_ROMEO_CONFIG_DIR || join(homedir(), '.config', 'dsh-romeo'), 'status.json')

function readStatus() {
  try { return JSON.parse(readFileSync(statusFile(), 'utf8')) } catch { return null }
}

// One round trip: the jobs, the watcher's last lines, the last request.
function askRomeo(st) {
  const names = st.models.map((m) => `romeollmtool-${m.fiche}`).join(',')
  const script = `squeue -u "$USER" -h -n '${names}' -o '%i %j %T %M %L %S' 2>/dev/null; echo --; tail -n 20 ~/.dsh-romeo/watch.log 2>/dev/null; echo --; f=$(ls -t ~/.romeollmtool/stats/requests-*.jsonl 2>/dev/null | head -1); [ -z "$f" ] || stat -c %Y "$f"; date +%s`
  return new Promise((resolve) => {
    const args = ['-o', 'BatchMode=yes', '-o', 'ControlMaster=no', '-o', 'ConnectTimeout=8']
    if (st.socket) args.push('-S', st.socket)
    args.push(st.host, script)
    let out = ''
    const child = spawn('ssh', args, { stdio: ['ignore', 'pipe', 'ignore'] })
    const timer = setTimeout(() => child.kill(), 15000)
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (c) => { out += c })
    child.on('error', () => { clearTimeout(timer); resolve(null) })
    child.on('close', (code) => { clearTimeout(timer); resolve(code === 0 ? out : null) })
  })
}

export function apply(ctx) {
  let cache = { at: 0, lang: '', value: null }
  let pending = null
  const route = {
    kind: 'prefix',
    path: '/dsh-romeo-status',
    handler: async (req, res) => {
      let rejection = 403
      try { rejection = ctx.connection?.requestRejection?.(req) } catch { rejection = 403 }
      const send = (status, value) => {
        const body = JSON.stringify(value)
        res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
        res.end(body)
      }
      if (rejection !== undefined) return send(rejection, { items: [] })
      const lang = String(req.headers['x-dsh-locale'] || 'en').toLowerCase().startsWith('fr') ? 'fr' : 'en'
      const now = Date.now()
      if (cache.value && now - cache.at < 20000 && cache.lang === lang) return send(200, cache.value)
      const st = readStatus()
      if (!st?.host || !Array.isArray(st.models) || st.models.length === 0) return send(200, { items: [] })
      pending ??= askRomeo(st).finally(() => { pending = null })
      const out = await pending
      const value = { items: describe(st, out, lang) }
      cache = { at: Date.now(), lang, value }
      send(200, value)
    },
  }
  const dispose = ctx.webServer.register(route)
  ctx.effect?.(() => () => { try { dispose?.() } catch {} }, 'dsh-romeo-status: unregister HTTP route')
}

// What the badge says, from dsh-romeo's status.json (st) and the answer of ROMEO (out: squeue's
// "id name state elapsed left start" lines, "--", dsh-romeo's watcher log, "--", the time of the
// last request, then ROMEO's time). Pure, for the tests. Only what needs the user: a model loading
// or queued, a job ending soon and whether the next one comes, a job gone, the idle stop near.
// [{ level: 'info' | 'warn' | 'error', text }], in French or English.

const T = {
  en: {
    unreachable: 'ROMEO does not answer: the SSH connection closed? Run dsh-romeo again',
    gone: (m) => `${m}: no job on ROMEO, dsh-romeo --launch`,
    idled: (n) => `jobs stopped after ${n} min without requests: dsh-romeo --launch`,
    queued: (m, at) => `${m} waiting for GPUs${at ? `, starts ~${at}` : ''}`,
    loading: (m, n) => `${m} loading${n > 0 ? `, ~${n} min` : ''}`,
    ends: (m, n) => `${m} ends in ${n} min`,
    next: 'the next job is coming',
    noRelay: 'no relay (GPU limit): dsh-romeo --launch after it',
    relayOff: 'dsh-romeo --launch to go on',
    idle: (n) => `jobs stop in ${n} min without requests`,
  },
  fr: {
    unreachable: 'ROMEO ne répond pas : connexion SSH fermée ? Relancez dsh-romeo',
    gone: (m) => `${m} : aucun job sur ROMEO, dsh-romeo --launch`,
    idled: (n) => `jobs arrêtés après ${n} min sans requête : dsh-romeo --launch`,
    queued: (m, at) => `${m} attend des GPU${at ? `, départ ~${at}` : ''}`,
    loading: (m, n) => `${m} se charge${n > 0 ? `, ~${n} min` : ''}`,
    ends: (m, n) => `${m} s'arrête dans ${n} min`,
    next: 'le job suivant arrive',
    noRelay: 'pas de relais (limite de GPU) : dsh-romeo --launch ensuite',
    relayOff: 'dsh-romeo --launch pour continuer',
    idle: (n) => `les jobs s'arrêtent dans ${n} min sans requête`,
  },
}

export function minutes(t) {  // a Slurm duration ([D-]H:MM:SS, MM:SS) in minutes
  if (!t || t === 'INVALID' || t === 'UNLIMITED') return 0
  let d = 0
  let rest = t
  if (rest.includes('-')) { d = Number(rest.split('-')[0]); rest = rest.split('-')[1] }
  const p = rest.split(':').map(Number)
  const [a, b] = p.length === 3 ? [p[0], p[1]] : p.length === 2 ? [0, p[0]] : [0, 0]
  return d * 1440 + a * 60 + b
}

export function describe(st, out, lang = 'en') {
  const t = T[lang] ?? T.en
  if (out == null) return [{ level: 'error', text: t.unreachable }]
  const [jobsPart = '', logPart = '', timePart = ''] = out.split(/^--$/m)
  const times = timePart.trim().split(/\s+/).filter(Boolean).map(Number)
  const now = times.at(-1) || Math.floor(Date.now() / 1000)
  const lastRequest = times.length > 1 ? times[0] : 0
  const jobs = jobsPart.trim().split('\n').filter((l) => /^\d/.test(l)).map((l) => {
    const [id, name, state, elapsed, left, start] = l.trim().split(/\s+/)
    return { id, fiche: name.replace(/^romeollmtool-/, ''), state, elapsed: minutes(elapsed), left: minutes(left), start }
  })
  const log = logPart.trim().split('\n').filter(Boolean).map((l) => l.split(' '))
  const items = []
  const lastStop = log.filter((l) => l[1] === 'stopped').at(-1)
  let newestStart = 0
  for (const m of st.models) {
    const mine = jobs.filter((j) => j.fiche === m.fiche)
    const name = m.short || m.label || m.fiche
    if (mine.length === 0) {
      if (lastStop && now - Number(lastStop[0]) < 3 * 3600) continue  // said once below
      items.push({ level: 'error', text: t.gone(name) })
      continue
    }
    const running = mine.filter((j) => j.state === 'RUNNING').sort((a, b) => b.left - a.left)
    if (running.length === 0) {
      const at = /T(\d\d:\d\d)/.exec(mine[0].start ?? '')?.[1]
      items.push({ level: 'warn', text: t.queued(name, at) })
      continue
    }
    const best = running[0]
    newestStart = Math.max(newestStart, now - best.elapsed * 60)
    const loadMin = Math.round((Number(m.load) || 0) / 60)
    if (best.elapsed < loadMin) { items.push({ level: 'info', text: t.loading(name, loadMin - best.elapsed) }); continue }
    if (best.left < 30) {
      const other = mine.some((j) => j.id !== best.id && (j.state === 'PENDING' || j.left > best.left))
      const refused = log.some((l) => l[1] === 'no-relay' && l[2] === m.fiche && l[3] === best.id)
      const tail = other ? t.next : refused ? t.noRelay : st.relay === 'on' ? '' : t.relayOff
      items.push({ level: 'warn', text: t.ends(name, best.left) + (tail ? ` · ${tail}` : '') })
    }
  }
  if (jobs.length === 0 && lastStop && now - Number(lastStop[0]) < 3 * 3600) {
    items.push({ level: 'info', text: t.idled(lastStop.at(-1)) })
  }
  const idle = Number(st.idle)
  if (Number.isFinite(idle) && idle > 0 && jobs.some((j) => j.state === 'RUNNING')) {
    const quiet = now - Math.max(lastRequest, newestStart, Number(st.started) || 0)
    const left = Math.ceil((idle * 60 - quiet) / 60)
    if (left > 0 && left <= 10) items.push({ level: 'info', text: t.idle(left) })
  }
  return items
}

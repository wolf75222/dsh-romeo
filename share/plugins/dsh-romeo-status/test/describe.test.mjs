// node share/plugins/dsh-romeo-status/test/describe.test.mjs: what the badge says.
import assert from 'node:assert/strict'
import { describe, minutes } from '../lib/describe.mjs'

const st = { host: 'romeo', models: [{ fiche: 'k', short: 'Kimi', load: 840 }, { fiche: 'd', short: 'DeepSeek', load: 480 }], idle: 60, relay: 'on' }
const now = 1794086000
const texts = (out, lang = 'en', s = st) => describe(s, out, lang).map((i) => `${i.level}: ${i.text}`)
let n = 0
const eq = (a, b) => { assert.deepEqual(a, b); n++ }

eq(minutes('7:59:18'), 479); eq(minutes('20:00'), 20); eq(minutes('1-02:00:00'), 1560); eq(minutes('N/A'), 0)
eq(texts(null), ['error: ROMEO does not answer: the SSH connection closed? Run dsh-romeo again'])
// loading and queued
eq(texts(`1 romeollmtool-k RUNNING 5:00 7:55:00 x\n2 romeollmtool-d PENDING 0:00 8:00:00 2026-11-07T23:47:00\n--\n--\n${now}\n`, 'fr'),
  ['info: Kimi se charge, ~9 min', 'warn: DeepSeek attend des GPU, départ ~23:47'])
// all well: nothing
eq(texts(`1 romeollmtool-k RUNNING 1:00:00 7:00:00 x\n2 romeollmtool-d RUNNING 1:00:00 7:00:00 x\n--\n--\n${now - 60}\n${now}\n`), [])
// ending: the next job coming, refused, relay off
eq(texts(`1 romeollmtool-k RUNNING 7:40:00 20:00 x\n3 romeollmtool-d RUNNING 7:40:00 20:00 x\n4 romeollmtool-d PENDING 0:00 8:00:00 N/A\n--\n${now} no-relay k 1 over\n--\n${now}\n`),
  ['warn: Kimi ends in 20 min · no relay (GPU limit): dsh-romeo --launch after it', 'warn: DeepSeek ends in 20 min · the next job is coming'])
eq(texts(`1 romeollmtool-k RUNNING 7:40:00 20:00 x\n--\n--\n${now}\n`, 'en', { ...st, models: [st.models[0]], relay: 'off' }),
  ['warn: Kimi ends in 20 min · dsh-romeo --launch to go on'])
// a job gone, and the idle stop
eq(texts(`--\n--\n${now}\n`), ['error: Kimi: no job on ROMEO, dsh-romeo --launch', 'error: DeepSeek: no job on ROMEO, dsh-romeo --launch'])
eq(texts(`--\n${now - 100} stopped 1 2 idle 60\n--\n${now}\n`, 'fr'), ['info: jobs arrêtés après 60 min sans requête : dsh-romeo --launch'])
eq(texts(`1 romeollmtool-k RUNNING 3:00:00 5:00:00 x\n2 romeollmtool-d RUNNING 3:00:00 5:00:00 x\n--\n--\n${now - 55 * 60}\n${now}\n`),
  ['info: jobs stop in 5 min without requests'])
eq(texts(`1 romeollmtool-k RUNNING 3:00:00 5:00:00 x\n2 romeollmtool-d RUNNING 3:00:00 5:00:00 x\n--\n--\n${now - 55 * 60}\n${now}\n`, 'en', { ...st, idle: 'off' }), [])
console.log(`dsh-romeo-status: ${n} passed`)

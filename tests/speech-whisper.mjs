// The Whisper provider (share/speech-whisper-romeo.mjs) against a fake /v1/audio/transcriptions:
// node tests/speech-whisper.mjs prints "ok ..." lines, or "FAIL ..." and exits 1.
import { createServer } from 'node:http'
import { apply } from '../share/speech-whisper-romeo.mjs'

let seen
const server = createServer((req, res) => {
  const chunks = []
  req.on('data', (c) => chunks.push(c))
  req.on('end', () => {
    seen = { url: req.url, auth: req.headers.authorization, type: req.headers['content-type'], body: Buffer.concat(chunks).toString('latin1') }
    res.setHeader('content-type', 'application/json')
    res.end(JSON.stringify({ text: ' Bonjour ROMEO. ' }))
  })
}).listen(0)
await new Promise((r) => server.once('listening', r))
const port = server.address().port

let provider
const ctx = { speechToText: { register: (p) => { provider = p; return async () => {} } }, effect: (fn) => fn() }
process.env.ROMEO_LLM_KEY = 'test-key'
apply(ctx, { baseURL: `http://127.0.0.1:${port}/v1`, model: 'dsh-whisper-large-v3-turbo' })

let failed = 0
const check = (name, ok) => { console.log(`  ${ok ? 'ok  ' : 'FAIL'}  whisper provider: ${name}`); if (!ok) failed++ }
check('registered with its id', provider?.info?.id === 'dsh-romeo-whisper' && provider.info.languages.includes('fr'))
const wav = new Uint8Array(44 + 32000)  // one second of 16 kHz mono PCM16
const out = await provider.transcribe({ audio: wav, language: 'fr' }, AbortSignal.timeout(5000))
check('posts to /v1/audio/transcriptions', seen.url === '/v1/audio/transcriptions')
check('with the gateway key', seen.auth === 'Bearer test-key')
check('as multipart with the WAV file', seen.type.startsWith('multipart/form-data') && seen.body.includes('filename="recording.wav"'))
check('names the served model', seen.body.includes('dsh-whisper-large-v3-turbo'))
check('passes the language', /name="language"\r\n\r\nfr/.test(seen.body))
check('returns the trimmed text', out.text === 'Bonjour ROMEO.')
check('measures the audio', Math.abs(out.audioSeconds - 1) < 1e-9)
await provider.transcribe({ audio: wav, language: 'auto' }, AbortSignal.timeout(5000))
check('auto: lets Whisper detect the language', !seen.body.includes('name="language"'))
const { writeFileSync, mkdtempSync } = await import('node:fs')
const keyFile = mkdtempSync('/tmp/whisper-key-') + '/key'
writeFileSync(keyFile, 'key-from-file\n')
let fileProvider
apply({ speechToText: { register: (p) => { fileProvider = p; return async () => {} } }, effect: (fn) => fn() },
      { baseURL: `http://127.0.0.1:${port}/v1`, apiKeyFile: keyFile })
await fileProvider.transcribe({ audio: wav, language: 'fr' }, AbortSignal.timeout(5000))
check('reads the key from apiKeyFile at each recording', seen.auth === 'Bearer key-from-file')
writeFileSync(keyFile, 'new-job-key\n')
await fileProvider.transcribe({ audio: wav, language: 'fr' }, AbortSignal.timeout(5000))
check('picks up a key written later', seen.auth === 'Bearer new-job-key')
server.close()
process.exit(failed ? 1 : 0)

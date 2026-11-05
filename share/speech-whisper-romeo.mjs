// DeepSeek Harness (dsh) Cordis plugin: a speech-to-text provider for ctx.speechToText that sends
// each recording to Whisper on ROMEO, to the job's OpenAI-compatible /v1/audio/transcriptions
// (dsh-romeo forwards a local port to the job). dsh-romeo selects it with
//   - id: speech-to-text
//     config: { defaultProvider: dsh-romeo-whisper, language: auto }
// Only Node built-ins are imported, so it resolves from any directory (no @deepseek-ai/* lookup).
// The key is read at each recording from apiKeyFile (dsh-romeo writes it once the Whisper job runs,
// so a job that starts after dsh works too), else from the apiKeyEnv variable.
// The browser records 16 kHz mono PCM16 WAV, which Whisper takes as is.

import { readFileSync } from 'node:fs'

export const name = 'dsh-romeo-whisper'
export const inject = ['speechToText']

const DEFAULTS = {
  providerId: 'dsh-romeo-whisper',
  baseURL: 'http://127.0.0.1:11319/v1',
  apiKeyEnv: 'ROMEO_LLM_KEY',
  apiKeyFile: '',
  model: 'dsh-whisper-large-v3-turbo',
  timeoutMs: 120000,
}

// Whisper's languages that the voice UI offers, "auto" letting it detect the language.
const LANGUAGES = ['auto', 'fr', 'en', 'de', 'es', 'it', 'pt', 'nl', 'zh', 'ja', 'ko', 'ru', 'ar']

function apiKey(opts) {
  if (opts.apiKeyFile) {
    try { return readFileSync(opts.apiKeyFile, 'utf8').trim() } catch { /* not written yet */ }
  }
  return process.env[opts.apiKeyEnv] ?? ''
}

function wavSeconds(audio) {  // 16 kHz mono PCM16 after a 44-byte header
  return Math.max(0, audio.byteLength - 44) / (16000 * 2)
}

export function apply(ctx, config) {
  const opts = { ...DEFAULTS, ...(config ?? {}) }
  const provider = {
    info: { id: opts.providerId, name: 'Whisper (ROMEO)', location: 'cloud', languages: LANGUAGES },
    async transcribe(input, signal) {
      const form = new FormData()
      form.append('file', new Blob([input.audio], { type: 'audio/wav' }), 'recording.wav')
      form.append('model', opts.model)
      form.append('response_format', 'json')
      if (input.language && input.language !== 'auto') form.append('language', input.language)
      const started = performance.now()
      const timeout = AbortSignal.timeout(opts.timeoutMs)
      const response = await fetch(opts.baseURL.replace(/\/*$/u, '') + '/audio/transcriptions', {
        method: 'POST',
        headers: { authorization: `Bearer ${apiKey(opts)}` },
        body: form,
        redirect: 'error',
        signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      })
      if (!response.ok) {
        const detail = (await response.text().catch(() => '')).slice(0, 200)
        throw new Error(`Whisper on ROMEO: HTTP ${response.status}${detail ? `: ${detail}` : ''} (is its job running? dsh-romeo --status)`)
      }
      const data = await response.json()
      return {
        text: typeof data?.text === 'string' ? data.text.trim() : '',
        audioSeconds: wavSeconds(input.audio),
        inferenceSeconds: (performance.now() - started) / 1000,
      }
    },
  }
  ctx.effect(() => ctx.speechToText.register(provider), 'dsh-romeo-whisper: speech provider')
}

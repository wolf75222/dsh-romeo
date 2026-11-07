// DeepSeek Harness (dsh) Cordis plugin: appends the model a subagent runs on to its name, so the
// subagent list shows "Fix the parser · DeepSeek" or "Review the design · Kimi" (dsh-romeo
// --models kimi+deepseek, where the agent picks the model of each subagent).
// dsh-romeo selects it with
//   - id: dsh-romeo-subagent-model-label
//     config: { labels: { <model id>: <short name>, ... } }
// The model is the one the subagent tool asks for (agentOptions.model), else the parent's own.
// Only node: built-ins (none here), so it resolves from any directory.

export const name = 'dsh-romeo-subagent-model-label'
export const inject = ['subagents']

const SEP = ' · '
const WRAPPED = Symbol.for('dsh-romeo.subagent-model-label')

function parentModel(parent) {
  try {
    return parent?.session?.requestHeader?.()?.config?.model ?? parent?.options?.model
  } catch {
    return parent?.options?.model
  }
}

export function labelFor(labels, spec) {
  const model = spec?.request?.agentOptions?.model ?? parentModel(spec?.request?.parent)
  if (typeof model !== 'string' || model === '') return undefined
  return labels[model] ?? model
}

export function withModel(label, short) {
  if (short === undefined) return label
  const base = typeof label === 'string' && label !== '' ? label : 'Subagent'
  return base.endsWith(SEP + short) ? base : base + SEP + short
}

export function apply(ctx, config) {
  const labels = { ...(config?.labels ?? {}) }
  const proto = Object.getPrototypeOf(ctx.subagents)
  const original = proto?.startActivation
  if (typeof original !== 'function' || original[WRAPPED]) return
  const wrapped = function startActivation(spec) {
    let next = spec
    try {
      const short = labelFor(labels, spec)
      if (short !== undefined) next = { ...spec, label: withModel(spec.label, short) }
    } catch {}
    return original.call(this, next)
  }
  wrapped[WRAPPED] = true
  proto.startActivation = wrapped
  ctx.on('dispose', () => {
    if (proto.startActivation === wrapped) proto.startActivation = original
  })
}

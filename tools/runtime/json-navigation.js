// Read-only views decode embedded JSON only when a field is visited. Keep the
// original values for rendering and for existing explicit JSON.parse calls.
export function createJSONNavigation(root) {
  const views = new WeakMap()
  const sources = new WeakMap()
  const strings = new Map()

  function visit(original) {
    let value = original
    if (typeof value === 'string') {
      const first = value.trimStart()[0]
      if (first !== '{' && first !== '[') return value
      if (strings.has(value)) return strings.get(value)
      try {
        value = JSON.parse(value)
      } catch {
        strings.set(original, original)
        return original
      }
    }
    if (value === null || typeof value !== 'object') return value
    if (views.has(value)) return views.get(value)

    const view = Array.isArray(value) ? [] : {}
    views.set(value, view)
    sources.set(view, original)
    if (typeof original === 'string') {
      strings.set(original, view)
      Object.defineProperty(view, Symbol.toPrimitive, { value: () => original })
    }
    for (const key of Object.keys(value)) {
      Object.defineProperty(view, key, {
        enumerable: true,
        get: () => visit(value[key])
      })
    }
    return Object.freeze(view)
  }

  return {
    data: visit(root),
    source: value => sources.get(value) ?? value
  }
}

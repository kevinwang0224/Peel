import { build } from 'esbuild'
import { fileURLToPath } from 'node:url'
const base = new URL('../', import.meta.url)
await build({
  entryPoints: [fileURLToPath(new URL('scripts/runtime-entry.js', base))],
  outfile: fileURLToPath(new URL('Sources/PeelScript/Resources/runtime.js', base)),
  bundle: true, platform: 'browser', format: 'iife', globalName: 'PeelRuntime',
  target: 'safari17', legalComments: 'eof'
})

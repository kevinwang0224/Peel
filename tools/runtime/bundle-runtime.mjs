import { build } from 'esbuild'
import { fileURLToPath } from 'node:url'
const base = new URL('../../', import.meta.url)
await build({
  absWorkingDir: fileURLToPath(new URL('./', import.meta.url)),
  entryPoints: [fileURLToPath(new URL('./runtime-entry.js', import.meta.url))],
  outfile: fileURLToPath(new URL('Sources/PeelScript/Resources/runtime.js', base)),
  bundle: true, platform: 'browser', format: 'iife', globalName: 'PeelRuntime',
  target: 'safari17', legalComments: 'eof'
})

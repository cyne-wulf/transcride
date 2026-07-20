# EditorWeb

Offline CodeMirror 6 editor assets for Transcride. The exact dependency graph is
captured in `package-lock.json`; `dist/` is committed and is the only directory the
macOS application loads. Normal Xcode builds copy those assets and never run npm.

Developer validation:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run typecheck
npm test
npm run build
npm run check:freshness
```

The freshness check makes a clean exact-lock install in a temporary directory,
rebuilds there, and byte-compares the result with the checked-in bundle.

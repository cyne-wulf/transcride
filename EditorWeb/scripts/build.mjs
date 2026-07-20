import {build} from "esbuild"
import {cp, mkdir, rm} from "node:fs/promises"
import {resolve} from "node:path"

const outputDirectory = resolve(process.env.TRANSCRIDE_EDITOR_DIST ?? "dist")
await rm(outputDirectory, {recursive: true, force: true})
await mkdir(outputDirectory, {recursive: true})
await build({
  entryPoints: ["src/index.ts"],
  outfile: resolve(outputDirectory, "editor.js"),
  bundle: true,
  minify: true,
  sourcemap: false,
  platform: "browser",
  target: ["safari18"],
  legalComments: "none"
})
await cp("src/index.html", resolve(outputDirectory, "index.html"))

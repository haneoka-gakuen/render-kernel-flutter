import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, renameSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const compiler = process.argv[process.argv.indexOf("--compiler") + 1];
if (!process.argv.includes("--compiler") || !compiler)
  throw Error(
    "Usage: node tool/build-shaders.mjs --compiler /path/to/impellerc",
  );
// Regeneration is explicit so released kernels build from their pinned wrappers.
// The neutral source is shared with Three; no game/engine package is imported.
const sourceIndex = process.argv.indexOf("--render-shaders");
if (sourceIndex >= 0) {
  const source = process.argv[sourceIndex + 1];
  if (!source)
    throw Error("--render-shaders requires the canonical package root");
  const { flutterSpatialShaders } = await import(
    pathToFileURL(join(source, "src/flutter.js")).href
  );
  for (const [name, body] of Object.entries(flutterSpatialShaders()))
    writeFileSync(join(root, "assets/shaders", name), body);
  const identity = createHash("sha256")
    .update(readFileSync(join(source, "src/fsr1.js")))
    .digest("hex");
  writeFileSync(
    join(root, "assets/shaders/SPATIAL-SOURCE.json"),
    JSON.stringify(
      {
        package: "@haneoka/render-shaders",
        version: "0.1.0",
        canonicalSha256: identity,
        upstream: "GPUOpen-Effects/FidelityFX-FSR",
        tag: "v1.0.2",
        commit: "a21ffb8f6c13233ba336352bdff293894c706575",
      },
      null,
      2,
    ) + "\n",
  );
}
const target = join(root, "assets/shaders/spatial.shaderbundle"),
  temporary = target + ".building";
try {
  execFileSync(
    compiler,
    [
      "--metal-desktop",
      "--metal-ios",
      "--opengl-desktop",
      "--opengl-es",
      "--vulkan",
      "--shader-bundle=" +
        readFileSync(join(root, "assets/shaders/shaderbundle.json"), "utf8"),
      "--sl=" + temporary,
    ],
    { cwd: root, stdio: "inherit" },
  );
  renameSync(temporary, target);
} finally {
  rmSync(temporary, { force: true });
}

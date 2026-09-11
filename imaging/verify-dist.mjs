import assert from "node:assert/strict";
import { readFile, readdir, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export async function verifyDist(directory) {
  const html = await readFile(path.join(directory, "index.html"), "utf8");
  // HTML parsers also terminate scripts when an end tag has ignored attributes.
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\b[^>]*>/gi)];
  // This checks the pinned build template, not arbitrary HTML. Reject script
  // markup outside that contract instead of silently leaving it unchecked.
  assert.equal(
    scripts.length,
    [...html.matchAll(/<script\b/gi)].length,
    "Every script must have a supported closing tag",
  );
  assert.ok(scripts.length >= 3, "Expected bootstrap, configuration and generated app scripts");
  const sources = [];
  for (const [, attributes, content] of scripts) {
    assert.equal(content.trim(), "", "Executable inline scripts violate the gateway CSP");
    const source = attributes.match(/\bsrc=["']([^"']+)["']/i)?.[1];
    assert.ok(source?.startsWith("/imaging/"), "Every entry script must use the imaging prefix");
    assert.ok(!source.includes(".."), "Entry scripts must stay inside the build directory");
    assert.ok((await stat(path.join(directory, source.slice("/imaging/".length)))).isFile());
    sources.push(source);
  }
  assert.ok(
    sources.indexOf("/imaging/sihsalus-bootstrap.js") === 0 &&
      sources.indexOf("/imaging/app-config.js") === 1,
    "The external bootstrap and configuration must precede generated OHIF bundles",
  );
  assert.doesNotMatch(
    html,
    /init-service-worker|fonts\.googleapis|fonts\.gstatic/i,
    "Unsupported external bootstrap or fonts in the imaging shell",
  );

  const files = await readdir(directory);
  const appBundle = files.find((name) => /^app\.bundle\..+\.js$/.test(name));
  assert.ok(appBundle, "The OHIF app bundle must exist");
  const app = await readFile(path.join(directory, appBundle), "utf8");
  // Webpack keeps its runtime in this entry bundle. Production Terser renames
  // the runtime variable, while its publicPath (.p) and chunk loader (.u)
  // properties are stable. Check both on the same object, without parsing or
  // executing the application's code during image construction.
  const runtime = app.match(/(?:^|[^\w$.])([A-Za-z_$][\w$]*)\.p\s*=\s*["']\/imaging\/["']/)?.[1];
  assert.ok(
    runtime,
    "Lazy chunks and workers must use the compiled /imaging/ public path",
  );
  const escapedRuntime = runtime.replaceAll("$", "\\$");
  assert.match(
    app,
    new RegExp(`(?:^|[^\\w$.])${escapedRuntime}\\.u\\s*=`),
    "The prefixed runtime must load lazy chunks",
  );

  // Asset/resource emits content hashes for codecs. Verify references in the
  // generated chunks, including workers, instead of accepting one arbitrary
  // WASM file while a lazy decoder's binary is missing.
  const codecs = new Set();
  for (const bundle of files.filter((name) => name.endsWith(".js"))) {
    const source = bundle === appBundle ? app : await readFile(path.join(directory, bundle), "utf8");
    for (const [, codec] of source.matchAll(/["']([0-9a-f]{16,64}\.wasm)["']/g)) {
      codecs.add(codec);
    }
  }
  assert.ok(codecs.size > 0, "The generated chunks must reference DICOM codec assets");
  for (const codec of codecs) {
    const bytes = await readFile(path.join(directory, codec));
    assert.ok(
      bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0])),
      `Referenced codec ${codec} must be a WebAssembly module`,
    );
  }
  assert.ok(!files.includes("init-service-worker.js") && !files.includes("sw.js"));
  assert.ok(
    (await stat(path.join(directory, "dicom-microscopy-viewer/dicomMicroscopyViewer.min.js"))).isFile(),
    "The browser-imported microscopy module must have its own prefixed asset directory",
  );
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) {
    throw new Error("Usage: node verify-dist.mjs OHIF_DIST_DIRECTORY");
  }
  await verifyDist(process.argv[2]);
  console.log("OHIF compiled asset contract passed");
}

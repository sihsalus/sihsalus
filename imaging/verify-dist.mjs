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
  // OHIF 3.9.3 QUICK_BUILD disables minification and keeps the webpack runtime
  // in this entry bundle. Revisit this check if that build contract changes.
  assert.match(
    app,
    /__webpack_require__\.p\s*=\s*["']\/imaging\/["']/,
    "Lazy chunks and workers must use the compiled /imaging/ public path",
  );
  assert.ok(files.some((name) => name.endsWith(".wasm")), "DICOM codec WASM assets must be packaged");
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

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  EXTERNAL_BOOTSTRAP_FILE,
  parseConfigUrls,
  reconcileConfigUrls,
} = require('./patch-config-urls');

function makeOutputDirectory() {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sihsalus-spa-config-'));
  fs.writeFileSync(path.join(outDir, 'index.html'), '<!doctype html><html></html>\n');
  return outDir;
}

test('normalizes and deduplicates SPA_CONFIG_URLS', () => {
  assert.deepEqual(
    parseConfigUrls(' /openmrs/spa/frontend.json, /openmrs/spa/oauth.json, /openmrs/spa/frontend.json '),
    ['/openmrs/spa/frontend.json', '/openmrs/spa/oauth.json'],
  );
});

test('validates an external bootstrap without rewriting the revisioned artifact', (t) => {
  const outDir = makeOutputDirectory();
  t.after(() => fs.rmSync(outDir, { recursive: true, force: true }));

  const bootstrapPath = path.join(outDir, EXTERNAL_BOOTSTRAP_FILE);
  const source =
    'initializeSpa({\n  apiUrl: "/openmrs",\n  configUrls: ["/openmrs/spa/frontend.json"],\n});\n';
  fs.writeFileSync(bootstrapPath, source);

  const result = reconcileConfigUrls(outDir, '/openmrs/spa/frontend.json');

  assert.equal(result.mode, 'validated-external-bootstrap');
  assert.equal(result.targetPath, bootstrapPath);
  assert.equal(fs.readFileSync(bootstrapPath, 'utf8'), source);
});

test('rejects an external bootstrap assembled with different config URLs', (t) => {
  const outDir = makeOutputDirectory();
  t.after(() => fs.rmSync(outDir, { recursive: true, force: true }));

  fs.writeFileSync(
    path.join(outDir, EXTERNAL_BOOTSTRAP_FILE),
    'initializeSpa({ configUrls: ["/unexpected.json"] });\n',
  );

  assert.throws(
    () => reconcileConfigUrls(outDir, '/openmrs/spa/frontend.json'),
    /does not match SPA_CONFIG_URLS/,
  );
});

test('patches the inline initializer for a legacy app shell', (t) => {
  const outDir = makeOutputDirectory();
  t.after(() => fs.rmSync(outDir, { recursive: true, force: true }));

  const indexPath = path.join(outDir, 'index.html');
  fs.writeFileSync(
    indexPath,
    '<script>initializeSpa({ configUrls: ["$SPA_CONFIG_URLS"] });</script>\n',
  );

  const result = reconcileConfigUrls(
    outDir,
    '/openmrs/spa/frontend.json, /openmrs/spa/frontend-keycloak.json',
  );

  assert.equal(result.mode, 'patched-legacy-index');
  assert.match(
    fs.readFileSync(indexPath, 'utf8'),
    /configUrls: \["\/openmrs\/spa\/frontend\.json","\/openmrs\/spa\/frontend-keycloak\.json"\]/,
  );
});

test('rejects ambiguous or missing config initializers', (t) => {
  const outDir = makeOutputDirectory();
  t.after(() => fs.rmSync(outDir, { recursive: true, force: true }));

  assert.throws(
    () => reconcileConfigUrls(outDir, '/openmrs/spa/frontend.json'),
    /expected exactly one configUrls initializer.*found 0/,
  );

  fs.writeFileSync(
    path.join(outDir, EXTERNAL_BOOTSTRAP_FILE),
    'const first = { configUrls: ["/one.json"] }; const second = { configUrls: ["/two.json"] };\n',
  );
  assert.throws(
    () => reconcileConfigUrls(outDir, '/openmrs/spa/frontend.json'),
    /expected exactly one configUrls initializer.*found 2/,
  );
});

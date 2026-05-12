const fs = require('fs');
const path = require('path');

const outDir = process.env.SPA_OUTPUT_DIR || '/spa';
const loginBundle = path.join(outDir, 'esm-login-126-abf99dff.js');

if (!fs.existsSync(loginBundle)) {
  console.warn(`[patch-oauth-logout] ${loginBundle} not found; skipping`);
  process.exit(0);
}

const from = '"oauth2"!==e.provider.type&&(0,t.navigate)({to:"${openmrsSpaBase}/login"})';
const to =
  '"oauth2"===e.provider.type?globalThis.location.href=e.provider.logoutUrl:(0,t.navigate)({to:"${openmrsSpaBase}/login"})';

const source = fs.readFileSync(loginBundle, 'utf8');
const occurrences = source.split(from).length - 1;

if (occurrences === 0) {
  console.warn('[patch-oauth-logout] logout pattern not found; leaving login bundle unchanged');
  process.exit(0);
}

fs.writeFileSync(loginBundle, source.replaceAll(from, to));
console.log(`[patch-oauth-logout] patched ${occurrences} logout branch(es)`);

const fs = require('fs');
const path = require('path');

const outDir = process.env.SPA_OUTPUT_DIR || '/spa';
const indexPath = path.join(outDir, 'index.html');
const rawConfigUrls = (process.env.SPA_CONFIG_URLS || '').trim();

if (!fs.existsSync(indexPath)) {
  console.warn(`[patch-config-urls] ${indexPath} not found; skipping`);
  process.exit(0);
}

const configUrls = rawConfigUrls
  .split(',')
  .map((url) => url.trim())
  .filter(Boolean);

const replacement = `configUrls: ${JSON.stringify(configUrls)}`;
let html = fs.readFileSync(indexPath, 'utf8');
const nextHtml = html.replace(/configUrls:\s*\[[^\]]*\]/, replacement);

if (nextHtml === html) {
  console.warn('[patch-config-urls] configUrls initializer not found; leaving index.html unchanged');
  process.exit(0);
}

fs.writeFileSync(indexPath, nextHtml);
console.log(`[patch-config-urls] ${replacement}`);

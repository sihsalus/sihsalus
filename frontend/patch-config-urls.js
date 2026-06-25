const fs = require('fs');
const path = require('path');

const outDir = process.env.SPA_OUTPUT_DIR || '/spa';
const indexPath = path.join(outDir, 'index.html');
const rawConfigUrls = (process.env.SPA_CONFIG_URLS || '').trim();

if (!rawConfigUrls) {
  console.error('[patch-config-urls] SPA_CONFIG_URLS is required');
  process.exit(1);
}

if (!fs.existsSync(indexPath)) {
  console.error(`[patch-config-urls] ${indexPath} not found`);
  process.exit(1);
}

const configUrls = rawConfigUrls
  .split(',')
  .map((url) => url.trim())
  .filter(Boolean);

if (configUrls.length === 0) {
  console.error('[patch-config-urls] SPA_CONFIG_URLS did not contain any usable config URL');
  process.exit(1);
}

const replacement = `configUrls: ${JSON.stringify(configUrls)}`;
const html = fs.readFileSync(indexPath, 'utf8');
const nextHtml = html.replace(/configUrls:\s*\[[^\]]*\]/, replacement);

if (nextHtml === html) {
  console.error('[patch-config-urls] configUrls initializer not found in index.html');
  process.exit(1);
}

fs.writeFileSync(indexPath, nextHtml);
console.log(`[patch-config-urls] ${replacement}`);

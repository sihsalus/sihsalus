const fs = require('fs');
const path = require('path');

const CONFIG_URLS_PATTERN = /configUrls:\s*(\[[^\]]*\])/g;
const EXTERNAL_BOOTSTRAP_FILE = 'sihsalus-spa-bootstrap.js';

function parseConfigUrls(rawConfigUrls) {
  const normalized = rawConfigUrls.trim();
  if (!normalized) {
    throw new Error('SPA_CONFIG_URLS is required');
  }

  const configUrls = Array.from(
    new Set(
      normalized
        .split(',')
        .map((url) => url.trim())
        .filter(Boolean),
    ),
  );

  if (configUrls.length === 0) {
    throw new Error('SPA_CONFIG_URLS did not contain any usable config URL');
  }

  return configUrls;
}

function findSingleInitializer(source, targetPath) {
  const matches = [...source.matchAll(CONFIG_URLS_PATTERN)];
  if (matches.length !== 1) {
    throw new Error(
      `expected exactly one configUrls initializer in ${targetPath}, found ${matches.length}`,
    );
  }

  return matches[0];
}

function reconcileConfigUrls(outDir, rawConfigUrls) {
  const configUrls = parseConfigUrls(rawConfigUrls);
  const indexPath = path.join(outDir, 'index.html');
  const bootstrapPath = path.join(outDir, EXTERNAL_BOOTSTRAP_FILE);

  if (!fs.existsSync(indexPath)) {
    throw new Error(`${indexPath} not found`);
  }

  if (fs.existsSync(bootstrapPath)) {
    const bootstrap = fs.readFileSync(bootstrapPath, 'utf8');
    const initializer = findSingleInitializer(bootstrap, bootstrapPath);
    let assembledConfigUrls;

    try {
      assembledConfigUrls = JSON.parse(initializer[1]);
    } catch (error) {
      throw new Error(`configUrls initializer in ${bootstrapPath} is not a JSON array`, {
        cause: error,
      });
    }

    if (
      !Array.isArray(assembledConfigUrls) ||
      assembledConfigUrls.some((url) => typeof url !== 'string') ||
      JSON.stringify(assembledConfigUrls) !== JSON.stringify(configUrls)
    ) {
      throw new Error(
        `configUrls in ${bootstrapPath} does not match SPA_CONFIG_URLS; rebuild with the requested configuration`,
      );
    }

    return {
      configUrls,
      mode: 'validated-external-bootstrap',
      targetPath: bootstrapPath,
    };
  }

  const html = fs.readFileSync(indexPath, 'utf8');
  const initializer = findSingleInitializer(html, indexPath);
  const replacement = `configUrls: ${JSON.stringify(configUrls)}`;
  const nextHtml =
    html.slice(0, initializer.index) +
    replacement +
    html.slice(initializer.index + initializer[0].length);

  fs.writeFileSync(indexPath, nextHtml);
  return {
    configUrls,
    mode: 'patched-legacy-index',
    targetPath: indexPath,
  };
}

function main() {
  const outDir = process.env.SPA_OUTPUT_DIR || '/spa';
  const rawConfigUrls = process.env.SPA_CONFIG_URLS || '';
  const result = reconcileConfigUrls(outDir, rawConfigUrls);

  if (result.mode === 'validated-external-bootstrap') {
    console.log(
      `[patch-config-urls] validated configUrls in ${result.targetPath}: ${JSON.stringify(result.configUrls)}`,
    );
  } else {
    console.log(
      `[patch-config-urls] patched configUrls in ${result.targetPath}: ${JSON.stringify(result.configUrls)}`,
    );
  }
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`[patch-config-urls] ${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = {
  EXTERNAL_BOOTSTRAP_FILE,
  parseConfigUrls,
  reconcileConfigUrls,
};

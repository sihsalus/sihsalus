import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import { prepareSource } from "../../imaging/prepare-source.mjs";
import { verifyDist } from "../../imaging/verify-dist.mjs";

const imagingDirectory = new URL("../../imaging/", import.meta.url);
const buildEnvironment = { PUBLIC_URL: "/imaging/", APP_CONFIG: "config/sihsalus.js" };
const fixtureCodec = "0123456789abcdef01234.wasm";
const fixtureRuntime = `__webpack_require__.p = "/imaging/";
__webpack_require__.u = (id) => id + ".bundle.js";
const codec = __webpack_require__.p + "${fixtureCodec}";`;

async function temporaryDirectory(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "sihsalus-ohif-contract-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

async function sourceFixture(t, { version = "3.9.3", imports } = {}) {
  const directory = await temporaryDirectory(t);
  await mkdir(path.join(directory, "platform/app"), { recursive: true });
  await writeFile(path.join(directory, "platform/app/package.json"), JSON.stringify({ version }));
  const environmentPath = path.join(directory, "platform/app/.env");
  const environment = "# Upstream development configuration\nPUBLIC_URL=/\nAPP_CONFIG=config/default.js\nUSE_HASH_ROUTER=false\nANOTHER_SETTING=preserved\n";
  await writeFile(environmentPath, environment);
  const plugins = {
    extensions: [{ packageName: "@ohif/extension-default" }],
    modes: [{ packageName: "@ohif/mode-longitudinal" }],
    public: imports ?? [
      { directory: "./platform/public" },
      {
        packageName: "dicom-microscopy-viewer",
        importPath: "/dicom-microscopy-viewer/dicomMicroscopyViewer.min.js",
        globalName: "dicomMicroscopyViewer",
        directory: "./node_modules/dicom-microscopy-viewer/dist/dynamic-import",
      },
    ],
  };
  const pluginPath = path.join(directory, "platform/app/pluginConfig.json");
  const original = JSON.stringify(plugins);
  await writeFile(pluginPath, original);
  return { directory, pluginPath, plugins, original, environmentPath, environment };
}

async function distFixture(t) {
  const directory = await temporaryDirectory(t);
  await mkdir(path.join(directory, "dicom-microscopy-viewer"));
  const template = await readFile(new URL("index.html", imagingDirectory), "utf8");
  const html = template
    .replaceAll("<%= PUBLIC_URL %>", "/imaging/")
    .replace("</head>", '<script defer src="/imaging/app.bundle.fixture.js"></script></head>');
  await Promise.all([
    writeFile(path.join(directory, "index.html"), html),
    writeFile(path.join(directory, "sihsalus-bootstrap.js"), "// fixture bootstrap"),
    writeFile(path.join(directory, "app-config.js"), "window.config = {};"),
    writeFile(path.join(directory, "app.bundle.fixture.js"), fixtureRuntime),
    writeFile(path.join(directory, fixtureCodec), Buffer.from([0, 97, 115, 109, 1, 0, 0, 0])),
    writeFile(path.join(directory, "dicom-microscopy-viewer/dicomMicroscopyViewer.min.js"), "// fixture"),
  ]);
  return { directory, html };
}

test("bootstrap initializes the viewer without touching OpenMRS offline registrations or caches", async () => {
  const unexpectedAccess = () => assert.fail("The viewer must preserve another application's offline state");
  const window = {};
  const context = vm.createContext({
    window,
    console: { time() {} },
    navigator: { serviceWorker: { getRegistrations: unexpectedAccess, register: unexpectedAccess } },
    caches: { keys: unexpectedAccess, delete: unexpectedAccess },
    localStorage: { clear: unexpectedAccess, removeItem: unexpectedAccess },
  });
  const bootstrap = await readFile(new URL("bootstrap.js", imagingDirectory), "utf8");
  new vm.Script(bootstrap).runInContext(context);
  assert.equal(window.PUBLIC_URL, "/imaging/");
  assert.equal(typeof window.browserImportFunction, "function");
});

test("OHIF uses one router prefix with same-origin DICOMweb", async () => {
  const window = {};
  const configuration = await readFile(new URL("app-config.js", imagingDirectory), "utf8");
  new vm.Script(configuration).runInNewContext({ window });
  assert.equal(window.config.routerBasename, "/imaging");
  assert.equal(window.config.defaultDataSourceName, "dicomweb");
  const dataSource = window.config.dataSources.find((source) => source.sourceName === "dicomweb");
  for (const property of ["qidoRoot", "wadoRoot", "wadoUriRoot"]) {
    const endpoint = dataSource.configuration[property];
    assert.ok(endpoint.startsWith("/") && !endpoint.startsWith("//"));
    assert.equal(new URL(endpoint, "https://synthetic.invalid").origin, "https://synthetic.invalid");
  }
});

test("source preparation relocates microscopy without changing other plugins or modes", async (t) => {
  const fixture = await sourceFixture(t);
  await prepareSource(fixture.directory, buildEnvironment);
  const actual = JSON.parse(await readFile(fixture.pluginPath, "utf8"));
  const expected = structuredClone(fixture.plugins);
  expected.public[1].importPath = "/imaging/dicom-microscopy-viewer/dicomMicroscopyViewer.min.js";
  assert.deepEqual(actual, expected);
});

test("build inputs replace only the public path and app configuration in upstream dotenv", async (t) => {
  const fixture = await sourceFixture(t);
  await prepareSource(fixture.directory, buildEnvironment);
  assert.equal(
    await readFile(fixture.environmentPath, "utf8"),
    fixture.environment.replace("PUBLIC_URL=/\n", "PUBLIC_URL=/imaging/\n")
      .replace("APP_CONFIG=config/default.js", "APP_CONFIG=config/sihsalus.js"),
  );
});

for (const value of [undefined, "", "/imaging/\nOTHER=value"]) {
  test(`an invalid public build path ${JSON.stringify(value)} fails before source changes`, async (t) => {
    const fixture = await sourceFixture(t);
    await assert.rejects(
      prepareSource(fixture.directory, { ...buildEnvironment, PUBLIC_URL: value }),
      /single-line PUBLIC_URL/,
    );
    assert.equal(await readFile(fixture.pluginPath, "utf8"), fixture.original);
    assert.equal(await readFile(fixture.environmentPath, "utf8"), fixture.environment);
  });
}

for (const [name, replacement] of [["absent", ""], ["duplicate", "PUBLIC_URL=/\nPUBLIC_URL=/other/"]]) {
  test(`an ${name} upstream dotenv declaration requires review`, async (t) => {
    const fixture = await sourceFixture(t);
    const changed = fixture.environment.replace("PUBLIC_URL=/", replacement);
    await writeFile(fixture.environmentPath, changed);
    await assert.rejects(prepareSource(fixture.directory, buildEnvironment), /declaration changed/);
    assert.equal(await readFile(fixture.pluginPath, "utf8"), fixture.original);
    assert.equal(await readFile(fixture.environmentPath, "utf8"), changed);
  });
}

test("an upstream version change fails before altering its source", async (t) => {
  const fixture = await sourceFixture(t, { version: "3.10.0" });
  await assert.rejects(prepareSource(fixture.directory, buildEnvironment), /packaging contract/);
  assert.equal(await readFile(fixture.pluginPath, "utf8"), fixture.original);
});

for (const [name, imports] of [
  ["missing", []],
  ["moved", [{ packageName: "dicom-microscopy-viewer", importPath: "/changed.js" }]],
  [
    "duplicated",
    [1, 2].map(() => ({
      packageName: "dicom-microscopy-viewer",
      importPath: "/dicom-microscopy-viewer/dicomMicroscopyViewer.min.js",
    })),
  ],
]) {
  test(`a ${name} microscopy import fails without silently rewriting unknown source`, async (t) => {
    const fixture = await sourceFixture(t, { imports });
    await assert.rejects(prepareSource(fixture.directory, buildEnvironment), /microscopy import changed/);
    assert.equal(await readFile(fixture.pluginPath, "utf8"), fixture.original);
  });
}

test("the distribution contract accepts prefixed scripts, compiled chunks, codecs and microscopy", async (t) => {
  const { directory } = await distFixture(t);
  await verifyDist(directory);
});

for (const runtime of ["n", "a7", "$", "_r$"]) {
  test(`production minification can rename the webpack runtime to ${runtime}`, async (t) => {
    const { directory } = await distFixture(t);
    const bundle = `(()=>{${runtime}.u=e=>e+".bundle.js",${runtime}.p="/imaging/";const c=${runtime}.p+"${fixtureCodec}"})();`;
    await writeFile(path.join(directory, "app.bundle.fixture.js"), bundle);
    await verifyDist(directory);
  });
}

test("a path on an unrelated object cannot stand in for webpack's chunk runtime", async (t) => {
  const { directory } = await distFixture(t);
  const bundle = `n.u=e=>e+".bundle.js";n.p="/";other.p="/imaging/";const c="${fixtureCodec}";`;
  await writeFile(path.join(directory, "app.bundle.fixture.js"), bundle);
  await assert.rejects(verifyDist(directory), /prefixed runtime/);
});

test("runtime names cannot match the suffix of a different object", async (t) => {
  const { directory } = await distFixture(t);
  const bundle = `ba.u=e=>e+".bundle.js";a.p="/imaging/";const c="${fixtureCodec}";`;
  await writeFile(path.join(directory, "app.bundle.fixture.js"), bundle);
  await assert.rejects(verifyDist(directory), /prefixed runtime/);
});

test("every codec referenced by a lazy worker chunk must exist", async (t) => {
  const { directory } = await distFixture(t);
  const codec = "abcdef0123456789abcd0.wasm";
  await writeFile(path.join(directory, "decode.worker.js"), `const wasm = workerRuntime.p + "${codec}";`);
  await assert.rejects(verifyDist(directory), { code: "ENOENT" });
  await writeFile(path.join(directory, codec), Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]));
  await verifyDist(directory);
});

test("a codec cannot be an HTML fallback page or a truncated module", async (t) => {
  const { directory } = await distFixture(t);
  for (const content of ["<!doctype html><title>Not found</title>", Buffer.from([0, 97, 115, 109])]) {
    await writeFile(path.join(directory, fixtureCodec), content);
    await assert.rejects(verifyDist(directory), /must be a WebAssembly module/);
  }
});

test("script closing tags may use HTML whitespace and mixed case", async (t) => {
  const { directory, html } = await distFixture(t);
  await writeFile(path.join(directory, "index.html"), html.replaceAll("</script>", "</ScRiPt \t\n>"));
  await verifyDist(directory);
});

for (const [name, transform, message] of [
  [
    "inline bootstrap",
    (html) => html.replace("</head>", '<script>window.PUBLIC_URL="/";</script></head>'),
    /inline scripts/,
  ],
  [
    "inline bootstrap with closing-tag whitespace",
    (html) => html.replace("</head>", '<script>window.PUBLIC_URL="/";</script ></head>'),
    /inline scripts/,
  ],
  [
    "inline bootstrap with ignored closing-tag attributes",
    (html) => html.replace("</head>", '<script>window.PUBLIC_URL="/";</script ignored></head>'),
    /inline scripts/,
  ],
  [
    "inline bootstrap with mixed closing-tag whitespace and attributes",
    (html) => html.replace("</head>", '<script>window.PUBLIC_URL="/";</ScRiPt \t\n ignored="value"></head>'),
    /inline scripts/,
  ],
  [
    "unterminated script",
    (html) => html.replace("</body>", '<script src="/imaging/app.bundle.fixture.js"></body>'),
    /Every script/,
  ],
  [
    "root entry script",
    (html) => html.replace("/imaging/app.bundle.fixture.js", "/app.bundle.fixture.js"),
    /imaging prefix/,
  ],
  [
    "configuration before bootstrap",
    (html) => html
      .replace("sihsalus-bootstrap.js", "temporary.js")
      .replace("app-config.js", "sihsalus-bootstrap.js")
      .replace("temporary.js", "app-config.js"),
    /must precede/,
  ],
  [
    "unscoped service worker bootstrap",
    (html) => html.replace("</head>", "<!-- init-service-worker.js --></head>"),
    /Unsupported external bootstrap/,
  ],
]) {
  test(`the built asset contract rejects ${name}`, async (t) => {
    const { directory, html } = await distFixture(t);
    await writeFile(path.join(directory, "index.html"), transform(html));
    await assert.rejects(verifyDist(directory), message);
  });
}

test("changing the router alone cannot hide an incorrectly compiled public path", async (t) => {
  const { directory } = await distFixture(t);
  await writeFile(path.join(directory, "app.bundle.fixture.js"), '__webpack_require__.p = "/";');
  await assert.rejects(verifyDist(directory), /compiled \/imaging\//);
});

for (const missingFile of [
  "app.bundle.fixture.js",
  fixtureCodec,
  "dicom-microscopy-viewer/dicomMicroscopyViewer.min.js",
]) {
  test(`a missing ${missingFile} fails packaging`, async (t) => {
    const { directory } = await distFixture(t);
    await rm(path.join(directory, missingFile));
    await assert.rejects(verifyDist(directory));
  });
}

test("the upstream service worker cannot remain in the served distribution", async (t) => {
  const { directory } = await distFixture(t);
  await writeFile(path.join(directory, "sw.js"), "// upstream service worker");
  await assert.rejects(verifyDist(directory));
});

test("WASM permissions stay inside the viewer and executable inline scripts remain forbidden", async () => {
  const maps = await readFile(new URL("../../gateway/templates/includes/maps.conf.template", import.meta.url), "utf8");
  const viewer = maps.split("\n").find((line) => line.includes('"~^/imaging/"'));
  assert.ok(viewer, "The viewer must have its own CSP");
  const scripts = viewer.match(/script-src ([^;]+);/)?.[1];
  assert.equal(scripts, "'self' 'wasm-unsafe-eval'");
  assert.doesNotMatch(maps.replace(viewer, ""), /wasm-unsafe-eval/);
  assert.doesNotMatch(viewer, /https:\/\/|'unsafe-eval'/);
  assert.match(viewer, /worker-src 'self' blob:/);
  assert.match(viewer, /media-src 'self' blob:/);
});

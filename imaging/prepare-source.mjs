import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export async function prepareSource(sourceDirectory, buildEnvironment) {
  const packageJson = JSON.parse(
    await readFile(path.join(sourceDirectory, "platform/app/package.json"), "utf8"),
  );
  if (packageJson.version !== "3.9.3") {
    throw new Error("Review the SIH Salus packaging contract before changing OHIF version");
  }

  const pluginPath = path.join(sourceDirectory, "platform/app/pluginConfig.json");
  const plugins = JSON.parse(await readFile(pluginPath, "utf8"));
  const microscopy = plugins.public?.filter(
    (plugin) => plugin.packageName === "dicom-microscopy-viewer",
  );
  if (
    microscopy?.length !== 1 ||
    microscopy[0].importPath !== "/dicom-microscopy-viewer/dicomMicroscopyViewer.min.js"
  ) {
    throw new Error("The upstream microscopy import changed; review its asset location");
  }

  // The upstream dotenv-webpack plugin reads this file independently of the
  // DefinePlugin that uses Docker's environment. Align only these two values;
  // keep routing flags and any other upstream settings unchanged.
  const environmentPath = path.join(sourceDirectory, "platform/app/.env");
  let environment = await readFile(environmentPath, "utf8");
  for (const key of ["PUBLIC_URL", "APP_CONFIG"]) {
    const value = buildEnvironment?.[key];
    if (typeof value !== "string" || !value || /[\r\n]/.test(value)) {
      throw new Error(`A single-line ${key} build value is required`);
    }
    const declaration = new RegExp(`^${key}=.*$`, "gm");
    if ([...environment.matchAll(declaration)].length !== 1) {
      throw new Error(`The upstream ${key} declaration changed; review its build configuration`);
    }
    environment = environment.replace(declaration, () => `${key}=${value}`);
  }

  // OHIF's peer import is a browser import, outside webpack's PUBLIC_URL.
  // The Dockerfile packages this directory at the matching public location.
  microscopy[0].importPath = "/imaging/dicom-microscopy-viewer/dicomMicroscopyViewer.min.js";
  await writeFile(environmentPath, environment);
  await writeFile(pluginPath, `${JSON.stringify(plugins, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) {
    throw new Error("Usage: node prepare-source.mjs OHIF_SOURCE_DIRECTORY");
  }
  await prepareSource(process.argv[2], {
    PUBLIC_URL: process.env.PUBLIC_URL,
    APP_CONFIG: process.env.APP_CONFIG,
  });
}

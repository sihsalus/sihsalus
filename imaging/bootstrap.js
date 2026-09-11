// This classic script runs before app-config and the generated OHIF bundles.
// PUBLIC_URL also has to be compiled into webpack; this value alone cannot
// relocate lazy chunks, workers or WASM files from an upstream root build.
console.time("scriptToView");
window.PUBLIC_URL = "/imaging/";

window.browserImportFunction = function browserImportFunction(moduleId) {
  return import(moduleId);
};

// Do not run OHIF 3.9.3's init-service-worker.js: it unregisters every service
// worker on the origin, including OpenMRS's offline worker. This viewer does
// not register a service worker or alter another application's cache.

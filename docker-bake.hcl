// ===========================================
// sihsalus - Docker Bake Build Definitions
// ===========================================
//
// USAGE:
//   docker buildx bake                 # Build core (backend, gateway, frontend)
//   docker buildx bake all             # Build all targets
//   docker buildx bake backend         # Build single target
//   docker buildx bake --print         # Show resolved build config (dry-run)

variable "TAG" {
  default = "qa"
}

variable "REGISTRY" {
  default = ""
}

// Standalone HCL fallback. tests/frontend/build-config.py checks these values
// against Compose; when Compose is loaded, its target arguments take precedence.
FRONTEND_DEFAULT_SOURCE_TAG = "sha-a624206bca7e3e084c68b544e8d5b3ab0b037e27@sha256:ad79b27f913535048c676f8f922a77803d288c6ed0a5569e3ea98ea3a2ae8e26"

variable "FRONTEND_SOURCE_TAG" {
  default = FRONTEND_DEFAULT_SOURCE_TAG
}

variable "FRONTEND_SOURCE_IMAGE" {
  default = ""
}

variable "SIHSALUS_NODE_ID" {
  default = "unconfigured"
}

variable "STRIP_SOURCE_MAPS" {
  default = "true"
}

// ---- Shared base ----

target "_base" {
  pull = true
}

target "_frontend_defaults" {
  context    = "./frontend"
  dockerfile = "Dockerfile"
  args = {
    FRONTEND_SOURCE_IMAGE = FRONTEND_SOURCE_IMAGE != "" ? FRONTEND_SOURCE_IMAGE : "ghcr.io/sihsalus/sihsalus-frontend:${FRONTEND_SOURCE_TAG != "" ? FRONTEND_SOURCE_TAG : FRONTEND_DEFAULT_SOURCE_TAG}"
    SPA_PATH              = "/openmrs/spa"
    API_URL               = "/openmrs"
    SPA_CONFIG_URLS       = "/openmrs/spa/frontend.json"
    SPA_DEFAULT_LOCALE    = "es"
    SIHSALUS_NODE_ID       = SIHSALUS_NODE_ID != "" ? SIHSALUS_NODE_ID : "unconfigured"
    STRIP_SOURCE_MAPS      = STRIP_SOURCE_MAPS != "" ? STRIP_SOURCE_MAPS : "true"
  }
}

// ---- Groups ----

group "default" {
  targets = ["backend", "gateway", "frontend"]
}

group "all" {
  targets = ["backend", "gateway", "frontend", "keycloak", "certbot"]
}

// ---- Core Targets ----

target "backend" {
  inherits   = ["_base"]
  context    = "."
  dockerfile = "backend/Dockerfile"
  tags       = ["${REGISTRY}openmrs/openmrs-reference-application-3-backend:${TAG}"]
}

target "gateway" {
  inherits   = ["_base"]
  context    = "./gateway"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}sihsalus-gateway:${TAG}"]
}

target "frontend" {
  inherits   = ["_base", "_frontend_defaults"]
  // Inherited defaults also support -f docker-bake.hcl without loading Compose.
  tags       = ["${REGISTRY}sihsalus-frontend-runtime:${TAG}"]
}

// ---- Optional Targets ----

target "keycloak" {
  inherits   = ["_base"]
  context    = "./oauth"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}sihsalus-keycloak:${TAG}"]
}

target "certbot" {
  inherits   = ["_base"]
  context    = "./certbot"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}sihsalus-certbot:${TAG}"]
}

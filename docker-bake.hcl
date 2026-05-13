// ===========================================
// sihsalus - Docker Bake Build Definitions
// ===========================================
//
// USAGE:
//   docker buildx bake                 # Build core (backend, gateway)
//   docker buildx bake all             # Build all targets
//   docker buildx bake backend         # Build single target
//   docker buildx bake --print         # Show resolved build config (dry-run)

variable "TAG" {
  default = "qa"
}

variable "REGISTRY" {
  default = ""
}

variable "FRONTEND_SOURCE_TAG" {
  default = "latest"
}

// ---- Shared base ----

target "_base" {
  pull = true
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
  inherits   = ["_base"]
  context    = "./frontend"
  dockerfile = "Dockerfile"
  args = {
    FRONTEND_SOURCE_IMAGE = "ghcr.io/sihsalus/sihsalus-frontend:${FRONTEND_SOURCE_TAG}"
    SPA_PATH              = "/openmrs/spa"
    API_URL               = "/openmrs"
    SPA_CONFIG_URLS       = "/openmrs/spa/frontend.json"
    SPA_DEFAULT_LOCALE    = "es"
  }
  tags       = ["${REGISTRY}sihsalus-frontend-runtime:${TAG}"]
}

// ---- Optional Targets ----

target "keycloak" {
  inherits   = ["_base"]
  context    = "./keycloak"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}sihsalus-keycloak:${TAG}"]
}

target "certbot" {
  inherits   = ["_base"]
  context    = "./certbot"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}sihsalus-certbot:${TAG}"]
}

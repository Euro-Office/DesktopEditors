# docker-bake.hcl

variable "REGISTRY" {
  default = "euro-office"
}

variable "TAG" {
  default = "latest"
}

variable "PRODUCT_VERSION" {
  default = "9.3.1"
}

variable "BUILD_NUMBER" {
  default = "0"
}


variable "BUILD_ROOT" {
  default = "/package"
}

variable "NUGET_CACHE" {
  default = "local"
  validation {
    condition     = contains(["local", "remote"], NUGET_CACHE)
    error_message = "NUGET_CACHE must be 'local' or 'remote'."
  }
}

variable "NUGET_SOURCE_PATH" {
  default = "/nuget-cache"
}

variable "CACHE_BUST" {
  default = "1"
}

variable "BRANDING_DIR" {
  default = "."
}

variable "COMPANY_NAME" {
  default = "Euro-Office"
}

variable "COMPANY_NAME_LOW" {
  default = regex_replace(lower(COMPANY_NAME), "\\s+", "-")
}

variable "PRODUCT_NAME" {
  default = "Desktop Editors"
}

# ──────────────────────────────────────────────
# BUILD GROUPS
# ──────────────────────────────────────────────

group "default" {
  targets = ["desktop-export"]
}

group "deps" {
  targets = ["core-base", "desktop-js", "sdkjs-desktop", "web-apps"]
}

# ──────────────────────────────────────────────
# SHARED ARGS (inherited by all targets)
# ──────────────────────────────────────────────

target "_common" {
  args = {
    PRODUCT_VERSION     = "${PRODUCT_VERSION}"
    BUILD_NUMBER        = "${BUILD_NUMBER}"
    BUILD_ROOT          = "${BUILD_ROOT}"
    NUGET_CACHE         = "${NUGET_CACHE}"
    CACHE_BUST          = "${CACHE_BUST}"
    BRANDING_DIR        = "${BRANDING_DIR}"
    PRODUCT_NAME        = "${PRODUCT_NAME}"
    COMPANY_NAME        = "${COMPANY_NAME}"
    COMPANY_NAME_LOW    = "${COMPANY_NAME_LOW}"
  }
}

# ──────────────────────────────────────────────
# DEPENDENCY TARGETS
# ──────────────────────────────────────────────

target "third-party" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./core/.docker/third-party.bake.Dockerfile"
  target     = "third-party-builder"
  tags       = ["${REGISTRY}/third-party:${TAG}"]
  secret = [
    "id=nextcloud_user,env=NEXTCLOUD_USER",
    "id=nextcloud_pass,env=NEXTCLOUD_PASS",
  ]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/third-party"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/third-party,mode=max"]
}


target "core-base" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./core/.docker/core.bake.Dockerfile"
  target     = "core-base"
  tags       = ["${REGISTRY}/core-base:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/core-base"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/core-base,mode=max"]
}

target "core-wasm" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./core/.docker/core-wasm.bake.Dockerfile"
  tags       = ["${REGISTRY}/core-wasm:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/core-wasm"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/core-wasm,mode=max"]
}

target "desktop-js" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./desktop-apps/.docker/desktop-js.bake.Dockerfile"
  tags       = ["${REGISTRY}/desktop-js:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/desktop-js"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/desktop-js,mode=max"]
}

target "sdkjs-desktop" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./sdkjs/.docker/sdkjs.bake.Dockerfile"
  tags       = ["${REGISTRY}/sdkjs-desktop:${TAG}"]
  target     = "sdkjs-desktop"
  cache-from = ["type=local,src=/tmp/${REGISTRY}/sdkjs-desktop"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/sdkjs-desktop,mode=max"]
  contexts = {
    core-wasm    = "target:core-wasm"
  }
}

target "web-apps" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./web-apps/.docker/web-apps.bake.Dockerfile"
  tags       = ["${REGISTRY}/web-apps:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/web-apps"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/web-apps,mode=max"]
}

# ──────────────────────────────────────────────
# BUILD TARGET
# ──────────────────────────────────────────────

target "desktop-builder" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./desktop-apps/.docker/desktop-apps.bake.Dockerfile"
  target     = "desktop-builder"
  tags       = ["${REGISTRY}/desktop-builder:${TAG}"]
  contexts = {
    core-base     = "target:core-base"
    desktop-js    = "target:desktop-js"
    sdkjs-desktop = "target:sdkjs-desktop"
    web-apps      = "target:web-apps"
    third-party   = "target:third-party"
  }
  secret = [
    "id=nextcloud_user,env=NEXTCLOUD_USER",
    "id=nextcloud_pass,env=NEXTCLOUD_PASS",
  ]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/desktop-builder"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/desktop-builder,mode=max"]
}

# ──────────────────────────────────────────────
# EXPORT TARGET
# ──────────────────────────────────────────────

target "desktop-export" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./build/.docker/desktop-composer.bake.Dockerfile"
  target     = "desktop-export"       # points to the FROM scratch stage
  tags       = ["${REGISTRY}/desktop-export:${TAG}"]
  contexts = {
    core-base       = "target:core-base"        # ← needed because Dockerfile references them
    desktop-js      = "target:desktop-js"       #   even in stages before desktop-export
    sdkjs-desktop   = "target:sdkjs-desktop"
    web-apps        = "target:web-apps"
    desktop-builder = "target:desktop-builder"
  }

  # Export the filesystem directly to a local directory instead of an image
  output = ["type=local,dest=./deploy/desktop"]

  cache-from = ["type=local,src=/tmp/${REGISTRY}/desktop-builder"]  # reuses builder cache
}

target "packages" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./build/.docker/packages.bake.Dockerfile"
  target     = "packages"       # points to the FROM scratch stage
  tags       = ["${REGISTRY}/packages:${TAG}"]
  contexts = {
    desktop-export          = "target:desktop-export"
  }

  # Export the filesystem directly to a local directory instead of an image
  output = ["type=local,dest=./deploy/packages"]

  cache-from = ["type=local,src=/tmp/${REGISTRY}/packages"]  # reuses builder cache
}
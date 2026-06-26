# docker-bake.hcl

variable "GIT_COMMIT" {
  default = ""
} 

variable "REGISTRY" {
  default = "ghcr.io/euro-office"
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
  targets = ["desktop-common"]
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

target "core-base" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./core/.docker/core.bake.Dockerfile"
  target     = "core-base"
  tags       = ["${REGISTRY}/core-base:${TAG}"]
  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/core-base"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/core-base,mode=max"]
}

target "core-wasm" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./core/.docker/core-wasm.bake.Dockerfile"
  tags       = ["${REGISTRY}/core-wasm:${TAG}"]
  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/core-wasm"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/core-wasm,mode=max"]
}

target "desktop-js" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./desktop-apps/.docker/desktop-js.bake.Dockerfile"
  tags       = ["${REGISTRY}/desktop-js:${TAG}"]
  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/desktop-js"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/desktop-js,mode=max"]
}

target "sdkjs-desktop" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./sdkjs/.docker/sdkjs.bake.Dockerfile"
  tags       = ["${REGISTRY}/sdkjs-desktop:${TAG}"]
  target     = "sdkjs-desktop"
  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/sdkjs-desktop"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/sdkjs-desktop,mode=max"]
  contexts = {
    core-wasm    = "target:core-wasm"
  }
}

target "web-apps" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./web-apps/.docker/web-apps.bake.Dockerfile"
  tags       = ["${REGISTRY}/web-apps:${TAG}"]
  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/web-apps"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/web-apps,mode=max"]
}

# ──────────────────────────────────────────────
# BUILD TARGET
# ──────────────────────────────────────────────

target "third-party" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./core/.docker/third-party.bake.Dockerfile"
  target     = "third-party-builder"
  tags       = ["${REGISTRY}/third-party:${TAG}"]
  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/third-party"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/third-party,mode=max"]
}

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
    desktop-common = "target:desktop-common"
    third-party   = "target:third-party"
  }
  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/desktop-builder"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/desktop-builder,mode=max"]
}

# ──────────────────────────────────────────────
# EXPORT TARGET
# ──────────────────────────────────────────────


### Compose files that are common to all operating systems
target "desktop-common" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./build/.docker/desktop-composer.bake.Dockerfile"
  target     = "desktop-common"       # points to the FROM scratch stage
  tags       = ["${REGISTRY}/desktop-common:${GIT_COMMIT}"]
  contexts = {
    desktop-js      = "target:desktop-js"       #   even in stages before desktop-common
    sdkjs-desktop   = "target:sdkjs-desktop"
    web-apps        = "target:web-apps"
  }

  # Export the filesystem directly to a local directory instead of an image
  output = ["type=docker"]

  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/desktop-builder"]  # reuses builder cache
}

target "desktop-export" {
  inherits   = ["_common"]
  context    = ".."
  dockerfile = "./desktop-apps/.docker/desktop-apps.bake.Dockerfile"
  target     = "desktop-export"
  tags       = ["${REGISTRY}/desktop-export:${GIT_COMMIT}"]
  contexts = {
    desktop-builder = "target:desktop-builder"
  }
  output = ["type=docker"]
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

  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/packages"]  # reuses builder cache
}
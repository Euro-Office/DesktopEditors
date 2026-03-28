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
    PRODUCT_VERSION = "${PRODUCT_VERSION}"
    BUILD_ROOT      = "${BUILD_ROOT}"
    NUGET_CACHE     = "${NUGET_CACHE}"
    CACHE_BUST      = "${CACHE_BUST}"
  }
}

# ──────────────────────────────────────────────
# DEPENDENCY TARGETS
# ──────────────────────────────────────────────

target "core-base" {
  inherits   = ["_common"]
  context    = "."
  dockerfile = "./build/docker/core.Dockerfile"
  target     = "core-base"
  tags       = ["${REGISTRY}/core-base:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/core-base"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/core-base,mode=max"]
}

target "core-wasm" {
  inherits   = ["_common"]
  context    = "."
  dockerfile = "./build/docker/core-wasm.Dockerfile"
  tags       = ["${REGISTRY}/core-wasm:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/core-wasm"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/core-wasm,mode=max"]
}

target "web-base" {
  inherits   = ["_common"]
  context    = "."
  dockerfile = "./build/docker/web-base.Dockerfile"
  tags       = ["${REGISTRY}/web-base:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/web-base"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/web-base,mode=max"]
}

target "desktop-js" {
  inherits   = ["_common"]
  context    = "."
  dockerfile = "./build/docker/desktop-js.Dockerfile"
  tags       = ["${REGISTRY}/desktop-js:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/desktop-js"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/desktop-js,mode=max"]
  contexts = {
    web-base     = "target:web-base"
  }
}

target "sdkjs-desktop" {
  inherits   = ["_common"]
  context    = "."
  dockerfile = "./build/docker/sdkjs.Dockerfile"
  tags       = ["${REGISTRY}/sdkjs-desktop:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/sdkjs-desktop"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/sdkjs-desktop,mode=max"]
  contexts = {
    core-wasm    = "target:core-wasm"
    web-base     = "target:web-base"
  }
}

target "web-apps" {
  inherits   = ["_common"]
  context    = "."
  dockerfile = "./build/docker/web-apps.Dockerfile"
  tags       = ["${REGISTRY}/web-apps:${TAG}"]
  cache-from = ["type=local,src=/tmp/${REGISTRY}/web-apps"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/web-apps,mode=max"]
  contexts = {
    web-base     = "target:web-base"
  }
}

# ──────────────────────────────────────────────
# BUILD TARGET
# ──────────────────────────────────────────────

target "desktop-builder" {
  inherits   = ["_common"]
  context    = "."
  dockerfile = "./build/docker/desktop-apps.Dockerfile"
  target     = "desktop-builder"
  tags       = ["${REGISTRY}/desktop-builder:${TAG}"]
  contexts = {
    core-base     = "target:core-base"
    desktop-js    = "target:desktop-js"
    sdkjs-desktop = "target:sdkjs-desktop"
    web-apps      = "target:web-apps"
  }
  cache-from = ["type=local,src=/tmp/${REGISTRY}/desktop-builder"]
  cache-to   = ["type=local,dest=/tmp/${REGISTRY}/desktop-builder,mode=max"]
}

# ──────────────────────────────────────────────
# EXPORT TARGET
# ──────────────────────────────────────────────

target "desktop-export" {
  inherits   = ["_common"]
  context    = "."
  dockerfile = "./build/docker/desktop-apps.Dockerfile"
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
  output = ["type=local,dest=./dist/desktop"]

  cache-from = ["type=local,src=/tmp/${REGISTRY}/desktop-builder"]  # reuses builder cache
}
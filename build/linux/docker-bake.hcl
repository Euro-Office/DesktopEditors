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
  default = "dev.0"
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
  targets = ["packages"]
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

  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/third-party"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/third-party,mode=max"]
}


target "core-base" {
  inherits   = ["_common"]
  context    = "../.."
  dockerfile = "./core/.docker/core.bake.Dockerfile"
  target     = "core-base"
  tags       = ["${REGISTRY}/core-base:${TAG}"]
  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/core-base"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/core-base,mode=max"]
}

# ──────────────────────────────────────────────
# BUILD TARGET
# ──────────────────────────────────────────────

target "desktop-linux" {
  inherits   = ["_common"]
  context    = "../.."
  dockerfile = "./desktop-apps/.docker/desktop-apps.bake.Dockerfile"
  target     = "desktop-linux"
  tags       = ["${REGISTRY}/desktop-linux:${TAG}"]
  contexts = {
    desktop-common  = "docker-image://${REGISTRY}/desktop-common:${GIT_COMMIT}"
    core-base       = "target:core-base"
  }
  secret = [
    "id=nextcloud_user,env=NEXTCLOUD_USER",
    "id=nextcloud_pass,env=NEXTCLOUD_PASS",
  ]
  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/desktop-linux"]
  cache-to   = ["type=local,dest=./.docker-cache/${REGISTRY}/desktop-linux,mode=max"]
}

# ──────────────────────────────────────────────
# EXPORT TARGET
# ──────────────────────────────────────────────

target "packages" {
  inherits   = ["_common"]
  context    = "../.."
  dockerfile = "./build/.docker/packages.bake.Dockerfile"
  target     = "packages"       # points to the FROM scratch stage
  tags       = ["${REGISTRY}/packages:${TAG}"]
  contexts = {
    desktop-linux          = "target:desktop-linux"
  }

  # Export the filesystem directly to a local directory instead of an image
  output = ["type=local,dest=./deploy/packages"]

  cache-from = ["type=local,src=./.docker-cache/${REGISTRY}/packages"]  # reuses builder cache
}
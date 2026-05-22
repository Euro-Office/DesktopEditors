# ==============================================================================
# MODULE DOCKERFILE
# This file is not meant to be built standalone. It is consumed by the 
# docker-bake.hcl files in the parent monorepos.
#
# REQUIRED CONTEXTS:
# - bundle: bundled builds 
# ==============================================================================

#### PACKAGE ####

FROM ubuntu:24.04 AS package

    ARG COMPANY_NAME
    ARG COMPANY_NAME_LOW
    ARG PRODUCT_NAME
    ARG BRANDING_DIR
    ARG PRODUCT_VERSION
    ARG BUILD_NUMBER=0
    ARG OUT_BASE="/build/package/out"
    ARG BUNDLE_BASE="/build/bundle"
    ARG OUT_DIR="${BUNDLE_BASE}/${COMPANY_NAME_LOW}/desktopeditors"

    ENV PRODUCT_VERSION=${PRODUCT_VERSION}
    ENV COMPANY_NAME=${COMPANY_NAME}
    ENV PRODUCT_NAME=${PRODUCT_NAME}
    ENV BUILD_NUMBER=${BUILD_NUMBER}
    ENV OUT_BASE=${OUT_BASE}
    ENV BUNDLE_BASE=${BUNDLE_BASE}
    ENV OUT_DIR=${OUT_DIR}

    RUN apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            devscripts dpkg-dev build-essential fakeroot debhelper \
            rpm m4 curl ca-certificates gnupg symlinks && \
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
        apt-get install -y nodejs && \
        npm install -g @yao-pkg/pkg && \
        rm -rf /var/lib/apt/lists/*

    #Build files
    COPY --from=desktop-export / ${OUT_DIR}/

    # Upstream packaging repo
    COPY desktop-apps/package/ /desktop-editors-package/

    ### Branding
    COPY ${BRANDING_DIR}/desktop-apps/package/ /desktop-editors-package/
    ###

    RUN cd desktop-editors-package && \
        mkdir -p ${OUT_BASE} && \
        ln -s ${BUNDLE_BASE} ${OUT_BASE}/linux_64  && \
        ln -s ${BUNDLE_BASE} ${OUT_BASE}/linux_arm64 && \
        make deb rpm tar \
            BRANDING_DIR="." \
            BUILD_OUTPUT_DIR="${OUT_BASE}" \
            PRODUCT_VERSION="${PRODUCT_VERSION}" \
            PACKAGE_EDITION=opensource \
            BUILD_NUMBER="${BUILD_NUMBER}"

    RUN mkdir -p /packages && \
        find /desktop-editors-package/deb -name "*.deb"    -exec cp -v {} /packages/ \;  && \
        find /desktop-editors-package/rpm -name "*.rpm"    -exec cp -v {} /packages/ \;  && \
        find /desktop-editors-package/tar -name "*.tar.xz" -exec cp -v {} /packages/ \;

#### PACKAGES OUTPUT ####
# Scratch stage so `docker build --target packages -o <dir>` extracts only
# the finished .deb and .rpm files.
FROM scratch AS packages
    COPY --from=package /packages/ /
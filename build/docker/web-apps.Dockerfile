ARG PRODUCT_VERSION
ARG BUILD_ROOT

#### WEB-APPS ####
FROM web-base AS web-apps
    ARG PRODUCT_VERSION
    ARG BUILD_ROOT=/package

    COPY web-apps/build/package*.json /app/build/
    COPY web-apps/build/sprites/package*.json /app/build/sprites/
    COPY web-apps/build/plugins/grunt-inline/ /app/build/plugins/grunt-inline/

    RUN --mount=type=cache,target=/root/.npm \
        cd app/build && \
        npm install


    COPY web-apps/ /app

    ENV PRODUCT_VERSION=${PRODUCT_VERSION}
    ENV BUILD_ROOT=${BUILD_ROOT}

    ARG TARGETARCH
    RUN cd app/build && \
        THEME=nextcloud grunt $(if [ "$TARGETARCH" = "arm64" ]; then echo "--skip-imagemin"; fi)
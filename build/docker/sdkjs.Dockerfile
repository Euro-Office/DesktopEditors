ARG PRODUCT_VERSION
ARG BUILD_ROOT

#### SDKJS ####
FROM web-base AS sdkjs-base

    ARG BUILD_ROOT=/package

    ARG PRODUCT_VERSION

    COPY sdkjs/build/package*.json /app/build/

    RUN --mount=type=cache,target=/root/.npm \
        cd app/build && \
        npm install

    COPY sdkjs/ /app
    COPY sdkjs-forms/ /sdkjs-forms

    ENV BUILD_ROOT=${BUILD_ROOT}

    ENV PRODUCT_VERSION=${PRODUCT_VERSION}

    ## Copy core wasm builds
    COPY --from=core-wasm ${BUILD_ROOT}/engine/ /app/pdf/src/engine/
    COPY --from=core-wasm ${BUILD_ROOT}/zlib/ /app/common/zlib/
    COPY --from=core-wasm ${BUILD_ROOT}/hash/ /app/common/hash/
    COPY --from=core-wasm ${BUILD_ROOT}/spell/ /app/common/spell/
    COPY --from=core-wasm ${BUILD_ROOT}/libfont/ /app/common/libfont/

FROM sdkjs-base AS sdkjs-desktop
    ARG TARGETARCH
    RUN cd app/build && \
        CC_PLATFORM=$(if [ "$TARGETARCH" = "arm64" ]; then echo "java"; else echo "native,java"; fi) grunt --addon=sdkjs-forms --desktop=true

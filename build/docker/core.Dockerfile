ARG NUGET_CACHE
ARG BUILD_ROOT
ARG NUGET_SOURCE_PATH

#### VCPKG BASE ####
FROM ubuntu:24.04 AS vcpkg-base

    # Avoid interactive prompts during package install
    ENV DEBIAN_FRONTEND=noninteractive

    # Install system dependencies
    RUN apt-get update && apt-get install -y \
        ca-certificates \
        git \
        curl \
        zip \
        unzip \
        tar \
        build-essential \
        pkg-config \
        cmake \
        ninja-build \
        mono-devel \
        && rm -rf /var/lib/apt/lists/*

    # Install vcpkg
    WORKDIR /opt
    RUN git clone https://github.com/microsoft/vcpkg.git \
        && cd vcpkg \
        && ./bootstrap-vcpkg.sh

    # Make vcpkg available globally
    ENV VCPKG_ROOT=/opt/vcpkg
    ENV PATH="${VCPKG_ROOT}:${PATH}"

    ENV VCPKG_BINARY_SOURCES="clear;nuget,NuGetCache,readwrite;nugettimeout,3600"


FROM vcpkg-base AS vcpkg-local

    RUN vcpkg fetch nuget && \
        mkdir /nuget-cache && \
        mono $(vcpkg fetch nuget) sources add \
            -Source "/nuget-cache" \
            -Name "NuGetCache"


FROM vcpkg-base AS vcpkg-remote

    ARG NUGET_REMOTE_URL
    ARG NUGET_USERNAME
    ARG NUGET_PASSWORD

    RUN vcpkg fetch nuget && \
        mono $(vcpkg fetch nuget) sources add \
            -Source "${NUGET_REMOTE_URL}" \
            -Name "NuGetCache" \
            -Username "${NUGET_USERNAME}" \
            -Password "${NUGET_PASSWORD}" \
            -StorePasswordInClearText



#### CORE BASE ####
FROM vcpkg-${NUGET_CACHE} AS core-base
    ARG BUILD_ROOT=/package
    ARG TARGETARCH

    ENV TZ=Etc/UTC
    ENV DEBIAN_FRONTEND=noninteractive
    ENV PLEASE_PRELOAD_LIBSTDCPP=true

    RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
        apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            git curl sudo wget ssh \
            build-essential make cmake ninja-build pkg-config \
            libglib2.0-dev \
            python3 python-is-python3 python3-venv python3-setuptools \
            python3-httplib2 \
            lsb-release libboost-all-dev findutils \
            gn \
        && rm -rf /var/lib/apt/lists/*

    # clang-13 required for V8 9.x — only available on jammy (22.04), not noble (24.04)
    RUN wget -qO - https://apt.llvm.org/llvm-snapshot.gpg.key | \
        gpg --dearmor -o /etc/apt/keyrings/llvm-snapshot.gpg && \
        echo "deb [signed-by=/etc/apt/keyrings/llvm-snapshot.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-13 main" \
        > /etc/apt/sources.list.d/llvm-13.list && \
        apt-get update && apt-get install -y \
            clang-13 lld-13 llvm-13-dev llvm-13 \
            libc++-13-dev libc++abi-13-dev \
            qemu-user-static binfmt-support && \
        rm -rf /var/lib/apt/lists/*

    # set clang 13 as standard
    RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-13 100 && \
        update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-13 100 && \
        update-alternatives --install /usr/bin/llvm-ar llvm-ar /usr/bin/llvm-ar-13 100 && \
        update-alternatives --install /usr/bin/llvm-nm llvm-nm /usr/bin/llvm-nm-13 100 && \
        update-alternatives --install /usr/bin/llvm-ranlib llvm-ranlib /usr/bin/llvm-ranlib-13 100 && \
        update-alternatives --install /usr/bin/lld lld /usr/bin/lld-13 100


    ENV PATH="/root/.cargo/bin:${PATH}"

    # Git needs to allow repo paths copied by Docker
    RUN git config --global --add safe.directory '*'

    # upstream behavior — unchanged
    COPY core /core

    ENV BUILD_ROOT=${BUILD_ROOT}


#### CORE ####
FROM core-base AS core
    RUN --mount=type=cache,target=/build-cache \
        --mount=type=bind,source=${NUGET_SOURCE_PATH},target=/nuget-cache,rw <<EOF
        set -e
        mkdir -p ${BUILD_ROOT}
        cd /build-cache

        cmake -GNinja \
        -DVCPKG_MANIFEST_MODE=ON \
        -DVCPKG_MANIFEST_DIR=/core \
        -DVCPKG_TARGET_TRIPLET=x64-linux-dynamic \
        -DCMAKE_TOOLCHAIN_FILE=/opt/vcpkg/scripts/buildsystems/vcpkg.cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS_RELEASE="-O3 -w" \
        -DCMAKE_C_FLAGS_RELEASE="-O3 -w" \
        -DEO_CORE_OUTPUT_DIR=${BUILD_ROOT}/bin \
        -DEO_CORE_TOOLS_DIR=${BUILD_ROOT}/tools \
        /core

        cmake --build .
EOF

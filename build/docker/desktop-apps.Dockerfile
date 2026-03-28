ARG PRODUCT_VERSION
ARG CACHE_BUST
ARG BUILD_ROOT

#### DESKTOP-APPS
FROM core-base AS desktop-builder

    RUN apt-get -y update && \
        apt-get -y upgrade && \ 
        apt-get -y install \
                    libgtk-3-dev \
                    libatk1.0-dev \
                    libxkbcommon-x11-dev \
                    python3-venv \
                    bison \
                    libnotify-dev \
                    libcups2-dev \
                    libdbus-1-dev \
                    libxcb-util0-dev \
                    libxcb-xkb-dev \
                    libxcb-cursor-dev \
                    libxcb-xinput-dev \
                    build-essential \
                    ninja-build \
                    pkg-config \
                    libx11-dev \
                    libx11-xcb-dev \
                    libxcb1-dev \
                    libxcb-render0-dev \
                    libxcb-shape0-dev \
                    libxcb-xfixes0-dev \
                    libxcb-randr0-dev \
                    libxcb-keysyms1-dev \
                    libxcb-image0-dev \
                    libxcb-icccm4-dev \
                    libxcb-sync-dev \
                    libxcb-xinerama0-dev \
                    libxcb-util-dev \
                    libxrender-dev \
                    libxi-dev \
                    libxkbcommon-dev \
                    libxkbcommon-x11-dev \
                    libgl1-mesa-dev \
                    libegl1-mesa-dev \
                    libasound2-dev \
                    libpulse-dev

    COPY desktop-sdk /desktop-sdk
    COPY desktop-apps /desktop-apps
    COPY core-fonts /core-fonts

    COPY --from=desktop-js /app/loginpage/deploy /desktop-apps/common/loginpage/deploy
    #COPY gcc_64 /qt5

    ARG CACHE_BUST=1

    ARG PRODUCT_VERSION

    ENV PRODUCT_VERSION=${PRODUCT_VERSION}

    RUN --mount=type=cache,target=/build-cache-desktop,id=build-cache-desktop-${CACHE_BUST} \
        --mount=type=cache,target=/nuget-cache,id=nuget-cache-${CACHE_BUST} \
        cd /build-cache-desktop && \
        cmake -GNinja -DVCPKG_TARGET_TRIPLET=x64-linux-dynamic \
              -DCMAKE_TOOLCHAIN_FILE=/opt/vcpkg/scripts/buildsystems/vcpkg.cmake \
              -DVCPKG_MANIFEST_MODE=ON \
              -DVCPKG_MANIFEST_DIR="/core" \
              /desktop-apps/win-linux/ && \
        cmake --build . && \
        cmake --install . && \
        cp -a desktopeditors /desktopeditors
    
    COPY --from=sdkjs-desktop ${BUILD_ROOT} /desktopeditors/editors/
    COPY --from=web-apps ${BUILD_ROOT} /desktopeditors/editors/

    COPY --from=desktop-js /app/loginpage/deploy/index.html /desktopeditors/index.html
    COPY --from=desktop-js /app/loginpage/deploy/noconnect.html /desktopeditors/editors/webext/noconnect.html

    COPY web-apps/apps/api/documents/index.html.desktop /desktopeditors/editors/web-apps/apps/api/documents/index.html
    
    COPY desktop-apps/common/converter/* /desktopeditors/converter/
    COPY desktop-apps/common/loginpage/providers /desktopeditors/providers
    COPY desktop-apps/common/templates /desktopeditors/converter/templates

    COPY build/configs/core/DoctRenderer.config.desktop /desktopeditors/converter/DoctRenderer.config
    
    COPY document-templates/new /desktopeditors/converter/empty

    COPY dictionaries/ /desktopeditors/dictionaries
    

    COPY core-fonts/opensans   /desktopeditors/fonts
    COPY core-fonts/asana      /desktopeditors/fonts/asana
    COPY core-fonts/caladea    /desktopeditors/fonts/caladea
    COPY core-fonts/crosextra  /desktopeditors/fonts/crosextra
    COPY core-fonts/openoffice /desktopeditors/fonts/openoffice
    COPY core-fonts/ASC.ttf    /desktopeditors/fonts/ASC.ttf

    RUN /desktopeditors/converter/allfontsgen \
        --use-system=1 \
        --input=/desktopeditors/fonts \
        --input=/core-fonts \
        --allfonts=/desktopeditors/converter/AllFonts.js \
        --selection=/desktopeditors/converter/font_selection.bin 
    
    RUN /desktopeditors/converter/allthemesgen \
        --converter-dir=/desktopeditors/converter \
        --src=/desktopeditors/editors/sdkjs/slide/themes \
        --allfonts=/desktopeditors/converter/AllFonts.js \
        --output=/desktopeditors/editors/sdkjs/common/Images

    RUN echo 'LD_LIBRARY_PATH=$PWD:$PWD/converter:$LD_LIBRARY_PATH LD_PRELOAD=libcef.so ./DesktopEditors' > /desktopeditors/start_desktop.sh && \
        chmod +x /desktopeditors/start_desktop.sh

FROM scratch AS desktop-export
    COPY --from=desktop-builder /desktopeditors /
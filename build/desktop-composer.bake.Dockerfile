# ==============================================================================
# MODULE DOCKERFILE
# This file is not meant to be built standalone. It is consumed by the 
# docker-bake.hcl file in this monorepo.
# ==============================================================================

FROM desktop-builder AS desktop-composer

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
    COPY --from=desktop-composer /desktopeditors /
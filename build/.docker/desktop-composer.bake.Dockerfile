# ==============================================================================
# MODULE DOCKERFILE
# This file is not meant to be built standalone. It is consumed by the 
# docker-bake.hcl file in this monorepo.
# ==============================================================================

FROM scratch AS desktop-common
    ARG BUILD_ROOT

    COPY --from=sdkjs-desktop ${BUILD_ROOT} /editors/
    COPY --from=web-apps ${BUILD_ROOT} /editors/

    COPY --from=desktop-js /app/loginpage/deploy/index.html /index.html
    COPY --from=desktop-js /app/loginpage/deploy/noconnect.html /editors/webext/noconnect.html

    COPY web-apps/apps/api/documents/index.html.desktop /editors/web-apps/apps/api/documents/index.html
    
    COPY desktop-apps/common/converter/* /converter/
    # Support only Nextcloud for now
    COPY desktop-apps/common/loginpage/providers/nextcloud /providers/nextcloud
    COPY desktop-apps/common/templates /converter/templates

    COPY desktop-sdk/ChromiumBasedEditors/resources/ /editors/sdkjs/common/Images/

    COPY build/configs/core/DoctRenderer.config.desktop /converter/DoctRenderer.config
    
    COPY document-templates/new /converter/empty

    COPY dictionaries/ /dictionaries
    

    COPY core-fonts/opensans   /fonts
    COPY core-fonts/asana      /fonts/asana
    COPY core-fonts/caladea    /fonts/caladea
    COPY core-fonts/crosextra  /fonts/crosextra
    COPY core-fonts/openoffice /fonts/openoffice
    COPY core-fonts/ASC.ttf    /fonts/ASC.ttf

    # Create sdkjs-plugins dir in scratch image
    WORKDIR /editors/sdkjs-plugins

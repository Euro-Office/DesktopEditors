FROM web-base AS desktop-js

    COPY desktop-apps/common app

    RUN cd app/loginpage/build && \
        npm install && \
        grunt
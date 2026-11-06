# SPDX-FileCopyrightText: 2026 Euro-Office contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Installs a desktop editors .deb on a minimal Ubuntu LTS, as a user would,
# and runs the smoke tests against it. The package comes from the "package"
# build context, a directory with exactly one .deb (see run.sh).

FROM node:20-bookworm-slim AS deps
WORKDIR /smoke
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM ubuntu:24.04
# Only what the tests need; everything the app needs has to come from the
# package's own dependencies.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xvfb xauth x11-apps imagemagick unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,from=package,target=/package \
    apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /package/*.deb \
    && rm -rf /var/lib/apt/lists/*

COPY --from=deps /usr/local/bin/node /usr/local/bin/node
COPY --from=deps /smoke/node_modules /smoke/node_modules
COPY lib /smoke/lib
COPY fixtures /smoke/fixtures
COPY smoke.test.js /smoke/

# As root the app opens a warning dialog before starting, so run as a user
RUN useradd -m tester && mkdir /results && chown tester /results
USER tester
WORKDIR /smoke
ENV RESULTS_DIR=/results
CMD ["node", "--test", "--test-reporter=spec", "--test-concurrency=1", "smoke.test.js"]

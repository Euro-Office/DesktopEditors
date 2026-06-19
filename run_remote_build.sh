#!/bin/bash

# Replace this with your actual SSH connection string (e.g., ssh://username@192.168.1.50)
REMOTE_HOST="ssh://user@server"

echo "Connecting to $REMOTE_HOST to run BUILDKIT_STEP_LOG_MAX_SIZE=-1 docker buildx bake..."
echo "This will capture the entire output to build_output.log so the AI can read it."

cd build && rm -rf ../build_output.log && DOCKER_HOST="$REMOTE_HOST" BUILDX_BAKE_ENTITLEMENTS_FS=0 BUILDKIT_STEP_LOG_MAX_SIZE=-1 docker buildx bake --allow=fs=./.docker-cache/euro-office/desktop-js --allow=fs=./.docker-cache/euro-office/web-apps --allow=fs=./.docker-cache/euro-office/core-base --allow=fs=./.docker-cache/euro-office/desktop-builder --allow=fs.read=.. > ../build_output.log 2>&1
cd ..
echo "Build complete! The output has been saved to build_output.log."

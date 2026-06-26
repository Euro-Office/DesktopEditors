 #!/bin/bash

# Replace this with your actual SSH connection string (e.g., ssh://username@192.168.1.50)
REMOTE_HOST="ssh://pplupo@server"

echo "Connecting to $REMOTE_HOST to run BUILDKIT_STEP_LOG_MAX_SIZE=-1 docker buildx bake..."
echo "This will capture the entire output to build_output.log so the AI can read it."

cd build && rm -rf ../build_output.log && DOCKER_HOST="$REMOTE_HOST" GIT_COMMIT=$(git rev-parse HEAD) TAG=latest BUILDX_BAKE_ENTITLEMENTS_FS=0 BUILDKIT_STEP_LOG_MAX_SIZE=-1 docker buildx bake \
  --allow=fs.read=.. \
  --set desktop-export.output="type=tar,dest=./deploy/desktop.tar" \
  desktop-export > ../build_output.log 2>&1
cd ..

mkdir -p build/deploy/desktop
tar -xf build/deploy/desktop.tar -C build/deploy/desktop

echo "Build complete! The output has been saved to build_output.log."

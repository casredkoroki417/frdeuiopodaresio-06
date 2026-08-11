#!/usr/bin/env bash
set -e

# Capture starting directory
START_DIR=$(pwd)

SLOT=$1
if [ -z "$SLOT" ]; then
  SLOT=1
fi

echo "========================================="
echo " Starting V4 Runner for Slot $SLOT "
echo "========================================="

# Common function to run container (defined FIRST)
run_container() {
    echo -e "\n=== Running Container ==="
    echo "Running with custom flags:"
    echo "  --shm-size=4g"
    echo "  -e MIN_SLEEP_MINUTES=15"
    echo "  -e MAX_SLEEP_MINUTES=50"
    echo "  -e SKIP_RANDOM_SLEEP=true"
    echo "  --env-file .env"

    # Process config.json Override right before running
    # CRITICAL FIX: We MUST always mount the config directory even if there is no override,
    # otherwise the container's entrypoint crashes trying to copy the example file into a missing folder!
    mkdir -p config
    CONFIG_OVERRIDE=$(jq -r ".config_override_$SLOT" runner_env.json)
    if [ "$CONFIG_OVERRIDE" != "null" ] && [ -n "$CONFIG_OVERRIDE" ]; then
        echo "$CONFIG_OVERRIDE" > config/config.json
        echo "[!] Applied custom config.json override from MSR-Database."
    else
        echo "[-] Using default config settings. (Mounted empty config dir to prevent crash)"
    fi
    VOLUME_MOUNT="-v $(pwd)/config:/usr/src/microsoft-rewards-script/config"

    # Run container in detached mode (Passing .env so the container gets the Bootstrapper variables)
    CONTAINER_ID=$(docker run -d \
      --shm-size=4g \
      -e MIN_SLEEP_MINUTES=15 \
      -e MAX_SLEEP_MINUTES=50 \
      -e SKIP_RANDOM_SLEEP=true \
      --env-file .env \
      $VOLUME_MOUNT \
      $FINAL_IMAGE)

    echo "Container started with ID: $CONTAINER_ID"

    # Stream logs to console so we can see what's happening
    docker logs -f $CONTAINER_ID

    # Wait for container to finish
    docker wait $CONTAINER_ID

    echo "Container execution finished."

    # Cleanup
    echo "Cleaning up container..."
    docker rm -f $CONTAINER_ID || true
}

# Process Docker Image/Dockerfile Override
DOCKER_OVERRIDE=$(jq -r ".docker_override_$SLOT" runner_env.json)

if [ "$DOCKER_OVERRIDE" != "null" ] && [ -n "$DOCKER_OVERRIDE" ]; then
    # Check if the override looks like a full Dockerfile (starts with FROM or contains FROM)
    if echo "$DOCKER_OVERRIDE" | grep -qE "(^|\n)FROM "; then
        echo "[!] Detected full Dockerfile override. Building custom image locally..."
        echo "$DOCKER_OVERRIDE" > Dockerfile.custom
        
        # Find the FROM line and extract the image name
        BASE_IMAGE=$(grep -m1 '^FROM' Dockerfile.custom | sed 's/^FROM //' | tr -d '[:space:]')
        
        if [ -z "$BASE_IMAGE" ]; then
            echo "ERROR: Could not find base image in custom Dockerfile!"
            exit 1
        fi
        
        echo "Found base image in Dockerfile: $BASE_IMAGE"
        SHOULD_BUILD=true
    else
        echo "[!] Using custom Docker image tag: $DOCKER_OVERRIDE"
        FINAL_IMAGE="$DOCKER_OVERRIDE"
        SHOULD_BUILD=false
    fi
else
    echo "[-] Using default Docker image."
    FINAL_IMAGE="ghcr.io/thenetsky/microsoft-rewards-script:4"
    SHOULD_BUILD=false
fi

if [ "$SHOULD_BUILD" = false ]; then
    echo "Skipping build phase. Proceeding to run..."
    run_container
    exit 0
fi

echo "=== Phase 1: Try normal build first ==="
NORMAL_SUCCESS=false

# Try normal build 3 times
for attempt in {1..3}; do
    echo "Normal build attempt $attempt of 3..."
    if docker build -t myimage:latest -f Dockerfile.custom .; then
        echo "✅ Normal build successful!"
        NORMAL_SUCCESS=true
        break
    else
        if [ $attempt -lt 3 ]; then
            echo "Normal build failed, retrying in 5 seconds..."
            sleep 5
        fi
    fi
done

# If normal build succeeded, skip to run
if [ "$NORMAL_SUCCESS" = true ]; then
    echo "Build successful! Proceeding to run..."
    FINAL_IMAGE="myimage:latest"
    run_container
    exit 0
fi

echo -e "\n=== Phase 2: Normal build failed, trying optimized approach ==="

# 1. Increase Docker timeouts
echo "Increasing Docker timeouts..."
sudo tee /etc/docker/daemon.json << EOF2
{
  "max-concurrent-downloads": 1,
  "max-download-attempts": 5,
  "dns": ["8.8.8.8", "1.1.1.1"]
}
EOF2
sudo systemctl restart docker || sudo service docker restart

# 2. Pre-pull the base image with retry (using extracted image name)
echo "Pre-pulling base image..."
echo "Base image to pull: $BASE_IMAGE"

for attempt in {1..5}; do
    echo "Pull attempt $attempt of 5..."
    if docker pull "$BASE_IMAGE"; then
        echo "Successfully pulled base image"
        break
    else
        if [ $attempt -eq 5 ]; then
            echo "All pull attempts failed. Trying alternative approach..."
            # Continue anyway, build might use cache
        else
            echo "Pull failed, retrying in 15 seconds..."
            sleep 15
        fi
    fi
done

# 3. Build with retry logic
echo "Building Docker image..."
for attempt in {1..3}; do
    echo "Build attempt $attempt of 3..."

    # Enable BuildKit for better caching
    DOCKER_BUILDKIT=1 docker build \
        --progress=plain \
        --no-cache \
        -f Dockerfile.custom \
        -t myimage:latest . && break

    if [ $attempt -lt 3 ]; then
        echo "Build failed, cleaning cache and retrying in 10 seconds..."
        docker builder prune -f
        sleep 10
    else
        echo "All build attempts failed!"
        exit 1
    fi
done

echo "Build successful!"

FINAL_IMAGE="myimage:latest"
# Call the common run function
run_container

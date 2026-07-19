#! /bin/bash
set -euo pipefail

# All output → system journal, tag "mo-startup" (debug with: sudo journalctl -t mo-startup)
exec > >(logger -t mo-startup) 2>&1

# Mode: "all" (default, boot) or "backend-only" (deploys)
MODE="${1:-all}"

echo "=== mo-prod-vm startup script starting (mode=${MODE}) at $(date -u) ==="

# ---------------------------------------------------------------------------
# Start Typesense (search engine)
# ---------------------------------------------------------------------------
start_typesense() {
  local image="typesense/typesense:28.0"
  local data_dir="/home/ahamedmaam/typesense-data"

  echo "Removing any existing container named 'typesense'..."
  docker rm -f typesense 2>/dev/null || true

  echo "Starting Typesense container..."
  docker run -d \
    --name typesense \
    --restart=unless-stopped \
    -p 8108:8108 \
    -v "${data_dir}:/data" \
    "$image" \
    --data-dir /data \
    --api-key=<> \
    --enable-cors

  echo "Typesense container started."
}

# ---------------------------------------------------------------------------
# Start the backend (image reference read from VM metadata)
# ---------------------------------------------------------------------------
start_backend() {
  local metadata_url="http://metadata.google.internal/computeMetadata/v1/instance/attributes/mo-backend-image"

  # Configure Docker to authenticate to GCR using the VM's service account.
  # konlet used to do this internally; without it, pulls are anonymous and denied.
  # COS's root filesystem is read-only (/root/.docker is unwritable), so Docker's
  # config must live somewhere writable — hence DOCKER_CONFIG. Idempotent, runs every boot.
  echo "Configuring GCR authentication..."
  export DOCKER_CONFIG=/var/lib/mo-docker
  mkdir -p "$DOCKER_CONFIG"
  docker-credential-gcr configure-docker --registries=gcr.io

  echo "Fetching backend image reference from metadata..."
  local backend_image
  backend_image="$(curl -sf -H "Metadata-Flavor: Google" "$metadata_url")"
  echo "Backend image resolved to: ${backend_image}"

  echo "Pulling backend image..."
  docker pull "$backend_image"

  echo "Removing any existing backend container named 'mo-backend'..."
  docker rm -f mo-backend 2>/dev/null || true

  echo "Starting backend container..."
  docker run -d \
    --name mo-backend \
    --network=host \
    --privileged \
    --restart=on-failure \
    --log-opt max-size=500m \
    --log-opt max-file=3 \
    -t -i \
    "$backend_image"

  echo "Backend container started."
}

# ---------------------------------------------------------------------------
# Dispatch based on mode
# ---------------------------------------------------------------------------
case "$MODE" in
  all)
    start_typesense
    start_backend
    ;;
  backend-only)
    start_backend
    ;;
  *)
    echo "ERROR: unknown mode '${MODE}' (expected 'all' or 'backend-only')" >&2
    exit 1
    ;;
esac

echo "=== mo-prod-vm startup script completed (mode=${MODE}) at $(date -u) ==="
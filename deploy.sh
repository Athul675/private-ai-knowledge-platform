#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Private AI Knowledge Platform deployment
# Target: NVIDIA GB10 / ARM64
# Project: private-ai-knowledge-platform
# ============================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PROJECT_NAME="private-ai-knowledge-platform"
STARTUP_TIMEOUT=180
STARTUP_INTERVAL=10

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

info() {
  printf '\n[INFO] %s\n' "$*"
}

warn() {
  printf '\n[WARN] %s\n' "$*" >&2
}

error() {
  printf '\n[ERROR] %s\n' "$*" >&2
}

die() {
  error "$*"
  exit 1
}

# ------------------------------------------------------------
# 1. Check prerequisites
# ------------------------------------------------------------

info "Checking prerequisites..."

command -v docker >/dev/null 2>&1 \
  || die "Docker is not installed or is not in PATH."

docker compose version >/dev/null 2>&1 \
  || die "Docker Compose plugin is unavailable."

command -v python3 >/dev/null 2>&1 \
  || die "Python 3 is required to configure WEBUI_SECRET_KEY."

command -v curl >/dev/null 2>&1 \
  || die "curl is required for readiness checks."

docker info >/dev/null 2>&1 \
  || die "Cannot communicate with the Docker daemon. Check Docker permissions and service status."

# ------------------------------------------------------------
# 2. Prepare .env without overwriting existing configuration
# ------------------------------------------------------------

info "Checking environment configuration..."

if [[ ! -f "$ROOT/.env" ]]; then
  [[ -f "$ROOT/.env.example" ]] \
    || die ".env.example is missing."

  cp "$ROOT/.env.example" "$ROOT/.env"
  chmod 600 "$ROOT/.env"

  info "Created .env from .env.example."
else
  info "Existing .env found; preserving its configuration."
fi

# Restrict permissions even when .env already existed.
chmod 600 "$ROOT/.env"

# Generate a persistent secret only when no nonempty key exists.
# Never print the secret or any other environment variable.
python3 - <<'PY'
import secrets
from pathlib import Path

path = Path(".env")
key_name = "WEBUI_SECRET_KEY="

lines = path.read_text().splitlines()

existing_values = [
    line[len(key_name):].strip()
    for line in lines
    if line.startswith(key_name)
]

nonempty_values = [
    value for value in existing_values
    if value
]

if nonempty_values:
    # Preserve the first configured nonempty secret and remove
    # duplicate WEBUI_SECRET_KEY entries to avoid ambiguity.
    secret = nonempty_values[0]

    lines = [
        line for line in lines
        if not line.startswith(key_name)
    ]
    lines.append(key_name + secret)

    print("WEBUI_SECRET_KEY already configured; preserving it.")
else:
    # Remove empty or duplicate definitions and create a new key.
    lines = [
        line for line in lines
        if not line.startswith(key_name)
    ]
    lines.append(key_name + secrets.token_hex(32))

    print("Generated a new persistent WEBUI_SECRET_KEY.")

path.write_text("\n".join(lines) + "\n")
path.chmod(0o600)
PY

# ------------------------------------------------------------
# 3. Check required Compose files
# ------------------------------------------------------------

info "Checking deployment files..."

REQUIRED_FILES=(
  "$ROOT/opea/compose.yaml"
  "$ROOT/opea/compose.vllm.override.yaml"
  "$ROOT/compose.app.yaml"
)

for file in "${REQUIRED_FILES[@]}"; do
  [[ -f "$file" ]] || die "Required Compose file is missing: $file"
done

# ------------------------------------------------------------
# 4. Define the complete Compose project
# ------------------------------------------------------------

COMPOSE=(
  docker compose
  --project-name "$PROJECT_NAME"
  --env-file "$ROOT/.env"
  -f "$ROOT/opea/compose.yaml"
  -f "$ROOT/opea/compose.vllm.override.yaml"
  -f "$ROOT/compose.app.yaml"
)

# ------------------------------------------------------------
# 5. Validate merged Compose configuration
# ------------------------------------------------------------

info "Validating merged Docker Compose configuration..."

if ! "${COMPOSE[@]}" config --quiet; then
  die "Compose validation failed. Fix the configuration before deploying."
fi

info "Compose configuration is valid."

# ------------------------------------------------------------
# 6. Start services
# ------------------------------------------------------------

info "Starting Private AI Knowledge Platform..."
info "Docker may build local images or download required images."

if ! "${COMPOSE[@]}" up -d --build; then
  error "One or more services failed to start."
  echo
  echo "Current service status:"
  "${COMPOSE[@]}" ps || true

  echo
  echo "Recent service logs:"
  "${COMPOSE[@]}" logs --tail 80 || true

  die "Deployment startup failed. Review the logs above."
fi

# ------------------------------------------------------------
# 7. Wait for vLLM API readiness
# ------------------------------------------------------------

info "Waiting for the vLLM API at 127.0.0.1:8000..."
info "Model loading can take several minutes."

VLLM_READY=0

for ((i = 1; i <= STARTUP_TIMEOUT; i++)); do
  if curl \
    --fail \
    --silent \
    --show-error \
    --max-time 5 \
    http://127.0.0.1:8000/v1/models \
    >/dev/null 2>&1; then

    VLLM_READY=1
    break
  fi

  if (( i % 6 == 0 )); then
    info "Still waiting for vLLM ($((i * STARTUP_INTERVAL / 60)) minutes elapsed)..."
  fi

  sleep "$STARTUP_INTERVAL"
done

if [[ "$VLLM_READY" -ne 1 ]]; then
  error "vLLM did not become ready within the configured timeout."

  echo
  echo "vLLM service status:"
  "${COMPOSE[@]}" ps rag-llm || true

  echo
  echo "Recent vLLM logs:"
  "${COMPOSE[@]}" logs --tail 120 rag-llm || true

  die "vLLM readiness check failed. Other services have been left running for diagnosis."
fi

info "vLLM API is responding."

# ------------------------------------------------------------
# 8. Check DataPrep health
# ------------------------------------------------------------

info "Checking OPEA DataPrep health..."

DATAPREP_CONTAINER_ID="$("${COMPOSE[@]}" ps -q dataprep-redis-service)"

if [[ -z "$DATAPREP_CONTAINER_ID" ]]; then
  error "DataPrep container was not found."
  "${COMPOSE[@]}" ps || true
  "${COMPOSE[@]}" logs --tail 100 dataprep-redis-service || true
  die "DataPrep readiness check failed. Services have been left running for diagnosis."
fi

DATAPREP_READY=0
DATAPREP_HEALTH_STATUS="unknown"

for ((attempt = 1; attempt <= STARTUP_TIMEOUT; attempt++)); do
  DATAPREP_HEALTH_STATUS="$(
    docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
      "$DATAPREP_CONTAINER_ID" 2>/dev/null || printf 'unavailable'
  )"

  if [[ "$DATAPREP_HEALTH_STATUS" == "healthy" ]]; then
    DATAPREP_READY=1
    break
  fi

  if (( attempt % 6 == 0 )); then
    info "Waiting for DataPrep health: ${DATAPREP_HEALTH_STATUS} (${attempt}/${STARTUP_TIMEOUT})"
  fi

  sleep "$STARTUP_INTERVAL"
done

if [[ "$DATAPREP_READY" -ne 1 ]]; then
  error "DataPrep did not become healthy within the configured timeout."
  echo "Last reported health status: $DATAPREP_HEALTH_STATUS"

  echo
  echo "Current service status:"
  "${COMPOSE[@]}" ps || true

  echo
  echo "Recent DataPrep logs:"
  "${COMPOSE[@]}" logs --tail 100 dataprep-redis-service || true

  die "DataPrep readiness check failed. Services have been left running for diagnosis."
fi

info "DataPrep health check passed."

# ------------------------------------------------------------
# 9. Display final service status
# ------------------------------------------------------------

echo
info "Initial readiness checks passed."

echo "Project:       $PROJECT_NAME"
echo "Portal:        http://<SERVER-IP>/"
echo "AI Assistant:  http://<SERVER-IP>:3000/"
echo "Knowledge UI:  http://<SERVER-IP>:8098/"
echo
echo "Local API endpoints:"
echo "vLLM:          http://127.0.0.1:8000/v1/models"
echo "Adapter:       http://127.0.0.1:8099/"
echo "DataPrep:      Docker-internal only (no host port published)"
echo
echo "Check service status with:"
echo "  ./status.sh"
echo
echo "Note: These readiness checks do not prove that document retrieval,"
echo "embedding, reranking, and end-to-end RAG responses all work."
echo

"${COMPOSE[@]}" ps

echo
info "Deployment startup checks completed."

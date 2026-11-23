#!/usr/bin/env bash
set -euo pipefail

# Chạy trên Actions runner; truyền image vào script trên VPS.
environment="${1:?Missing environment}"
frontend_image="${2:-}"
backend_image="${3:-}"

# Tách biệt hoàn toàn biến SSH giữa staging và production, tránh fallback im lặng.
case "$environment" in
  staging)
    if [[ -n "${PRODUCTION_VPS_HOST:-}" || -n "${PRODUCTION_VPS_USER:-}" || \
          -n "${PRODUCTION_VPS_SSH_KEY:-}" || -n "${PRODUCTION_VPS_KNOWN_HOSTS:-}" ]]; then
      echo "ERROR: Production SSH secrets must not be passed to a staging deployment." >&2
      exit 1
    fi
    ssh_host="${VPS_HOST:?Missing VPS_HOST}"
    ssh_user="${VPS_USER:?Missing VPS_USER}"
    ssh_key="${VPS_SSH_KEY:?Missing VPS_SSH_KEY}"
    ssh_known_hosts="${VPS_KNOWN_HOSTS:?Missing VPS_KNOWN_HOSTS}"
    ;;
  production)
    if [[ -n "${VPS_HOST:-}" || -n "${VPS_USER:-}" || \
          -n "${VPS_SSH_KEY:-}" || -n "${VPS_KNOWN_HOSTS:-}" ]]; then
      echo "ERROR: Staging VPS_* secrets must not be passed to a production deployment." >&2
      exit 1
    fi
    ssh_host="${PRODUCTION_VPS_HOST:?Missing PRODUCTION_VPS_HOST in production environment}"
    ssh_user="${PRODUCTION_VPS_USER:?Missing PRODUCTION_VPS_USER in production environment}"
    ssh_key="${PRODUCTION_VPS_SSH_KEY:?Missing PRODUCTION_VPS_SSH_KEY in production environment}"
    ssh_known_hosts="${PRODUCTION_VPS_KNOWN_HOSTS:?Missing PRODUCTION_VPS_KNOWN_HOSTS in production environment}"

    # Chặn dùng chung cùng user@host với staging nếu workflow cung cấp tham chiếu staging.
    if [[ -n "${STAGING_SSH_HOST_REF:-}" && -n "${STAGING_SSH_USER_REF:-}" && \
          "$ssh_host" == "$STAGING_SSH_HOST_REF" && "$ssh_user" == "$STAGING_SSH_USER_REF" ]]; then
      echo "ERROR: Production SSH target must not reuse the staging user@host; configure a dedicated production OS user or separate VPS." >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: remote-deploy.sh staging|production [frontend] [backend]" >&2
    exit 1
    ;;
esac

if [[ "$ssh_host" =~ [[:space:]] || "$ssh_user" =~ [[:space:]] ]]; then
  echo "ERROR: SSH host and user must not contain whitespace." >&2
  exit 1
fi

[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ ]]

# Kiểm tra trước khi ghép input vào lệnh SSH.
frontend_pattern='^ghcr\.io/68cs-hotel-booking-system/frontend@sha256:[0-9a-f]{64}$'
backend_pattern='^ghcr\.io/68cs-hotel-booking-system/backend-api@sha256:[0-9a-f]{64}$'
if [[ -n "$frontend_image" && ! "$frontend_image" =~ $frontend_pattern ]]; then
  echo "Invalid frontend image digest." >&2
  exit 1
fi
if [[ -n "$backend_image" && ! "$backend_image" =~ $backend_pattern ]]; then
  echo "Invalid backend image digest." >&2
  exit 1
fi
if [[ "$environment" == production ]]; then
  : "${frontend_image:?Production requires frontend image}"
  : "${backend_image:?Production requires backend image}"
fi

# Key chỉ tồn tại trên runner, không gửi cùng source và dọn dẹp khi kết thúc.
install -d -m 700 "$HOME/.ssh"
trap 'rm -f -- "$HOME/.ssh/id_ed25519"' EXIT
printf '%s\n' "$ssh_key" | tr -d '\r' > "$HOME/.ssh/id_ed25519"
printf '%s\n' "$ssh_known_hosts" | tr -d '\r' > "$HOME/.ssh/known_hosts"
chmod 600 "$HOME/.ssh/id_ed25519" "$HOME/.ssh/known_hosts"
ssh_options=(-i "$HOME/.ssh/id_ed25519" -o BatchMode=yes -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes -o ConnectTimeout=15)
target="$ssh_user@$ssh_host"

# Source tách theo env/infra commit; runtime và gateway không bị ghi đè.
remote_dir="/opt/hotel-booking/deployments/$environment/$GITHUB_SHA"
tar -czf - compose.app.yaml \
  compose/backend.yaml compose/frontend.yaml compose/postgres.yaml \
  scripts/deploy.sh scripts/health-check.sh scripts/snapshot-release.sh |
  ssh "${ssh_options[@]}" "$target" \
    "mkdir -p -- '$remote_dir' && tar --overwrite -xzf - -C '$remote_dir'"

ssh "${ssh_options[@]}" "$target" \
  "bash '$remote_dir/scripts/deploy.sh' '$environment' '$frontend_image' '$backend_image'" \
  </dev/null

# Public health từ runner phải đạt trước khi chụp snapshot.
bash scripts/health-check.sh "$environment"
ssh "${ssh_options[@]}" "$target" \
  "bash '$remote_dir/scripts/snapshot-release.sh' '$environment' '$GITHUB_RUN_ID' '$GITHUB_SHA'" \
  </dev/null > deployed-release.json
jq -e --arg environment "$environment" --arg runId "$GITHUB_RUN_ID" \
  --arg sha "$GITHUB_SHA" --arg frontend "$frontend_image" --arg backend "$backend_image" \
  '.environment == $environment and .deploymentRunId == $runId and .infraCommit == $sha and
   ($frontend == "" or .frontend.image == $frontend) and
   ($backend == "" or .backend.image == $backend)' \
  deployed-release.json > /dev/null

#!/usr/bin/env bash
set -euo pipefail

# Chạy trên Actions runner; truyền image vào script trên VPS.
environment="${1:?Missing environment}"
frontend_image="${2:-}"
backend_image="${3:-}"
[[ "$environment" == staging || "$environment" == production ]]
: "${VPS_HOST:?Missing VPS_HOST}" "${VPS_USER:?Missing VPS_USER}" \
  "${VPS_SSH_KEY:?Missing VPS_SSH_KEY}" "${VPS_KNOWN_HOSTS:?Missing VPS_KNOWN_HOSTS}"
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

# Key chỉ tồn tại trên runner, không gửi cùng source.
install -d -m 700 "$HOME/.ssh"
printf '%s\n' "$VPS_SSH_KEY" | tr -d '\r' > "$HOME/.ssh/id_ed25519"
printf '%s\n' "$VPS_KNOWN_HOSTS" | tr -d '\r' > "$HOME/.ssh/known_hosts"
chmod 600 "$HOME/.ssh/id_ed25519" "$HOME/.ssh/known_hosts"
ssh_options=(-i "$HOME/.ssh/id_ed25519" -o BatchMode=yes -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes -o ConnectTimeout=15)
target="$VPS_USER@$VPS_HOST"

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

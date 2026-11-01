#!/usr/bin/env bash
set -euo pipefail

# Tham số: môi trường, frontend mới, backend mới.
environment="${1:-staging}"
frontend_image="${2:-}"
backend_image="${3:-}"

# Chọn profile; production bắt buộc nhận đủ cặp image từ release.
case "$environment" in
  staging)
    profile=staging
    ;;
  production)
    profile=prod
    : "${frontend_image:?Production requires frontend image}"
    : "${backend_image:?Production requires backend image}"
    ;;
  *)
    echo "Usage: deploy.sh staging|production [frontend] [backend]" >&2
    exit 1
    ;;
esac

# Source nằm theo vị trí script; cấu hình runtime nằm cố định trên VPS.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="${HOTEL_RUNTIME_ROOT:-/opt/hotel-booking}"
state_dir="$runtime_root/environments/$environment"
image_file="$state_dir/images.env"

if [[ ! -s "$state_dir/.env" ]]; then
  echo "Missing runtime configuration: $state_dir/.env" >&2
  exit 1
fi

if [[ ! -f "$repo_root/compose.app.yaml" ]]; then
  echo "Missing compose.app.yaml" >&2
  exit 1
fi

# Staging được giữ image của thành phần không có bản cập nhật.
if [[ "$environment" == staging && -s "$image_file" ]]; then
  frontend_image="${frontend_image:-$(sed -n 's/^FRONTEND_IMAGE=//p' "$image_file" | tr -d '\r')}"
  backend_image="${backend_image:-$(sed -n 's/^BACKEND_IMAGE=//p' "$image_file" | tr -d '\r')}"
fi

# Kiểm tra đúng repository và registry digest.
frontend_pattern='^ghcr\.io/68cs-hotel-booking-system/frontend@sha256:[0-9a-f]{64}$'
backend_pattern='^ghcr\.io/68cs-hotel-booking-system/backend-api@sha256:[0-9a-f]{64}$'

if [[ ! "$frontend_image" =~ $frontend_pattern ]]; then
  echo "Invalid or missing frontend image digest." >&2
  exit 1
fi

if [[ ! "$backend_image" =~ $backend_pattern ]]; then
  echo "Invalid or missing backend image digest." >&2
  exit 1
fi

# Gateway chung và network phải được chuẩn bị trước khi deploy ứng dụng.
if ! docker network inspect hotel-booking-edge > /dev/null 2>&1; then
  echo "Missing shared network: hotel-booking-edge" >&2
  exit 1
fi

gateway_id="$(docker ps -q \
  --filter label=com.docker.compose.project=hotel-booking-gateway \
  --filter label=com.docker.compose.service=gateway \
  --filter health=healthy)"

if [[ -z "$gateway_id" || "$gateway_id" == *$'\n'* ]]; then
  echo "Expected one healthy shared gateway." >&2
  exit 1
fi

# Chuẩn bị file image tạm; chưa thay images.env đang lưu.
candidate_file="$(mktemp "$state_dir/.images.XXXXXX")"
trap 'rm -f -- "$candidate_file"' EXIT

printf 'FRONTEND_IMAGE=%s\nBACKEND_IMAGE=%s\n' \
  "$frontend_image" "$backend_image" > "$candidate_file"

# Tách project và profile; giữ đúng tên project staging hiện tại.
compose() {
  DEPLOY_ENVIRONMENT="$environment" \
  SPRING_PROFILES_ACTIVE="$profile" \
  FRONTEND_IMAGE="$frontend_image" \
  BACKEND_IMAGE="$backend_image" \
    docker compose \
      --project-name "hotel-booking-$environment" \
      --project-directory "$repo_root" \
      --file "$repo_root/compose.app.yaml" \
      --env-file "$state_dir/.env" \
      --env-file "$candidate_file" "$@"
}

# Kiểm tra cấu hình, tải image và cập nhật container ứng dụng.
compose config --quiet
compose pull
compose up -d --wait --wait-timeout 180

# Kiểm tra qua domain trước khi ghi nhận phiên bản thành công.
bash "$repo_root/scripts/health-check.sh" "$environment"

mv -- "$candidate_file" "$image_file"
trap - EXIT

printf 'FRONTEND_IMAGE=%s\nBACKEND_IMAGE=%s\n' \
  "$frontend_image" "$backend_image"

echo "DEPLOY_OK: $environment"

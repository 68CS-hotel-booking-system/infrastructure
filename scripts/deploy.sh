#!/usr/bin/env bash
set -euo pipefail

# Tham số: môi trường, frontend mới, backend mới.
environment="${1:-staging}"
frontend_image="${2:-}"
backend_image="${3:-}"

if [[ "$environment" != "staging" ]]; then
  echo "Usage: bash scripts/deploy.sh staging [frontend_image] [backend_image]" >&2
  exit 1
fi

# Tính mọi đường dẫn từ thư mục gốc repo.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repo_root"
state_dir="environments/$environment"
image_file="$state_dir/images.env"

# Không truyền image mới thì dùng phiên bản đang lưu.
if [[ -s "$image_file" ]]; then
  frontend_image="${frontend_image:-$(sed -n 's/^FRONTEND_IMAGE=//p' "$image_file" | tr -d '\r')}"
  backend_image="${backend_image:-$(sed -n 's/^BACKEND_IMAGE=//p' "$image_file" | tr -d '\r')}"
fi

# Staging chạy cả frontend và backend, nên cần hai digest hợp lệ.
frontend_pattern='^ghcr\.io/68cs-hotel-booking-system/frontend@sha256:[0-9a-f]{64}$'
backend_pattern='^ghcr\.io/68cs-hotel-booking-system/backend-api@sha256:[0-9a-f]{64}$'

if [[ ! "$frontend_image" =~ $frontend_pattern ]]; then
  echo "Supply a valid frontend image digest, or save it in $image_file." >&2
  exit 1
fi

if [[ ! "$backend_image" =~ $backend_pattern ]]; then
  echo "Supply a valid backend image digest, or save it in $image_file." >&2
  exit 1
fi

# Dùng file tạm để giữ nguyên phiên bản đang lưu nếu deploy thất bại.
mkdir -p -- "$state_dir"
candidate_file="$(mktemp "$state_dir/.images.XXXXXX")"
trap 'rm -f -- "$candidate_file"' EXIT
printf 'FRONTEND_IMAGE=%s\nBACKEND_IMAGE=%s\n' \
  "$frontend_image" "$backend_image" > "$candidate_file"

# Nạp cấu hình runtime bắt buộc và hai phiên bản đã chọn.
compose() {
  FRONTEND_IMAGE="$frontend_image" BACKEND_IMAGE="$backend_image" \
    docker compose --project-directory "$repo_root" \
      --file "$repo_root/compose.yaml" \
      --env-file "$state_dir/.env" --env-file "$candidate_file" "$@"
}

# Compose gốc đã include đủ bốn service; kiểm tra trước khi thay container.
compose config --quiet

# Pull, chạy container và kiểm tra/reload Nginx.
compose pull
compose up -d --wait --wait-timeout 120
compose exec -T --interactive=false gateway nginx -t </dev/null
compose exec -T --interactive=false gateway nginx -s reload </dev/null

# Chỉ lưu phiên bản sau khi các bước nội bộ thành công.
mv -- "$candidate_file" "$image_file"
trap - EXIT
printf 'FRONTEND_IMAGE=%s\nBACKEND_IMAGE=%s\n' "$frontend_image" "$backend_image"
echo "GATEWAY_DEPLOY_OK"

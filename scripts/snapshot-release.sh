#!/usr/bin/env bash
set -euo pipefail

# Thông tin deployment do workflow truyền vào.
environment="${1:-staging}"
run_id="${2:?Missing deployment run ID}"
infra_commit="${3:?Missing infrastructure commit}"

[[ "$environment" == staging || "$environment" == production ]]
[[ "$run_id" =~ ^[0-9]+$ ]]
[[ "$infra_commit" =~ ^[0-9a-f]{40}$ ]]

runtime_root="${HOTEL_RUNTIME_ROOT:-/opt/hotel-booking}"
state_dir="$runtime_root/environments/$environment"

# Đọc image, commit và source-tree của một service đang chạy.
read_component() {
  local service="$1"
  local repository="$2"
  local container_id

  container_id="$(docker ps -q \
    --filter "label=com.docker.compose.project=hotel-booking-$environment" \
    --filter "label=com.docker.compose.service=$service")"

  # Cần đúng một container đang chạy cho mỗi service.
  if [[ -z "$container_id" || "$container_id" == *$'\n'* ]]; then
    echo "Expected one running container for $service." >&2
    return 1
  fi

  docker inspect "$container_id" |
    jq -e --arg repository "$repository" '
      .[0] |
      {
        image: .Config.Image,
        commit: .Config.Labels["org.opencontainers.image.revision"],
        sourceTree: .Config.Labels["io.hotelbooking.source-tree"]
      } |
      if (.image | startswith($repository + "@sha256:")) and
         (.image | test("@sha256:[0-9a-f]{64}$")) and
         ((.commit // "") | test("^[0-9a-f]{40}$")) and
         ((.sourceTree // "") | test("^[0-9a-f]{40}$"))
      then .
      else error("Missing or invalid image metadata")
      end
    '
}

# Lấy đúng cặp FE/BE thực tế trên VPS.
frontend="$(read_component frontend \
  ghcr.io/68cs-hotel-booking-system/frontend)"

backend="$(read_component backend \
  ghcr.io/68cs-hotel-booking-system/backend-api)"

# Tạo snapshot chung, không chứa secret.
snapshot="$(jq -n \
  --arg environment "$environment" \
  --arg runId "$run_id" \
  --arg infraCommit "$infra_commit" \
  --argjson frontend "$frontend" \
  --argjson backend "$backend" \
  '{
    schemaVersion: 1,
    environment: $environment,
    deploymentRunId: $runId,
    infraCommit: $infraCommit,
    deploymentUrl: (
      "https://github.com/68CS-hotel-booking-system/infrastructure/actions/runs/"
      + $runId
    ),
    frontend: $frontend,
    backend: $backend
  }')"

# Ghi qua file tạm để tránh để lại state.json đang ghi dở.
temporary="$(mktemp "$state_dir/.state.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT

printf '%s\n' "$snapshot" > "$temporary"
mv -- "$temporary" "$state_dir/state.json"

trap - EXIT

# Workflow sẽ lấy kết quả này để lưu artifact theo từng deployment.
printf '%s\n' "$snapshot"

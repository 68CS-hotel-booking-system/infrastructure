#!/usr/bin/env bash
set -euo pipefail

# Nhận file snapshot/release và nhánh cần kiểm tra.
release_file="${1:?Missing release file}"
branch="${2:-staging}"

[[ "$branch" == staging || "$branch" == main ]]
: "${GH_TOKEN:?Missing GitHub read token}"

# Kiểm tra cấu trúc và metadata trước khi gọi GitHub API.
jq -e '
  .schemaVersion == 1 and
  .environment == "staging" and
  (.deploymentRunId | test("^[0-9]+$")) and
  (.frontend.image |
    test("^ghcr\\.io/68cs-hotel-booking-system/frontend@sha256:[0-9a-f]{64}$")) and
  (.backend.image |
    test("^ghcr\\.io/68cs-hotel-booking-system/backend-api@sha256:[0-9a-f]{64}$")) and
  ([.frontend.commit, .frontend.sourceTree,
    .backend.commit, .backend.sourceTree] |
    all(.[]; test("^[0-9a-f]{40}$")))
' "$release_file" > /dev/null

ready=true

# Cả FE và BE phải cùng đạt điều kiện.
for component in frontend backend; do
  if [[ "$component" == frontend ]]; then
    repository=68CS-hotel-booking-system/frontend
  else
    repository=68CS-hotel-booking-system/backend-api
  fi

  expected_tree="$(jq -r --arg component "$component" \
    '.[$component].sourceTree' "$release_file")"

  # Đọc commit hiện tại và nội dung source trên nhánh đích.
  head_json="$(gh api "repos/$repository/commits/$branch")"
  head_sha="$(jq -r '.sha' <<< "$head_json")"
  actual_tree="$(jq -r '.commit.tree.sha' <<< "$head_json")"

  if [[ "$actual_tree" != "$expected_tree" ]]; then
    echo "WAIT: $repository:$branch does not match the tested source." >&2
    ready=false
    continue
  fi

  # Lấy các lần CI push của đúng commit trên nhánh đích.
  runs="$(gh api --method GET \
    "repos/$repository/actions/workflows/ci.yml/runs" \
    -f branch="$branch" \
    -f event=push \
    -f head_sha="$head_sha" \
    -f per_page=100)"

  # Lần CI mới nhất của commit đó phải thành công.
  if ! jq -e --arg sha "$head_sha" '
    [.workflow_runs[] | select(.head_sha == $sha)] |
    sort_by(.id) | last | .conclusion == "success"
  ' <<< "$runs" > /dev/null; then
    echo "WAIT: $repository:$branch CI has not succeeded." >&2
    ready=false
  fi
done

# Workflow sẽ dựa vào mã thoát để quyết định bước tiếp theo.
if [[ "$ready" != true ]]; then
  exit 2
fi

echo "RELEASE_SOURCE_AND_CI_OK"
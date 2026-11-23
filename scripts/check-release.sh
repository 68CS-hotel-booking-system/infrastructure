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

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

# Xác minh digest trong manifest khớp artifact producer do CI push nhánh develop tạo ra.
verify_image_provenance() {
  local component="$1"
  local repository="$2"
  local expected_image="$3"
  local expected_commit="$4"
  local expected_tree="$5"
  local expected_digest="${expected_image#*@}"
  local artifact_name="release-$component"
  local producer_branch="develop"
  local producer_workflow=".github/workflows/ci.yml"
  local producer_runs matching_runs run_count producer_run_id
  local artifacts_json matching_artifacts artifact_count
  local artifact_dir producer_manifest

  if ! producer_runs="$(gh api --method GET \
    "repos/$repository/actions/workflows/ci.yml/runs" \
    -f branch="$producer_branch" \
    -f event=push \
    -f head_sha="$expected_commit" \
    -f per_page=100)"; then
    echo "ERROR: Failed to query producer CI runs for $repository@$expected_commit." >&2
    return 1
  fi

  matching_runs="$(jq -c \
    --arg repo "$repository" \
    --arg branch "$producer_branch" \
    --arg workflow "$producer_workflow" \
    --arg commit "$expected_commit" '
      [
        (.workflow_runs // [])[]
        | select(
            .head_sha == $commit and
            .head_branch == $branch and
            .event == "push" and
            .path == $workflow and
            .status == "completed" and
            .conclusion == "success" and
            ((.repository.full_name // "") | ascii_downcase) == ($repo | ascii_downcase) and
            ((.head_repository.full_name // "") | ascii_downcase) == ($repo | ascii_downcase)
          )
        | .id
      ] | unique
    ' <<< "$producer_runs")"

  run_count="$(jq -r 'length' <<< "$matching_runs")"
  if [[ "$run_count" -eq 0 ]]; then
    echo "ERROR: No successful trusted producer CI run on $repository:$producer_branch for commit $expected_commit." >&2
    return 1
  fi
  if [[ "$run_count" -ne 1 ]]; then
    echo "ERROR: Ambiguous producer CI runs ($run_count) on $repository:$producer_branch for commit $expected_commit." >&2
    return 1
  fi

  producer_run_id="$(jq -r '.[0]' <<< "$matching_runs")"
  if [[ ! "$producer_run_id" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid producer CI run ID for $repository@$expected_commit." >&2
    return 1
  fi

  if ! artifacts_json="$(gh api --method GET \
    "repos/$repository/actions/runs/$producer_run_id/artifacts" \
    -f per_page=100)"; then
    echo "ERROR: Failed to query producer artifacts for $repository run $producer_run_id." >&2
    return 1
  fi

  matching_artifacts="$(jq -c --arg name "$artifact_name" '
    [
      (.artifacts // [])[]
      | select(.name == $name and .expired == false)
      | .id
    ] | unique
  ' <<< "$artifacts_json")"

  artifact_count="$(jq -r 'length' <<< "$matching_artifacts")"
  if [[ "$artifact_count" -eq 0 ]]; then
    echo "ERROR: Missing or expired producer artifact $artifact_name for $repository run $producer_run_id." >&2
    return 1
  fi
  if [[ "$artifact_count" -ne 1 ]]; then
    echo "ERROR: Ambiguous producer artifacts ($artifact_count) named $artifact_name for $repository run $producer_run_id." >&2
    return 1
  fi

  artifact_dir="$work_dir/$component"
  mkdir -p "$artifact_dir"
  if ! gh run download "$producer_run_id" \
    --repo "$repository" \
    --name "$artifact_name" \
    --dir "$artifact_dir"; then
    echo "ERROR: Failed to download producer artifact $artifact_name for $repository run $producer_run_id." >&2
    return 1
  fi

  producer_manifest="$artifact_dir/release.json"
  if [[ ! -f "$producer_manifest" ]]; then
    echo "ERROR: Producer artifact $artifact_name for $repository run $producer_run_id is missing release.json." >&2
    return 1
  fi

  if ! jq -e \
    --arg component "$component" \
    --arg repo "$repository" \
    --arg commit "$expected_commit" \
    --arg tree "$expected_tree" \
    --arg branch "$producer_branch" \
    --arg image "$expected_image" \
    --arg digest "$expected_digest" \
    --arg runId "$producer_run_id" '
      .schemaVersion == 1 and
      .component == $component and
      ((.repository // "") | ascii_downcase) == ($repo | ascii_downcase) and
      .commit == $commit and
      .sourceTree == $tree and
      .sourceBranch == $branch and
      .image == $image and
      .digest == $digest and
      ((.runId // "") | tostring) == $runId and
      .smokeTest.passed == true
    ' "$producer_manifest" > /dev/null; then
    echo "ERROR: Producer artifact $artifact_name for $repository run $producer_run_id does not match release digest/metadata." >&2
    return 1
  fi
}

ready=true

# Cả FE và BE phải cùng đạt điều kiện.
for component in frontend backend; do
  if [[ "$component" == frontend ]]; then
    repository=68CS-hotel-booking-system/frontend
  else
    repository=68CS-hotel-booking-system/backend-api
  fi

  expected_image="$(jq -r --arg component "$component" \
    '.[$component].image' "$release_file")"
  expected_commit="$(jq -r --arg component "$component" \
    '.[$component].commit' "$release_file")"
  expected_tree="$(jq -r --arg component "$component" \
    '.[$component].sourceTree' "$release_file")"

  # Đối chiếu digest và metadata với artifact producer từ CI develop trước khi xét trạng thái nhánh đích.
  verify_image_provenance \
    "$component" "$repository" "$expected_image" "$expected_commit" "$expected_tree"

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
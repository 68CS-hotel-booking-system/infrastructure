#!/usr/bin/env bash
set -euo pipefail

# Đọc repo infra bằng GITHUB_TOKEN, khác token đọc FE/BE.
release_file="${1:?Missing release file}"
: "${GH_TOKEN:?Missing infrastructure read token}" "${GITHUB_REPOSITORY:?}"
release_id="$(jq -er .releaseId "$release_file")"
[[ "$release_id" =~ ^v[0-9][0-9A-Za-z._-]*$ ]]
[[ "$release_file" == "releases/$release_id.json" ]]

# Chặn run cũ khi main infra đã chọn release khác.
selected_id="$(
  gh api "repos/$GITHUB_REPOSITORY/contents/environments/production/release.json?ref=main" \
    --jq .content | base64 --decode | jq -er .releaseId
)"
if [[ "$selected_id" != "$release_id" ]]; then
  echo "WAIT: production now selects $selected_id instead of $release_id." >&2
  exit 2
fi

# Nội dung file phải đúng bản đang được chọn trên main, không chỉ trùng ID.
current_blob="$(gh api \
  "repos/$GITHUB_REPOSITORY/contents/$release_file?ref=main" --jq .sha)"
if [[ "$current_blob" != "$(git hash-object "$release_file")" ]]; then
  echo "Release content differs from the approved file on main." >&2
  exit 1
fi

# Không coi một environment mới tạo, chưa có reviewer, là đủ điều kiện.
protection="$(gh api "repos/$GITHUB_REPOSITORY/environments/production")"
if ! jq -e '
  any(.protection_rules[]?;
    .type == "required_reviewers" and ((.reviewers // []) | length > 0))
' <<< "$protection" > /dev/null; then
  echo "Configure required reviewers for the production environment first." >&2
  exit 1
fi
echo "PRODUCTION_SELECTION_AND_REVIEW_POLICY_OK"

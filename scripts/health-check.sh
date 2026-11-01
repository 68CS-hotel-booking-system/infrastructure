#!/usr/bin/env bash
set -euo pipefail

# Chọn domain theo môi trường; mặc định là staging.
environment="${1:-staging}"

case "$environment" in
  staging)
    base_url="https://staging.hotelbooking.id.vn"
    ;;
  production)
    base_url="https://hotelbooking.id.vn"
    ;;
  *)
    echo "Usage: bash scripts/health-check.sh staging|production" >&2
    exit 1
    ;;
esac
curl_options=(
  --fail --silent --show-error
  --connect-timeout 10
  --max-time 20
  --retry 20
  --retry-delay 3
  --retry-all-errors
)

response="$(curl "${curl_options[@]}" "$base_url/healthz")"
if [[ "$response" != "OK" ]]; then
  echo "HTTPS health check did not return OK." >&2
  exit 1
fi
echo "HTTPS_OK"

html="$(curl "${curl_options[@]}" "$base_url/")"
if [[ "$html" != *'id="root"'* ]]; then
  echo "Frontend HTML was not returned." >&2
  exit 1
fi
echo "FRONTEND_OK"

# Kiểm tra backend qua domain và Nginx gateway.
backend_health="$(
  curl "${curl_options[@]}" "$base_url/actuator/health"
)"

if ! jq -e '.status == "UP"' <<< "$backend_health" > /dev/null; then
  echo "Backend health did not report UP." >&2
  exit 1
fi

echo "BACKEND_OK"
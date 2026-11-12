#!/usr/bin/env bash
# Smoke test for the built image: starts a container and checks the nginx
# rules that would otherwise fail silently -- wrong MIME types, PWA files
# cached too long, missing assets answered with HTML instead of a 404.
#
#   scripts/smoke-test.sh [image]     (default: routetracker:smoke)
set -euo pipefail

IMAGE="${1:-routetracker:smoke}"
PORT="${SMOKE_PORT:-17000}"
BASE="http://127.0.0.1:${PORT}"
NAME="routetracker-smoke-$$"
FAILED=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" -p "${PORT}:7000" "$IMAGE" >/dev/null

for _ in $(seq 1 30); do
  curl -fs "$BASE/api/health" >/dev/null && break
  sleep 0.5
done

# Hashed filenames change every build, so look them up inside the container.
html_root=/usr/share/nginx/html
wasm=$(docker exec "$NAME" sh -c "cd $html_root && ls assets/*.wasm | head -n1")
js=$(docker exec "$NAME" sh -c "cd $html_root && ls assets/index-*.js | head -n1")

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILED=1; }

# check <path> <expected status> [header regex...] -- each regex must match
# some response header line (case-insensitive).
check() {
  local path=$1 status=$2; shift 2
  local headers
  headers=$(curl -s -o /dev/null -D - -H 'Accept-Encoding: gzip' "$BASE$path" | tr -d '\r')
  if ! grep -q "^HTTP/[0-9.]* $status" <<<"$headers"; then
    fail "$path -> expected $status, got: $(head -n1 <<<"$headers")"
    return
  fi
  for re in "$@"; do
    grep -qiE "$re" <<<"$headers" || { fail "$path -> missing header /$re/"; return; }
  done
  pass "$path ($status${*:+, $*})"
}

echo "Smoke-testing $IMAGE"
check /                      200 '^content-type: text/html'          '^cache-control: no-cache'
check /index.html            200 '^cache-control: no-cache'
check /sw.js                 200 '^content-type: application/javascript' '^cache-control: no-cache'
check /manifest.webmanifest  200 '^content-type: application/manifest\+json' '^cache-control: no-cache'
check "/$wasm"               200 '^content-type: application/wasm'   '^cache-control: .*immutable'
check "/$js"                 200 '^content-type: application/javascript' '^cache-control: .*immutable' '^content-encoding: gzip'
check /api/health            200 '^content-type: application/json'
check /assets/missing.js     404
check /missing.js            404

body=$(curl -s "$BASE/api/health")
[[ $body == '{"status":"ok"}' ]] && pass "/api/health body" || fail "/api/health body: ${body:0:80}"

user=$(docker exec "$NAME" id -u)
[[ $user != 0 ]] && pass "runs as non-root (uid $user)" || fail "runs as root"

exit $FAILED

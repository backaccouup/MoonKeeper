#!/usr/bin/env bash
set -euo pipefail

mode=${1:-single}
zk_host=${2:-127.0.0.1}
zk_port=${3:-21819}
case "$mode" in single|existing) ;; *) echo 'Usage: integration.sh [single|existing] [host] [port]' >&2; exit 2 ;; esac
if [[ ! "$zk_port" =~ ^[0-9]{1,5}$ ]] || ((10#$zk_port < 1 || 10#$zk_port > 65535)); then
  echo 'Port must be in 1..65535.' >&2; exit 2
fi
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
command -v moon >/dev/null || { echo 'MoonBit is required; install the documented toolchain first.' >&2; exit 1; }
export MOONKEEPER_ZK_HOST="$zk_host" MOONKEEPER_ZK_PORT="$zk_port"
project="moonkeeper-handshake-$$"
started=false
cleanup() {
  if [[ "$started" == true ]]; then
    docker compose -p "$project" -f integration/compose.yaml down --volumes --remove-orphans || echo "Could not clean up Compose project $project" >&2
  fi
}
trap cleanup EXIT
if [[ "$mode" == single ]]; then
  [[ "$zk_host" == 127.0.0.1 ]] || { echo 'single mode binds loopback only; use existing mode for another host.' >&2; exit 2; }
  command -v docker >/dev/null || { echo 'Docker with Compose is required for single mode. Use existing mode with an external ZooKeeper if Docker is unavailable.' >&2; exit 1; }
  docker compose version
  started=true
  docker compose -p "$project" -f integration/compose.yaml up -d --wait --wait-timeout 60
fi
moon build --target native --deny-warn
ready=false
for attempt in {1..6}; do
  if moon run cmd/connect --target native -- "$zk_host" "$zk_port"; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { echo "ZooKeeper handshake readiness failed at $zk_host:$zk_port." >&2; exit 1; }
moon test integration --target native --include-skipped --deny-warn

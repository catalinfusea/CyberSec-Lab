#!/usr/bin/env bash
# Helperi comuni pentru provisioning Linux (Ubuntu 24.04). Se include cu: source /tmp/lab-lib.sh
set -Eeuo pipefail
umask 022

log() { printf '[%s] [%s] %s\n' "$(date -Is)" "$(hostname)" "$*"; }
die() { log "EROARE: $*"; exit 1; }

require_env() {
  local name="$1"
  local val="${!name:-}"
  [[ -n "$val" && "$val" != __MISSING_* ]] || die "Variabila de mediu $name lipseste"
}

# Descarca HTTPS si verifica SHA256 fixat.
fetch_verified() {
  local url="$1" out="$2" sha="$3"
  [[ "$url" == https://* ]] || die "Refuz URL non-HTTPS: $url"
  log "Download: $url"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$out" "$url"
  echo "${sha}  ${out}" | sha256sum -c --quiet - || { rm -f "$out"; die "SHA256 nepotrivit: $url"; }
  log "SHA256 OK: $out"
}

export DEBIAN_FRONTEND=noninteractive

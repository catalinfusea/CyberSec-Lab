#!/usr/bin/env bash
# auditd cu regulile Neo23x0 la un commit fixat (SHA256 verificat). Idempotent.
# shellcheck source=../common/lib.sh
source /tmp/lab-lib.sh
require_env AUDIT_RULES_URL
require_env AUDIT_RULES_SHA256

if ! dpkg -s auditd >/dev/null 2>&1; then
  apt-get update -q
  apt-get install -y -q auditd
fi

tmp="$(mktemp)"
fetch_verified "$AUDIT_RULES_URL" "$tmp" "$AUDIT_RULES_SHA256"
install -m 640 -o root -g root "$tmp" /etc/audit/rules.d/audit.rules
rm -f "$tmp"

systemctl enable --now auditd
augenrules --load
log "Reguli auditd active: $(auditctl -l | wc -l)"

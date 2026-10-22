#!/usr/bin/env bash
# Agent Wazuh din repo-ul oficial APT, versiune fixata si pusa pe hold. Idempotent.
# shellcheck source=../common/lib.sh
source /tmp/lab-lib.sh
for v in WAZUH_VERSION WAZUH_MANAGER WAZUH_GROUP; do require_env "$v"; done

if dpkg -s wazuh-agent >/dev/null 2>&1; then
  log "wazuh-agent deja instalat; skip"
  exit 0
fi

apt-get update -q
apt-get install -y -q gnupg apt-transport-https curl
curl -fsSL --proto '=https' --tlsv1.2 https://packages.wazuh.com/key/GPG-KEY-WAZUH \
  | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
  > /etc/apt/sources.list.d/wazuh.list
apt-get update -q

WAZUH_MANAGER="$WAZUH_MANAGER" WAZUH_AGENT_GROUP="$WAZUH_GROUP" WAZUH_AGENT_NAME="$(hostname)" \
  apt-get install -y -q "wazuh-agent=${WAZUH_VERSION}"
apt-mark hold wazuh-agent
# Recomandarea Wazuh: dezactiveaza repo-ul ca sa nu treci accidental agentul peste manager.
sed -i 's/^deb /#deb /' /etc/apt/sources.list.d/wazuh.list
apt-get update -q

systemctl daemon-reload
systemctl enable --now wazuh-agent
log "Agent Wazuh ${WAZUH_VERSION} instalat (manager=${WAZUH_MANAGER}, grup=${WAZUH_GROUP})"

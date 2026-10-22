#!/usr/bin/env bash
# Wazuh all-in-one (indexer + manager + dashboard) cu asistentul oficial, plus grupuri de agenti
# cu configuratie centralizata (Sysmon/PowerShell pe Windows, audit.log pe Linux). Idempotent.
# shellcheck source=../common/lib.sh
source /tmp/lab-lib.sh
require_env WAZUH_SERIES
require_env LAB_IP

if systemctl is-active --quiet wazuh-manager; then
  log "wazuh-manager deja activ; sar peste instalare"
else
  apt-get update -q
  apt-get install -y -q curl tar
  cd /root
  # Scriptul nu are hash publicat; increderea se bazeaza pe TLS catre packages.wazuh.com.
  curl -fsSL --proto '=https' --tlsv1.2 -o wazuh-install.sh "https://packages.wazuh.com/${WAZUH_SERIES}/wazuh-install.sh"
  log "Instalez Wazuh ${WAZUH_SERIES} AIO (10-20 min). Output-ul (contine parole) merge in /root/wazuh-install.log"
  touch /root/wazuh-install.log && chmod 600 /root/wazuh-install.log
  if ! bash wazuh-install.sh -a >/root/wazuh-install.log 2>&1; then
    tail -n 30 /root/wazuh-install.log | grep -viE 'password|passwd' || true
    die "wazuh-install.sh a esuat; vezi /root/wazuh-install.log"
  fi
  chmod 600 /root/wazuh-install-files.tar 2>/dev/null || true
fi

# Vulnerability Detection: feed-ul se actualizeaza implicit la 60m (si minim 60m, docs Wazuh 4.14).
# Fiecare actualizare rescrie date in /var/ossec/queue/vd (~10 GB) -> VMDK-ul creste (disc fara discard).
vd_int="${WAZUH_VD_FEED_INTERVAL:-1d}"
[[ "$vd_int" =~ ^[0-9]+[smhd]$ ]] || die "WAZUH_VD_FEED_INTERVAL invalid: $vd_int"
conf=/var/ossec/etc/ossec.conf
cur="$(sed -n 's#.*<feed-update-interval>\([^<]*\)</feed-update-interval>.*#\1#p' "$conf" | head -n1)"
[[ -n "$cur" ]] || die "Nu gasesc <feed-update-interval> in $conf"
if [[ "$cur" != "$vd_int" ]]; then
  sed -i "s#<feed-update-interval>[^<]*</feed-update-interval>#<feed-update-interval>${vd_int}</feed-update-interval>#" "$conf"
  systemctl restart wazuh-manager
  log "VD feed-update-interval: ${cur} -> ${vd_int}"
fi

# Grupuri + agent.conf centralizat.
for g in windows linux; do
  if [[ ! -d "/var/ossec/etc/shared/${g}" ]]; then
    /var/ossec/bin/agent_groups -a -g "$g" -q
    log "Grup creat: $g"
  fi
done

cat > /var/ossec/etc/shared/windows/agent.conf <<'EOF'
<agent_config>
  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
  <localfile>
    <location>Microsoft-Windows-PowerShell/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
  <localfile>
    <location>Microsoft-Windows-Windows Defender/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
</agent_config>
EOF

cat > /var/ossec/etc/shared/linux/agent.conf <<'EOF'
<agent_config>
  <localfile>
    <log_format>audit</log_format>
    <location>/var/log/audit/audit.log</location>
  </localfile>
</agent_config>
EOF

chown wazuh:wazuh /var/ossec/etc/shared/windows/agent.conf /var/ossec/etc/shared/linux/agent.conf
chmod 660 /var/ossec/etc/shared/windows/agent.conf /var/ossec/etc/shared/linux/agent.conf
/var/ossec/bin/verify-agent-conf || die "agent.conf invalid"

log "Dashboard: https://${LAB_IP}  (certificat self-signed)"
log "Parola admin: sudo tar -O -xf /root/wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt"

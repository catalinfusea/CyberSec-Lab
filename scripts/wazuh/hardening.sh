#!/usr/bin/env bash
# Hardening wazuh01 (Ubuntu 24.04): rpcbind mascat + ufw default deny incoming.
#   NIC lab  (VMnet3): tcp WAZUH_TCP_PORTS, doar din subnetul lab (calculat din LAB_IP/LAB_PREFIX)
#   NIC mgmt (NAT)   : tcp 22, doar de la sursa sesiunii SSH Vagrant curente (port forward VMnet8)
# Idempotent (run: always). Interfetele se identifica dupa MAC, ca in net-linux.sh.
# Regulile se reaplica (ufw reset) doar cand specificatia s-a schimbat sau ufw nu e activ.
# shellcheck source=../common/lib.sh
source /tmp/lab-lib.sh
# Fix 2026-10-21: awk fara `exit` in pipeline-uri (cu pipefail, `exit` -> SIGPIPE pe `ip` -> iesire silentioasa; masurat 37/200 pe lin01).

for v in LAB_MAC LAB_MGMT_MAC LAB_IP LAB_PREFIX WAZUH_TCP_PORTS; do require_env "$v"; done

ipv4_re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
[[ "$LAB_IP" =~ $ipv4_re ]] || die "LAB_IP invalid: $LAB_IP"
[[ "$LAB_PREFIX" =~ ^[0-9]+$ ]] && (( LAB_PREFIX >= 8 && LAB_PREFIX <= 30 )) || die "LAB_PREFIX invalid: $LAB_PREFIX"
[[ "$WAZUH_TCP_PORTS" =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || die "WAZUH_TCP_PORTS invalid: $WAZUH_TCP_PORTS"

# ---------------------------------------------------------------- rpcbind
# Ordinea conteaza: socket-ul ar reactiva serviciul.
for u in rpcbind.socket rpcbind.service; do
  st="$(systemctl is-enabled "$u" 2>/dev/null || true)"
  systemctl stop "$u" 2>/dev/null || true
  if [[ "$st" != masked ]]; then
    systemctl disable "$u" 2>/dev/null || true
    systemctl mask "$u" >/dev/null
    log "$u: mascat (era: ${st:-necunoscut})"
  fi
done
if [[ -n "$(ss -Hlntu '( sport = :111 )')" ]]; then
  die "Ceva asculta inca pe portul 111: $(ss -Hlntup '( sport = :111 )')"
fi

# ---------------------------------------------------------------- interfete
dev_by_mac() {
  ip -o link | awk -v m="${1,,}" '!f && tolower($0) ~ m {gsub(":","",$2); sub(/@.*/,"",$2); print $2; f=1}'
}
lab_dev="$(dev_by_mac "$LAB_MAC")"
mgmt_dev="$(dev_by_mac "$LAB_MGMT_MAC")"
[[ -n "$lab_dev" ]]  || die "Nu gasesc NIC-ul lab cu MAC ${LAB_MAC}"
[[ -n "$mgmt_dev" ]] || die "Nu gasesc NIC-ul mgmt cu MAC ${LAB_MGMT_MAC}"
[[ "$lab_dev" != "$mgmt_dev" ]] || die "NIC lab si mgmt coincid ($lab_dev)"

# Subnet lab din LAB_IP/LAB_PREFIX (nu din starea curenta a interfetei).
IFS=. read -r o1 o2 o3 o4 <<<"$LAB_IP"
ipnum=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
mask=$(( (0xFFFFFFFF << (32 - LAB_PREFIX)) & 0xFFFFFFFF ))
net=$(( ipnum & mask ))
lab_net="$(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( (net >> 8) & 255 )).$(( net & 255 ))/${LAB_PREFIX}"

# Sursa SSH pe mgmt = sursa sesiunii prin care ruleaza chiar acest provisioner.
mgmt_ip="$(ip -4 -o addr show dev "$mgmt_dev" scope global | awk '!f {split($4,a,"/"); print a[1]; f=1}')"
[[ -n "$mgmt_ip" ]] || die "NIC-ul mgmt ($mgmt_dev) nu are IPv4"
mapfile -t ssh_srcs < <(ss -Htn state established '( sport = :22 )' \
  | awk -v l="${mgmt_ip}:22" '$3 == l {sub(/:[0-9]+$/, "", $4); print $4}' | sort -u)

if (( ${#ssh_srcs[@]} == 1 )); then
  ssh_src="${ssh_srcs[0]}"
elif (( ${#ssh_srcs[@]} == 0 )); then
  # Fallback (NETESTAT): ROUTER din lease-ul DHCP systemd-networkd al NIC-ului mgmt.
  lease="/run/systemd/netif/leases/$(cat "/sys/class/net/${mgmt_dev}/ifindex")"
  ssh_src="$(awk -F= '$1 == "ROUTER" {split($2, r, " "); print r[1]; exit}' "$lease" 2>/dev/null || true)"
  [[ -n "$ssh_src" ]] || die "Nu pot determina sursa SSH Vagrant pe ${mgmt_dev}; ufw neschimbat"
  log "AVERTISMENT: nicio sesiune SSH pe ${mgmt_ip}:22; folosesc gateway-ul DHCP ${ssh_src}"
else
  die "Mai multe surse SSH pe ${mgmt_dev}: ${ssh_srcs[*]}; refuz sa aleg. ufw neschimbat"
fi
[[ "$ssh_src" =~ $ipv4_re ]] || die "Sursa SSH invalida: $ssh_src"

# ---------------------------------------------------------------- ufw
command -v ufw >/dev/null || apt-get install -y -q ufw

spec="v1|lab=${lab_dev}|net=${lab_net}|ports=${WAZUH_TCP_PORTS}|mgmt=${mgmt_dev}|ssh_src=${ssh_src}"
state_file=/etc/ufw/lab-hardening.state
ufw_status="$(ufw status)"

if [[ "$ufw_status" == "Status: active"* && -f "$state_file" && "$(cat "$state_file")" == "$spec" ]]; then
  log "ufw neschimbat ($spec)"
else
  log "Aplic ufw: $spec"
  # reset dezactiveaza ufw (fara lockout); enable pastreaza sesiunea curenta (ESTABLISHED in before.rules).
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw logging low
  IFS=, read -ra ports <<<"$WAZUH_TCP_PORTS"
  for p in "${ports[@]}"; do
    (( p >= 1 && p <= 65535 )) || die "Port invalid: $p"
    ufw allow in on "$lab_dev" from "$lab_net" to any port "$p" proto tcp comment "lab tcp/$p"
  done
  ufw allow in on "$mgmt_dev" from "$ssh_src" to any port 22 proto tcp comment "vagrant ssh via NAT port-forward"
  ufw --force enable
  install -m 600 /dev/null "$state_file"
  printf '%s\n' "$spec" > "$state_file"
fi

[[ "$(ufw status)" == "Status: active"* ]] || die "ufw nu e activ dupa aplicare"
ufw status numbered | while IFS= read -r line; do
  if [[ -n "$line" ]]; then log "ufw: $line"; fi
done

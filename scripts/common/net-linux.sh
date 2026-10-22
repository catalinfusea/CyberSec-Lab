#!/usr/bin/env bash
# NIC1 (VMnet3) static + default route prin pfSense; NIC0 (NAT Vagrant) DHCP fara rute/DNS.
# Idempotent (run: always). Interfetele se identifica dupa MAC, nu dupa nume.
# Aplicare SINCRONA, fara `netplan apply` (care reconfigura NIC0 si taia sesiunea SSH a Vagrant):
#   netplan generate -> networkctl reload -> networkctl reconfigure, ca in net-kali.sh.
#   - MGMT are `critical: true` -> netplan scrie KeepConfiguration in .network: adresa DHCP
#     (aceeasi, rezervare VMnet8 pe MAC) nu se sterge la reconfigurare, deci SSH-ul ramane;
#   - pe MGMT se sterg manual doar rutele default (SSH-ul vine de la gateway-ul NAT, on-link).
# Valabil pentru Ubuntu 24.04 (netplan + systemd-networkd). NETESTAT la data scrierii (2026-10-20).
# shellcheck source=lib.sh
source /tmp/lab-lib.sh
# Fix 2026-10-21: awk fara `exit` in pipeline-uri (cu pipefail, `exit` -> SIGPIPE pe `ip` -> iesire silentioasa; masurat 37/200 pe lin01).

for v in LAB_MAC LAB_MGMT_MAC LAB_IP LAB_PREFIX LAB_GW LAB_DNS LAB_DOMAIN; do require_env "$v"; done

# shellcheck disable=SC2153  # LAB_MAC vine din env (Vagrant)
lab_mac="${LAB_MAC,,}"
mgmt_mac="${LAB_MGMT_MAC,,}"
dns_yaml="[$(echo "$LAB_DNS" | sed 's/[[:space:]]//g; s/,/, /g')]"
target=/etc/netplan/60-lab.yaml

dev_by_mac() { ip -o link | awk -v m="$1" '!f && tolower($0) ~ m {gsub(":","",$2); sub(/@.*/,"",$2); print $2; f=1}'; }
lab_dev="$(dev_by_mac "$lab_mac")"
mgmt_dev="$(dev_by_mac "$mgmt_mac")"
[[ -n "$lab_dev" ]]  || die "Nu gasesc interfata LAB cu MAC ${lab_mac}"
[[ -n "$mgmt_dev" ]] || die "Nu gasesc interfata MGMT cu MAC ${mgmt_mac}"

tmp="$(mktemp)"
cat > "$tmp" <<EOF
# Generat de Vagrant (net-linux.sh). Nu edita manual.
network:
  version: 2
  renderer: networkd
  ethernets:
    mgmt:
      match:
        macaddress: "${mgmt_mac}"
      critical: true
      dhcp4: true
      dhcp6: false
      link-local: []
      dhcp4-overrides:
        use-routes: false
        use-dns: false
        use-domains: false
        use-ntp: false
        use-hostname: false
    lab:
      match:
        macaddress: "${lab_mac}"
      dhcp4: false
      dhcp6: false
      link-local: []
      addresses: ["${LAB_IP}/${LAB_PREFIX}"]
      routes:
        - to: default
          via: ${LAB_GW}
      nameservers:
        addresses: ${dns_yaml}
        search: [${LAB_DOMAIN}]
EOF

if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
  rm -f "$tmp"
  log "Netplan neschimbat"
else
  # Dezactiveaza celelalte configuratii netplan (backup) si generarea de retea din cloud-init.
  mkdir -p /etc/netplan/lab-backup
  find /etc/netplan -maxdepth 1 -name '*.yaml' ! -name '60-lab.yaml' -exec mv -f {} /etc/netplan/lab-backup/ \;
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-lab-disable-network-config.cfg
  fi
  install -m 600 -o root -g root "$tmp" "$target"
  rm -f "$tmp"
  netplan generate

  # Rute default ramase pe MGMT din vechiul lease (KeepConfiguration le-ar pastra).
  while read -r r; do
    [[ -n "$r" ]] || continue
    # shellcheck disable=SC2086  # r = specificatia rutei, trebuie despartita in cuvinte
    ip -4 route del $r dev "$mgmt_dev" 2>/dev/null || true
  done < <(ip -4 route show default dev "$mgmt_dev")

  networkctl reload
  networkctl reconfigure "$lab_dev" "$mgmt_dev"
  log "networkd reconfigurat sincron (${lab_dev}, ${mgmt_dev}); KeepConfiguration: $(grep -h '^KeepConfiguration=' /run/systemd/network/*netplan-mgmt*.network 2>/dev/null || echo '<lipsa>')"
fi

# Verificare: iesirea spre Internet trebuie sa fie pe LAB (prin pfSense), max ~30s.
egress_dev=""
for _ in $(seq 1 30); do
  egress_dev="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '!f {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); f=1; break}}')" || egress_dev=""
  [[ "$egress_dev" == "$lab_dev" ]] && break
  sleep 1
done

n_default="$(ip -4 route show default | wc -l)"
log "LAB=${LAB_IP}/${LAB_PREFIX} dev=${lab_dev} gw=${LAB_GW} dns=${LAB_DNS}; MGMT dev=${mgmt_dev}; egress=${egress_dev:-<nicio ruta>}; rute default=${n_default}"
[[ -n "$egress_dev" ]] || die "Nicio ruta spre Internet dupa 30s. Verifica: ip route; networkctl status ${lab_dev}; ping ${LAB_GW}"
[[ "$egress_dev" == "$lab_dev" ]] || die "Traficul spre Internet nu iese prin LAB (${lab_dev}), ci prin ${egress_dev}"
(( n_default == 1 )) || die "Exista ${n_default} rute default (astept 1, pe ${lab_dev}): $(ip -4 route show default | paste -sd';')"

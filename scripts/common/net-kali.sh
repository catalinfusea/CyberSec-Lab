#!/usr/bin/env bash
# Kali (box kalilinux/rolling): retea gestionata DOAR de systemd-networkd.
# NIC1 (VMnet3) static + default route prin pfSense; NIC0 (NAT Vagrant) DHCP fara rute/DNS.
# Aceeasi logica ca net-linux.sh (netplan -> networkd pe Ubuntu), dar fara netplan.
# Box-ul vine cu NetworkManager SI systemd-networkd active pe eth0 (2 lease-uri DHCP) ->
# NetworkManager e oprit si mascat, 20-wired.network e mutat in backup.
# Idempotent (run: always). Interfetele se identifica dupa MAC, nu dupa nume.
# Aplicare sincrona, fara sa cada sesiunea SSH a Vagrant (care vine pe NIC0):
#   - NIC0 primeste aceeasi adresa (rezervare DHCP VMnet8 pe MAC) si KeepConfiguration
#     impiedica stergerea adresei DHCP la reconfigurare;
#   - pe NIC0 se sterg doar rutele default (SSH-ul vine de la gateway-ul NAT, on-link).
# shellcheck source=lib.sh
source /tmp/lab-lib.sh
# Fix 2026-10-21: awk fara `exit` in pipeline-uri (cu pipefail, `exit` -> SIGPIPE pe `ip` -> iesire silentioasa; masurat 37/200 pe lin01).

for v in LAB_MAC LAB_MGMT_MAC LAB_IP LAB_PREFIX LAB_GW LAB_DNS LAB_DOMAIN; do require_env "$v"; done

# shellcheck disable=SC2153  # LAB_MAC vine din env (Vagrant)
lab_mac="${LAB_MAC,,}"
mgmt_mac="${LAB_MGMT_MAC,,}"
netdir=/etc/systemd/network
bkdir="${netdir}/lab-backup"   # subdirector: networkd citeste doar fisierele din $netdir

dev_by_mac() { ip -o link | awk -v m="$1" '!f && tolower($0) ~ m {gsub(":","",$2); sub(/@.*/,"",$2); print $2; f=1}'; }
lab_dev="$(dev_by_mac "$lab_mac")"
mgmt_dev="$(dev_by_mac "$mgmt_mac")"
[[ -n "$lab_dev" ]]  || die "Nu gasesc interfata LAB cu MAC ${lab_mac}"
[[ -n "$mgmt_dev" ]] || die "Nu gasesc interfata MGMT cu MAC ${mgmt_mac}"

# KeepConfiguration: valorile s-au redenumit in systemd 257 (dhcp -> dynamic).
sd_ver="$(systemctl --version | awk 'NR==1{print $2+0}')"
if (( sd_ver >= 257 )); then keep=dynamic; else keep=dhcp; fi

changed=0
put() { # put <fisier> <mod> ; continutul vine pe stdin
  local target="$1" mode="$2" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
  else
    rm -f "$target"   # inclusiv symlink (ex. resolv.conf)
    install -m "$mode" -o root -g root "$tmp" "$target"; rm -f "$tmp"
    log "Scris: $target"; changed=1
  fi
}

put "${netdir}/10-lab-mgmt.network" 644 <<EOF2
# Generat de Vagrant (net-kali.sh). Nu edita manual.
[Match]
MACAddress=${mgmt_mac}

[Network]
DHCP=ipv4
LinkLocalAddressing=no
IPv6AcceptRA=no
KeepConfiguration=${keep}

[DHCPv4]
ClientIdentifier=mac
UseRoutes=no
UseDNS=no
UseDomains=no
UseNTP=no
UseHostname=no
EOF2

dns_lines="$(echo "$LAB_DNS" | tr ',' '\n' | sed 's/[[:space:]]//g; /^$/d')"

{
  echo "# Generat de Vagrant (net-kali.sh). Nu edita manual."
  echo "[Match]"
  echo "MACAddress=${lab_mac}"
  echo
  echo "[Network]"
  echo "Address=${LAB_IP}/${LAB_PREFIX}"
  echo "Gateway=${LAB_GW}"
  while read -r d; do echo "DNS=${d}"; done <<< "$dns_lines"
  echo "Domains=${LAB_DOMAIN}"
  echo "LinkLocalAddressing=no"
  echo "IPv6AcceptRA=no"
} | put "${netdir}/10-lab-lab.network" 644

# systemd-resolved e inactiv pe box -> resolv.conf static (scris inainte de NetworkManager).
{
  echo "# Generat de Vagrant (net-kali.sh). Nu edita manual."
  echo "search ${LAB_DOMAIN}"
  while read -r d; do echo "nameserver ${d}"; done <<< "$dns_lines"
  echo "options timeout:2 attempts:2"
} | put /etc/resolv.conf 644

# Config-ul original al box-ului (Name=eth0, DHCP=yes) -> backup.
mkdir -p "$bkdir"
for f in "${netdir}"/*.network; do
  [[ -e "$f" ]] || continue
  case "$(basename "$f")" in 10-lab-mgmt.network|10-lab-lab.network) continue;; esac
  mv -f "$f" "$bkdir/"; log "Mutat in backup: $f"; changed=1
done

# Un singur manager: NetworkManager oprit + mascat. La stop, NM lasa adresele/rutele pe loc.
if [[ "$(systemctl is-enabled NetworkManager.service 2>/dev/null || true)" != "masked" ]]; then
  systemctl disable --now NetworkManager.service NetworkManager-wait-online.service 2>/dev/null || true
  systemctl mask NetworkManager.service >/dev/null
  log "NetworkManager oprit si mascat"; changed=1
fi
systemctl enable systemd-networkd.service >/dev/null 2>&1 || true

if (( changed )); then
  # Resturi de la NM/20-wired: rute default pe MGMT (SSH-ul nu depinde de ele) si orice adresa pe LAB.
  while read -r r; do
    [[ -n "$r" ]] || continue
    # shellcheck disable=SC2086  # r = specificatia rutei, trebuie despartita in cuvinte
    ip -4 route del $r dev "$mgmt_dev" 2>/dev/null || true
  done < <(ip -4 route show default dev "$mgmt_dev")
  ip -4 addr flush dev "$lab_dev"
  networkctl reload
  networkctl reconfigure "$lab_dev" "$mgmt_dev"
  log "networkd reconfigurat (${lab_dev}, ${mgmt_dev}); KeepConfiguration=${keep} (systemd ${sd_ver})"
else
  log "Config retea neschimbat"
fi

# Verificare: iesirea spre Internet trebuie sa fie pe LAB (prin pfSense), max ~30s.
egress_dev=""
for _ in $(seq 1 30); do
  egress_dev="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '!f {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); f=1; break}}')" || egress_dev=""
  [[ "$egress_dev" == "$lab_dev" ]] && break
  sleep 1
done

n_default="$(ip -4 route show default | wc -l)"
log "LAB=${LAB_IP}/${LAB_PREFIX} dev=${lab_dev} gw=${LAB_GW} dns=$(echo "$dns_lines" | paste -sd,); MGMT dev=${mgmt_dev}; egress=${egress_dev:-<nicio ruta>}; rute default=${n_default}"
[[ -n "$egress_dev" ]] || die "Nicio ruta spre Internet dupa 30s. Verifica: ip route; networkctl status ${lab_dev}; ping ${LAB_GW}"
[[ "$egress_dev" == "$lab_dev" ]] || die "Traficul spre Internet nu iese prin LAB (${lab_dev}), ci prin ${egress_dev}"
(( n_default == 1 )) || die "Exista ${n_default} rute default (astept 1, pe ${lab_dev}): $(ip -4 route show default | paste -sd';')"

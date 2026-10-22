#!/usr/bin/env bash
# admin01 (Kali): configurare de baza. Idempotent (run: always).
#   1. fus orar din lab.yml (aliniere timestamps cu restul lab-ului / Wazuh);
#   2. sshd doar cu cheie (Vagrant foloseste cheia generata la primul up);
#   3. ~/.ssh/config pentru pfSense (bloc gestionat intre markeri, restul fisierului ramane).
# NU automatizeaza (vezi README, sectiunea admin01): cheia SSH pentru pfSense, parola userului vagrant.
# shellcheck source=../common/lib.sh
source /tmp/lab-lib.sh

for v in LAB_TZ LAB_PFSENSE_IP LAB_ADMIN_USER; do require_env "$v"; done

# --- 1. Fus orar ---------------------------------------------------------------
[[ -f "/usr/share/zoneinfo/${LAB_TZ}" ]] || die "Fus orar inexistent: ${LAB_TZ}"
if [[ "$(timedatectl show -p Timezone --value)" != "$LAB_TZ" ]]; then
  timedatectl set-timezone "$LAB_TZ"
  log "Fus orar setat: ${LAB_TZ}"
fi

# --- 2. sshd doar cu cheie -------------------------------------------------------
# OpenSSH ia prima valoare gasita; Include-ul e la inceputul sshd_config (Debian/Kali),
# iar fisierele din sshd_config.d se citesc in ordine lexicala -> 00-* castiga.
sshd_main=/etc/ssh/sshd_config
dropin=/etc/ssh/sshd_config.d/00-lab.conf
grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$sshd_main" \
  || die "${sshd_main} nu include sshd_config.d/*.conf; drop-in-ul nu s-ar aplica"

tmp="$(mktemp)"
cat > "$tmp" <<'EOF'
# Generat de Vagrant (kali-base.sh). Nu edita manual.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
if [[ -f "$dropin" ]] && cmp -s "$tmp" "$dropin"; then
  rm -f "$tmp"
else
  install -D -m 644 -o root -g root "$tmp" "$dropin"; rm -f "$tmp"
  sshd -t || { rm -f "$dropin"; die "sshd -t a esuat; drop-in sters, sshd neatins"; }
  systemctl try-reload-or-restart ssh.service   # sesiunile SSH existente raman
  log "Scris: ${dropin}; sshd reincarcat"
fi
pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}' || true)"
[[ "$pa" == "no" ]] || die "sshd efectiv: passwordauthentication=${pa:-?} (astept no)"

# --- 3. ~/.ssh/config pentru pfSense ----------------------------------------------
home="$(getent passwd "$LAB_ADMIN_USER" | cut -d: -f6)"
[[ -n "$home" && -d "$home" ]] || die "Nu gasesc home pentru ${LAB_ADMIN_USER}"
grp="$(id -gn "$LAB_ADMIN_USER")"
sshdir="${home}/.ssh"
cfg="${sshdir}/config"
install -d -m 700 -o "$LAB_ADMIN_USER" -g "$grp" "$sshdir"

begin='# BEGIN lab-managed (kali-base.sh). Nu edita intre markeri.'
end='# END lab-managed'
tmp="$(mktemp)"
{
  # Blocul gestionat primul: la optiuni duplicate, ssh ia prima valoare.
  echo "$begin"
  echo "Host pfsense"
  echo "  HostName ${LAB_PFSENSE_IP}"
  echo "  User admin"
  echo "  IdentityFile ~/.ssh/pfsense"
  echo "  IdentitiesOnly yes"
  echo "$end"
  if [[ -f "$cfg" ]]; then
    awk -v b="$begin" -v e="$end" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' "$cfg"
  fi
} > "$tmp"
if [[ -f "$cfg" ]] && cmp -s "$tmp" "$cfg"; then
  rm -f "$tmp"
else
  install -m 600 -o "$LAB_ADMIN_USER" -g "$grp" "$tmp" "$cfg"; rm -f "$tmp"
  log "Scris: ${cfg} (Host pfsense)"
fi

# Un "Host pfsense" scris manual in afara blocului e redundant (blocul gestionat are prioritate).
n_host="$(grep -Ec '^[[:space:]]*Host[[:space:]]+pfsense([[:space:]]|$)' "$cfg" || true)"
(( n_host <= 1 )) || log "ATENTIE: ${cfg} are ${n_host} intrari 'Host pfsense'; sterge-o pe cea manuala (in afara markerilor)"

if [[ ! -f "${sshdir}/pfsense" ]]; then
  log "ATENTIE: lipseste ${sshdir}/pfsense. Pas manual: genereaza cheia si pune-o in pfSense (README, admin01)"
fi

log "admin-base OK: tz=${LAB_TZ}; sshd passwordauthentication=${pa}; ssh config pfsense -> ${LAB_PFSENSE_IP}"

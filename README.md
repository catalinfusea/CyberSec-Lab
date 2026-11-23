# CyberSec-Lab: SOC home lab as code (Vagrant + VMware Workstation)

An isolated Active Directory lab behind a pfSense firewall, built and checked from code, used to generate
and analyse security telemetry with Wazuh, Sysmon, auditd and Suricata.

**What it covers**
- **Infrastructure as code:** Vagrant (`vmware_desktop`) with PowerShell and bash provisioners, pinned box versions,
  and an orchestrator (`lab-build.ps1`) that builds the machines in order, checks each one and stops at the first
  failure. `-CheckOnly` validates the whole lab without changing anything.
- **Active Directory:** a Windows Server 2022 domain controller (`lab.internal`) populated with BadBlood
  (about 1,000 users, 500+ groups), two domain-joined Windows 11 workstations and an Ubuntu server.
- **Telemetry:** Sysmon (sysmon-modular config) and advanced audit policy on Windows, auditd on Linux, and a Wazuh 4.14
  manager with agents on every endpoint. Suricata IDS runs on the pfSense LAN interface.
- **Isolation:** the host has no interface on the lab network. The pfSense and Wazuh web interfaces can only be
  reached through an SSH tunnel via a Kali admin VM, and pfSense rules block lab traffic to private ranges.
- **Engineering practice:** static validation (shellcheck, PowerShell and YAML syntax, Ruby tests for the Vagrantfile),
  a troubleshooting log of real problems and fixes, documented known risks, and an explicit tested/untested status
  for each orchestrator path.

**Status:** phase 1 works end to end (validated 2026-10-21). Phase 2 (Elastic Security) is planned.

> The operational documentation below is in Romanian.

![CyberSec-Lab topology](docs/cybersec-lab-topology.png)

---

# Lab SOC: Vagrant + VMware Workstation

Pașii manuali (VMware, pfSense, host): [docs/MANUAL-SETUP.md](docs/MANUAL-SETUP.md)

Faza 1: dc01 (AD + BadBlood), wazuh01 (Wazuh AIO), ws01/ws02 (Win11, join, Sysmon, agent Wazuh),
lin01 (auditd, agent Wazuh), admin01 (Kali, admin + atac). Toate pe VMnet3, în spatele pfSense (192.168.0.254).
Faza 2 (decis 2026-10-21: nu acum): elastic01, doar rețea, fără provisioning.

**Stare (2026-10-21):** toate VM-urile din faza 1 construite și validate pe host
(`.\lab-build.ps1 -CheckOnly` → toate OK). Validare statică: `tests/validate.sh` (Ruby/YAML/PowerShell/shellcheck
+ test Vagrantfile cu stub). Netestate încă: ramurile din `lab-build.ps1` care creează o mașină de la zero,
reprovizionează ws/dc, așteaptă promovarea DC și detectează un forward pierdut (vezi „Orchestrator”).

## Valabil pentru
- Host: Windows, PowerShell 5.1, VMware Workstation 26H1, Vagrant 2.4.9, plugin vagrant-vmware-desktop 3.0.5,
  Vagrant VMware Utility (serviciul `VagrantVMware`).
- Box-uri: gusztavvargadr (versiuni fixate în `config/lab.yml`, release 2607), kalilinux/rolling 2026.2.0.
- Wazuh 4.14 (manager) / agent 4.14.8-1. BadBlood @ b3c6325. sysmon-modular configs-082cba578667 (Sysmon 15.21;
  pe VM-uri rulează Sysmon 15.22, binarul Sysinternals „latest”).

## Plan de adrese
| VM | IP (VMnet3) | MAC NIC0 (NAT) | NAT VMnet8 (rezervare) | MAC NIC1 (VMnet3) |
|---|---|---|---|---|
| dc01 | 192.168.0.10 | 00:50:56:3A:00:0A | `<subnet VMnet8>`.10 | 00:50:56:3B:00:0A |
| wazuh01 | 192.168.0.20 | 00:50:56:3A:00:14 | .20 | 00:50:56:3B:00:14 |
| elastic01 (faza 2) | 192.168.0.21 | ...:15 | .21 | ...:15 |
| ws01 | 192.168.0.31 | ...:1F | .31 | ...:1F |
| ws02 | 192.168.0.32 | ...:20 | .32 | ...:20 |
| lin01 | 192.168.0.41 | ...:29 | .41 | ...:29 |
| admin01 (Kali) | 192.168.0.50 | ...:32 | .50 | ...:32 |

Host-ul nu are adaptor pe VMnet3; ajunge la VM-uri doar prin port-forward-urile NAT VMnet8 (`vmnetnat.conf`),
folosite de `vagrant ssh/winrm`. GUI-urile se deschid prin tunel SSH prin admin01 (vezi „Acces GUI”).

## Pregătire host (o singură dată)
```powershell
# Box-urile si plugin-urile Vagrant in E:\CyberSec-Lab\VagrantBoxes (deschide un terminal NOU dupa setare)
[Environment]::SetEnvironmentVariable('VAGRANT_HOME', 'E:\CyberSec-Lab\VagrantBoxes', 'User')
# In terminalul nou: plugin-urile stau in VAGRANT_HOME, deci daca l-ai schimbat, reinstaleaza:
vagrant plugin install vagrant-vmware-desktop
```
Workaround-uri VMware Workstation 26H1 (rulează ca Administrator; ambele fac backup în `reg-backup\`):
- `.\fix-vmware26-registry.ps1`: utility-ul caută cheile Workstation în WOW6432Node; 26H1 le scrie doar în view-ul 64-bit.
- `.\fix-vmware26-dhcp-reservations.ps1`: rezervările DHCP VMnet8 pentru toate mașinile din `lab.yml`, în WOW6432Node.
  Reruleaz-o după ce adaugi o mașină în `lab.yml`.

Clonele VM ajung în `E:\CyberSec-Lab\VMs` (`vmware_clone_directory: "VMs"` din `lab.yml`).

**Antivirus pe host (Norton, observat 2026-10-21):** Behavioral Protection raportează `IDP.Generic` pe
`powershell.exe` la primul rulaj al unui `.ps1` nou sau modificat (reputație „Unknown”). Fals pozitiv în cazurile
verificate. Procedură: compară hash-ul (`Get-FileHash`) cu cel al versiunii scrise, apoi excepție **doar pe fișier**
(nu pe `powershell.exe`, nu pe tot folderul). Se repetă la fiecare modificare a scriptului.

## pfSense, înainte de primul up
- Regula implicită LAN → any activă; Outbound NAT automat (implicit).
- DNS Resolver (Unbound) activ pe LAN: dc01 îl folosește ca forwarder, wazuh01 direct.
- IP-urile statice ale lab-ului sunt în afara pool-ului DHCP (.100–.200).

## Rulare

### Orchestrator: `lab-build.ps1`
Construiește sau reia lab-ul în ordinea din `lab.yml`, verifică fiecare mașină și se oprește la prima eroare.
Pentru fiecare `vagrant up/provision` folosește `lab-up.ps1` (log în `logs\`).
```powershell
cd E:\CyberSec-Lab
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab-build.ps1 -CheckOnly       # doar verificari, nu schimba nimic
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab-build.ps1                  # toate masinile cu autostart != false
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab-build.ps1 -From ws01       # reia de la ws01
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab-build.ps1 -Only lin01 -Snapshot
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab-build.ps1 -Only elastic01  # elastic01 doar explicit
```
- Preflight: vagrant + VMware Utility răspund, rezervări DHCP, disc (`-MinFreeDiskGB`, implicit 60), RAM,
  box-uri descărcate (doar avertisment; box-ul Win11 a durat ~2 h), backup `vmnetnat.conf` în `reg-backup\`.
- Parola DSRM se cere o singură dată, la început, doar dacă dc01 trebuie creat.
- Pe fiecare mașină: verificarea trece → skip; necreată → up (dc01: + așteaptă DomainRole=5 + provision
  `dc-post,badblood,sysmon,wazuh-agent`); oprită → up; pornită dar verificarea pică → reprovizionare doar
  pentru ws și dc (provisioneri idempotenți), altfel stop cu comanda sugerată.
- După fiecare schimbare compară `vmnetnat.conf`: un forward dispărut = stop.
- Exit 0 = toate OK; 1 = cel puțin o mașină FAIL (sumarul arată motivul).

| Ramură | Stare |
|---|---|
| `-CheckOnly`, test negativ (elastic01 FAIL, exit 1) | testat 2026-10-21 |
| mașină oprită → pornit (lin01) | testat 2026-10-21 |
| creare de la zero, reprovizionare ws/dc, așteptare DomainRole=5, forward pierdut | **netestat** |

### O singură mașină: `lab-up.ps1`
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab-up.ps1 -Machine ws01 -Provision -NatMac 00:50:56:3a:00:1f
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab-up.ps1 -Machine dc01 -Action provision -ProvisionWith dc-post,badblood,sysmon,wazuh-agent
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab-up.ps1 -Machine ws02 -Action provision -ProvisionWith tz
```
Nu rula `vagrant up` fără nume de mașină. Parola DSRM se cere doar dacă rulează `dc-promote`
(primul up al dc01, `provision` fără listă, `--provision`, sau listă care conține `dc-promote`).
`--provision-with X` rulează doar provisionerul X (nu și pe cei `run: always`).

După fiecare etapă stabilă, fă snapshot: `vagrant snapshot save dc01 post-badblood`.

## Verificări după up
Rapid: `.\lab-build.ps1 -CheckOnly`. Manual (în `vagrant winrm/ssh -c '...'` fără ghilimele duble; în PS 5.1 se
pierd la transmitere — folosește `''...''`):
```powershell
vagrant winrm dc01 -c '@(Get-ADUser -Filter *).Count; Resolve-DnsName lab.internal -DnsOnly | Format-Table | Out-String' 2>&1 | Out-String
vagrant winrm ws01 -c '(Find-NetRoute -RemoteIPAddress 1.1.1.1 | Select-Object -First 1).InterfaceAlias; Get-Service Sysmon64,WazuhSvc | Format-Table Name,Status | Out-String; nltest /sc_verify:lab.internal' 2>&1 | Out-String
vagrant ssh wazuh01 -c 'sudo /var/ossec/bin/agent_control -l' 2>&1 | Out-String
Select-String C:\ProgramData\VMware\vmnetnat.conf -Pattern '^\s*\d+\s*=\s*\d'     # forward-urile NAT
```
Parole Wazuh (output sensibil, nu-l lăsa în loguri): `vagrant ssh wazuh01 -c 'sudo tar -O -xf /root/wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt'`

## Acces GUI (pfSense, Wazuh)
Prin tunel SSH prin admin01, de pe host (fereastra rămâne deschisă cât folosești GUI-ul):
```powershell
vagrant ssh admin01 -- -L 8443:192.168.0.254:443 -N     # pfSense -> https://localhost:8443
vagrant ssh admin01 -- -L 8444:192.168.0.20:443 -N      # Wazuh dashboard -> https://localhost:8444 (testat 2026-10-21)
```

Test vizibilitate east-west pentru Suricata (pe pfSense, în timp ce ws01 dă ping la dc01):
`tcpdump -ni em1 icmp and host 192.168.0.31 and host 192.168.0.10`

## admin01 (Kali): ce e automat și ce nu
Automat (Vagrantfile + `scripts/common/net-kali.sh` + `scripts/admin/kali-base.sh`, la fiecare up):
rețea doar prin systemd-networkd (NetworkManager mascat), `isolation.tools` (fără copy/paste,
drag&drop, shared folders cu host-ul), fus orar din `lab.yml`, sshd doar cu cheie,
`~/.ssh/config` cu `Host pfsense`.

Manual, după fiecare `vagrant destroy` + `up` (secretele nu stau în repo):
1. Cheia SSH pentru pfSense, în guest: `ssh-keygen -t ed25519 -f ~/.ssh/pfsense -C admin01-pfsense` (cu passphrase).
2. Pe host: `vagrant ssh admin01 -c 'cat ~/.ssh/pfsense.pub' | Set-Clipboard` → pfSense: System → User Manager →
   admin → Authorized SSH Keys (înlocuiește cheia veche) → Save.
3. Test în guest: `ssh pfsense`.
4. Parola userului vagrant (consola VMware), pe host: `vagrant ssh admin01 -c 'sudo passwd vagrant'`.
   Login-ul SSH cu parolă e oricum dezactivat.

## pfSense: configurare manuală (nu e în Vagrant)
Stă în `config.xml` al pfSense. Backup după fiecare schimbare: Diagnostics → Backup & Restore →
Download configuration, în `pfsense-backup/` (exclus din git: conține hash-uri de parole și chei).
- Alias port `443_22` (22, 443).
- LAN, în ordine: Allow DNS to pfSense; `admin01 -> pfSense mgmt` (TCP 192.168.0.50 → LAN address, port `443_22`);
  `dc01 -> pfSense NTP` (UDP 192.168.0.10 → LAN address, port 123); Block lab to RFC1918; Block lab to pfSense;
  Default allow LAN to any. Regulile „allow” spre pfSense trebuie să fie **deasupra** lui „Block lab to RFC1918”:
  alias-ul RFC1918 conține 192.168.0.0/16, deci și LAN address.
- Services → NTP: activ, Interface = LAN + Localhost (nu WAN), Time Servers `2.pfsense.pool.ntp.org` (pool).
  E sursa de timp pentru dc01 (`02-post-promote.ps1`); fără regula NTP de mai sus, dc01 rămâne pe ceasul local.
- SSH activ, „Public Key Only”; cheia lui admin01 la userul admin.
- Anti-Lockout dezactivat (System → Advanced → Admin Access → „Disable webConfigurator anti-lockout rule” bifat,
  confirmat 2026-10-21): GUI/SSH pfSense doar prin regula `admin01 -> pfSense mgmt`. Atenție: opțiunea
  „Set interface(s) IP address” din consola pfSense reactivează Anti-Lockout – verifică după orice schimbare din consolă.
  Dacă regula admin01 se strică, acces de urgență din consola VMware a pfSense.
- Parola userului admin schimbată 2026-10-21 (nu mai e cea implicită). Parola stă în managerul de parole, nu în repo.
- Backup config după fiecare schimbare, în `pfsense-backup\` (exclus din git).

## Fus orar
Linux: `timezone` din `lab.yml` (`Etc/UTC`) se aplică doar pe admin01 (`kali-base.sh`); lin01/wazuh01 rămân pe fusul
box-ului (UTC în logurile din 2026-10-21). Windows: provisionerul `tz` (`scripts/win/timezone.ps1`, `run: always`)
setează `windows_timezone` din `lab.yml` (`UTC`). ws01/ws02 (box Win11) veneau pe Pacific Standard Time; dc01 era deja pe UTC.
dc01 e sursa de timp a domeniului (PDC, `tools.synctime FALSE`) și se sincronizează NTP de la pfSense
(`w32tm /config /manualpeerlist:192.168.0.254,0x8 /syncfromflags:manual /reliable:yes`, în `02-post-promote.ps1`,
env `LAB_NTP`). Verificat 2026-10-21: sursa `192.168.0.254,0x8`, stratum 5. Ceilalți membri rămân pe NT5DS (ierarhia domeniului).
Verificare: `vagrant winrm dc01 -c 'w32tm /query /source; w32tm /query /status' 2>&1 | Out-String`.

## Depanare (probleme întâlnite)
| Simptom | Cauză | Remediere |
|---|---|---|
| `Get "http://localhost:<port>/api/vmnet" ... actively refused` la orice comandă vagrant | `vmrest.exe` pornit de utility a murit; serviciul `VagrantVMware` arată Running | Ca Administrator: `Restart-Service VagrantVMware` (nu oprește VM-urile) |
| `Waiting for the VM to receive an address` | rezervare DHCP lipsă în WOW6432Node sau lease-uri vechi pe MAC | `.\fix-vmware26-dhcp-reservations.ps1`; `lab-up.ps1 -NatMac ...` verifică lease-urile |
| Un forward dispare din `vmnetnat.conf` după un up | rescriere de către plugin (observat o dată, lin01) | `vmrun -T ws stop <vmx> soft`, apoi `lab-up.ps1 -Machine <vm>` |
| `WinRMAuthorizationError` după promovarea DC | sesiunea WinRM a contului local cade după Install-ADDSForest | rezolvat: promovarea rulează în scheduled task (`01-promote.ps1`); restul provisionerilor DC sunt `run: never` |
| Provisionerul `net` Linux iese cu eroare fără niciun mesaj (intermitent) | `ip ... \| awk '{...; exit}'` + `pipefail` → SIGPIPE pe `ip` → `set -e` oprește scriptul | rezolvat 2026-10-21 în `net-linux.sh`, `net-kali.sh`, `hardening.sh` (awk fără `exit`) |
| `net` Windows: `Unable to set NetworkCategory ... 'Identifying...'` | NLA încă identifică rețeaua după schimbarea IP | rezolvat 2026-10-21 în `net-win.ps1` (retry 60 s, apoi warning) |
| `Linii pcislotnumber in log: 2` la VM-uri non-Kali | linii interne `Removing allowlisted VMX key: ethernetN.pcislotnumber` | zgomot; NIC-urile se identifică după MAC |
| `w32tm /stripchart /computer:192.168.0.254` → `0x800705B4` (timeout) | NTP spre pfSense blocat de „Block lab to RFC1918” | regula `dc01 -> pfSense NTP` deasupra blocurilor (vezi pfSense) |
| Rerulare `dc-post` → „vagrant adaugat in Schema/Enterprise Admins” | BadBlood (care le scoate) face skip după marker | rezolvat 2026-10-21: `02-post-promote.ps1` le adaugă doar dacă marker-ul `badblood` lipsește |
| `Exception calling "Read" ... line:100` | winrm-elevated | zgomot inofensiv |
| `vagrant box add ... \| Out-String` pare blocat | `Out-String` ține output-ul până la final | rulează fără `Out-String` ca să vezi progresul |

## Riscuri cunoscute (lab izolat, nu producție)
- `vagrant/vagrant` rămâne Domain Admin (folosit la join). Schema/Enterprise Admins sunt scoase după BadBlood
  și nu mai sunt readăugate la rerularea `dc-post`. Verificare: membership `vagrant` în cele 3 grupuri (True/False/False).
- `LocalAccountTokenFilterPolicy=1` pe ws01/ws02 (necesar pentru WinRM Vagrant cu UAC activ).
- `wazuh-install.sh` și `Sysmon.zip` nu pot fi fixate prin hash: se bazează pe TLS, respectiv pe semnătura Microsoft.
  MSI-ul Wazuh e verificat doar ca semnătură Authenticode validă.
- Box-urile sunt community builds (un singur maintainer).
- Înregistrarea agenților Wazuh fără parolă de enrollment.
- Excepțiile antivirus de pe host pentru `lab-up.ps1` / `lab-build.ps1` (doar pe fișier).

## Teste (în CI/Linux)
`tests/validate.sh` (necesită ruby ≥ 2.7, pwsh 7, shellcheck). Verifică sintaxa tuturor `.ps1`/`.sh`, `lab.yml`,
shellcheck cu severitate warning+, și `tests/vagrantfile_test.rb`: ordinea și tipul provisionerilor (inclusiv
`tz` pe Windows, `run: never` pe DC), MAC-uri și rezervări NAT unice, izolare VMware Tools, pcislotnumber Kali.
Ultima rulare: 2026-10-21, ruby 3.3.6, pwsh 7.4.6, shellcheck 0.11.0 → OK.

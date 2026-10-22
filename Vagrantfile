# -*- mode: ruby -*-
# Lab SOC: Vagrant + vagrant-vmware-desktop pe VMware Workstation (host Windows).
# Scris pentru Vagrant 2.4.x si plugin vagrant-vmware-desktop 3.0.x. NETESTAT end-to-end.
require "yaml"

LAB_DIR = File.dirname(__FILE__)
LAB = YAML.safe_load(File.read(File.join(LAB_DIR, "config", "lab.yml")))

NET    = LAB.fetch("network")
# Cale relativa in lab.yml -> relativa la folderul Vagrantfile (ex. E:/CyberSec-Lab/VMs).
CLONE_DIR = LAB["vmware_clone_directory"] && File.expand_path(LAB["vmware_clone_directory"], LAB_DIR)
DOMAIN = LAB.fetch("domain")

# MAC-uri statice in intervalul VMware pentru adrese manuale (00:50:56:00:00:00-3F:FF:FF).
# Motiv: actiunea Network a pluginului sterge cheile ethernetN.* la fiecare `up`;
# fara MAC static, NIC-ul ar primi alt MAC -> Windows il vede ca adaptor nou.
def lab_mac(prefix_byte, ip)
  last = ip.split(".").last.to_i
  raise ArgumentError, "IP invalid: #{ip}" unless (1..254).cover?(last)
  format("00:50:56:%s:00:%02X", prefix_byte, last)
end

# NIC0 = NAT Vagrant (management), NIC1 = VMnet3 (lab)
def mgmt_mac(ip)
  lab_mac("3A", ip)
end

def labnet_mac(ip)
  lab_mac("3B", ip)
end

# Secrete: doar din variabile de mediu, niciodata in repo.
def secret(name)
  v = ENV[name].to_s
  v.empty? ? "__MISSING_#{name}__" : v
end

# Subnetul NAT (VMnet8) citit din configul DHCP VMware al host-ului, nu hardcodat.
# Folosit pentru rezervari DHCP pe NIC0 (base_address): utility-ul respinge MAC-urile cu 2 lease-uri
# active cu hostname diferit (boot box = "vagrant", apoi numele VM-ului) si cade pe rezervare.
# Vezi go_src/vagrant-vmware-utility: utility/dhcp_lease_file.go (loadEntry), driver/advanced.go (LookupDhcpAddress).
def vmnet8_prefix
  conf = File.join(ENV.fetch("ProgramData", "C:/ProgramData"), "VMware", "vmnetdhcp.conf")
  abort "Nu pot citi #{conf} (subnetul VMnet8)." unless File.readable?(conf)
  seg = File.read(conf)[/^# Virtual ethernet segment 8\b.*?^# End/m]
  m = seg && seg.match(/^\s*subnet\s+(\d+\.\d+\.\d+)\.0\s+netmask\s+255\.255\.255\.0\s*\{/)
  abort "Nu gasesc in #{conf} un subnet /24 pentru VMnet8." unless m
  m[1]
end

# Adresa rezervata pe VMnet8: acelasi ultim octet ca IP-ul din lab.
# Pluginul accepta doar .2-.127 (.128-.254 = pool DHCP); .2 = gateway NAT, deci 3..127.
def mgmt_address(nat_prefix, ip)
  last = ip.split(".").last.to_i
  raise ArgumentError, "Octet #{last} in afara 3..127 pentru rezervarea VMnet8 (#{ip})" unless (3..127).cover?(last)
  "#{nat_prefix}.#{last}"
end

unless Vagrant.has_plugin?("vagrant-vmware-desktop")
  abort "Lipseste plugin-ul vagrant-vmware-desktop (vagrant plugin install vagrant-vmware-desktop)."
end

# Netplan pe Linux e gestionat exclusiv de provisioner-ul `net` (scripts/common/net-linux.sh).
# Vagrant core (plugins/guests/debian/cap/configure_networks.rb) scrie 50-vagrant.yaml si
# ruleaza `netplan apply` la fiecare `up`/`reload` -> SSH cade si plugin-ul da "not yet ready for SSH".
# Capability-ul inregistrat pe :ubuntu / :kali are prioritate fata de cel de pe :debian (parinte),
# deci core-ul ramane neatins. Se aplica doar guest-urilor detectate ca Ubuntu sau Kali
# (Kali: plugins/guests/kali, guest(:kali, :debian), detectie dupa ID=kali din os-release).
# Pe Kali reteaua e gestionata de scripts/common/net-kali.sh (systemd-networkd).
module LabSkipNetCfg
  class Cap
    def self.configure_networks(machine, _networks)
      machine.ui.info("configure_networks: skipped (gestionat de provisioner net)")
    end
  end

  class Plugin < Vagrant.plugin("2")
    name "lab-skip-configure-networks"
    guest_capability(:ubuntu, :configure_networks) { Cap }
    guest_capability(:kali, :configure_networks) { Cap }
  end
end

NAT_PREFIX = vmnet8_prefix

Vagrant.configure("2") do |config|
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.boot_timeout = 1200

  LAB.fetch("machines").each do |m|
    name = m.fetch("name")
    role = m.fetch("role")
    box  = LAB.fetch("boxes").fetch(m.fetch("box"))
    ip   = m.fetch("ip")
    windows = %w[dc ws].include?(role)
    kali    = box.fetch("name").start_with?("kalilinux/")

    config.vm.define name, autostart: m.fetch("autostart", true) do |node|
      node.vm.box         = box.fetch("name")
      node.vm.box_version = box.fetch("version")
      node.vm.hostname    = name

     if windows
        node.vm.guest        = :windows
        node.vm.communicator = "winrm"
        node.winrm.username  = "vagrant"
        node.winrm.password  = "vagrant"
        node.winrm.timeout   = 300   # implicit 1800 > boot_timeout 1200 -> o conexiune agatata consuma tot boot-ul
      end

      node.vm.provider "vmware_desktop" do |v|
        v.gui    = false
        v.cpus   = m.fetch("cpus")
        v.memory = m.fetch("memory")
        v.linked_clone = true
        v.clone_directory = CLONE_DIR if CLONE_DIR
        # IP-ul de management se ia din leases-urile VMnet8 (NIC0), nu din vmrun,
        # care ar putea intoarce IP-ul de pe VMnet3 si l-am schimba in timpul provisioning-ului.
        v.enable_vmrun_ip_lookup = false
        v.base_mac = mgmt_mac(ip)
        v.base_address = mgmt_address(NAT_PREFIX, ip)  # rezervare DHCP VMnet8 pt base_mac

        v.vmx["displayname"]             = "lab-#{name}"
        v.vmx["ethernet1.present"]       = "TRUE"
        v.vmx["ethernet1.connectiontype"] = "custom"
        v.vmx["ethernet1.vnet"]          = NET.fetch("vnet")
        v.vmx["ethernet1.virtualdev"]    = "e1000e"
        v.vmx["ethernet1.addresstype"]   = "static"
        v.vmx["ethernet1.address"]       = labnet_mac(ip)
        v.vmx["tools.synctime"]          = "FALSE" if role == "dc" # DC = sursa de timp
        # RTC-ul virtual e implicit pe ora locala a host-ului; Linux il citeste ca UTC.
        v.vmx["rtc.diffFromUTC"]         = "0" unless windows
        # Box-ul Kali vine cu pcislotnumber in .vmx; pluginul il suprascrie azi, dar avertizeaza ca va inceta.
        # Fixate la valorile detectate la primul up (2026-10-20) -> ordinea eth0/eth1 ramane stabila.
        if kali
          v.vmx["ethernet0.pcislotnumber"] = "33"
          v.vmx["ethernet1.pcislotnumber"] = "192"
        end
        # VM-uri victima + admin01 (tool-uri de atac): fara canale host<->guest prin VMware Tools
        # (copy/paste, drag&drop, shared folders). Nu afecteaza `vagrant ssh` (merge prin NIC0).
        if %w[dc ws linux admin].include?(role)
          v.vmx["isolation.tools.copy.disable"]  = "TRUE"
          v.vmx["isolation.tools.paste.disable"] = "TRUE"
          v.vmx["isolation.tools.dnd.disable"]   = "TRUE"
          v.vmx["isolation.tools.hgfs.disable"]  = "TRUE"
        end
      end

      net_env = {
        "LAB_MAC"      => labnet_mac(ip),
        "LAB_MGMT_MAC" => mgmt_mac(ip),
        "LAB_IP"       => ip,
        "LAB_PREFIX"   => NET.fetch("prefix").to_s,
        "LAB_GW"       => NET.fetch("gateway"),
        "LAB_DOMAIN"   => DOMAIN.fetch("fqdn"),
        # wazuh01 si dc01 (pre-promote) folosesc pfSense; restul DC-ul, cu pfSense ca fallback.
        "LAB_DNS"      => (%w[wazuh dc elastic].include?(role) ? NET.fetch("pfsense_dns") : "#{NET.fetch('dc_ip')},#{NET.fetch('pfsense_dns')}")
      }

      if windows
        node.vm.provision "lab-dir", type: "shell", run: "always",
          inline: "New-Item -ItemType Directory -Force -Path C:\\lab | Out-Null"
        node.vm.provision "lab-lib", type: "file", run: "always",
          source: "scripts/common/lib.ps1", destination: "C:/lab/lib.ps1"
        node.vm.provision "net", type: "shell", run: "always",
          path: "scripts/common/net-win.ps1", env: net_env
        # run: always -> pe DC se reaplica dupa promovare (subcategoriile Directory Service)
        node.vm.provision "audit", type: "shell", run: "always", path: "scripts/win/audit-policy.ps1"
        # Fus orar (box-urile vin pe Pacific Standard Time). run: always -> aplicat si pe VM-urile existente.
        node.vm.provision "tz", type: "shell", run: "always", path: "scripts/win/timezone.ps1",
          env: { "LAB_WIN_TZ" => LAB.fetch("windows_timezone", "UTC") }
      else
        node.vm.provision "lab-lib", type: "file", run: "always",
          source: "scripts/common/lib.sh", destination: "/tmp/lab-lib.sh"
        node.vm.provision "net", type: "shell", run: "always",
          path: (kali ? "scripts/common/net-kali.sh" : "scripts/common/net-linux.sh"), env: net_env
		# node.vm.provision "reconectare-retea", type: "shell", reboot: true # Forțăm o reconectare Vagrant pentru a prinde interfețele cu noile IP-uri
      end

      wazuh_win_env = {
        "WAZUH_VERSION" => LAB.dig("wazuh", "agent_version"),
        "WAZUH_MANAGER" => LAB.dig("wazuh", "manager_ip"),
        "WAZUH_GROUP"   => "windows"
      }
      sysmon_env = {
        "SYSMON_CONFIG_URL"    => LAB.dig("sysmon", "config_url"),
        "SYSMON_CONFIG_SHA256" => LAB.dig("sysmon", "config_sha256")
      }

      case role
      when "wazuh"
        node.vm.provision "wazuh-aio", type: "shell", path: "scripts/wazuh/install-aio.sh",
          env: { "WAZUH_SERIES" => LAB.dig("wazuh", "series"), "LAB_IP" => ip }
        # run: always -> ufw + rpcbind mascat se reaplica la fiecare up/provision (idempotent).
        node.vm.provision "wazuh-hardening", type: "shell", run: "always",
          path: "scripts/wazuh/hardening.sh",
          env: net_env.merge("WAZUH_TCP_PORTS" => "22,443,1514,1515,55000")

      when "dc"
        # Promovarea ruleaza intr-un scheduled task care face si reboot-ul (vezi 01-promote.ps1):
        # sesiunea WinRM a Vagrant pica (WinRMAuthorizationError) dupa Install-ADDSForest.
        # Restul provisionerilor DC sunt run: "never" -> se ruleaza explicit dupa DomainRole=5:
        #   vagrant provision dc01 --provision-with dc-post,badblood,sysmon,wazuh-agent
        node.vm.provision "dc-promote", type: "shell", path: "scripts/dc/01-promote.ps1",
          sensitive: true,
          env: { "LAB_DOMAIN" => DOMAIN.fetch("fqdn"), "LAB_NETBIOS" => DOMAIN.fetch("netbios"),
                 "LAB_DSRM_PASSWORD" => secret("LAB_DSRM_PASSWORD"),
                 "LAB_TASK_USER" => node.winrm.username, "LAB_TASK_PASSWORD" => node.winrm.password }
        node.vm.provision "dc-post", type: "shell", run: "never", path: "scripts/dc/02-post-promote.ps1",
          env: { "LAB_IP" => ip, "LAB_FORWARDER" => NET.fetch("pfsense_dns"),
                 "LAB_PREFIX" => NET.fetch("prefix").to_s,
                 # Sursa NTP a PDC-ului = pfSense (necesita regula LAN dc01 -> LAN address UDP 123, vezi README)
                 "LAB_NTP" => NET.fetch("gateway") }
        node.vm.provision "badblood", type: "shell", run: "never", path: "scripts/dc/03-badblood.ps1",
          env: { "BB_COMMIT" => LAB.dig("badblood", "commit"),
                 "BB_SHA256" => LAB.dig("badblood", "zip_sha256"),
                 "BB_USERS" => LAB.dig("badblood", "users").to_s,
                 "BB_GROUPS" => LAB.dig("badblood", "groups").to_s,
                 "BB_COMPUTERS" => LAB.dig("badblood", "computers").to_s,
                 "BB_SKIP_LAPS" => LAB.dig("badblood", "skip_laps").to_s }
        node.vm.provision "sysmon", type: "shell", run: "never", path: "scripts/win/sysmon.ps1", env: sysmon_env
        node.vm.provision "wazuh-agent", type: "shell", run: "never", path: "scripts/win/wazuh-agent.ps1", env: wazuh_win_env

      when "ws"
        node.vm.provision "defender-uac", type: "shell", path: "scripts/win/defender-uac.ps1"
        node.vm.provision "join", type: "shell", path: "scripts/win/join-domain.ps1",
          sensitive: true,
          env: { "LAB_DOMAIN" => DOMAIN.fetch("fqdn"), "LAB_NETBIOS" => DOMAIN.fetch("netbios"),
                 "LAB_JOIN_USER" => "vagrant", "LAB_JOIN_PASSWORD" => "vagrant" }
        node.vm.provision "join-reboot", type: "shell", reboot: true
        node.vm.provision "sysmon", type: "shell", path: "scripts/win/sysmon.ps1", env: sysmon_env
        node.vm.provision "wazuh-agent", type: "shell", path: "scripts/win/wazuh-agent.ps1", env: wazuh_win_env

      when "linux"
        node.vm.provision "auditd", type: "shell", path: "scripts/linux/auditd.sh",
          env: { "AUDIT_RULES_URL" => LAB.dig("auditd", "rules_url"),
                 "AUDIT_RULES_SHA256" => LAB.dig("auditd", "rules_sha256") }
        node.vm.provision "wazuh-agent", type: "shell", path: "scripts/linux/wazuh-agent.sh",
          env: { "WAZUH_VERSION" => LAB.dig("wazuh", "agent_version"),
                 "WAZUH_MANAGER" => LAB.dig("wazuh", "manager_ip"),
                 "WAZUH_GROUP" => "linux" }

      when "admin"
        # admin01 (Kali): fus orar, sshd doar cu cheie, ~/.ssh/config pentru pfSense.
        # Pasi manuali (cheia SSH pentru pfSense, parola userului vagrant): README, sectiunea admin01.
        node.vm.provision "admin-base", type: "shell", run: "always",
          path: "scripts/admin/kali-base.sh",
          env: { "LAB_TZ" => LAB.fetch("timezone"),
                 "LAB_PFSENSE_IP" => NET.fetch("gateway"),
                 "LAB_ADMIN_USER" => "vagrant" }

      when "elastic"
        # faza 2
      end
    end
  end
end

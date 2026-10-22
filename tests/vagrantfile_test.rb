# Test offline: evalueaza Vagrantfile cu un stub minimal al DSL-ului Vagrant si verifica
# configuratia rezultata (MAC-uri, rezervari NAT, vmx, ordinea si tipul provisionerilor).
# Ruby >= 2.7. Ruleaza pe Linux/CI: vmnetdhcp.conf (subnet VMnet8) e simulat intr-un dir temporar.
# Actualizat 2026-10-21 (admin01, tz, dc run: never, Kali pcislotnumber).
require "set"
require "tmpdir"
require "fileutils"

NAT_PREFIX_TEST = "192.168.207"

# --- vmnetdhcp.conf simulat (Vagrantfile il citeste din %ProgramData%\VMware)
pd = Dir.mktmpdir("lab-pd")
FileUtils.mkdir_p(File.join(pd, "VMware"))
File.write(File.join(pd, "VMware", "vmnetdhcp.conf"),
           "# Virtual ethernet segment 8\nsubnet #{NAT_PREFIX_TEST}.0 netmask 255.255.255.0 {\n}\n# End\n")
ENV["ProgramData"] = pd

class Rec
  attr_reader :calls, :children
  def initialize; @calls = Hash.new { |h, k| h[k] = [] }; @children = {}; end
  def method_missing(name, *args, **kw, &blk)
    n = name.to_s
    if n.end_with?("=") then @calls[n.chomp("=")] << args.first; return args.first end
    if blk
      child = Rec.new; @calls[n] << [args, kw, child]; blk.call(child); return child
    end
    @calls[n] << [args, kw]
    @children[n] ||= (n == "vmx" ? {} : Rec.new)
  end
  def respond_to_missing?(*) = true
end

module Vagrant
  def self.has_plugin?(_) = true
  def self.configure(_v, &blk) ; $root = Rec.new; blk.call($root) ; end
  # LabSkipNetCfg::Plugin < Vagrant.plugin("2"): clasa-baza cu `name` si `guest_capability`
  def self.plugin(_v)
    Class.new do
      def self.name(*a) = (a.empty? ? "stub" : nil)
      def self.guest_capability(*a, &_b) = ((@caps ||= []) << a)
    end
  end
end

def check(cond, msg) = (cond or abort("FAIL: #{msg}"))

load File.expand_path("../Vagrantfile", __dir__)

defs = $root.children["vm"].calls["define"]
check !defs.empty?, "nu s-au definit VM-uri"
names = defs.map { |a, _kw, _c| a.first }
expected = %w[wazuh01 dc01 ws01 ws02 lin01 admin01 elastic01]
check names == expected, "ordine/nume VM gresite: #{names}"

WIN_ALWAYS = %w[lab-dir lab-lib net audit tz]
PROV = {
  "wazuh01"   => %w[lab-lib net wazuh-aio wazuh-hardening],
  "dc01"      => WIN_ALWAYS + %w[dc-promote dc-post badblood sysmon wazuh-agent],
  "ws01"      => WIN_ALWAYS + %w[defender-uac join join-reboot sysmon wazuh-agent],
  "ws02"      => WIN_ALWAYS + %w[defender-uac join join-reboot sysmon wazuh-agent],
  "lin01"     => %w[lab-lib net auditd wazuh-agent],
  "admin01"   => %w[lab-lib net admin-base],
  "elastic01" => %w[lab-lib net]
}
WINDOWS = %w[dc01 ws01 ws02]

macs = Set.new
nat_ips = Set.new
defs.each do |args, kw, node|
  name = args.first
  vm = node.children["vm"]
  v = vm.calls["provider"].first[2]
  vmx = v.children["vmx"]
  mac0 = v.calls["base_mac"].first
  mac1 = vmx["ethernet1.address"]
  [mac0, mac1].each do |m|
    check m =~ /\A00:50:56:[0-3][0-9A-F]:[0-9A-F]{2}:[0-9A-F]{2}\z/, "#{name}: MAC in afara intervalului static VMware: #{m}"
    check macs.add?(m), "#{name}: MAC duplicat #{m}"
  end
  nat = v.calls["base_address"].first
  check nat == "#{NAT_PREFIX_TEST}.#{mac0.split(':').last.to_i(16)}", "#{name}: base_address #{nat} nu corespunde MAC-ului #{mac0}"
  check nat_ips.add?(nat), "#{name}: rezervare NAT duplicata #{nat}"

  check vmx["ethernet1.vnet"] == "VMnet3", "#{name}: vnet gresit"
  check vmx["ethernet1.connectiontype"] == "custom", "#{name}: connectiontype"
  check v.calls["clone_directory"].first == File.expand_path("VMs", File.expand_path("..", __dir__)), "#{name}: clone_directory"
  check v.calls["enable_vmrun_ip_lookup"].first == false, "#{name}: vmrun ip lookup trebuie dezactivat"

  provs = vm.calls["provision"].map { |a, _k| a.first }
  check provs == PROV.fetch(name), "#{name} ordine provisioneri: #{provs} (astept #{PROV[name]})"
  pk = vm.calls["provision"].to_h { |a, k| [a.first, k] }
  %w[lab-lib net].each { |p| check pk[p][:run] == "always", "#{name}: #{p} trebuie run: always" }

  if WINDOWS.include?(name)
    check vm.calls["communicator"].first == "winrm", "#{name}: communicator"
    check pk["tz"][:run] == "always", "#{name}: tz trebuie run: always"
    check pk["tz"][:env]["LAB_WIN_TZ"] == "UTC", "#{name}: LAB_WIN_TZ=#{pk['tz'][:env]['LAB_WIN_TZ']}"
    check pk["net"][:env]["LAB_DNS"] == (name == "dc01" ? "192.168.0.254" : "192.168.0.10,192.168.0.254"), "#{name}: LAB_DNS"
    check vmx["rtc.diffFromUTC"].nil?, "#{name}: rtc.diffFromUTC nu se seteaza pe Windows"
  else
    check vmx["rtc.diffFromUTC"] == "0", "#{name}: rtc.diffFromUTC"
  end
  if %w[dc01 ws01 ws02 lin01 admin01].include?(name)
    %w[copy paste dnd hgfs].each { |k| check vmx["isolation.tools.#{k}.disable"] == "TRUE", "#{name}: isolation.tools.#{k}" }
  end

  case name
  when "dc01"
    %w[dc-post badblood sysmon wazuh-agent].each { |p| check pk[p][:run] == "never", "dc01: #{p} trebuie run: never" }
    check pk["dc-promote"][:sensitive] == true, "dc-promote trebuie sensitive"
    check pk["dc-promote"][:env]["LAB_DSRM_PASSWORD"].start_with?("__MISSING_") || ENV["LAB_DSRM_PASSWORD"], "dsrm placeholder"
    check vmx["tools.synctime"] == "FALSE", "dc01: tools.synctime"
    check pk["dc-post"][:env]["LAB_NTP"] == "192.168.0.254", "dc01: dc-post LAB_NTP=#{pk['dc-post'][:env]['LAB_NTP']}"
  when "ws01", "ws02"
    check pk["join"][:sensitive] == true, "#{name}: join trebuie sensitive"
    check pk["join-reboot"][:reboot] == true, "#{name}: join-reboot reboot: true"
  when "admin01"
    check vmx["ethernet0.pcislotnumber"] == "33" && vmx["ethernet1.pcislotnumber"] == "192", "admin01: pcislotnumber fixat"
  when "elastic01"
    check kw[:autostart] == false, "elastic01 trebuie autostart: false"
  end
  check kw[:autostart] != false, "#{name}: autostart" unless name == "elastic01"
  puts "OK #{name}: mgmt=#{mac0} nat=#{nat} lab=#{mac1} prov=#{provs.join(',')}"
end

FileUtils.rm_rf(pd)
puts "TOATE TESTELE VAGRANTFILE AU TRECUT"

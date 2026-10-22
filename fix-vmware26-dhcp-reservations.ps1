#Requires -RunAsAdministrator
<#
  Workaround 2 pentru VMware Workstation 26H1 + vagrant-vmware-utility (vezi si fix-vmware26-registry.ps1).

  Problema: Vagrantfile face rezervari DHCP pe VMnet8 (v.base_address) pentru NIC0 al fiecarui VM.
  vnetlib (26H1) scrie rezervarea doar in view-ul 64-bit:
      HKLM\SOFTWARE\VMware, Inc.\VMnetLib\VMnetConfig\vmnet8\DHCP\FixedIPtoMac
  iar utility-ul o cauta in view-ul 32-bit (WOW6432Node) -> "Waiting for the VM to receive an address".
  Sursa: vagrant-vmware-desktop go_src/vagrant-vmware-utility/service/vnetlib_windows.go
         (lookupReservedAddress, registryAccess -> WOW64_32KEY).

  Scriptul scrie in WOW6432Node:
    1. rezervarile existente din view-ul 64-bit (oglindire);
    2. rezervarile pentru TOATE masinile din config\lab.yml, calculate ca in Vagrantfile
       (MAC 00:50:56:3a:00:<ultimul octet hex>, IP <subnet VMnet8>.<ultimul octet>),
       ca sa functioneze si la primul `vagrant up` al unui VM nou.
  Idempotent. Backup in E:\CyberSec-Lab\reg-backup inainte de scriere.
  Tinta: Windows PowerShell 5.1, rulat ca Administrator. NETESTAT pe Windows.
  De scos impreuna cu fix-vmware26-registry.ps1 cand utility-ul suporta 26H1 (hashicorp/vagrant#13828).
#>
$ErrorActionPreference = 'Stop'

$labDir  = 'E:\CyberSec-Lab'
$labYml  = Join-Path $labDir 'config\lab.yml'
$dhcpCnf = Join-Path $env:ProgramData 'VMware\vmnetdhcp.conf'
$bkDir   = Join-Path $labDir 'reg-backup'
$rel     = 'VMware, Inc.\VMnetLib\VMnetConfig\vmnet8\DHCP\FixedIPtoMac'
$src     = "HKLM:\SOFTWARE\$rel"
$dst     = "HKLM:\SOFTWARE\WOW6432Node\$rel"

# --- subnet VMnet8 (aceeasi logica ca vmnet8_prefix din Vagrantfile)
$conf = Get-Content -Raw -Path $dhcpCnf
$seg  = [regex]::Match($conf, '(?ms)^# Virtual ethernet segment 8\b.*?^# End')
if (-not $seg.Success) { throw "Nu gasesc segmentul VMnet8 in $dhcpCnf" }
$m = [regex]::Match($seg.Value, '(?m)^\s*subnet\s+(\d+\.\d+\.\d+)\.0\s+netmask\s+255\.255\.255\.0\s*\{')
if (-not $m.Success) { throw "Nu gasesc un subnet /24 pentru VMnet8 in $dhcpCnf" }
$natPrefix = $m.Groups[1].Value

# --- rezervari dorite: MAC (lowercase, ca vnetlib) -> IP
$want = [ordered]@{}

if (Test-Path $src) {
    $k = Get-Item $src
    foreach ($n in $k.GetValueNames()) { $want[$n.ToLower()] = [string]$k.GetValue($n) }
}

$ips = Select-String -Path $labYml -Pattern '^\s+ip:\s*"(\d+\.\d+\.\d+\.\d+)"' |
       ForEach-Object { $_.Matches[0].Groups[1].Value }
if (-not $ips) { throw "Nu gasesc IP-uri de masini in $labYml" }
foreach ($ip in $ips) {
    $last = [int]($ip.Split('.')[3])
    if ($last -lt 3 -or $last -gt 127) { throw "Octet $last in afara 3..127 ($ip)" }
    $mac = ('00:50:56:3a:00:{0:x2}' -f $last)
    $want[$mac] = "$natPrefix.$last"
}

# --- backup + scriere in view-ul 32-bit
New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMnetLib') {
    & reg.exe export 'HKLM\SOFTWARE\WOW6432Node\VMware, Inc.\VMnetLib' "$bkDir\vmnetlib-wow64-$stamp.reg" /y | Out-Null
} else {
    Set-Content -Path "$bkDir\vmnetlib-wow64-$stamp.absent.txt" -Value 'WOW6432Node\VMware, Inc.\VMnetLib nu exista inainte'
}

if (-not (Test-Path $dst)) { New-Item -Path $dst -Force | Out-Null }
foreach ($mac in $want.Keys) {
    $cur = (Get-ItemProperty -Path $dst -Name $mac -ErrorAction SilentlyContinue).$mac
    if ($cur -ne $want[$mac]) {
        New-ItemProperty -Path $dst -Name $mac -Value $want[$mac] -PropertyType String -Force | Out-Null
        Write-Host "[SET] $mac -> $($want[$mac])  (era: $cur)"
    } else {
        Write-Host "[OK]  $mac -> $cur"
    }
}

Write-Host "`nWOW6432Node FixedIPtoMac:"
& reg.exe query "HKLM\SOFTWARE\$rel" /reg:32

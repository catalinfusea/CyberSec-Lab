#Requires -RunAsAdministrator
<#
  Workaround: vagrant-vmware-utility nu detecteaza VMware Workstation 26H1 (26.x),
  pentru ca 26H1 scrie cheile doar in view-ul 64-bit al registry-ului, iar utility-ul
  le cauta in WOW6432Node (32-bit).
  Scriptul copiaza valorile necesare in WOW6432Node, cu backup inainte.
  Tinta: Windows PowerShell 5.1, rulat ca Administrator. NETESTAT pe Windows.
#>
$ErrorActionPreference = 'Stop'

$srcRoot = 'HKLM:\SOFTWARE\VMware, Inc.'
$src     = "$srcRoot\VMware Workstation"
$dstRoot = 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.'
$dst     = "$dstRoot\VMware Workstation"
$bkDir   = 'E:\CyberSec-Lab\reg-backup'

if (-not (Test-Path $src)) { throw "Nu exista $src - VMware nu pare instalat." }

# 1. Verificare binare (daca lipseste vmrest/vmnetcli, utility-ul vechi poate pica in continuare)
$p = Get-ItemProperty $src
$installPath = $p.InstallPath
foreach ($exe in 'vmrun.exe','vmware.exe','vmrest.exe','vmnetcli.exe','vmware-vdiskmanager.exe') {
    $f = Join-Path $installPath $exe
    if (Test-Path $f) { Write-Host "[OK]    $exe" } else { Write-Warning "[LIPSA] $f" }
}

# 2. Backup
New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
& reg.exe export "HKLM\SOFTWARE\VMware, Inc." "$bkDir\vmware-64.reg" /y | Out-Null
$rootExisted = Test-Path $dstRoot
if ($rootExisted) {
    & reg.exe export "HKLM\SOFTWARE\WOW6432Node\VMware, Inc." "$bkDir\vmware-wow64-before.reg" /y | Out-Null
}
Set-Content -Path "$bkDir\wow64-root-existed.txt" -Value $rootExisted
Write-Host "Backup in $bkDir (WOW6432Node\VMware, Inc. exista inainte: $rootExisted)"

# 3. Creare chei in WOW6432Node
$core = (Get-ItemProperty $srcRoot -ErrorAction SilentlyContinue).Core
if (-not $core) { $core = 'VMware Workstation' }

if (-not (Test-Path $dstRoot)) { New-Item -Path $dstRoot | Out-Null }
if (-not (Test-Path $dst))     { New-Item -Path $dst     | Out-Null }

New-ItemProperty -Path $dstRoot -Name 'Core' -Value $core -PropertyType String -Force | Out-Null
foreach ($n in 'InstallPath','InstallPath64','ProductCode','ProductVersion','Version') {
    $v = $p.$n
    if ($null -ne $v) {
        New-ItemProperty -Path $dst -Name $n -Value $v -PropertyType String -Force | Out-Null
    }
}

Write-Host "`nValori scrise in WOW6432Node:"
Get-ItemProperty $dst | Select-Object InstallPath, InstallPath64, ProductVersion | Format-List

# 4. Pornire serviciu
Start-Service VagrantVMware
Get-Service VagrantVMware

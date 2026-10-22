#Requires -Version 5.1
<#
.SYNOPSIS
  Wrapper vagrant pentru CyberSec-Lab: seteaza variabilele de mediu, cere parola DSRM ascuns,
  verifica lease-urile DHCP pe VMnet8, logheaza in .\logs\ si afiseaza un sumar. Curata env la final.

.EXAMPLE
  .\lab-up.ps1 -Machine dc01 -Provision -NatMac 00:50:56:3a:00:0a
  .\lab-up.ps1 -Machine dc01 -Action provision -ProvisionWith dc-post,badblood,sysmon,wazuh-agent
  .\lab-up.ps1 -Machine wazuh01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Machine,
    [ValidateSet('up', 'provision', 'reload')][string]$Action = 'up',
    [switch]$Provision,
    [ValidatePattern('^[a-z0-9-]+(,[a-z0-9-]+)*$')][string]$ProvisionWith,
    [ValidatePattern('^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')][string]$NatMac,
    [string]$LeasesFile = 'C:\ProgramData\VMware\vmnetdhcp.leases',
    [int]$RebootRetrySeconds = 900,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ActiveLease {
    # Lease-urile active (ends > acum, UTC) pentru un MAC, din fisierul ISC-style al VMware.
    param([string]$Path, [string]$Mac)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Warning "Nu gasesc $Path; sar verificarea lease-urilor."; return @() }
    $text = Get-Content -LiteralPath $Path -Raw
    $now  = (Get-Date).ToUniversalTime()
    $macRx = 'hardware ethernet\s+' + [regex]::Escape($Mac) + '\s*;'
    foreach ($m in [regex]::Matches($text, '(?s)lease\s+(\S+)\s*\{(.*?)\}')) {
        $body = $m.Groups[2].Value
        if ($body -notmatch $macRx) { continue }      # -notmatch e case-insensitive
        $ends = $null
        if ($body -match 'ends\s+\d\s+(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})') {
            $ends = [datetime]::ParseExact($Matches[1], 'yyyy/MM/dd HH:mm:ss',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
            if ($ends -le $now) { continue }
        }
        $hostName = if ($body -match 'client-hostname\s+"([^"]*)"') { $Matches[1] } else { '<fara hostname>' }
        [pscustomobject]@{ IP = $m.Groups[1].Value; Hostname = $hostName; EndsUtc = $ends }
    }
}

function Read-DsrmPassword {
    $a = Read-Host 'Parola DSRM' -AsSecureString
    $b = Read-Host 'Confirmare parola DSRM' -AsSecureString
    $pa = [Net.NetworkCredential]::new('', $a).Password
    $pb = [Net.NetworkCredential]::new('', $b).Password
    if ([string]::IsNullOrEmpty($pa) -or $pa -cne $pb) { throw 'Parola goala sau confirmarea nu coincide.' }
    return $pa
}

if ($Provision -and $Action -eq 'provision') { throw '-Provision nu are sens cu -Action provision.' }

Set-Location -LiteralPath $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Vagrantfile'))) { throw "Nu exista Vagrantfile in $PSScriptRoot." }

# --- Verificare lease-uri (vezi vagrant-vmware-utility, dhcp_lease_file.go) ---
if ($NatMac) {
    $leases = @(Get-ActiveLease -Path $LeasesFile -Mac $NatMac)
    $fresh  = -not (Test-Path -LiteralPath ".vagrant\machines\$Machine\vmware_desktop\id")
    $names  = @($leases | Select-Object -ExpandProperty Hostname -Unique)
    $leases | Format-Table -AutoSize | Out-Host
    $problem = if ($fresh -and $leases.Count -gt 0) { 'masina e noua (fara id), dar exista lease-uri active pe MAC' }
               elseif ($names.Count -gt 1)           { 'lease-uri active cu hostname-uri diferite' }
    if ($problem) {
        $until = ($leases | Where-Object EndsUtc | Measure-Object EndsUtc -Maximum).Maximum
        $msg = "Risc 'Waiting for the VM to receive an address': $problem."
        if ($until) { $msg += " Ultimul expira la $($until.ToLocalTime()) (ora locala)." }
        if (-not $Force) { throw "$msg Asteapta expirarea sau ruleaza cu -Force." }
        Write-Warning $msg
    }
}

# DSRM doar daca ruleaza dc-promote (fix 2026-10-21, pentru lab-build.ps1 nesupravegheat):
#  --provision-with -> doar daca lista contine dc-promote; provision / --provision -> da;
#  up pe masina necreata -> da (primul up provizioneaza); altfel (up/reload simplu) -> nu.
$created = Test-Path -LiteralPath (Join-Path $PSScriptRoot ".vagrant\machines\$Machine\vmware_desktop\id")
$promoteRuns = if ($ProvisionWith)                        { ($ProvisionWith -split ',') -contains 'dc-promote' }
               elseif ($Action -eq 'provision' -or $Provision) { $true }
               elseif ($Action -eq 'up')                  { -not $created }
               else                                       { $false }
$needDsrm = ($Machine -like 'dc*') -and $promoteRuns
$dsrm = $null
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ('{0}-{1}-{2:yyyyMMdd-HHmmss}.log' -f $Machine, $Action, (Get-Date))

$vArgs = @($Action, $Machine)
if ($Provision)     { $vArgs += '--provision' }
if ($ProvisionWith) { $vArgs += '--provision-with', $ProvisionWith }

$code = 1
try {
    if ($needDsrm) {
        # lab-build.ps1 cere parola o singura data, la inceput, si o paseaza prin env.
        if ($env:LAB_DSRM_PASSWORD) { $dsrm = $env:LAB_DSRM_PASSWORD }
        else { $dsrm = Read-DsrmPassword; $env:LAB_DSRM_PASSWORD = $dsrm }
    }
    $env:VAGRANT_MAX_REBOOT_RETRY_DURATION = "$RebootRetrySeconds"
    $env:VAGRANT_LOG = 'info'
    Write-Host "vagrant $($vArgs -join ' ')  (log: $log)"
    # Argumentele sunt validate prin regex mai sus, deci nu exista injectie in linia cmd.
    & cmd.exe /c "vagrant $($vArgs -join ' ') 2>`"$log`""
    $code = $LASTEXITCODE
}
finally {
    if ($dsrm -and (Test-Path -LiteralPath $log)) {
        if (Select-String -LiteralPath $log -SimpleMatch -Pattern $dsrm -Quiet) {
            Write-Warning "Parola DSRM apare in clar in $log. Sterge sau curata logul."
        }
    }
    Remove-Item Env:LAB_DSRM_PASSWORD, Env:VAGRANT_LOG, Env:VAGRANT_MAX_REBOOT_RETRY_DURATION -ErrorAction SilentlyContinue
    $dsrm = $null
}

# --- Sumar ---
Write-Host "`n=== Sumar (exit code vagrant: $code) ==="
if (Test-Path -LiteralPath $log) {
    $prov = Select-String -LiteralPath $log -Pattern 'Running provisioner: (\S+)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique
    Write-Host ('Provisioners pornite: ' + ($(if ($prov) { $prov -join ', ' } else { '-' })))
    $err = Select-String -LiteralPath $log -Pattern 'error-exit' | Select-Object -Last 1
    if ($err) { Write-Host "error-exit: $($err.Line.Trim())" -ForegroundColor Red }
    $pci = @(Select-String -LiteralPath $log -Pattern 'pcislotnumber').Count
    if ($pci) { Write-Host "Linii pcislotnumber in log: $pci" -ForegroundColor Yellow }
}
exit $code

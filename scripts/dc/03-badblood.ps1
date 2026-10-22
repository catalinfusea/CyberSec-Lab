# Populeaza AD cu BadBlood la un commit fixat (zip verificat SHA256). Ruleaza o singura data.
. C:\lab\lib.ps1
Import-Module ActiveDirectory

if (Test-LabMarker 'badblood') { Write-Lab "BadBlood deja rulat; skip."; exit 0 }

$commit    = Get-RequiredEnv 'BB_COMMIT'
$sha256    = Get-RequiredEnv 'BB_SHA256'
$users     = [int](Get-RequiredEnv 'BB_USERS')
$groups    = [int](Get-RequiredEnv 'BB_GROUPS')
$computers = [int](Get-RequiredEnv 'BB_COMPUTERS')
$skipLaps  = (Get-RequiredEnv 'BB_SKIP_LAPS') -eq 'true'

Wait-Until -What 'Get-ADDomain' -TimeoutSec 900 { $null -ne (Get-ADDomain) }

# Drepturile de grup (Schema Admins) se aplica doar la un logon nou; procesul curent e nou.
$me = (whoami /groups) -join "`n"
if (-not $skipLaps -and $me -notmatch 'Schema Admins') {
    throw "Contul curent nu are Schema Admins in token. Ruleaza din nou: vagrant provision dc01 --provision-with badblood"
}

$zip  = 'C:\lab\BadBlood.zip'
$root = 'C:\lab\BadBlood'
Get-VerifiedFile -Uri "https://codeload.github.com/davidprowe/BadBlood/zip/$commit" -OutFile $zip -Sha256 $sha256
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $root -Force
$dir = Join-Path $root "BadBlood-$commit"
Get-ChildItem -Path $dir -Recurse -File | Unblock-File

# BadBlood face dot-source pe subfoldere relativ la $PSCommandPath, deci il apelam ca script.
# Clear-Host poate esua intr-o sesiune fara consola (task elevat WinRM): il neutralizam.
function global:Clear-Host { }

$params = @{ UserCount = $users; GroupCount = $groups; ComputerCount = $computers; NonInteractive = $true }
if ($skipLaps) { $params['SkipLapsInstall'] = $true }

Write-Lab "BadBlood: users=$users groups=$groups computers=$computers skipLaps=$skipLaps (dureaza)"
$ErrorActionPreference = 'Continue'   # BadBlood genereaza erori ne-terminale (nume duplicate etc.)
# lib.ps1 activeaza Set-StrictMode 2.0, mostenit de scope-urile copil; BadBlood e scris pentru
# modul normal (variabile nesetate, .count pe $null) -> VariableIsUndefined / PropertyNotFoundStrict
# la fiecare obiect (2026-10-21). StrictMode oprit doar pe durata BadBlood.
Set-StrictMode -Off
try {
    & (Join-Path $dir 'Invoke-BadBlood.ps1') @params
} finally {
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
}

$count = @(Get-ADUser -Filter *).Count
Write-Lab "Useri in AD dupa BadBlood: $count"
if ($count -lt [Math]::Floor($users * 0.9)) { throw "Prea putini useri creati ($count); verifica output-ul." }

# Scoate drepturile temporare; vagrant ramane Domain Admin (necesar pentru join-ul clientilor).
foreach ($g in 'Schema Admins', 'Enterprise Admins') {
    Remove-ADGroupMember -Identity $g -Members 'vagrant' -Confirm:$false -ErrorAction SilentlyContinue
}
Set-LabMarker 'badblood'
Write-Lab "BadBlood terminat."

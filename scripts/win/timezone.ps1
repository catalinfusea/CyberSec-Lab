# Fus orar Windows din config\lab.yml (windows_timezone; implicit "UTC"). Idempotent, run: always.
# Box-urile gusztavvargadr vin pe "Pacific Standard Time" (constatat 2026-10-21 pe ws01).
# Schimba doar afisarea/ora locala; ceasul UTC (Kerberos, Wazuh) nu e afectat.
# Windows PowerShell 5.1 (Set-TimeZone exista din 5.1). NETESTAT pe Windows.
. C:\lab\lib.ps1

$tz = Get-RequiredEnv 'LAB_WIN_TZ'
if (-not (Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $tz })) {
    throw "Fus orar Windows necunoscut: '$tz' (vezi Get-TimeZone -ListAvailable)."
}

$cur = (Get-TimeZone).Id
if ($cur -eq $tz) {
    Write-Lab "Fus orar deja $tz; skip."
} else {
    Set-TimeZone -Id $tz
    Write-Lab "Fus orar schimbat: $cur -> $((Get-TimeZone).Id)"
}

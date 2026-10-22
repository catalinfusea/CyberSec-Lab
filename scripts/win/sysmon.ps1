# Instaleaza Sysmon standalone (Sysinternals) cu config sysmon-modular fixat prin SHA256.
# Binarul Sysmon nu se poate fixa pe versiune (URL-ul e mereu "latest"): se verifica semnatura Microsoft.
# Nu se combina cu Sysmon built-in din Windows 11 (nesuportat side-by-side).
. C:\lab\lib.ps1

$cfgUrl = Get-RequiredEnv 'SYSMON_CONFIG_URL'
$cfgSha = Get-RequiredEnv 'SYSMON_CONFIG_SHA256'
$work = 'C:\lab\sysmon'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$cfg = Join-Path $work 'sysmonconfig.xml'
Get-VerifiedFile -Uri $cfgUrl -OutFile $cfg -Sha256 $cfgSha

$installed = Get-Service -Name 'Sysmon64' -ErrorAction SilentlyContinue
$other = @(Get-Service -Name '*sysmon*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'Sysmon64', 'SysmonDrv' })

if ($installed) {
    Write-Lab "Sysmon64 deja instalat; reaplic configuratia."
    $exe = 'C:\Windows\Sysmon64.exe'
    Assert-Authenticode -Path $exe -SignerLike '*O=Microsoft Corporation*'
    & $exe -c $cfg
    if ($LASTEXITCODE -ne 0) { throw "Sysmon64 -c a esuat ($LASTEXITCODE)" }
    exit 0
}
if ($other.Count -gt 0) {
    Write-Warning "Exista alt serviciu Sysmon ($($other.Name -join ', ')), posibil built-in. Nu instalez standalone."
    exit 0
}

$zip = Join-Path $work 'Sysmon.zip'
Get-VerifiedFile -Uri 'https://download.sysinternals.com/files/Sysmon.zip' -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $work -Force
$exe = Join-Path $work 'Sysmon64.exe'
Assert-Authenticode -Path $exe -SignerLike '*O=Microsoft Corporation*'
Write-Lab ("Sysmon versiune: {0}" -f (Get-Item $exe).VersionInfo.FileVersion)

& $exe -accepteula -i $cfg
if ($LASTEXITCODE -ne 0) { throw "Instalarea Sysmon a esuat ($LASTEXITCODE)" }
Get-Service Sysmon64 | Format-Table -AutoSize Name, Status | Out-String | Write-Output

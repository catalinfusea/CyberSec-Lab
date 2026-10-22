# Helperi comuni pentru provisioning Windows. Compatibil Windows PowerShell 5.1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest e foarte lent cu progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:LabState = 'C:\lab\state'
New-Item -ItemType Directory -Force -Path $script:LabState | Out-Null

function Write-Lab([string]$Message) {
    Write-Output ("[{0}] [{1}] {2}" -f (Get-Date -Format s), $env:COMPUTERNAME, $Message)
}

function Get-RequiredEnv([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v) -or $v -like '__MISSING_*') {
        throw "Variabila de mediu $Name lipseste (setata pe host?)."
    }
    return $v
}

function Test-LabMarker([string]$Name) { Test-Path (Join-Path $script:LabState "$Name.done") }
function Set-LabMarker([string]$Name)  { Set-Content -Path (Join-Path $script:LabState "$Name.done") -Value (Get-Date -Format s) }

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSec = 900, [int]$IntervalSec = 10, [string]$What = 'conditie') {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return } } catch { }
        Start-Sleep -Seconds $IntervalSec
    }
    throw "Timeout ($TimeoutSec s) asteptand: $What"
}

# Descarca un fisier si il verifica: SHA256 fixat si/sau semnatura Authenticode valida.
function Get-VerifiedFile {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$OutFile,
        [string]$Sha256,
        [switch]$RequireAuthenticode,
        [string]$SignerLike
    )
    if (-not $Uri.StartsWith('https://')) { throw "Refuz URL non-HTTPS: $Uri" }
    Write-Lab "Download: $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    if ($Sha256) {
        $actual = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
        if ($actual -ne $Sha256.ToUpperInvariant()) {
            Remove-Item $OutFile -Force
            throw "SHA256 nepotrivit pentru $Uri. Asteptat $Sha256, primit $actual"
        }
        Write-Lab "SHA256 OK"
    }
    if ($RequireAuthenticode) { Assert-Authenticode -Path $OutFile -SignerLike $SignerLike }
}

function Assert-Authenticode([string]$Path, [string]$SignerLike) {
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') { throw "Semnatura Authenticode invalida ($($sig.Status)) pe $Path" }
    $subject = $sig.SignerCertificate.Subject
    if ($SignerLike -and ($subject -notlike $SignerLike)) { throw "Semnatar neasteptat pe ${Path}: $subject" }
    Write-Lab "Authenticode OK: $subject"
}

# Audit avansat local + command line in 4688 + logging PowerShell. Idempotent.
# Numele subcategoriilor auditpol sunt localizate: scriptul presupune Windows en-US (cum sunt box-urile).
. C:\lab\lib.ps1

$isDC = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4

# Subcategoriile avansate au prioritate fata de politica legacy (inclusiv pe DC).
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'SCENoApplyLegacyAuditPolicy' `
    -PropertyType DWord -Value 1 -Force | Out-Null

$subcats = @(
    'Credential Validation', 'Kerberos Authentication Service', 'Kerberos Service Ticket Operations',
    'Logon', 'Logoff', 'Special Logon', 'Account Lockout', 'Other Logon/Logoff Events',
    'User Account Management', 'Security Group Management', 'Computer Account Management',
    'Process Creation', 'Process Termination',
    'Audit Policy Change', 'Authentication Policy Change',
    'Sensitive Privilege Use', 'Security System Extension',
    'Detailed File Share', 'File Share', 'Other Object Access Events', 'Removable Storage'
)
if ($isDC) { $subcats += @('Directory Service Access', 'Directory Service Changes') }

foreach ($s in $subcats) {
    & auditpol.exe /set /subcategory:"$s" /success:enable /failure:enable | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "auditpol a esuat pentru '$s' (locale non en-US?)" }
}

# Linia de comanda in evenimentul 4688.
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'
New-Item -Path $sys -Force | Out-Null
New-ItemProperty -Path $sys -Name 'ProcessCreationIncludeCmdLine_Enabled' -PropertyType DWord -Value 1 -Force | Out-Null

# PowerShell: Script Block Logging (4104) + Module Logging (4103).
$ps = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'
New-Item -Path "$ps\ScriptBlockLogging" -Force | Out-Null
New-ItemProperty -Path "$ps\ScriptBlockLogging" -Name 'EnableScriptBlockLogging' -PropertyType DWord -Value 1 -Force | Out-Null
New-Item -Path "$ps\ModuleLogging\ModuleNames" -Force | Out-Null
New-ItemProperty -Path "$ps\ModuleLogging" -Name 'EnableModuleLogging' -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path "$ps\ModuleLogging\ModuleNames" -Name '*' -PropertyType String -Value '*' -Force | Out-Null

# Log-uri mai mari (1 GB Security, 256 MB PowerShell).
& wevtutil.exe sl Security /ms:1073741824
& wevtutil.exe sl 'Microsoft-Windows-PowerShell/Operational' /ms:268435456

Write-Lab "Audit policy aplicata ($($subcats.Count) subcategorii, DC=$isDC)"

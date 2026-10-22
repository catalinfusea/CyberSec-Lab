# Promoveaza dc01 ca prim DC intr-o padure noua.
# De ce prin scheduled task: dupa Install-ADDSForest (fara reboot), sesiunea WinRM a Vagrant
# primeste WinRMAuthorizationError la inchiderea shell-ului (vezi logs\dc01-run1-dupa-promote.log,
# 2026-10-04) -> `vagrant up` se opreste chiar daca promovarea a reusit. Aici provisioner-ul doar
# instaleaza rolul, porneste task-ul si iese; task-ul (ca userul vagrant, RunLevel Highest, ca
# winrm-elevated) ruleaza Install-ADDSForest si face singur reboot-ul.
# Pe host, dupa: asteapta DomainRole=5, apoi
#   vagrant provision dc01 --provision-with dc-post,badblood,sysmon,wazuh-agent
# Windows PowerShell 5.1 / Windows Server 2022. NETESTAT end-to-end (2026-10-20).
. C:\lab\lib.ps1

$domain   = Get-RequiredEnv 'LAB_DOMAIN'
$netbios  = Get-RequiredEnv 'LAB_NETBIOS'
$taskUser = Get-RequiredEnv 'LAB_TASK_USER'
$taskName = 'lab-promote'
$secFile  = Join-Path $script:LabState 'dsrm.sec'
$taskPs1  = 'C:\lab\promote-task.ps1'
$taskLog  = Join-Path $script:LabState 'promote-task.log'

function Clear-SecretEnv { Remove-Item Env:\LAB_DSRM_PASSWORD, Env:\LAB_TASK_PASSWORD -ErrorAction SilentlyContinue }

if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
    Write-Lab "Deja controller de domeniu; skip."
    Clear-SecretEnv
    exit 0
}

# Promovare deja pornita (ex. `vagrant provision` repetat in fereastra de promovare).
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') {
    Write-Lab "Task-ul $taskName ruleaza deja; nu repornesc promovarea. Log: $taskLog"
    Clear-SecretEnv
    exit 0
}
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    if (Test-Path $taskLog) {
        Write-Lab "Rulare anterioara a $taskName (masina nu e DC) - ultimele linii din log:"
        Get-Content $taskLog -Tail 20 | ForEach-Object { Write-Output "    $_" }
    }
}

$dsrm = ConvertTo-SecureString (Get-RequiredEnv 'LAB_DSRM_PASSWORD') -AsPlainText -Force
$taskPassword = Get-RequiredEnv 'LAB_TASK_PASSWORD'
Clear-SecretEnv

Write-Lab "Instalez AD-Domain-Services"
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null

# DSRM -> fisier criptat DPAPI (scope: userul curent = $taskUser); task-ul il citeste si il sterge.
# ACL: doar $taskUser si SYSTEM, Full (cu (R,D) Remove-Item -Force dadea Access denied, 2026-10-20).
$acct = "${env:COMPUTERNAME}\${taskUser}"
if (Test-Path $secFile) {
    # rest de la o rulare esuata; ca owner (Administrators, token elevat) putem rescrie ACL-ul
    & icacls.exe $secFile /grant:r "${acct}:(F)" | Out-Null
    Remove-Item -Path $secFile -Force
    Write-Lab "Sters $secFile ramas de la o rulare anterioara"
}
ConvertFrom-SecureString -SecureString $dsrm | Set-Content -Path $secFile -Encoding ASCII
& icacls.exe $secFile /inheritance:r /grant:r "${acct}:(F)" 'SYSTEM:(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls a esuat pe $secFile ($LASTEXITCODE)" }

# Scriptul task-ului: contine doar valori ne-secrete.
$body = @"
`$ErrorActionPreference = 'Stop'
Start-Transcript -Path '$taskLog' -Append | Out-Null
try {
    `$sec = (Get-Content -Path '$secFile' -Raw).Trim() | ConvertTo-SecureString
    Remove-Item -Path '$secFile' -Force
    Import-Module ADDSDeployment
    Write-Output "[`$(Get-Date -Format s)] Install-ADDSForest $domain ($netbios); reboot automat la final"
    Install-ADDSForest -DomainName '$domain' -DomainNetbiosName '$netbios' -SafeModeAdministratorPassword `$sec -InstallDns -Force
} catch {
    Write-Output "[`$(Get-Date -Format s)] EROARE: `$(`$_ | Out-String)"
    Remove-Item -Path '$secFile' -Force -ErrorAction SilentlyContinue
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
"@
Set-Content -Path $taskPs1 -Value $body -Encoding ASCII

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $taskPs1"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings `
    -User "${env:COMPUTERNAME}\${taskUser}" -Password $taskPassword -RunLevel Highest -Force | Out-Null
$taskPassword = $null
Start-ScheduledTask -TaskName $taskName

# Confirma doar pornirea + ca nu a picat imediat (ex. DPAPI, modul lipsa).
# NU astepta promovarea: sesiunea WinRM ar pica la final.
Start-Sleep -Seconds 20
$state = (Get-ScheduledTask -TaskName $taskName).State
$info  = Get-ScheduledTaskInfo -TaskName $taskName
if ($state -ne 'Running') {
    if (Test-Path $taskLog) { Get-Content $taskLog -Tail 30 | ForEach-Object { Write-Output "    $_" } }
    throw "Task-ul $taskName nu ruleaza (state=$state, LastTaskResult=$($info.LastTaskResult)). Vezi $taskLog"
}
Set-LabMarker 'promote-started'
Write-Lab "Promovare pornita in task-ul $taskName (log in guest: $taskLog). VM-ul reporneste singur in cateva minute."

#Requires -Version 5.1
<#
.SYNOPSIS
  Orchestrator CyberSec-Lab: construieste sau reia lab-ul in ordinea din config\lab.yml,
  cu verificari dupa fiecare masina si oprire la prima eroare. Fiecare `vagrant up/provision`
  trece prin lab-up.ps1 (log in logs\, verificare lease-uri, DSRM).

.DESCRIPTION
  Preflight: vagrant + VMware Utility raspund, rezervari DHCP (WOW6432Node), disc, RAM, box-uri,
  backup vmnetnat.conf, parola DSRM (doar daca dc01 trebuie creat; ceruta o singura data).
  Pe fiecare masina selectata:
    - verificarea trece                     -> skip
    - not_created                           -> up (dc01: + asteapta DomainRole=5 + dc-post,badblood,sysmon,wazuh-agent)
    - oprita/suspendata                     -> up (boot + provisioneri run: always), reverifica
    - pornita dar verificarea pica          -> reprovisionare doar pentru ws si dc (provisioneri idempotenti),
                                               altfel stop cu comanda sugerata
    - dupa schimbari: compara vmnetnat.conf; un forward disparut = stop
  -Snapshot: snapshot dupa fiecare masina construita/reparata in rularea curenta.

  Windows PowerShell 5.1 pe host Windows. Validat doar sintactic (2026-10-21), NETESTAT end-to-end.

.EXAMPLE
  .\lab-build.ps1 -CheckOnly
.EXAMPLE
  .\lab-build.ps1                       # toate masinile cu autostart != false
.EXAMPLE
  .\lab-build.ps1 -From ws01 -Snapshot
.EXAMPLE
  .\lab-build.ps1 -Only elastic01        # elastic01 (autostart: false) doar explicit
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9-]+$')][string[]]$Only,
    [ValidatePattern('^[a-z0-9-]+$')][string]$From,
    [switch]$Snapshot,
    [switch]$CheckOnly,
    [ValidateRange(1, 2000)][int]$MinFreeDiskGB = 60,
    [ValidateRange(5, 240)][int]$DcPromoteTimeoutMin = 45,
    [ValidateRange(0, 1800)][int]$AgentWaitSec = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LabDir  = $PSScriptRoot
$LabUp   = Join-Path $LabDir 'lab-up.ps1'
$LabYml  = Join-Path $LabDir 'config\lab.yml'
$NatConf = Join-Path $env:ProgramData 'VMware\vmnetnat.conf'
$RegRes  = 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMnetLib\VMnetConfig\vmnet8\DHCP\FixedIPtoMac'
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$DcProvisionList = 'dc-post,badblood,sysmon,wazuh-agent'

# ---------------------------------------------------------------- utilitare

function Write-Step([string]$Text) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Text) -ForegroundColor Cyan }

function Invoke-Vagrant {
    # Captureaza stdout+stderr. EAP local = Continue: in PS 5.1, 2>&1 pe o comanda nativa cu
    # EAP=Stop transforma orice linie stderr in eroare terminala.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = & vagrant @Arguments 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function ConvertFrom-KLines([string]$Text) {
    # Comenzile din guest scriu linii K_<cheie>=<valoare>; restul output-ului e ignorat.
    $h = @{}
    foreach ($m in [regex]::Matches($Text, '(?m)^K_(\w+)=(.*?)\s*$')) { $h[$m.Groups[1].Value] = $m.Groups[2].Value }
    return $h
}

function Get-LabConfig([string]$Path) {
    # Parser minimal pentru structura cunoscuta a lab.yml (fara modul YAML in PS 5.1).
    $cfg = @{ Machines = New-Object System.Collections.Generic.List[object]; Boxes = @{}
              Fqdn = $null; BbUsers = $null; WinTz = 'UTC' }
    $section = ''; $cur = $null; $box = $null
    foreach ($l in (Get-Content -LiteralPath $Path)) {
        $l = ($l -replace '\s+#.*$', '')
        if ($l -match '^([A-Za-z_]\w*):\s*(.*)$') {
            $section = $Matches[1]
            if ($section -eq 'windows_timezone' -and $Matches[2] -match '"([^"]+)"') { $cfg.WinTz = $Matches[1] }
            continue
        }
        switch ($section) {
            'machines' {
                if ($l -match '^\s*-\s*name:\s*(\S+)') {
                    $cur = [pscustomobject]@{ Name = $Matches[1]; Role = $null; Box = $null; Ip = $null; Memory = 0; Autostart = $true }
                    $cfg.Machines.Add($cur)
                } elseif ($null -ne $cur) {
                    if     ($l -match '^\s+role:\s*(\S+)')                    { $cur.Role = $Matches[1] }
                    elseif ($l -match '^\s+box:\s*(\S+)')                     { $cur.Box = $Matches[1] }
                    elseif ($l -match '^\s+ip:\s*"(\d+\.\d+\.\d+\.\d+)"')     { $cur.Ip = $Matches[1] }
                    elseif ($l -match '^\s+memory:\s*(\d+)')                  { $cur.Memory = [int]$Matches[1] }
                    elseif ($l -match '^\s+autostart:\s*false')               { $cur.Autostart = $false }
                }
            }
            'boxes' {
                if ($l -match '^\s{2}(\w+):\s*$') { $box = $Matches[1]; $cfg.Boxes[$box] = @{ Name = $null; Version = $null } }
                elseif ($box -and $l -match '^\s+name:\s*"([^"]+)"')    { $cfg.Boxes[$box].Name = $Matches[1] }
                elseif ($box -and $l -match '^\s+version:\s*"([^"]+)"') { $cfg.Boxes[$box].Version = $Matches[1] }
            }
            'domain'   { if ($l -match '^\s+fqdn:\s*"([^"]+)"')  { $cfg.Fqdn = $Matches[1] } }
            'badblood' { if ($l -match '^\s+users:\s*(\d+)')     { $cfg.BbUsers = [int]$Matches[1] } }
        }
    }
    if ($cfg.Machines.Count -eq 0) { throw "Nu gasesc masini in $Path" }
    if (-not $cfg.Fqdn)            { throw "Nu gasesc domain.fqdn in $Path" }
    if (-not $cfg.BbUsers)         { throw "Nu gasesc badblood.users in $Path" }
    $seen = @{}
    foreach ($m in $cfg.Machines) {
        if ($m.Name -notmatch '^[a-z0-9-]+$') { throw "Nume de masina invalid in lab.yml: $($m.Name)" }
        if (-not $m.Role -or -not $m.Ip -or -not $m.Box) { throw "Masina $($m.Name): lipseste role/ip/box in lab.yml" }
        if ($seen.ContainsKey($m.Name)) { throw "Masina duplicata in lab.yml: $($m.Name)" }
        $seen[$m.Name] = $true
    }
    $cfg.Machines = [object[]]$cfg.Machines.ToArray()   # @(List[object]) arunca "Argument types do not match"
    return $cfg
}

function Get-MgmtMac([string]$Ip) { '00:50:56:3a:00:{0:x2}' -f [int]($Ip.Split('.')[3]) }  # ca mgmt_mac din Vagrantfile

function Get-MachineStates {
    $r = Invoke-Vagrant @('status', '--machine-readable')
    if ($r.Code -ne 0) {
        if ($r.Out -match 'api/vmnet') {
            throw "Vagrant VMware Utility nu poate contacta vmrest (api/vmnet). Ca Administrator: Restart-Service VagrantVMware, apoi reia."
        }
        throw "vagrant status a esuat:`n$($r.Out)"
    }
    $h = @{}
    foreach ($line in ($r.Out -split "`r?`n")) {
        $p = $line.Split(',')
        if ($p.Count -ge 4 -and $p[2] -eq 'state') { $h[$p[1]] = $p[3] }
    }
    return $h
}

function Get-NatForwards {
    if (-not (Test-Path -LiteralPath $NatConf)) { return @() }
    @(Select-String -LiteralPath $NatConf -Pattern '^\s*\d+\s*=\s*\d' | ForEach-Object { ($_.Line.Trim() -replace '\s+', ' ') })
}

function Invoke-LabUp([string]$Name, [string[]]$Extra = @()) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LabUp, '-Machine', $Name) + $Extra
    Write-Step "lab-up.ps1 -Machine $Name $($Extra -join ' ')"
    & powershell.exe @a | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "lab-up.ps1 -Machine $Name $($Extra -join ' ') a iesit cu $LASTEXITCODE (vezi logs\)." }
}

# ---------------------------------------------------------------- verificari

function Get-AgentsText {
    $r = Invoke-Vagrant @('ssh', 'wazuh01', '-c', 'sudo /var/ossec/bin/agent_control -l')
    if ($r.Code -ne 0) { return '' }
    return $r.Out
}

function Test-AgentActive([string]$AgentName, [int]$WaitSec) {
    $rx = '(?im)Name:\s*' + [regex]::Escape($AgentName) + ',[^\r\n]*\bActive\b'
    $deadline = (Get-Date).AddSeconds($WaitSec)
    do {
        if ((Get-AgentsText) -match $rx) { return $true }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 15
    } while ($true)
    return $false
}

function New-Result([bool]$Ok, [string[]]$Problems, [string[]]$Warnings) {
    [pscustomobject]@{ Ok = $Ok; Problems = ($Problems -join '; '); Warnings = ($Warnings -join '; ') }
}

function Test-Machine($M, [int]$WaitAgentSec = 0) {
    $prob = New-Object System.Collections.Generic.List[string]
    $warn = New-Object System.Collections.Generic.List[string]
    switch ($M.Role) {
        'wazuh' {
            if ((Get-AgentsText) -notmatch 'Active/Local') { $prob.Add('agent_control -l nu raspunde / manager inactiv') }
        }
        'dc' {
            $c = ('$r=(Get-CimInstance Win32_ComputerSystem).DomainRole; ''K_role='' + $r; ' +
                  'if ($r -ge 4) { ''K_users='' + @(Get-ADUser -Filter *).Count; ' +
                  '''K_srv='' + @(Resolve-DnsName _ldap._tcp.dc._msdcs.__FQDN__ -Type SRV -DnsOnly -ErrorAction SilentlyContinue).Count; ' +
                  '''K_bb='' + (Test-Path C:\lab\state\badblood.done) }; ' +
                  '''K_svc='' + @(Get-Service Sysmon64,WazuhSvc -ErrorAction SilentlyContinue | Where-Object Status -eq Running).Count; ' +
                  '''K_tz='' + (Get-TimeZone).Id').Replace('__FQDN__', $Cfg.Fqdn)
            $k = ConvertFrom-KLines (Invoke-Vagrant @('winrm', $M.Name, '-c', $c)).Out
            $minUsers = [Math]::Floor($Cfg.BbUsers * 0.9)
            if ($k['role'] -ne '5')                           { $prob.Add("DomainRole=$($k['role']) (astept 5)") }
            else {
                if ([int]("0" + $k['users']) -lt $minUsers)  { $prob.Add("useri AD=$($k['users']) (< $minUsers)") }
                if ($k['srv'] -in $null, '', '0')            { $prob.Add('SRV _ldap lipsa') }
                if ($k['bb'] -ne 'True')                     { $prob.Add('marker BadBlood lipsa') }
            }
            if ($k['svc'] -ne '2')                            { $prob.Add("Sysmon64/WazuhSvc Running=$($k['svc']) (astept 2)") }
            if ($k['tz'] -and $k['tz'] -ne $Cfg.WinTz)        { $warn.Add("tz=$($k['tz'])") }
            if ($prob.Count -eq 0 -and -not (Test-AgentActive $M.Name $WaitAgentSec)) { $prob.Add('agent Wazuh nu e Active') }
        }
        'ws' {
            $c = ('$cs=Get-CimInstance Win32_ComputerSystem; ''K_part='' + $cs.PartOfDomain + ''|'' + $cs.Domain; ' +
                  '''K_egress='' + (Find-NetRoute -RemoteIPAddress 1.1.1.1 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty InterfaceAlias); ' +
                  '''K_svc='' + @(Get-Service Sysmon64,WazuhSvc -ErrorAction SilentlyContinue | Where-Object Status -eq Running).Count; ' +
                  '''K_sc='' + [bool](nltest /sc_verify:__FQDN__ | Select-String -SimpleMatch NERR_Success); ' +
                  '''K_tz='' + (Get-TimeZone).Id').Replace('__FQDN__', $Cfg.Fqdn)
            $k = ConvertFrom-KLines (Invoke-Vagrant @('winrm', $M.Name, '-c', $c)).Out
            if ($k['part'] -ne "True|$($Cfg.Fqdn)") { $prob.Add("domeniu='$($k['part'])'") }
            if ($k['egress'] -ne 'LAB')             { $prob.Add("egress='$($k['egress'])' (astept LAB)") }
            if ($k['svc'] -ne '2')                  { $prob.Add("Sysmon64/WazuhSvc Running=$($k['svc']) (astept 2)") }
            if ($k['sc'] -ne 'True')                { $prob.Add('nltest /sc_verify esuat') }
            if ($k['tz'] -and $k['tz'] -ne $Cfg.WinTz) { $warn.Add("tz=$($k['tz'])") }
            if ($prob.Count -eq 0 -and -not (Test-AgentActive $M.Name $WaitAgentSec)) { $prob.Add('agent Wazuh nu e Active') }
        }
        'linux' {
            $r = Invoke-Vagrant @('ssh', $M.Name, '-c', 'systemctl is-active auditd wazuh-agent')
            if (@([regex]::Matches($r.Out, '(?m)^active\s*$')).Count -ne 2) { $prob.Add('auditd/wazuh-agent nu sunt ambele active') }
            if ($prob.Count -eq 0 -and -not (Test-AgentActive $M.Name $WaitAgentSec)) { $prob.Add('agent Wazuh nu e Active') }
        }
        'admin' {
            $k = ConvertFrom-KLines (Invoke-Vagrant @('ssh', $M.Name, '-c', 'echo K_ok=1')).Out
            if ($k['ok'] -ne '1') { $prob.Add('vagrant ssh nu raspunde') }
        }
        default { }   # elastic (faza 2): doar starea running, verificata de apelant
    }
    return New-Result ($prob.Count -eq 0) $prob.ToArray() $warn.ToArray()
}

function Wait-DcPromoted([string]$Name) {
    Write-Step "Astept DomainRole=5 pe $Name (max $DcPromoteTimeoutMin min; promovarea + reboot ruleaza in task-ul lab-promote)"
    $deadline = (Get-Date).AddMinutes($DcPromoteTimeoutMin)
    $c = '''K_role='' + (Get-CimInstance Win32_ComputerSystem).DomainRole'
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $k = ConvertFrom-KLines (Invoke-Vagrant @('winrm', $Name, '-c', $c)).Out
        Write-Host ("  DomainRole={0}" -f $(if ($k['role']) { $k['role'] } else { '?' }))
        if ($k['role'] -eq '5') { Start-Sleep -Seconds 60; return }   # lasa serviciile AD sa porneasca
    }
    throw "Timeout: $Name nu a ajuns DomainRole=5 in $DcPromoteTimeoutMin min. In guest: C:\lab\state\promote-task.log"
}

# ---------------------------------------------------------------- main

if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) { throw 'vagrant nu e in PATH.' }
foreach ($f in $LabUp, $LabYml, (Join-Path $LabDir 'Vagrantfile')) { if (-not (Test-Path -LiteralPath $f)) { throw "Lipseste $f" } }
Set-Location -LiteralPath $LabDir

$logDir = Join-Path $LabDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$transcript = Join-Path $logDir "lab-build-$Stamp.log"
Start-Transcript -LiteralPath $transcript | Out-Null

$summary = New-Object System.Collections.Generic.List[object]
$dsrmSec = $null
$exitCode = 1
$curName = $null; $action = '-'; $t0 = Get-Date   # masina in lucru (pentru randul FAIL din sumar la exceptie)
try {
    $Cfg = Get-LabConfig $LabYml
    $all = @($Cfg.Machines)

    # --- selectie
    $sel = if ($Only) {
        foreach ($n in $Only) { if (-not ($all | Where-Object Name -eq $n)) { throw "-Only: masina necunoscuta $n" } }
        @($all | Where-Object { $Only -contains $_.Name })
    } else { @($all | Where-Object Autostart) }
    if ($From) {
        $idx = [array]::IndexOf(@($sel | ForEach-Object Name), $From)
        if ($idx -lt 0) { throw "-From: $From nu e in selectie ($(@($sel | ForEach-Object Name) -join ','))" }
        $sel = @($sel[$idx..($sel.Count - 1)])
    }
    Write-Step ("Selectie: {0}{1}" -f (@($sel | ForEach-Object Name) -join ', '), $(if ($CheckOnly) { '  (CheckOnly)' } else { '' }))

    # --- preflight
    Write-Step 'Preflight: vagrant status'
    $states = Get-MachineStates
    foreach ($m in $sel) { if (-not $states.ContainsKey($m.Name)) { throw "Masina $($m.Name) din lab.yml nu apare in vagrant status (Vagrantfile?)." } }
    $toCreate = @($sel | Where-Object { $states[$_.Name] -eq 'not_created' })
    $toStart  = @($sel | Where-Object { $states[$_.Name] -ne 'running' })

    if (-not $CheckOnly -and $toCreate.Count -gt 0) {
        Write-Step "Preflight: rezervari DHCP VMnet8 (WOW6432Node) pentru $(@($toCreate | ForEach-Object Name) -join ',')"
        $res = Get-ItemProperty -LiteralPath $RegRes -ErrorAction SilentlyContinue
        foreach ($m in $toCreate) {
            $mac = Get-MgmtMac $m.Ip; $last = $m.Ip.Split('.')[3]
            $v = if ($res -and ($res.PSObject.Properties.Name -contains $mac)) { [string]$res.$mac } else { $null }
            if (-not $v -or -not $v.EndsWith(".$last")) {
                throw "Rezervare DHCP lipsa/gresita pentru $($m.Name) ($mac -> '$v'). Ruleaza ca Administrator: .\fix-vmware26-dhcp-reservations.ps1"
            }
        }

        $freeGB = (Get-PSDrive -Name ($LabDir.Substring(0, 1))).Free / 1GB
        Write-Step ('Preflight: disc liber {0:N1} GB (minim {1})' -f $freeGB, $MinFreeDiskGB)
        if ($freeGB -lt $MinFreeDiskGB) { throw "Spatiu insuficient pe disc ($('{0:N1}' -f $freeGB) GB < $MinFreeDiskGB GB)." }

        $boxList = (Invoke-Vagrant @('box', 'list')).Out
        foreach ($b in @($toCreate | ForEach-Object Box | Select-Object -Unique)) {
            $bx = $Cfg.Boxes[$b]
            if (-not $bx) { throw "Box '$b' nedefinit in lab.yml" }
            $rx = '(?m)^' + [regex]::Escape($bx.Name) + '\s+\(vmware_desktop,\s*' + [regex]::Escape($bx.Version) + '\b'
            if ($boxList -notmatch $rx) { Write-Warning "Box $($bx.Name) $($bx.Version) nu e descarcat: va fi descarcat la up (win11 a durat ~2 h, 2026-10-21)." }
        }
    }
    if (-not $CheckOnly -and $toStart.Count -gt 0) {
        $needMB = ($toStart | Measure-Object Memory -Sum).Sum
        $freeMB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB
        Write-Step ('Preflight: RAM liber {0:N0} MB, necesar ~{1:N0} MB pentru {2}' -f $freeMB, $needMB, (@($toStart | ForEach-Object Name) -join ','))
        if ($freeMB -lt $needMB * 1.1) { throw 'RAM liber insuficient pentru masinile de pornit.' }
    }
    if (-not $CheckOnly -and ($toCreate | Where-Object Role -eq 'dc')) {
        $a = Read-Host 'dc01 va fi creat: parola DSRM' -AsSecureString
        $b = Read-Host 'Confirmare parola DSRM' -AsSecureString
        $pa = [Net.NetworkCredential]::new('', $a).Password; $pb = [Net.NetworkCredential]::new('', $b).Password
        if ([string]::IsNullOrEmpty($pa) -or $pa -cne $pb) { throw 'Parola DSRM goala sau confirmarea nu coincide.' }
        $dsrmSec = $a; $pa = $null; $pb = $null
    }
    if (-not $CheckOnly) {
        $bk = Join-Path $LabDir "reg-backup\vmnetnat.conf.bak-$Stamp-lab-build"
        New-Item -ItemType Directory -Force -Path (Split-Path $bk) | Out-Null
        Copy-Item -LiteralPath $NatConf -Destination $bk
        Write-Step "Backup vmnetnat.conf -> $bk"
    }

    # --- masini
    $failed = $false
    foreach ($m in $sel) {
        $t0 = Get-Date
        $curName = $m.Name
        $state = $states[$m.Name]
        $action = '-'
        Write-Step "=== $($m.Name) ($($m.Role), $state)"

        # dependinte (nu in CheckOnly): agentii au nevoie de wazuh01, ws de dc01 valid
        if (-not $CheckOnly) {
            if ($m.Role -in 'dc', 'ws', 'linux') {
                $w = $all | Where-Object Role -eq 'wazuh' | Select-Object -First 1
                if ($w -and $states[$w.Name] -ne 'running') { throw "$($m.Name) are nevoie de $($w.Name) pornit." }
            }
            if ($m.Role -eq 'ws') {
                $d = $all | Where-Object Role -eq 'dc' | Select-Object -First 1
                if (-not (Test-Machine $d).Ok) { throw "$($m.Name) are nevoie de $($d.Name) valid (ruleaza -Only $($d.Name))." }
            }
        }

        $r = if ($state -eq 'running') { Test-Machine $m } else { New-Result $false @("stare $state") @() }
        if ($m.Role -eq 'elastic' -and $state -eq 'running') { $r = New-Result $true @() @() }

        if (-not $r.Ok -and -not $CheckOnly) {
            $natBefore = Get-NatForwards
            if ($state -eq 'not_created') {
                $action = 'creat'
                $extra = @('-NatMac', (Get-MgmtMac $m.Ip))
                if ($m.Role -eq 'dc') {
                    $env:LAB_DSRM_PASSWORD = [Net.NetworkCredential]::new('', $dsrmSec).Password
                    try { Invoke-LabUp $m.Name $extra } finally { Remove-Item Env:LAB_DSRM_PASSWORD -ErrorAction SilentlyContinue }
                    Wait-DcPromoted $m.Name
                    Invoke-LabUp $m.Name @('-Action', 'provision', '-ProvisionWith', $DcProvisionList)
                } else {
                    Invoke-LabUp $m.Name $extra
                }
            } else {
                if ($state -ne 'running') {
                    $action = 'pornit'
                    Invoke-LabUp $m.Name
                    $r = Test-Machine $m $AgentWaitSec
                }
                if (-not $r.Ok) {
                    Write-Warning "$($m.Name): $($r.Problems)"
                    switch ($m.Role) {
                        'ws' { $action = 'reprovizionat'; Invoke-LabUp $m.Name @('-Action', 'provision') }
                        'dc' {
                            $k = ConvertFrom-KLines (Invoke-Vagrant @('winrm', $m.Name, '-c', '''K_role='' + (Get-CimInstance Win32_ComputerSystem).DomainRole')).Out
                            if ($k['role'] -ne '5') { throw "$($m.Name) exista dar nu e DC (DomainRole=$($k['role'])). Verifica manual (promote-task.log); nu repornesc promovarea automat." }
                            $action = 'reprovizionat'
                            Invoke-LabUp $m.Name @('-Action', 'provision', '-ProvisionWith', $DcProvisionList)
                        }
                        default { throw "$($m.Name) pornit dar verificarea pica: $($r.Problems). Reprovizionare manuala: .\lab-up.ps1 -Machine $($m.Name) -Action provision" }
                    }
                }
            }
            $states[$m.Name] = 'running'
            $r = if ($m.Role -eq 'elastic') { New-Result $true @() @() } else { Test-Machine $m $AgentWaitSec }

            $natAfter = Get-NatForwards
            $lost = @($natBefore | Where-Object { $natAfter -notcontains $_ })
            if ($lost.Count -gt 0) {
                throw ("Forward-uri disparute din vmnetnat.conf dupa $($m.Name): $($lost -join ' | '). " +
                       "Remediere: vmrun -T ws stop <vmx-ul masinii afectate> soft, apoi .\lab-up.ps1 -Machine <masina>.")
            }
            if ($r.Ok -and $Snapshot) {
                $sn = "lab-build-$Stamp"
                $s = Invoke-Vagrant @('snapshot', 'save', $m.Name, $sn)
                if ($s.Code -ne 0) { Write-Warning "Snapshot $sn pe $($m.Name) a esuat:`n$($s.Out)" } else { Write-Step "Snapshot $($m.Name): $sn" }
            }
        }

        $summary.Add([pscustomobject]@{
            Masina = $m.Name; Actiune = $action; Rezultat = $(if ($r.Ok) { 'OK' } else { 'FAIL' })
            Detalii = (@($r.Problems, $(if ($r.Warnings) { "warn: $($r.Warnings)" })) | Where-Object { $_ }) -join ' | '
            Min = '{0:N1}' -f ((Get-Date) - $t0).TotalMinutes })
        $curName = $null
        if (-not $r.Ok) {
            $failed = $true
            if (-not $CheckOnly) { throw "$($m.Name): verificarea finala pica: $($r.Problems)" }
        }
    }
    $exitCode = if ($failed) { 1 } else { 0 }
}
catch {
    Write-Host "EROARE: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
    if ($curName) {
        $msg = $_.Exception.Message
        if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 157) + '...' }
        $summary.Add([pscustomobject]@{ Masina = $curName; Actiune = $action; Rezultat = 'FAIL'
            Detalii = $msg; Min = '{0:N1}' -f ((Get-Date) - $t0).TotalMinutes })
    }
}
finally {
    Remove-Item Env:LAB_DSRM_PASSWORD -ErrorAction SilentlyContinue
    $dsrmSec = $null
    Write-Host "`n=== Sumar lab-build (exit $exitCode) ==="
    $summary | Format-Table -AutoSize -Wrap | Out-String | Write-Host
    Stop-Transcript | Out-Null
    Write-Host "Transcript: $transcript (output-ul vagrant complet e in logs\<masina>-*.log)"
}
exit $exitCode

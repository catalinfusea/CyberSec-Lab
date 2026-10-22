# Post-promovare: asteapta AD, DNS doar pe IP-ul LAB, forwarder pfSense, zona reverse,
# drepturi pentru contul vagrant (necesare BadBlood), sursa NTP pfSense (2026-10-21). Idempotent.
. C:\lab\lib.ps1
Import-Module ActiveDirectory, DnsServer

$labIp     = Get-RequiredEnv 'LAB_IP'
$forwarder = Get-RequiredEnv 'LAB_FORWARDER'
$prefix    = Get-RequiredEnv 'LAB_PREFIX'
$ntp       = Get-RequiredEnv 'LAB_NTP'

Wait-Until -What 'ADWS / Get-ADDomain' -TimeoutSec 1200 { $null -ne (Get-ADDomain) }
$dom = Get-ADDomain
$fqdn = $dom.DNSRoot
Write-Lab "AD disponibil: $fqdn"

# 0) Curatenie dupa 01-promote.ps1 (task-ul de promovare si scriptul lui; DSRM e sters de task).
if (Get-ScheduledTask -TaskName 'lab-promote' -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName 'lab-promote' -Confirm:$false
    Write-Lab "Task lab-promote sters"
}
Remove-Item -Path 'C:\lab\promote-task.ps1', (Join-Path $script:LabState 'dsrm.sec') -Force -ErrorAction SilentlyContinue

# 1) DNS server: asculta doar pe IP-ul LAB; forwarder catre pfSense (Unbound).
& dnscmd.exe /ResetListenAddresses $labIp | Out-Null
# (fix 2026-10-20: `-not` se evalua inaintea lui `-contains` -> conditia nu verifica forwarder-ul)
$fw = @(Get-DnsServerForwarder | ForEach-Object { $_.IPAddress } | Where-Object { $_ } |
    ForEach-Object { $_.IPAddressToString })
if ($fw -notcontains $forwarder) {
    Set-DnsServerForwarder -IPAddress $forwarder
    Write-Lab "Forwarder DNS setat: $forwarder (era: $($fw -join ','))"
}

# DNS client pe DC = IP-ul LAB (serverul nu asculta pe 127.0.0.1 dupa ResetListenAddresses).
# Acelasi set pe LAB si MGMT, ca in net-win.ps1.
foreach ($alias in 'LAB', 'MGMT') {
    $ad = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    if ($ad) { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $labIp }
}

# 2) Zona reverse pentru subnetul LAB (doar /24 suportat de acest calcul simplu).
if ($prefix -eq '24') {
    $o = $labIp.Split('.')
    $rev = "{0}.{1}.{2}.in-addr.arpa" -f $o[2], $o[1], $o[0]
    if (-not (Get-DnsServerZone -Name $rev -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -NetworkId ("{0}.{1}.{2}.0/24" -f $o[0], $o[1], $o[2]) -ReplicationScope Forest
        Write-Lab "Zona reverse creata: $rev"
    }
}

# 3) Curata eventualele inregistrari A cu IP-ul de management (NIC0) din zonele domeniului.
$mgmtIps = @(Get-NetIPAddress -InterfaceAlias 'MGMT' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    ForEach-Object { $_.IPAddress })
foreach ($zone in @($fqdn, "_msdcs.$fqdn")) {
    Get-DnsServerResourceRecord -ZoneName $zone -RRType A -ErrorAction SilentlyContinue |
        Where-Object { $mgmtIps -contains $_.RecordData.IPv4Address.IPAddressToString } |
        ForEach-Object {
            Write-Lab "Sterg A record $($_.HostName) -> $($_.RecordData.IPv4Address) din $zone"
            $_ | Remove-DnsServerResourceRecord -ZoneName $zone -Force
        }
}
Restart-Service DNS

# 4) Cont vagrant: parola sa nu expire (altfel WinRM-ul Vagrant cade dupa 42 de zile)
#    si drepturi temporare pentru BadBlood (schema LAPS + ACL-uri). Schema/Enterprise
#    Admins se scot la finalul 03-badblood.ps1.
#    Fix 2026-10-21: daca BadBlood a rulat deja (marker), 03-badblood.ps1 face skip si NU mai scoate
#    drepturile -> la o rerulare dc-post le-ar fi lasat permanent. Le adaugam doar inainte de BadBlood.
Set-ADUser -Identity 'vagrant' -PasswordNeverExpires $true
$vagrantGroups = @('Domain Admins')
if (Test-LabMarker 'badblood') { Write-Lab "BadBlood deja rulat: nu adaug vagrant in Schema/Enterprise Admins" }
else { $vagrantGroups += 'Schema Admins', 'Enterprise Admins' }
foreach ($g in $vagrantGroups) {
    if (-not (Get-ADGroupMember -Identity $g | Where-Object { $_.SamAccountName -eq 'vagrant' })) {
        Add-ADGroupMember -Identity $g -Members 'vagrant'
        Write-Lab "vagrant adaugat in $g"
    }
}

# 5) Timp: dc01 e PDC-ul padurii (sursa de timp a domeniului) -> NTP de la pfSense, nu ceasul local.
#    0x8 = mod client; /reliable:yes -> AnnounceFlags 5. Clientii raman pe NT5DS (ierarhia domeniului).
#    Necesita regula pfSense LAN: dc01 -> LAN address UDP 123, deasupra "Block lab to RFC1918".
$peer = "$ntp,0x8"
$w32cfg = (& w32tm.exe /query /configuration) -join "`n"
if ($w32cfg -notmatch ('(?m)^\s*NtpServer:\s*' + [regex]::Escape($peer) + '\b') -or $w32cfg -notmatch '(?m)^\s*Type:\s*NTP\b') {
    & w32tm.exe /config "/manualpeerlist:$peer" /syncfromflags:manual /reliable:yes /update | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "w32tm /config a esuat ($LASTEXITCODE)" }
    Restart-Service w32time
    Write-Lab "w32time: sursa NTP setata la $peer (reliable)"
}
& w32tm.exe /resync /rediscover | Out-Null   # poate esua la primul apel (inca fara esantioane); nu e fatal
Start-Sleep -Seconds 5
Write-Lab ("w32time sursa: {0}" -f ((& w32tm.exe /query /source) -join ' ').Trim())

# Verificare: numele domeniului trebuie sa rezolve DOAR la IP-ul LAB.
Start-Sleep -Seconds 5
$answers = @(Resolve-DnsName -Name $fqdn -Type A -Server $labIp -DnsOnly | ForEach-Object { $_.IPAddress })
Write-Lab "$fqdn -> $($answers -join ', ')"
if (@($answers | Where-Object { $_ -ne $labIp }).Count -gt 0) {
    Write-Warning "Exista inregistrari A in afara de $labIp. Netlogon le poate re-inregistra; ruleaza din nou: vagrant provision dc01 --provision-with dc-post"
}

# Configureaza NIC1 (VMnet3) static, default route prin pfSense, NIC0 doar management.
# Idempotent; ruleaza la fiecare `vagrant up` (run: always). Adaptoarele se identifica dupa MAC.
. C:\lab\lib.ps1

$labMac  = (Get-RequiredEnv 'LAB_MAC').Replace(':', '-').ToUpperInvariant()
$mgmtMac = (Get-RequiredEnv 'LAB_MGMT_MAC').Replace(':', '-').ToUpperInvariant()
$ip      = Get-RequiredEnv 'LAB_IP'
$prefix  = [int](Get-RequiredEnv 'LAB_PREFIX')
$gw      = Get-RequiredEnv 'LAB_GW'
$dns     = @((Get-RequiredEnv 'LAB_DNS').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Dupa promovare, DC-ul isi foloseste propriul DNS, pe IP-ul LAB: 02-post-promote.ps1 face
# dnscmd /ResetListenAddresses <IP LAB>, deci serverul NU asculta pe 127.0.0.1 (fix 2026-10-20).
$isDC = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4
if ($isDC) { $dns = @($ip) }

function Get-AdapterByMac([string]$Mac) {
    $a = @(Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $Mac })
    if ($a.Count -ne 1) { throw "Nu gasesc exact un adaptor cu MAC $Mac (gasite: $($a.Count))" }
    return $a[0]
}

$lab  = Get-AdapterByMac $labMac
$mgmt = Get-AdapterByMac $mgmtMac
if ($lab.Name -ne 'LAB')   { Rename-NetAdapter -Name $lab.Name -NewName 'LAB';  $lab  = Get-NetAdapter -Name 'LAB' }
if ($mgmt.Name -ne 'MGMT') { Rename-NetAdapter -Name $mgmt.Name -NewName 'MGMT'; $mgmt = Get-NetAdapter -Name 'MGMT' }

# LAB: static. Scoate adresele IPv4 care nu sunt cea dorita (ex. lease de la DHCP-ul pfSense).
Set-NetIPInterface -InterfaceIndex $lab.ifIndex -AddressFamily IPv4 -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $lab.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne $ip } | Remove-NetIPAddress -Confirm:$false
if (-not (Get-NetIPAddress -InterfaceIndex $lab.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceIndex $lab.ifIndex -IPAddress $ip -PrefixLength $prefix | Out-Null
}
$routes = @(Get-NetRoute -InterfaceIndex $lab.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
$routes | Where-Object { $_.NextHop -ne $gw } | Remove-NetRoute -Confirm:$false
if (-not ($routes | Where-Object { $_.NextHop -eq $gw })) {
    New-NetRoute -InterfaceIndex $lab.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $gw -RouteMetric 0 | Out-Null
}

# Metrici: LAB preferat; ruta default din DHCP pe MGMT ramane, dar cu metrica mare
# (DHCP o readauga la renew, deci nu o sterg).
Set-NetIPInterface -InterfaceIndex $lab.ifIndex  -AddressFamily IPv4 -InterfaceMetric 10
Set-NetIPInterface -InterfaceIndex $mgmt.ifIndex -AddressFamily IPv4 -InterfaceMetric 5000
Start-Sleep -Seconds 2

# DNS: acelasi set pe ambele interfete (altfel DNS-ul NAT VMware poate raspunde NXDOMAIN pt domeniu);
# MGMT nu se inregistreaza in DNS (critic pe DC-ul multi-homed).
Set-DnsClientServerAddress -InterfaceIndex $lab.ifIndex  -ServerAddresses $dns
Set-DnsClientServerAddress -InterfaceIndex $mgmt.ifIndex -ServerAddresses $dns
Set-DnsClient -InterfaceIndex $lab.ifIndex  -RegisterThisConnectionsAddress $true
Set-DnsClient -InterfaceIndex $mgmt.ifIndex -RegisterThisConnectionsAddress $false

# Inainte de join, retelele necunoscute sunt Public. Dupa join, LAB devine DomainAuthenticated.
# Best-effort (fix 2026-10-21): imediat dupa schimbarea IP-ului, NLA marcheaza reteaua 'Identifying...'
# si Set-NetConnectionProfile arunca (MI RESULT 7). Retry 60 s, apoi doar warning: join-ul nu depinde de profil.
$profOk = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $prof = Get-NetConnectionProfile -InterfaceIndex $lab.ifIndex -ErrorAction Stop
        if ($prof.NetworkCategory -eq 'Public') {
            Set-NetConnectionProfile -InterfaceIndex $lab.ifIndex -NetworkCategory Private -ErrorAction Stop
        }
        $profOk = $true
        break
    } catch {
        Start-Sleep -Seconds 5
    }
}
if ($profOk) {
    Write-Lab ("Profil retea LAB: {0}" -f (Get-NetConnectionProfile -InterfaceIndex $lab.ifIndex).NetworkCategory)
} else {
    Write-Warning "Profilul retelei LAB a ramas Public/Identifying dupa 60 s; continui (dupa join devine DomainAuthenticated)."
}

#$egress = (Find-NetRoute -RemoteIPAddress '1.1.1.1' | Select-Object -First 1).InterfaceAlias
#Write-Lab "LAB=$ip/$prefix gw=$gw dns=$($dns -join ',') ; egress catre Internet: $egress"
#if ($egress -ne 'LAB') { throw "Traficul spre Internet nu iese prin LAB/pfSense (iese prin '$egress')" }
# Verificare deterministă: Caută ruta default active pe interfața LAB și verifică gateway-ul
$defaultRouteLab = Get-NetRoute -InterfaceIndex $lab.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $gw }

if (-not $defaultRouteLab) {
    throw "Traficul spre Internet nu este rutat corect prin gateway-ul $gw pe interfata LAB."
}

Write-Lab "LAB=$ip/$prefix gw=$gw dns=$($dns -join ',') ; rutarea spre Internet prin pfSense este configurata cu succes."

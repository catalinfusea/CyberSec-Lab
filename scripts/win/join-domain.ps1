# Join in domeniu. Rebootul il face provisionerul urmator (join-reboot). Idempotent.
. C:\lab\lib.ps1

$domain  = Get-RequiredEnv 'LAB_DOMAIN'
$netbios = Get-RequiredEnv 'LAB_NETBIOS'
$user    = Get-RequiredEnv 'LAB_JOIN_USER'
$pass    = Get-RequiredEnv 'LAB_JOIN_PASSWORD'

$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -eq $domain) { Write-Lab "Deja membru al $domain; skip."; exit 0 }

Wait-Until -What "SRV _ldap._tcp.dc._msdcs.$domain" -TimeoutSec 1800 -IntervalSec 15 {
    @(Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Type SRV -DnsOnly -ErrorAction Stop).Count -gt 0
}

$cred = New-Object System.Management.Automation.PSCredential("$netbios\$user", (ConvertTo-SecureString $pass -AsPlainText -Force))
Add-Computer -DomainName $domain -Credential $cred -Force
Write-Lab "Join in $domain reusit; urmeaza reboot."

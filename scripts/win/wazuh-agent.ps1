# Instaleaza agentul Wazuh (MSI oficial, versiune fixata, semnatura Authenticode verificata).
# Inrolarea se face automat la pornire; daca managerul nu e inca sus, agentul reincearca.
. C:\lab\lib.ps1

$ver     = Get-RequiredEnv 'WAZUH_VERSION'   # ex. 4.14.8-1
$manager = Get-RequiredEnv 'WAZUH_MANAGER'
$group   = Get-RequiredEnv 'WAZUH_GROUP'

if (Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue) { Write-Lab "Agent Wazuh deja instalat; skip."; exit 0 }

$msi = "C:\lab\wazuh-agent-$ver.msi"
Get-VerifiedFile -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-$ver.msi" -OutFile $msi -RequireAuthenticode

$msiArgs = @('/i', "`"$msi`"", '/q', "WAZUH_MANAGER=`"$manager`"", "WAZUH_AGENT_GROUP=`"$group`"",
          "WAZUH_AGENT_NAME=`"$env:COMPUTERNAME`"", '/l*v', '"C:\lab\wazuh-agent-install.log"')
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { throw "msiexec a esuat cu codul $($p.ExitCode); vezi C:\lab\wazuh-agent-install.log" }

Start-Service -Name 'WazuhSvc'
Write-Lab "Agent Wazuh $ver instalat (manager=$manager, grup=$group)."

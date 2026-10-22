# Reactiveaza Defender si UAC pe statiile de lucru (box-ul le are dezactivate).
# Metoda prin care box-ul a dezactivat Defender nu e documentata: best-effort, raporteaza starea reala.
# UAC devine activ dupa reboot (provisionerul join-reboot).
. C:\lab\lib.ps1

# --- Defender: scoate politicile care il dezactiveaza ---
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
foreach ($name in 'DisableAntiSpyware', 'DisableAntiVirus') {
    Remove-ItemProperty -Path $pol -Name $name -ErrorAction SilentlyContinue
}
Remove-Item -Path "$pol\Real-Time Protection" -Recurse -Force -ErrorAction SilentlyContinue

try {
    Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false `
        -DisableIOAVProtection $false -DisableScriptScanning $false
} catch {
    Write-Warning "Set-MpPreference a esuat: $($_.Exception.Message)"
}

# --- UAC ---
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty -Path $sys -Name 'EnableLUA' -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $sys -Name 'ConsentPromptBehaviorAdmin' -PropertyType DWord -Value 5 -Force | Out-Null
New-ItemProperty -Path $sys -Name 'PromptOnSecureDesktop' -PropertyType DWord -Value 1 -Force | Out-Null
# Necesar ca WinRM-ul Vagrant (cont local vagrant) sa ramana admin complet cu UAC activ.
# ATENTIE: setare cunoscuta ca facilitator de lateral movement (pass-the-hash cu conturi locale).
New-ItemProperty -Path $sys -Name 'LocalAccountTokenFilterPolicy' -PropertyType DWord -Value 1 -Force | Out-Null

try {
    $s = Get-MpComputerStatus
    Write-Lab ("Defender: AMServiceEnabled={0} AntivirusEnabled={1} RealTimeProtectionEnabled={2} (unele valori devin True abia dupa reboot)" -f `
        $s.AMServiceEnabled, $s.AntivirusEnabled, $s.RealTimeProtectionEnabled)
} catch {
    Write-Warning "Nu pot citi starea Defender: $($_.Exception.Message)"
}
Write-Lab "UAC configurat (activ dupa reboot)."

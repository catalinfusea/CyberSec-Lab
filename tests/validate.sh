#!/usr/bin/env bash
# Validare statica: sintaxa Ruby/YAML/PowerShell/Bash + test Vagrantfile cu stub.
# Necesita: ruby (>= 2.7), pwsh (PowerShell 7), shellcheck. Ruleaza din radacina repo-ului: tests/validate.sh
# Actualizat 2026-10-21: .ps1 din radacina (lab-up, lab-build, fix-*), scripts/admin, shellcheck -S warning.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== ruby -c Vagrantfile";  ruby -c Vagrantfile
echo "== YAML";                 ruby -ryaml -e 'YAML.safe_load(File.read("config/lab.yml")); puts "lab.yml OK"'
echo "== PowerShell parser"
pwsh -NoProfile -Command '
  $bad = 0
  $files = @(Get-ChildItem -Path . -Filter *.ps1 -File) + @(Get-ChildItem -Recurse -Filter *.ps1 -File scripts)
  foreach ($f in $files) {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e) | Out-Null
    if ($e.Count) { $bad++; $e | ForEach-Object { Write-Host "$($_.Extent.File):$($_.Extent.StartLineNumber) $($_.Message)" } }
    else { Write-Host "OK $($f.Name)" }
  }
  exit $bad'
echo "== shellcheck (severitate warning+)"
shellcheck -S warning -x -P scripts/common scripts/common/*.sh scripts/wazuh/*.sh scripts/linux/*.sh scripts/admin/*.sh
echo "shellcheck OK"
echo "== Vagrantfile (stub)";   ruby tests/vagrantfile_test.rb

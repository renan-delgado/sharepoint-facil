# Canonical local check: lint (PSScriptAnalyzer), unit/UI tests, launcher and
# installer layout. Read-only for the user's data: no mount, no Graph, no install.
# Usage: pwsh -NoProfile -File scripts\check.ps1 [-VerifyUi]
param([switch]$VerifyUi)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = @()
$lintSkipped = $false

# Lint gate: errors fail the check; warnings are reported for burndown
# (baseline in docs/quality.md).
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $scripts = @(Join-Path $root 'RcloneDriveManager.ps1') +
        @(Get-ChildItem (Join-Path $root 'tests'), (Join-Path $root 'installer\scripts'), (Join-Path $root 'scripts') -Filter *.ps1 | ForEach-Object FullName)
    $results = @(foreach ($file in $scripts) { Invoke-ScriptAnalyzer -Path $file })
    $errors = @($results | Where-Object Severity -eq 'Error')
    $warnings = @($results | Where-Object Severity -eq 'Warning')
    Write-Output ('LINT: {0} errors, {1} warnings, {2} information' -f $errors.Count, $warnings.Count, ($results.Count - $errors.Count - $warnings.Count))
    $errors | ForEach-Object { Write-Output ('  {0}:{1} {2} {3}' -f (Split-Path -Leaf $_.ScriptPath), $_.Line, $_.RuleName, $_.Message) }
    if ($errors.Count) { $failures += 'lint' }
} else {
    $lintSkipped = $true
    Write-Output 'LINT: SKIPPED - PSScriptAnalyzer not installed for this PowerShell (see docs/onboarding.md)'
}

# The application targets Windows PowerShell 5.1, so tests run there. A test
# writing to stderr must not abort the loop before its FAIL summary.
$ErrorActionPreference = 'Continue'
# Child powershell.exe writes in the OEM code page; decode it as such.
[Console]::OutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tests = @(
    @{ Name = 'documents'; File = 'tests\Test-DocumentActions.ps1'; Args = $(if ($VerifyUi) { @('-VerifyUi') } else { @() }) },
    @{ Name = 'launcher'; File = 'tests\Test-Launcher.ps1'; Args = @() },
    @{ Name = 'installer layout'; File = 'installer\scripts\Test-InstallerLayout.ps1'; Args = @() }
)
foreach ($test in $tests) {
    $output = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $test.File) @($test.Args) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failures += $test.Name
        Write-Output ('FAIL {0}' -f $test.Name)
        $output | Select-Object -Last 15 | ForEach-Object { Write-Output ('  ' + $_) }
    } else {
        Write-Output ('PASS {0}: {1}' -f $test.Name, ($output | Select-Object -Last 1))
    }
}

if ($failures.Count) {
    Write-Output ('CHECK FAILED: ' + ($failures -join ', '))
    exit 1
}
Write-Output $(if ($lintSkipped) { 'CHECK OK (lint skipped)' } else { 'CHECK OK' })

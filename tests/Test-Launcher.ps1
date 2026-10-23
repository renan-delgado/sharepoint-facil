$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $projectRoot 'installer\scripts\Build-Launcher.ps1')
$launcher = Join-Path $projectRoot 'installer\build\launcher\SharePointFacil.exe'
$bytes = [IO.File]::ReadAllBytes($launcher)
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt16($bytes, $peOffset + 24 + 68) -ne 2) { throw 'Launcher must be Windows GUI subsystem.' }
if ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664) { throw 'Launcher must target x64.' }
$assembly = [Reflection.Assembly]::LoadFile($launcher)
$type = $assembly.GetType('Launcher')
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$create = $type.GetMethod('CreateStartInfo', $flags, $null, [Type[]]@([string], [string[]]), $null)
$createWithSettings = $type.GetMethod('CreateStartInfo', $flags, $null, [Type[]]@([string], [string[]], [string]), $null)
$quote = $type.GetMethod('Quote', $flags)
$testParent = Join-Path $PSScriptRoot 'artifacts'
$testRoot = Join-Path $testParent ('SharePointFacil-LauncherTest-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
try {
    Copy-Item -LiteralPath $launcher -Destination (Join-Path $testRoot 'SharePointFacil.exe')
    $probe = @'
param([switch]$AutoMount, [switch]$ShellWatcher, [string]$DocumentAction, [string]$DocumentPath)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
@{ Console = [ConsoleProbe]::GetConsoleWindow().ToInt64(); AutoMount = [bool]$AutoMount; ShellWatcher = [bool]$ShellWatcher; Action = $DocumentAction; Path = $DocumentPath } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.json') -Encoding UTF8
Write-Output 'Probe output must not create a terminal.'
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'RcloneDriveManager.ps1'), $probe, (New-Object Text.UTF8Encoding($true)))
    $cases = @(
        [pscustomobject]@{ Args = [string[]]@(); Action = ''; Path = ''; AutoMount = $false; ShellWatcher = $false },
        [pscustomobject]@{ Args = [string[]]@('-AutoMount'); Action = ''; Path = ''; AutoMount = $true; ShellWatcher = $false },
        [pscustomobject]@{ Args = [string[]]@('-ShellWatcher'); Action = ''; Path = ''; AutoMount = $false; ShellWatcher = $true }
    )
    foreach ($path in @('Z:\', 'Z:\Ação & teste\100% $x; $(literal).xlsx')) {
        $cases += [pscustomobject]@{ Args = [string[]]@('-DocumentAction', 'SharePoint', '-DocumentPath', $path); Action = 'SharePoint'; Path = $path; AutoMount = $false; ShellWatcher = $false }
    }
    foreach ($case in $cases) {
        $info = $create.Invoke($null, [object[]]@([string]$testRoot, [string[]]$case.Args))
        if ($info.UseShellExecute -or -not $info.CreateNoWindow -or $info.WindowStyle -ne 'Hidden') { throw 'PowerShell child can allocate a console.' }
        if ($info.Arguments -notmatch '-STA' -or $info.Arguments -notmatch '-NoProfile' -or $info.FileName -notmatch '\\WindowsPowerShell\\v1.0\\powershell.exe$') { throw 'Unexpected PowerShell command.' }
        $resultFile = Join-Path $testRoot 'result.json'
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $testRoot 'SharePointFacil.exe'
        $start.Arguments = (@($case.Args | ForEach-Object { $quote.Invoke($null, [object[]]@([string]$_)) }) -join ' ')
        $start.UseShellExecute = $true
        $process = [Diagnostics.Process]::Start($start)
        try {
            if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) { throw 'Launcher did not exit successfully.' }
        } finally { $process.Dispose() }
        $deadline = (Get-Date).AddSeconds(15)
        while (-not (Test-Path -LiteralPath $resultFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Start-Sleep -Milliseconds 150
        if (-not (Test-Path -LiteralPath $resultFile)) {
            $info.RedirectStandardError = $true
            $info.RedirectStandardOutput = $true
            $diagnostic = [Diagnostics.Process]::Start($info)
            try {
                $stderr = $diagnostic.StandardError.ReadToEnd()
                $stdout = $diagnostic.StandardOutput.ReadToEnd()
                [void]$diagnostic.WaitForExit(10000)
                throw ('Probe failed. Arguments: ' + $info.Arguments + '; stderr: ' + $stderr + '; stdout: ' + $stdout)
            } finally { $diagnostic.Dispose() }
        }
        $result = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($result.Console -ne 0) { throw 'PowerShell was attached to a console window.' }
        if ($result.Path -cne $case.Path -or $result.Action -cne $case.Action -or $result.AutoMount -ne $case.AutoMount -or $result.ShellWatcher -ne $case.ShellWatcher) { throw 'Arguments did not survive the launcher/PowerShell round trip.' }
    }
    $rejected = $false
    try { [void]$create.Invoke($null, [object[]]@([string]$testRoot, [string[]]@('-Command', 'anything'))) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Launcher accepted arbitrary commands.' }
    foreach ($removed in @('Exclusive', 'Coauthor', 'Finish', 'Auto')) {
        $rejected = $false
        try { [void]$create.Invoke($null, [object[]]@([string]$testRoot, [string[]]@('-DocumentAction', $removed, '-DocumentPath', 'Z:\a.xlsx'))) } catch { $rejected = $true }
        if (-not $rejected) { throw ('Launcher accepted a removed document action: ' + $removed) }
    }

    # Double-click routing: only files on a mapped drive go to the SharePoint URL.
    [string]$settings = Join-Path $testRoot 'settings.json'
    [IO.File]::WriteAllText($settings, '{ "version": 2, "profiles": [ { "drive": "Z", "remote": "r" } ] }')
    $mapped = 'Z:\Ação & teste\100% $x.xlsx'
    $info = $createWithSettings.Invoke($null, [object[]]@([string]$testRoot, [string[]]@('-OfficeOpen', $mapped), $settings))
    if ($info.UseShellExecute -or $info.Arguments -notlike ('* -DocumentAction Auto -DocumentPath ' + $quote.Invoke($null, [object[]]@($mapped)))) { throw 'Mapped document was not routed to Auto.' }
    foreach ($other in @('C:\Users\x\Planilha.xlsx', 'Y:\Planilha.xlsx', '\\server\share\Planilha.xlsx')) {
        $info = $createWithSettings.Invoke($null, [object[]]@([string]$testRoot, [string[]]@('-OfficeOpen', $other), $settings))
        if (-not $info.UseShellExecute -or $info.Verb -ne 'Open' -or $info.FileName -ne $other) { throw ('Unmapped document was not handed to Office Open: ' + $other) }
    }
    $info = $createWithSettings.Invoke($null, [object[]]@([string]$testRoot, [string[]]@('-OfficeOpen', 'Z:\a.xlsx'), [string](Join-Path $testRoot 'missing.json')))
    if (-not $info.UseShellExecute) { throw 'Missing settings must fall back to Office Open.' }
    $rejected = $false
    try { [void]$createWithSettings.Invoke($null, [object[]]@([string]$testRoot, [string[]]@('-OfficeOpen', 'Z:\a"b.xlsx'), $settings)) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Quoted document path accepted.' }
    Write-Output 'LAUNCHER_TESTS_OK: GUI x64; 5 real launches without a console; arguments preserved; arbitrary and removed commands rejected; Office double-click routing.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath($testParent).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'SharePointFacil-LauncherTest-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

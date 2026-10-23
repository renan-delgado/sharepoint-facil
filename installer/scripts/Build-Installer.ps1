[CmdletBinding()]
param(
    [string]$ProductVersion = '1.1.5',
    [string]$ProductManufacturer = 'UTI DA INFORMATICA LTDA',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$IncludeBundle,
    [string]$WinFspMsiPath,
    [string]$WinFspSha256,
    [switch]$SkipRcloneHashCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-MsiVersion {
    param([string]$Version)

    $parts = $Version -split '\.'
    Assert-Condition ($parts.Count -eq 3) 'ProductVersion deve usar três campos MSI, por exemplo 1.0.0.'
    $limits = @(255, 255, 65535)
    for ($index = 0; $index -lt $parts.Count; $index++) {
        [int]$value = 0
        Assert-Condition ([int]::TryParse($parts[$index], [ref]$value)) "Campo inválido em ProductVersion: $($parts[$index])"
        Assert-Condition ($value -ge 0 -and $value -le $limits[$index]) "Campo ProductVersion fora do limite MSI: $($parts[$index])"
    }
}

function Find-BuildArtifact {
    param(
        [string]$Directory,
        [string]$Filter,
        [string]$Description
    )

    $artifacts = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    Assert-Condition ($artifacts.Count -gt 0) "$Description não foi produzido em $Directory"
    return $artifacts[0].FullName
}

Test-MsiVersion -Version $ProductVersion
Assert-Condition (-not [string]::IsNullOrWhiteSpace($ProductManufacturer)) 'ProductManufacturer não pode ficar vazio.'

$installerRoot = Split-Path -Parent $PSScriptRoot
$payloadDirectory = Join-Path $installerRoot 'build\payload'
$stageScript = Join-Path $PSScriptRoot 'Stage-Payload.ps1'
$testScript = Join-Path $PSScriptRoot 'Test-InstallerLayout.ps1'
$msiProject = Join-Path $installerRoot 'RcloneDriveManager.Installer.wixproj'
$bundleProject = Join-Path $installerRoot 'RcloneDriveManager.Bundle.wixproj'
$winFspManifestPath = Join-Path $installerRoot 'config\winfsp.manifest.json'

$stageArguments = @{ OutputDirectory = $payloadDirectory }
if ($SkipRcloneHashCheck) {
    $stageArguments.SkipRcloneHashCheck = $true
}
& $stageScript @stageArguments

$testArguments = @{ RequireStagedPayload = $true }
if ($SkipRcloneHashCheck) {
    $testArguments.SkipRcloneHashCheck = $true
}

if ($IncludeBundle) {
    $winFspManifest = Get-Content -LiteralPath $winFspManifestPath -Raw | ConvertFrom-Json
    Assert-Condition ([string]$winFspManifest.packageFileName -match '^[^\\/]+\.msi$') 'O nome de arquivo em config\winfsp.manifest.json deve ser um MSI simples.'
    Assert-Condition ([string]$winFspManifest.version -match '^\d+\.\d+\.\d+$') 'A versão fixada do WinFsp em config\winfsp.manifest.json é inválida.'
    Assert-Condition ([string]$winFspManifest.sourceUrl -match '^https://github\.com/winfsp/winfsp/releases/download/') 'A origem fixada do WinFsp deve apontar diretamente para um asset oficial de release.'
    if ([string]::IsNullOrWhiteSpace($WinFspMsiPath)) {
        $WinFspMsiPath = Join-Path (Join-Path $installerRoot 'third-party\winfsp') $winFspManifest.packageFileName
    }
    $resolvedWinFspPath = [System.IO.Path]::GetFullPath($WinFspMsiPath)
    Assert-Condition (Test-Path -LiteralPath $resolvedWinFspPath -PathType Leaf) "MSI do WinFsp não encontrado: $resolvedWinFspPath"
    if ([string]::IsNullOrWhiteSpace($WinFspSha256)) {
        $WinFspSha256 = [string]$winFspManifest.sha256
    }
    Assert-Condition ($WinFspSha256 -match '^[A-Fa-f0-9]{64}$') 'Para gerar Setup.exe, atualize config\winfsp.manifest.json com o checksum oficial ou informe -WinFspSha256.'
    $actualWinFspHash = (Get-FileHash -LiteralPath $resolvedWinFspPath -Algorithm SHA256).Hash.ToUpperInvariant()
    Assert-Condition ($actualWinFspHash -eq $WinFspSha256.ToUpperInvariant()) 'O SHA-256 do MSI do WinFsp não confere.'
    $testArguments.WinFspMsiPath = $resolvedWinFspPath
    $testArguments.WinFspSha256 = $WinFspSha256
}

& $testScript @testArguments

$portableDotnetPath = Join-Path $installerRoot '.tools\dotnet\dotnet.exe'
if (Test-Path -LiteralPath $portableDotnetPath -PathType Leaf) {
    $dotnetExecutable = [System.IO.Path]::GetFullPath($portableDotnetPath)
    $dotnetRoot = Split-Path -Parent $dotnetExecutable
} else {
    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    Assert-Condition ($null -ne $dotnetCommand) 'dotnet não está disponível. Prepare installer\.tools\dotnet ou instale um .NET SDK compatível.'
    $dotnetExecutable = $dotnetCommand.Source
    $dotnetRoot = Split-Path -Parent $dotnetExecutable
}

$buildHome = Join-Path $installerRoot '.tools\build-home'
$buildAppData = Join-Path $buildHome 'AppData\Roaming'
$nugetPackages = Join-Path $installerRoot '.tools\nuget-packages'
New-Item -ItemType Directory -Path $buildAppData, $nugetPackages -Force | Out-Null

$environmentNames = @(
    'APPDATA',
    'DOTNET_ADD_GLOBAL_TOOLS_TO_PATH',
    'DOTNET_CLI_HOME',
    'DOTNET_CLI_TELEMETRY_OPTOUT',
    'DOTNET_NOLOGO',
    'DOTNET_ROOT',
    'DOTNET_SKIP_FIRST_TIME_EXPERIENCE',
    'NUGET_PACKAGES',
    'PATH'
)
$environmentBackup = @{}
foreach ($environmentName in $environmentNames) {
    $environmentBackup[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, [EnvironmentVariableTarget]::Process)
}

try {
    $env:APPDATA = $buildAppData
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
    $env:DOTNET_CLI_HOME = $buildHome
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $env:DOTNET_ROOT = $dotnetRoot
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:NUGET_PACKAGES = $nugetPackages
    $env:PATH = "$dotnetRoot;$env:PATH"

    $installedSdks = @(& $dotnetExecutable --list-sdks 2>$null)
    Assert-Condition ($LASTEXITCODE -eq 0 -and $installedSdks.Count -gt 0) 'Nenhum .NET SDK foi encontrado. O runtime sozinho não gera o MSI.'
    Write-Host "SDK .NET: $dotnetExecutable"

    $msiBuildArguments = @(
        'build',
        $msiProject,
        '--configuration', $Configuration,
        "--property:ProductVersion=$ProductVersion",
        "--property:ProductManufacturer=$ProductManufacturer",
        "--property:PayloadDir=$payloadDirectory"
    )
    & $dotnetExecutable @msiBuildArguments
    Assert-Condition ($LASTEXITCODE -eq 0) 'A compilação do MSI falhou.'

    $msiOutputDirectory = Join-Path $installerRoot 'bin\msi'
    $msiArtifact = Find-BuildArtifact -Directory $msiOutputDirectory -Filter "SharePointFacil-$ProductVersion-x64.msi" -Description 'MSI'
    Write-Host "MSI criado: $msiArtifact"

    if ($IncludeBundle) {
        $bundleBuildArguments = @(
            'build',
            $bundleProject,
            '--configuration', $Configuration,
            "--property:ProductVersion=$ProductVersion",
            "--property:ProductManufacturer=$ProductManufacturer",
            "--property:ApplicationMsiPath=$msiArtifact",
            "--property:WinFspMsiPath=$resolvedWinFspPath",
            "--property:PayloadDir=$payloadDirectory"
        )
        & $dotnetExecutable @bundleBuildArguments
        Assert-Condition ($LASTEXITCODE -eq 0) 'A compilação do Setup.exe falhou.'

        $bundleOutputDirectory = Join-Path $installerRoot 'bin\bundle'
        $bundleArtifact = Find-BuildArtifact -Directory $bundleOutputDirectory -Filter "SharePointFacilSetup-$ProductVersion-x64.exe" -Description 'Setup.exe'
        Write-Host "Setup.exe criado: $bundleArtifact"
    }
} finally {
    foreach ($environmentName in $environmentNames) {
        [Environment]::SetEnvironmentVariable($environmentName, $environmentBackup[$environmentName], [EnvironmentVariableTarget]::Process)
    }
}

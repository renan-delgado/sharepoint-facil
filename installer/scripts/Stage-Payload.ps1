[CmdletBinding()]
param(
    [string]$ApplicationScriptPath,
    [string]$RclonePath,
    [string]$OutputDirectory,
    [switch]$SkipRcloneHashCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installerRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $installerRoot 'config\payload.manifest.json'
$manifestDirectory = Split-Path -Parent $manifestPath

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Resolve-RequiredFile {
    param(
        [string]$Path,
        [string]$Description
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    Assert-Condition (Test-Path -LiteralPath $fullPath -PathType Leaf) "$Description não encontrado: $fullPath"
    return $fullPath
}

Assert-Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) "Manifesto de payload não encontrado: $manifestPath"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Assert-Condition ($manifest.schemaVersion -eq 1) 'Versão de manifesto de payload não suportada.'

if ([string]::IsNullOrWhiteSpace($ApplicationScriptPath)) {
    $ApplicationScriptPath = Join-Path $manifestDirectory $manifest.application.source
}
if ([string]::IsNullOrWhiteSpace($RclonePath)) {
    $RclonePath = Join-Path $manifestDirectory $manifest.rclone.source
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $installerRoot 'build\payload'
}

$applicationSource = Resolve-RequiredFile -Path $ApplicationScriptPath -Description 'Script do aplicativo'
& (Join-Path $PSScriptRoot 'Build-Launcher.ps1')
$launcherSource = Resolve-RequiredFile -Path (Join-Path $manifestDirectory $manifest.launcher.source) -Description 'Inicializador grafico'
$rcloneSource = Resolve-RequiredFile -Path $RclonePath -Description 'rclone.exe'
$iconSource = Resolve-RequiredFile -Path (Join-Path $manifestDirectory $manifest.icon.source) -Description 'Ícone do aplicativo'
$noticesSource = Resolve-RequiredFile -Path (Join-Path $manifestDirectory $manifest.notices.source) -Description 'Aviso de terceiros'

$expectedHash = ([string]$manifest.rclone.sha256).ToUpperInvariant()
Assert-Condition ($expectedHash -match '^[A-F0-9]{64}$') 'O SHA-256 do rclone no manifesto é inválido.'
$actualHash = (Get-FileHash -LiteralPath $rcloneSource -Algorithm SHA256).Hash.ToUpperInvariant()
if (-not $SkipRcloneHashCheck) {
    Assert-Condition ($actualHash -eq $expectedHash) "O SHA-256 do rclone não confere. Esperado: $expectedHash. Obtido: $actualHash"
}

$expectedVersion = [string]$manifest.rclone.version
$actualVersion = [string](Get-Item -LiteralPath $rcloneSource).VersionInfo.ProductVersion
Assert-Condition ($actualVersion -eq $expectedVersion) "A versão do rclone não confere. Esperada: $expectedVersion. Obtida: $actualVersion"

$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
$installerRootPath = [System.IO.Path]::GetFullPath($installerRoot)
$installerRootPrefix = $installerRootPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
Assert-Condition ($outputPath.StartsWith($installerRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) 'O diretório de staging deve ficar dentro de installer.'

$payload = @(
    [pscustomobject]@{ Source = $launcherSource; Destination = [string]$manifest.launcher.destination },
    [pscustomobject]@{ Source = $applicationSource; Destination = [string]$manifest.application.destination },
    [pscustomobject]@{ Source = $rcloneSource; Destination = [string]$manifest.rclone.destination },
    [pscustomobject]@{ Source = $iconSource; Destination = [string]$manifest.icon.destination },
    [pscustomobject]@{ Source = $noticesSource; Destination = [string]$manifest.notices.destination }
)

$payload | ForEach-Object {
    Assert-Condition ($_.Destination -notmatch '[\\/]') "O destino de payload deve ser um nome de arquivo simples: $($_.Destination)"
}

if (-not (Test-Path -LiteralPath $outputPath)) {
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
}

$expectedNames = @($payload | ForEach-Object { $_.Destination } | Sort-Object -Unique)
$existingFiles = @(Get-ChildItem -LiteralPath $outputPath -File -Recurse -ErrorAction SilentlyContinue)
$unexpectedFiles = @($existingFiles | Where-Object { $_.Name -notin $expectedNames })
$unexpectedFileList = ($unexpectedFiles | ForEach-Object { $_.FullName }) -join ', '
Assert-Condition ($unexpectedFiles.Count -eq 0) "O staging contém arquivos não permitidos: $unexpectedFileList"

foreach ($item in $payload) {
    Copy-Item -LiteralPath $item.Source -Destination (Join-Path $outputPath $item.Destination) -Force
}

Write-Host "Payload preparado em: $outputPath"
Write-Host "rclone ${actualVersion}: $actualHash"

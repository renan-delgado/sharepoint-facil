$ErrorActionPreference = 'Stop'
$installerRoot = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Compilador do .NET Framework 4 de 64 bits ausente.' }
$output = Join-Path $installerRoot 'build\launcher'
[void](New-Item -ItemType Directory -Path $output -Force)
$arguments = @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
    '/reference:System.Windows.Forms.dll',
    ('/win32icon:' + (Join-Path $installerRoot 'assets\SharePointFacil.ico')),
    ('/out:' + (Join-Path $output 'SharePointFacil.exe')),
    (Join-Path $installerRoot 'src\Launcher.cs')
)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar o inicializador grafico.' }

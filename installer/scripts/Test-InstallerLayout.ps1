[CmdletBinding()]
param(
    [string]$InstallerRoot,
    [switch]$RequireStagedPayload,
    [string]$WinFspMsiPath,
    [string]$WinFspSha256,
    [switch]$SkipRcloneHashCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $InstallerRoot) { $InstallerRoot = Split-Path -Parent $PSScriptRoot }

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Read-XmlFile {
    param([string]$Path)

    try {
        return [xml](Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    } catch {
        throw "XML inválido em ${Path}: $($_.Exception.Message)"
    }
}

$installerRoot = [System.IO.Path]::GetFullPath($InstallerRoot)
$requiredFiles = @(
    'RcloneDriveManager.Installer.wixproj',
    'RcloneDriveManager.Bundle.wixproj',
    'Directory.Build.props',
    'NuGet.Config',
    'src\Product.wxs',
    'src\Bundle.wxs',
    'config\payload.manifest.json',
    'config\winfsp.manifest.json',
    'assets\SharePointFacil.ico',
    'assets\THIRD-PARTY-NOTICES.txt',
    'scripts\Stage-Payload.ps1',
    'scripts\Build-Launcher.ps1',
    'src\Launcher.cs',
    'third-party\winfsp\winfsp.msi'
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $installerRoot $relativePath
    Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "Arquivo obrigatório ausente: $relativePath"
}

$iconPath = Join-Path $installerRoot 'assets\SharePointFacil.ico'
$iconBytes = [System.IO.File]::ReadAllBytes($iconPath)
Assert-Condition ($iconBytes.Length -gt 6) 'O ícone do aplicativo está vazio ou truncado.'
Assert-Condition ([BitConverter]::ToUInt16($iconBytes, 0) -eq 0 -and [BitConverter]::ToUInt16($iconBytes, 2) -eq 1) 'O arquivo SharePointFacil.ico não possui um cabeçalho ICO válido.'
$iconImageCount = [BitConverter]::ToUInt16($iconBytes, 4)
Assert-Condition ($iconImageCount -ge 4) 'O ícone deve conter tamanhos suficientes para o Explorador do Windows.'
$iconWidths = @()
for ($iconIndex = 0; $iconIndex -lt $iconImageCount; $iconIndex++) {
    $entryOffset = 6 + (16 * $iconIndex)
    Assert-Condition (($entryOffset + 16) -le $iconBytes.Length) 'A tabela de imagens do ícone está truncada.'
    $iconWidths += if ($iconBytes[$entryOffset] -eq 0) { 256 } else { [int]$iconBytes[$entryOffset] }
    $imageLength = [BitConverter]::ToUInt32($iconBytes, $entryOffset + 8)
    $imageOffset = [BitConverter]::ToUInt32($iconBytes, $entryOffset + 12)
    Assert-Condition ($imageLength -gt 0 -and ($imageOffset + $imageLength) -le $iconBytes.Length) 'Uma imagem incorporada no ícone está fora dos limites do arquivo.'
}
Assert-Condition ($iconWidths -contains 16 -and $iconWidths -contains 256) 'O ícone deve incluir versões de 16 e 256 pixels.'

$projectFiles = @(
    (Join-Path $installerRoot 'RcloneDriveManager.Installer.wixproj'),
    (Join-Path $installerRoot 'RcloneDriveManager.Bundle.wixproj')
)
foreach ($projectFile in $projectFiles) {
    [void](Read-XmlFile -Path $projectFile)
    $projectText = Get-Content -LiteralPath $projectFile -Raw -Encoding UTF8
    Assert-Condition ($projectText -match 'WixToolset\.Sdk/4\.0\.6') "O projeto deve fixar WiX 4.0.6: $projectFile"
}
$msiProjectText = Get-Content -LiteralPath (Join-Path $installerRoot 'RcloneDriveManager.Installer.wixproj') -Raw -Encoding UTF8
$bundleProjectText = Get-Content -LiteralPath (Join-Path $installerRoot 'RcloneDriveManager.Bundle.wixproj') -Raw -Encoding UTF8
Assert-Condition ($msiProjectText -match '<EnableDefaultCompileItems>false</EnableDefaultCompileItems>' -and $msiProjectText -match '<Compile Include="src\\Product\.wxs"') 'O projeto MSI deve compilar somente Product.wxs.'
Assert-Condition ($bundleProjectText -match '<EnableDefaultCompileItems>false</EnableDefaultCompileItems>' -and $bundleProjectText -match '<Compile Include="src\\Bundle\.wxs"') 'O projeto do bundle deve compilar somente Bundle.wxs.'
Assert-Condition (($msiProjectText + $bundleProjectText) -notmatch '(?i)SuppressValidation|SuppressIces') 'Os projetos devem manter a validação ICE padrão do WiX habilitada.'
Assert-Condition ($msiProjectText -match '<OutputName>SharePointFacil-\$\(ProductVersion\)-x64</OutputName>') 'O MSI deve usar o nome de artefato SharePointFacil.'
Assert-Condition ($bundleProjectText -match '<OutputName>SharePointFacilSetup-\$\(ProductVersion\)-x64</OutputName>') 'O distribuidor deve usar o nome de artefato SharePointFacilSetup.'
Assert-Condition ($msiProjectText -match '<ProductManufacturer[^>]*>UTI DA INFORMATICA LTDA</ProductManufacturer>') 'O MSI deve usar a razão social validada como fabricante padrão.'
Assert-Condition ($bundleProjectText -match '<ProductManufacturer[^>]*>UTI DA INFORMATICA LTDA</ProductManufacturer>') 'O bundle deve usar a razão social validada como fabricante padrão.'

$buildScriptText = Get-Content -LiteralPath (Join-Path $installerRoot 'scripts\Build-Installer.ps1') -Raw -Encoding UTF8
Assert-Condition ($buildScriptText -match [regex]::Escape('.tools\dotnet\dotnet.exe')) 'O build deve detectar o SDK .NET portátil em installer\.tools\dotnet.'
Assert-Condition ($buildScriptText -match 'DOTNET_CLI_HOME' -and $buildScriptText -match 'NUGET_PACKAGES' -and $buildScriptText -match 'APPDATA') 'O build deve isolar o ambiente e o cache do SDK portátil dentro de installer.'
Assert-Condition ($buildScriptText -match '(?s)try\s*\{.*\}\s*finally\s*\{' -and $buildScriptText -match 'EnvironmentVariableTarget') 'O build deve restaurar as variáveis de ambiente mesmo quando falhar.'
$gitIgnoreText = Get-Content -LiteralPath (Join-Path $installerRoot '.gitignore') -Raw -Encoding UTF8
Assert-Condition ($gitIgnoreText -match '(?m)^/\.tools/$') 'O SDK portátil e seus caches não devem entrar no controle de versão.'

$manifestPath = Join-Path $installerRoot 'config\payload.manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Condition ($manifest.schemaVersion -eq 1) 'Versão de manifesto de payload não suportada.'
Assert-Condition (([string]$manifest.rclone.version) -match '^\d+\.\d+\.\d+$') 'A versão do rclone no manifesto é inválida.'
Assert-Condition (([string]$manifest.rclone.sha256) -match '^[A-Fa-f0-9]{64}$') 'O SHA-256 do rclone no manifesto é inválido.'

$winFspManifestPath = Join-Path $installerRoot 'config\winfsp.manifest.json'
$winFspManifest = Get-Content -LiteralPath $winFspManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Condition ($winFspManifest.schemaVersion -eq 1) 'Versão de manifesto do WinFsp não suportada.'
Assert-Condition ([string]$winFspManifest.version -eq '2.2.26215') 'A versão fixada do WinFsp deve ser 2.2.26215 (v2.2B4).'
Assert-Condition ([string]$winFspManifest.sourceUrl -eq 'https://github.com/winfsp/winfsp/releases/download/v2.2B4/winfsp-2.2.26215.msi') 'A URL do WinFsp deve apontar para o asset oficial fixado da v2.2B4.'
Assert-Condition ([string]$winFspManifest.packageFileName -match '^[^\\/]+\.msi$') 'O nome de arquivo do WinFsp deve ser um MSI simples.'
Assert-Condition ([string]$winFspManifest.sha256 -eq '2ECB5C89405488A95BBD8A01875E02C48534FD37BBDFD84488F7590464D65944') 'O SHA-256 fixado do WinFsp v2.2B4 foi alterado.'
$bundledWinFspPath = Join-Path (Join-Path $installerRoot 'third-party\winfsp') ([string]$winFspManifest.packageFileName)
$bundledWinFspHash = (Get-FileHash -LiteralPath $bundledWinFspPath -Algorithm SHA256).Hash.ToUpperInvariant()
Assert-Condition ($bundledWinFspHash -eq ([string]$winFspManifest.sha256).ToUpperInvariant()) 'O MSI local do WinFsp não corresponde ao manifesto fixado.'

$productPath = Join-Path $installerRoot 'src\Product.wxs'
$product = Read-XmlFile -Path $productPath
$wixNs = New-Object System.Xml.XmlNamespaceManager($product.NameTable)
$wixNs.AddNamespace('wix', 'http://wixtoolset.org/schemas/v4/wxs')

$package = $product.SelectSingleNode('/wix:Wix/wix:Package', $wixNs)
Assert-Condition ($null -ne $package) 'Package WiX não encontrado.'
Assert-Condition ($package.Name -eq 'SharePoint Fácil') 'O nome público do MSI deve ser SharePoint Fácil.'
Assert-Condition ($package.Scope -eq 'perMachine') 'O MSI deve ser por máquina.'
Assert-Condition ($package.UpgradeCode -match '^\{[0-9A-Fa-f-]{36}\}$') 'O MSI deve ter UpgradeCode fixo.'
Assert-Condition ($null -eq $product.SelectSingleNode('//wix:Property[@Id="ARPNOREPAIR"]', $wixNs)) 'O MSI deve permitir a opção Reparar no Windows.'
$appIcon = $product.SelectSingleNode('//wix:Icon[@Id="SharePointFacil.ico"]', $wixNs)
Assert-Condition ($null -ne $appIcon -and $appIcon.SourceFile -match 'SharePointFacil\.ico$') 'O MSI deve incorporar o ícone do SharePoint Fácil.'
Assert-Condition ($null -ne $product.SelectSingleNode('//wix:Property[@Id="ARPPRODUCTICON" and @Value="SharePointFacil.ico"]', $wixNs)) 'O ícone deve aparecer em Aplicativos instalados.'
Assert-Condition ($null -ne $product.SelectSingleNode('//wix:Property[@Id="ARPCONTACT" and contains(@Value,"UTI DA INFORMATICA LTDA") and contains(@Value,"04.181.850/0001-94")]', $wixNs)) 'O MSI deve identificar a razão social e o CNPJ do fabricante.'
Assert-Condition ($null -ne $product.SelectSingleNode('//wix:Property[@Id="ARPURLINFOABOUT" and @Value="https://utidainformatica.net/"]', $wixNs)) 'O MSI deve apontar para o site oficial da UTI da Informática.'
Assert-Condition ($null -ne $product.SelectSingleNode('//wix:Property[@Id="ARPHELPLINK" and @Value="https://utidainformatica.net/contato/"]', $wixNs)) 'O MSI deve apontar para a página oficial de contato.'

$majorUpgrade = $product.SelectSingleNode('/wix:Wix/wix:Package/wix:MajorUpgrade', $wixNs)
Assert-Condition ($null -ne $majorUpgrade) 'O MSI deve declarar MajorUpgrade.'
Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$majorUpgrade.DowngradeErrorMessage)) 'MajorUpgrade deve bloquear downgrade.'
Assert-Condition ($majorUpgrade.Schedule -eq 'afterInstallInitialize') 'A remoção da versão anterior deve ocorrer dentro da transação de instalação.'

$componentGuids = @($product.SelectNodes('//wix:Component', $wixNs) | ForEach-Object { [string]$_.Guid })
Assert-Condition (@($componentGuids | Where-Object { $_ -notmatch '^\{[0-9A-Fa-f-]{36}\}$' }).Count -eq 0) 'Todos os componentes MSI devem ter GUID fixo e válido.'
Assert-Condition (@($componentGuids | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) 'Os GUIDs dos componentes MSI devem ser exclusivos.'

$programFiles = $product.SelectSingleNode('//wix:StandardDirectory[@Id="ProgramFiles6432Folder"]', $wixNs)
Assert-Condition ($null -ne $programFiles) 'O MSI deve usar ProgramFiles6432Folder.'
Assert-Condition ($programFiles.SelectSingleNode('wix:Directory[@Id="INSTALLFOLDER" and @Name="SharePoint Fácil"]', $wixNs) -ne $null) 'A pasta instalada deve se chamar SharePoint Fácil.'
Assert-Condition ($null -ne $product.SelectSingleNode('//wix:StandardDirectory[@Id="ProgramMenuFolder"]', $wixNs)) 'O MSI deve declarar a pasta padrão do menu Iniciar.'
Assert-Condition ($null -ne $product.SelectSingleNode('//wix:StandardDirectory[@Id="DesktopFolder"]', $wixNs)) 'O MSI deve declarar a pasta padrão da área de trabalho.'
Assert-Condition ($null -ne $product.SelectSingleNode('//wix:StandardDirectory[@Id="StartupFolder"]', $wixNs)) 'O MSI deve declarar a pasta padrão de inicialização.'

$sourceFiles = @($product.SelectNodes('//wix:File', $wixNs) | ForEach-Object { [string]$_.Source })
$documentMenu = $product.SelectSingleNode('//wix:Component[@Id="DocumentContextMenu"]', $wixNs)
Assert-Condition ($null -ne $documentMenu) 'O menu de documentos deve pertencer a um componente próprio.'
Assert-Condition ($null -ne $product.SelectSingleNode('//wix:Feature/wix:ComponentRef[@Id="DocumentContextMenu"]', $wixNs)) 'O menu de documentos deve ser instalado pelo recurso principal.'
$documentCommands = @($documentMenu.SelectNodes('.//wix:RegistryKey[@Key="command"]/wix:RegistryValue', $wixNs))
Assert-Condition ($documentCommands.Count -eq 4) 'O menu deve conter quatro comandos de documento.'
foreach ($action in @('Exclusive', 'Coauthor', 'SharePoint', 'Finish')) {
    $command = @($documentCommands | Where-Object { $_.Value -match ('-DocumentAction ' + $action + ' ') })
    Assert-Condition ($command.Count -eq 1) ('Comando ausente ou duplicado: ' + $action)
    Assert-Condition ($command[0].Value -match '^"\[INSTALLFOLDER\]SharePointFacil.exe" ' -and $command[0].Value -match '-DocumentPath "%1"$') 'O menu deve chamar o inicializador grafico com o documento entre aspas.'
    Assert-Condition ($command[0].Value -notmatch '(?i)-Command|cmd.exe') 'O documento deve ser passado como argumento, sem avaliação de código.'
}
$officeVerbs = $product.SelectSingleNode('//wix:Component[@Id="OfficeOpenVerbs"]', $wixNs)
Assert-Condition ($null -ne $officeVerbs -and $null -ne $product.SelectSingleNode('//wix:Feature/wix:ComponentRef[@Id="OfficeOpenVerbs"]', $wixNs)) 'O duplo clique do Office deve ser instalado pelo recurso principal.'
foreach ($progId in @('Word.Document.12', 'Excel.Sheet.12', 'PowerPoint.Show.12')) {
    $shellKey = $officeVerbs.SelectSingleNode(('wix:RegistryKey[@Root="HKLM" and @Key="Software\Classes\{0}\shell"]' -f $progId), $wixNs)
    Assert-Condition ($null -ne $shellKey) ('Verbo de duplo clique ausente: ' + $progId)
    Assert-Condition ($shellKey.SelectSingleNode('wix:RegistryValue[not(@Name) and @Value="SharePointFacil.Open"]', $wixNs) -ne $null) ('O verbo padrão deve ser SharePointFacil.Open: ' + $progId)
    Assert-Condition ($null -eq $shellKey.GetAttributeNode('ForceDeleteOnUninstall')) 'A desinstalação não pode apagar os verbos do Office.'
    $verb = $shellKey.SelectSingleNode('wix:RegistryKey[@Key="SharePointFacil.Open" and @ForceDeleteOnUninstall="yes"]', $wixNs)
    $verbCommand = $verb.SelectSingleNode('wix:RegistryKey[@Key="command"]/wix:RegistryValue', $wixNs)
    Assert-Condition ($verbCommand.Value -eq '"[INSTALLFOLDER]SharePointFacil.exe" -OfficeOpen "%1"') 'O duplo clique deve chamar o inicializador com o documento entre aspas.'
}
$expectedSources = @(
    '$(var.PayloadDir)\SharePointFacil.exe',
    '$(var.PayloadDir)\RcloneDriveManager.ps1',
    '$(var.PayloadDir)\rclone.exe',
    '$(var.PayloadDir)\SharePointFacil.ico',
    '$(var.PayloadDir)\THIRD-PARTY-NOTICES.txt'
)
Assert-Condition (@(Compare-Object -ReferenceObject ($expectedSources | Sort-Object) -DifferenceObject ($sourceFiles | Sort-Object)).Count -eq 0) 'O MSI deve empacotar somente os cinco arquivos de payload aprovados.'
Assert-Condition (@($sourceFiles | Where-Object { $_ -match '(?i)settings\.json|rclone\.conf|appdata' }).Count -eq 0) 'O MSI não pode empacotar configurações por usuário.'

$shortcuts = @($product.SelectNodes('//wix:Shortcut', $wixNs))
Assert-Condition ($shortcuts.Count -eq 3) 'O MSI deve criar atalhos no menu Iniciar, na área de trabalho e na inicialização comum.'
Assert-Condition (@($shortcuts | Where-Object { $_.Name -eq 'SharePoint Fácil' }).Count -eq 3) 'Todos os atalhos devem usar o nome SharePoint Fácil.'
Assert-Condition (@($shortcuts | Where-Object { $_.Target -eq '[INSTALLFOLDER]SharePointFacil.exe' }).Count -eq 3) 'Os atalhos devem chamar o inicializador grafico sem console.'
Assert-Condition (@($shortcuts | Where-Object { $_.GetAttribute('Arguments') -notin @('', '-AutoMount') }).Count -eq 0) 'Os atalhos devem passar somente os argumentos autorizados ao inicializador.'
Assert-Condition (@($shortcuts | Where-Object { $_.Icon -eq 'SharePointFacil.ico' }).Count -eq 3) 'Todos os atalhos devem usar o ícone do SharePoint Fácil.'
$autoMountShortcuts = @($shortcuts | Where-Object { $_.HasAttribute('Arguments') -and $_.Arguments -match '(?i)(?:^|\s)-AutoMount(?:\s|$)' })
Assert-Condition ($autoMountShortcuts.Count -eq 1 -and $autoMountShortcuts[0].Id -eq 'AutoMountShortcutLink') 'Somente o atalho de inicialização deve chamar -AutoMount.'
$shortcutComponent = $product.SelectSingleNode('//wix:Component[@Id="ApplicationShortcuts"]', $wixNs)
Assert-Condition ($null -ne $shortcutComponent) 'Os atalhos devem ter um componente MSI próprio.'
Assert-Condition (@($shortcutComponent.SelectNodes('wix:Shortcut', $wixNs)).Count -eq 3) 'Os três atalhos devem pertencer ao mesmo componente.'
Assert-Condition ($null -ne $shortcutComponent.SelectSingleNode('wix:RegistryValue[@Root="HKCU" and @KeyPath="yes"]', $wixNs)) 'O componente dos atalhos deve usar o KeyPath por usuário exigido para atalhos não anunciados.'
Assert-Condition ($null -ne $product.SelectSingleNode('//wix:Feature/wix:ComponentRef[@Id="ApplicationShortcuts"]', $wixNs)) 'O componente dos atalhos deve pertencer ao recurso principal do MSI.'
Assert-Condition ($null -eq $product.SelectSingleNode('//wix:Component[@Id="StartMenuShortcut" or @Id="DesktopShortcut" or @Id="AutoMountShortcut"]', $wixNs)) 'Não devem existir componentes separados de atalho que causem ICE38, ICE43 ou ICE57.'

Assert-Condition ($null -eq $product.SelectSingleNode('//wix:CustomAction', $wixNs) -and $null -eq $product.SelectSingleNode('//wix:Binary', $wixNs)) 'O MSI não deve executar scripts ou auxiliares por CustomAction.'

$bundlePath = Join-Path $installerRoot 'src\Bundle.wxs'
$bundle = Read-XmlFile -Path $bundlePath
$bundleNs = New-Object System.Xml.XmlNamespaceManager($bundle.NameTable)
$bundleNs.AddNamespace('wix', 'http://wixtoolset.org/schemas/v4/wxs')
$bundleNs.AddNamespace('bal', 'http://wixtoolset.org/schemas/v4/wxs/bal')

$bundleRoot = $bundle.SelectSingleNode('/wix:Wix/wix:Bundle', $bundleNs)
Assert-Condition ($null -ne $bundleRoot) 'Bundle WiX não encontrado.'
Assert-Condition ($bundleRoot.Name -eq 'SharePoint Fácil - Instalador') 'O distribuidor deve exibir o nome SharePoint Fácil.'
Assert-Condition ($bundleRoot.UpgradeCode -match '^\{[0-9A-Fa-f-]{36}\}$') 'O bundle deve ter UpgradeCode fixo.'
Assert-Condition ($bundleRoot.IconSourceFile -match 'SharePointFacil\.ico$') 'O distribuidor deve usar o ícone do SharePoint Fácil.'
Assert-Condition ($null -ne $bundle.SelectSingleNode('//bal:WixStandardBootstrapperApplication', $bundleNs)) 'O bundle deve usar BootstrapperApplication padrão.'
Assert-Condition ($null -eq $bundle.SelectSingleNode('//*[local-name()="RegistrySearch"]', $bundleNs)) 'O bundle não deve pular a manutenção do WinFsp apenas pela presença do serviço.'

$chain = $bundle.SelectNodes('/wix:Wix/wix:Bundle/wix:Chain/wix:MsiPackage', $bundleNs)
Assert-Condition ($chain.Count -eq 2) 'O bundle deve encadear WinFsp e o MSI do aplicativo.'
$winFspPackage = $chain.Item(0)
$appPackage = $chain.Item(1)
Assert-Condition ($winFspPackage.Id -eq 'WinFsp') 'WinFsp deve ser o primeiro pacote da cadeia.'
Assert-Condition ($winFspPackage.Permanent -eq 'yes') 'WinFsp deve permanecer instalado na remoção do aplicativo.'
Assert-Condition ($winFspPackage.ForcePerMachine -eq 'yes') 'WinFsp deve instalar por máquina.'
Assert-Condition (-not $winFspPackage.HasAttribute('InstallCondition')) 'O MSI oficial deve sempre decidir se mantém, repara ou atualiza o WinFsp 2.x.'
Assert-Condition ($appPackage.Id -eq 'RcloneDriveManager' -and $appPackage.ForcePerMachine -eq 'yes') 'O MSI do aplicativo deve instalar por máquina.'

$chainPackages = @($bundle.SelectNodes('/wix:Wix/wix:Bundle/wix:Chain/*', $bundleNs))
Assert-Condition ($chainPackages.Count -eq 2 -and $chainPackages[0].Id -eq 'WinFsp' -and $chainPackages[1].Id -eq 'RcloneDriveManager') 'A cadeia pública deve conter somente WinFsp e o aplicativo.'

Assert-Condition (($sourceFiles -join "`n") -notmatch '(?i)\.vbs$' -and (Get-Content -LiteralPath $productPath -Raw -Encoding UTF8) -notmatch '(?i)VBScript|\.vbs') 'O produto distribuído não pode depender de VBScript.'

$readmeText = Get-Content -LiteralPath (Join-Path $installerRoot 'README.md') -Raw -Encoding UTF8
Assert-Condition ($readmeText -match 'UTI DA INFORMATICA LTDA' -and $readmeText -match '04\.181\.850/0001-94') 'O README deve documentar a identidade jurídica do publicador.'
Assert-Condition ($readmeText -match [regex]::Escape('%LOCALAPPDATA%\SharePointFacil')) 'O README deve documentar o local correto dos dados por usuário.'
Assert-Condition ($readmeText -match '2\.2\.26215' -and $readmeText -match 'v2\.2B4' -and $readmeText -match '(?i)pré-(?:release|lançamento)') 'O README deve documentar a versão pré-release fixada do WinFsp.'
Assert-Condition ($readmeText -match '(?i)vulnerabil' -and $readmeText -match '(?i)deadlock' -and $readmeText -match '(?i)escrita' -and $readmeText -match '(?i)renome') 'O README deve registrar a justificativa técnica para a pré-release do WinFsp.'
Assert-Condition ($readmeText -match '(?i)VFS' -and $readmeText -match '(?i)Word' -and $readmeText -match '(?i)Excel' -and $readmeText -match '(?i)PowerPoint') 'O README deve orientar o uso seguro com arquivos Office.'
Assert-Condition ($readmeText -match '(?i)cache\s+sujo' -and $readmeText -match '(?i)envio\s+pendente' -and $readmeText -match '(?i)coautoria' -and $readmeText -match '(?i)conflito') 'O README deve explicar cache pendente e risco de conflito em coautoria.'

if ($RequireStagedPayload) {
    $payloadDirectory = Join-Path $installerRoot 'build\payload'
    Assert-Condition (Test-Path -LiteralPath $payloadDirectory -PathType Container) 'Payload ainda não foi preparado.'
    $expectedPayloadNames = @(
        [string]$manifest.launcher.destination,
        [string]$manifest.application.destination,
        [string]$manifest.rclone.destination,
        [string]$manifest.icon.destination,
        [string]$manifest.notices.destination
    ) | Sort-Object
    $stagedFiles = @(Get-ChildItem -LiteralPath $payloadDirectory -File -Recurse)
    $stagedNames = @($stagedFiles | ForEach-Object { $_.Name } | Sort-Object)
    Assert-Condition (@(Compare-Object -ReferenceObject $expectedPayloadNames -DifferenceObject $stagedNames).Count -eq 0) 'O staging contém arquivos ausentes ou não autorizados.'

    $stagedRclone = Join-Path $payloadDirectory $manifest.rclone.destination
    $actualRcloneHash = (Get-FileHash -LiteralPath $stagedRclone -Algorithm SHA256).Hash.ToUpperInvariant()
    if (-not $SkipRcloneHashCheck) {
        Assert-Condition ($actualRcloneHash -eq ([string]$manifest.rclone.sha256).ToUpperInvariant()) 'O rclone em staging não corresponde ao manifesto.'
    }
}

if (-not [string]::IsNullOrWhiteSpace($WinFspMsiPath)) {
    $resolvedWinFspPath = [System.IO.Path]::GetFullPath($WinFspMsiPath)
    Assert-Condition (Test-Path -LiteralPath $resolvedWinFspPath -PathType Leaf) "MSI do WinFsp não encontrado: $resolvedWinFspPath"
    if ([string]::IsNullOrWhiteSpace($WinFspSha256)) {
        $WinFspSha256 = [string]$winFspManifest.sha256
    }
    Assert-Condition ($WinFspSha256 -match '^[A-Fa-f0-9]{64}$') 'Informe um SHA-256 válido para validar o MSI do WinFsp.'
    $actualWinFspHash = (Get-FileHash -LiteralPath $resolvedWinFspPath -Algorithm SHA256).Hash
    Assert-Condition ($actualWinFspHash -eq $WinFspSha256.ToUpperInvariant()) 'O SHA-256 do MSI do WinFsp não confere.'
}

Write-Host "Validação estática concluída: $installerRoot"

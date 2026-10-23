param(
    [switch]$AutoMount,
    [switch]$SelfTest,
    [switch]$ShellWatcher,
    [ValidateSet('Exclusive', 'Coauthor', 'SharePoint', 'Finish', 'Auto')]
    [string]$DocumentAction,
    [string]$DocumentPath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppName = 'SharePoint Fácil'
$script:AppVersion = '1.1.3'
$script:ExpectedRcloneHash = '033EEE51C9AD47C2DE2624B6674D355274BCD6CF0027A5F85DB4437BA24AE81C'
$script:RclonePath = Join-Path $PSScriptRoot 'rclone.exe'
$script:DataDir = Join-Path $env:LOCALAPPDATA 'SharePointFacil'
$script:SettingsFile = Join-Path $script:DataDir 'settings.json'
$script:RcloneConfigFile = Join-Path $script:DataDir 'rclone.conf'
$script:ConfigSecretFile = Join-Path $script:DataDir 'config.secret'
$script:ControllerFile = Join-Path $script:DataDir 'controller.json'
$script:CacheDir = Join-Path $script:DataDir 'cache'
$script:LogDir = Join-Path $script:DataDir 'logs'
$script:AppLogFile = Join-Path $script:LogDir 'SharePointFacil.log'
$script:LegacySettingsFile = Join-Path (Join-Path $env:APPDATA 'RcloneDriveManager') 'settings.json'
$script:Profiles = @()
$script:ConfigPassword = $null
$script:Controller = $null
$script:MainForm = $null
$script:IsBusy = $false
$script:BusyDepth = 0
$script:StatusDot = $null
$script:RefreshTimer = $null
$script:UpdateActions = $null
$script:LastLogWriteSucceeded = $false
$script:Entropy = [Text.Encoding]::UTF8.GetBytes('SharePointFacil.Config.v1.9FD81408')
$script:VfsWriteBackSeconds = 2
$script:DirectoryCacheTime = '24h'
$script:RemotePollInterval = '15s'

if ($SelfTest) {
    $script:DataDir = Join-Path ([IO.Path]::GetTempPath()) ('SharePointFacil-SelfTest-' + [Guid]::NewGuid().ToString('N'))
    $script:SettingsFile = Join-Path $script:DataDir 'settings.json'
    $script:RcloneConfigFile = Join-Path $script:DataDir 'rclone.conf'
    $script:ConfigSecretFile = Join-Path $script:DataDir 'config.secret'
    $script:ControllerFile = Join-Path $script:DataDir 'controller.json'
    $script:CacheDir = Join-Path $script:DataDir 'cache'
    $script:LogDir = Join-Path $script:DataDir 'logs'
    $script:AppLogFile = Join-Path $script:LogDir 'SharePointFacil.log'
    $script:LegacySettingsFile = ''
}

$script:Colors = @{
    Ink       = [Drawing.Color]::FromArgb(24, 43, 56)
    Muted     = [Drawing.Color]::FromArgb(91, 108, 119)
    Surface   = [Drawing.Color]::White
    Canvas    = [Drawing.Color]::FromArgb(244, 248, 250)
    Border    = [Drawing.Color]::FromArgb(216, 227, 232)
    Navy      = [Drawing.Color]::FromArgb(13, 59, 71)
    Teal      = [Drawing.Color]::FromArgb(3, 120, 124)
    TealHover = [Drawing.Color]::FromArgb(2, 101, 105)
    PaleTeal  = [Drawing.Color]::FromArgb(226, 244, 243)
    Success   = [Drawing.Color]::FromArgb(16, 124, 65)
    Warning   = [Drawing.Color]::FromArgb(173, 103, 0)
    Danger    = [Drawing.Color]::FromArgb(178, 34, 34)
}

function Protect-LogMessage {
    param([object]$Message)
    $safe = [string]$Message
    if (-not $safe) { return '' }

    # RC errors can echo the complete request. In config/create and config/update
    # the token is itself a JSON string, so a simple access_token regex is not
    # enough: redact the whole sensitive value, including escaped quotes.
    $valuePattern = '(?is)(?<lead>^|[\s{,\[]|\\")(?<prefix>"?(?:access_token|refresh_token|client_secret|token|authorization|password|secret)"?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|[^\s,;}\r\n]+)'
    $safe = [regex]::Replace($safe, $valuePattern, {
        param($match)
        return $match.Groups['lead'].Value + $match.Groups['prefix'].Value + '"[removido]"'
    })
    $safe = [regex]::Replace($safe, '(?im)(?<prefix>\bAuthorization\s*[:=]\s*)[^\r\n]+', '${prefix}[removido]')
    $safe = [regex]::Replace($safe, '(?im)(?<prefix>\bRCLONE_(?:CONFIG_PASS|RC_PASS)\s*=\s*)[^\r\n]+', '${prefix}[removido]')
    $safe = [regex]::Replace($safe, '(?i)(?<prefix>\b(?:access_token|refresh_token|client_secret|token)=)[^&\s]+', '${prefix}[removido]')
    return $safe
}

function Write-AppLog {
    param([string]$Level, [string]$Message)
    $script:LastLogWriteSucceeded = $false
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $script:AppLogFile) {
            $logInfo = Get-Item -LiteralPath $script:AppLogFile
            if ($logInfo.Length -gt 5MB) {
                $backup = $script:AppLogFile + '.1'
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                Move-Item -LiteralPath $script:AppLogFile -Destination $backup -Force
            }
        }
        $safeMessage = Protect-LogMessage $Message
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level.ToUpperInvariant(), $safeMessage
        Add-Content -LiteralPath $script:AppLogFile -Value $line -Encoding UTF8
        $script:LastLogWriteSucceeded = $true
    } catch {}
}

function Initialize-ShellNotifier {
    if ('SharePointFacilShellNotifier' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SharePointFacilShellNotifier
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(uint eventId, uint flags, string item1, IntPtr item2);
}
'@
}

function Get-OpenExplorerDirectories {
    $paths = @()
    $shell = $null
    $windows = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $windows = $shell.Windows()
        foreach ($window in @($windows)) {
            try {
                $path = [string]$window.Document.Folder.Self.Path
                if ($path -and [IO.Path]::IsPathRooted($path)) { $paths += $path }
            } catch {}
            finally { if ($window) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($window) } }
        }
    } catch {
        Write-AppLog 'WARN' ('Não foi possível consultar as pastas abertas do Explorador: ' + $_.Exception.Message)
    } finally {
        if ($windows) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($windows) } catch {} }
        if ($shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch {} }
    }
    return @($paths | Select-Object -Unique)
}

function Send-ShellDirectoryUpdate {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    Initialize-ShellNotifier
    # SHCNE_UPDATEDIR + SHCNF_PATHW tells Explorer to enumerate this folder
    # again without closing the user's window or changing its current path.
    [SharePointFacilShellNotifier]::SHChangeNotify(0x00001000, 0x00000005, $Path, [IntPtr]::Zero)
}

function Notify-ProfileExplorerViews {
    param($Profile, [string[]]$OpenDirectories)
    $root = ([string]$Profile.drive).ToUpperInvariant() + ':\'
    if (-not $OpenDirectories) { $OpenDirectories = @(Get-OpenExplorerDirectories) }
    $targets = @($root)
    foreach ($path in @($OpenDirectories)) {
        if ([string]$path -and ([string]$path).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $targets += [string]$path
        }
    }
    foreach ($target in @($targets | Select-Object -Unique)) {
        try { Send-ShellDirectoryUpdate $target }
        catch { Write-AppLog 'WARN' ('O Explorador não aceitou a atualização de {0}: {1}' -f $target, $_.Exception.Message) }
    }
}

function Start-ShellWatcher {
    if ($SelfTest -or $ShellWatcher) { return }
    $launcher = Join-Path $PSScriptRoot 'SharePointFacil.exe'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        Write-AppLog 'WARN' 'O observador do Explorador não foi iniciado porque o launcher integrado não foi encontrado.'
        return
    }
    try {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $launcher
        $start.Arguments = '-ShellWatcher'
        $start.WorkingDirectory = $PSScriptRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $process = [Diagnostics.Process]::Start($start)
        if ($process) { $process.Dispose() }
    } catch {
        Write-AppLog 'WARN' ('Não foi possível iniciar o observador do Explorador: ' + $_.Exception.Message)
    }
}

function Invoke-ShellWatcher {
    $emptyChecks = 0
    while ($true) {
        try {
            # Reload the small settings file so a watcher already running also
            # learns about units added or removed by the main window.
            Load-Settings
            $controller = Read-ControllerState
            if (-not $controller -or -not (Test-ControllerWithRetry $controller)) {
                $emptyChecks++
            } else {
                $script:Controller = $controller
                $response = Invoke-ControllerRequest 'mount/listmounts' @{} $controller 5
                $mounts = @($response.mountPoints)
                $mountedProfiles = @($script:Profiles | Where-Object { Test-ExactMount $_ $mounts })
                if ($mountedProfiles.Count -eq 0) {
                    $emptyChecks++
                } else {
                    $emptyChecks = 0
                    $openDirectories = @(Get-OpenExplorerDirectories)
                    foreach ($profile in $mountedProfiles) {
                        Notify-ProfileExplorerViews $profile $openDirectories
                    }
                }
            }
        } catch {
            $emptyChecks++
            Write-AppLog 'WARN' ('Falha temporária no observador do Explorador: ' + $_.Exception.Message)
        }
        if ($emptyChecks -ge 2) { return 0 }
        Start-Sleep -Seconds 15
    }
}

function Show-FriendlyError {
    param([string]$Title, [string]$Message, [object]$ErrorRecord)
    $reference = 'SPF-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($ErrorRecord) { Write-AppLog 'ERROR' ('[' + $reference + '] ' + ($ErrorRecord | Out-String)) }
    if ($AutoMount) { return }
    $supportText = if ($script:LastLogWriteSucceeded) {
        'Os detalhes foram registrados para o suporte. Referência: ' + $reference
    } else {
        $detail = if ($ErrorRecord) { Protect-LogMessage $ErrorRecord.Exception.Message } else { 'Falha sem detalhe adicional.' }
        if ($detail.Length -gt 260) { $detail = $detail.Substring(0, 260) + '…' }
        'Detalhe seguro: ' + $detail
    }
    [Windows.Forms.MessageBox]::Show(
        $Message + [Environment]::NewLine + [Environment]::NewLine + $supportText,
        $Title,
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Enter-AppBusy {
    $script:BusyDepth++
    $script:IsBusy = $true
}

function Exit-AppBusy {
    $script:BusyDepth = [Math]::Max(0, $script:BusyDepth - 1)
    $script:IsBusy = $script:BusyDepth -gt 0
}

function Begin-UiAction {
    if ($script:IsBusy) { return $false }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:UiDocumentGuard = New-Object Threading.Mutex($false, ('Local\SharePointFacil-Documents-' + $sid))
    $held = $false
    try { $held = $script:UiDocumentGuard.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) {
        $script:UiDocumentGuard.Dispose()
        $script:UiDocumentGuard = $null
        [Windows.Forms.MessageBox]::Show('Há uma operação em andamento pelo Explorador. Aguarde para continuar.', $script:AppName) | Out-Null
        return $false
    }
    Enter-AppBusy
    if ($script:ConnectButton) { $script:ConnectButton.Enabled = $false }
    if ($script:UpdateActions) { & $script:UpdateActions }
    return $true
}

function End-UiAction {
    Exit-AppBusy
    if ($script:UiDocumentGuard) {
        $script:UiDocumentGuard.ReleaseMutex()
        $script:UiDocumentGuard.Dispose()
        $script:UiDocumentGuard = $null
    }
    if ($script:ConnectButton) { $script:ConnectButton.Enabled = -not $script:IsBusy }
    if ($script:UpdateActions) { & $script:UpdateActions }
}

function Set-PrivatePathAcl {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        if ($item.PSIsContainer) {
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            $propagation = [Security.AccessControl.PropagationFlags]::None
            $acl.SetOwner($currentSid)
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($currentSid, 'FullControl', $inheritance, $propagation, 'Allow')))
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($systemSid, 'FullControl', $inheritance, $propagation, 'Allow')))
        } else {
            $acl = New-Object Security.AccessControl.FileSecurity
            $acl.SetOwner($currentSid)
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($currentSid, 'FullControl', 'Allow')))
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($systemSid, 'FullControl', 'Allow')))
        }
        if ($item.PSIsContainer) { [IO.Directory]::SetAccessControl($item.FullName, $acl) }
        else { [IO.File]::SetAccessControl($item.FullName, $acl) }
    } catch {
        Write-AppLog 'WARN' ('Não foi possível restringir a ACL de {0}: {1}' -f $Path, $_.Exception.Message)
    }
}

function Initialize-DataDirectories {
    foreach ($directory in @($script:DataDir, $script:CacheDir, $script:LogDir)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Set-PrivatePathAcl $script:DataDir
}

function Protect-LocalSecret {
    param([string]$PlainText)
    $bytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $script:Entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Convert]::ToBase64String($protected)
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Unprotect-LocalSecret {
    param([string]$ProtectedText)
    $protected = [Convert]::FromBase64String($ProtectedText)
    $plain = $null
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $script:Entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plain)
    } finally {
        [Array]::Clear($protected, 0, $protected.Length)
        if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
}

function New-RandomSecret {
    $bytes = New-Object byte[] 32
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    try { return [Convert]::ToBase64String($bytes) } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Write-AtomicText {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
    $backup = $Path + '.bak'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup, $true)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
        Set-PrivatePathAcl $Path
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-OrCreateConfigPassword {
    $foundSecretFile = $false
    foreach ($candidate in @($script:ConfigSecretFile, ($script:ConfigSecretFile + '.bak'))) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $foundSecretFile = $true
        try {
            $password = Unprotect-LocalSecret (Get-Content -LiteralPath $candidate -Raw)
            if ([string]::IsNullOrWhiteSpace($password)) { throw 'O segredo protegido está vazio.' }
            if ($candidate -ne $script:ConfigSecretFile) {
                Write-AtomicText $script:ConfigSecretFile (Protect-LocalSecret $password)
                Write-AppLog 'WARN' 'O segredo da configuração foi restaurado da cópia de segurança.'
            }
            return $password
        } catch {
            Write-AppLog 'WARN' ('Segredo local inválido em {0}: {1}' -f (Split-Path -Leaf $candidate), $_.Exception.Message)
        }
    }
    if ($foundSecretFile) {
        throw 'O segredo que protege a configuração local e sua cópia de segurança estão inválidos.'
    }
    foreach ($configCandidate in @($script:RcloneConfigFile, ($script:RcloneConfigFile + '.bak'))) {
        if ((Test-Path -LiteralPath $configCandidate -PathType Leaf) -and (Test-ConfigFileEncryptedPrefix $configCandidate)) {
            throw 'A configuração está protegida, mas o segredo local necessário para abri-la não foi encontrado.'
        }
    }
    $password = New-RandomSecret
    Write-AtomicText $script:ConfigSecretFile (Protect-LocalSecret $password)
    return $password
}

function Test-ConfigFileEncryptedPrefix {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $reader = $null
    try {
        $reader = New-Object IO.StreamReader($Path, [Text.Encoding]::UTF8, $true, 1024)
        for ($lineNumber = 0; $lineNumber -lt 8 -and -not $reader.EndOfStream; $lineNumber++) {
            if ([string]$reader.ReadLine() -match '^RCLONE_ENCRYPT_V\d+:\s*$') { return $true }
        }
        return $false
    } finally {
        if ($reader) { $reader.Dispose() }
    }
}

function Quote-Arg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Join-Arguments {
    param([string[]]$Values)
    return (($Values | ForEach-Object { Quote-Arg $_ }) -join ' ')
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WinFspInstalled {
    $service = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    $dlls = @(
        (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'WinFsp\bin\winfsp-x64.dll'),
        (Join-Path $env:ProgramFiles 'WinFsp\bin\winfsp-x64.dll')
    )
    return ($service -and $service.Status -eq 'Running' -and @($dlls | Where-Object { $_ -and (Test-Path -LiteralPath $_) }).Count -gt 0)
}

function Test-BundledRclone {
    if (-not (Test-Path -LiteralPath $script:RclonePath -PathType Leaf)) { return $false }
    $stream = $null
    $sha256 = $null
    try {
        $stream = [IO.File]::OpenRead($script:RclonePath)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($stream)
        $actual = ([BitConverter]::ToString($hashBytes)).Replace('-', '')
        return $actual -eq $script:ExpectedRcloneHash
    } catch { return $false }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($sha256) { $sha256.Dispose() }
    }
}

function New-BusyWindow {
    param([string]$Message, [bool]$CanCancel = $true)
    $window = New-Object Windows.Forms.Form
    $window.Text = $script:AppName
    $window.Size = New-Object Drawing.Size(500, 190)
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.MinimizeBox = $false
    $window.ControlBox = $false
    $window.ShowIcon = $false
    $window.StartPosition = 'CenterParent'
    $window.BackColor = $script:Colors.Surface
    $window.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $window.AutoScaleMode = 'Dpi'
    $accent = New-Object Windows.Forms.Panel
    $accent.BackColor = $script:Colors.Teal
    $accent.Dock = 'Top'
    $accent.Height = 5
    $window.Controls.Add($accent)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Message
    $label.Location = New-Object Drawing.Point(24, 27)
    $label.Size = New-Object Drawing.Size(440, 46)
    $label.ForeColor = $script:Colors.Ink
    $window.Controls.Add($label)
    $bar = New-Object Windows.Forms.ProgressBar
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 28
    $bar.Location = New-Object Drawing.Point(26, 82)
    $bar.Size = New-Object Drawing.Size(438, 18)
    $window.Controls.Add($bar)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancelar'
    $cancel.Location = New-Object Drawing.Point(369, 115)
    $cancel.Size = New-Object Drawing.Size(95, 30)
    $cancel.Visible = $CanCancel
    $window.Controls.Add($cancel)
    $state = [pscustomobject]@{ Canceled = $false }
    $cancel.Add_Click(({
        $state.Canceled = $true
        $cancel.Enabled = $false
        $label.Text = 'Cancelando com segurança...'
    }).GetNewClosure())
    $ownerWasEnabled = $false
    if ($script:MainForm) {
        $ownerWasEnabled = $script:MainForm.Enabled
        $script:MainForm.Enabled = $false
        $window.Show($script:MainForm)
    } else { $window.Show() }
    [Windows.Forms.Application]::DoEvents()
    return [pscustomobject]@{ Window = $window; Label = $label; State = $state; OwnerWasEnabled = $ownerWasEnabled }
}

function Close-BusyWindow {
    param($Busy)
    if ($Busy -and $Busy.Window) {
        $Busy.Window.Close()
        $Busy.Window.Dispose()
        if ($Busy.OwnerWasEnabled -and $script:MainForm -and -not $script:MainForm.IsDisposed) {
            $script:MainForm.Enabled = $true
            $script:MainForm.Activate()
        }
    }
}

function New-RcloneStartInfo {
    param([string[]]$Arguments, [switch]$NoAppConfig, [switch]$UseConfigPassword)
    $allArguments = @($Arguments)
    if (-not $NoAppConfig) {
        $allArguments += @('--config', $script:RcloneConfigFile, '--cache-dir', $script:CacheDir)
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:RclonePath
    $psi.Arguments = Join-Arguments $allArguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    if ((-not $NoAppConfig -or $UseConfigPassword) -and $script:ConfigPassword) {
        $psi.EnvironmentVariables['RCLONE_CONFIG_PASS'] = $script:ConfigPassword
    }
    return $psi
}

function Invoke-RcloneProcess {
    param(
        [string[]]$Arguments,
        [string]$Message = '',
        [switch]$NoAppConfig,
        [switch]$UseConfigPassword,
        [int]$TimeoutSeconds = 120
    )
    $psi = New-RcloneStartInfo -Arguments $Arguments -NoAppConfig:$NoAppConfig -UseConfigPassword:$UseConfigPassword
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    $busy = $null
    try {
        Enter-AppBusy
        if ($Message -and -not $AutoMount) { $busy = New-BusyWindow $Message $true }
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $started = Get-Date
        while (-not $process.HasExited) {
            if ($busy -and $busy.State.Canceled) {
                $process.Kill()
                return [pscustomobject]@{ ExitCode = 1223; Output = ''; ErrorText = 'Operação cancelada.'; Canceled = $true }
            }
            if (((Get-Date) - $started).TotalSeconds -ge $TimeoutSeconds) {
                $process.Kill()
                return [pscustomobject]@{ ExitCode = 1460; Output = ''; ErrorText = 'A operação demorou mais que o esperado.'; Canceled = $false }
            }
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 70
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdoutTask.GetAwaiter().GetResult()
            ErrorText = $stderrTask.GetAwaiter().GetResult()
            Canceled = $false
        }
    } finally {
        Close-BusyWindow $busy
        Exit-AppBusy
        $process.Dispose()
    }
}

function Set-InitialConfigEncryption {
    $touch = Invoke-RcloneProcess -Arguments @('config', 'touch', '--config', $script:RcloneConfigFile) -NoAppConfig -TimeoutSeconds 20
    if ($touch.ExitCode -ne 0) { throw $touch.ErrorText }

    $psi = New-RcloneStartInfo -Arguments @('config', 'encryption', 'set', '--config', $script:RcloneConfigFile) -NoAppConfig
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine($script:ConfigPassword)
        $process.StandardInput.WriteLine($script:ConfigPassword)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Não foi possível proteger a configuração local.' }
        if ($process.ExitCode -ne 0) { throw $stderrTask.GetAwaiter().GetResult() }
        $null = $stdoutTask.GetAwaiter().GetResult()
    } finally { $process.Dispose() }
    Set-PrivatePathAcl $script:RcloneConfigFile
}

function Assert-RcloneConfigEncryption {
    param([string]$Path)
    if (-not (Test-ConfigFileEncryptedPrefix $Path)) {
        throw ('A configuração {0} ainda não está criptografada.' -f (Split-Path -Leaf $Path))
    }
    $check = Invoke-RcloneProcess -Arguments @('config', 'encryption', 'check', '--config', $Path) -NoAppConfig -UseConfigPassword -TimeoutSeconds 20
    if ($check.ExitCode -ne 0) {
        throw ('A configuração protegida {0} não pôde ser aberta: {1}' -f (Split-Path -Leaf $Path), (Protect-LogMessage $check.ErrorText))
    }
}

function Save-AppConfigBackup {
    if (-not (Test-Path -LiteralPath $script:RcloneConfigFile -PathType Leaf)) { return }
    Assert-RcloneConfigEncryption $script:RcloneConfigFile
    $configText = [IO.File]::ReadAllText($script:RcloneConfigFile, [Text.Encoding]::UTF8)
    Write-AtomicText ($script:RcloneConfigFile + '.bak') $configText
}

function Initialize-AppConfigEncryption {
    $primary = $script:RcloneConfigFile
    $backup = $script:RcloneConfigFile + '.bak'

    if (Test-Path -LiteralPath $primary -PathType Leaf) {
        if (Test-ConfigFileEncryptedPrefix $primary) {
            try {
                Assert-RcloneConfigEncryption $primary
                Save-AppConfigBackup
                return
            } catch {
                Write-AppLog 'WARN' ('A configuração principal não abriu; tentando a cópia de segurança: ' + $_.Exception.Message)
                if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw }
                Assert-RcloneConfigEncryption $backup
                $backupText = [IO.File]::ReadAllText($backup, [Text.Encoding]::UTF8)
                Write-AtomicText $primary $backupText
                Assert-RcloneConfigEncryption $primary
                Save-AppConfigBackup
                Write-AppLog 'WARN' 'A configuração do rclone foi restaurada da cópia de segurança.'
                return
            }
        }

        # An interrupted first run can leave the file created by `config touch`
        # but still plain. Encrypt it before any token or remote is written.
        Set-InitialConfigEncryption
        Assert-RcloneConfigEncryption $primary
        Save-AppConfigBackup
        Write-AppLog 'INFO' 'A configuração local existente foi protegida antes do uso.'
        return
    }

    if (Test-Path -LiteralPath $backup -PathType Leaf) {
        $backupText = [IO.File]::ReadAllText($backup, [Text.Encoding]::UTF8)
        Write-AtomicText $primary $backupText
        if (-not (Test-ConfigFileEncryptedPrefix $primary)) { Set-InitialConfigEncryption }
        Assert-RcloneConfigEncryption $primary
        Save-AppConfigBackup
        Write-AppLog 'WARN' 'A configuração ausente foi restaurada da cópia de segurança.'
        return
    }

    Set-InitialConfigEncryption
    Assert-RcloneConfigEncryption $primary
    Save-AppConfigBackup
}

function Get-FreeTcpPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally { $listener.Stop() }
}

function Get-ControllerAuthorizationHeader {
    param($Controller)
    $pair = '{0}:{1}' -f $Controller.user, $Controller.password
    return 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
}

function Get-ConfigPasswordFingerprint {
    if ([string]::IsNullOrWhiteSpace($script:ConfigPassword)) { return '' }
    $canonicalConfig = [IO.Path]::GetFullPath($script:RcloneConfigFile).ToUpperInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes($script:ConfigPassword + "`n" + $canonicalConfig)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '')
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $sha256.Dispose()
    }
}

function Invoke-ControllerRequest {
    param(
        [string]$Endpoint,
        [object]$Body = @{},
        $Controller = $script:Controller,
        [int]$TimeoutSeconds = 30
    )
    if (-not $Controller) { throw 'O serviço local não está disponível.' }
    $endpointPath = $Endpoint.TrimStart('/')
    $uri = 'http://127.0.0.1:{0}/{1}/{2}' -f $Controller.port, $Controller.baseUrl, $endpointPath
    $json = $Body | ConvertTo-Json -Compress -Depth 12
    $handler = $null
    $client = $null
    $request = $null
    $response = $null
    try {
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $client = New-Object Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Post, $uri)
        [void]$request.Headers.TryAddWithoutValidation('Authorization', (Get-ControllerAuthorizationHeader $Controller))
        $request.Content = New-Object Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $responseText = [Text.Encoding]::UTF8.GetString($bytes)
        if (-not $response.IsSuccessStatusCode) {
            $detail = 'O serviço local recusou a operação solicitada.'
            if ($responseText) {
                try {
                    $responseData = $responseText | ConvertFrom-Json
                    if ($responseData.error) { $detail = [string]$responseData.error }
                } catch {}
            }
            throw $detail
        }
        if ([string]::IsNullOrWhiteSpace($responseText)) { return [pscustomobject]@{} }
        try { return ($responseText | ConvertFrom-Json) }
        catch { throw 'O serviço local retornou uma resposta inválida.' }
    } catch {
        throw (Protect-LogMessage $_.Exception.Message)
    } finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

function Read-ControllerState {
    param([string]$Path = $script:ControllerFile)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ([int]$saved.pid -le 0) { throw 'PID inválido.' }
        if ([int]$saved.port -lt 1024 -or [int]$saved.port -gt 65535) { return $null }
        if ([string]$saved.baseUrl -notmatch '^spf-[a-f0-9]{32}$') { return $null }
        $password = Unprotect-LocalSecret ([string]$saved.secret)
        if ([string]::IsNullOrWhiteSpace($password)) { throw 'Credencial RC vazia.' }
        $expectedConfigPath = [IO.Path]::GetFullPath($script:RcloneConfigFile)
        $savedConfigPath = [string]$saved.configPath
        $expectedFingerprint = Get-ConfigPasswordFingerprint
        $compatible = (
            [int]$saved.version -ge 2 -and
            -not [string]::IsNullOrWhiteSpace($savedConfigPath) -and
            [IO.Path]::GetFullPath($savedConfigPath).Equals($expectedConfigPath, [StringComparison]::OrdinalIgnoreCase) -and
            [string]$saved.configFingerprint -eq $expectedFingerprint
        )
        return [pscustomobject]@{
            pid = [int]$saved.pid
            port = [int]$saved.port
            user = 'spf'
            baseUrl = [string]$saved.baseUrl
            password = $password
            sourcePath = $Path
            compatible = [bool]$compatible
        }
    } catch {
        Write-AppLog 'WARN' ('Estado do serviço local inválido em {0}: {1}' -f (Split-Path -Leaf $Path), $_.Exception.Message)
        return $null
    }
}

function Save-ControllerState {
    param($Controller)
    $data = [ordered]@{
        version = 2
        pid = [int]$Controller.pid
        port = [int]$Controller.port
        baseUrl = [string]$Controller.baseUrl
        configPath = [IO.Path]::GetFullPath($script:RcloneConfigFile)
        configFingerprint = Get-ConfigPasswordFingerprint
        secret = Protect-LocalSecret ([string]$Controller.password)
    }
    Write-AtomicText $script:ControllerFile ($data | ConvertTo-Json -Depth 4)
}

function Stop-IncompatibleControllerIfIdle {
    param($Controller)
    if (-not (Test-ControllerWithRetry $Controller)) {
        if (Test-SavedControllerProcessAlive $Controller) {
            throw 'O serviço anterior está em execução, mas não respondeu. Reinicie o Windows antes de tentar novamente.'
        }
        return $true
    }

    try {
        $mounts = Invoke-ControllerRequest 'mount/listmounts' @{} $Controller 5
    } catch {
        throw 'Não foi possível confirmar se o serviço anterior ainda mantém alguma unidade. Reinicie o Windows antes de tentar novamente.'
    }
    if (@($mounts.mountPoints).Count -gt 0) {
        throw 'Uma unidade ainda está ligada a uma sessão anterior. Reinicie o Windows para protegê-la antes de criar outra conexão.'
    }

    $oldPid = [int]$Controller.pid
    try { $null = Invoke-ControllerRequest 'core/quit' @{} $Controller 3 } catch {}
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 100
    }
    if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
        throw 'O serviço anterior não pôde ser encerrado com segurança. Reinicie o Windows antes de tentar novamente.'
    }
    Write-AppLog 'WARN' 'Um controlador antigo e incompatível foi encerrado antes de abrir a configuração atual.'
    return $true
}

function Test-Controller {
    param($Controller)
    if (-not $Controller) { return $false }
    try {
        $reply = Invoke-ControllerRequest -Endpoint 'core/version' -Body @{} -Controller $Controller -TimeoutSeconds 2
        $match = [regex]::Match([string]$reply.version, '^v?(\d+)\.(\d+)')
        return $match.Success -and [int]$match.Groups[1].Value -eq 1 -and [int]$match.Groups[2].Value -ge 65
    } catch { return $false }
}

function Test-ControllerWithRetry {
    param($Controller, [int]$Attempts = 3)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (Test-Controller $Controller) { return $true }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds (200 * $attempt) }
    }
    return $false
}

function Test-SavedControllerProcessAlive {
    param($Controller)
    $process = Get-Process -Id ([int]$Controller.pid) -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try {
        $processPath = [IO.Path]::GetFullPath([string]$process.Path)
        $expectedPath = [IO.Path]::GetFullPath($script:RclonePath)
        if ($processPath) { return $processPath -eq $expectedPath }
    } catch {
        # If Windows does not let us inspect the process, fail closed rather
        # than starting a second controller over the same cache.
        return $true
    }
    return $true
}

function Start-Controller {
    if ($script:Controller -and (Test-ControllerWithRetry $script:Controller)) { return $script:Controller }

    $statePaths = @($script:ControllerFile, ($script:ControllerFile + '.bak'))
    $hasStateFile = @($statePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0
    $savedStates = @()
    foreach ($statePath in $statePaths) {
        $saved = Read-ControllerState $statePath
        if ($saved) { $savedStates += $saved }
    }
    foreach ($saved in $savedStates) {
        if (-not $saved.compatible) {
            if (Stop-IncompatibleControllerIfIdle $saved) {
                Remove-Item -LiteralPath $saved.sourcePath -Force -ErrorAction SilentlyContinue
            }
            continue
        }
        if (Test-ControllerWithRetry $saved) {
            $script:Controller = $saved
            if ($saved.sourcePath -ne $script:ControllerFile) {
                Save-ControllerState $saved
                Write-AppLog 'WARN' 'O controle das unidades foi restaurado da cópia de segurança.'
            }
            return $script:Controller
        }
        if (Test-SavedControllerProcessAlive $saved) {
            throw 'O serviço que mantém as unidades está em execução, mas não respondeu. As credenciais de controle foram preservadas; reinicie o Windows antes de tentar novamente.'
        }
    }
    if ($hasStateFile -and $savedStates.Count -eq 0) {
        throw 'O estado do serviço local está inválido e foi preservado para recuperação. Reinicie o Windows antes de tentar novamente.'
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $port = Get-FreeTcpPort
        $password = New-RandomSecret
        $baseUrl = 'spf-' + ([Guid]::NewGuid().ToString('N'))
        $logFile = Join-Path $script:LogDir 'rclone-controller.log'
        $arguments = @(
            'rcd',
            '--rc-addr', ('127.0.0.1:' + $port),
            '--rc-baseurl', $baseUrl,
            '--rc-server-read-timeout', '2m',
            '--rc-server-write-timeout', '2m',
            '--log-file', $logFile,
            '--log-level', 'NOTICE',
            '--log-file-max-size', '5M',
            '--log-file-max-backups', '3',
            '--log-file-max-age', '14d'
        )
        $psi = New-RcloneStartInfo -Arguments $arguments
        $psi.EnvironmentVariables['RCLONE_RC_USER'] = 'spf'
        $psi.EnvironmentVariables['RCLONE_RC_PASS'] = $password
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $psi
        try {
            [void]$process.Start()
            $candidate = [pscustomobject]@{
                pid = $process.Id
                port = $port
                user = 'spf'
                baseUrl = $baseUrl
                password = $password
            }
            $started = Get-Date
            do {
                if ($process.HasExited) { break }
                if (Test-Controller $candidate) {
                    $script:Controller = $candidate
                    Save-ControllerState $candidate
                    return $script:Controller
                }
                [Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 120
            } while (((Get-Date) - $started).TotalSeconds -lt 8)
            if (-not $process.HasExited) { $process.Kill() }
        } finally { $process.Dispose() }
    }
    throw 'O serviço local de unidades não pôde ser iniciado.'
}

function Stop-ControllerIfIdle {
    if (-not $script:Controller) { return }
    try {
        $mounts = Invoke-ControllerRequest 'mount/listmounts'
        if (@($mounts.mountPoints).Count -gt 0) { return }
    } catch {
        Write-AppLog 'WARN' ('O estado RC foi preservado porque não foi possível confirmar que o serviço está ocioso: ' + $_.Exception.Message)
        return
    }

    $controllerPid = [int]$script:Controller.pid
    try { $null = Invoke-ControllerRequest 'core/quit' -TimeoutSeconds 3 }
    catch { Write-AppLog 'WARN' ('O encerramento do serviço local não foi confirmado: ' + $_.Exception.Message) }
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline -and (Get-Process -Id $controllerPid -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 100
    }
    if (Get-Process -Id $controllerPid -ErrorAction SilentlyContinue) {
        Write-AppLog 'WARN' 'O serviço local continuou em execução; o estado RC foi preservado.'
        return
    }
    $script:Controller = $null
    Remove-Item -LiteralPath $script:ControllerFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($script:ControllerFile + '.bak') -Force -ErrorAction SilentlyContinue
}

function Get-LegacyConfigDump {
    try {
        $result = Invoke-RcloneProcess -Arguments @('config', 'dump') -NoAppConfig -TimeoutSeconds 20
        if ($result.ExitCode -eq 0 -and $result.Output) { return ($result.Output | ConvertFrom-Json) }
    } catch {}
    return $null
}

function Get-AppRemoteConfigurationAnswer {
    param($Reply, [hashtable]$Parameters)
    $optionName = if ($Reply -and $Reply.Option) { [string]$Reply.Option.Name } else { '' }
    switch ($optionName) {
        # The app already obtained a valid delegated token in its single,
        # user-visible authorization flow. Replacing it here would open a
        # second browser tab and let rclone choose the personal OneDrive.
        'config_refresh_token' { return 'false' }
        # Use the exact SharePoint drive selected from Microsoft Graph.
        'config_type' { return 'driveid' }
        'config_driveid_fixed' { return [string]$Parameters.drive_id }
        'config_driveid' { return [string]$Parameters.drive_id }
        'config_drive_ok' { return 'true' }
        default {
            $detail = if ($Reply -and $Reply.Error) { ' ' + [string]$Reply.Error } else { '' }
            throw ('O rclone pediu uma etapa de configuração não reconhecida ({0}).{1}' -f $optionName, $detail)
        }
    }
}

function Invoke-AppRemoteConfiguration {
    param(
        [ValidateSet('create', 'update')][string]$Action,
        [string]$Name,
        [hashtable]$Parameters,
        [string]$Type = 'onedrive'
    )
    $controller = Start-Controller
    $body = [ordered]@{
        name = $Name
        parameters = $Parameters
        opt = @{ nonInteractive = $true }
    }
    if ($Action -eq 'create') { $body.type = $Type }

    $reply = Invoke-ControllerRequest ('config/' + $Action) $body $controller 45
    for ($step = 0; $step -lt 8 -and $reply -and -not [string]::IsNullOrWhiteSpace([string]$reply.State); $step++) {
        if ($reply.Error) { throw [string]$reply.Error }
        $answer = Get-AppRemoteConfigurationAnswer $reply $Parameters
        $reply = Invoke-ControllerRequest 'config/update' ([ordered]@{
            name = $Name
            parameters = $Parameters
            opt = @{
                nonInteractive = $true
                continue = $true
                state = [string]$reply.State
                result = [string]$answer
            }
        }) $controller 45
    }
    if ($reply -and $reply.Error) { throw [string]$reply.Error }
    if ($reply -and -not [string]::IsNullOrWhiteSpace([string]$reply.State)) {
        throw 'O rclone não concluiu a configuração da biblioteca no número esperado de etapas.'
    }

    if ($Type -eq 'onedrive' -and $Parameters.drive_id) {
        $config = Get-AppConfigDump
        $remote = $config.PSObject.Properties[$Name]
        if (-not $remote -or [string]$remote.Value.drive_id -ne [string]$Parameters.drive_id -or [string]$remote.Value.drive_type -ne 'documentLibrary') {
            throw 'O destino salvo pelo rclone não corresponde à biblioteca SharePoint selecionada.'
        }
    }
    Save-AppConfigBackup
}

function New-AppRemote {
    param([string]$Name, [hashtable]$Parameters, [string]$Type = 'onedrive')
    Invoke-AppRemoteConfiguration -Action create -Name $Name -Parameters $Parameters -Type $Type
}

function Remove-AppRemote {
    param([string]$Name)
    $null = Start-Controller
    $null = Invoke-ControllerRequest 'config/delete' @{ name = $Name }
    Save-AppConfigBackup
}

function Get-AppConfigDump {
    $null = Start-Controller
    $reply = Invoke-ControllerRequest 'config/dump' @{}
    if ($null -eq $reply) { return [pscustomobject]@{} }
    return $reply
}

function Import-LegacyRemotes {
    param($LegacyConfig)
    if (-not $LegacyConfig) { return }
    foreach ($profile in $script:Profiles) {
        $sourceProperty = $LegacyConfig.PSObject.Properties[[string]$profile.remote]
        if (-not $sourceProperty -or $sourceProperty.Value.type -ne 'onedrive') { continue }
        try {
            $parameters = @{}
            foreach ($property in $sourceProperty.Value.PSObject.Properties) {
                if ($property.Name -ne 'type' -and $null -ne $property.Value) {
                    $parameters[$property.Name] = [string]$property.Value
                }
            }
            New-AppRemote -Name ([string]$profile.remote) -Parameters $parameters
        } catch {
            Write-AppLog 'ERROR' ('Falha ao migrar {0}: {1}' -f $profile.remote, $_.Exception.Message)
        }
    }
}

function Import-LegacyAuthorization {
    param($LegacyConfig)
    if (-not $LegacyConfig) { return }
    try {
        $current = Get-AppConfigDump
        if ($current.PSObject.Properties['_spf-auth']) { return }
        $candidates = @()
        foreach ($property in $LegacyConfig.PSObject.Properties) {
            $value = $property.Value
            if ($value.type -ne 'onedrive' -or $value.drive_type -ne 'documentLibrary' -or -not $value.token -or -not $value.drive_id) { continue }
            $expiry = [DateTimeOffset]::MinValue
            try {
                $tokenData = [string]$value.token | ConvertFrom-Json
                $parsedExpiry = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$tokenData.expiry, [ref]$parsedExpiry)) { $expiry = $parsedExpiry }
            } catch {}
            $candidates += [pscustomobject]@{ Config = $value; Expiry = $expiry }
        }
        $selected = @($candidates | Sort-Object Expiry -Descending | Select-Object -First 1)
        if ($selected.Count -eq 0) { return }
        $parameters = @{}
        foreach ($property in $selected[0].Config.PSObject.Properties) {
            if ($property.Name -ne 'type' -and $null -ne $property.Value) {
                $parameters[$property.Name] = [string]$property.Value
            }
        }
        New-AppRemote '_spf-auth' $parameters
        Write-AppLog 'INFO' 'A autorização Microsoft existente foi migrada para a configuração privada do aplicativo.'
    } catch {
        Write-AppLog 'WARN' ('A autorização anterior não pôde ser reutilizada: ' + $_.Exception.Message)
    }
}

function Import-LegacyAuthorizationIfNeeded {
    try {
        $current = Get-AppConfigDump
        $authorization = $current.PSObject.Properties['_spf-auth']
        if ($authorization -and $authorization.Value.token) { return }
        Import-LegacyAuthorization (Get-LegacyConfigDump)
    } catch {}
}

function ConvertTo-SafeProfile {
    param($Source, [hashtable]$SeenDrives)
    $remote = [string]$Source.remote
    $drive = ([string]$Source.drive).Trim().TrimEnd(':').ToUpperInvariant()
    $label = ([string]$Source.label).Trim()
    if ($remote.Length -lt 1 -or $remote.Length -gt 100 -or $remote -match '[:\x00-\x1F]') { return $null }
    if ($drive -notmatch '^[D-Z]$' -or $SeenDrives.ContainsKey($drive)) { return $null }
    if ($label.Length -lt 1) { $label = $remote }
    if ($label.Length -gt 64) { $label = $label.Substring(0, 64) }
    $label = $label -replace '[\\/:*?"<>|\x00-\x1F]', '-'
    $id = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$Source.id, [ref]$id)) { $id = [Guid]::NewGuid() }
    $SeenDrives[$drive] = $true
    return [pscustomobject]@{
        id = $id.ToString('N')
        remote = $remote
        drive = $drive
        label = $label
        autoMount = [bool]$Source.autoMount
        siteName = [string]$Source.siteName
        libraryName = [string]$Source.libraryName
        webUrl = [string]$Source.webUrl
        driveId = [string]$Source.driveId
    }
}

function Read-SafeSettingsFile {
    param([string]$Path)
    $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $saved -or -not $saved.PSObject.Properties['profiles']) {
        throw 'O arquivo não contém a lista de unidades esperada.'
    }
    $sourceProfiles = @($saved.profiles)
    $safeProfiles = @()
    $seen = @{}
    foreach ($profile in $sourceProfiles) {
        $safe = ConvertTo-SafeProfile $profile $seen
        if (-not $safe) { throw 'O arquivo contém uma unidade inválida ou repetida.' }
        $safeProfiles += $safe
    }
    return [pscustomobject]@{ Profiles = @($safeProfiles) }
}

function Load-Settings {
    $script:Profiles = @()
    $sourcePath = $script:SettingsFile
    if (-not (Test-Path -LiteralPath $sourcePath) -and -not (Test-Path -LiteralPath ($sourcePath + '.bak')) -and (Test-Path -LiteralPath $script:LegacySettingsFile)) {
        $sourcePath = $script:LegacySettingsFile
    }
    $candidates = @($sourcePath, ($sourcePath + '.bak')) | Select-Object -Unique
    if (@($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 0) { return }

    $failures = @()
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $loaded = Read-SafeSettingsFile $candidate
            $script:Profiles = @($loaded.Profiles)
            if ($candidate -ne $sourcePath) {
                if ($sourcePath -eq $script:SettingsFile -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    $corruptCopy = $sourcePath + '.corrompido-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                    Copy-Item -LiteralPath $sourcePath -Destination $corruptCopy -Force -ErrorAction SilentlyContinue
                }
                if ($sourcePath -eq $script:SettingsFile) {
                    Write-AtomicText $script:SettingsFile ([IO.File]::ReadAllText($candidate, [Text.Encoding]::UTF8))
                }
                Write-AppLog 'WARN' 'As unidades foram restauradas da cópia de segurança das configurações.'
            }
            return
        } catch {
            $failures += ('{0}: {1}' -f (Split-Path -Leaf $candidate), $_.Exception.Message)
        }
    }
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        $corruptCopy = $sourcePath + '.corrompido-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $sourcePath -Destination $corruptCopy -Force -ErrorAction SilentlyContinue
    }
    Write-AppLog 'ERROR' ('Nenhuma cópia válida das configurações foi encontrada. ' + ($failures -join ' | '))
    throw 'As configurações das unidades e sua cópia de segurança estão inválidas. Nenhuma alteração foi gravada.'
}

function Save-Settings {
    $data = [ordered]@{
        version = 2
        profiles = @($script:Profiles)
    }
    Write-AtomicText $script:SettingsFile ($data | ConvertTo-Json -Depth 6)
    Update-StartupShortcut
}

function Initialize-AppConfig {
    $script:ConfigPassword = Get-OrCreateConfigPassword
    $needsLegacyImport = -not (Test-Path -LiteralPath $script:RcloneConfigFile -PathType Leaf)
    if (-not $needsLegacyImport -and -not (Test-ConfigFileEncryptedPrefix $script:RcloneConfigFile)) {
        try { $needsLegacyImport = [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($script:RcloneConfigFile)) }
        catch { $needsLegacyImport = $false }
    }
    $legacy = if ($needsLegacyImport) { Get-LegacyConfigDump } else { $null }
    Initialize-AppConfigEncryption
    if ($legacy) { Import-LegacyRemotes $legacy }
    if (-not $SelfTest) {
        if ($legacy) { Import-LegacyAuthorization $legacy }
        else { Import-LegacyAuthorizationIfNeeded }
    }
    Set-PrivatePathAcl $script:RcloneConfigFile
}

function Get-OAuthTokenFromOutput {
    param([string]$Output)
    $lines = @($Output -split '[\r\n]+')
    [Array]::Reverse($lines)
    foreach ($line in $lines) {
        $candidate = $line.Trim()
        if ($candidate.StartsWith('{') -and $candidate.EndsWith('}')) {
            try {
                $data = $candidate | ConvertFrom-Json
                if ($data.access_token) { return [pscustomobject]@{ Json = $candidate; Data = $data } }
            } catch {}
        }
    }
    return $null
}

function Get-TokenAccountName {
    param([string]$AccessToken)
    try {
        $parts = $AccessToken.Split('.')
        if ($parts.Count -lt 2) { return '' }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        while (($payload.Length % 4) -ne 0) { $payload += '=' }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        foreach ($name in @('preferred_username', 'upn', 'email', 'name')) {
            if ($claims.$name) { return [string]$claims.$name }
        }
    } catch {}
    return ''
}

function Request-MicrosoftAuthorization {
    $result = Invoke-RcloneProcess -Arguments @('authorize', 'onedrive') -Message 'Entre com sua conta Microsoft no navegador para liberar o acesso às bibliotecas.' -TimeoutSeconds 300
    if ($result.Canceled) { return $null }
    if ($result.ExitCode -ne 0) { throw $result.ErrorText }
    $oauth = Get-OAuthTokenFromOutput $result.Output
    if (-not $oauth) { throw 'A Microsoft não devolveu a autorização necessária.' }
    return $oauth
}

function Get-CachedOAuthToken {
    try {
        $config = Get-AppConfigDump
        $names = @()
        foreach ($preferred in @('_spf-auth') + @($script:Profiles | ForEach-Object { $_.remote })) {
            if ($preferred -and $names -notcontains $preferred) { $names += $preferred }
        }
        foreach ($name in $names) {
            $property = $config.PSObject.Properties[$name]
            if (-not $property -or -not $property.Value.token) { continue }
            try {
                $tokenData = [string]$property.Value.token | ConvertFrom-Json
                $expiry = [DateTimeOffset]::MinValue
                $validExpiry = [DateTimeOffset]::TryParse([string]$tokenData.expiry, [ref]$expiry)
                if ($tokenData.access_token -and $validExpiry -and $expiry -gt [DateTimeOffset]::Now.AddMinutes(3)) {
                    return [pscustomobject]@{ Json = [string]$property.Value.token; Data = $tokenData }
                }
                $null = Invoke-ControllerRequest 'operations/list' @{
                    fs = ($name + ':')
                    remote = ''
                    opt = @{ dirsOnly = $true; noModTime = $true }
                } $script:Controller 30
                $updated = Get-AppConfigDump
                $updatedProperty = $updated.PSObject.Properties[$name]
                if ($updatedProperty -and $updatedProperty.Value.token) {
                    $updatedData = [string]$updatedProperty.Value.token | ConvertFrom-Json
                    if ($updatedData.access_token) {
                        Save-AppConfigBackup
                        return [pscustomobject]@{ Json = [string]$updatedProperty.Value.token; Data = $updatedData }
                    }
                }
            } catch {}
        }
    } catch {}
    return $null
}

function New-GraphBusyWindow {
    param([string]$Message)
    if ($AutoMount) { return $null }
    return New-BusyWindow $Message $true
}

function Wait-UiTask {
    param([Threading.Tasks.Task]$Task, $Busy, [int]$TimeoutSeconds = 35)
    $started = Get-Date
    while (-not $Task.IsCompleted) {
        if ($Busy -and $Busy.State.Canceled) { throw (New-Object OperationCanceledException('Operação cancelada.')) }
        if (((Get-Date) - $started).TotalSeconds -ge $TimeoutSeconds) { throw (New-Object TimeoutException('A Microsoft demorou mais que o esperado para responder.')) }
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
    }
    return $Task.GetAwaiter().GetResult()
}

function Invoke-GraphGet {
    param([string]$Uri, [string]$AccessToken, $Busy)
    $parsed = [Uri]$Uri
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com') {
        throw 'A paginação da Microsoft retornou um endereço inválido.'
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $client = New-Object Net.Http.HttpClient
        $client.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $AccessToken)
        try {
            $response = Wait-UiTask ($client.GetAsync($parsed)) $Busy 35
            $content = Wait-UiTask ($response.Content.ReadAsStringAsync()) $Busy 15
            if ($response.IsSuccessStatusCode) { return ($content | ConvertFrom-Json) }
            $status = [int]$response.StatusCode
            if ($status -eq 401) { throw (New-Object UnauthorizedAccessException('A autorização Microsoft precisa ser renovada.')) }
            if ($status -eq 403) { throw (New-Object Security.SecurityException('A conta não tem permissão para consultar este conteúdo.')) }
            if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 3) {
                $delayUntil = (Get-Date).AddSeconds([Math]::Pow(2, $attempt - 1))
                while ((Get-Date) -lt $delayUntil) {
                    if ($Busy -and $Busy.State.Canceled) { throw (New-Object OperationCanceledException('Operação cancelada.')) }
                    [Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 80
                }
                continue
            }
            throw ('A Microsoft respondeu com o código {0}.' -f $status)
        } finally { $client.Dispose() }
    }
}

function Invoke-GraphPaged {
    param([string]$Uri, [string]$AccessToken, $Busy)
    $items = @()
    $next = $Uri
    while ($next) {
        $response = Invoke-GraphGet $next $AccessToken $Busy
        $items += @($response.value)
        $next = [string]$response.'@odata.nextLink'
    }
    return @($items)
}

function Get-AccessibleLibraries {
    param($OAuth)
    $busy = New-GraphBusyWindow 'Localizando os sites e bibliotecas disponíveis para sua conta...'
    try {
        $sites = @(Invoke-GraphPaged 'https://graph.microsoft.com/v1.0/sites?search=*' $OAuth.Data.access_token $busy |
            Where-Object { $_.webUrl -and $_.webUrl -notmatch '/contentstorage/' -and $_.name -ne 'contentTypeHub' } |
            Sort-Object id -Unique |
            Sort-Object displayName)
        if ($sites.Count -eq 0) { return @() }
        $libraries = @()
        for ($index = 0; $index -lt $sites.Count; $index++) {
            if ($busy) {
                $busy.Label.Text = 'Localizando bibliotecas: {0} de {1}' -f ($index + 1), $sites.Count
                [Windows.Forms.Application]::DoEvents()
            }
            $site = $sites[$index]
            try {
                $siteId = [Uri]::EscapeDataString([string]$site.id)
                $drives = @(Invoke-GraphPaged ('https://graph.microsoft.com/v1.0/sites/{0}/drives' -f $siteId) $OAuth.Data.access_token $busy)
                $siteTitle = if ($site.displayName) { [string]$site.displayName } else { [string]$site.name }
                $sitePath = ([Uri]$site.webUrl).AbsolutePath.TrimEnd('/')
                if (-not $sitePath) { $sitePath = '/' }
                foreach ($drive in $drives) {
                    if (-not $drive.id -or -not $drive.webUrl) { continue }
                    $libraries += [pscustomobject]@{
                        DriveId = [string]$drive.id
                        SiteName = $siteTitle
                        LibraryName = [string]$drive.name
                        WebUrl = [string]$drive.webUrl
                        Display = ('{0}  ·  {1}   —   {2}' -f $siteTitle, $drive.name, $sitePath)
                    }
                }
            } catch [UnauthorizedAccessException] { throw }
            catch [Security.SecurityException] { Write-AppLog 'WARN' ('Site sem permissão para listar bibliotecas: ' + $site.webUrl) }
            catch { Write-AppLog 'WARN' ('Bibliotecas omitidas em {0}: {1}' -f $site.webUrl, $_.Exception.Message) }
        }
        $mappedIds = @($script:Profiles | Where-Object { $_.driveId } | ForEach-Object { $_.driveId })
        return @($libraries | Where-Object { $mappedIds -notcontains $_.DriveId } | Sort-Object DriveId -Unique | Sort-Object Display)
    } finally { Close-BusyWindow $busy }
}

function Get-DocumentTarget {
    param([string]$Path)
    # Resolve lexically: never follow a local link or guess a SharePoint URL.
    if ($Path -notmatch '^[D-Zd-z]:\\' -or $Path -match '[\x00-\x1f<>"|?*]' -or $Path.Substring(2).Contains(':')) {
        throw 'Selecione um caminho absoluto de uma unidade do SharePoint Fácil.'
    }
    if (@($Path.Substring(3).Split('\') | Where-Object { $_ -in @('.', '..') -or $_ -match '[. ]$' }).Count -gt 0) {
        throw 'O caminho contém um segmento ambíguo.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $profiles = @($script:Profiles | Where-Object { $_.drive -eq $full.Substring(0, 1) })
    if ($profiles.Count -ne 1) { throw 'Este caminho não pertence a uma unidade do SharePoint Fácil.' }
    $relative = $full.Substring(3).TrimEnd('\')
    $encoded = (@($relative.Split('\') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    $base = 'https://graph.microsoft.com/v1.0/drives/' + [Uri]::EscapeDataString([string]$profiles[0].driveId)
    $uri = if ($relative) { $base + '/root:/' + $encoded } else { $base + '/root' }
    return [pscustomobject]@{ Profile = $profiles[0]; Relative = $relative; Uri = $uri }
}

function Get-ProfileAccessToken {
    param($Profile)
    Assert-ProfileRemoteTarget $Profile
    # Refresh through this exact remote. Never borrow _spf-auth or another account.
    $null = Invoke-ControllerRequest 'operations/list' @{ fs = ($Profile.remote + ':'); remote = ''; opt = @{ dirsOnly = $true; noModTime = $true } } $script:Controller 35
    $config = Get-AppConfigDump
    $remote = $config.PSObject.Properties[[string]$Profile.remote]
    if ($remote.Value.root_folder_id) { throw 'Este mapeamento usa uma subpasta técnica. Reconecte a biblioteca pela seleção de bibliotecas antes de usar os comandos de documentos.' }
    $token = [string]$remote.Value.token | ConvertFrom-Json
    if (-not $token.access_token) { throw 'Renove a conexão Microsoft desta biblioteca.' }
    return [string]$token.access_token
}

function Get-DocumentItemUri {
    param($Profile, [string]$ItemId)
    return 'https://graph.microsoft.com/v1.0/drives/' + [Uri]::EscapeDataString([string]$Profile.driveId) + '/items/' + [Uri]::EscapeDataString($ItemId)
}

function Get-DocumentMetadataUri {
    param([string]$Uri)
    if ([string]::IsNullOrWhiteSpace($Uri) -or $Uri.Contains('?')) {
        throw 'Endereço de consulta Microsoft inválido.'
    }
    # The publication facet is not returned by Graph unless it is selected.
    # Checkout ownership cannot be confirmed safely without it.
    return $Uri + '?$select=id,name,webUrl,webDavUrl,file,remoteItem,publication'
}

function Get-TrustedDocumentUrl {
    param($Profile, $Item, [string]$Address = $Item.webUrl)
    $url = [Uri]$Address
    $library = [Uri]$Profile.webUrl
    if (-not $url.IsAbsoluteUri -or $url.Scheme -ne 'https' -or $url.UserInfo -or -not $url.IsDefaultPort -or
        $url.Host -ne $library.Host -or $library.Scheme -ne 'https' -or
        $url.OriginalString -match '[\x00-\x1f"|]' -or $url.Fragment) {
        throw 'O SharePoint não retornou uma URL HTTPS válida para esta biblioteca.'
    }
    if ($Item.remoteItem) { throw 'Atalhos para outra biblioteca devem ser abertos diretamente no SharePoint.' }
    return $url.AbsoluteUri
}

function Get-OfficeDocumentUri {
    param($Profile, $Item)
    $scheme = switch ([IO.Path]::GetExtension([string]$Item.name).ToLowerInvariant()) {
        { $_ -in @('.docx', '.docm', '.doc') } { 'ms-word'; break }
        { $_ -in @('.xlsx', '.xlsm', '.xlsb', '.xls') } { 'ms-excel'; break }
        { $_ -in @('.pptx', '.pptm', '.ppt', '.ppsx', '.ppsm') } { 'ms-powerpoint'; break }
        default { throw 'Use um documento Word, Excel ou PowerPoint, ou escolha Abrir no SharePoint.' }
    }
    if (-not $Item.file) { throw 'Selecione um arquivo Office.' }
    # Office needs the file's own address. webUrl is often the browser viewer
    # (_layouts/15/Doc.aspx?sourcedoc=...), which the desktop apps cannot open.
    $address = if ($Item.webDavUrl) { [string]$Item.webDavUrl } else { [string]$Item.webUrl }
    return $scheme + ':ofe|u|' + (Get-TrustedDocumentUrl $Profile $Item $address)
}

function Open-DocumentUri {
    param([string]$Uri)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Uri
    $info.UseShellExecute = $true
    [void][Diagnostics.Process]::Start($info)
}

function Open-LocalDocument {
    param([string]$Path)
    # Office's own Open verb, never the default verb (which routes back here).
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Path
    $info.Verb = 'Open'
    $info.UseShellExecute = $true
    [void][Diagnostics.Process]::Start($info)
}

function Invoke-GraphDocumentPost {
    param([string]$Uri, [string]$AccessToken, $Body = $null)
    $parsed = [Uri]$Uri
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com' -or $parsed.UserInfo -or -not $parsed.IsDefaultPort) {
        throw 'Endereço de operação Microsoft inválido.'
    }
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object Net.Http.HttpClient($handler)
    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Post, $parsed)
    $response = $null
    try {
        $request.Headers.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $AccessToken)
        if ($null -ne $Body) {
            $request.Content = New-Object Net.Http.StringContent(($Body | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'application/json')
        }
        # Mutations are never retried automatically; a timeout may have committed.
        $response = Wait-UiTask ($client.SendAsync($request)) $null 35
        if ([int]$response.StatusCode -ne 204) {
            throw ('A Microsoft não confirmou a operação (HTTP {0}). Confira a reserva no SharePoint antes de tentar novamente.' -f [int]$response.StatusCode)
        }
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
}

function Read-DocumentReservations {
    $file = Join-Path $script:DataDir 'reservations.json'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    # Never silently recover an older journal: it could release a newer checkout.
    $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if ($data.version -ne 1 -or -not $data.PSObject.Properties['reservations']) { throw 'O registro de reservas está inválido. Consulte o suporte; as reservas no SharePoint foram preservadas.' }
    return @($data.reservations)
}

function Save-DocumentReservations {
    param([object[]]$Reservations)
    Write-AtomicText (Join-Path $script:DataDir 'reservations.json') (@{ version = 1; reservations = @($Reservations) } | ConvertTo-Json -Depth 6)
}

function Assert-DocumentCacheClean {
    param($Profile)
    $mounts = @(Get-ActiveMounts -ThrowOnError)
    $state = Get-ProfileMountState $Profile $mounts
    if ($state -eq 'Conflict') { throw 'Esta letra está sendo usada por outra unidade.' }
    if ($state -eq 'Mounted') {
        $stats = Invoke-ControllerRequest 'vfs/stats' @{ fs = ($Profile.remote + ':') } $script:Controller 8
        if (-not $stats.diskCache -or
            -not $stats.diskCache.PSObject.Properties['uploadsQueued'] -or
            -not $stats.diskCache.PSObject.Properties['uploadsInProgress'] -or
            -not $stats.diskCache.PSObject.Properties['erroredFiles']) {
            throw 'Não foi possível confirmar o estado dos envios desta unidade.'
        }
        if (([int]$stats.diskCache.uploadsQueued + [int]$stats.diskCache.uploadsInProgress + [int]$stats.diskCache.erroredFiles) -gt 0) {
            throw 'Há envios ou erros pendentes nesta unidade. Conclua-os antes de editar online.'
        }
        $cache = Get-ProfileVfsCacheInfo $Profile $stats
    } else {
        $cache = Get-ProfileVfsCacheInfo $Profile
    }
    if ($cache.IsUncertain -or $cache.IsDirty) { throw 'Há alterações locais pendentes ou não verificáveis. Conclua os envios antes de editar online.' }
}

function Assert-OwnedDocumentCheckout {
    param($Item, [string]$UserId)
    if ($Item.publication.level -ne 'checkout' -or -not $UserId -or [string]$Item.publication.checkedOutBy.user.id -ne $UserId) {
        throw 'Não foi possível confirmar sua reserva no SharePoint. A edição foi interrompida; confira o documento no site.'
    }
}

function Invoke-DocumentAction {
    param([string]$Action, [string]$Path, [switch]$ConfirmedSavedAndClosed, [string]$ReservationItemId)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $guard = New-Object Threading.Mutex($false, ('Local\SharePointFacil-Documents-' + $sid))
    $held = $false
    try {
        # A multi-file double-click launches one Auto per file: queue them.
        $wait = if ($Action -eq 'Auto') { 30000 } else { 0 }
        try { $held = $guard.WaitOne($wait) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Outra operação de documento está em andamento. Aguarde e tente novamente.' }
        if ($DocumentAction) { Load-Settings }
        $target = Get-DocumentTarget $Path
        $profile = $target.Profile
        $token = Get-ProfileAccessToken $profile
        $lookupUri = if ($ReservationItemId) { Get-DocumentItemUri $profile $ReservationItemId } else { $target.Uri }
        $item = Invoke-GraphGet (Get-DocumentMetadataUri $lookupUri) $token $null
        $url = Get-TrustedDocumentUrl $profile $item
        if ($Action -eq 'SharePoint') { Open-DocumentUri $url; return 'Aberto no SharePoint.' }
        if ($Action -eq 'Auto') {
            # Local edits not yet uploaded are newer than the server copy.
            Assert-DocumentCacheClean $profile
            # A checked-out item still opens by URL: Office shows the checkout state.
            Open-DocumentUri (Get-OfficeDocumentUri $profile $item)
            return 'Documento aberto no Office pelo SharePoint.'
        }
        if ($Action -notin @('Exclusive', 'Coauthor', 'Finish', 'Reconcile')) { throw 'Ação de documento inválida.' }
        $itemUri = Get-DocumentItemUri $profile ([string]$item.id)
        $entries = @(Read-DocumentReservations)
        $matches = @($entries | Where-Object { $_.driveId -eq $profile.driveId -and $_.itemId -eq $item.id })
        if ($matches.Count -gt 1) { throw 'O registro contém reservas duplicadas. Consulte o suporte.' }
        $entry = if ($matches.Count -eq 1) { $matches[0] } else { $null }
        if ($Action -eq 'Reconcile') {
            if (-not $entry) { throw 'Não há registro local para conferir.' }
            if ($item.publication.level -ne 'published' -or $item.publication.checkedOutBy) {
                throw 'A Microsoft ainda não confirmou o fim da reserva. Confira e conclua a edição no SharePoint.'
            }
            Save-DocumentReservations @($entries | Where-Object { $_ -ne $entry })
            return 'O SharePoint confirmou que não há reserva. O registro local foi encerrado.'
        }
        Assert-DocumentCacheClean $profile
        $officeUri = Get-OfficeDocumentUri $profile $item
        if ($Action -eq 'Coauthor') {
            if ($entry -or $item.publication.level -eq 'checkout') { throw 'Este documento possui uma reserva. Conclua a edição exclusiva no SharePoint antes da coautoria.' }
            if ([IO.Path]::GetExtension([string]$item.name).ToLowerInvariant() -notin @('.docx', '.xlsx', '.pptx')) {
                throw 'Para coautoria, use DOCX, XLSX ou PPTX. Converta outros formatos pelo Office.'
            }
            Open-DocumentUri $officeUri
            return 'Documento aberto no Office pelo SharePoint. A coautoria depende do Office e das regras da biblioteca.'
        }
        $me = Invoke-GraphGet 'https://graph.microsoft.com/v1.0/me?$select=id' $token $null
        if (-not $me.id) { throw 'Não foi possível identificar a conta desta biblioteca.' }
        if ($Action -eq 'Finish') {
            if (-not $entry) { throw 'Não há reserva registrada neste computador. Conclua reservas externas no SharePoint.' }
            if (-not $ConfirmedSavedAndClosed) { throw 'Salve, aguarde o Office confirmar o envio e feche o documento antes de concluir.' }
            if ($entry.state -ne 'Reserved' -or [string]$entry.userId -ne [string]$me.id) {
                throw 'A reserva exige conferência no SharePoint. Nenhum check-in automático será realizado.'
            }
            Assert-OwnedDocumentCheckout $item ([string]$entry.userId)
            $entry.state = 'CheckinPending'
            Save-DocumentReservations $entries
            Invoke-GraphDocumentPost ($itemUri + '/checkin') $token @{ comment = 'Edição concluída pelo SharePoint Fácil' }
            $entries = @($entries | Where-Object { $_ -ne $entry })
            Save-DocumentReservations $entries
            try {
                $null = Invoke-ControllerRequest 'vfs/forget' @{ fs = ($profile.remote + ':') } $script:Controller 8
                Notify-ProfileExplorerViews $profile
            } catch {
                Write-AppLog 'WARN' ('O conteúdo será atualizado pelo observador: ' + $_.Exception.Message)
            }
            return 'Check-in confirmado pelo SharePoint. As regras de aprovação da biblioteca continuam valendo.'
        }
        # Never adopt a pre-existing checkout, including one by the same account.
        if ($entry -or $item.publication.level -eq 'checkout') {
            throw 'O documento já está reservado ou exige conferência. Use Reservas / concluir ou abra no SharePoint.'
        }
        $entry = [pscustomobject]@{
            driveId = [string]$profile.driveId; itemId = [string]$item.id; userId = [string]$me.id
            profileId = [string]$profile.id; relativePath = $target.Relative; name = [string]$item.name
            state = 'CheckoutPending'; createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $entries += $entry
        Save-DocumentReservations $entries
        Invoke-GraphDocumentPost ($itemUri + '/checkout') $token
        $confirmed = Invoke-GraphGet (Get-DocumentMetadataUri $itemUri) $token $null
        Assert-OwnedDocumentCheckout $confirmed ([string]$me.id)
        $entry.state = 'Reserved'
        Save-DocumentReservations $entries
        # If Office cannot launch, retain the reservation for explicit recovery.
        Open-DocumentUri (Get-OfficeDocumentUri $profile $confirmed)
        return 'Reserva confirmada para este arquivo. Salve e feche no Office; depois use Reservas / concluir. A unidade continua gravável: não edite outra cópia pela unidade enquanto usa este documento online.'
    } finally {
        if ($held) { $guard.ReleaseMutex() }
        $guard.Dispose()
    }
}

function Show-DocumentAction {
    param([string]$Action, [string]$Path, [string]$ReservationItemId)
    if ($Action -eq 'Auto') {
        # A double-click must always open the file: fall back to the drive copy.
        try { $null = Invoke-DocumentAction 'Auto' $Path }
        catch {
            Write-AppLog 'WARN' ('Abertura pela unidade em vez do SharePoint: ' + $_.Exception.Message)
            try { Open-LocalDocument $Path } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, $script:AppName, 'OK', 'Warning') | Out-Null }
        }
        return
    }
    try {
        $confirmed = $false
        if ($Action -eq 'Finish') {
            $answer = [Windows.Forms.MessageBox]::Show('O Office já confirmou que o arquivo foi salvo no SharePoint e você fechou o documento? O check-in liberará a versão enviada. Alterações offline do Office não são verificadas pelo rclone.', $script:AppName, 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
            $confirmed = $true
        }
        $message = Invoke-DocumentAction $Action $Path -ConfirmedSavedAndClosed:$confirmed -ReservationItemId $ReservationItemId
        if ($Action -in @('Exclusive', 'Finish', 'Reconcile')) { [Windows.Forms.MessageBox]::Show($message, $script:AppName, 'OK', 'Information') | Out-Null }
    } catch {
        Write-AppLog 'ERROR' ('Operação de documento: ' + $_.Exception.Message)
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, $script:AppName, 'OK', 'Warning') | Out-Null
    }
}

function Show-DocumentPicker {
    param([string]$Action)
    $profile = & $script:GetSelectedProfile
    if (-not $profile) { return }
    $picker = New-Object Windows.Forms.OpenFileDialog
    try {
        $picker.Title = 'Selecione o documento na unidade ' + $profile.drive + ':'
        $picker.InitialDirectory = $profile.drive + ':\'
        $picker.Filter = 'Documentos Office|*.docx;*.docm;*.doc;*.xlsx;*.xlsm;*.xlsb;*.xls;*.pptx;*.pptm;*.ppt;*.ppsx;*.ppsm'
        if ($picker.ShowDialog($script:MainForm) -eq 'OK') { Show-DocumentAction $Action $picker.FileName }
    } finally { $picker.Dispose() }
}

function Show-DocumentReservations {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Reservas / concluir edição'
    $dialog.Size = New-Object Drawing.Size(760, 350)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.AutoScaleMode = 'Dpi'
    $dialog.StartPosition = 'CenterParent'
    $dialog.Font = New-Object Drawing.Font('Segoe UI', 9)
    $list = New-Object Windows.Forms.ListBox
    $list.Location = New-Object Drawing.Point(16, 16)
    $list.Size = New-Object Drawing.Size(710, 175)
    $list.Anchor = 'Top,Bottom,Left,Right'
    $list.DisplayMember = 'Display'
    foreach ($entry in @(Read-DocumentReservations)) {
        [void]$list.Items.Add([pscustomobject]@{ Display = ($entry.name + ' — ' + $entry.state); Entry = $entry })
    }
    $dialog.Controls.Add($list)
    $hint = New-Object Windows.Forms.Label
    $hint.Text = 'Reservas persistem após fechar o aplicativo. Estados Pending exigem conferência no SharePoint. Use a mesma conta no Office e no aplicativo.'
    $hint.Location = New-Object Drawing.Point(16, 200)
    $hint.Size = New-Object Drawing.Size(710, 42)
    $dialog.Controls.Add($hint)
    $open = New-Object Windows.Forms.Button
    $open.Text = 'Abrir no SharePoint'
    $open.Location = New-Object Drawing.Point(16, 255)
    $open.Size = New-Object Drawing.Size(160, 32)
    $finish = New-Object Windows.Forms.Button
    $finish.Text = 'Salvei e fechei: concluir'
    $finish.Location = New-Object Drawing.Point(185, 255)
    $finish.Size = New-Object Drawing.Size(200, 32)
    $reconcile = New-Object Windows.Forms.Button
    $reconcile.Text = 'Já concluí no site: conferir'
    $reconcile.Location = New-Object Drawing.Point(397, 255)
    $reconcile.Size = New-Object Drawing.Size(225, 32)
    $dialog.Controls.AddRange(@($open, $finish, $reconcile))
    $open.Add_Click({
        if (-not $list.SelectedItem) { return }
        $entry = $list.SelectedItem.Entry
        $profile = @($script:Profiles | Where-Object { $_.id -eq $entry.profileId })[0]
        if ($profile) {
            try {
                $token = Get-ProfileAccessToken $profile
                $item = Invoke-GraphGet (Get-DocumentMetadataUri (Get-DocumentItemUri $profile $entry.itemId)) $token $null
                Open-DocumentUri (Get-TrustedDocumentUrl $profile $item)
            } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, $script:AppName) | Out-Null }
        }
    })
    $finish.Add_Click({
        if (-not $list.SelectedItem) { return }
        $entry = $list.SelectedItem.Entry
        $profile = @($script:Profiles | Where-Object { $_.id -eq $entry.profileId })[0]
        if ($profile) { Show-DocumentAction 'Finish' ($profile.drive + ':\' + $entry.relativePath) $entry.itemId; $dialog.Close() }
    })
    $reconcile.Add_Click({
        if (-not $list.SelectedItem) { return }
        $entry = $list.SelectedItem.Entry
        $profile = @($script:Profiles | Where-Object { $_.id -eq $entry.profileId })[0]
        if ($profile) { Show-DocumentAction 'Reconcile' ($profile.drive + ':\' + $entry.relativePath) $entry.itemId; $dialog.Close() }
    })
    try { [void]$dialog.ShowDialog($script:MainForm) } finally { $dialog.Dispose() }
}

function Get-DriveInUse {
    param([string]$Drive)
    try { return [IO.DriveInfo]::GetDrives().Name -contains ($Drive.ToUpperInvariant() + ':\') } catch { return $false }
}

function Get-ActiveMounts {
    param([switch]$ThrowOnError)
    try {
        $null = Start-Controller
        $response = Invoke-ControllerRequest 'mount/listmounts' @{} $script:Controller 5
        return @($response.mountPoints)
    } catch {
        if ($ThrowOnError) { throw }
        return @()
    }
}

function Test-ExactMount {
    param($Profile, [object[]]$ActiveMounts)
    return @($ActiveMounts | Where-Object {
        [string]$_.MountPoint -eq ($Profile.drive + ':') -and [string]$_.Fs -eq ($Profile.remote + ':')
    }).Count -gt 0
}

function Get-ProfileMountState {
    param($Profile, [object[]]$ActiveMounts)
    $mount = @($ActiveMounts | Where-Object {
        [string]$_.MountPoint -eq ($Profile.drive + ':') -and [string]$_.Fs -eq ($Profile.remote + ':')
    } | Select-Object -First 1)
    if ($mount.Count -gt 0) { return 'Mounted' }
    if (Get-DriveInUse $Profile.drive) { return 'Conflict' }
    return 'Stopped'
}

function Assert-ProfileRemoteTarget {
    param($Profile)
    if ([string]$Profile.remote -eq ':memory') { return }
    if (-not $Profile.driveId) { throw 'A biblioteca desta unidade não possui um identificador SharePoint válido.' }
    $config = Get-AppConfigDump
    $remote = $config.PSObject.Properties[[string]$Profile.remote]
    if (-not $remote -or
        [string]$remote.Value.drive_id -ne [string]$Profile.driveId -or
        [string]$remote.Value.drive_type -ne 'documentLibrary') {
        throw 'O destino local não corresponde à biblioteca SharePoint escolhida. Reconecte a biblioteca antes de usar esta unidade.'
    }
}

function New-MountRequest {
    param($Profile)
    return [ordered]@{
        fs = ($Profile.remote + ':')
        mountPoint = ($Profile.drive + ':')
        mountType = 'cmount'
        network_mode = $true
        volname = $Profile.label
        option = @('FileSecurity=D:P(A;;FA;;;OW)')
        vfs_cache_mode = 'full'
        vfs_cache_max_age = '24h'
        vfs_cache_max_size = '10G'
        vfs_cache_min_free_space = '2G'
        vfs_write_back = ($script:VfsWriteBackSeconds.ToString() + 's')
        # OneDrive/SharePoint change notifications (delta API) invalidate the
        # directory cache within poll_interval, so listings can be kept for
        # long and large folders are not re-listed on every Explorer refresh.
        dir_cache_time = $script:DirectoryCacheTime
        poll_interval = $script:RemotePollInterval
        # Explorer stats each file several times; cache attributes briefly.
        attr_timeout = '10s'
        # Download large files over parallel ranged requests.
        vfs_read_chunk_streams = 8
        vfs_read_chunk_size = '8M'
        # The cmount/WinFsp network-drive path requires link translation.
        # SharePoint rewrites Office files on upload (library metadata), so the
        # stored size/hash never match the cache. Without these switches every
        # Office save fails as "corrupted on transfer" and is retried forever.
        # See rclone docs: "Unexpected file size/hash differences on Sharepoint".
        _config = @{ Links = $true; IgnoreSize = $true; IgnoreChecksum = $true }
    }
}

function Start-Mount {
    param($Profile, [switch]$Quiet)
    if (-not (Test-WinFspInstalled)) {
        if (-not $Quiet) { Show-FriendlyError 'Componente necessário' 'O componente de unidades do Windows não está funcionando. Use Reparar no instalador do SharePoint Fácil.' $null }
        return $false
    }
    try {
        $mounts = Get-ActiveMounts
        $state = Get-ProfileMountState $Profile $mounts
        if ($state -eq 'Mounted') { return $true }
        if ($state -eq 'Conflict') { throw ('A letra {0}: já está sendo usada por outra unidade.' -f $Profile.drive) }

        $null = Start-Controller
        Assert-ProfileRemoteTarget $Profile
        $body = New-MountRequest $Profile
        $null = Invoke-ControllerRequest 'mount/mount' $body $script:Controller 45
        $deadline = (Get-Date).AddSeconds(12)
        while ((Get-Date) -lt $deadline) {
            $currentMounts = @(Get-ActiveMounts -ThrowOnError)
            if ((Test-ExactMount $Profile $currentMounts) -and (Get-DriveInUse $Profile.drive)) {
                Write-AppLog 'INFO' ('Unidade {0}: conectada a {1}' -f $Profile.drive, $Profile.remote)
                Start-ShellWatcher
                return $true
            }
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 180
        }
        throw ('A unidade {0}: não apareceu no Explorador dentro do tempo esperado.' -f $Profile.drive)
    } catch {
        $mountError = $_
        try {
            $partial = @(Get-ActiveMounts | Where-Object {
                [string]$_.MountPoint -eq ($Profile.drive + ':') -and [string]$_.Fs -eq ($Profile.remote + ':')
            } | Select-Object -First 1)
            if ($partial.Count -gt 0) {
                $null = Invoke-ControllerRequest 'mount/unmount' @{ mountPoint = ($Profile.drive + ':') } $script:Controller 20
                Write-AppLog 'WARN' ('Montagem incompleta em {0}: foi desfeita automaticamente.' -f $Profile.drive)
            }
        } catch {
            Write-AppLog 'WARN' ('Não foi possível desfazer a montagem incompleta em {0}: {1}' -f $Profile.drive, $_.Exception.Message)
        }
        Write-AppLog 'ERROR' ('Falha ao conectar {0}: {1}' -f $Profile.label, $mountError.Exception.Message)
        if (-not $Quiet) { Show-FriendlyError 'Não foi possível conectar' ('A unidade {0}: não pôde ser criada. Verifique sua internet e tente novamente.' -f $Profile.drive) $mountError }
        return $false
    }
}

function Resolve-SafeVfsCachePath {
    param([string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return '' }
    $rawPath = $Candidate
    if ($rawPath.StartsWith('\\?\') -and -not $rawPath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $rawPath = $rawPath.Substring(4)
    }
    $cacheRoot = [IO.Path]::GetFullPath($script:CacheDir).TrimEnd('\') + '\'
    $fullPath = [IO.Path]::GetFullPath($rawPath).TrimEnd('\')
    if (-not ($fullPath + '\').StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase) -or ($fullPath + '\') -eq $cacheRoot) {
        throw ('O caminho de cache está fora da área privada do aplicativo: ' + $fullPath)
    }
    return $fullPath
}

function Get-VfsMetadataHealth {
    param([string]$MetaPath, [string]$DataPath = '')
    $safeMeta = Resolve-SafeVfsCachePath $MetaPath
    $safeData = Resolve-SafeVfsCachePath $DataPath
    $dirtyFiles = @()
    $uncertainFiles = @()
    $metaFiles = @()
    $dataFiles = @()

    if ($safeMeta -and (Test-Path -LiteralPath $safeMeta -PathType Container)) {
        $metaFiles = @(Get-ChildItem -LiteralPath $safeMeta -Recurse -File -Force -ErrorAction Stop)
        foreach ($metaFile in $metaFiles) {
            $metadata = $null
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    $metadata = [IO.File]::ReadAllText($metaFile.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
                    if (-not $metadata.PSObject.Properties['Dirty']) { throw 'Campo Dirty ausente.' }
                    break
                } catch {
                    if ($attempt -lt 3) { Start-Sleep -Milliseconds 80 }
                    else { $uncertainFiles += $metaFile.FullName }
                }
            }
            if ($metadata -and $metadata.Dirty -eq $true) { $dirtyFiles += $metaFile.FullName }
        }
    }
    if ($safeData -and (Test-Path -LiteralPath $safeData -PathType Container)) {
        $dataFiles = @(Get-ChildItem -LiteralPath $safeData -Recurse -File -Force -ErrorAction Stop)
    }
    if ($dataFiles.Count -gt 0 -and $metaFiles.Count -eq 0) {
        $uncertainFiles += $safeData
    }
    return [pscustomobject]@{
        DirtyFiles = @($dirtyFiles)
        UncertainFiles = @($uncertainFiles)
        IsDirty = $dirtyFiles.Count -gt 0
        IsUncertain = $uncertainFiles.Count -gt 0
    }
}

function Get-ProfileVfsCacheInfo {
    param($Profile, $Stats = $null)
    if ($Stats) {
        if (-not $Stats.diskCache -or -not $Stats.diskCache.pathMeta) {
            throw 'O rclone não informou a área de cache necessária para validar as gravações.'
        }
        $dataPath = Resolve-SafeVfsCachePath ([string]$Stats.diskCache.path)
        $metaPath = Resolve-SafeVfsCachePath ([string]$Stats.diskCache.pathMeta)
    } else {
        $dataPath = Resolve-SafeVfsCachePath (Join-Path (Join-Path $script:CacheDir 'vfs') ([string]$Profile.remote))
        $metaPath = Resolve-SafeVfsCachePath (Join-Path (Join-Path $script:CacheDir 'vfsMeta') ([string]$Profile.remote))
    }
    $health = Get-VfsMetadataHealth $metaPath $dataPath
    $paths = @(@($dataPath, $metaPath) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
    return [pscustomobject]@{
        DataPath = $dataPath
        MetaPath = $metaPath
        Paths = @($paths)
        DirtyFiles = @($health.DirtyFiles)
        IsDirty = [bool]$health.IsDirty
        IsUncertain = [bool]$health.IsUncertain
    }
}

function Wait-PendingUploads {
    param($Profile, [int]$TimeoutSeconds = 180, [switch]$Quiet)
    $busy = $null
    $started = Get-Date
    $cleanSince = $null
    $cleanSamples = 0
    $lastDirtyCount = 0
    try {
        while ($true) {
            try {
                $stats = Invoke-ControllerRequest 'vfs/stats' @{ fs = ($Profile.remote + ':') } $script:Controller 8
                $queued = [int]$stats.diskCache.uploadsQueued
                $uploading = [int]$stats.diskCache.uploadsInProgress
                $errors = [int]$stats.diskCache.erroredFiles
                $cacheInfo = Get-ProfileVfsCacheInfo $Profile $stats
                if ($cacheInfo.IsUncertain) { throw 'O estado de um arquivo no cache local não pôde ser validado.' }
                $lastDirtyCount = @($cacheInfo.DirtyFiles).Count
            } catch {
                Write-AppLog 'WARN' ('Status de upload indisponível para {0}: {1}' -f $Profile.remote, $_.Exception.Message)
                if (-not $AutoMount -and -not $Quiet) {
                    Show-FriendlyError 'Não foi possível verificar os envios' 'A unidade foi mantida conectada porque o SharePoint Fácil não conseguiu confirmar que todas as alterações terminaram de enviar. Verifique sua internet e tente novamente.' $_
                }
                return $false
            }
            if ($errors -gt 0) {
                if ($busy) { Close-BusyWindow $busy; $busy = $null }
                if (-not $Quiet) { Show-FriendlyError 'Envio pendente' 'Há um arquivo que ainda não foi enviado ao SharePoint. Mantenha a unidade conectada, verifique a internet e tente desmontar novamente.' $null }
                return $false
            }
            if (($queued + $uploading + $lastDirtyCount) -eq 0) {
                $cleanSamples++
                if (-not $cleanSince) { $cleanSince = Get-Date }
                # Keep observing a clean cache beyond the configured write-back
                # delay so a just-closed Office file has time to enter and leave
                # the upload queue.
                if ($cleanSamples -ge 2 -and ((Get-Date) - $cleanSince).TotalSeconds -ge ($script:VfsWriteBackSeconds + 0.25)) { return $true }
            } else {
                $cleanSamples = 0
                $cleanSince = $null
            }
            if (-not $busy -and -not $AutoMount -and -not $Quiet) {
                $busy = New-BusyWindow 'Concluindo as alterações antes de desmontar...' $true
            }
            if ($busy) {
                if ($lastDirtyCount -gt 0) {
                    $busy.Label.Text = 'Feche {0} arquivo(s) que ainda estão abertos nesta unidade. Você pode cancelar e mantê-la conectada.' -f $lastDirtyCount
                } elseif (($queued + $uploading) -gt 0) {
                    $busy.Label.Text = 'Enviando {0} arquivo(s) antes de desmontar. Você pode cancelar e manter a unidade conectada.' -f ($queued + $uploading)
                } else {
                    $busy.Label.Text = 'Confirmando que todas as alterações terminaram de enviar...'
                }
                if ($busy.State.Canceled) { return $false }
            }
            if (((Get-Date) - $started).TotalSeconds -ge $TimeoutSeconds) {
                if ($busy) { Close-BusyWindow $busy; $busy = $null }
                if (-not $Quiet) {
                    $message = if ($lastDirtyCount -gt 0) { 'Ainda há um arquivo aberto ou não finalizado. Feche-o e tente desmontar novamente.' } else { 'As alterações ainda não terminaram de enviar. A unidade foi mantida conectada para proteger seus arquivos.' }
                    Show-FriendlyError 'Envio ainda em andamento' $message $null
                }
                return $false
            }
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 500
        }
    } finally { Close-BusyWindow $busy }
}

function Get-SafeVfsCachePaths {
    param($Profile)
    $stats = Invoke-ControllerRequest 'vfs/stats' @{ fs = ($Profile.remote + ':') } $script:Controller 8
    $cacheInfo = Get-ProfileVfsCacheInfo $Profile $stats
    if ($cacheInfo.IsUncertain) { throw 'O cache local não pôde ser validado com segurança.' }
    return @($cacheInfo.Paths)
}

function Remove-SafeVfsCachePaths {
    param([string[]]$Paths)
    $cacheRoot = [IO.Path]::GetFullPath($script:CacheDir).TrimEnd('\') + '\'
    foreach ($candidate in @($Paths)) {
        try {
            $fullPath = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
            if (($fullPath + '\').StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase) -and ($fullPath + '\') -ne $cacheRoot -and (Test-Path -LiteralPath $fullPath)) {
                Remove-Item -LiteralPath $fullPath -Recurse -Force
            }
        } catch {
            Write-AppLog 'WARN' ('O cache local não pôde ser removido: ' + $_.Exception.Message)
        }
    }
}

function Stop-Mount {
    param($Profile, [switch]$Quiet, [int]$TimeoutSeconds = 180)
    try {
        $mounts = Get-ActiveMounts -ThrowOnError
        $state = Get-ProfileMountState $Profile $mounts
        if ($state -eq 'Stopped') {
            $offlineCache = Get-ProfileVfsCacheInfo $Profile
            if ($offlineCache.IsDirty -or $offlineCache.IsUncertain) {
                $reason = if ($offlineCache.IsDirty) { 'Há alterações locais que ainda não chegaram ao SharePoint.' } else { 'O estado do cache local não pôde ser confirmado.' }
                Write-AppLog 'WARN' ('Remoção/desmontagem bloqueada para {0}: {1}' -f $Profile.remote, $reason)
                if (-not $Quiet) { Show-FriendlyError 'Alterações locais preservadas' ($reason + ' Monte a unidade novamente, aguarde o envio e tente de novo.') $null }
                return $false
            }
            return $true
        }
        if ($state -eq 'Conflict') { throw ('A letra {0}: pertence a outra unidade e não será alterada.' -f $Profile.drive) }
        if (-not (Wait-PendingUploads $Profile -TimeoutSeconds $TimeoutSeconds -Quiet:$Quiet)) { return $false }
        $null = Invoke-ControllerRequest 'mount/unmount' @{ mountPoint = ($Profile.drive + ':') } $script:Controller 30
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline) {
            $currentMounts = @(Get-ActiveMounts -ThrowOnError)
            if (-not (Test-ExactMount $Profile $currentMounts) -and -not (Get-DriveInUse $Profile.drive)) {
                Write-AppLog 'INFO' ('Unidade {0}: desmontada com segurança' -f $Profile.drive)
                return $true
            }
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
        }
        throw ('A unidade {0}: continua visível no Explorador.' -f $Profile.drive)
    } catch {
        Write-AppLog 'ERROR' ('Falha ao desmontar {0}: {1}' -f $Profile.label, $_.Exception.Message)
        if (-not $Quiet) { Show-FriendlyError 'Não foi possível desmontar' 'A unidade foi mantida como estava para proteger seus arquivos.' $_ }
        return $false
    }
}

function Update-StartupShortcut {
    # O MSI instala um único atalho compartilhado com -AutoMount. O aplicativo
    # apenas registra, em cada perfil, quais bibliotecas devem ser reconectadas.
    return
}

function Test-ValidVolumeLabel {
    param([string]$Label, $ExcludeProfile)
    $value = $Label.Trim()
    if ($value.Length -lt 1 -or $value.Length -gt 64) { return $false }
    if ($value -match '[\\/:*?"<>|\x00-\x1F]') { return $false }
    $duplicate = @($script:Profiles | Where-Object { $_ -ne $ExcludeProfile -and $_.label -eq $value }).Count -gt 0
    return -not $duplicate
}

function Get-AvailableDriveLetters {
    param([string]$IncludeDrive = '')
    $configured = @($script:Profiles | Where-Object { $_.drive -ne $IncludeDrive } | ForEach-Object { $_.drive })
    return @([char[]](90..68) | ForEach-Object { [string]$_ } | Where-Object {
        $_ -eq $IncludeDrive -or ($configured -notcontains $_ -and -not (Get-DriveInUse $_))
    })
}

function Set-DialogButtonStyle {
    param([Windows.Forms.Button]$Button, [bool]$Primary = $false)
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 1
    $Button.Cursor = [Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $Button.BackColor = $script:Colors.Teal
        $Button.ForeColor = [Drawing.Color]::White
        $Button.FlatAppearance.BorderColor = $script:Colors.Teal
        $Button.FlatAppearance.MouseOverBackColor = $script:Colors.TealHover
    } else {
        $Button.BackColor = $script:Colors.Surface
        $Button.ForeColor = $script:Colors.Ink
        $Button.FlatAppearance.BorderColor = $script:Colors.Border
    }
}

function Show-NewSharePointMappingDialog {
    param([object[]]$Libraries, [string]$AccountName)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Conectar biblioteca'
    $dialog.Size = New-Object Drawing.Size(780, 470)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowIcon = $false
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $script:Colors.Surface
    $dialog.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $dialog.AutoScaleMode = 'Dpi'

    $header = New-Object Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 92
    $header.BackColor = $script:Colors.Navy
    $dialog.Controls.Add($header)
    $title = New-Object Windows.Forms.Label
    $title.Text = 'Escolha a biblioteca'
    $title.Font = New-Object Drawing.Font('Segoe UI Semibold', 17)
    $title.ForeColor = [Drawing.Color]::White
    $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point(24, 16)
    $header.Controls.Add($title)
    $account = New-Object Windows.Forms.Label
    $account.Text = if ($AccountName) { 'Conta Microsoft: ' + $AccountName } else { 'Conta Microsoft autorizada' }
    $account.ForeColor = [Drawing.Color]::FromArgb(206, 231, 233)
    $account.AutoSize = $true
    $account.Location = New-Object Drawing.Point(27, 54)
    $header.Controls.Add($account)

    $libraryLabel = New-Object Windows.Forms.Label
    $libraryLabel.Text = 'Site e biblioteca'
    $libraryLabel.AutoSize = $true
    $libraryLabel.ForeColor = $script:Colors.Ink
    $libraryLabel.Location = New-Object Drawing.Point(28, 116)
    $dialog.Controls.Add($libraryLabel)
    $libraryBox = New-Object Windows.Forms.ComboBox
    $libraryBox.DropDownStyle = 'DropDown'
    $libraryBox.AutoCompleteMode = 'SuggestAppend'
    $libraryBox.AutoCompleteSource = 'ListItems'
    $libraryBox.Location = New-Object Drawing.Point(31, 140)
    $libraryBox.Size = New-Object Drawing.Size(712, 28)
    $libraryBox.DropDownWidth = 740
    $libraryBox.DisplayMember = 'Display'
    [void]$libraryBox.Items.AddRange([object[]]$Libraries)
    $libraryBox.AccessibleName = 'Site e biblioteca do SharePoint'
    $dialog.Controls.Add($libraryBox)

    $urlLabel = New-Object Windows.Forms.Label
    $urlLabel.ForeColor = $script:Colors.Muted
    $urlLabel.AutoEllipsis = $true
    $urlLabel.Location = New-Object Drawing.Point(31, 174)
    $urlLabel.Size = New-Object Drawing.Size(710, 20)
    $dialog.Controls.Add($urlLabel)

    $driveLabel = New-Object Windows.Forms.Label
    $driveLabel.Text = 'Letra da unidade'
    $driveLabel.AutoSize = $true
    $driveLabel.Location = New-Object Drawing.Point(28, 215)
    $dialog.Controls.Add($driveLabel)
    $driveBox = New-Object Windows.Forms.ComboBox
    $driveBox.DropDownStyle = 'DropDownList'
    $driveBox.Location = New-Object Drawing.Point(31, 239)
    $driveBox.Size = New-Object Drawing.Size(112, 28)
    [void]$driveBox.Items.AddRange([object[]](Get-AvailableDriveLetters))
    $driveBox.AccessibleName = 'Letra da unidade no Explorador'
    $dialog.Controls.Add($driveBox)

    $nameLabel = New-Object Windows.Forms.Label
    $nameLabel.Text = 'Nome no Explorador de Arquivos'
    $nameLabel.AutoSize = $true
    $nameLabel.Location = New-Object Drawing.Point(177, 215)
    $dialog.Controls.Add($nameLabel)
    $nameBox = New-Object Windows.Forms.TextBox
    $nameBox.Location = New-Object Drawing.Point(180, 239)
    $nameBox.Size = New-Object Drawing.Size(563, 28)
    $nameBox.MaxLength = 64
    $nameBox.AccessibleName = 'Nome da unidade no Explorador'
    $dialog.Controls.Add($nameBox)

    $hint = New-Object Windows.Forms.Label
    $hint.Text = 'Você poderá alterar a letra e o nome depois.'
    $hint.ForeColor = $script:Colors.Muted
    $hint.AutoSize = $true
    $hint.Location = New-Object Drawing.Point(179, 272)
    $dialog.Controls.Add($hint)

    $autoCheck = New-Object Windows.Forms.CheckBox
    $autoCheck.Text = 'Reconectar automaticamente quando eu entrar no Windows'
    $autoCheck.Checked = $true
    $autoCheck.Location = New-Object Drawing.Point(31, 307)
    $autoCheck.Size = New-Object Drawing.Size(430, 26)
    $dialog.Controls.Add($autoCheck)

    $connect = New-Object Windows.Forms.Button
    $connect.Text = 'Conectar'
    $connect.Location = New-Object Drawing.Point(544, 367)
    $connect.Size = New-Object Drawing.Size(96, 36)
    Set-DialogButtonStyle $connect $true
    $dialog.Controls.Add($connect)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancelar'
    $cancel.DialogResult = 'Cancel'
    $cancel.Location = New-Object Drawing.Point(647, 367)
    $cancel.Size = New-Object Drawing.Size(96, 36)
    Set-DialogButtonStyle $cancel $false
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $connect
    $dialog.CancelButton = $cancel

    $updateLibrary = {
        $entry = $libraryBox.SelectedItem
        if (-not $entry) { return }
        $urlLabel.Text = $entry.WebUrl
        $suggested = if ($entry.LibraryName -match '^(Documentos|Documents|Shared Documents)$') {
            $entry.SiteName
        } else {
            '{0} - {1}' -f $entry.SiteName, $entry.LibraryName
        }
        if ($suggested.Length -gt 64) { $suggested = $suggested.Substring(0, 64) }
        $nameBox.Text = $suggested -replace '[\\/:*?"<>|\x00-\x1F]', '-'
    }
    $libraryBox.Add_SelectedIndexChanged($updateLibrary)
    $libraryBox.Add_TextChanged($updateLibrary)
    if ($libraryBox.Items.Count -gt 0) { $libraryBox.SelectedIndex = 0 }
    if ($driveBox.Items.Count -gt 0) { $driveBox.SelectedIndex = 0 }

    $connect.Add_Click({
        $selectedLibrary = $libraryBox.SelectedItem
        if (-not $selectedLibrary) {
            [Windows.Forms.MessageBox]::Show('Escolha uma biblioteca da lista.', $script:AppName, 'OK', 'Warning') | Out-Null
            return
        }
        if ($driveBox.SelectedIndex -lt 0) {
            [Windows.Forms.MessageBox]::Show('Não há uma letra de unidade disponível.', $script:AppName, 'OK', 'Warning') | Out-Null
            return
        }
        if (-not (Test-ValidVolumeLabel $nameBox.Text $null)) {
            [Windows.Forms.MessageBox]::Show('Use um nome único, com até 64 caracteres e sem \\ / : * ? " < > |.', $script:AppName, 'OK', 'Warning') | Out-Null
            return
        }
        $dialog.Tag = [pscustomobject]@{
            Library = $selectedLibrary
            DriveLetter = [string]$driveBox.SelectedItem
            Label = $nameBox.Text.Trim()
            AutoMount = $autoCheck.Checked
        }
        $dialog.DialogResult = 'OK'
        $dialog.Close()
    })

    if ($dialog.ShowDialog($script:MainForm) -eq 'OK') { return $dialog.Tag }
    return $null
}

function Show-EditProfileDialog {
    param($Profile)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Editar unidade'
    $dialog.Size = New-Object Drawing.Size(600, 360)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowIcon = $false
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $script:Colors.Surface
    $dialog.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $dialog.AutoScaleMode = 'Dpi'

    $title = New-Object Windows.Forms.Label
    $title.Text = if ($Profile.libraryName) { $Profile.libraryName } else { $Profile.label }
    $title.Font = New-Object Drawing.Font('Segoe UI Semibold', 15)
    $title.ForeColor = $script:Colors.Ink
    $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point(24, 20)
    $dialog.Controls.Add($title)
    $origin = New-Object Windows.Forms.Label
    $origin.Text = if ($Profile.siteName) { $Profile.siteName } else { 'Biblioteca do SharePoint' }
    $origin.ForeColor = $script:Colors.Muted
    $origin.AutoSize = $true
    $origin.Location = New-Object Drawing.Point(27, 53)
    $dialog.Controls.Add($origin)

    $driveLabel = New-Object Windows.Forms.Label
    $driveLabel.Text = 'Letra da unidade'
    $driveLabel.AutoSize = $true
    $driveLabel.Location = New-Object Drawing.Point(27, 97)
    $dialog.Controls.Add($driveLabel)
    $driveBox = New-Object Windows.Forms.ComboBox
    $driveBox.DropDownStyle = 'DropDownList'
    $driveBox.Location = New-Object Drawing.Point(30, 121)
    $driveBox.Size = New-Object Drawing.Size(95, 28)
    [void]$driveBox.Items.AddRange([object[]](Get-AvailableDriveLetters $Profile.drive))
    $driveBox.SelectedItem = $Profile.drive
    $dialog.Controls.Add($driveBox)

    $nameLabel = New-Object Windows.Forms.Label
    $nameLabel.Text = 'Nome no Explorador'
    $nameLabel.AutoSize = $true
    $nameLabel.Location = New-Object Drawing.Point(155, 97)
    $dialog.Controls.Add($nameLabel)
    $nameBox = New-Object Windows.Forms.TextBox
    $nameBox.Text = $Profile.label
    $nameBox.MaxLength = 64
    $nameBox.Location = New-Object Drawing.Point(158, 121)
    $nameBox.Size = New-Object Drawing.Size(395, 28)
    $dialog.Controls.Add($nameBox)

    $autoCheck = New-Object Windows.Forms.CheckBox
    $autoCheck.Text = 'Reconectar automaticamente quando eu entrar no Windows'
    $autoCheck.Checked = $Profile.autoMount
    $autoCheck.Location = New-Object Drawing.Point(30, 179)
    $autoCheck.Size = New-Object Drawing.Size(430, 26)
    $dialog.Controls.Add($autoCheck)

    $save = New-Object Windows.Forms.Button
    $save.Text = 'Salvar alterações'
    $save.Location = New-Object Drawing.Point(353, 254)
    $save.Size = New-Object Drawing.Size(118, 36)
    Set-DialogButtonStyle $save $true
    $dialog.Controls.Add($save)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancelar'
    $cancel.DialogResult = 'Cancel'
    $cancel.Location = New-Object Drawing.Point(478, 254)
    $cancel.Size = New-Object Drawing.Size(75, 36)
    Set-DialogButtonStyle $cancel $false
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $save
    $dialog.CancelButton = $cancel

    $save.Add_Click({
        if ($driveBox.SelectedIndex -lt 0 -or -not (Test-ValidVolumeLabel $nameBox.Text $Profile)) {
            [Windows.Forms.MessageBox]::Show('Escolha uma letra livre e use um nome único e válido.', $script:AppName, 'OK', 'Warning') | Out-Null
            return
        }
        $dialog.Tag = [pscustomobject]@{
            Drive = [string]$driveBox.SelectedItem
            Label = $nameBox.Text.Trim()
            AutoMount = $autoCheck.Checked
        }
        $dialog.DialogResult = 'OK'
        $dialog.Close()
    })
    if ($dialog.ShowDialog($script:MainForm) -eq 'OK') { return $dialog.Tag }
    return $null
}

function Set-AppRemote {
    param([string]$Name, [hashtable]$Parameters)
    $config = Get-AppConfigDump
    if ($config.PSObject.Properties[$Name]) {
        Invoke-AppRemoteConfiguration -Action update -Name $Name -Parameters $Parameters
    } else {
        New-AppRemote $Name $Parameters
    }
}

function Add-SharePointLibrary {
    $oauth = $null
    $remoteName = ''
    $profileSaved = $false
    try {
        $oauth = Get-CachedOAuthToken
        $usedCachedAuthorization = $null -ne $oauth
        if (-not $oauth) {
            $oauth = Request-MicrosoftAuthorization
            if (-not $oauth) { return 'Canceled' }
        }
        try {
            $libraries = @(Get-AccessibleLibraries $oauth)
        } catch [UnauthorizedAccessException] {
            $oauth = Request-MicrosoftAuthorization
            if (-not $oauth) { return 'Canceled' }
            $usedCachedAuthorization = $false
            $libraries = @(Get-AccessibleLibraries $oauth)
        } catch [Security.SecurityException] {
            $oauth = Request-MicrosoftAuthorization
            if (-not $oauth) { return 'Canceled' }
            $usedCachedAuthorization = $false
            $libraries = @(Get-AccessibleLibraries $oauth)
        }
        if ($libraries.Count -eq 0 -and $usedCachedAuthorization) {
            $answer = [Windows.Forms.MessageBox]::Show(
                'Não encontrei outra biblioteca disponível para esta conta. Deseja entrar com uma conta Microsoft diferente?',
                $script:AppName,
                'YesNo',
                'Question'
            )
            if ($answer -eq 'Yes') {
                $oauth = Request-MicrosoftAuthorization
                if (-not $oauth) { return 'Canceled' }
                $libraries = @(Get-AccessibleLibraries $oauth)
            }
        }
        if ($libraries.Count -eq 0) {
            [Windows.Forms.MessageBox]::Show('Todas as bibliotecas encontradas já estão conectadas, ou sua conta não possui outra biblioteca disponível.', $script:AppName, 'OK', 'Information') | Out-Null
            return 'NoAvailable'
        }
        $accountName = Get-TokenAccountName ([string]$oauth.Data.access_token)
        if ($script:AccountLabel) {
            $script:AccountLabel.Text = if ($accountName) { 'Conta Microsoft: ' + $accountName } else { 'Conta Microsoft autorizada' }
        }
        $mapping = Show-NewSharePointMappingDialog $libraries $accountName
        if (-not $mapping) { return 'Canceled' }

        $remoteName = 'spf-drive-' + ([Guid]::NewGuid().ToString('N').Substring(0, 16))
        $parameters = @{
            token = [string]$oauth.Json
            drive_id = [string]$mapping.Library.DriveId
            drive_type = 'documentLibrary'
            # Keep rclone's OneDrive best practice: session uploads for every
            # size avoid the extra version created by small single-part uploads.
            upload_cutoff = 'off'
        }
        Set-AppRemote '_spf-auth' $parameters
        New-AppRemote $remoteName $parameters
        try {
            $null = Invoke-ControllerRequest 'operations/list' @{
                fs = ($remoteName + ':')
                remote = ''
                opt = @{ dirsOnly = $true; noModTime = $true }
            } $script:Controller 45
        } catch {
            try { Remove-AppRemote $remoteName } catch {}
            throw
        }

        $profile = [pscustomobject]@{
            id = [Guid]::NewGuid().ToString('N')
            remote = $remoteName
            drive = [string]$mapping.DriveLetter
            label = [string]$mapping.Label
            autoMount = [bool]$mapping.AutoMount
            siteName = [string]$mapping.Library.SiteName
            libraryName = [string]$mapping.Library.LibraryName
            webUrl = [string]$mapping.Library.WebUrl
            driveId = [string]$mapping.Library.DriveId
        }
        $script:Profiles += $profile
        try {
            Save-Settings
            $profileSaved = $true
        } catch {
            $script:Profiles = @($script:Profiles | Where-Object { $_ -ne $profile })
            throw
        }
        $mounted = Start-Mount $profile
        if ($mounted) { return 'Connected' }
        return 'AddedOffline'
    } catch [OperationCanceledException] {
        if ($remoteName -and -not $profileSaved) { try { Remove-AppRemote $remoteName } catch {} }
        return 'Canceled'
    } catch {
        if ($remoteName -and -not $profileSaved) { try { Remove-AppRemote $remoteName } catch {} }
        Show-FriendlyError 'Não foi possível conectar' 'Não foi possível concluir a conexão com o SharePoint. Verifique sua internet e as permissões da conta.' $_
        return 'Failed'
    } finally {
        $oauth = $null
    }
}

function Sync-ProfileMetadataFromConfig {
    try {
        $config = Get-AppConfigDump
        $changed = $false
        foreach ($profile in $script:Profiles) {
            $remote = $config.PSObject.Properties[[string]$profile.remote]
            if ($remote -and -not $profile.driveId -and $remote.Value.drive_id) {
                $profile.driveId = [string]$remote.Value.drive_id
                $changed = $true
            }
        }
        if ($changed) { Save-Settings }
    } catch { Write-AppLog 'WARN' ('Metadados antigos não puderam ser completados: ' + $_.Exception.Message) }
}

function Repair-SharePointRemoteTargets {
    $repairable = @($script:Profiles | Where-Object { $_.remote -and $_.driveId })
    if ($repairable.Count -eq 0) { return }

    try {
        $config = Get-AppConfigDump
        # Migrate remotes created by 1.1.2. Updating this backend option does
        # not disturb an active VFS; it is applied on the next mount.
        $uploadPolicyRemotes = @($repairable | Where-Object {
            $remote = $config.PSObject.Properties[[string]$_.remote]
            $remote -and [string]$remote.Value.upload_cutoff -ne 'off'
        })
        foreach ($profile in $uploadPolicyRemotes) {
            Set-AppRemote ([string]$profile.remote) @{ upload_cutoff = 'off' }
            Write-AppLog 'INFO' ('Política de upload da unidade {0}: atualizada para sessões OneDrive.' -f $profile.drive)
        }
        $authRemote = $config.PSObject.Properties['_spf-auth']
        if ($authRemote -and [string]$authRemote.Value.upload_cutoff -ne 'off') {
            Set-AppRemote '_spf-auth' @{ upload_cutoff = 'off' }
        }
        if ($uploadPolicyRemotes.Count -gt 0 -or ($authRemote -and [string]$authRemote.Value.upload_cutoff -ne 'off')) {
            $config = Get-AppConfigDump
        }
        $pending = @($repairable | Where-Object {
            $remote = $config.PSObject.Properties[[string]$_.remote]
            -not $remote -or
                [string]$remote.Value.drive_id -ne [string]$_.driveId -or
                [string]$remote.Value.drive_type -ne 'documentLibrary'
        })
        if ($pending.Count -eq 0) { return }

        $oauth = Get-CachedOAuthToken
        if (-not $oauth) {
            Write-AppLog 'WARN' 'Há unidades com destino incorreto, mas a autorização Microsoft precisa ser renovada antes do reparo.'
            return
        }

        $activeMounts = @(Get-ActiveMounts)
        foreach ($profile in $pending) {
            $wasMounted = Test-ExactMount $profile $activeMounts
            if ($wasMounted -and -not (Stop-Mount $profile -Quiet)) {
                Write-AppLog 'WARN' ('O destino de {0}: não foi alterado porque a unidade não pôde ser desmontada com segurança.' -f $profile.drive)
                continue
            }
            $parameters = @{
                token = [string]$oauth.Json
                drive_id = [string]$profile.driveId
                drive_type = 'documentLibrary'
                upload_cutoff = 'off'
            }
            Set-AppRemote ([string]$profile.remote) $parameters
            Write-AppLog 'INFO' ('Destino da unidade {0}: reparado para a biblioteca SharePoint salva no perfil.' -f $profile.drive)
            if ($wasMounted) { [void](Start-Mount $profile -Quiet) }
        }

        # Keep one protected token cache for adding another library without a
        # new browser authorization. It points to a known SharePoint drive and
        # is never mounted by the user.
        $first = @($repairable | Select-Object -First 1)
        if ($first.Count -gt 0) {
            Set-AppRemote '_spf-auth' @{
                token = [string]$oauth.Json
                drive_id = [string]$first[0].driveId
                drive_type = 'documentLibrary'
                upload_cutoff = 'off'
            }
        }
    } catch {
        Write-AppLog 'ERROR' ('Não foi possível reparar automaticamente os destinos SharePoint: ' + $_.Exception.Message)
    }
}

function Get-AccountNameFromConfig {
    try {
        $config = Get-AppConfigDump
        $auth = $config.PSObject.Properties['_spf-auth']
        if (-not $auth -or -not $auth.Value.token) { return '' }
        $token = [string]$auth.Value.token | ConvertFrom-Json
        return Get-TokenAccountName ([string]$token.access_token)
    } catch { return '' }
}

function New-MainButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [bool]$Primary = $false)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object Drawing.Point($X, $Y)
    $button.Size = New-Object Drawing.Size($Width, 36)
    $button.Anchor = 'Bottom,Left'
    Set-DialogButtonStyle $button $Primary
    return $button
}

function Build-MainForm {
    $form = New-Object Windows.Forms.Form
    $script:MainForm = $form
    $form.Text = $script:AppName
    $form.Size = New-Object Drawing.Size(980, 730)
    $form.MinimumSize = New-Object Drawing.Size(980, 650)
    $form.StartPosition = 'CenterScreen'
    $form.ShowIcon = $false
    $form.BackColor = $script:Colors.Canvas
    $form.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $form.AutoScaleMode = 'Dpi'

    $header = New-Object Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 112
    $header.BackColor = $script:Colors.Navy
    $form.Controls.Add($header)

    $logo = New-Object Windows.Forms.Panel
    $logo.Location = New-Object Drawing.Point(24, 25)
    $logo.Size = New-Object Drawing.Size(58, 58)
    $logo.BackColor = $script:Colors.PaleTeal
    $header.Controls.Add($logo)
    $logoText = New-Object Windows.Forms.Label
    $logoText.Text = 'S:'
    $logoText.Font = New-Object Drawing.Font('Segoe UI Semibold', 18)
    $logoText.ForeColor = $script:Colors.Teal
    $logoText.TextAlign = 'MiddleCenter'
    $logoText.Dock = 'Fill'
    $logo.Controls.Add($logoText)

    $title = New-Object Windows.Forms.Label
    $title.Text = 'SharePoint Fácil'
    $title.Font = New-Object Drawing.Font('Segoe UI Semibold', 20)
    $title.ForeColor = [Drawing.Color]::White
    $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point(99, 23)
    $header.Controls.Add($title)
    $subtitle = New-Object Windows.Forms.Label
    $subtitle.Text = 'Suas bibliotecas no Explorador de Arquivos'
    $subtitle.ForeColor = [Drawing.Color]::FromArgb(205, 229, 231)
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object Drawing.Point(102, 63)
    $header.Controls.Add($subtitle)

    $script:ConnectButton = New-Object Windows.Forms.Button
    $script:ConnectButton.Text = '+  Conectar biblioteca'
    $script:ConnectButton.Location = New-Object Drawing.Point(753, 37)
    $script:ConnectButton.Size = New-Object Drawing.Size(190, 39)
    $script:ConnectButton.Anchor = 'Top,Right'
    $script:ConnectButton.FlatStyle = 'Flat'
    $script:ConnectButton.FlatAppearance.BorderSize = 0
    $script:ConnectButton.BackColor = [Drawing.Color]::White
    $script:ConnectButton.ForeColor = $script:Colors.Teal
    $script:ConnectButton.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
    $script:ConnectButton.Cursor = [Windows.Forms.Cursors]::Hand
    $script:ConnectButton.AccessibleName = 'Conectar uma biblioteca do SharePoint'
    $header.Controls.Add($script:ConnectButton)
    # The WinFsp FLOSS exception requires its notice and repository link in the UI.
    $aboutLink = New-Object Windows.Forms.LinkLabel
    $aboutLink.Text = 'Sobre e licenças'
    $aboutLink.AutoSize = $true
    $aboutLink.Location = New-Object Drawing.Point(838, 84)
    $aboutLink.Anchor = 'Top,Right'
    $aboutLink.LinkColor = [Drawing.Color]::FromArgb(205, 229, 231)
    $aboutLink.ActiveLinkColor = [Drawing.Color]::White
    $aboutLink.add_LinkClicked({
        $notice = "$($script:AppName) $($script:AppVersion) - licença MIT`n`n" +
            "rclone - https://rclone.org`nCopyright (C) Nick Craig-Wood. Licença MIT.`n`n" +
            "WinFsp - Windows File System Proxy, Copyright (C) Bill Zissimopoulos`nhttps://github.com/winfsp/winfsp`n`n" +
            "Avisos completos: THIRD-PARTY-NOTICES.txt na pasta de instalação.`n`n" +
            'Abrir o repositório do WinFsp?'
        if ([Windows.Forms.MessageBox]::Show($notice, $script:AppName, 'YesNo', 'Information') -eq 'Yes') {
            Open-DocumentUri 'https://github.com/winfsp/winfsp'
        }
    })
    $header.Controls.Add($aboutLink)

    $sectionTitle = New-Object Windows.Forms.Label
    $sectionTitle.Text = 'Suas unidades'
    $sectionTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 13)
    $sectionTitle.ForeColor = $script:Colors.Ink
    $sectionTitle.AutoSize = $true
    $sectionTitle.Location = New-Object Drawing.Point(24, 132)
    $form.Controls.Add($sectionTitle)
    $script:CountLabel = New-Object Windows.Forms.Label
    $script:CountLabel.ForeColor = $script:Colors.Muted
    $script:CountLabel.AutoSize = $true
    $script:CountLabel.Location = New-Object Drawing.Point(215, 138)
    $form.Controls.Add($script:CountLabel)

    $script:Grid = New-Object Windows.Forms.DataGridView
    $script:Grid.Location = New-Object Drawing.Point(24, 164)
    $script:Grid.Size = New-Object Drawing.Size(919, 318)
    $script:Grid.Anchor = 'Top,Bottom,Left,Right'
    $script:Grid.AllowUserToAddRows = $false
    $script:Grid.AllowUserToDeleteRows = $false
    $script:Grid.AllowUserToResizeRows = $false
    $script:Grid.AllowUserToResizeColumns = $true
    $script:Grid.MultiSelect = $false
    $script:Grid.SelectionMode = 'FullRowSelect'
    $script:Grid.RowHeadersVisible = $false
    $script:Grid.AutoGenerateColumns = $false
    $script:Grid.ReadOnly = $true
    $script:Grid.BackgroundColor = $script:Colors.Surface
    $script:Grid.BorderStyle = 'FixedSingle'
    $script:Grid.CellBorderStyle = 'SingleHorizontal'
    $script:Grid.GridColor = $script:Colors.Border
    $script:Grid.EnableHeadersVisualStyles = $false
    $script:Grid.ColumnHeadersHeight = 38
    $script:Grid.ColumnHeadersBorderStyle = 'None'
    $script:Grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(238, 244, 246)
    $script:Grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:Colors.Muted
    $script:Grid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
    $script:Grid.DefaultCellStyle.BackColor = $script:Colors.Surface
    $script:Grid.DefaultCellStyle.ForeColor = $script:Colors.Ink
    $script:Grid.DefaultCellStyle.SelectionBackColor = $script:Colors.PaleTeal
    $script:Grid.DefaultCellStyle.SelectionForeColor = $script:Colors.Ink
    $script:Grid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(5, 0, 5, 0)
    $script:Grid.RowTemplate.Height = 46
    $script:Grid.AccessibleName = 'Unidades do SharePoint conectadas'

    $columns = @(
        @{ Name = 'Status'; Header = 'ESTADO'; Width = 125; Fill = $false; Check = $false },
        @{ Name = 'Drive'; Header = 'UNIDADE'; Width = 78; Fill = $false; Check = $false },
        @{ Name = 'Label'; Header = 'NOME'; Width = 200; Fill = $false; Check = $false },
        @{ Name = 'Site'; Header = 'SITE'; Width = 180; Fill = $true; Check = $false },
        @{ Name = 'Library'; Header = 'BIBLIOTECA'; Width = 165; Fill = $false; Check = $false },
        @{ Name = 'Auto'; Header = 'NO LOGON'; Width = 88; Fill = $false; Check = $true }
    )
    foreach ($definition in $columns) {
        if ($definition.Check) { $column = New-Object Windows.Forms.DataGridViewCheckBoxColumn }
        else { $column = New-Object Windows.Forms.DataGridViewTextBoxColumn }
        $column.Name = $definition.Name
        $column.HeaderText = $definition.Header
        $column.Width = $definition.Width
        $column.ReadOnly = $true
        if ($definition.Fill) { $column.AutoSizeMode = 'Fill' }
        [void]$script:Grid.Columns.Add($column)
    }
    $form.Controls.Add($script:Grid)

    $script:EmptyPanel = New-Object Windows.Forms.Panel
    $script:EmptyPanel.Location = New-Object Drawing.Point(24, 164)
    $script:EmptyPanel.Size = New-Object Drawing.Size(919, 318)
    $script:EmptyPanel.Anchor = 'Top,Bottom,Left,Right'
    $script:EmptyPanel.BackColor = $script:Colors.Surface
    $script:EmptyPanel.BorderStyle = 'FixedSingle'
    $emptyMark = New-Object Windows.Forms.Label
    $emptyMark.Text = 'S:'
    $emptyMark.Font = New-Object Drawing.Font('Segoe UI Semibold', 24)
    $emptyMark.ForeColor = $script:Colors.Teal
    $emptyMark.TextAlign = 'MiddleCenter'
    $emptyMark.Size = New-Object Drawing.Size(70, 55)
    $emptyMark.Location = New-Object Drawing.Point(424, 58)
    $emptyMark.Anchor = 'Top'
    $script:EmptyPanel.Controls.Add($emptyMark)
    $emptyTitle = New-Object Windows.Forms.Label
    $emptyTitle.Text = 'Nenhuma biblioteca conectada'
    $emptyTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 13)
    $emptyTitle.ForeColor = $script:Colors.Ink
    $emptyTitle.TextAlign = 'MiddleCenter'
    $emptyTitle.Size = New-Object Drawing.Size(500, 30)
    $emptyTitle.Location = New-Object Drawing.Point(209, 120)
    $emptyTitle.Anchor = 'Top'
    $script:EmptyPanel.Controls.Add($emptyTitle)
    $emptyText = New-Object Windows.Forms.Label
    $emptyText.Text = 'Conecte uma biblioteca para acessá-la como uma unidade no Explorador.'
    $emptyText.ForeColor = $script:Colors.Muted
    $emptyText.TextAlign = 'MiddleCenter'
    $emptyText.Size = New-Object Drawing.Size(600, 42)
    $emptyText.Location = New-Object Drawing.Point(159, 154)
    $emptyText.Anchor = 'Top'
    $script:EmptyPanel.Controls.Add($emptyText)
    $emptyButton = New-Object Windows.Forms.Button
    $emptyButton.Text = 'Conectar biblioteca'
    $emptyButton.Size = New-Object Drawing.Size(245, 38)
    $emptyButton.Location = New-Object Drawing.Point(336, 212)
    $emptyButton.Anchor = 'Top'
    Set-DialogButtonStyle $emptyButton $true
    $script:EmptyPanel.Controls.Add($emptyButton)
    $form.Controls.Add($script:EmptyPanel)
    $script:EmptyPanel.BringToFront()

    $script:EditButton = New-MainButton 'Editar' 24 500 82 $false
    $script:RemoveButton = New-MainButton 'Remover' 113 500 92 $false
    $script:RefreshButton = New-MainButton 'Atualizar' 212 500 92 $false
    foreach ($button in @($script:EditButton, $script:RemoveButton, $script:RefreshButton)) { $form.Controls.Add($button) }

    $script:OpenButton = New-MainButton 'Abrir pasta' 833 500 110 $true
    $script:OpenButton.Anchor = 'Bottom,Right'
    $script:UnmountButton = New-MainButton 'Desmontar' 723 500 102 $false
    $script:UnmountButton.Anchor = 'Bottom,Right'
    $script:MountButton = New-MainButton 'Montar' 833 500 110 $true
    $script:MountButton.Anchor = 'Bottom,Right'
    foreach ($button in @($script:MountButton, $script:UnmountButton, $script:OpenButton)) { $form.Controls.Add($button) }

    $script:ExclusiveButton = New-MainButton 'Reservar e abrir' 24 550 170 $false
    $script:CoauthorButton = New-MainButton 'Abrir para coautoria' 204 550 190 $false
    $script:WebButton = New-MainButton 'Abrir no SharePoint' 404 550 185 $false
    $script:ReservationsButton = New-MainButton 'Reservas / concluir' 599 550 185 $false
    foreach ($button in @($script:ExclusiveButton, $script:CoauthorButton, $script:WebButton, $script:ReservationsButton)) { $form.Controls.Add($button) }
    $documentHint = New-Object Windows.Forms.Label
    $documentHint.Text = 'A unidade continua gravável. A reserva vale para o arquivo escolhido; a edição direta pela unidade não passa por este controle. Use a mesma conta no Office e evite abrir outra cópia local durante a edição online.'
    $documentHint.Location = New-Object Drawing.Point(24, 594)
    $documentHint.Size = New-Object Drawing.Size(919, 44)
    $documentHint.Anchor = 'Bottom,Left,Right'
    $documentHint.ForeColor = $script:Colors.Warning
    $form.Controls.Add($documentHint)

    $script:ExclusiveButton.Add_Click({
        if (-not (Begin-UiAction)) { return }
        try { Show-DocumentPicker 'Exclusive' } finally { End-UiAction }
    })
    $script:CoauthorButton.Add_Click({
        if (-not (Begin-UiAction)) { return }
        try { Show-DocumentPicker 'Coauthor' } finally { End-UiAction }
    })
    $script:WebButton.Add_Click({
        if (-not (Begin-UiAction)) { return }
        try {
            $profile = & $script:GetSelectedProfile
            if ($profile) { Show-DocumentAction 'SharePoint' ($profile.drive + ':\') }
        } finally { End-UiAction }
    })
    $script:ReservationsButton.Add_Click({
        if (-not (Begin-UiAction)) { return }
        try { Show-DocumentReservations }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, $script:AppName) | Out-Null }
        finally { End-UiAction }
    })

    $statusPanel = New-Object Windows.Forms.Panel
    $statusPanel.Dock = 'Bottom'
    $statusPanel.Height = 52
    $statusPanel.BackColor = $script:Colors.Surface
    $statusPanel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($statusPanel)
    $script:StatusDot = New-Object Windows.Forms.Label
    $script:StatusDot.Text = '●'
    $script:StatusDot.Font = New-Object Drawing.Font('Segoe UI', 11)
    $script:StatusDot.ForeColor = $script:Colors.Success
    $script:StatusDot.AutoSize = $true
    $script:StatusDot.Location = New-Object Drawing.Point(23, 14)
    $statusPanel.Controls.Add($script:StatusDot)
    $script:StatusLabel = New-Object Windows.Forms.Label
    $script:StatusLabel.Text = 'Pronto para conectar'
    $script:StatusLabel.ForeColor = $script:Colors.Ink
    $script:StatusLabel.AutoSize = $true
    $script:StatusLabel.Location = New-Object Drawing.Point(47, 16)
    $statusPanel.Controls.Add($script:StatusLabel)
    $script:AccountLabel = New-Object Windows.Forms.Label
    $script:AccountLabel.ForeColor = $script:Colors.Muted
    $script:AccountLabel.TextAlign = 'MiddleRight'
    $script:AccountLabel.Location = New-Object Drawing.Point(560, 10)
    $script:AccountLabel.Size = New-Object Drawing.Size(380, 28)
    $script:AccountLabel.Anchor = 'Top,Right'
    $statusPanel.Controls.Add($script:AccountLabel)

    $toolTip = New-Object Windows.Forms.ToolTip
    $toolTip.SetToolTip($script:ConnectButton, 'Mostra todas as bibliotecas disponíveis para sua conta Microsoft.')
    $toolTip.SetToolTip($script:MountButton, 'Mostra a unidade no Explorador de Arquivos.')
    $toolTip.SetToolTip($script:UnmountButton, 'Conclui os envios e remove a letra do Explorador.')
    $toolTip.SetToolTip($script:RemoveButton, 'Remove apenas a conexão deste computador. Os arquivos no SharePoint são preservados.')
    $toolTip.SetToolTip($script:RefreshButton, 'Atualiza o estado e descarta a listagem antiga para buscar as mudanças do SharePoint.')

    $script:SetStatus = {
        param([string]$Text, [Drawing.Color]$Color = $script:Colors.Success)
        $script:StatusLabel.Text = $Text
        $script:StatusDot.ForeColor = $Color
        [Windows.Forms.Application]::DoEvents()
    }

    $script:GetSelectedProfile = {
        if ($script:Grid.SelectedRows.Count -eq 0) { return $null }
        return $script:Grid.SelectedRows[0].Tag
    }

    $script:UpdateActions = {
        $profile = & $script:GetSelectedProfile
        $hasSelection = $null -ne $profile
        $hasProfiles = $script:Profiles.Count -gt 0
        $state = if ($hasSelection) { [string]$script:Grid.SelectedRows[0].Cells['Status'].Tag } else { '' }
        $script:EditButton.Enabled = $hasSelection -and -not $script:IsBusy
        $script:RemoveButton.Enabled = $hasSelection -and -not $script:IsBusy
        $script:EditButton.Visible = $hasProfiles
        $script:RemoveButton.Visible = $hasProfiles
        $script:RefreshButton.Visible = $hasProfiles
        $script:MountButton.Enabled = $hasSelection -and $state -eq 'Stopped' -and -not $script:IsBusy
        $script:UnmountButton.Enabled = $hasSelection -and $state -eq 'Mounted' -and -not $script:IsBusy
        $script:OpenButton.Enabled = $hasSelection -and $state -eq 'Mounted' -and -not $script:IsBusy
        $script:MountButton.Visible = $hasSelection -and $state -eq 'Stopped'
        $script:UnmountButton.Visible = $hasSelection -and $state -eq 'Mounted'
        $script:OpenButton.Visible = $hasSelection -and $state -eq 'Mounted'
        $script:ExclusiveButton.Enabled = $hasSelection -and $state -eq 'Mounted' -and -not $script:IsBusy
        $script:CoauthorButton.Enabled = $script:ExclusiveButton.Enabled
        $script:WebButton.Enabled = $hasSelection -and -not $script:IsBusy
        $script:ReservationsButton.Enabled = -not $script:IsBusy
        try {
            $count = @(Read-DocumentReservations).Count
            $script:ReservationsButton.Text = 'Reservas / concluir (' + $count + ')'
        } catch { $script:ReservationsButton.Text = 'Reservas: verificar' }
    }

    $script:RefreshGrid = {
        $selectedId = ''
        $selected = & $script:GetSelectedProfile
        if ($selected) { $selectedId = [string]$selected.id }
        $mounts = Get-ActiveMounts
        $script:Grid.Rows.Clear()
        foreach ($profile in $script:Profiles) {
            $state = Get-ProfileMountState $profile $mounts
            $statusText = switch ($state) {
                'Mounted' { 'Conectada' }
                'Conflict' { 'Letra em uso' }
                default { 'Desconectada' }
            }
            if ($state -eq 'Mounted') {
                try {
                    $stats = Invoke-ControllerRequest 'vfs/stats' @{ fs = ($profile.remote + ':') } $script:Controller 2
                    $pending = [int]$stats.diskCache.uploadsQueued + [int]$stats.diskCache.uploadsInProgress
                    if ($pending -gt 0) { $statusText = 'Enviando (' + $pending + ')' }
                } catch {}
            }
            $siteText = if ($profile.siteName) { $profile.siteName } else { 'SharePoint' }
            $libraryText = if ($profile.libraryName) { $profile.libraryName } else { $profile.label }
            $rowIndex = $script:Grid.Rows.Add($statusText, ($profile.drive + ':'), $profile.label, $siteText, $libraryText, $profile.autoMount)
            $row = $script:Grid.Rows[$rowIndex]
            $row.Tag = $profile
            $row.Cells['Status'].Tag = $state
            if ($state -eq 'Mounted') { $row.Cells['Status'].Style.ForeColor = $script:Colors.Success }
            elseif ($state -eq 'Conflict') { $row.Cells['Status'].Style.ForeColor = $script:Colors.Danger }
            else { $row.Cells['Status'].Style.ForeColor = $script:Colors.Muted }
            if ([string]$profile.id -eq $selectedId) { $row.Selected = $true }
        }
        $count = $script:Profiles.Count
        $script:CountLabel.Text = if ($count -eq 1) { '1 biblioteca' } else { '{0} bibliotecas' -f $count }
        $script:EmptyPanel.Visible = $count -eq 0
        if ($script:EmptyPanel.Visible) { $script:EmptyPanel.BringToFront() } else { $script:Grid.BringToFront() }
        & $script:UpdateActions
    }

    $connectAction = {
        if (-not (Begin-UiAction)) { return }
        try {
            & $script:SetStatus 'Localizando suas bibliotecas...' $script:Colors.Teal
            $result = Add-SharePointLibrary
            if ($result -eq 'Connected' -or $result -eq 'AddedOffline') { & $script:RefreshGrid }
            switch ($result) {
                'Connected' { & $script:SetStatus 'Biblioteca conectada e pronta para usar' $script:Colors.Success }
                'AddedOffline' { & $script:SetStatus 'Biblioteca adicionada; tente montar novamente' $script:Colors.Warning }
                'Failed' { & $script:SetStatus 'A conexão não foi concluída' $script:Colors.Danger }
                default { & $script:SetStatus 'Pronto para conectar' $script:Colors.Success }
            }
        } finally { End-UiAction }
    }
    $script:ConnectButton.Add_Click($connectAction)
    $emptyButton.Add_Click($connectAction)

    $script:MountButton.Add_Click({
        if (-not (Begin-UiAction)) { return }
        try {
            $profile = & $script:GetSelectedProfile
            if (-not $profile) { return }
            & $script:SetStatus ('Conectando {0}:...' -f $profile.drive) $script:Colors.Teal
            $mounted = Start-Mount $profile
            & $script:RefreshGrid
            if ($mounted) { & $script:SetStatus ('Unidade {0}: conectada' -f $profile.drive) $script:Colors.Success }
            else { & $script:SetStatus ('A unidade {0}: continua desconectada' -f $profile.drive) $script:Colors.Danger }
        } finally { End-UiAction }
    })

    $script:UnmountButton.Add_Click({
        if (-not (Begin-UiAction)) { return }
        try {
            $profile = & $script:GetSelectedProfile
            if (-not $profile) { return }
            & $script:SetStatus ('Concluindo alterações em {0}:...' -f $profile.drive) $script:Colors.Teal
            $unmounted = Stop-Mount $profile
            & $script:RefreshGrid
            if ($unmounted) { & $script:SetStatus ('Unidade {0}: desmontada com segurança' -f $profile.drive) $script:Colors.Success }
            else { & $script:SetStatus ('A unidade {0}: foi mantida conectada' -f $profile.drive) $script:Colors.Warning }
        } finally { End-UiAction }
    })

    $script:OpenButton.Add_Click({
        $profile = & $script:GetSelectedProfile
        if ($profile -and (Get-ProfileMountState $profile (Get-ActiveMounts)) -eq 'Mounted') {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ($profile.drive + ':\')
        }
    })

    $script:EditButton.Add_Click({
        if (-not (Begin-UiAction)) { return }
        try {
            $profile = & $script:GetSelectedProfile
            if (-not $profile) { return }
            $changes = Show-EditProfileDialog $profile
            if (-not $changes) { return }
            $mountState = Get-ProfileMountState $profile (Get-ActiveMounts)
            $needsRestart = $mountState -eq 'Mounted' -and ($changes.Drive -ne $profile.drive -or $changes.Label -ne $profile.label)
            if ($needsRestart) {
                $answer = [Windows.Forms.MessageBox]::Show('A unidade será desmontada com segurança e reconectada para aplicar as alterações. Continuar?', $script:AppName, 'YesNo', 'Question')
                if ($answer -ne 'Yes' -or -not (Stop-Mount $profile)) { return }
            }
            $profile.drive = $changes.Drive
            $profile.label = $changes.Label
            $profile.autoMount = $changes.AutoMount
            Save-Settings
            if ($needsRestart) { [void](Start-Mount $profile) }
            & $script:RefreshGrid
        } finally { End-UiAction }
    })

    $script:RemoveButton.Add_Click({
        if (-not (Begin-UiAction)) { return }
        try {
            $profile = & $script:GetSelectedProfile
            if (-not $profile) { return }
            if (@(Read-DocumentReservations | Where-Object { $_.profileId -eq $profile.id }).Count -gt 0) {
                [Windows.Forms.MessageBox]::Show('Conclua ou confira as reservas desta biblioteca antes de remover a conexão.', $script:AppName, 'OK', 'Warning') | Out-Null
                return
            }
            $description = if ($profile.siteName -and $profile.libraryName) { $profile.siteName + ' · ' + $profile.libraryName } else { $profile.label }
            $message = 'Remover a unidade ' + $profile.drive + ': deste computador?' + [Environment]::NewLine + [Environment]::NewLine + $description + [Environment]::NewLine + [Environment]::NewLine + 'Os arquivos no SharePoint serão preservados.'
            $answer = [Windows.Forms.MessageBox]::Show($message, $script:AppName, 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
            $mountState = Get-ProfileMountState $profile (Get-ActiveMounts -ThrowOnError)
            $cachePaths = if ($mountState -eq 'Mounted') { @(Get-SafeVfsCachePaths $profile) } else { @((Get-ProfileVfsCacheInfo $profile).Paths) }
            if (-not (Stop-Mount $profile)) { return }
            $finalCacheInfo = Get-ProfileVfsCacheInfo $profile
            if ($finalCacheInfo.IsDirty -or $finalCacheInfo.IsUncertain) {
                throw 'O cache local ainda contém uma alteração não confirmada. A conexão foi preservada.'
            }
            $cachePaths = @($finalCacheInfo.Paths)
            $otherUsers = @($script:Profiles | Where-Object { $_ -ne $profile -and $_.remote -eq $profile.remote })
            $previousProfiles = @($script:Profiles)
            $script:Profiles = @($previousProfiles | Where-Object { $_ -ne $profile })
            try { Save-Settings }
            catch {
                $script:Profiles = $previousProfiles
                throw
            }
            if ($otherUsers.Count -eq 0) {
                try { Remove-AppRemote $profile.remote }
                catch { Write-AppLog 'WARN' ('A configuração técnica antiga será limpa em uma próxima manutenção: ' + $_.Exception.Message) }
                Remove-SafeVfsCachePaths $cachePaths
            }
            & $script:RefreshGrid
            Stop-ControllerIfIdle
            & $script:SetStatus 'Unidade removida deste computador' $script:Colors.Success
        } catch {
            Show-FriendlyError 'Não foi possível remover' 'A conexão foi mantida para que você possa tentar novamente.' $_
        } finally { End-UiAction }
    })

    $script:RefreshButton.Add_Click({
        if (-not (Begin-UiAction)) { return }
        try {
            $profile = & $script:GetSelectedProfile
            if ($profile -and (Get-ProfileMountState $profile (Get-ActiveMounts -ThrowOnError)) -eq 'Mounted') {
                & $script:SetStatus ('Atualizando {0}:...' -f $profile.drive) $script:Colors.Teal
                Assert-DocumentCacheClean $profile
                $null = Invoke-ControllerRequest 'vfs/forget' @{ fs = ($profile.remote + ':') } $script:Controller 8
                Notify-ProfileExplorerViews $profile
            }
            & $script:RefreshGrid
            & $script:SetStatus 'Conteúdo e estado atualizados' $script:Colors.Success
        } catch {
            Write-AppLog 'ERROR' ('Falha ao atualizar a unidade: ' + $_.Exception.Message)
            Show-FriendlyError 'Não foi possível atualizar' 'A listagem antiga foi preservada para proteger alterações locais.' $_
        } finally { End-UiAction }
    })
    $script:Grid.Add_SelectionChanged({ & $script:UpdateActions })
    $script:Grid.Add_CellDoubleClick({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -lt 0) { return }
        if ($script:OpenButton.Enabled) { $script:OpenButton.PerformClick() }
        elseif ($script:MountButton.Enabled) { $script:MountButton.PerformClick() }
    })

    $script:RefreshTimer = New-Object Windows.Forms.Timer
    $script:RefreshTimer.Interval = 4000
    $script:RefreshTimer.Add_Tick({ if (-not $script:IsBusy) { & $script:RefreshGrid } })
    $script:RefreshTimer.Start()
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:IsBusy) { $eventArgs.Cancel = $true; return }
        if ($script:RefreshTimer) { $script:RefreshTimer.Stop() }
    })
    $form.Add_FormClosed({
        if ($script:RefreshTimer) {
            $script:RefreshTimer.Dispose()
            $script:RefreshTimer = $null
        }
        Stop-ControllerIfIdle
    })

    $accountName = Get-AccountNameFromConfig
    $script:AccountLabel.Text = if ($accountName) { 'Conta Microsoft: ' + $accountName } else { 'Conta Microsoft será solicitada ao conectar' }
    & $script:RefreshGrid
    return $form
}

function Invoke-AutoMount {
    if (-not (Test-WinFspInstalled)) {
        Write-AppLog 'ERROR' 'WinFsp ausente ou parado durante a reconexão automática.'
        return 3
    }
    $pending = @($script:Profiles | Where-Object { $_.autoMount })
    foreach ($delay in @(0, 5, 15, 30)) {
        if ($pending.Count -eq 0) { break }
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        foreach ($profile in @($pending)) {
            if (Start-Mount $profile -Quiet) {
                $pending = @($pending | Where-Object { $_.id -ne $profile.id })
            }
        }
    }
    foreach ($profile in $pending) {
        Write-AppLog 'ERROR' ('Não foi possível reconectar automaticamente {0}:.' -f $profile.drive)
    }
    if ($pending.Count -eq 0) { return 0 }
    return 4
}

function Invoke-SelfTest {
    $profile = $null
    $openHandle = $null
    try {
        Initialize-AppConfig
        $null = Start-Controller
        if ((Get-AppRemoteConfigurationAnswer ([pscustomobject]@{ Option = [pscustomobject]@{ Name = 'config_refresh_token' } }) @{ drive_id = 'test-drive' }) -ne 'false') { throw 'A reutilização do token não está protegida.' }
        if ((Get-AppRemoteConfigurationAnswer ([pscustomobject]@{ Option = [pscustomobject]@{ Name = 'config_type' } }) @{ drive_id = 'test-drive' }) -ne 'driveid') { throw 'O tipo de destino SharePoint não está protegido.' }
        if ((Get-AppRemoteConfigurationAnswer ([pscustomobject]@{ Option = [pscustomobject]@{ Name = 'config_driveid' } }) @{ drive_id = 'test-drive' }) -ne 'test-drive') { throw 'O ID da biblioteca não está protegido.' }
        New-AppRemote -Name '_spf-selftest' -Parameters @{} -Type 'local'
        $dump = Get-AppConfigDump
        if (-not $dump.PSObject.Properties['_spf-selftest']) { throw 'A configuração protegida não aceitou gravação.' }
        Assert-RcloneConfigEncryption ($script:RcloneConfigFile + '.bak')

        $savedController = Read-ControllerState
        if (-not $savedController -or -not $savedController.compatible) {
            throw 'O estado atual do controlador não foi vinculado à chave da configuração.'
        }
        $oldControllerPid = [int]$script:Controller.pid
        $legacyState = [ordered]@{
            version = 1
            pid = $oldControllerPid
            port = [int]$script:Controller.port
            baseUrl = [string]$script:Controller.baseUrl
            secret = Protect-LocalSecret ([string]$script:Controller.password)
        }
        Write-AtomicText $script:ControllerFile ($legacyState | ConvertTo-Json -Depth 4)
        $script:Controller = $null
        $replacementController = Start-Controller
        if ([int]$replacementController.pid -eq $oldControllerPid) {
            throw 'O controlador incompatível foi reutilizado no teste.'
        }
        $dump = Get-AppConfigDump
        if (-not $dump.PSObject.Properties['_spf-selftest']) {
            throw 'A configuração se perdeu ao substituir o controlador incompatível.'
        }
        Remove-AppRemote '_spf-selftest'

        # Exercise the on-disk Dirty parser independently of backend timing.
        $syntheticMeta = Join-Path $script:CacheDir '_selftest-dirty-meta'
        [IO.Directory]::CreateDirectory($syntheticMeta) | Out-Null
        [IO.File]::WriteAllText((Join-Path $syntheticMeta 'arquivo.json'), '{"Dirty":true}', [Text.Encoding]::UTF8)
        $syntheticHealth = Get-VfsMetadataHealth $syntheticMeta ''
        if (-not $syntheticHealth.IsDirty) { throw 'A validação de metadata Dirty não bloqueou o cache de teste.' }
        Remove-SafeVfsCachePaths @($syntheticMeta)

        $drive = @(Get-AvailableDriveLetters | Select-Object -First 1)
        if ($drive.Count -eq 0) { throw 'Não há letra livre para o teste.' }
        $profile = [pscustomobject]@{
            id = [Guid]::NewGuid().ToString('N')
            remote = ':memory'
            drive = [string]$drive[0]
            label = 'SharePoint Fácil - teste'
            autoMount = $false
            siteName = 'Teste local'
            libraryName = 'Memória'
            webUrl = ''
            driveId = 'selftest'
        }
        if (-not (Start-Mount $profile -Quiet)) { throw 'A unidade de teste não foi montada.' }

        # Simulate the save pattern used by Office: an existing workbook is
        # replaced by a fully flushed temporary file and then renamed.
        $officePath = $profile.drive + ':\verificacao-office.xlsx'
        $temporaryPath = $profile.drive + ':\~verificacao-office.tmp'
        [IO.File]::WriteAllBytes($officePath, [Text.Encoding]::UTF8.GetBytes('versao-anterior'))
        if (-not (Wait-PendingUploads $profile -TimeoutSeconds 30 -Quiet)) { throw 'A versão inicial do teste Office não terminou de enviar.' }
        $replacement = [Text.Encoding]::UTF8.GetBytes('nova-versao-do-arquivo-office')
        $officeStream = [IO.File]::Open($temporaryPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try {
            $officeStream.Write($replacement, 0, $replacement.Length)
            $officeStream.Flush($true)
        } finally { $officeStream.Dispose() }
        Move-Item -LiteralPath $temporaryPath -Destination $officePath -Force
        if (-not (Wait-PendingUploads $profile -TimeoutSeconds 45 -Quiet)) { throw 'A substituição do teste Office não terminou de enviar.' }
        $remoteStat = Invoke-ControllerRequest 'operations/stat' @{ fs = ($profile.remote + ':'); remote = 'verificacao-office.xlsx' } $script:Controller 15
        if (-not $remoteStat.item -or [int64]$remoteStat.item.Size -ne [int64]$replacement.Length) {
            throw 'O arquivo substituído pelo padrão do Office não foi confirmado no remote.'
        }

        # A dirty file can still report uploadsQueued=0 while its handle is
        # open. The safe unmount must refuse this exact state.
        $dirtyPath = $profile.drive + ':\verificacao-aberta.tmp'
        $openHandle = [IO.File]::Open($dirtyPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        $dirtyBytes = New-Object byte[] (1MB)
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($dirtyBytes) } finally { $rng.Dispose() }
        $openHandle.Write($dirtyBytes, 0, $dirtyBytes.Length)
        $openHandle.Flush()
        $unsafeHandleObserved = $false
        $dirtyDeadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $dirtyDeadline) {
            $dirtyStats = Invoke-ControllerRequest 'vfs/stats' @{ fs = ($profile.remote + ':') } $script:Controller 8
            $dirtyCache = Get-ProfileVfsCacheInfo $profile $dirtyStats
            if ($dirtyCache.IsDirty -or [int]$dirtyStats.inUse -gt 0) { $unsafeHandleObserved = $true; break }
            Start-Sleep -Milliseconds 150
        }
        if (-not $unsafeHandleObserved) { throw 'O teste não detectou o arquivo aberto no VFS.' }
        if (Stop-Mount $profile -Quiet -TimeoutSeconds 3) { throw 'A unidade foi desmontada com um arquivo Dirty ainda aberto.' }
        if (-not (Test-ExactMount $profile (Get-ActiveMounts -ThrowOnError))) { throw 'A unidade não foi preservada após bloquear o arquivo aberto.' }
        $openHandle.Dispose()
        $openHandle = $null
        if (-not (Wait-PendingUploads $profile -TimeoutSeconds 45 -Quiet)) { throw 'O arquivo fechado não terminou de enviar.' }
        if (-not (Stop-Mount $profile -Quiet -TimeoutSeconds 45)) { throw 'A unidade de teste não foi desmontada.' }
        Stop-ControllerIfIdle
        return 0
    } catch {
        Write-AppLog 'ERROR' ('Self-test: ' + ($_ | Out-String))
        [Console]::Out.WriteLine('SELFTEST_DETAIL: ' + (Protect-LogMessage $_.Exception.Message))
        return 20
    } finally {
        if ($openHandle) { try { $openHandle.Dispose() } catch {}; $openHandle = $null }
        if ($profile) {
            try {
                if (-not (Stop-Mount $profile -Quiet -TimeoutSeconds 30) -and $script:Controller) {
                    $testMounts = @(Get-ActiveMounts -ThrowOnError)
                    if (Test-ExactMount $profile $testMounts) {
                        $null = Invoke-ControllerRequest 'mount/unmount' @{ mountPoint = ($profile.drive + ':') } $script:Controller 15
                    }
                }
            } catch {
                Write-AppLog 'WARN' ('A montagem isolada do autoteste exigiu limpeza forçada: ' + $_.Exception.Message)
            }
        }
        try { Stop-ControllerIfIdle } catch {}
        # The self-test owns an isolated controller and cache. Never leave that
        # helper alive after a failed assertion, even when its mount state could
        # not be queried. Production controllers keep their fail-closed behavior.
        if ($script:Controller) {
            $testControllerPid = [int]$script:Controller.pid
            try { $null = Invoke-ControllerRequest 'core/quit' @{} $script:Controller 3 } catch {}
            $quitDeadline = (Get-Date).AddSeconds(5)
            while ((Get-Date) -lt $quitDeadline -and (Get-Process -Id $testControllerPid -ErrorAction SilentlyContinue)) {
                Start-Sleep -Milliseconds 100
            }
            $testProcess = Get-Process -Id $testControllerPid -ErrorAction SilentlyContinue
            if ($testProcess) {
                try {
                    if ([IO.Path]::GetFullPath([string]$testProcess.Path) -eq [IO.Path]::GetFullPath($script:RclonePath)) {
                        $testProcess.Kill()
                        [void]$testProcess.WaitForExit(5000)
                    }
                } catch {}
            }
            if (-not (Get-Process -Id $testControllerPid -ErrorAction SilentlyContinue)) {
                $script:Controller = $null
                Remove-Item -LiteralPath $script:ControllerFile -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath ($script:ControllerFile + '.bak') -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$createdNew = $false
$mutexSuffix = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '-', '_')
if ($SelfTest) { $mutexSuffix += '-SelfTest' }
if ($DocumentAction) { $mutexSuffix += '-DocumentCommand' }
if ($ShellWatcher) { $mutexSuffix += '-ShellWatcher' }
$mutexName = 'Local\SharePointFacil-' + $mutexSuffix
$script:AppMutex = New-Object Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew -and $DocumentAction -eq 'Auto') {
    try { $createdNew = $script:AppMutex.WaitOne(60000) } catch [Threading.AbandonedMutexException] { $createdNew = $true }
    if (-not $createdNew) { try { Open-LocalDocument $DocumentPath } catch {}; exit 0 }
}
if (-not $createdNew) {
    if ($SelfTest) {
        [Console]::Out.WriteLine('SELFTEST_DETAIL: Já existe um autoteste em execução.')
        exit 21
    }
    if (-not $AutoMount -and -not $ShellWatcher) {
        $message = if ($DocumentAction) { 'Outra operação de documento está em andamento. Aguarde e tente novamente.' } else { 'O SharePoint Fácil já está aberto.' }
        [Windows.Forms.MessageBox]::Show($message, $script:AppName, 'OK', 'Information') | Out-Null
    }
    exit 0
}

$applicationExitCode = 0
try {
    Initialize-DataDirectories
    if (-not (Test-BundledRclone)) {
        Write-AppLog 'ERROR' 'O rclone integrado está ausente ou não corresponde à versão aprovada.'
        if (-not $AutoMount -and -not $ShellWatcher) { [Windows.Forms.MessageBox]::Show('A instalação está incompleta. Abra Aplicativos instalados no Windows e use Reparar no SharePoint Fácil.', $script:AppName, 'OK', 'Error') | Out-Null }
        $applicationExitCode = 2
    } elseif ($ShellWatcher) {
        if ($AutoMount -or $SelfTest -or $DocumentAction -or $DocumentPath) { throw 'O observador não aceita outras ações.' }
        if (Test-IsElevated) {
            Write-AppLog 'ERROR' 'Observador elevado bloqueado para preservar a sessão correta do Explorador.'
            $applicationExitCode = 5
        } else {
            $applicationExitCode = [int](Invoke-ShellWatcher)
        }
    } elseif ($SelfTest) {
        if (-not (Test-WinFspInstalled)) { $applicationExitCode = 3 }
        else {
            $applicationExitCode = [int](Invoke-SelfTest)
            if ($applicationExitCode -eq 0) { Write-Output 'SELFTEST_OK' }
            else { Write-Output ('SELFTEST_FAILED: ' + $applicationExitCode) }
        }
    } elseif (Test-IsElevated) {
        Write-AppLog 'ERROR' 'Execução elevada bloqueada para manter as unidades visíveis na sessão do usuário.'
        if (-not $AutoMount) { [Windows.Forms.MessageBox]::Show('Abra o SharePoint Fácil normalmente, sem usar “Executar como administrador”.', $script:AppName, 'OK', 'Warning') | Out-Null }
        $applicationExitCode = 5
    } elseif (-not (Test-WinFspInstalled)) {
        Write-AppLog 'ERROR' 'WinFsp ausente, parado ou incompleto.'
        if (-not $AutoMount) { [Windows.Forms.MessageBox]::Show('O componente de unidades do Windows não está instalado corretamente. Abra Aplicativos instalados e use Reparar no SharePoint Fácil.', $script:AppName, 'OK', 'Error') | Out-Null }
        $applicationExitCode = 3
    } elseif ($DocumentAction) {
        if ($AutoMount -or -not $DocumentPath) { throw 'Informe o caminho do documento e não combine a ação com AutoMount.' }
        Load-Settings
        Initialize-AppConfig
        Show-DocumentAction $DocumentAction $DocumentPath
    } else {
        Load-Settings
        if ($AutoMount -and @($script:Profiles | Where-Object { $_.autoMount }).Count -eq 0) {
            $applicationExitCode = 0
        } else {
            Initialize-AppConfig
            if ($script:Profiles.Count -gt 0) {
                Sync-ProfileMetadataFromConfig
                Repair-SharePointRemoteTargets
            }
            Save-Settings
            if (-not $AutoMount -and @(Get-ActiveMounts).Count -gt 0) { Start-ShellWatcher }
            if ($AutoMount) {
                $applicationExitCode = Invoke-AutoMount
            } else {
                $main = Build-MainForm
                [void]$main.ShowDialog()
            }
        }
    }
} catch {
    Write-AppLog 'ERROR' ($_ | Out-String)
    if ($DocumentAction -eq 'Auto') { try { Open-LocalDocument $DocumentPath } catch {} }
    elseif (-not $AutoMount -and -not $SelfTest -and -not $ShellWatcher) { Show-FriendlyError 'O SharePoint Fácil não pôde iniciar' 'A configuração local não pôde ser aberta. Use Reparar no instalador e tente novamente.' $_ }
    $applicationExitCode = 10
} finally {
    if ($AutoMount -or $SelfTest -or $ShellWatcher) {
        try { Stop-ControllerIfIdle } catch {}
    }
    if ($SelfTest) {
        try {
            $resolvedData = [IO.Path]::GetFullPath($script:DataDir).TrimEnd('\') + '\'
            $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            $leaf = Split-Path -Leaf $script:DataDir
            if ($resolvedData.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and $leaf -like 'SharePointFacil-SelfTest-*') {
                Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    if ($script:AppMutex) {
        try { $script:AppMutex.ReleaseMutex() } catch {}
        $script:AppMutex.Dispose()
    }
    $script:ConfigPassword = $null
}

if ($AutoMount -or $SelfTest -or $ShellWatcher) { exit $applicationExitCode }

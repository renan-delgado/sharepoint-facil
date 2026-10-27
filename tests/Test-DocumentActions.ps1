param([switch]$VerifyUi)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# Load definitions only. Never start the application, authenticate, or mount a customer's drive.
$appPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'RcloneDriveManager.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($appPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
foreach ($definition in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:DataDir = Join-Path ([IO.Path]::GetTempPath()) ('SharePointFacil-DocumentTest-' + [Guid]::NewGuid().ToString('N'))
$script:LogDir = Join-Path $script:DataDir 'logs'
$script:AppLogFile = Join-Path $script:LogDir 'test.log'
$script:AppName = 'SharePoint Fácil - teste isolado'
$script:Controller = $null
$DocumentAction = ''
$script:TestsPassed = 0

function Assert-Test($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:TestsPassed++
}
function Assert-Throws([scriptblock]$Work, [string]$Message) {
    $threw = $false
    try { & $Work | Out-Null } catch { $threw = $true }
    Assert-Test $threw $Message
}
function Reset-Scenario {
    $script:Profiles = @([pscustomobject]@{ id = 'profile1'; remote = 'remote1'; drive = 'Z'; driveId = 'drive1'; webUrl = 'https://tenant.sharepoint.com/sites/Docs/Shared%20Documents'; label = 'Teste'; siteName = 'Teste'; libraryName = 'Docs'; autoMount = $false })
    $script:Item = [pscustomobject]@{ id = 'item1'; name = 'Planilha.xlsx'; webUrl = 'https://tenant.sharepoint.com/sites/Docs/Shared%20Documents/Planilha.xlsx'; file = @{ mimeType = 'application/octet-stream' } }
    $script:Opened = @()
    $script:SeenGetUris = @()
    $script:FailOpen = $false
    $script:Dirty = $false
    $script:Uncertain = $false
    $script:Stats = [pscustomobject]@{ diskCache = [pscustomobject]@{ uploadsQueued = 0; uploadsInProgress = 0; erroredFiles = 0 } }
    $script:ControllerCalls = @()
}
function Get-ProfileAccessToken { param($Profile); return 'test-only' }
function ConvertTo-TestJwt([hashtable]$Claims) {
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return 'eyJhbGciOiJub25lIn0.' + $payload + '.sig'
}
function Invoke-GraphGet {
    param($Uri, $AccessToken, $Busy)
    $script:SeenGetUris += $Uri
    Assert-Test ($Uri -notlike '*/me?*' -and $Uri -notlike '*/me') 'Graph /me needs User.Read, which the rclone OAuth app does not grant'
    return $script:Item
}
function Open-DocumentUri {
    param($Uri)
    if ($script:FailOpen) { throw 'Office not installed' }
    $script:Opened += $Uri
}
function Get-ActiveMounts { param([switch]$ThrowOnError); return @([pscustomobject]@{ MountPoint = 'Z:'; Fs = 'remote1:' }) }
function Get-ProfileVfsCacheInfo { param($Profile, $Stats); return [pscustomobject]@{ IsDirty = $script:Dirty; IsUncertain = $script:Uncertain } }
function Invoke-ControllerRequest {
    param($Method, $Body, $Controller, $TimeoutSeconds)
    $script:ControllerCalls += [pscustomobject]@{ Method = $Method; Body = $Body }
    return $script:Stats
}

try {
    Reset-Scenario
    $script:VfsWriteBackSeconds = 2
    $script:DirectoryCacheTime = '24h'
    $script:RemotePollInterval = '15s'
    $mountRequest = New-MountRequest $script:Profiles[0]
    Assert-Test ($mountRequest.poll_interval -eq '15s' -and $mountRequest.dir_cache_time -eq '24h') 'Mount is not configured for prompt automatic remote change detection'
    Assert-Test ($mountRequest.attr_timeout -eq '10s' -and $mountRequest.vfs_read_chunk_streams -eq 8) 'Mount lost attribute caching or parallel reads'
    Assert-Test ($mountRequest.vfs_cache_mode -eq 'full') 'Office-safe mount options changed unexpectedly'
    Assert-Test (-not $mountRequest._config.Contains('Links') -and -not $mountRequest.Contains('links') -and -not $mountRequest.Contains('vfs_links')) 'Mount must not translate .rclonelink files into local symlinks'
    Assert-Test ($mountRequest._config.IgnoreSize -and $mountRequest._config.IgnoreChecksum) 'Mount must tolerate SharePoint rewriting Office files on upload'

    # The RC credential is only sent to the app's own rclone listener.
    & {
        $script:RclonePath = 'C:\App\rclone.exe'
        $start = [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $script:FakeProcess = [pscustomobject]@{ Path = 'C:\App\rclone.exe'; StartTime = $start }
        $script:ListenerOwner = 4242
        $script:ListenerLookups = 0
        $script:Probes = 0
        function Get-Process { [CmdletBinding()] param($Id); if ($Id -eq 4242) { return $script:FakeProcess } }
        function Get-NetTCPConnection {
            [CmdletBinding()] param($LocalAddress, $LocalPort, $State)
            Assert-Test ($LocalAddress -eq '127.0.0.1' -and $LocalPort -eq 50000 -and $State -eq 'Listen') 'Listener lookup must target the loopback controller port'
            $script:ListenerLookups++
            [pscustomobject]@{ OwningProcess = $script:ListenerOwner }
        }
        function Invoke-ControllerRequest { $script:Probes++; [pscustomobject]@{ version = 'v1.75.1' } }
        $controller = [pscustomobject]@{ pid = 4242; port = 50000; startTime = $start.Ticks; user = 'spf'; baseUrl = 'x'; password = 'y' }

        $script:VerifiedControllerKey = $null
        $script:ListenerOwner = 999
        Assert-Test (-not (Test-Controller $controller) -and $script:Probes -eq 0) 'Controller credential sent to a listener owned by another process'
        $script:ListenerOwner = 4242
        $script:FakeProcess.Path = 'C:\Other\rclone.exe'
        Assert-Test (-not (Test-Controller $controller) -and $script:Probes -eq 0) 'Controller accepted a different executable'
        $script:FakeProcess.Path = 'C:\App\rclone.exe'
        Assert-Test (-not (Test-Controller ([pscustomobject]@{ pid = 4242; port = 50000; startTime = $start.AddSeconds(1).Ticks })) -and $script:Probes -eq 0) 'Controller accepted a reused PID'
        Assert-Test (-not (Test-Controller ([pscustomobject]@{ pid = 7; port = 50000; startTime = 0 })) -and $script:Probes -eq 0) 'Controller accepted a dead PID'
        Assert-Test ((Test-Controller $controller) -and (Test-Controller $controller) -and $script:Probes -eq 2 -and $script:ListenerLookups -eq 2) 'Verified controller was rejected or the listener lookup was not cached'
        $script:VerifiedControllerKey = $null
    }
    $script:ShellUpdates = @()
    function Send-ShellDirectoryUpdate { param([string]$Path); $script:ShellUpdates += $Path }
    Notify-ProfileExplorerViews $script:Profiles[0] @('Z:\Contratos', 'Y:\Outro')
    Assert-Test ($script:ShellUpdates -contains 'Z:\' -and $script:ShellUpdates -contains 'Z:\Contratos' -and $script:ShellUpdates -notcontains 'Y:\Outro') 'Explorer notifier did not target only the mounted drive'
    & {
        $definition = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-ProfileAccessToken' }
        . ([scriptblock]::Create($definition.Extent.Text))
        function Assert-ProfileRemoteTarget { param($Profile) }
        function Invoke-ControllerRequest { param($Method, $Body); Assert-Test ($Method -eq 'operations/list' -and $Body.fs -eq 'remote1:') 'Refresh borrowed another remote' }
        function Get-AppConfigDump { return [pscustomobject]@{ remote1 = [pscustomobject]@{ token = '{"access_token":"correct-account"}' }; '_spf-auth' = [pscustomobject]@{ token = '{"access_token":"wrong-account"}' } } }
        Assert-Test ((Get-ProfileAccessToken $script:Profiles[0]) -eq 'correct-account') 'Document auth borrowed another account'
        function Get-AppConfigDump { return [pscustomobject]@{ remote1 = [pscustomobject]@{ token = '{"access_token":"correct-account"}'; root_folder_id = 'subfolder' } } }
        Assert-Throws { Get-ProfileAccessToken $script:Profiles[0] } 'Subfolder remote mapped against wrong Graph root'
    }
    $target = Get-DocumentTarget 'Z:\Contratos\Ação # 100%.xlsx'
    Assert-Test ($target.Uri -eq 'https://graph.microsoft.com/v1.0/drives/drive1/root:/Contratos/A%C3%A7%C3%A3o%20%23%20100%25.xlsx') 'Incorrect segment encoding'
    $metadataUri = Get-DocumentMetadataUri $target.Uri
    Assert-Test ($metadataUri -eq ($target.Uri + '?$select=id,name,webUrl,webDavUrl,file,remoteItem')) 'Unexpected document metadata selection'
    foreach ($path in @('C:\arquivo.xlsx', 'Z:arquivo.xlsx', 'Z:\..\arquivo.xlsx', '\\server\share\arquivo.xlsx', 'Z:\arquivo.xlsx:stream', 'Z:\pasta.\arquivo.xlsx', 'Z:\a|b.xlsx')) {
        Assert-Throws { Get-DocumentTarget $path } ('Unsafe path accepted: ' + $path)
    }
    foreach ($removed in @('Exclusive', 'Coauthor', 'Finish', 'Reconcile')) {
        Assert-Throws { Invoke-DocumentAction $removed 'Z:\Planilha.xlsx' } ('Removed document action still accepted: ' + $removed)
    }

    # "Abrir no SharePoint": the browser page of the item, never an Office URI.
    $null = Invoke-DocumentAction 'SharePoint' 'Z:\Planilha.xlsx'
    Assert-Test ($script:Opened.Count -eq 1 -and $script:Opened[0] -eq 'https://tenant.sharepoint.com/sites/Docs/Shared%20Documents/Planilha.xlsx') 'Open in SharePoint must launch the trusted web URL'

    # Double-click must not hide local edits that are newer than the server copy.
    foreach ($flag in @('Dirty', 'Uncertain')) {
        Reset-Scenario
        Set-Variable -Name $flag -Scope Script -Value $true
        Assert-Throws { Invoke-DocumentAction 'Auto' 'Z:\Planilha.xlsx' } 'Unsafe cache was accepted'
        Assert-Test ($script:Opened.Count -eq 0) 'Unsafe cache caused an action'
    }
    foreach ($field in @('uploadsQueued', 'uploadsInProgress', 'erroredFiles')) {
        Reset-Scenario
        $script:Stats.diskCache.$field = 1
        Assert-Throws { Invoke-DocumentAction 'Auto' 'Z:\Planilha.xlsx' } 'Pending upload was accepted'
    }
    Reset-Scenario
    $script:Stats = [pscustomobject]@{}
    Assert-Throws { Invoke-DocumentAction 'Auto' 'Z:\Planilha.xlsx' } 'Missing VFS data was treated as clean'

    Reset-Scenario
    foreach ($url in @('http://tenant.sharepoint.com/a.xlsx', 'https://other.sharepoint.com/a.xlsx', 'https://tenant.sharepoint.com/a.xlsx|bad', 'https://user@tenant.sharepoint.com/a.xlsx')) {
        $script:Item.webUrl = $url
        Assert-Throws { Invoke-DocumentAction 'Auto' 'Z:\Planilha.xlsx' } 'Untrusted Office URL accepted'
        Assert-Throws { Invoke-DocumentAction 'SharePoint' 'Z:\Planilha.xlsx' } 'Untrusted web URL accepted'
    }
    Reset-Scenario
    $script:Item.name = 'notas.txt'
    Assert-Throws { Invoke-DocumentAction 'Auto' 'Z:\notas.txt' } 'Non-Office file sent to an Office URI'

    # Account name comes from the token, never from Graph /me.
    $jwt = ConvertTo-TestJwt @{ upn = 'ana.silva@tenant.com' }
    Assert-Test ((Get-TokenAccountName $jwt) -eq 'ana.silva@tenant.com' -and (Get-TokenAccountName 'garbage') -eq '') 'Token account claim not read safely'

    # OneDrive sync: the same odopen link as SharePoint's Sync button.
    & {
        $jwt = ConvertTo-TestJwt @{ upn = 'ana.silva@tenant.com' }
        $library = [pscustomobject]@{ DriveId = 'b!drive'; SiteName = 'UTI Docs & Cia'; LibraryName = 'Documentos'; WebUrl = 'https://tenant.sharepoint.com/sites/UTI-DOCS/Documentos%20Compartilhados' }
        $script:SyncDrive = [pscustomobject]@{ name = 'Documentos'; sharePointIds = [pscustomobject]@{ siteId = '11111111-1111-1111-1111-111111111111'; webId = '22222222-2222-2222-2222-222222222222'; listId = '33333333-3333-3333-3333-333333333333'; siteUrl = 'https://tenant.sharepoint.com/sites/UTI-DOCS' } }
        function Invoke-GraphGet {
            param($Uri)
            Assert-Test ($Uri -eq 'https://graph.microsoft.com/v1.0/drives/b!drive?$select=name,sharePointIds') 'Sync lookup must select the drive SharePoint IDs'
            return $script:SyncDrive
        }
        $uri = Get-OneDriveSyncUri $library $jwt $null
        Assert-Test ($uri -eq 'odopen://sync/?siteId=%7B11111111-1111-1111-1111-111111111111%7D&webId=%7B22222222-2222-2222-2222-222222222222%7D&listId=%7B33333333-3333-3333-3333-333333333333%7D&userEmail=ana.silva%40tenant.com&webUrl=https%3A%2F%2Ftenant.sharepoint.com%2Fsites%2FUTI-DOCS&webTitle=UTI%20Docs%20%26%20Cia&listTitle=Documentos') ('Unexpected OneDrive sync link: ' + $uri)
        $script:SyncDrive.sharePointIds.siteUrl = 'https://evil.example.com/sites/UTI-DOCS'
        Assert-Throws { Get-OneDriveSyncUri $library $jwt $null } 'Sync link accepted a site on another host'
        $script:SyncDrive.sharePointIds.siteUrl = 'https://tenant.sharepoint.com/sites/UTI-DOCS'
        $script:SyncDrive.sharePointIds.listId = $null
        Assert-Throws { Get-OneDriveSyncUri $library $jwt $null } 'Sync link built without a list ID'
    }

    # OneDrive shortcut: a remoteItem in My files pointing at the library root.
    & {
        $library = [pscustomobject]@{ DriveId = 'b!drive'; SiteName = 'UTI Docs'; LibraryName = 'Documentos'; WebUrl = 'https://tenant.sharepoint.com/sites/UTI-DOCS/Documentos' }
        function Invoke-GraphGet {
            param($Uri)
            Assert-Test ($Uri -eq 'https://graph.microsoft.com/v1.0/drives/b!drive/root?$select=id') 'Shortcut must target the library root item'
            return [pscustomobject]@{ id = 'root-item' }
        }
        $script:PostResult = [pscustomobject]@{ id = 'local1'; name = 'UTI Docs - Documentos'; remoteItem = @{ id = 'root-item' } }
        $script:PostCalls = @()
        function Invoke-GraphPost { $script:PostCalls += [pscustomobject]@{ Uri = $args[0]; Body = $args[2] }; return $script:PostResult }
        $created = Add-OneDriveShortcut $library 'token' $null
        $call = $script:PostCalls[0]
        Assert-Test ($created.name -eq 'UTI Docs - Documentos' -and $call.Uri -eq 'https://graph.microsoft.com/v1.0/me/drive/root/children') 'Shortcut not created in My files'
        Assert-Test ($call.Body.name -eq 'Documentos' -and $call.Body.remoteItem.id -eq 'root-item' -and $call.Body.remoteItem.parentReference.driveId -eq 'b!drive' -and $call.Body.'@microsoft.graph.conflictBehavior' -eq 'fail') 'Unexpected shortcut request body'
        foreach ($status in 409, 403, 500) {
            $script:PostResult = [pscustomobject]@{ GraphError = $status }
            $message = ''
            try { $null = Add-OneDriveShortcut $library 'token' $null } catch { $message = $_.Exception.Message }
            Assert-Test ($message -ne '') ('Shortcut failure not reported: HTTP ' + $status)
            if ($status -eq 409) { Assert-Test ($message -like '*Já existe um atalho*') 'Duplicate shortcut message unclear' }
        }
    }

    # Office must get the file address, not the browser viewer link.
    Reset-Scenario
    $script:Item.webUrl = 'https://tenant.sharepoint.com/sites/Docs/_layouts/15/Doc.aspx?sourcedoc=%7B1%7D&file=Planilha.xlsx&action=default'
    $script:Item | Add-Member webDavUrl 'https://tenant.sharepoint.com/sites/Docs/Shared%20Documents/Planilha.xlsx'
    $null = Invoke-DocumentAction 'Auto' 'Z:\Planilha.xlsx'
    Assert-Test ($script:Opened[0] -eq 'ms-excel:ofe|u|https://tenant.sharepoint.com/sites/Docs/Shared%20Documents/Planilha.xlsx') 'Office was given the browser viewer link instead of the file address'
    $script:Item.webDavUrl = 'https://other.sharepoint.com/Planilha.xlsx'
    Assert-Throws { Invoke-DocumentAction 'Auto' 'Z:\Planilha.xlsx' } 'Untrusted webDavUrl accepted'

    # Double-click (Auto): SharePoint URL when safe, otherwise the drive copy.
    function Open-LocalDocument { param($Path); $script:LocalOpened += $Path }
    Reset-Scenario
    $script:LocalOpened = @()
    Show-DocumentAction 'Auto' 'Z:\Planilha.xlsx'
    Assert-Test ($script:Opened.Count -eq 1 -and $script:Opened[0] -like 'ms-excel:ofe|u|https://tenant.sharepoint.com/*' -and $script:LocalOpened.Count -eq 0) 'Auto must open the SharePoint URL'
    foreach ($case in @('Dirty', 'Upload', 'Office')) {
        Reset-Scenario
        $script:LocalOpened = @()
        if ($case -eq 'Dirty') { $script:Dirty = $true }
        if ($case -eq 'Upload') { $script:Stats.diskCache.uploadsQueued = 1 }
        if ($case -eq 'Office') { $script:FailOpen = $true }
        Show-DocumentAction 'Auto' 'Z:\Planilha.xlsx'
        Assert-Test ($script:Opened.Count -eq 0 -and $script:LocalOpened -contains 'Z:\Planilha.xlsx') ('Auto did not fall back to the drive copy: ' + $case)
    }

    if ($VerifyUi) {
        Reset-Scenario
        foreach ($statement in $ast.EndBlock.Statements) {
            if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -eq '$script:Colors') { . ([scriptblock]::Create($statement.Extent.Text)) }
        }
        function Get-AccountNameFromConfig { return 'Conta de teste' }
        function Stop-ControllerIfIdle {}
        $script:IsBusy = $false
        $script:BusyDepth = 0
        $script:MainForm = $null
        $form = Build-MainForm
        try {
            $form.PerformLayout()
            Assert-Test ($null -eq $script:ExclusiveButton -and $null -eq $script:ReservationsButton) 'Reservation buttons came back to the main window'
            $footerTop = $form.ClientSize.Height - 52
            # Relative to the button height so it holds at any monitor DPI.
            Assert-Test ($script:EditButton.Bottom -lt $footerTop -and ($footerTop - $script:EditButton.Bottom) -lt $script:EditButton.Height) ('Action buttons overlap the footer or leave an empty band (gap {0}px, button {1}px)' -f ($footerTop - $script:EditButton.Bottom), $script:EditButton.Height)
            $form.Size = $form.MinimumSize
            $form.PerformLayout()
            Assert-Test ($script:Grid.Bottom -lt $script:EditButton.Top -and $script:EditButton.Bottom -lt ($form.ClientSize.Height - 52)) 'Controls overlap at minimum size'
            $artifactDir = Join-Path $PSScriptRoot 'artifacts'
            [void](New-Item -ItemType Directory -Path $artifactDir -Force)
            $form.StartPosition = 'Manual'
            $form.Location = New-Object Drawing.Point(-20000, -20000)
            $form.ShowInTaskbar = $false
            $form.Show()
            [Windows.Forms.Application]::DoEvents()
            $script:ControllerCalls = @()
            $script:RefreshButton.PerformClick()
            Assert-Test (@($script:ControllerCalls | Where-Object { $_.Method -eq 'vfs/forget' -and $_.Body.fs -eq 'remote1:' }).Count -eq 1) 'Refresh button did not invalidate the selected VFS directory cache'
            $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
            try {
                $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                $bitmap.Save((Join-Path $artifactDir 'document-actions-ui.png'), [Drawing.Imaging.ImageFormat]::Png)
            } finally { $bitmap.Dispose(); $form.Hide() }
        } finally { $script:RefreshTimer.Stop(); $script:RefreshTimer.Dispose(); $form.Dispose() }
    }
    Write-Output ('DOCUMENT_TESTS_OK: ' + $script:TestsPassed + ' assertions')
} finally {
    $testRoot = [IO.Path]::GetFullPath($script:DataDir)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $testRoot) -like 'SharePointFacil-DocumentTest-*') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

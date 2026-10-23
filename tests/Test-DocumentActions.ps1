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
    $script:Item = [pscustomobject]@{ id = 'item1'; name = 'Planilha.xlsx'; webUrl = 'https://tenant.sharepoint.com/sites/Docs/Shared%20Documents/Planilha.xlsx'; file = @{ mimeType = 'application/octet-stream' }; publication = [pscustomobject]@{ level = 'published'; checkedOutBy = $null } }
    $script:Posts = @()
    $script:Opened = @()
    $script:SeenGetUris = @()
    $script:FailPost = ''
    $script:FailOpen = $false
    $script:WrongOwner = $false
    $script:Dirty = $false
    $script:Uncertain = $false
    $script:Stats = [pscustomobject]@{ diskCache = [pscustomobject]@{ uploadsQueued = 0; uploadsInProgress = 0; erroredFiles = 0 } }
    $script:ControllerCalls = @()
    Save-DocumentReservations @()
}
function Get-ProfileAccessToken { param($Profile); return 'test-only' }
function Invoke-GraphGet {
    param($Uri, $AccessToken, $Busy)
    $script:SeenGetUris += $Uri
    if ($Uri -like '*/me?*') { return [pscustomobject]@{ id = 'user1' } }
    return $script:Item
}
function Invoke-GraphDocumentPost {
    param($Uri, $AccessToken, $Body)
    # Assert durable intent is present before any remote mutation.
    $journal = @(Read-DocumentReservations)
    Assert-Test ($journal.Count -eq 1) 'Mutation without durable journal'
    $script:Posts += $Uri
    if ($Uri.EndsWith('/checkout')) {
        Assert-Test ($journal[0].state -eq 'CheckoutPending') 'Checkout intent was not recorded'
        $script:Item.publication.level = 'checkout'
        $script:Item.publication.checkedOutBy = @{ user = @{ id = $(if ($script:WrongOwner) { 'other' } else { 'user1' }) } }
    } else {
        Assert-Test ($journal[0].state -eq 'CheckinPending') 'Checkin intent was not recorded'
        $script:Item.publication.level = 'published'
        $script:Item.publication.checkedOutBy = $null
    }
    if ($script:FailPost -and $Uri.EndsWith($script:FailPost)) { throw 'Simulated lost response after remote commit' }
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
    Assert-Test ($metadataUri -eq ($target.Uri + '?$select=id,name,webUrl,webDavUrl,file,remoteItem,publication')) 'Checkout metadata did not request publication explicitly'
    foreach ($path in @('C:\arquivo.xlsx', 'Z:arquivo.xlsx', 'Z:\..\arquivo.xlsx', '\\server\share\arquivo.xlsx', 'Z:\arquivo.xlsx:stream', 'Z:\pasta.\arquivo.xlsx', 'Z:\a|b.xlsx')) {
        Assert-Throws { Get-DocumentTarget $path } ('Unsafe path accepted: ' + $path)
    }
    $null = Invoke-DocumentAction 'Coauthor' 'Z:\Planilha.xlsx'
    Assert-Test ($script:Posts.Count -eq 0 -and $script:Opened[0] -like 'ms-excel:ofe|u|https://tenant.sharepoint.com/*') 'Coauthor must only launch the remote Office URL'
    Assert-Test (@($script:SeenGetUris | Where-Object { $_ -like '*?$select=*publication*' }).Count -eq 1) 'Document lookup omitted the publication facet'
    Reset-Scenario
    $null = Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx'
    Assert-Test ($script:Posts.Count -eq 1 -and $script:Opened.Count -eq 1 -and @(Read-DocumentReservations)[0].state -eq 'Reserved') 'Exclusive flow failed'
    Assert-Throws { Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx' } 'Existing reservation was adopted'
    Assert-Throws { Invoke-DocumentAction 'Coauthor' 'Z:\Planilha.xlsx' } 'Coauthor allowed during checkout'
    Assert-Throws { Invoke-DocumentAction 'Finish' 'Z:\Planilha.xlsx' } 'Checkin without save confirmation'
    Assert-Test ($script:Posts.Count -eq 1) 'Blocked actions mutated SharePoint'
    $null = Invoke-DocumentAction 'Finish' 'Z:\old-name.xlsx' -ReservationItemId 'item1' -ConfirmedSavedAndClosed
    Assert-Test ($script:Posts.Count -eq 2 -and @(Read-DocumentReservations).Count -eq 0 -and $script:SeenGetUris -contains 'https://graph.microsoft.com/v1.0/drives/drive1/items/item1?$select=id,name,webUrl,webDavUrl,file,remoteItem,publication') 'Checkin must resolve stable item id with publication metadata and clear the journal'

    foreach ($flag in @('Dirty', 'Uncertain')) {
        Reset-Scenario
        Set-Variable -Name $flag -Scope Script -Value $true
        Assert-Throws { Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx' } 'Unsafe cache was accepted'
        Assert-Test ($script:Posts.Count -eq 0 -and $script:Opened.Count -eq 0) 'Unsafe cache caused an action'
    }
    foreach ($field in @('uploadsQueued', 'uploadsInProgress', 'erroredFiles')) {
        Reset-Scenario
        $script:Stats.diskCache.$field = 1
        Assert-Throws { Invoke-DocumentAction 'Coauthor' 'Z:\Planilha.xlsx' } 'Pending upload was accepted'
    }
    Reset-Scenario
    $script:Stats = [pscustomobject]@{}
    Assert-Throws { Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx' } 'Missing VFS data was treated as clean'

    foreach ($owner in @('user1', 'other')) {
        Reset-Scenario
        $script:Item.publication.level = 'checkout'
        $script:Item.publication.checkedOutBy = @{ user = @{ id = $owner } }
        Assert-Throws { Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx' } 'Pre-existing checkout adopted'
        Assert-Throws { Invoke-DocumentAction 'Finish' 'Z:\Planilha.xlsx' -ConfirmedSavedAndClosed } 'Foreign checkout released'
        Assert-Test ($script:Posts.Count -eq 0) 'Foreign checkout was mutated'
    }
    Reset-Scenario
    $script:WrongOwner = $true
    Assert-Throws { Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx' } 'Ownership was not verified after checkout'
    Assert-Test ($script:Opened.Count -eq 0) 'Office opened without ownership'

    Reset-Scenario
    $script:FailPost = '/checkout'
    Assert-Throws { Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx' } 'Lost checkout response ignored'
    Assert-Test ($script:Posts.Count -eq 1 -and $script:Opened.Count -eq 0 -and @(Read-DocumentReservations)[0].state -eq 'CheckoutPending') 'Uncertain checkout must be preserved without retry'
    Assert-Throws { Invoke-DocumentAction 'Reconcile' 'Z:\Planilha.xlsx' } 'Active checkout cleared during reconciliation'
    Reset-Scenario
    $null = Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx'
    $script:FailPost = '/checkin'
    Assert-Throws { Invoke-DocumentAction 'Finish' 'Z:\Planilha.xlsx' -ConfirmedSavedAndClosed } 'Lost checkin response ignored'
    Assert-Test (@(Read-DocumentReservations)[0].state -eq 'CheckinPending') 'Uncertain checkin not retained'
    Assert-Throws { Invoke-DocumentAction 'Finish' 'Z:\Planilha.xlsx' -ConfirmedSavedAndClosed } 'Uncertain checkin retried'
    $null = Invoke-DocumentAction 'Reconcile' 'Z:\Planilha.xlsx'
    Assert-Test (@(Read-DocumentReservations).Count -eq 0 -and $script:Posts.Count -eq 2) 'Reconcile must only clear local state'

    Reset-Scenario
    $script:FailOpen = $true
    Assert-Throws { Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx' } 'Missing Office ignored'
    Assert-Test (@(Read-DocumentReservations)[0].state -eq 'Reserved') 'Launch failure discarded reservation'

    Reset-Scenario
    foreach ($url in @('http://tenant.sharepoint.com/a.xlsx', 'https://other.sharepoint.com/a.xlsx', 'https://tenant.sharepoint.com/a.xlsx|bad', 'https://user@tenant.sharepoint.com/a.xlsx')) {
        $script:Item.webUrl = $url
        Assert-Throws { Invoke-DocumentAction 'Coauthor' 'Z:\Planilha.xlsx' } 'Untrusted Office URL accepted'
    }
    Reset-Scenario
    $script:Item.name = 'legacy.xls'
    Assert-Throws { Invoke-DocumentAction 'Coauthor' 'Z:\legacy.xls' } 'Unsupported coauthor format accepted'
    # Office must get the file address, not the browser viewer link.
    Reset-Scenario
    $script:Item.webUrl = 'https://tenant.sharepoint.com/sites/Docs/_layouts/15/Doc.aspx?sourcedoc=%7B1%7D&file=Planilha.xlsx&action=default'
    $script:Item | Add-Member webDavUrl 'https://tenant.sharepoint.com/sites/Docs/Shared%20Documents/Planilha.xlsx'
    $null = Invoke-DocumentAction 'Coauthor' 'Z:\Planilha.xlsx'
    Assert-Test ($script:Opened[0] -eq 'ms-excel:ofe|u|https://tenant.sharepoint.com/sites/Docs/Shared%20Documents/Planilha.xlsx') 'Office was given the browser viewer link instead of the file address'
    $script:Item.webDavUrl = 'https://other.sharepoint.com/Planilha.xlsx'
    Assert-Throws { Invoke-DocumentAction 'Coauthor' 'Z:\Planilha.xlsx' } 'Untrusted webDavUrl accepted'

    # Double-click (Auto): SharePoint URL when safe, otherwise the drive copy.
    function Open-LocalDocument { param($Path); $script:LocalOpened += $Path }
    Reset-Scenario
    $script:LocalOpened = @()
    Show-DocumentAction 'Auto' 'Z:\Planilha.xlsx'
    Assert-Test ($script:Opened.Count -eq 1 -and $script:Opened[0] -like 'ms-excel:ofe|u|https://tenant.sharepoint.com/*' -and $script:LocalOpened.Count -eq 0 -and $script:Posts.Count -eq 0) 'Auto must open the SharePoint URL without mutations'
    Reset-Scenario
    $script:LocalOpened = @()
    $script:Item.publication.level = 'checkout'
    $script:Item.publication.checkedOutBy = @{ user = @{ id = 'other' } }
    Show-DocumentAction 'Auto' 'Z:\Planilha.xlsx'
    Assert-Test ($script:Opened.Count -eq 1 -and $script:Posts.Count -eq 0) 'Auto must open a checked-out item by URL without touching the checkout'
    foreach ($case in @('Dirty', 'Upload', 'Office')) {
        Reset-Scenario
        $script:LocalOpened = @()
        if ($case -eq 'Dirty') { $script:Dirty = $true }
        if ($case -eq 'Upload') { $script:Stats.diskCache.uploadsQueued = 1 }
        if ($case -eq 'Office') { $script:FailOpen = $true }
        Show-DocumentAction 'Auto' 'Z:\Planilha.xlsx'
        Assert-Test ($script:Opened.Count -eq 0 -and $script:LocalOpened -contains 'Z:\Planilha.xlsx') ('Auto did not fall back to the drive copy: ' + $case)
    }

    Reset-Scenario
    Write-AtomicText (Join-Path $script:DataDir 'reservations.json') '{broken'
    Assert-Throws { Invoke-DocumentAction 'Exclusive' 'Z:\Planilha.xlsx' } 'Corrupt journal was ignored'
    Assert-Test ($script:Posts.Count -eq 0) 'Mutation after corrupt journal'

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
            Assert-Test ($script:ExclusiveButton.Enabled -and $script:CoauthorButton.Enabled) 'Document actions not enabled for mounted library'
            Assert-Test ($script:ExclusiveButton.Bottom -lt ($form.ClientSize.Height - 52)) 'Document toolbar overlaps footer'
            $form.Size = $form.MinimumSize
            $form.PerformLayout()
            Assert-Test ($script:Grid.Bottom -lt $script:EditButton.Top -and $script:EditButton.Bottom -lt $script:ExclusiveButton.Top) 'Controls overlap at minimum size'
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

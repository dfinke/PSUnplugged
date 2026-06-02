.$(Join-Path $PSScriptRoot 'Private\PowerShellRich.Status.ps1')

$threadFormatPath = Join-Path $PSScriptRoot 'PSUnplugged.Threads.Format.ps1xml'
$script:CodexTaskSessionPathCache = @{}
$script:CodexTaskTerminalStatusCache = @{}
$script:CodexModelLookupCache = $null
if (Test-Path -LiteralPath $threadFormatPath) {
    Update-FormatData -PrependPath $threadFormatPath -ErrorAction SilentlyContinue
}

if (-not (Get-Command -Name Start-CodexSession -CommandType Function -ListImported -ErrorAction Ignore)) {
    function Start-CodexSession {
        [CmdletBinding()]
        param(
            [string]$ClientName = "powershell_client",
            [string]$ClientTitle = "PowerShell Codex Client",
            [string]$Version = "0.1.1",
            [string]$ApiKey,
            [string]$CodexPath = "codex"
        )

        $resolvedPath = $null

        if ($CodexPath -ne "codex") {
            if (-not (Test-Path $CodexPath)) {
                throw "Codex binary not found at: $CodexPath"
            }
            $resolvedPath = $CodexPath
        }
        else {
            if ($env:CODEX_EXE -and (Test-Path $env:CODEX_EXE)) {
                $resolvedPath = $env:CODEX_EXE
            }

            if (-not $resolvedPath) {
                $npmRoots = @()
                $npmRoot = & npm root -g 2>$null
                if ($npmRoot) { $npmRoots += $npmRoot }
                if ($env:APPDATA) { $npmRoots += "$env:APPDATA\npm\node_modules" }
                if ($env:ProgramFiles) { $npmRoots += "$env:ProgramFiles\nodejs\node_modules" }

                foreach ($root in ($npmRoots | Select-Object -Unique)) {
                    $native = Join-Path $root "@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe"
                    if (Test-Path $native) { $resolvedPath = $native; break }
                    $native = Join-Path $root "@openai\codex\node_modules\@openai\codex-win32-arm64\vendor\aarch64-pc-windows-msvc\codex\codex.exe"
                    if (Test-Path $native) { $resolvedPath = $native; break }
                }
            }

            if (-not $resolvedPath) {
                $npmRoot = & npm root -g 2>$null
                if ($npmRoot) {
                    $codexPkg = Join-Path $npmRoot "@openai\codex"
                    if (Test-Path $codexPkg) {
                        $found = Get-ChildItem $codexPkg -Recurse -Filter "codex.exe" -ErrorAction SilentlyContinue |
                        Where-Object { $_.Length -gt 1MB } |
                        Select-Object -First 1
                        if ($found) { $resolvedPath = $found.FullName }
                    }
                }
            }

            if (-not $resolvedPath -and -not $IsWindows) {
                $cmd = Get-Command codex -ErrorAction SilentlyContinue
                if ($cmd) { $resolvedPath = $cmd.Source }
            }

            if (-not $resolvedPath) {
                throw "Cannot find the native codex.exe binary."
            }
        }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        if ($resolvedPath -match '\.ps1$') {
            $psi.FileName = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
            $psi.Arguments = "-NoProfile -NonInteractive -File `"$resolvedPath`" app-server"
        }
        elseif ($resolvedPath -match '\.(cmd|bat)$') {
            $psi.FileName = "cmd.exe"
            $psi.Arguments = "/c `"$resolvedPath`" app-server"
        }
        else {
            $psi.FileName = $resolvedPath
            $psi.Arguments = "app-server"
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { throw "Failed to start codex app-server" }

        $session = [PSCustomObject]@{
            Process         = $proc
            Writer          = $proc.StandardInput
            Reader          = $proc.StandardOutput
            PendingReadTask = $null
            NextId          = 1
            Verbose         = $VerbosePreference -ne 'SilentlyContinue'
        }

        $null = Send-CodexRequest -Session $session -Method "initialize" -Params @{
            clientInfo = @{
                name    = $ClientName
                title   = $ClientTitle
                version = $Version
            }
        }

        Send-CodexNotification -Session $session -Method "initialized" -Params @{}

        if ($ApiKey) {
            $null = Send-CodexRequest -Session $session -Method "account/login/start" -Params @{
                type   = "apiKey"
                apiKey = $ApiKey
            }
            Read-CodexNotifications -Session $session -TimeoutMs 3000 | Out-Null
        }

        return $session
    }

    function Stop-CodexSession {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory, ValueFromPipeline)]
            [PSCustomObject]$Session
        )

        try {
            $Session.Writer.Close()
            if (-not $Session.Process.WaitForExit(5000)) {
                $Session.Process.Kill()
            }
        }
        catch { }
        $Session.Process.Dispose()
    }

    function Receive-CodexLine {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][PSCustomObject]$Session,
            [int]$TimeoutMs
        )

        if (-not $Session.PendingReadTask) {
            $Session.PendingReadTask = $Session.Reader.ReadLineAsync()
        }

        $completed = if ($PSBoundParameters.ContainsKey('TimeoutMs')) {
            $Session.PendingReadTask.Wait($TimeoutMs)
        }
        else {
            $Session.PendingReadTask.Wait()
            $true
        }

        if (-not $completed) {
            return [PSCustomObject]@{ HasLine = $false; Line = $null }
        }

        $line = $Session.PendingReadTask.Result
        $Session.PendingReadTask = $null
        return [PSCustomObject]@{ HasLine = $true; Line = $line }
    }

    function Send-CodexRequest {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][PSCustomObject]$Session,
            [Parameter(Mandatory)][string]$Method,
            [hashtable]$Params = @{}
        )

        $id = $Session.NextId++
        $msg = @{ method = $Method; id = $id; params = $Params }
        $json = $msg | ConvertTo-Json -Depth 20 -Compress
        $Session.Writer.WriteLine($json)
        $Session.Writer.Flush()

        while ($true) {
            $read = Receive-CodexLine -Session $Session
            $line = $read.Line
            if ($null -eq $line) { throw "codex app-server closed unexpectedly" }

            $parsed = $line | ConvertFrom-Json
            if ($null -ne $parsed.id -and $parsed.id -eq $id) {
                if ($parsed.error) {
                    throw "Codex error ($($parsed.error.code)): $($parsed.error.message)"
                }
                return $parsed.result
            }
        }
    }

    function Send-CodexNotification {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][PSCustomObject]$Session,
            [Parameter(Mandatory)][string]$Method,
            [hashtable]$Params = @{}
        )

        $msg = @{ method = $Method; params = $Params }
        $json = $msg | ConvertTo-Json -Depth 20 -Compress
        $Session.Writer.WriteLine($json)
        $Session.Writer.Flush()
    }

    function Read-CodexNotifications {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][PSCustomObject]$Session,
            [int]$TimeoutMs = 60000,
            [switch]$WaitForTurnComplete
        )

        $events = [System.Collections.Generic.List[PSObject]]::new()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $remaining = $TimeoutMs - [int]$sw.ElapsedMilliseconds
            if ($remaining -le 0) { break }

            $slice = [Math]::Min(500, $remaining)
            $read = Receive-CodexLine -Session $Session -TimeoutMs $slice
            if (-not $read.HasLine) { continue }

            $line = $read.Line
            if ($null -eq $line) { break }

            $parsed = $line | ConvertFrom-Json
            $events.Add($parsed)

            if ($parsed.method -eq "item/commandExecution/requestApproval" -or
                $parsed.method -eq "item/fileChange/requestApproval") {
                $approvalResponse = @{
                    id     = $parsed.id
                    result = @{ decision = "accept" }
                }
                $json = $approvalResponse | ConvertTo-Json -Depth 10 -Compress
                $Session.Writer.WriteLine($json)
                $Session.Writer.Flush()
            }

            if ($WaitForTurnComplete -and $parsed.method -eq "turn/completed") {
                break
            }
        }

        return $events
    }

    function Get-CodexThreads {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][PSCustomObject]$Session,
            [int]$Limit = 25,
            [string]$Cursor
        )

        $params = @{ limit = $Limit }
        if ($Cursor) { $params.cursor = $Cursor }

        return Send-CodexRequest -Session $Session -Method "thread/list" -Params $params
    }

    function Get-CodexThreadRecord {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][PSCustomObject]$Session,
            [Parameter(Mandatory)][string]$ThreadId,
            [switch]$IncludeTurns
        )

        $params = @{
            threadId = $ThreadId
        }
        if ($IncludeTurns) {
            $params.includeTurns = $true
        }

        return Send-CodexRequest -Session $Session -Method "thread/read" -Params $params
    }
}

function Get-PSUnpluggedDataRoot {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:PSUNPLUGGED_HOME)) {
        return [System.IO.Path]::GetFullPath($env:PSUNPLUGGED_HOME)
    }

    if ($IsWindows) {
        return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSUnplugged')
    }

    return (Join-Path $HOME '.psunplugged')
}

function Get-PSUnpluggedModuleRoot {
    [CmdletBinding()]
    param()

    $root = $PSScriptRoot
    if (Test-Path (Join-Path $root 'Examples\Start-AgentChat.ps1')) {
        return $root
    }

    return (Split-Path -Parent $root)
}

function Get-PSUnpluggedCatalogPath {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-PSUnpluggedDataRoot) 'thread-catalog.json')
}

function Get-PSUnpluggedArchivedThreadsPath {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-PSUnpluggedDataRoot) 'archived-threads.json')
}

function Get-CodexHomePath {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }

    return (Join-Path $HOME '.codex')
}

function Get-CodexSessionIndexPath {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-CodexHomePath) 'session_index.jsonl')
}

function Get-CodexSessionsRootPath {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-CodexHomePath) 'sessions')
}

function Get-CodexDesktopGlobalStatePath {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-CodexHomePath) '.codex-global-state.json')
}

function Get-CodexDesktopWorkspaceRoots {
    [CmdletBinding()]
    param()

    $globalStatePath = Get-CodexDesktopGlobalStatePath
    if (-not (Test-Path -LiteralPath $globalStatePath)) {
        return @()
    }

    try {
        $state = Get-Content -LiteralPath $globalStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return @()
    }

    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($propertyName in 'active-workspace-roots', 'electron-saved-workspace-roots') {
        $property = $state.PSObject.Properties[$propertyName]
        if (-not $property -or $null -eq $property.Value) {
            continue
        }

        foreach ($path in @($property.Value)) {
            if ([string]::IsNullOrWhiteSpace([string]$path)) {
                continue
            }

            try {
                $fullPath = [System.IO.Path]::GetFullPath([string]$path)
            }
            catch {
                continue
            }

            if (-not $roots.Contains($fullPath)) {
                $roots.Add($fullPath)
            }
        }
    }

    return @($roots)
}

function Get-CodexPreferredPlaygroundRoot {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:PSUNPLUGGED_PLAYGROUND_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:PSUNPLUGGED_PLAYGROUND_ROOT)
    }

    $workspaceRoots = @(Get-CodexDesktopWorkspaceRoots)
    $playgroundRoots = @(
        $workspaceRoots |
        Where-Object {
            $leaf = Split-Path -Leaf $_
            $leaf -match '^(?i:playground|playgrounds)$'
        }
    )

    foreach ($candidate in @($playgroundRoots + $workspaceRoots)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (Test-Path -LiteralPath $candidate) {
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    return (Join-Path $HOME 'CodexPlaygrounds')
}

function Resolve-CodexSessionPath {
    [CmdletBinding()]
    param(
        [string]$ThreadId
    )

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return $null
    }

    $sessionsRoot = Get-CodexSessionsRootPath
    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        return $null
    }

    $candidate = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter "*$ThreadId*.jsonl" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

    if ($candidate) {
        return $candidate.FullName
    }

    return $null
}

function Get-PSUnpluggedUtcNowString {
    [CmdletBinding()]
    param()

    return ([DateTimeOffset]::UtcNow.ToString('o'))
}

function Initialize-PSUnpluggedCatalog {
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        version  = 1
        projects = @()
        threads  = @()
    }
}

function Merge-CodexCatalogThreadRecords {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Thread
    )

    $groupedRecords = [ordered]@{}
    foreach ($record in @($Thread)) {
        if ($null -eq $record) {
            continue
        }

        $threadId = [string](Get-CodexFirstValue -InputObject $record -PropertyName @('ThreadId', 'threadId'))
        $normalizedThreadId = Get-CodexNormalizedThreadId -ThreadId $threadId
        if ([string]::IsNullOrWhiteSpace($normalizedThreadId)) {
            continue
        }

        if (-not $groupedRecords.Contains($normalizedThreadId)) {
            $groupedRecords[$normalizedThreadId] = [System.Collections.Generic.List[object]]::new()
        }

        $groupedRecords[$normalizedThreadId].Add($record)
    }

    $mergedRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($recordGroup in @($groupedRecords.Values)) {
        $orderedRecords = @(
            $recordGroup |
            Sort-Object -Property @{
                Expression = { ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $_ -PropertyName @('UpdatedAt', 'updatedAt')) }
                Descending = $true
            }, @{
                Expression = { ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $_ -PropertyName @('LastActivityAt', 'lastActivityAt')) }
                Descending = $true
            }
        )

        $primaryRecord = @($orderedRecords | Select-Object -First 1)[0]
        if ($null -eq $primaryRecord) {
            continue
        }

        $mergedRecord = [ordered]@{}
        foreach ($property in $primaryRecord.PSObject.Properties) {
            $mergedRecord[$property.Name] = $property.Value
        }

        $tagSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($record in @($orderedRecords)) {
            foreach ($tag in @($record.Tags)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$tag)) {
                    $null = $tagSet.Add([string]$tag)
                }
            }

            foreach ($property in $record.PSObject.Properties) {
                if ($property.Name -in @('Tags', 'Archived', 'Pinned')) {
                    continue
                }

                if (
                    -not $mergedRecord.Contains($property.Name) -or
                    $null -eq $mergedRecord[$property.Name] -or
                    [string]::IsNullOrWhiteSpace([string]$mergedRecord[$property.Name])
                ) {
                    $mergedRecord[$property.Name] = $property.Value
                }
            }
        }

        $mergedRecord.ThreadId = [string](Get-CodexFirstValue -InputObject $primaryRecord -PropertyName @('ThreadId', 'threadId'))
        $mergedRecord.Archived = @($orderedRecords | Where-Object { [bool](Get-CodexFirstValue -InputObject $_ -PropertyName @('Archived', 'archived')) }).Count -gt 0
        $mergedRecord.Pinned = @($orderedRecords | Where-Object { [bool](Get-CodexFirstValue -InputObject $_ -PropertyName @('Pinned', 'pinned')) }).Count -gt 0
        $mergedRecord.Tags = @($tagSet)

        $mergedRecords.Add([PSCustomObject]$mergedRecord)
    }

    return @($mergedRecords)
}

function Import-PSUnpluggedArchivedThreadIndex {
    [CmdletBinding()]
    param()

    $index = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $path = Get-PSUnpluggedArchivedThreadsPath
    if (-not (Test-Path -LiteralPath $path)) {
        return (, $index)
    }

    try {
        $items = @(Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return (, $index)
    }

    foreach ($item in @($items)) {
        $normalizedThreadId = Get-CodexNormalizedThreadId -ThreadId ([string]$item)
        if (-not [string]::IsNullOrWhiteSpace($normalizedThreadId)) {
            $null = $index.Add($normalizedThreadId)
        }
    }

    return (, $index)
}

function Export-PSUnpluggedArchivedThreadIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$Index
    )

    $root = Get-PSUnpluggedDataRoot
    if (-not (Test-Path -LiteralPath $root)) {
        $null = New-Item -ItemType Directory -Force -Path $root
    }

    @($Index | Sort-Object) |
    ConvertTo-Json -Depth 3 |
    Set-Content -LiteralPath (Get-PSUnpluggedArchivedThreadsPath) -Encoding utf8
}

function Set-PSUnpluggedThreadArchivedState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ThreadId,
        [Parameter(Mandatory)][bool]$Archived
    )

    $normalizedThreadId = Get-CodexNormalizedThreadId -ThreadId $ThreadId
    if ([string]::IsNullOrWhiteSpace($normalizedThreadId)) {
        return
    }

    $index = Import-PSUnpluggedArchivedThreadIndex
    if ($null -eq $index) {
        $index = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    if ($Archived) {
        $null = $index.Add($normalizedThreadId)
    }
    else {
        $null = $index.Remove($normalizedThreadId)
    }

    Export-PSUnpluggedArchivedThreadIndex -Index $index
}

function Test-PSUnpluggedThreadArchivedState {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ThreadId
    )

    $normalizedThreadId = Get-CodexNormalizedThreadId -ThreadId $ThreadId
    if ([string]::IsNullOrWhiteSpace($normalizedThreadId)) {
        return $false
    }

    $index = Import-PSUnpluggedArchivedThreadIndex
    if ($null -eq $index) {
        return $false
    }

    return $index.Contains($normalizedThreadId)
}

function Import-PSUnpluggedCatalog {
    [CmdletBinding()]
    param()

    $catalogPath = Get-PSUnpluggedCatalogPath
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        return (Initialize-PSUnpluggedCatalog)
    }

    try {
        $raw = Get-Content -LiteralPath $catalogPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return (Initialize-PSUnpluggedCatalog)
        }

        $catalog = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return (Initialize-PSUnpluggedCatalog)
    }

    if ($catalog -is [System.Collections.IEnumerable] -and -not ($catalog -is [string])) {
        $normalizedCatalog = Initialize-PSUnpluggedCatalog
        foreach ($item in @($catalog)) {
            if ($null -eq $item -or -not $item.PSObject) {
                continue
            }

            if ($item.PSObject.Properties['projects']) {
                $normalizedCatalog.projects += @($item.projects | Where-Object { $null -ne $_ })
            }
            if ($item.PSObject.Properties['threads']) {
                $normalizedCatalog.threads += @($item.threads | Where-Object { $null -ne $_ })
            }
        }

        $catalog = $normalizedCatalog
    }

    if (-not $catalog.projects) { $catalog | Add-Member -NotePropertyName projects -NotePropertyValue @() -Force }
    if (-not $catalog.threads) { $catalog | Add-Member -NotePropertyName threads -NotePropertyValue @() -Force }
    if (-not $catalog.version) { $catalog | Add-Member -NotePropertyName version -NotePropertyValue 1 -Force }

    $catalog | Add-Member -NotePropertyName projects -NotePropertyValue @(@($catalog.projects) | Where-Object { $null -ne $_ }) -Force
    $catalog | Add-Member -NotePropertyName threads -NotePropertyValue @(Merge-CodexCatalogThreadRecords -Thread $catalog.threads) -Force

    return $catalog
}

function Export-PSUnpluggedCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog
    )

    $root = Get-PSUnpluggedDataRoot
    if (-not (Test-Path -LiteralPath $root)) {
        $null = New-Item -ItemType Directory -Force -Path $root
    }

    $catalog | Add-Member -NotePropertyName projects -NotePropertyValue @(@($Catalog.projects) | Where-Object { $null -ne $_ }) -Force
    $catalog | Add-Member -NotePropertyName threads -NotePropertyValue @(Merge-CodexCatalogThreadRecords -Thread $Catalog.threads) -Force

    $Catalog |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Get-PSUnpluggedCatalogPath) -Encoding utf8
}

function Resolve-CodexSessionIndexThreadName {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread
    )

    if ($null -eq $Thread) {
        return $null
    }

    foreach ($value in @(
            [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('Name', 'name')),
            [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('PromptPreview', 'promptPreview', 'preview')),
            [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('Project', 'ProjectName', 'project', 'projectName'))
        )) {
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value -ne 'Untitled thread') {
            return $value
        }
    }

    return 'Untitled thread'
}

function Update-CodexSessionIndex {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Thread
    )

    $sessionIndexPath = Get-CodexSessionIndexPath
    $sessionIndexRoot = Split-Path -Parent $sessionIndexPath
    if (-not (Test-Path -LiteralPath $sessionIndexRoot)) {
        return
    }

    $existingEntries = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $sessionIndexPath) {
        foreach ($line in @(Get-Content -LiteralPath $sessionIndexPath -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $entry = $line | ConvertFrom-Json -ErrorAction Stop
                if ($entry.id) {
                    $existingEntries.Add($entry)
                }
            }
            catch {
            }
        }
    }

    $updates = [System.Collections.Generic.List[object]]::new()
    foreach ($threadItem in @($Thread)) {
        if ($null -eq $threadItem) {
            continue
        }

        $threadId = [string](Get-CodexFirstValue -InputObject $threadItem -PropertyName @('ThreadId', 'threadId', 'Id', 'id'))
        if ([string]::IsNullOrWhiteSpace($threadId)) {
            continue
        }

        $rawThread = Get-CodexFirstValue -InputObject $threadItem -PropertyName @('RawThread', 'rawThread')
        $sessionPath = [string](Get-CodexFirstValue -InputObject $rawThread -PropertyName @('path', 'Path'))
        if ([string]::IsNullOrWhiteSpace($sessionPath) -or -not (Test-Path -LiteralPath $sessionPath)) {
            continue
        }

        $threadName = Resolve-CodexSessionIndexThreadName -Thread $threadItem
        $updatedAt = $null
        foreach ($value in @(
                (Get-CodexFirstValue -InputObject $threadItem -PropertyName @('LastActivityAt', 'lastActivityAt', 'UpdatedAt', 'updatedAt', 'CreatedAt', 'createdAt')),
                (Get-CodexFirstValue -InputObject $rawThread -PropertyName @('updatedAt', 'UpdatedAt', 'createdAt', 'CreatedAt'))
            )) {
            $parsed = ConvertTo-CodexDateTimeOffset -Value $value
            if ($parsed) {
                $updatedAt = $parsed.ToUniversalTime().ToString('o')
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($updatedAt)) {
            $updatedAt = Get-PSUnpluggedUtcNowString
        }

        $updates.Add([PSCustomObject]@{
                id          = $threadId
                thread_name = $threadName
                updated_at  = $updatedAt
            })
    }

    if ($updates.Count -eq 0) {
        return
    }

    $updatedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $updates) {
        $null = $updatedIds.Add([string]$entry.id)
    }

    $outputEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $existingEntries) {
        if (-not $updatedIds.Contains([string]$entry.id)) {
            $outputEntries.Add($entry)
        }
    }

    foreach ($entry in @($updates | Sort-Object updated_at, thread_name)) {
        $outputEntries.Add($entry)
    }

    $lines = foreach ($entry in $outputEntries) {
        $entry | ConvertTo-Json -Compress
    }

    Set-Content -LiteralPath $sessionIndexPath -Value $lines -Encoding utf8
}

function Get-CodexTranscriptText {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $segments = [System.Collections.Generic.List[string]]::new()

    if ($InputObject -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($InputObject)) {
            $segments.Add($InputObject)
        }
    }
    elseif ($InputObject.PSObject) {
        foreach ($propertyName in 'text', 'Text', 'message', 'Message') {
            $property = $InputObject.PSObject.Properties[$propertyName]
            if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $segments.Add([string]$property.Value)
            }
        }

        foreach ($propertyName in 'content', 'Content') {
            $property = $InputObject.PSObject.Properties[$propertyName]
            if (-not $property -or $null -eq $property.Value) {
                continue
            }

            foreach ($contentItem in @($property.Value)) {
                $contentType = [string](Get-CodexFirstValue -InputObject $contentItem -PropertyName @('type', 'Type'))
                switch ($contentType) {
                    'text' {
                        $text = [string](Get-CodexFirstValue -InputObject $contentItem -PropertyName @('text', 'Text'))
                        if (-not [string]::IsNullOrWhiteSpace($text)) {
                            $segments.Add($text)
                        }
                    }
                    'input_text' {
                        $text = [string](Get-CodexFirstValue -InputObject $contentItem -PropertyName @('text', 'Text'))
                        if (-not [string]::IsNullOrWhiteSpace($text)) {
                            $segments.Add($text)
                        }
                    }
                    'output_text' {
                        $text = [string](Get-CodexFirstValue -InputObject $contentItem -PropertyName @('text', 'Text'))
                        if (-not [string]::IsNullOrWhiteSpace($text)) {
                            $segments.Add($text)
                        }
                    }
                }
            }
        }
    }

    $uniqueSegments = [System.Collections.Generic.List[string]]::new()
    $seenSegments = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($segment in @($segments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($seenSegments.Add($segment)) {
            $uniqueSegments.Add($segment)
        }
    }

    if ($uniqueSegments.Count -eq 0) {
        return $null
    }

    return ($uniqueSegments -join "`n")
}

function New-CodexTranscriptItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ThreadId,
        [string]$ThreadName,
        [string]$Project,
        [string]$TurnId,
        [int]$Index,
        [string]$Role,
        [string]$ItemType,
        [string]$Phase,
        [string]$Text,
        [AllowNull()][Nullable[DateTimeOffset]]$Timestamp
    )

    $timestampValue = if ($null -ne $Timestamp) { [DateTimeOffset]$Timestamp } else { $null }
    $item = [PSCustomObject]@{
        ThreadId   = $ThreadId
        ThreadName = $ThreadName
        TurnId     = $TurnId
        Index      = $Index
        Role       = $Role
        Project    = $Project
        ItemType   = $ItemType
        Phase      = $Phase
        Timestamp  = if ($null -ne $timestampValue) { $timestampValue.ToString('o') } else { $null }
        When       = if ($null -ne $timestampValue) { Get-CodexDisplayTimestamp -Timestamp $timestampValue } else { $null }
        Text       = $Text
    }

    $item.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTranscriptItem')
    return $item
}

function Test-CodexTelemetryTypeEnabled {
    [CmdletBinding()]
    param(
        [string[]]$TelemetryType,
        [Parameter(Mandatory)][string]$Type
    )

    $normalizedType = $Type.Trim().ToLowerInvariant()
    foreach ($entry in @($TelemetryType)) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        $normalizedEntry = $entry.Trim().ToLowerInvariant()
        if ($normalizedEntry -eq 'all' -or $normalizedEntry -eq $normalizedType) {
            return $true
        }
    }

    return $false
}

function ConvertTo-CodexTelemetryArgumentObject {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Arguments
    )

    if ([string]::IsNullOrWhiteSpace($Arguments)) {
        return $null
    }

    try {
        return ($Arguments | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function ConvertTo-CodexTelemetryValueText {
    [CmdletBinding()]
    param(
        [AllowNull()]$Value,
        [int]$MaxLength = 72
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        (@($Value) | ForEach-Object { [string]$_ }) -join ' '
    }
    else {
        [string]$Value
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $text = (($text -replace '\s+', ' ').Trim())
    if ($text.Length -gt $MaxLength) {
        return ($text.Substring(0, $MaxLength - 3) + '...')
    }

    return $text
}

function Get-CodexTelemetryDisplayName {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($Name -eq 'shell_command') {
        return 'shell'
    }

    if ($Name -match '^mcp__codex_apps__([^_]+)_(.+)$') {
        return ('{0}.{1}' -f $matches[1], $matches[2])
    }

    return $Name
}

function Get-CodexTelemetryArgumentSummary {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Arguments,
        [string[]]$PreferKey = @(),
        [int]$MaxItems = 2
    )

    $argumentObject = ConvertTo-CodexTelemetryArgumentObject -Arguments $Arguments
    if ($null -eq $argumentObject -or -not $argumentObject.PSObject) {
        return (ConvertTo-CodexTelemetryValueText -Value $Arguments -MaxLength 80)
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($propertyName in @($PreferKey)) {
        $property = $argumentObject.PSObject.Properties[$propertyName]
        if ($property) {
            $valueText = ConvertTo-CodexTelemetryValueText -Value $property.Value
            if (-not [string]::IsNullOrWhiteSpace($valueText)) {
                $parts.Add(('{0}={1}' -f $property.Name, $valueText))
                $null = $seen.Add($property.Name)
            }
        }

        if ($parts.Count -ge $MaxItems) {
            break
        }
    }

    if ($parts.Count -lt $MaxItems) {
        foreach ($property in @($argumentObject.PSObject.Properties)) {
            if ($parts.Count -ge $MaxItems) {
                break
            }

            if ($seen.Contains($property.Name)) {
                continue
            }

            $valueText = ConvertTo-CodexTelemetryValueText -Value $property.Value
            if (-not [string]::IsNullOrWhiteSpace($valueText)) {
                $parts.Add(('{0}={1}' -f $property.Name, $valueText))
            }
        }
    }

    return ($parts -join ', ')
}

function Get-CodexShellCommandSummary {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Arguments
    )

    $argumentObject = ConvertTo-CodexTelemetryArgumentObject -Arguments $Arguments
    $commandText = [string](Get-CodexFirstValue -InputObject $argumentObject -PropertyName @('command', 'Command'))
    if ([string]::IsNullOrWhiteSpace($commandText)) {
        return (ConvertTo-CodexTelemetryValueText -Value $Arguments -MaxLength 90)
    }

    return (ConvertTo-CodexTelemetryValueText -Value $commandText -MaxLength 90)
}

function Get-CodexShellCommandResultSummary {
    [CmdletBinding()]
    param(
        [string]$CommandSummary,
        [AllowNull()][string]$Output
    )

    $exitCode = $null
    $wallTime = $null
    $timedOut = $false

    if (-not [string]::IsNullOrWhiteSpace($Output)) {
        $exitMatch = [regex]::Match($Output, 'Exit code:\s*(-?\d+)')
        if ($exitMatch.Success) {
            $exitCode = $exitMatch.Groups[1].Value
        }

        $wallMatch = [regex]::Match($Output, 'Wall time:\s*([^\r\n]+)')
        if ($wallMatch.Success) {
            $wallTime = $wallMatch.Groups[1].Value.Trim()
        }

        if ($Output -match 'command timed out after') {
            $timedOut = $true
        }
    }

    $statusText = if ($timedOut) {
        'Timed out'
    }
    elseif ($exitCode -eq '0') {
        'Completed'
    }
    elseif ($exitCode) {
        'Failed'
    }
    else {
        'Finished'
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($statusText)
    if (-not [string]::IsNullOrWhiteSpace($CommandSummary)) {
        $parts.Add($CommandSummary)
    }

    $suffix = [System.Collections.Generic.List[string]]::new()
    if ($exitCode) {
        $suffix.Add("exit $exitCode")
    }
    if ($wallTime) {
        $suffix.Add($wallTime)
    }

    if ($suffix.Count -gt 0) {
        return ('{0} ({1})' -f ($parts -join ': '), ($suffix -join ', '))
    }

    return ($parts -join ': ')
}

function Get-CodexToolCallSummary {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Name,
        [AllowNull()][string]$Arguments
    )

    $displayName = Get-CodexTelemetryDisplayName -Name $Name
    $argumentSummary = Get-CodexTelemetryArgumentSummary -Arguments $Arguments -PreferKey @(
        'issue_number',
        'pr_number',
        'repo',
        'repo_full_name',
        'repository_full_name',
        'query',
        'path',
        'branch_name',
        'name'
    )

    if (-not [string]::IsNullOrWhiteSpace($argumentSummary)) {
        return ('{0} {1}' -f $displayName, $argumentSummary)
    }

    return $displayName
}

function Get-CodexEventSummary {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [string]$Fallback,
        [int]$MaxLength = 180
    )

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        return (ConvertTo-CodexTelemetryValueText -Value $Text -MaxLength $MaxLength)
    }

    return $Fallback
}

function Get-CodexNestedFirstValue {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string[]]$PropertyName,
        [int]$MaxDepth = 4
    )

    if ($null -eq $InputObject -or $MaxDepth -lt 0) {
        return $null
    }

    foreach ($name in $PropertyName) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property.Value
        }
    }

    if ($InputObject -is [string]) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            foreach ($name in $PropertyName) {
                if ([string]::Equals([string]$key, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $value = $InputObject[$key]
                    if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                        return $value
                    }
                }
            }
        }
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        foreach ($item in @($InputObject)) {
            $value = Get-CodexNestedFirstValue -InputObject $item -PropertyName $PropertyName -MaxDepth ($MaxDepth - 1)
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }

        return $null
    }

    foreach ($property in @($InputObject.PSObject.Properties)) {
        $value = $property.Value
        if ($null -eq $value -or $value -is [string]) {
            continue
        }

        $nested = Get-CodexNestedFirstValue -InputObject $value -PropertyName $PropertyName -MaxDepth ($MaxDepth - 1)
        if ($null -ne $nested -and -not [string]::IsNullOrWhiteSpace([string]$nested)) {
            return $nested
        }
    }

    return $null
}

function New-CodexEvent {
    [CmdletBinding()]
    param(
        [string]$ThreadId,
        [string]$ThreadName,
        [string]$Project,
        [string]$TurnId,
        [int]$Index,
        [string]$Kind,
        [string]$Type,
        [string]$Name,
        [string]$Phase,
        [string]$Summary,
        [string]$Text,
        [string]$Source = 'SessionJsonl',
        [string]$SessionPath,
        [AllowNull()][Nullable[DateTimeOffset]]$Timestamp,
        [AllowNull()]$RawEvent,
        [switch]$IncludeRaw
    )

    if ([string]::IsNullOrWhiteSpace($Kind)) {
        $Kind = 'Unknown'
    }

    $timestampValue = if ($null -ne $Timestamp) { [DateTimeOffset]$Timestamp } else { $null }
    $eventId = if (-not [string]::IsNullOrWhiteSpace($ThreadId)) {
        '{0}:{1}' -f (Get-CodexCompactId -Id $ThreadId -Length 8), $Index
    }
    else {
        'event:{0}' -f $Index
    }

    $event = [PSCustomObject]@{
        Id          = $eventId
        TaskId      = $ThreadId
        ThreadId    = $ThreadId
        ThreadName  = $ThreadName
        Project     = $Project
        TurnId      = $TurnId
        Index       = $Index
        Kind        = $Kind
        Type        = $Type
        Name        = $Name
        Phase       = $Phase
        Timestamp   = if ($null -ne $timestampValue) { $timestampValue.ToString('o') } else { $null }
        When        = if ($null -ne $timestampValue) { Get-CodexDisplayTimestamp -Timestamp $timestampValue } else { $null }
        Summary     = $Summary
        Text        = $Text
        Source      = $Source
        SessionPath = $SessionPath
    }

    if ($IncludeRaw) {
        $event | Add-Member -NotePropertyName RawEvent -NotePropertyValue $RawEvent -Force
        $event.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexEvent.Raw')
        if (-not ($event.PSObject.TypeNames -contains 'PSUnplugged.CodexEvent')) {
            $event.PSObject.TypeNames.Insert(1, 'PSUnplugged.CodexEvent')
        }
    }
    elseif (-not ($event.PSObject.TypeNames -contains 'PSUnplugged.CodexEvent')) {
        $event.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexEvent')
    }
    return $event
}

function ConvertTo-CodexEventsFromThreadRecord {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread,
        [string]$ThreadName,
        [string]$Project,
        [switch]$IncludeRaw
    )

    if ($null -eq $Thread) {
        return @()
    }

    $threadId = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('id', 'Id', 'threadId', 'ThreadId'))
    $events = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($turn in @($Thread.turns)) {
        $turnId = [string](Get-CodexFirstValue -InputObject $turn -PropertyName @('id', 'Id', 'turnId', 'TurnId'))
        foreach ($turnItem in @($turn.items)) {
            $itemType = [string](Get-CodexFirstValue -InputObject $turnItem -PropertyName @('type', 'Type'))
            $kind = switch ($itemType) {
                'userMessage' { 'UserMessage' }
                'agentMessage' { 'AgentMessage' }
                default { $null }
            }
            if ([string]::IsNullOrWhiteSpace($kind)) {
                continue
            }

            $text = Get-CodexTranscriptText -InputObject $turnItem
            $timestamp = $null
            foreach ($value in @(
                    (Get-CodexFirstValue -InputObject $turnItem -PropertyName @('createdAt', 'CreatedAt', 'timestamp', 'Timestamp', 'updatedAt', 'UpdatedAt')),
                    (Get-CodexFirstValue -InputObject $turn -PropertyName @('createdAt', 'CreatedAt', 'timestamp', 'Timestamp', 'updatedAt', 'UpdatedAt'))
                )) {
                $timestamp = ConvertTo-CodexDateTimeOffset -Value $value
                if ($timestamp) {
                    break
                }
            }

            $index++
            $events.Add((New-CodexEvent -ThreadId $threadId -ThreadName $ThreadName -Project $Project -TurnId $turnId -Index $index -Kind $kind -Type $itemType -Phase ([string](Get-CodexFirstValue -InputObject $turnItem -PropertyName @('phase', 'Phase'))) -Summary (Get-CodexEventSummary -Text $text -Fallback $kind) -Text $text -Source 'ThreadRecord' -Timestamp $timestamp -RawEvent $turnItem -IncludeRaw:$IncludeRaw))
        }
    }

    return @($events)
}

function ConvertTo-CodexEventsFromSessionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ThreadId,
        [string]$ThreadName,
        [string]$Project,
        [switch]$IncludeRaw
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $events = [System.Collections.Generic.List[object]]::new()
    $callMetadata = @{}
    $currentTurnId = $null
    $resolvedThreadId = $ThreadId
    $index = 0

    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        $entryType = [string](Get-CodexFirstValue -InputObject $entry -PropertyName @('type', 'Type'))
        $method = [string](Get-CodexFirstValue -InputObject $entry -PropertyName @('method', 'Method'))
        $payload = if ($entry.PSObject.Properties['payload']) { $entry.payload } else { $null }
        $params = if ($entry.PSObject.Properties['params']) { $entry.params } else { $null }
        $timestamp = ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $entry -PropertyName @('timestamp', 'Timestamp'))
        $kind = $null
        $name = $null
        $phase = $null
        $summary = $null
        $text = $null
        $type = $entryType

        if ($entryType -eq 'session_meta') {
            if ([string]::IsNullOrWhiteSpace($resolvedThreadId)) {
                $resolvedThreadId = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('id', 'Id'))
            }
            $kind = 'SessionMeta'
            $summary = 'Session metadata'
        }
        elseif ($entryType -eq 'turn_context') {
            $currentTurnId = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('turn_id', 'turnId', 'TurnId'))
            $kind = 'TurnContext'
            $summary = if (-not [string]::IsNullOrWhiteSpace($currentTurnId)) { "Turn context $currentTurnId" } else { 'Turn context' }
        }
        elseif ($entryType -eq 'event_msg') {
            $payloadType = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('type', 'Type'))
            $type = $payloadType
            switch ($payloadType) {
                'task_started' {
                    $currentTurnId = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('turn_id', 'turnId', 'TurnId'))
                    $kind = 'TaskStarted'
                    $summary = 'Task started'
                }
                'task_complete' {
                    $kind = 'TaskCompleted'
                    $phase = 'final_answer'
                    $text = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('last_agent_message', 'lastAgentMessage'))
                    $summary = Get-CodexEventSummary -Text $text -Fallback 'Task completed'
                }
                'user_message' {
                    $kind = 'UserMessage'
                    $text = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('message', 'Message'))
                    $summary = Get-CodexEventSummary -Text $text -Fallback 'User message'
                }
                'agent_message' {
                    $kind = 'AgentMessage'
                    $phase = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('phase', 'Phase'))
                    $text = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('message', 'Message'))
                    $summary = Get-CodexEventSummary -Text $text -Fallback 'Agent message'
                }
                'agent_reasoning' {
                    $kind = 'Reasoning'
                    $phase = 'reasoning'
                    $text = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('text', 'Text'))
                    $summary = Get-CodexEventSummary -Text $text -Fallback 'Agent reasoning'
                }
                default {
                    $kind = 'EventMessage'
                    $name = $payloadType
                    $summary = if (-not [string]::IsNullOrWhiteSpace($payloadType)) { $payloadType } else { 'Event message' }
                }
            }
        }
        elseif ($entryType -eq 'response_item') {
            $payloadType = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('type', 'Type'))
            $type = $payloadType
            switch ($payloadType) {
                'message' {
                    $role = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('role', 'Role'))
                    $kind = if ($role -eq 'user') { 'UserMessage' } else { 'AgentMessage' }
                    $phase = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('phase', 'Phase'))
                    $text = Get-CodexTranscriptText -InputObject $payload
                    $summary = Get-CodexEventSummary -Text $text -Fallback $kind
                }
                'function_call' {
                    $callId = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('call_id', 'callId'))
                    $callName = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('name', 'Name'))
                    $callArguments = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('arguments', 'Arguments'))
                    $name = $callName
                    if ($callName -eq 'shell_command') {
                        $kind = 'Command'
                        $phase = 'command'
                        $summary = Get-CodexShellCommandSummary -Arguments $callArguments
                    }
                    else {
                        $kind = 'ToolCall'
                        $phase = 'tool'
                        $summary = Get-CodexToolCallSummary -Name $callName -Arguments $callArguments
                    }
                    $text = $summary
                    if (-not [string]::IsNullOrWhiteSpace($callId)) {
                        $callMetadata[$callId] = @{
                            Kind    = $kind
                            Name    = $callName
                            Summary = $summary
                        }
                    }
                }
                'function_call_output' {
                    $callId = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('call_id', 'callId'))
                    $output = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('output', 'Output'))
                    $callInfo = if (-not [string]::IsNullOrWhiteSpace($callId) -and $callMetadata.ContainsKey($callId)) { $callMetadata[$callId] } else { $null }
                    $name = if ($callInfo) { [string]$callInfo.Name } else { $callId }
                    if ($callInfo -and $callInfo.Kind -eq 'Command') {
                        $kind = 'CommandResult'
                        $phase = 'command'
                        $summary = Get-CodexShellCommandResultSummary -CommandSummary ([string]$callInfo.Summary) -Output $output
                    }
                    else {
                        $kind = 'ToolResult'
                        $phase = 'tool'
                        $summary = if ($callInfo -and -not [string]::IsNullOrWhiteSpace([string]$callInfo.Summary)) {
                            'Finished: {0}' -f [string]$callInfo.Summary
                        }
                        else {
                            Get-CodexEventSummary -Text $output -Fallback 'Tool result'
                        }
                    }
                    $text = $output
                }
                'reasoning' {
                    $kind = 'Reasoning'
                    $phase = 'reasoning'
                    $text = Get-CodexTranscriptText -InputObject $payload
                    $summary = Get-CodexEventSummary -Text $text -Fallback 'Reasoning'
                }
                default {
                    $kind = 'ResponseItem'
                    $name = $payloadType
                    $summary = if (-not [string]::IsNullOrWhiteSpace($payloadType)) { $payloadType } else { 'Response item' }
                }
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($method)) {
            if ($method -like '*/delta') {
                continue
            }

            $type = $method
            switch ($method) {
                'item/commandExecution/requestApproval' {
                    $kind = 'ApprovalRequested'
                    $name = 'commandExecution'
                    $commandText = [string](Get-CodexNestedFirstValue -InputObject $params -PropertyName @('command', 'Command'))
                    $summary = if (-not [string]::IsNullOrWhiteSpace($commandText)) {
                        'Command approval requested: {0}' -f (ConvertTo-CodexTelemetryValueText -Value $commandText -MaxLength 120)
                    }
                    else {
                        'Command approval requested'
                    }
                    $text = $commandText
                }
                'item/fileChange/requestApproval' {
                    $kind = 'ApprovalRequested'
                    $name = 'fileChange'
                    $pathText = [string](Get-CodexNestedFirstValue -InputObject $params -PropertyName @('path', 'Path', 'filePath', 'file_path'))
                    $summary = if (-not [string]::IsNullOrWhiteSpace($pathText)) {
                        'File change approval requested: {0}' -f (ConvertTo-CodexTelemetryValueText -Value $pathText -MaxLength 120)
                    }
                    else {
                        'File change approval requested'
                    }
                    $text = $pathText
                }
                'turn/completed' {
                    $kind = 'TurnCompleted'
                    $summary = 'Turn completed'
                }
                'item/completed' {
                    $kind = 'ItemCompleted'
                    $item = if ($params -and $params.PSObject.Properties['item']) { $params.item } else { $null }
                    $name = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('type', 'Type'))
                    $summary = if (-not [string]::IsNullOrWhiteSpace($name)) { "Item completed: $name" } else { 'Item completed' }
                }
                default {
                    $kind = 'Notification'
                    $name = $method
                    $summary = $method
                }
            }
        }
        else {
            $kind = 'Unknown'
            $summary = if (-not [string]::IsNullOrWhiteSpace($entryType)) { $entryType } else { 'Unknown event' }
        }

        $index++
        $events.Add((New-CodexEvent -ThreadId $resolvedThreadId -ThreadName $ThreadName -Project $Project -TurnId $currentTurnId -Index $index -Kind $kind -Type $type -Name $name -Phase $phase -Summary $summary -Text $text -Source 'SessionJsonl' -SessionPath $Path -Timestamp $timestamp -RawEvent $entry -IncludeRaw:$IncludeRaw))
    }

    return @($events)
}

function ConvertTo-CodexTranscriptItemsFromThreadRecord {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread,
        [string]$ThreadName,
        [string]$Project
    )

    if ($null -eq $Thread) {
        return @()
    }

    $threadId = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('id', 'Id', 'threadId', 'ThreadId'))
    $items = [System.Collections.Generic.List[object]]::new()
    $index = 0
    $assistantOutputSeen = $false

    foreach ($turn in @($Thread.turns)) {
        $turnId = [string](Get-CodexFirstValue -InputObject $turn -PropertyName @('id', 'Id', 'turnId', 'TurnId'))
        foreach ($turnItem in @($turn.items)) {
            $itemType = [string](Get-CodexFirstValue -InputObject $turnItem -PropertyName @('type', 'Type'))
            $role = switch ($itemType) {
                'userMessage' { 'user' }
                'agentMessage' { 'assistant' }
                default { $null }
            }

            if ([string]::IsNullOrWhiteSpace($role)) {
                continue
            }

            $text = Get-CodexTranscriptText -InputObject $turnItem
            if ([string]::IsNullOrWhiteSpace($text)) {
                continue
            }

            $timestamp = $null
            foreach ($value in @(
                    (Get-CodexFirstValue -InputObject $turnItem -PropertyName @('createdAt', 'CreatedAt', 'timestamp', 'Timestamp', 'updatedAt', 'UpdatedAt')),
                    (Get-CodexFirstValue -InputObject $turn -PropertyName @('createdAt', 'CreatedAt', 'timestamp', 'Timestamp', 'updatedAt', 'UpdatedAt'))
                )) {
                $timestamp = ConvertTo-CodexDateTimeOffset -Value $value
                if ($timestamp) {
                    break
                }
            }

            $index++
            $items.Add((New-CodexTranscriptItem -ThreadId $threadId -ThreadName $ThreadName -Project $Project -TurnId $turnId -Index $index -Role $role -ItemType $itemType -Phase ([string](Get-CodexFirstValue -InputObject $turnItem -PropertyName @('phase', 'Phase'))) -Text $text -Timestamp $timestamp))
        }
    }

    return @($items)
}

function ConvertTo-CodexTranscriptItemsFromSessionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ThreadId,
        [string]$ThreadName,
        [string]$Project,
        [string[]]$TelemetryType
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $items = [System.Collections.Generic.List[object]]::new()
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $callMetadata = @{}
    $currentTurnId = $null
    $resolvedThreadId = $ThreadId
    $index = 0

    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        if ($entry.type -eq 'session_meta' -and [string]::IsNullOrWhiteSpace($resolvedThreadId)) {
            $resolvedThreadId = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('id', 'Id'))
        }

        if ($entry.type -eq 'turn_context' -and $entry.payload.turn_id) {
            $currentTurnId = [string]$entry.payload.turn_id
        }
        elseif ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'task_started' -and $entry.payload.turn_id) {
            $currentTurnId = [string]$entry.payload.turn_id
        }

        $role = $null
        $itemType = $null
        $phase = $null
        $text = $null

        if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'user_message') {
            $role = 'user'
            $itemType = 'userMessage'
            $text = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('message', 'Message'))
        }
        elseif ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'agent_message') {
            $role = 'assistant'
            $itemType = 'agentMessage'
            $phase = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('phase', 'Phase'))
            $text = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('message', 'Message'))
        }
        elseif ($entry.type -eq 'response_item' -and $entry.payload.type -eq 'message' -and $entry.payload.role -eq 'assistant') {
            $role = 'assistant'
            $itemType = 'agentMessage'
            $phase = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('phase', 'Phase'))
            $text = Get-CodexTranscriptText -InputObject $entry.payload
        }
        elseif ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'task_complete') {
            $lastAgentMessage = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('last_agent_message', 'lastAgentMessage'))
            if (-not [string]::IsNullOrWhiteSpace($lastAgentMessage)) {
                $role = 'assistant'
                $itemType = 'agentMessage'
                $phase = 'final_answer'
                $text = $lastAgentMessage
            }
            elseif (-not $assistantOutputSeen) {
                $role = 'assistant'
                $itemType = 'agentMessage'
                $phase = 'failed'
                $text = 'Task completed with no assistant output.'
            }
        }
        elseif ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'agent_reasoning' -and (Test-CodexTelemetryTypeEnabled -TelemetryType $TelemetryType -Type 'reasoning')) {
            $role = 'assistant'
            $itemType = 'agentReasoning'
            $phase = 'reasoning'
            $text = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('text', 'Text'))
        }
        elseif ($entry.type -eq 'response_item' -and $entry.payload.type -eq 'function_call') {
            $callId = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('call_id', 'callId'))
            $callName = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('name', 'Name'))
            $callArguments = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('arguments', 'Arguments'))

            if ($callName -eq 'shell_command' -and (Test-CodexTelemetryTypeEnabled -TelemetryType $TelemetryType -Type 'commands')) {
                $commandSummary = Get-CodexShellCommandSummary -Arguments $callArguments
                if (-not [string]::IsNullOrWhiteSpace($callId)) {
                    $callMetadata[$callId] = @{
                        Kind    = 'command'
                        Summary = $commandSummary
                    }
                }

                $role = 'assistant'
                $itemType = 'command'
                $phase = 'command'
                $text = if (-not [string]::IsNullOrWhiteSpace($commandSummary)) {
                    "Running: $commandSummary"
                }
                else {
                    'Running command'
                }
            }
            elseif ($callName -ne 'shell_command' -and (Test-CodexTelemetryTypeEnabled -TelemetryType $TelemetryType -Type 'tools')) {
                $toolSummary = Get-CodexToolCallSummary -Name $callName -Arguments $callArguments
                if (-not [string]::IsNullOrWhiteSpace($callId)) {
                    $callMetadata[$callId] = @{
                        Kind    = 'tool'
                        Summary = $toolSummary
                    }
                }

                $role = 'assistant'
                $itemType = 'toolCall'
                $phase = 'tool'
                $text = $toolSummary
            }
        }
        elseif ($entry.type -eq 'response_item' -and $entry.payload.type -eq 'function_call_output') {
            $callId = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('call_id', 'callId'))
            if (-not [string]::IsNullOrWhiteSpace($callId) -and $callMetadata.ContainsKey($callId)) {
                $callInfo = $callMetadata[$callId]
                if ($callInfo.Kind -eq 'command' -and (Test-CodexTelemetryTypeEnabled -TelemetryType $TelemetryType -Type 'commands')) {
                    $role = 'assistant'
                    $itemType = 'command'
                    $phase = 'command'
                    $text = Get-CodexShellCommandResultSummary -CommandSummary ([string]$callInfo.Summary) -Output ([string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('output', 'Output')))
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($role) -or [string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $timestamp = ConvertTo-CodexDateTimeOffset -Value $entry.timestamp
        $dedupeTimestamp = if ($timestamp) { $timestamp.ToString('o') } else { [string]$entry.timestamp }
        $dedupeKey = '{0}|{1}|{2}|{3}' -f $role, $phase, $dedupeTimestamp, $text
        if (-not $seenKeys.Add($dedupeKey)) {
            continue
        }

        $index++
        $items.Add((New-CodexTranscriptItem -ThreadId $resolvedThreadId -ThreadName $ThreadName -Project $Project -TurnId $currentTurnId -Index $index -Role $role -ItemType $itemType -Phase $phase -Text $text -Timestamp $timestamp))
        if ($role -eq 'assistant' -and $itemType -eq 'agentMessage') {
            $assistantOutputSeen = $true
        }
    }

    return @($items)
}

function Get-CodexNormalizedValue {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return ($Value.Trim().TrimEnd('\', '/').ToLowerInvariant())
}

function Get-CodexNormalizedPathValue {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return (Get-CodexNormalizedValue -Value (($Path.Trim()) -replace '/', '\'))
}

function Get-CodexNormalizedThreadId {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ThreadId
    )

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return $null
    }

    $normalized = $ThreadId.Trim()
    if ($normalized.StartsWith('urn:uuid:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(9)
    }

    $normalized = $normalized.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    return ($normalized -replace '-', '')
}

function Resolve-CodexProjectLocation {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path,
        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = (Get-Location).Path
    }

    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    if (-not $AllowMissing) {
        throw "Path not found: $Path"
    }

    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }
    catch {
        return [System.IO.Path]::GetFullPath($Path, (Get-Location).Path)
    }
}

function Get-CodexGitMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{
            IsGitRepo = $false
            Root      = $null
            Branch    = $null
            RemoteUrl = $null
        }
    }

    $root = (& git -C $Path rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
        return [PSCustomObject]@{
            IsGitRepo = $false
            Root      = $null
            Branch    = $null
            RemoteUrl = $null
        }
    }

    $branch = (& git -C $root rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        $branch = $null
    }

    $remoteUrl = (& git -C $root remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
        $remoteUrl = $null
    }

    return [PSCustomObject]@{
        IsGitRepo = $true
        Root      = $root.Trim()
        Branch    = if ($branch) { $branch.Trim() } else { $null }
        RemoteUrl = if ($remoteUrl) { $remoteUrl.Trim() } else { $null }
    }
}

function Get-CodexProjectIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Name
    )

    $resolvedPath = Resolve-CodexProjectLocation -Path $Path
    $git = Get-CodexGitMetadata -Path $resolvedPath
    $explicitManifestPath = Join-Path $resolvedPath '.psunplugged-project.json'
    $hasExplicitManifest = Test-Path -LiteralPath $explicitManifestPath
    $projectPath = if ($hasExplicitManifest) { $resolvedPath } elseif ($git.IsGitRepo) { $git.Root } else { $resolvedPath }
    $manifestPath = if ($hasExplicitManifest) { $explicitManifestPath } else { Join-Path $projectPath '.psunplugged-project.json' }
    $manifest = $null

    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        }
        catch {
            $manifest = $null
        }
    }

    $projectName = $Name
    if ([string]::IsNullOrWhiteSpace($projectName) -and $manifest -and $manifest.name) {
        $projectName = [string]$manifest.name
    }
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = Split-Path -Path $projectPath -Leaf
    }

    $kind = if ($manifest -and $manifest.kind) {
        [string]$manifest.kind
    }
    elseif ($git.IsGitRepo) {
        'GitRepository'
    }
    else {
        'Workspace'
    }

    $projectKeySource = if ($manifest -and $projectPath -ne $git.Root) {
        "path::$projectPath"
    }
    elseif ($git.RemoteUrl) {
        "git::$($git.RemoteUrl)"
    }
    else {
        "path::$projectPath"
    }

    return [PSCustomObject]@{
        ProjectKey   = Get-CodexNormalizedValue -Value $projectKeySource
        Name         = $projectName
        Path         = $projectPath
        Kind         = $kind
        Branch       = $git.Branch
        RemoteUrl    = $git.RemoteUrl
        ManifestPath = if (Test-Path -LiteralPath $manifestPath) { $manifestPath } else { $null }
    }
}

function Find-CodexCatalogProjectRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog,
        [Parameter(Mandatory)][string]$ProjectKey
    )

    return @($Catalog.projects) | Where-Object { $_.ProjectKey -eq $ProjectKey } | Select-Object -First 1
}

function Set-CodexCatalogProjectRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog,
        [Parameter(Mandatory)][PSCustomObject]$ProjectIdentity
    )

    if (-not $Catalog.PSObject.Properties['projects']) {
        $Catalog | Add-Member -NotePropertyName projects -NotePropertyValue @() -Force
    }

    $existing = Find-CodexCatalogProjectRecord -Catalog $Catalog -ProjectKey $ProjectIdentity.ProjectKey
    $now = Get-PSUnpluggedUtcNowString

    $record = [PSCustomObject]@{
        ProjectKey   = $ProjectIdentity.ProjectKey
        Name         = $ProjectIdentity.Name
        Path         = $ProjectIdentity.Path
        Kind         = $ProjectIdentity.Kind
        Branch       = $ProjectIdentity.Branch
        RemoteUrl    = $ProjectIdentity.RemoteUrl
        ManifestPath = $ProjectIdentity.ManifestPath
        RegisteredAt = if ($existing) { $existing.RegisteredAt } else { $now }
        UpdatedAt    = $now
    }

    $projects = @($Catalog.projects | Where-Object { $_.ProjectKey -ne $ProjectIdentity.ProjectKey })
    $projects += $record
    $Catalog | Add-Member -NotePropertyName projects -NotePropertyValue $projects -Force

    return $record
}

function Find-CodexCatalogThreadRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog,
        [Parameter(Mandatory)][string]$ThreadId
    )

    $normalizedThreadId = Get-CodexNormalizedThreadId -ThreadId $ThreadId
    if ([string]::IsNullOrWhiteSpace($normalizedThreadId)) {
        return $null
    }

    return @($Catalog.threads) |
    Where-Object {
        (Get-CodexNormalizedThreadId -ThreadId ([string]$_.ThreadId)) -eq $normalizedThreadId
    } |
    Select-Object -First 1
}

function Set-CodexCatalogThreadRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog,
        [Parameter(Mandatory)][hashtable]$Properties
    )

    if (-not $Catalog.PSObject.Properties['threads']) {
        $Catalog | Add-Member -NotePropertyName threads -NotePropertyValue @() -Force
    }

    $threadId = [string]$Properties.ThreadId
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        throw "ThreadId is required."
    }

    $existing = Find-CodexCatalogThreadRecord -Catalog $Catalog -ThreadId $threadId
    if ($existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.ThreadId)) {
        $threadId = [string]$existing.ThreadId
    }

    $normalizedThreadId = Get-CodexNormalizedThreadId -ThreadId $threadId
    $now = Get-PSUnpluggedUtcNowString

    $record = [ordered]@{
        ThreadId       = $threadId
        Name           = $null
        ProjectKey     = $null
        ProjectName    = $null
        Path           = $null
        PromptPreview  = $null
        Tags           = @()
        Pinned         = $false
        Archived       = $false
        CreatedAt      = $now
        LastOpenedAt   = $null
        LastActivityAt = $null
        Model          = $null
        ApprovalPolicy = $null
        SandboxType    = $null
        Source         = 'PSUnplugged'
        UpdatedAt      = $now
    }

    if ($existing) {
        foreach ($property in $existing.PSObject.Properties) {
            $record[$property.Name] = $property.Value
        }
    }

    foreach ($key in $Properties.Keys) {
        $record[$key] = $Properties[$key]
    }

    if (-not $record.CreatedAt) {
        $record.CreatedAt = $now
    }

    $record.UpdatedAt = $now
    $record.Tags = @($record.Tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    $threads = @(
        $Catalog.threads | Where-Object {
            (Get-CodexNormalizedThreadId -ThreadId ([string]$_.ThreadId)) -ne $normalizedThreadId
        }
    )
    $threads += [PSCustomObject]$record
    $Catalog | Add-Member -NotePropertyName threads -NotePropertyValue @(Merge-CodexCatalogThreadRecords -Thread $threads) -Force

    return ([PSCustomObject]$record)
}

function Resolve-CodexThreadList {
    [CmdletBinding()]
    param(
        [AllowNull()]$ThreadList
    )

    if ($null -eq $ThreadList) {
        return @()
    }

    foreach ($propertyName in 'threads', 'items', 'data', 'results') {
        if ($ThreadList.PSObject.Properties.Name -contains $propertyName) {
            return @($ThreadList.$propertyName)
        }
    }

    if ($ThreadList -is [System.Collections.IEnumerable] -and -not ($ThreadList -is [string])) {
        return @($ThreadList)
    }

    return @($ThreadList)
}

function Get-CodexFirstValue {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string[]]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    foreach ($name in $PropertyName) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property.Value
        }
    }

    return $null
}

function Get-CodexThreadIdentifier {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread
    )

    return [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('ThreadId', 'threadId', 'id', 'Id'))
}

function Get-CodexCompactId {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Id,
        [int]$Length = 18
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $null
    }

    if ($Id.Length -le $Length) {
        return $Id
    }

    return $Id.Substring(0, $Length)
}

function Get-CodexThreadTitle {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread,
        [AllowNull()]$Record
    )

    $title = $null
    if ($Record) {
        $title = Get-CodexFirstValue -InputObject $Record -PropertyName @('Name', 'PromptPreview')
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = Get-CodexFirstValue -InputObject $Thread -PropertyName @('title', 'name', 'summary', 'subject')
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = 'Untitled thread'
    }

    return [string]$title
}

function ConvertTo-CodexDateTimeOffset {
    [CmdletBinding()]
    param(
        [AllowNull()]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [DateTimeOffset]) {
        return $Value
    }

    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]$Value)
    }

    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) {
        try {
            $numericValue = [int64]$Value
            if ([Math]::Abs($numericValue) -gt 100000000000) {
                return [DateTimeOffset]::FromUnixTimeMilliseconds($numericValue)
            }

            return [DateTimeOffset]::FromUnixTimeSeconds($numericValue)
        }
        catch {
            return $null
        }
    }

    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return (ConvertTo-CodexDateTimeOffset -Value ([int64][Math]::Round([double]$Value)))
    }

    if ($Value -is [string]) {
        $trimmedValue = $Value.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedValue)) {
            return $null
        }

        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($trimmedValue, [ref]$parsed)) {
            return $parsed
        }

        $numericValue = 0L
        if ([int64]::TryParse($trimmedValue, [ref]$numericValue)) {
            return (ConvertTo-CodexDateTimeOffset -Value $numericValue)
        }

        return $null
    }

    if ($Value.PSObject) {
        foreach ($propertyName in 'value', 'Value', 'iso', 'Iso', 'dateTime', 'DateTime', 'timestamp', 'Timestamp', 'unixMs', 'UnixMs', 'unix_ms', 'milliseconds', 'Milliseconds', 'ms', 'Ms', 'seconds', 'Seconds') {
            $property = $Value.PSObject.Properties[$propertyName]
            if ($property -and $null -ne $property.Value) {
                $parsed = ConvertTo-CodexDateTimeOffset -Value $property.Value
                if ($parsed) {
                    return $parsed
                }
            }
        }
    }

    return $null
}

function Get-CodexUuidV7Timestamp {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $null
    }

    $hex = ($Id -replace '[^0-9a-fA-F]', '')
    if ($hex.Length -lt 13) {
        return $null
    }

    if ($hex.Substring(12, 1).ToLowerInvariant() -ne '7') {
        return $null
    }

    try {
        $milliseconds = [Convert]::ToInt64($hex.Substring(0, 12), 16)
        return [DateTimeOffset]::FromUnixTimeMilliseconds($milliseconds)
    }
    catch {
        return $null
    }
}

function Get-CodexThreadTimestamp {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread,
        [AllowNull()]$Record
    )

    $values = @()
    foreach ($source in @($Thread, $Record)) {
        if ($null -eq $source) { continue }
        foreach ($propertyName in 'lastActivityAt', 'LastActivityAt', 'last_activity_at', 'updatedAt', 'UpdatedAt', 'updated_at', 'lastUpdatedAt', 'last_updated_at', 'createdAt', 'CreatedAt', 'created_at') {
            $property = $source.PSObject.Properties[$propertyName]
            if ($property -and $property.Value) {
                $values += $property.Value
            }
        }
    }

    foreach ($value in $values) {
        $parsed = ConvertTo-CodexDateTimeOffset -Value $value
        if ($parsed) {
            return $parsed
        }
    }

    foreach ($source in @($Thread, $Record)) {
        $parsed = Get-CodexUuidV7Timestamp -Id (Get-CodexThreadIdentifier -Thread $source)
        if ($parsed) {
            return $parsed
        }
    }

    return $null
}

function Get-CodexDisplayTimestamp {
    [CmdletBinding()]
    param(
        [AllowNull()][DateTimeOffset]$Timestamp
    )

    if ($null -eq $Timestamp) {
        return $null
    }

    $localTimestamp = $Timestamp.ToLocalTime()
    $now = [DateTimeOffset]::Now

    if ($localTimestamp.Date -eq $now.Date) {
        return $localTimestamp.ToString('HH:mm')
    }

    if ($localTimestamp.Year -eq $now.Year) {
        return $localTimestamp.ToString('MM-dd HH:mm')
    }

    return $localTimestamp.ToString('yyyy-MM-dd')
}

function ConvertTo-CodexProjectOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Record,
        [hashtable]$StatsLookup,
        [switch]$Details
    )

    $recordProjectKey = Get-CodexNormalizedValue -Value $Record.ProjectKey
    $recordPath = Get-CodexNormalizedPathValue -Path $Record.Path
    $stats = $null
    foreach ($lookupKey in @($recordProjectKey, $recordPath)) {
        if ([string]::IsNullOrWhiteSpace($lookupKey)) { continue }
        if ($StatsLookup -and $StatsLookup.ContainsKey($lookupKey)) {
            $stats = $StatsLookup[$lookupKey]
            break
        }
    }

    $lastThreadAt = if ($stats) {
        ConvertTo-CodexDateTimeOffset -Value $stats.LastThreadAt
    }
    else {
        ConvertTo-CodexDateTimeOffset -Value $Record.UpdatedAt
    }

    $projectOutput = [ordered]@{
        Name         = $Record.Name
        ProjectKey   = $Record.ProjectKey
        Path         = $Record.Path
        Kind         = $Record.Kind
        Branch       = $Record.Branch
        RemoteUrl    = $Record.RemoteUrl
        LastThreadAt = if ($lastThreadAt) { $lastThreadAt.ToString('o') } else { $null }
        LastActive   = if ($lastThreadAt) { Get-CodexDisplayTimestamp -Timestamp $lastThreadAt } else { $null }
        RegisteredAt = $Record.RegisteredAt
        UpdatedAt    = $Record.UpdatedAt
    }

    if ($Details) {
        $activeThreads = if ($stats) { [int]$stats.ActiveThreads } else { 0 }
        $totalThreads = if ($stats) { [int]$stats.TotalThreads } else { 0 }
        $projectOutput.ThreadSummary = "$activeThreads/$totalThreads"
        $projectOutput.Threads = $activeThreads
        $projectOutput.TotalThreads = $totalThreads
        $projectOutput.ThreadCount = $totalThreads
        $projectOutput.ActiveThreadCount = $activeThreads
    }

    $projectObject = [PSCustomObject]$projectOutput
    $projectTypeName = if ($Details) { 'PSUnplugged.CodexProject.Details' } else { 'PSUnplugged.CodexProject' }
    $projectObject.PSObject.TypeNames.Insert(0, $projectTypeName)

    return $projectObject
}

function ConvertTo-CodexProjectRecordFromThreadOutput {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread,
        [switch]$SkipPathResolution
    )

    if ($null -eq $Thread) {
        return $null
    }

    $projectKey = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('ProjectKey', 'projectKey'))
    $projectName = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('Project', 'ProjectName', 'project', 'projectName'))
    $path = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('Path', 'path', 'cwd', 'workingDirectory'))
    $kind = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('ProjectKind', 'projectKind', 'Kind', 'kind'))
    $branch = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('ProjectBranch', 'projectBranch', 'Branch', 'branch'))
    $remoteUrl = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('ProjectRemoteUrl', 'projectRemoteUrl', 'RemoteUrl', 'remoteUrl'))
    $manifestPath = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('ProjectManifestPath', 'projectManifestPath', 'ManifestPath', 'manifestPath'))

    if ([string]::IsNullOrWhiteSpace($kind)) {
        $kind = 'Workspace'
    }

    if ((-not $SkipPathResolution) -and -not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
        try {
            $identity = Get-CodexProjectIdentity -Path $path -Name $projectName
            if (-not [string]::IsNullOrWhiteSpace($identity.ProjectKey)) { $projectKey = $identity.ProjectKey }
            if (-not [string]::IsNullOrWhiteSpace($identity.Name)) { $projectName = $identity.Name }
            if (-not [string]::IsNullOrWhiteSpace($identity.Path)) { $path = $identity.Path }
            if (-not [string]::IsNullOrWhiteSpace($identity.Kind)) { $kind = $identity.Kind }
            $branch = $identity.Branch
            $remoteUrl = $identity.RemoteUrl
            $manifestPath = $identity.ManifestPath
        }
        catch {
        }
    }

    if ([string]::IsNullOrWhiteSpace($projectKey)) {
        if (-not [string]::IsNullOrWhiteSpace($remoteUrl)) {
            $projectKey = Get-CodexNormalizedValue -Value "git::$remoteUrl"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($path)) {
            $projectKey = Get-CodexNormalizedValue -Value "path::$path"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($projectName)) {
            $projectKey = Get-CodexNormalizedValue -Value "name::$projectName"
        }
    }

    if ([string]::IsNullOrWhiteSpace($projectName)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $projectName = Split-Path -Path $path -Leaf
        }
        else {
            $projectName = $projectKey
        }
    }

    if ([string]::IsNullOrWhiteSpace($projectKey)) {
        return $null
    }

    return [PSCustomObject]@{
        ProjectKey   = $projectKey
        Name         = $projectName
        Path         = $path
        Kind         = $kind
        Branch       = $branch
        RemoteUrl    = $remoteUrl
        ManifestPath = $manifestPath
        RegisteredAt = $null
        UpdatedAt    = if ($Thread.LastActivityAt) { $Thread.LastActivityAt } else { $Thread.CreatedAt }
    }
}

function Get-CodexProjectDiscoveryKey {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread
    )

    if ($null -eq $Thread) {
        return $null
    }

    foreach ($value in @(
            [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('ProjectKey', 'projectKey')),
            [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('Path', 'path', 'cwd', 'workingDirectory')),
            [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('Project', 'ProjectName', 'project', 'projectName'))
        )) {
        $normalizedValue = Get-CodexNormalizedValue -Value $value
        if (-not [string]::IsNullOrWhiteSpace($normalizedValue)) {
            return $normalizedValue
        }
    }

    return $null
}

function Test-CodexEphemeralProjectRecord {
    [CmdletBinding()]
    param(
        [AllowNull()]$Record
    )

    if ($null -eq $Record) {
        return $false
    }

    $kind = [string](Get-CodexFirstValue -InputObject $Record -PropertyName @('Kind', 'kind'))
    $remoteUrl = [string](Get-CodexFirstValue -InputObject $Record -PropertyName @('RemoteUrl', 'remoteUrl'))
    if (-not [string]::IsNullOrWhiteSpace($remoteUrl)) {
        return $false
    }

    $path = [string](Get-CodexFirstValue -InputObject $Record -PropertyName @('Path', 'path', 'cwd', 'workingDirectory'))
    $name = [string](Get-CodexFirstValue -InputObject $Record -PropertyName @('Name', 'Project', 'ProjectName', 'name', 'project', 'projectName'))
    $leaf = if (-not [string]::IsNullOrWhiteSpace($path)) { Split-Path -Path $path -Leaf } else { $name }

    return (
        ($kind -eq 'Workspace' -or [string]::IsNullOrWhiteSpace($kind)) -and
        (-not [string]::IsNullOrWhiteSpace($leaf)) -and
        ($leaf -like 'rollout-*')
    )
}

function Get-CodexProjectRecordsFromCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog
    )

    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($record in @($Catalog.projects)) {
        if (-not (Test-CodexEphemeralProjectRecord -Record $record)) {
            $records.Add($record)
        }
    }

    foreach ($threadRecord in @($Catalog.threads)) {
        try {
            $record = ConvertTo-CodexProjectRecordFromThreadOutput -Thread $threadRecord -SkipPathResolution
            if ($record -and -not (Test-CodexEphemeralProjectRecord -Record $record)) {
                $records.Add($record)
            }
        }
        catch {
            Write-Verbose "Skipping catalog thread project discovery for '$($threadRecord.ThreadId)': $($_.Exception.Message)"
        }
    }

    return @($records)
}

function Update-CodexCatalogFromThreadOutputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog,
        [AllowNull()][object[]]$Thread
    )

    $didChange = $false
    foreach ($threadOutput in @($Thread)) {
        if ($null -eq $threadOutput) {
            continue
        }

        $threadId = [string]$threadOutput.ThreadId
        if ([string]::IsNullOrWhiteSpace($threadId)) {
            continue
        }

        $existingThreadRecord = Find-CodexCatalogThreadRecord -Catalog $Catalog -ThreadId $threadId
        $properties = @{
            ThreadId = if ($existingThreadRecord -and -not [string]::IsNullOrWhiteSpace([string]$existingThreadRecord.ThreadId)) {
                [string]$existingThreadRecord.ThreadId
            }
            else {
                $threadId
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.ProjectKey)) { $properties.ProjectKey = $threadOutput.ProjectKey }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.Project)) { $properties.ProjectName = $threadOutput.Project }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.Path)) { $properties.Path = $threadOutput.Path }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.CreatedAt)) { $properties.CreatedAt = $threadOutput.CreatedAt }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.LastActivityAt)) { $properties.LastActivityAt = $threadOutput.LastActivityAt }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.Name) -and $threadOutput.Name -ne 'Untitled thread') { $properties.Name = $threadOutput.Name }
        if ($threadOutput.Archived -or ($existingThreadRecord -and [bool]$existingThreadRecord.Archived) -or (Test-PSUnpluggedThreadArchivedState -ThreadId $threadId)) { $properties.Archived = $true }

        $null = Set-CodexCatalogThreadRecord -Catalog $Catalog -Properties $properties
        $didChange = $true

        $projectRecord = ConvertTo-CodexProjectRecordFromThreadOutput -Thread $threadOutput -SkipPathResolution
        if ($projectRecord -and -not (Test-CodexEphemeralProjectRecord -Record $projectRecord)) {
            $projectIdentity = [PSCustomObject]@{
                ProjectKey   = $projectRecord.ProjectKey
                Name         = $projectRecord.Name
                Path         = $projectRecord.Path
                Kind         = $projectRecord.Kind
                Branch       = $projectRecord.Branch
                RemoteUrl    = $projectRecord.RemoteUrl
                ManifestPath = $projectRecord.ManifestPath
            }

            $null = Set-CodexCatalogProjectRecord -Catalog $Catalog -ProjectIdentity $projectIdentity
            $didChange = $true
        }
    }

    return $didChange
}

function Get-CodexProjectOutputsFromCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog,
        [AllowNull()][string[]]$Name,
        [AllowNull()][string[]]$Path,
        [switch]$Details
    )

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @(Get-CodexProjectRecordsFromCatalog -Catalog $Catalog)) {
        $records.Add($record)
    }

    if ($Path) {
        foreach ($item in $Path) {
            $identity = Get-CodexProjectIdentity -Path $item
            $record = Find-CodexCatalogProjectRecord -Catalog $Catalog -ProjectKey $identity.ProjectKey
            if (-not $record) {
                $record = [PSCustomObject]@{
                    ProjectKey   = $identity.ProjectKey
                    Name         = $identity.Name
                    Path         = $identity.Path
                    Kind         = $identity.Kind
                    Branch       = $identity.Branch
                    RemoteUrl    = $identity.RemoteUrl
                    ManifestPath = $identity.ManifestPath
                    RegisteredAt = $null
                    UpdatedAt    = $null
                }
            }

            if (-not (Test-CodexEphemeralProjectRecord -Record $record)) {
                $records.Add($record)
            }
        }
    }

    $statsLookup = New-CodexProjectStatsLookup -Thread @($Catalog.threads)
    $uniqueRecords = [ordered]@{}
    foreach ($record in @($records)) {
        if ($null -eq $record) {
            continue
        }

        $key = if (-not [string]::IsNullOrWhiteSpace($record.ProjectKey)) {
            $record.ProjectKey
        }
        elseif (-not [string]::IsNullOrWhiteSpace($record.Path)) {
            Get-CodexNormalizedValue -Value "path::$($record.Path)"
        }
        else {
            Get-CodexNormalizedValue -Value "name::$($record.Name)"
        }

        if (-not $uniqueRecords.Contains($key)) {
            $uniqueRecords[$key] = $record
        }
    }

    $results = @(
        $uniqueRecords.Values |
        ForEach-Object { ConvertTo-CodexProjectOutput -Record $_ -StatsLookup $statsLookup -Details:$Details } |
        Sort-Object -Property @{ Expression = { $_.LastThreadAt }; Descending = $true }, Name
    )

    if ($Path) {
        $pathKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in $Path) {
            $identity = Get-CodexProjectIdentity -Path $item
            $null = $pathKeys.Add($identity.ProjectKey)
            $null = $pathKeys.Add($identity.Path)
        }

        $results = @($results | Where-Object {
                $pathKeys.Contains($_.ProjectKey) -or
                $pathKeys.Contains($_.Path)
            })
    }

    if ($Name) {
        $results = @($results | Where-Object {
                foreach ($term in $Name) {
                    if ([string]::IsNullOrWhiteSpace($term)) {
                        continue
                    }

                    $hasWildcard = $term.Contains('*') -or $term.Contains('?') -or $term.Contains('[')
                    if ((-not $hasWildcard) -and (Test-Path -LiteralPath $term)) {
                        $identity = Get-CodexProjectIdentity -Path $term
                        if ($_.ProjectKey -eq $identity.ProjectKey -or $_.Path -eq $identity.Path) {
                            return $true
                        }
                    }

                    if (
                        $_.Name -like $term -or
                        $_.Path -like $term -or
                        $_.ProjectKey -like $term
                    ) {
                        return $true
                    }
                }

                return $false
            })
    }

    return $results
}

function ConvertTo-CodexProjectStatsThreadRecord {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread
    )

    if ($null -eq $Thread) {
        return $null
    }

    $projectRecord = ConvertTo-CodexProjectRecordFromThreadOutput -Thread $Thread
    $threadId = Get-CodexThreadIdentifier -Thread $Thread
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        $threadId = [Guid]::NewGuid().ToString()
    }

    $timestamp = Get-CodexThreadTimestamp -Thread $Thread
    $createdAt = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('CreatedAt', 'createdAt'))
    $archivedProperty = $Thread.PSObject.Properties['Archived']

    return [PSCustomObject]@{
        ThreadId       = $threadId
        ProjectKey     = if ($projectRecord) { $projectRecord.ProjectKey } else { [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('ProjectKey', 'projectKey')) }
        Path           = if ($projectRecord) { $projectRecord.Path } else { [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('Path', 'path', 'cwd', 'workingDirectory')) }
        Archived       = if ($archivedProperty) { [bool]$archivedProperty.Value } else { $false }
        CreatedAt      = $createdAt
        LastActivityAt = if ($timestamp) { $timestamp.ToString('o') } else { $null }
    }
}

function New-CodexProjectStatsLookup {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Thread
    )

    $statsLookup = @{}
    foreach ($threadItem in @($Thread)) {
        if ($null -eq $threadItem) {
            continue
        }

        $statsThread = ConvertTo-CodexProjectStatsThreadRecord -Thread $threadItem
        if ($null -eq $statsThread) {
            continue
        }

        $lookupKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($lookupKey in @(
                (Get-CodexNormalizedValue -Value $statsThread.ProjectKey),
                (Get-CodexNormalizedPathValue -Path $statsThread.Path)
            )) {
            if (-not [string]::IsNullOrWhiteSpace($lookupKey) -and -not $lookupKeys.Contains($lookupKey)) {
                $lookupKeys.Add($lookupKey)
            }
        }

        if ($lookupKeys.Count -eq 0) {
            continue
        }

        $stats = $null
        foreach ($lookupKey in $lookupKeys) {
            if ($statsLookup.ContainsKey($lookupKey)) {
                $stats = $statsLookup[$lookupKey]
                break
            }
        }

        if (-not $stats) {
            $stats = [PSCustomObject]@{
                TotalThreads  = 0
                ActiveThreads = 0
                LastThreadAt  = $null
            }
        }

        $stats.TotalThreads = [int]$stats.TotalThreads + 1
        if (-not $statsThread.Archived) {
            $stats.ActiveThreads = [int]$stats.ActiveThreads + 1
        }

        $threadTimestamp = ConvertTo-CodexDateTimeOffset -Value $statsThread.LastActivityAt
        if ($threadTimestamp -and (($null -eq $stats.LastThreadAt) -or ($threadTimestamp -gt $stats.LastThreadAt))) {
            $stats.LastThreadAt = $threadTimestamp
        }

        foreach ($lookupKey in $lookupKeys) {
            $statsLookup[$lookupKey] = $stats
        }
    }

    return $statsLookup
}

function ConvertTo-CodexThreadOutput {
    [CmdletBinding()]
    param(
        [AllowNull()]$Thread,
        [AllowNull()]$Record,
        [Parameter(Mandatory)][PSCustomObject]$Catalog
    )

    $threadId = if ($Record) { $Record.ThreadId } else { Get-CodexThreadIdentifier -Thread $Thread }
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        return $null
    }

    $path = $null
    if ($Record -and $Record.Path) {
        $path = $Record.Path
    }
    elseif ($Thread) {
        $path = Get-CodexFirstValue -InputObject $Thread -PropertyName @('cwd', 'path', 'workingDirectory')
    }

    $projectKey = $null
    $projectName = $null
    $projectRecord = $null
    $projectIdentity = $null
    if ($Record) {
        $projectKey = $Record.ProjectKey
        $projectName = $Record.ProjectName
        if (-not [string]::IsNullOrWhiteSpace($projectKey)) {
            $projectRecord = Find-CodexCatalogProjectRecord -Catalog $Catalog -ProjectKey $projectKey
        }
    }

    if ($path -and (Test-Path -LiteralPath $path)) {
        if ([string]::IsNullOrWhiteSpace($projectKey)) {
            $projectIdentity = Get-CodexProjectIdentity -Path $path
            $projectKey = $projectIdentity.ProjectKey
            $projectName = $projectIdentity.Name
        }
        elseif (-not $projectRecord -and -not $Record) {
            $projectIdentity = Get-CodexProjectIdentity -Path $path
            if ([string]::IsNullOrWhiteSpace($projectKey)) {
                $projectKey = $projectIdentity.ProjectKey
            }
            if ([string]::IsNullOrWhiteSpace($projectName)) {
                $projectName = $projectIdentity.Name
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($projectName) -and $projectKey) {
        if (-not $projectRecord) {
            $projectRecord = Find-CodexCatalogProjectRecord -Catalog $Catalog -ProjectKey $projectKey
        }
        if ($projectRecord) {
            $projectName = $projectRecord.Name
        }
    }

    if ([string]::IsNullOrWhiteSpace($projectName) -and $Thread) {
        $projectName = [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('project', 'Project', 'projectName', 'ProjectName'))
    }

    $projectKind = if ($projectRecord -and $projectRecord.Kind) {
        $projectRecord.Kind
    }
    elseif ($projectIdentity -and $projectIdentity.Kind) {
        $projectIdentity.Kind
    }
    else {
        $null
    }

    $projectBranch = if ($projectRecord -and $projectRecord.Branch) {
        $projectRecord.Branch
    }
    elseif ($projectIdentity -and $projectIdentity.Branch) {
        $projectIdentity.Branch
    }
    else {
        $null
    }

    $projectRemoteUrl = if ($projectRecord -and $projectRecord.RemoteUrl) {
        $projectRecord.RemoteUrl
    }
    elseif ($projectIdentity -and $projectIdentity.RemoteUrl) {
        $projectIdentity.RemoteUrl
    }
    else {
        $null
    }

    $projectManifestPath = if ($projectRecord -and $projectRecord.ManifestPath) {
        $projectRecord.ManifestPath
    }
    elseif ($projectIdentity -and $projectIdentity.ManifestPath) {
        $projectIdentity.ManifestPath
    }
    else {
        $null
    }

    $timestamp = Get-CodexThreadTimestamp -Thread $Thread -Record $Record
    $statusValue = Get-CodexFirstValue -InputObject $Thread -PropertyName @('status')
    if ($statusValue -and $statusValue.PSObject -and $statusValue.PSObject.Properties['type']) {
        $statusValue = $statusValue.type
    }

    $isArchived = (($Record -and $Record.Archived) -or (Test-PSUnpluggedThreadArchivedState -ThreadId $threadId))
    $status = if ($isArchived) {
        'archived'
    }
    else {
        [string]$statusValue
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = 'active'
    }

    $threadOutput = [PSCustomObject]@{
        Id                  = Get-CodexCompactId -Id $threadId
        ThreadId            = $threadId
        Name                = Get-CodexThreadTitle -Thread $Thread -Record $Record
        Project             = $projectName
        ProjectKey          = $projectKey
        Path                = $path
        ProjectKind         = $projectKind
        ProjectBranch       = $projectBranch
        ProjectRemoteUrl    = $projectRemoteUrl
        ProjectManifestPath = $projectManifestPath
        Model               = if ($Record -and $Record.Model) { $Record.Model } else { [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('model')) }
        Status              = $status
        LastTurnStatus      = if ($Record) { [string](Get-CodexFirstValue -InputObject $Record -PropertyName @('LastTurnStatus', 'lastTurnStatus')) } else { $null }
        LastErrorMessage    = if ($Record) { [string](Get-CodexFirstValue -InputObject $Record -PropertyName @('LastErrorMessage', 'lastErrorMessage')) } else { $null }
        Pinned              = if ($Record) { [bool]$Record.Pinned } else { $false }
        Archived            = $isArchived
        Tags                = if ($Record) { @($Record.Tags) } else { @() }
        CreatedAt           = if ($Record -and $Record.CreatedAt) { $Record.CreatedAt } else { [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('createdAt')) }
        LastActivityAt      = if ($timestamp) { $timestamp.ToString('o') } else { $null }
        LastActive          = if ($timestamp) { $timestamp.ToString('g') } else { $null }
        When                = if ($timestamp) { Get-CodexDisplayTimestamp -Timestamp $timestamp } else { $null }
        ApprovalPolicy      = if ($Record) { $Record.ApprovalPolicy } else { $null }
        SandboxType         = if ($Record) { $Record.SandboxType } else { $null }
        Source              = if ($Thread -and $Record) { 'Merged' } elseif ($Thread) { 'Remote' } else { 'Local' }
        Metadata            = $Record
        RawThread           = $Thread
    }

    $threadOutput.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexThread')

    return $threadOutput
}

function Resolve-CodexProjectFilter {
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$Project,
        [Parameter(Mandatory)][PSCustomObject]$Catalog
    )

    $matches = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $projectTerms = @($Project | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($projectTerms.Count -eq 0) {
        return $matches
    }

    foreach ($term in $projectTerms) {
        $hasWildcard = $term.Contains('*') -or $term.Contains('?') -or $term.Contains('[')
        if ((-not $hasWildcard) -and (Test-Path -LiteralPath $term)) {
            $identity = Get-CodexProjectIdentity -Path $term
            $null = $matches.Add($identity.ProjectKey)
            $null = $matches.Add($identity.Path)
            continue
        }

        foreach ($projectRecord in @(Get-CodexProjectRecordsFromCatalog -Catalog $Catalog)) {
            if (
                $projectRecord.ProjectKey -like $term -or
                $projectRecord.Name -like $term -or
                $projectRecord.Path -like $term
            ) {
                $null = $matches.Add($projectRecord.ProjectKey)
                $null = $matches.Add($projectRecord.Path)
            }
        }
    }

    return $matches
}

function New-PSUnpluggedManagedThread {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Session,
        [string]$Model = 'gpt-5.2',
        [Alias('Path')][string]$Cwd,
        [string]$ApprovalPolicy = 'never',
        [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
        [string]$SandboxType = 'workspace-write',
        [string]$Prompt,
        [string]$Name,
        [string[]]$Tags,
        [switch]$CreateCwd,
        [switch]$PromptInBackground,
        [int]$TurnTimeoutSec = 900,
        [string]$ReadyFilePath,
        [switch]$PassThruSession
    )

    if ($CreateCwd -and -not [string]::IsNullOrWhiteSpace($Cwd)) {
        $resolvedPath = Resolve-CodexProjectLocation -Path $Cwd -AllowMissing
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            $null = New-Item -ItemType Directory -Path $resolvedPath -Force
        }
    }
    else {
        $resolvedPath = Resolve-CodexProjectLocation -Path $Cwd
    }
    $createdSession = $false
    if (-not $Session) {
        $Session = Start-CodexSession
        $createdSession = $true
    }

    $Model = Resolve-CodexRequestedModel -Session $Session -Model $Model

    $catalog = Import-PSUnpluggedCatalog
    $projectIdentity = Get-CodexProjectIdentity -Path $resolvedPath
    $projectRecord = Set-CodexCatalogProjectRecord -Catalog $catalog -ProjectIdentity $projectIdentity
    Export-PSUnpluggedCatalog -Catalog $catalog

    $thread = $null
    $initialTurn = $null
    $threadView = $null
    $workerProcess = $null

    try {
        $params = @{
            model          = $Model
            approvalPolicy = $ApprovalPolicy
            sandbox        = $SandboxType
            cwd            = $projectIdentity.Path
        }

        $result = Send-CodexRequest -Session $Session -Method 'thread/start' -Params $params
        Read-CodexNotifications -Session $Session -TimeoutMs 1000 | Out-Null

        $thread = $result.thread
        $threadId = Get-CodexThreadIdentifier -Thread $thread

        $catalog = Import-PSUnpluggedCatalog
        $threadRecord = Set-CodexCatalogThreadRecord -Catalog $catalog -Properties @{
            ThreadId       = $threadId
            Name           = $Name
            ProjectKey     = $projectRecord.ProjectKey
            ProjectName    = $projectRecord.Name
            Path           = $projectRecord.Path
            PromptPreview  = if ($Prompt) { $Prompt.Substring(0, [Math]::Min($Prompt.Length, 120)) } else { $null }
            Tags           = @($Tags)
            Model          = $Model
            ApprovalPolicy = $ApprovalPolicy
            SandboxType    = $SandboxType
            LastOpenedAt   = Get-PSUnpluggedUtcNowString
            LastActivityAt = Get-PSUnpluggedUtcNowString
        }
        Export-PSUnpluggedCatalog -Catalog $catalog

        if (-not [string]::IsNullOrWhiteSpace($ReadyFilePath)) {
            Write-PSUnpluggedTaskReadyFile -Path $ReadyFilePath -ThreadId $threadId -ProjectPath $projectRecord.Path
        }

        if ($Prompt) {
            if ($PromptInBackground) {
                $workerProcess = Start-PSUnpluggedTaskWorkerProcess -ThreadId $threadId -Prompt $Prompt -ProjectPath $projectRecord.Path
            }
            else {
                $turnTimeoutMs = if ($TurnTimeoutSec -gt 0) { $TurnTimeoutSec * 1000 } else { 120000 }
                try {
                    $initialTurn = Invoke-CodexTurn -Session $Session -ThreadId $threadId -Text $Prompt -Model $Model -TimeoutMs $turnTimeoutMs
                    $turnStatus = ConvertTo-CodexTaskTerminalStatus -Status ([string](Get-CodexFirstValue -InputObject $initialTurn -PropertyName @('Status', 'status')))
                    $turnErrorMessage = Get-CodexTurnErrorMessage -TurnResult $initialTurn
                    Update-CodexThreadTurnMetadata -ThreadId $threadId -Status $turnStatus -ErrorMessage $turnErrorMessage
                }
                catch {
                    Update-CodexThreadTurnMetadata -ThreadId $threadId -Status 'failed' -ErrorMessage ([string]$_.Exception.Message)
                    throw
                }

                $catalog = Import-PSUnpluggedCatalog
                $threadRecord = Find-CodexCatalogThreadRecord -Catalog $catalog -ThreadId $threadId
            }
        }

        $catalog = Import-PSUnpluggedCatalog
        $threadView = ConvertTo-CodexThreadOutput -Thread $thread -Record $threadRecord -Catalog $catalog
        Update-CodexSessionIndex -Thread $threadView
        if ($initialTurn) {
            $threadView | Add-Member -NotePropertyName InitialTurn -NotePropertyValue $initialTurn -Force
        }
        if ($workerProcess) {
            $threadView | Add-Member -NotePropertyName WorkerProcessId -NotePropertyValue $workerProcess.Id -Force
            $threadView | Add-Member -NotePropertyName WorkerProcessName -NotePropertyValue $workerProcess.ProcessName -Force
        }
        if ($PassThruSession) {
            $threadView | Add-Member -NotePropertyName Session -NotePropertyValue $Session -Force
            $threadView | Add-Member -NotePropertyName OwnsSession -NotePropertyValue $createdSession -Force
        }

        return $threadView
    }
    finally {
        if ($createdSession -and -not $PassThruSession) {
            Stop-CodexSession -Session $Session
        }
    }
}

function Get-CodexProject {
    <#
    .SYNOPSIS
        Lists registered Codex projects, optionally filtered by name or wildcard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('Project')]
        [string[]]$Name,
        [string[]]$Path,
        [switch]$Details,
        [switch]$LocalOnly,
        [int]$Limit = 100,
        [PSCustomObject]$Session,
        [Parameter(DontShow = $true)][string]$SpinnerStatus = 'Loading Codex projects...'
    )

    $catalog = Import-PSUnpluggedCatalog
    return Invoke-PSUnpluggedWithSpinner -Status $SpinnerStatus -ScriptBlock {
        $results = @(Get-CodexProjectOutputsFromCatalog -Catalog $catalog -Name $Name -Path $Path -Details:$Details)
        $remoteError = $null

        if ((-not $LocalOnly) -and ($results.Count -eq 0)) {
            try {
                $null = Get-CodexThread -Project $Name -IncludeArchived -Limit $Limit -Session $Session -SpinnerStatus $null
            }
            catch {
                $remoteError = $_
            }

            $catalog = Import-PSUnpluggedCatalog
            $results = @(Get-CodexProjectOutputsFromCatalog -Catalog $catalog -Name $Name -Path $Path -Details:$Details)
        }

        if ($remoteError -and $results.Count -eq 0) {
            throw $remoteError
        }

        return $results
    }
}

function New-CodexProject {
    <#
    .SYNOPSIS
        Registers a workspace so its threads can be grouped and discovered later.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path,
        [string]$Name
    )

    $catalog = Import-PSUnpluggedCatalog
    $identity = Get-CodexProjectIdentity -Path $Path -Name $Name
    $record = Set-CodexCatalogProjectRecord -Catalog $catalog -ProjectIdentity $identity
    Export-PSUnpluggedCatalog -Catalog $catalog

    return (ConvertTo-CodexProjectOutput -Record $record -StatsLookup (New-CodexProjectStatsLookup -Thread @($catalog.threads)))
}

function New-CodexPlaygroundProject {
    <#
    .SYNOPSIS
        Creates a new playground folder and registers it as a Codex project.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ParentPath
    )

    if ([string]::IsNullOrWhiteSpace($ParentPath)) {
        $ParentPath = Get-CodexPreferredPlaygroundRoot
    }

    $playgroundRoot = Resolve-CodexProjectLocation -Path $ParentPath -AllowMissing
    if (-not (Test-Path -LiteralPath $playgroundRoot)) {
        $null = New-Item -ItemType Directory -Force -Path $playgroundRoot
    }

    $projectPath = Join-Path $playgroundRoot $Name
    if (-not (Test-Path -LiteralPath $projectPath)) {
        $null = New-Item -ItemType Directory -Force -Path $projectPath
    }

    $manifestPath = Join-Path $projectPath '.psunplugged-project.json'
    $manifest = [PSCustomObject]@{
        name      = $Name
        kind      = 'Playground'
        createdAt = Get-PSUnpluggedUtcNowString
    }

    $manifest |
    ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $manifestPath -Encoding utf8

    return (New-CodexProject -Path $projectPath -Name $Name)
}

function Get-CodexThread {
    <#
    .SYNOPSIS
        Returns enriched Codex threads with local project metadata.
    #>
    [CmdletBinding()]
    param(
        [Alias('ThreadId')][string]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [Parameter(ValueFromPipelineByPropertyName = $true, DontShow = $true)][string]$ProjectKey,
        [Parameter(ValueFromPipelineByPropertyName = $true, DontShow = $true)][Alias('Name')][string]$ProjectName,
        [Parameter(ValueFromPipelineByPropertyName = $true, DontShow = $true)][Alias('Path')][string]$ProjectPathInput,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [int]$Limit = 25,
        [PSCustomObject]$Session,
        [Parameter(DontShow = $true)][string]$SpinnerStatus = 'Loading Codex threads...'
    )

    begin {
        $projectTerms = [System.Collections.Generic.List[string]]::new()
        $projectInputs = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $projectInputs.Add($InputObject)
        }

        foreach ($term in @($Project, $ProjectKey, $ProjectName, $ProjectPathInput)) {
            if (-not [string]::IsNullOrWhiteSpace($term)) {
                $projectTerms.Add($term)
            }
        }
    }

    end {
        if (($null -ne $InputObject) -and ($projectInputs.Count -eq 0)) {
            $projectInputs.Add($InputObject)
        }

        foreach ($projectInput in $projectInputs) {
            foreach ($term in @(
                    [string](Get-CodexFirstValue -InputObject $projectInput -PropertyName @('ProjectKey', 'projectKey')),
                    [string](Get-CodexFirstValue -InputObject $projectInput -PropertyName @('Name', 'Project', 'ProjectName', 'name', 'project', 'projectName')),
                    [string](Get-CodexFirstValue -InputObject $projectInput -PropertyName @('Path', 'path'))
                )) {
                if (-not [string]::IsNullOrWhiteSpace($term)) {
                    $projectTerms.Add($term)
                }
            }
        }

        $catalog = Import-PSUnpluggedCatalog
        $projectTermsArray = @($projectTerms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($LocalOnly -and -not $PSBoundParameters.ContainsKey('SpinnerStatus')) {
            $SpinnerStatus = $null
        }

        return Invoke-PSUnpluggedWithSpinner -Status $SpinnerStatus -ScriptBlock {
            $remoteThreads = @()
            $remoteError = $null
            $createdSession = $false

            if (-not $LocalOnly) {
                try {
                    if (-not $Session) {
                        $Session = Start-CodexSession
                        $createdSession = $true
                    }

                    $remoteResult = Get-CodexThreads -Session $Session -Limit $Limit
                    $remoteThreads = Resolve-CodexThreadList -ThreadList $remoteResult
                }
                catch {
                    $remoteError = $_
                }
                finally {
                    if ($createdSession) {
                        Stop-CodexSession -Session $Session
                    }
                }
            }

            $merged = [ordered]@{}
            foreach ($remoteThread in $remoteThreads) {
                $threadId = Get-CodexThreadIdentifier -Thread $remoteThread
                if ([string]::IsNullOrWhiteSpace($threadId)) { continue }

                $record = Find-CodexCatalogThreadRecord -Catalog $catalog -ThreadId $threadId
                $threadOutput = ConvertTo-CodexThreadOutput -Thread $remoteThread -Record $record -Catalog $catalog
                if ($threadOutput) {
                    $merged[(Get-CodexNormalizedThreadId -ThreadId $threadId)] = $threadOutput
                }
            }

            foreach ($record in @($catalog.threads)) {
                $recordThreadId = [string]$record.ThreadId
                if ([string]::IsNullOrWhiteSpace($recordThreadId)) {
                    continue
                }

                $normalizedRecordThreadId = Get-CodexNormalizedThreadId -ThreadId $recordThreadId
                if ([string]::IsNullOrWhiteSpace($normalizedRecordThreadId)) {
                    continue
                }

                if (-not $merged.Contains($normalizedRecordThreadId)) {
                    $threadOutput = ConvertTo-CodexThreadOutput -Record $record -Catalog $catalog
                    if ($threadOutput) {
                        $merged[$normalizedRecordThreadId] = $threadOutput
                    }
                }
            }

            $results = @($merged.Values)

            if ($remoteThreads.Count -gt 0) {
                $didUpdateCatalog = Update-CodexCatalogFromThreadOutputs -Catalog $catalog -Thread $results
                if ($didUpdateCatalog) {
                    Export-PSUnpluggedCatalog -Catalog $catalog
                }
            }

            if ($Id) {
                $normalizedRequestedId = Get-CodexNormalizedThreadId -ThreadId $Id
                $results = @(
                    $results | Where-Object {
                        (Get-CodexNormalizedThreadId -ThreadId ([string]$_.ThreadId)) -eq $normalizedRequestedId
                    }
                )
            }

            $projectFilters = Resolve-CodexProjectFilter -Project $projectTermsArray -Catalog $catalog
            if ($projectTermsArray.Count -gt 0) {
                $normalizedProjectFilters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($projectFilter in $projectFilters) {
                    $normalizedValue = Get-CodexNormalizedValue -Value $projectFilter
                    if (-not [string]::IsNullOrWhiteSpace($normalizedValue)) {
                        $null = $normalizedProjectFilters.Add($normalizedValue)
                    }

                    $normalizedPath = Get-CodexNormalizedPathValue -Path $projectFilter
                    if (-not [string]::IsNullOrWhiteSpace($normalizedPath)) {
                        $null = $normalizedProjectFilters.Add($normalizedPath)
                    }
                }

                $results = @(
                    $results | Where-Object {
                        $threadProjectKey = Get-CodexNormalizedValue -Value $_.ProjectKey
                        $threadPath = Get-CodexNormalizedPathValue -Path $_.Path

                        if (
                            ($threadProjectKey -and $normalizedProjectFilters.Contains($threadProjectKey)) -or
                            ($threadPath -and $normalizedProjectFilters.Contains($threadPath))
                        ) {
                            return $true
                        }

                        foreach ($term in $projectTermsArray) {
                            if (
                                $_.Project -like $term -or
                                $_.ProjectKey -like $term -or
                                $_.Path -like $term
                            ) {
                                return $true
                            }
                        }

                        return $false
                    }
                )
            }

            if (-not $IncludeArchived) {
                $results = @($results | Where-Object { -not $_.Archived })
            }

            $results = @(
                $results |
                Sort-Object -Property @{ Expression = { $_.Pinned }; Descending = $true }, @{ Expression = { $_.LastActivityAt }; Descending = $true }
            )

            Update-CodexSessionIndex -Thread $results

            if ($remoteError -and $results.Count -eq 0) {
                throw $remoteError
            }

            return $results
        }
    }
}

function Get-CodexTranscript {
    <#
    .SYNOPSIS
        Reads the stored conversation transcript for one or more Codex threads.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('ThreadId')][string[]]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [switch]$IncludeTelemetry,
        [ValidateSet('reasoning', 'tools', 'commands', 'all')][string[]]$TelemetryType,
        [int]$Limit = 25,
        [PSCustomObject]$Session,
        [Parameter(DontShow = $true)][string]$SpinnerStatus = 'Loading Codex transcript...'
    )

    begin {
        $threadIds = [System.Collections.Generic.List[string]]::new()
        $inputObjects = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $inputObjects.Add($InputObject)
            if ($InputObject -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace([string]$InputObject)) {
                    $threadIds.Add([string]$InputObject)
                }
            }
            else {
                $threadId = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('ThreadId', 'threadId', 'Id', 'id'))
                if (-not [string]::IsNullOrWhiteSpace($threadId)) {
                    $threadIds.Add($threadId)
                }
            }

            return
        }

        foreach ($threadId in @($Id)) {
            if (-not [string]::IsNullOrWhiteSpace($threadId)) {
                $threadIds.Add($threadId)
            }
        }
    }

    end {
        $threadLookup = [ordered]@{}
        $getThreadRecordCommand = Get-Command -Name Get-CodexThreadRecord -CommandType Function -ErrorAction Ignore
        $effectiveTelemetryType = @($TelemetryType)
        if ($IncludeTelemetry -and $effectiveTelemetryType.Count -eq 0) {
            $effectiveTelemetryType = @('reasoning', 'tools', 'commands')
        }

        foreach ($threadId in @($threadIds | Select-Object -Unique)) {
            $threadLookup[$threadId] = [PSCustomObject]@{
                ThreadId = $threadId
            }
        }

        foreach ($item in $inputObjects) {
            if ($null -eq $item) {
                continue
            }

            if ($item -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($item)) {
                    $threadLookup[$item] = [PSCustomObject]@{
                        ThreadId = [string]$item
                    }
                }
                continue
            }

            $threadId = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('ThreadId', 'threadId', 'Id', 'id'))
            if ([string]::IsNullOrWhiteSpace($threadId)) {
                continue
            }

            $threadLookup[$threadId] = $item
        }

        if (-not [string]::IsNullOrWhiteSpace($Project)) {
            foreach ($thread in @(Get-CodexThread -Project $Project -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit $Limit -Session $Session -SpinnerStatus $null)) {
                if ($thread -and -not [string]::IsNullOrWhiteSpace([string]$thread.ThreadId)) {
                    $threadLookup[[string]$thread.ThreadId] = $thread
                }
            }
        }
        elseif ($threadLookup.Count -gt 0) {
            foreach ($threadId in @($threadLookup.Keys)) {
                $thread = Get-CodexThread -Id $threadId -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 1 -Session $Session -SpinnerStatus $null | Select-Object -First 1
                if ($thread) {
                    $threadLookup[$threadId] = $thread
                }
            }
        }

        if ($threadLookup.Count -eq 0) {
            return
        }

        return Invoke-PSUnpluggedWithSpinner -Status $SpinnerStatus -ScriptBlock {
            $createdSession = $false
            $results = [System.Collections.Generic.List[object]]::new()

            try {
                if (-not $LocalOnly) {
                    if (-not $Session) {
                        $Session = Start-CodexSession
                        $createdSession = $true
                    }
                }

                foreach ($threadEntry in @($threadLookup.Values)) {
                    if ($null -eq $threadEntry) {
                        continue
                    }

                    $threadId = [string](Get-CodexFirstValue -InputObject $threadEntry -PropertyName @('ThreadId', 'threadId', 'Id', 'id'))
                    if ([string]::IsNullOrWhiteSpace($threadId)) {
                        continue
                    }

                    $projectName = [string](Get-CodexFirstValue -InputObject $threadEntry -PropertyName @('Project', 'ProjectName', 'project', 'projectName'))
                    $threadName = [string](Get-CodexFirstValue -InputObject $threadEntry -PropertyName @('Name', 'name', 'ThreadName', 'threadName'))
                    $sessionPath = [string](Get-CodexFirstValue -InputObject (Get-CodexFirstValue -InputObject $threadEntry -PropertyName @('RawThread', 'rawThread')) -PropertyName @('path', 'Path'))
                    if ([string]::IsNullOrWhiteSpace($sessionPath)) {
                        $sessionPath = Resolve-CodexSessionPath -ThreadId $threadId
                    }
                    $transcriptItems = @()
                    $readError = $null
                    $threadRecord = $null

                    if (-not [string]::IsNullOrWhiteSpace($sessionPath) -and (Test-Path -LiteralPath $sessionPath)) {
                        $transcriptItems = @(ConvertTo-CodexTranscriptItemsFromSessionFile -Path $sessionPath -ThreadId $threadId -ThreadName $threadName -Project $projectName -TelemetryType $effectiveTelemetryType)
                    }

                    if ($transcriptItems.Count -eq 0 -and -not $LocalOnly -and $getThreadRecordCommand) {
                        try {
                            $threadRecord = & $getThreadRecordCommand.ScriptBlock -Session $Session -ThreadId $threadId -IncludeTurns

                            if ([string]::IsNullOrWhiteSpace($threadName) -and $threadRecord.thread) {
                                $threadName = Get-CodexThreadTitle -Thread $threadRecord.thread
                            }

                            if (-not $projectName) {
                                $threadPath = [string](Get-CodexFirstValue -InputObject $threadRecord.thread -PropertyName @('cwd', 'Cwd', 'path', 'Path'))
                                if (-not [string]::IsNullOrWhiteSpace($threadPath)) {
                                    $identity = Get-CodexProjectIdentity -Path $threadPath
                                    if ($identity) {
                                        $projectName = [string]$identity.Name
                                    }
                                }
                            }
                            if ([string]::IsNullOrWhiteSpace($sessionPath)) {
                                $sessionPath = [string](Get-CodexFirstValue -InputObject $threadRecord.thread -PropertyName @('path', 'Path'))
                            }
                        }
                        catch {
                            $readError = $_
                        }
                    }

                    if ($transcriptItems.Count -eq 0 -and $threadRecord -and $threadRecord.thread) {
                        $transcriptItems = @(ConvertTo-CodexTranscriptItemsFromThreadRecord -Thread $threadRecord.thread -ThreadName $threadName -Project $projectName)
                    }

                    if ($readError -and $transcriptItems.Count -eq 0 -and (Test-CodexEmptyRolloutError -ErrorRecord $readError)) {
                        $readError = $null
                    }

                    if ($readError -and $transcriptItems.Count -eq 0) {
                        throw $readError
                    }

                    foreach ($transcriptItem in @($transcriptItems)) {
                        $results.Add($transcriptItem)
                    }
                }

                return @($results)
            }
            finally {
                if ($createdSession) {
                    Stop-CodexSession -Session $Session
                }
            }
        }
    }
}

function Get-CodexEvent {
    <#
    .SYNOPSIS
        Reads the operational event stream for one or more Codex tasks.
    .DESCRIPTION
        Get-CodexEvent projects Codex session JSONL into structured PowerShell
        objects for operational inspection. Use Receive-CodexTask for task
        output, Get-CodexTranscript for conversation history, and Get-CodexEvent
        for what the task did.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('TaskId', 'ThreadId')][string[]]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [ValidateSet(
            'AgentMessage',
            'ApprovalRequested',
            'Command',
            'CommandResult',
            'Error',
            'EventMessage',
            'ItemCompleted',
            'Notification',
            'Reasoning',
            'ResponseItem',
            'SessionMeta',
            'TaskCompleted',
            'TaskStarted',
            'ToolCall',
            'ToolResult',
            'TurnCompleted',
            'TurnContext',
            'Unknown',
            'UserMessage'
        )]
        [string[]]$Kind,
        [object]$Since,
        [switch]$IncludeRaw,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [int]$Limit = 100,
        [PSCustomObject]$Session,
        [Parameter(DontShow = $true)][string]$SpinnerStatus = 'Loading Codex events...'
    )

    begin {
        $inputs = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $inputs.Add($InputObject)
        }
    }

    end {
        $taskLookup = [ordered]@{}
        foreach ($taskId in @($Id)) {
            if ([string]::IsNullOrWhiteSpace([string]$taskId)) {
                continue
            }

            $resolvedId = Resolve-CodexTaskIdentifierText -Id ([string]$taskId)
            if (-not [string]::IsNullOrWhiteSpace($resolvedId)) {
                $taskLookup[$resolvedId] = [PSCustomObject]@{
                    TaskId   = $resolvedId
                    ThreadId = $resolvedId
                }
            }
        }

        foreach ($item in @($inputs)) {
            if ($null -eq $item) {
                continue
            }

            $taskId = Resolve-CodexTaskIdentifier -InputObject $item
            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                $taskLookup[$taskId] = $item
            }
        }

        $hasExplicitTask = $taskLookup.Count -gt 0
        $effectiveProject = $Project
        if (-not $hasExplicitTask -and [string]::IsNullOrWhiteSpace($effectiveProject)) {
            $effectiveProject = (Get-Location).Path
        }

        if (-not [string]::IsNullOrWhiteSpace($effectiveProject)) {
            foreach ($task in @(Get-CodexTask -Project $effectiveProject -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 0 -Session $Session -SpinnerStatus $null)) {
                $taskId = Resolve-CodexTaskIdentifier -InputObject $task
                if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                    $taskLookup[$taskId] = $task
                }
            }
        }

        if ($taskLookup.Count -eq 0) {
            return
        }

        $kindFilter = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($kindEntry in @($Kind)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$kindEntry)) {
                $null = $kindFilter.Add(([string]$kindEntry).Trim())
            }
        }

        $sinceTimestamp = ConvertTo-CodexDateTimeOffset -Value $Since

        return Invoke-PSUnpluggedWithSpinner -Status $SpinnerStatus -ScriptBlock {
            $createdSession = $false
            $results = [System.Collections.Generic.List[object]]::new()

            try {
                if (-not $LocalOnly -and -not $Session) {
                    $Session = Start-CodexSession
                    $createdSession = $true
                }

                foreach ($taskEntry in @($taskLookup.Values)) {
                    if ($null -eq $taskEntry) {
                        continue
                    }

                    $taskId = Resolve-CodexTaskIdentifier -InputObject $taskEntry
                    if ([string]::IsNullOrWhiteSpace($taskId)) {
                        continue
                    }

                    $task = if ($taskEntry.PSObject.TypeNames -contains 'PSUnplugged.CodexTask') {
                        $taskEntry
                    }
                    else {
                        Get-CodexTask -Id $taskId -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 1 -Session $Session -SpinnerStatus $null |
                        Select-Object -First 1
                    }
                    if (-not $task) {
                        $task = $taskEntry
                    }

                    $threadName = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Name', 'name', 'ThreadName', 'threadName'))
                    $projectName = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Project', 'project', 'ProjectName', 'projectName'))
                    $rawThread = Get-CodexFirstValue -InputObject $task -PropertyName @('RawThread', 'rawThread')
                    $sessionPath = [string](Get-CodexFirstValue -InputObject $rawThread -PropertyName @('path', 'Path'))
                    if ([string]::IsNullOrWhiteSpace($sessionPath)) {
                        $sessionPath = Resolve-CodexSessionPath -ThreadId $taskId
                    }

                    $taskEvents = @()
                    if (-not [string]::IsNullOrWhiteSpace($sessionPath) -and (Test-Path -LiteralPath $sessionPath)) {
                        $taskEvents = @(ConvertTo-CodexEventsFromSessionFile -Path $sessionPath -ThreadId $taskId -ThreadName $threadName -Project $projectName -IncludeRaw:$IncludeRaw)
                    }

                    if ($taskEvents.Count -eq 0 -and -not $LocalOnly -and $Session) {
                        try {
                            $threadRecord = Get-CodexThreadRecord -Session $Session -ThreadId $taskId -IncludeTurns
                            if ($threadRecord -and $threadRecord.thread) {
                                if ([string]::IsNullOrWhiteSpace($threadName)) {
                                    $threadName = Get-CodexThreadTitle -Thread $threadRecord.thread
                                }
                                $taskEvents = @(ConvertTo-CodexEventsFromThreadRecord -Thread $threadRecord.thread -ThreadName $threadName -Project $projectName -IncludeRaw:$IncludeRaw)
                            }
                        }
                        catch {
                        }
                    }

                    foreach ($event in @($taskEvents)) {
                        if ($kindFilter.Count -gt 0) {
                            $eventKind = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Kind', 'kind'))
                            if ([string]::IsNullOrWhiteSpace($eventKind) -or -not $kindFilter.Contains($eventKind)) {
                                continue
                            }
                        }

                        if ($sinceTimestamp) {
                            $eventTimestamp = ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $event -PropertyName @('Timestamp', 'timestamp'))
                            if (-not $eventTimestamp -or $eventTimestamp -lt $sinceTimestamp) {
                                continue
                            }
                        }

                        $results.Add($event)
                    }
                }

                $sorted = @(
                    $results |
                    Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.TaskId } }, @{ Expression = { $_.Index } }
                )

                if ($Limit -gt 0 -and $sorted.Count -gt $Limit) {
                    $sorted = @($sorted | Select-Object -Last $Limit)
                }

                return $sorted
            }
            finally {
                if ($createdSession) {
                    Stop-CodexSession -Session $Session
                }
            }
        }
    }
}

function ConvertTo-CodexApprovalOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline = $true)]
        $InputObject,
        [switch]$IncludeRaw
    )

    process {
        if ($null -eq $InputObject) {
            return
        }

        $rawEvent = Get-CodexFirstValue -InputObject $InputObject -PropertyName @('RawEvent', 'rawEvent')
        $rawParams = Get-CodexFirstValue -InputObject $rawEvent -PropertyName @('params', 'Params')
        $eventName = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Name', 'name'))
        $eventType = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Type', 'type'))
        if ([string]::IsNullOrWhiteSpace($eventType)) {
            $eventType = [string](Get-CodexFirstValue -InputObject $rawEvent -PropertyName @('method', 'Method'))
        }

        $approvalType = if ($eventName -eq 'commandExecution' -or $eventType -like '*commandExecution/requestApproval') {
            'CommandExecution'
        }
        elseif ($eventName -eq 'fileChange' -or $eventType -like '*fileChange/requestApproval') {
            'FileChange'
        }
        else {
            'Unknown'
        }

        $commandText = [string](Get-CodexNestedFirstValue -InputObject $rawParams -PropertyName @('command', 'Command'))
        $pathText = [string](Get-CodexNestedFirstValue -InputObject $rawParams -PropertyName @('path', 'Path', 'filePath', 'file_path'))
        $reasonText = [string](Get-CodexNestedFirstValue -InputObject $rawParams -PropertyName @('reason', 'Reason', 'message', 'Message', 'description', 'Description'))
        $target = if (-not [string]::IsNullOrWhiteSpace($commandText)) {
            $commandText
        }
        elseif (-not [string]::IsNullOrWhiteSpace($pathText)) {
            $pathText
        }
        else {
            [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Text', 'text', 'Summary', 'summary'))
        }

        $approvalId = [string](Get-CodexFirstValue -InputObject $rawEvent -PropertyName @('id', 'Id'))
        if ([string]::IsNullOrWhiteSpace($approvalId)) {
            $approvalId = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Id', 'id'))
        }

        $approval = [PSCustomObject]@{
            Id           = $approvalId
            TaskId       = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('TaskId', 'taskId', 'ThreadId', 'threadId'))
            ThreadId     = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('ThreadId', 'threadId', 'TaskId', 'taskId'))
            ThreadName   = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('ThreadName', 'threadName'))
            Project      = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Project', 'project'))
            TurnId       = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('TurnId', 'turnId'))
            Status       = 'Requested'
            ApprovalType = $approvalType
            Target       = $target
            Command      = $commandText
            Path         = $pathText
            Reason       = $reasonText
            Summary      = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Summary', 'summary'))
            Timestamp    = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Timestamp', 'timestamp'))
            When         = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('When', 'when'))
            SourceEvent  = $InputObject
        }

        if ($IncludeRaw) {
            $approval | Add-Member -NotePropertyName RawEvent -NotePropertyValue $rawEvent -Force
            $approval.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexApproval.Raw')
            $approval.PSObject.TypeNames.Insert(1, 'PSUnplugged.CodexApproval')
        }
        else {
            $approval.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexApproval')
        }

        return $approval
    }
}

function Get-CodexApproval {
    <#
    .SYNOPSIS
        Reads approval requests observed for one or more Codex tasks.
    .DESCRIPTION
        Get-CodexApproval is a read-only approval view. It projects approval
        request events into PowerShell objects. It does not approve or deny
        requests; live approval handling is a separate control-flow concern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('TaskId', 'ThreadId')][string[]]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [ValidateSet('CommandExecution', 'FileChange', 'Unknown')]
        [string[]]$ApprovalType,
        [ValidateSet('Requested')]
        [string[]]$Status,
        [object]$Since,
        [switch]$IncludeRaw,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [int]$Limit = 100,
        [PSCustomObject]$Session,
        [Parameter(DontShow = $true)][string]$SpinnerStatus = 'Loading Codex approvals...'
    )

    begin {
        $inputs = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $inputs.Add($InputObject)
        }
    }

    end {
        $eventParams = @{
            Kind          = 'ApprovalRequested'
            IncludeRaw    = $true
            Limit         = 0
            SpinnerStatus = $SpinnerStatus
        }
        if ($Id) { $eventParams.Id = $Id }
        if ($Project) { $eventParams.Project = $Project }
        if ($Since) { $eventParams.Since = $Since }
        if ($IncludeArchived) { $eventParams.IncludeArchived = $true }
        if ($LocalOnly) { $eventParams.LocalOnly = $true }
        if ($Session) { $eventParams.Session = $Session }

        $events = if ($inputs.Count -gt 0) {
            @($inputs | Get-CodexEvent @eventParams)
        }
        else {
            @(Get-CodexEvent @eventParams)
        }

        $typeFilter = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($ApprovalType)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry)) {
                $null = $typeFilter.Add(([string]$entry).Trim())
            }
        }

        $statusFilter = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($Status)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry)) {
                $null = $statusFilter.Add(([string]$entry).Trim())
            }
        }

        $approvals = @(
            foreach ($approval in @($events | ConvertTo-CodexApprovalOutput -IncludeRaw:$IncludeRaw)) {
                if ($typeFilter.Count -gt 0 -and -not $typeFilter.Contains([string]$approval.ApprovalType)) {
                    continue
                }
                if ($statusFilter.Count -gt 0 -and -not $statusFilter.Contains([string]$approval.Status)) {
                    continue
                }

                $approval
            }
        )

        if ($Limit -gt 0 -and $approvals.Count -gt $Limit) {
            return @($approvals | Select-Object -Last $Limit)
        }

        return $approvals
    }
}

function Get-CodexArtifactTextSize {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return 0
    }

    return [System.Text.Encoding]::UTF8.GetByteCount($Text)
}

function ConvertTo-CodexArtifactTranscriptText {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Transcript
    )

    $blocks = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Transcript | Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } })) {
        if ($null -eq $item) {
            continue
        }

        $text = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Text', 'text'))
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($propertyName in @('When', 'Role', 'Phase')) {
            $value = [string](Get-CodexFirstValue -InputObject $item -PropertyName @($propertyName, $propertyName.ToLowerInvariant()))
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $parts.Add($value)
            }
        }

        $label = if ($parts.Count -gt 0) { '[' + ($parts -join ' | ') + ']' } else { '[transcript]' }
        $blocks.Add(($label + "`n" + $text.Trim()))
    }

    return ($blocks -join "`n`n")
}

function ConvertTo-CodexArtifactEventText {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Event
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Event | Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } })) {
        if ($null -eq $item) {
            continue
        }

        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($propertyName in @('When', 'Kind', 'Name')) {
            $value = [string](Get-CodexFirstValue -InputObject $item -PropertyName @($propertyName, $propertyName.ToLowerInvariant()))
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $parts.Add($value)
            }
        }

        $label = if ($parts.Count -gt 0) { '[' + ($parts -join ' | ') + ']' } else { '[event]' }
        $summary = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Summary', 'summary', 'Text', 'text'))
        if ([string]::IsNullOrWhiteSpace($summary)) {
            $summary = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Type', 'type'))
        }

        $lines.Add(('{0} {1}' -f $label, $summary).Trim())
    }

    return ($lines -join "`n")
}

function Get-CodexLatestTimestamp {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$InputObject
    )

    $latest = $null
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) {
            continue
        }

        $timestamp = ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $item -PropertyName @('Timestamp', 'timestamp', 'LastActivityAt', 'lastActivityAt', 'UpdatedAt', 'updatedAt'))
        if ($timestamp -and ($null -eq $latest -or $timestamp -gt $latest)) {
            $latest = $timestamp
        }
    }

    return $latest
}

function New-CodexArtifact {
    [CmdletBinding()]
    param(
        [string]$ThreadId,
        [string]$ThreadName,
        [string]$Project,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [string]$Path,
        [string]$Summary,
        [Nullable[Int64]]$Size,
        [Nullable[Int32]]$ItemCount,
        [AllowNull()][Nullable[DateTimeOffset]]$Timestamp,
        [string]$Source,
        [AllowNull()]$Content,
        [switch]$IncludeContent
    )

    $timestampValue = if ($null -ne $Timestamp) { [DateTimeOffset]$Timestamp } else { $null }
    $artifactName = if ([string]::IsNullOrWhiteSpace($Name)) { $Kind } else { $Name }
    $artifactId = if (-not [string]::IsNullOrWhiteSpace($ThreadId)) {
        '{0}:{1}:{2}' -f (Get-CodexCompactId -Id $ThreadId -Length 8), $Kind, (Get-CodexSafeFileName -Name $artifactName -Fallback 'artifact')
    }
    else {
        '{0}:{1}' -f $Kind, (Get-CodexSafeFileName -Name $artifactName -Fallback 'artifact')
    }

    $artifact = [PSCustomObject]@{
        Id         = $artifactId
        TaskId     = $ThreadId
        ThreadId   = $ThreadId
        ThreadName = $ThreadName
        Project    = $Project
        Kind       = $Kind
        Name       = $artifactName
        Path       = $Path
        Size       = if ($null -ne $Size) { [Int64]$Size } else { $null }
        ItemCount  = if ($null -ne $ItemCount) { [Int32]$ItemCount } else { $null }
        Timestamp  = if ($null -ne $timestampValue) { $timestampValue.ToString('o') } else { $null }
        When       = if ($null -ne $timestampValue) { Get-CodexDisplayTimestamp -Timestamp $timestampValue } else { $null }
        Summary    = $Summary
        Source     = $Source
    }

    if ($IncludeContent) {
        $artifact | Add-Member -NotePropertyName Content -NotePropertyValue $Content -Force
        $artifact.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexArtifact.Content')
        $artifact.PSObject.TypeNames.Insert(1, 'PSUnplugged.CodexArtifact')
    }
    else {
        $artifact.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexArtifact')
    }

    return $artifact
}

function Get-CodexArtifact {
    <#
    .SYNOPSIS
        Reads durable artifacts and materialized task views for Codex tasks.
    .DESCRIPTION
        Get-CodexArtifact projects existing Codex task state into artifact-like
        PowerShell objects. It does not create a separate artifact registry; it
        exposes the durable session file plus derived result, transcript, and
        event-log views.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('TaskId', 'ThreadId')][string[]]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [ValidateSet('SessionFile', 'ResultText', 'Transcript', 'EventLog')]
        [string[]]$Kind,
        [switch]$IncludeContent,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [int]$Limit = 100,
        [PSCustomObject]$Session,
        [Parameter(DontShow = $true)][string]$SpinnerStatus = 'Loading Codex artifacts...'
    )

    begin {
        $inputs = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $inputs.Add($InputObject)
        }
    }

    end {
        $taskLookup = [ordered]@{}
        foreach ($taskId in @($Id)) {
            if ([string]::IsNullOrWhiteSpace([string]$taskId)) {
                continue
            }

            $resolvedId = Resolve-CodexTaskIdentifierText -Id ([string]$taskId)
            if (-not [string]::IsNullOrWhiteSpace($resolvedId)) {
                $taskLookup[$resolvedId] = [PSCustomObject]@{
                    TaskId   = $resolvedId
                    ThreadId = $resolvedId
                }
            }
        }

        foreach ($item in @($inputs)) {
            if ($null -eq $item) {
                continue
            }

            $taskId = Resolve-CodexTaskIdentifier -InputObject $item
            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                $taskLookup[$taskId] = $item
            }
        }

        $hasExplicitTask = $taskLookup.Count -gt 0
        $effectiveProject = $Project
        if (-not $hasExplicitTask -and [string]::IsNullOrWhiteSpace($effectiveProject)) {
            $effectiveProject = (Get-Location).Path
        }

        if (-not [string]::IsNullOrWhiteSpace($effectiveProject)) {
            foreach ($task in @(Get-CodexTask -Project $effectiveProject -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 0 -Session $Session -SpinnerStatus $null)) {
                $taskId = Resolve-CodexTaskIdentifier -InputObject $task
                if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                    $taskLookup[$taskId] = $task
                }
            }
        }

        if ($taskLookup.Count -eq 0) {
            return
        }

        $kindFilter = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($kindEntry in @($Kind)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$kindEntry)) {
                $null = $kindFilter.Add(([string]$kindEntry).Trim())
            }
        }

        return Invoke-PSUnpluggedWithSpinner -Status $SpinnerStatus -ScriptBlock {
            $createdSession = $false
            $results = [System.Collections.Generic.List[object]]::new()

            try {
                if (-not $LocalOnly -and -not $Session) {
                    $Session = Start-CodexSession
                    $createdSession = $true
                }

                foreach ($taskEntry in @($taskLookup.Values)) {
                    if ($null -eq $taskEntry) {
                        continue
                    }

                    $taskId = Resolve-CodexTaskIdentifier -InputObject $taskEntry
                    if ([string]::IsNullOrWhiteSpace($taskId)) {
                        continue
                    }

                    $task = if ($taskEntry.PSObject.TypeNames -contains 'PSUnplugged.CodexTask') {
                        $taskEntry
                    }
                    else {
                        Get-CodexTask -Id $taskId -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 1 -Session $Session -SpinnerStatus $null |
                        Select-Object -First 1
                    }
                    if (-not $task) {
                        $task = $taskEntry
                    }

                    $threadName = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Name', 'name', 'ThreadName', 'threadName'))
                    $projectName = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Project', 'project', 'ProjectName', 'projectName'))
                    $sessionPath = Resolve-CodexTaskSessionPath -InputObject $task
                    $taskTimestamp = ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $task -PropertyName @('LastActivityAt', 'lastActivityAt', 'UpdatedAt', 'updatedAt', 'Timestamp', 'timestamp'))

                    if (($kindFilter.Count -eq 0 -or $kindFilter.Contains('SessionFile')) -and -not [string]::IsNullOrWhiteSpace($sessionPath) -and (Test-Path -LiteralPath $sessionPath)) {
                        $fileInfo = Get-Item -LiteralPath $sessionPath -ErrorAction SilentlyContinue
                        if ($fileInfo) {
                            $content = if ($IncludeContent) { Get-Content -LiteralPath $sessionPath -Raw -ErrorAction SilentlyContinue } else { $null }
                            $results.Add((New-CodexArtifact -ThreadId $taskId -ThreadName $threadName -Project $projectName -Kind 'SessionFile' -Name $fileInfo.Name -Path $fileInfo.FullName -Summary ('Codex session JSONL ({0} bytes)' -f $fileInfo.Length) -Size ([Int64]$fileInfo.Length) -ItemCount $null -Timestamp (ConvertTo-CodexDateTimeOffset -Value $fileInfo.LastWriteTimeUtc) -Source 'SessionJsonl' -Content $content -IncludeContent:$IncludeContent))
                        }
                    }

                    if ($kindFilter.Count -eq 0 -or $kindFilter.Contains('ResultText')) {
                        $receiveParams = @{
                            Limit = 25
                        }
                        if ($IncludeArchived) { $receiveParams.IncludeArchived = $true }
                        if ($LocalOnly) { $receiveParams.LocalOnly = $true }
                        if ($Session) { $receiveParams.Session = $Session }

                        $latestOutput = @($task | Receive-CodexTask @receiveParams) | Select-Object -First 1
                        if ($latestOutput) {
                            $text = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Text', 'text'))
                            if (-not [string]::IsNullOrWhiteSpace($text)) {
                                $summary = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Summary', 'summary'))
                                if ([string]::IsNullOrWhiteSpace($summary)) {
                                    $summary = Get-CodexTaskReceiveSummary -Text $text
                                }

                                $timestamp = ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Timestamp', 'timestamp'))
                                if (-not $timestamp) {
                                    $timestamp = $taskTimestamp
                                }

                                $results.Add((New-CodexArtifact -ThreadId $taskId -ThreadName $threadName -Project $projectName -Kind 'ResultText' -Name 'latest-output.md' -Path $null -Summary $summary -Size (Get-CodexArtifactTextSize -Text $text) -ItemCount 1 -Timestamp $timestamp -Source 'Receive-CodexTask' -Content $text -IncludeContent:$IncludeContent))
                            }
                        }
                    }

                    if ($kindFilter.Count -eq 0 -or $kindFilter.Contains('Transcript')) {
                        $transcriptParams = @{
                            Limit         = 25
                            SpinnerStatus = $null
                        }
                        if ($IncludeArchived) { $transcriptParams.IncludeArchived = $true }
                        if ($LocalOnly) { $transcriptParams.LocalOnly = $true }
                        if ($Session) { $transcriptParams.Session = $Session }

                        $transcript = @(Get-CodexTranscript -Id $taskId @transcriptParams)
                        if ($transcript.Count -gt 0) {
                            $content = if ($IncludeContent) { ConvertTo-CodexArtifactTranscriptText -Transcript $transcript } else { $null }
                            $size = if ($IncludeContent) { Get-CodexArtifactTextSize -Text $content } else { $null }
                            $timestamp = Get-CodexLatestTimestamp -InputObject $transcript
                            if (-not $timestamp) {
                                $timestamp = $taskTimestamp
                            }

                            $results.Add((New-CodexArtifact -ThreadId $taskId -ThreadName $threadName -Project $projectName -Kind 'Transcript' -Name 'transcript.md' -Path $null -Summary ('{0} transcript item(s)' -f $transcript.Count) -Size $size -ItemCount $transcript.Count -Timestamp $timestamp -Source 'Get-CodexTranscript' -Content $content -IncludeContent:$IncludeContent))
                        }
                    }

                    if ($kindFilter.Count -eq 0 -or $kindFilter.Contains('EventLog')) {
                        $eventParams = @{
                            Limit         = 0
                            SpinnerStatus = $null
                        }
                        if ($IncludeArchived) { $eventParams.IncludeArchived = $true }
                        if ($LocalOnly) { $eventParams.LocalOnly = $true }
                        if ($Session) { $eventParams.Session = $Session }

                        $events = @($task | Get-CodexEvent @eventParams)
                        if ($events.Count -gt 0) {
                            $content = if ($IncludeContent) { ConvertTo-CodexArtifactEventText -Event $events } else { $null }
                            $size = if ($IncludeContent) { Get-CodexArtifactTextSize -Text $content } else { $null }
                            $timestamp = Get-CodexLatestTimestamp -InputObject $events
                            if (-not $timestamp) {
                                $timestamp = $taskTimestamp
                            }

                            $results.Add((New-CodexArtifact -ThreadId $taskId -ThreadName $threadName -Project $projectName -Kind 'EventLog' -Name 'events.log' -Path $null -Summary ('{0} event(s)' -f $events.Count) -Size $size -ItemCount $events.Count -Timestamp $timestamp -Source 'Get-CodexEvent' -Content $content -IncludeContent:$IncludeContent))
                        }
                    }
                }

                $sorted = @(
                    $results |
                    Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.TaskId } }, @{ Expression = { $_.Kind } }
                )

                if ($Limit -gt 0 -and $sorted.Count -gt $Limit) {
                    $sorted = @($sorted | Select-Object -Last $Limit)
                }

                return $sorted
            }
            finally {
                if ($createdSession) {
                    Stop-CodexSession -Session $Session
                }
            }
        }
    }
}

function Get-CodexSafeFileName {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Fallback = 'codex-transcript'
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($Name)) { $Fallback } else { $Name }
    $invalidPattern = '[' + [Regex]::Escape(([string]::Join('', [System.IO.Path]::GetInvalidFileNameChars()))) + ']'
    $candidate = [Regex]::Replace($candidate, $invalidPattern, '-')
    $candidate = ($candidate -replace '\s+', '-').Trim('-')

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $Fallback
    }

    return $candidate
}

function New-CodexTranscriptHtmlPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Transcript,
        [string]$Title
    )

    $root = Join-Path (Get-PSUnpluggedDataRoot) 'transcripts'
    if (-not (Test-Path -LiteralPath $root)) {
        $null = New-Item -ItemType Directory -Path $root -Force
    }

    $threadGroups = @($Transcript | Group-Object ThreadId)
    $baseName = if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $Title
    }
    elseif ($threadGroups.Count -eq 1) {
        $first = $threadGroups[0].Group | Select-Object -First 1
        [string](Get-CodexFirstValue -InputObject $first -PropertyName @('ThreadName', 'Project', 'ThreadId'))
    }
    else {
        'codex-transcripts'
    }

    $safeName = Get-CodexSafeFileName -Name $baseName
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return (Join-Path $root "$stamp-$safeName.html")
}

function ConvertTo-CodexTranscriptHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Transcript,
        [string]$Title
    )

    $sortedItems = @(
        $Transcript |
        Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.ThreadId } }, @{ Expression = { $_.Index } }
    )

    $threadGroups = @($sortedItems | Group-Object ThreadId)
    $pageTitle = if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $Title
    }
    elseif ($threadGroups.Count -eq 1) {
        $first = $threadGroups[0].Group | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace([string]$first.ThreadName)) {
            [string]$first.ThreadName
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$first.Project)) {
            [string]$first.Project
        }
        else {
            "Transcript $($first.ThreadId)"
        }
    }
    else {
        'Codex Transcript Browser'
    }

    $threads = foreach ($threadGroup in $threadGroups) {
        $first = $threadGroup.Group | Select-Object -First 1
        [PSCustomObject]@{
            threadId   = [string]$threadGroup.Name
            threadName = [string](Get-CodexFirstValue -InputObject $first -PropertyName @('ThreadName', 'threadName'))
            project    = [string](Get-CodexFirstValue -InputObject $first -PropertyName @('Project', 'project'))
            itemCount  = $threadGroup.Count
        }
    }

    $items = foreach ($item in $sortedItems) {
        [PSCustomObject]@{
            threadId   = [string]$item.ThreadId
            threadName = [string]$item.ThreadName
            project    = [string]$item.Project
            role       = [string]$item.Role
            phase      = [string]$item.Phase
            when       = [string]$item.When
            timestamp  = [string]$item.Timestamp
            text       = [string]$item.Text
            index      = [int]$item.Index
        }
    }

    $data = [ordered]@{
        title       = $pageTitle
        generatedAt = (Get-Date).ToString('o')
        threadCount = $threads.Count
        itemCount   = $items.Count
        roles       = @($items.role | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        phases      = @($items.phase | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        threads     = @($threads)
        items       = @($items)
    }

    $json = ($data | ConvertTo-Json -Depth 8)
    $json = $json -replace '</script>', '<\/script>'
    $encodedTitle = [System.Net.WebUtility]::HtmlEncode($pageTitle)

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>$encodedTitle</title>
  <style>
    :root {
      --bg: #f4efe6;
      --panel: rgba(255, 251, 244, 0.88);
      --panel-strong: #fffaf1;
      --ink: #1f2a2b;
      --muted: #5c6a6b;
      --line: rgba(31, 42, 43, 0.12);
      --accent: #0f766e;
      --accent-soft: rgba(15, 118, 110, 0.12);
      --user: #b45309;
      --assistant: #0f766e;
      --shadow: 0 18px 60px rgba(31, 42, 43, 0.12);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, rgba(15, 118, 110, 0.16), transparent 34%),
        radial-gradient(circle at top right, rgba(180, 83, 9, 0.14), transparent 28%),
        linear-gradient(180deg, #f8f4ee 0%, var(--bg) 100%);
      font-family: "Segoe UI Variable Text", "Segoe UI", "IBM Plex Sans", system-ui, sans-serif;
    }
    .shell {
      display: grid;
      grid-template-columns: 320px 1fr;
      gap: 24px;
      padding: 24px;
    }
    .panel {
      background: var(--panel);
      backdrop-filter: blur(12px);
      border: 1px solid var(--line);
      border-radius: 24px;
      box-shadow: var(--shadow);
    }
    .sidebar {
      position: sticky;
      top: 24px;
      align-self: start;
      padding: 22px 20px;
    }
    .headline {
      margin: 0 0 8px;
      font-size: 1.45rem;
      line-height: 1.1;
    }
    .subtle {
      color: var(--muted);
      font-size: 0.95rem;
    }
    .stats {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
      margin: 18px 0;
    }
    .stat {
      padding: 12px 14px;
      border-radius: 16px;
      background: var(--panel-strong);
      border: 1px solid var(--line);
    }
    .stat-label {
      display: block;
      color: var(--muted);
      font-size: 0.76rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      margin-bottom: 6px;
    }
    .stat-value {
      font-size: 1.2rem;
      font-weight: 700;
    }
    .control-group {
      margin-top: 18px;
    }
    .control-label {
      display: block;
      margin-bottom: 8px;
      font-size: 0.8rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--muted);
    }
    input[type="search"], select {
      width: 100%;
      padding: 12px 14px;
      border-radius: 14px;
      border: 1px solid var(--line);
      background: var(--panel-strong);
      color: var(--ink);
      font: inherit;
      outline: none;
    }
    input[type="search"]:focus, select:focus {
      border-color: rgba(15, 118, 110, 0.45);
      box-shadow: 0 0 0 4px rgba(15, 118, 110, 0.12);
    }
    .thread-list {
      margin-top: 18px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      max-height: 42vh;
      overflow: auto;
      padding-right: 4px;
    }
    .thread-chip {
      width: 100%;
      text-align: left;
      border: 1px solid var(--line);
      background: var(--panel-strong);
      color: var(--ink);
      border-radius: 16px;
      padding: 12px 14px;
      cursor: pointer;
      transition: transform 140ms ease, border-color 140ms ease, background 140ms ease;
    }
    .thread-chip:hover {
      transform: translateY(-1px);
      border-color: rgba(15, 118, 110, 0.34);
    }
    .thread-chip.active {
      background: var(--accent-soft);
      border-color: rgba(15, 118, 110, 0.45);
    }
    .thread-title {
      display: block;
      font-weight: 700;
      margin-bottom: 4px;
    }
    .thread-meta {
      color: var(--muted);
      font-size: 0.88rem;
    }
    .main {
      min-width: 0;
    }
    .toolbar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      padding: 20px 24px;
      margin-bottom: 18px;
    }
    .toolbar-title {
      margin: 0;
      font-size: 1.05rem;
      font-weight: 700;
    }
    .toolbar-meta {
      color: var(--muted);
      font-size: 0.92rem;
    }
    .items {
      display: flex;
      flex-direction: column;
      gap: 14px;
    }
    .item {
      padding: 18px 20px;
      border-radius: 22px;
      border: 1px solid var(--line);
      background: rgba(255, 255, 255, 0.72);
      box-shadow: 0 10px 28px rgba(31, 42, 43, 0.06);
    }
    .item-header {
      display: flex;
      flex-wrap: wrap;
      gap: 10px 12px;
      align-items: center;
      margin-bottom: 12px;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      padding: 5px 10px;
      border-radius: 999px;
      font-size: 0.78rem;
      font-weight: 700;
      letter-spacing: 0.02em;
    }
    .badge.user {
      background: rgba(180, 83, 9, 0.12);
      color: var(--user);
    }
    .badge.assistant {
      background: rgba(15, 118, 110, 0.12);
      color: var(--assistant);
    }
    .meta {
      color: var(--muted);
      font-size: 0.88rem;
    }
    .item-thread {
      margin-left: auto;
      color: var(--muted);
      font-size: 0.85rem;
    }
    .item-text {
      margin: 0;
      white-space: pre-wrap;
      line-height: 1.6;
      font-size: 0.98rem;
    }
    .empty {
      padding: 40px 24px;
      text-align: center;
      color: var(--muted);
    }
    @media (max-width: 980px) {
      .shell {
        grid-template-columns: 1fr;
      }
      .sidebar {
        position: static;
      }
      .item-thread {
        margin-left: 0;
        width: 100%;
      }
    }
  </style>
</head>
<body>
  <div class="shell">
    <aside class="panel sidebar">
      <h1 class="headline">$encodedTitle</h1>
      <div class="subtle" id="summaryLine"></div>
      <div class="stats">
        <div class="stat">
          <span class="stat-label">Threads</span>
          <span class="stat-value" id="threadCount"></span>
        </div>
        <div class="stat">
          <span class="stat-label">Messages</span>
          <span class="stat-value" id="messageCount"></span>
        </div>
      </div>
      <div class="control-group">
        <label class="control-label" for="searchBox">Search</label>
        <input id="searchBox" type="search" placeholder="Find text in the transcript" />
      </div>
      <div class="control-group">
        <label class="control-label" for="roleFilter">Role</label>
        <select id="roleFilter"></select>
      </div>
      <div class="control-group">
        <label class="control-label" for="phaseFilter">Phase</label>
        <select id="phaseFilter"></select>
      </div>
      <div class="control-group">
        <label class="control-label">Threads</label>
        <div id="threadList" class="thread-list"></div>
      </div>
    </aside>
    <main class="main">
      <section class="panel toolbar">
        <div>
          <h2 class="toolbar-title">Transcript</h2>
          <div class="toolbar-meta" id="activeFilter"></div>
        </div>
        <div class="toolbar-meta" id="resultCount"></div>
      </section>
      <section id="items" class="items"></section>
    </main>
  </div>
  <script id="transcript-data" type="application/json">$json</script>
  <script>
    const data = JSON.parse(document.getElementById('transcript-data').textContent);
    const state = { search: '', role: 'all', phase: 'all', threadId: 'all' };

    const threadList = document.getElementById('threadList');
    const itemsRoot = document.getElementById('items');
    const searchBox = document.getElementById('searchBox');
    const roleFilter = document.getElementById('roleFilter');
    const phaseFilter = document.getElementById('phaseFilter');
    const resultCount = document.getElementById('resultCount');
    const activeFilter = document.getElementById('activeFilter');

    document.getElementById('threadCount').textContent = String(data.threadCount);
    document.getElementById('messageCount').textContent = String(data.itemCount);
    document.getElementById('summaryLine').textContent = 'Generated ' + new Date(data.generatedAt).toLocaleString();

    function fillSelect(select, values, label) {
      select.innerHTML = '';
      const allOption = document.createElement('option');
      allOption.value = 'all';
      allOption.textContent = 'All ' + label;
      select.appendChild(allOption);
      values.forEach((value) => {
        const option = document.createElement('option');
        option.value = value;
        option.textContent = value;
        select.appendChild(option);
      });
    }

    function buildThreadList() {
      threadList.innerHTML = '';
      const allButton = document.createElement('button');
      allButton.className = 'thread-chip active';
      allButton.dataset.threadId = 'all';
      allButton.innerHTML = '<span class=\"thread-title\">All Threads</span><span class=\"thread-meta\">Browse the full transcript set</span>';
      threadList.appendChild(allButton);

      data.threads.forEach((thread) => {
        const button = document.createElement('button');
        button.className = 'thread-chip';
        button.dataset.threadId = thread.threadId;
        const title = thread.threadName || thread.project || thread.threadId;
        const metaParts = [thread.project, thread.threadId.slice(0, 8), thread.itemCount + ' items'].filter(Boolean);
        button.innerHTML =
          '<span class=\"thread-title\">' + escapeHtml(title) + '</span>' +
          '<span class=\"thread-meta\">' + escapeHtml(metaParts.join(' | ')) + '</span>';
        threadList.appendChild(button);
      });
    }

    function escapeHtml(text) {
      return String(text ?? '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('\"', '&quot;');
    }

    function currentItems() {
      const search = state.search.trim().toLowerCase();
      return data.items.filter((item) => {
        if (state.threadId !== 'all' && item.threadId !== state.threadId) { return false; }
        if (state.role !== 'all' && item.role !== state.role) { return false; }
        if (state.phase !== 'all' && (item.phase || '') !== state.phase) { return false; }
        if (search) {
          const haystack = [item.text, item.threadName, item.project, item.role, item.phase].join(' ').toLowerCase();
          if (!haystack.includes(search)) { return false; }
        }
        return true;
      });
    }

    function render() {
      Array.from(threadList.querySelectorAll('.thread-chip')).forEach((button) => {
        button.classList.toggle('active', button.dataset.threadId === state.threadId);
      });

      const filtered = currentItems();
      const threadLabel = state.threadId === 'all'
        ? 'All threads'
        : (data.threads.find((thread) => thread.threadId === state.threadId)?.threadName || state.threadId);
      const bits = [threadLabel];
      if (state.role !== 'all') { bits.push('role: ' + state.role); }
      if (state.phase !== 'all') { bits.push('phase: ' + state.phase); }
      if (state.search) { bits.push('search: "' + state.search + '"'); }
      activeFilter.textContent = bits.join(' | ');
      resultCount.textContent = filtered.length + ' visible items';

      if (!filtered.length) {
        itemsRoot.innerHTML = '<div class=\"panel empty\">No transcript items match the current filters.</div>';
        return;
      }

      itemsRoot.innerHTML = filtered.map((item) => {
        const title = item.threadName || item.project || item.threadId;
        const metaBits = [item.phase, item.when, item.project].filter(Boolean).map(escapeHtml).join(' | ');
        return [
          '<article class=\"item\">',
          '  <div class=\"item-header\">',
          '    <span class=\"badge ' + escapeHtml(item.role) + '\">' + escapeHtml(item.role) + '</span>',
          metaBits ? '    <span class=\"meta\">' + metaBits + '</span>' : '',
          '    <span class=\"item-thread\">' + escapeHtml(title) + '</span>',
          '  </div>',
          '  <pre class=\"item-text\">' + escapeHtml(item.text) + '</pre>',
          '</article>'
        ].join('');
      }).join('');
    }

    fillSelect(roleFilter, data.roles, 'roles');
    fillSelect(phaseFilter, data.phases, 'phases');
    buildThreadList();
    render();

    searchBox.addEventListener('input', (event) => {
      state.search = event.target.value;
      render();
    });
    roleFilter.addEventListener('change', (event) => {
      state.role = event.target.value;
      render();
    });
    phaseFilter.addEventListener('change', (event) => {
      state.phase = event.target.value;
      render();
    });
    threadList.addEventListener('click', (event) => {
      const button = event.target.closest('.thread-chip');
      if (!button) { return; }
      state.threadId = button.dataset.threadId;
      render();
    });
  </script>
</body>
</html>
"@
}

function Show-CodexTranscript {
    <#
    .SYNOPSIS
        Builds a local interactive HTML page for one or more Codex transcripts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('ThreadId')][string[]]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [string]$OutputPath,
        [string]$Title,
        [switch]$NoOpen,
        [switch]$PassThru,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [int]$Limit = 25,
        [PSCustomObject]$Session
    )

    begin {
        $threadIds = [System.Collections.Generic.List[string]]::new()
        $transcriptInputs = [System.Collections.Generic.List[object]]::new()
        $sourceInputs = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $typeNames = @($InputObject.PSObject.TypeNames)
            if ($typeNames -contains 'PSUnplugged.CodexTranscriptItem') {
                $transcriptInputs.Add($InputObject)
                return
            }

            $sourceInputs.Add($InputObject)
            return
        }

        foreach ($threadId in @($Id)) {
            if (-not [string]::IsNullOrWhiteSpace($threadId)) {
                $threadIds.Add($threadId)
            }
        }
    }

    end {
        $resolvedItems = [System.Collections.Generic.List[object]]::new()

        foreach ($item in $transcriptInputs) {
            $resolvedItems.Add($item)
        }

        foreach ($transcriptItem in @(Get-CodexTranscript -Id @($threadIds | Select-Object -Unique) -Project $Project -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit $Limit -Session $Session -SpinnerStatus $null)) {
            $resolvedItems.Add($transcriptItem)
        }

        if ($sourceInputs.Count -gt 0) {
            foreach ($transcriptItem in @($sourceInputs | Get-CodexTranscript -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit $Limit -Session $Session -SpinnerStatus $null)) {
                $resolvedItems.Add($transcriptItem)
            }
        }

        $items = @(
            $resolvedItems |
            Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.ThreadId } }, @{ Expression = { $_.Index } }
        )

        if ($items.Count -eq 0) {
            return
        }

        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $OutputPath = New-CodexTranscriptHtmlPath -Transcript $items -Title $Title
        }
        else {
            $directory = Split-Path -Parent $OutputPath
            if ($directory -and -not (Test-Path -LiteralPath $directory)) {
                $null = New-Item -ItemType Directory -Path $directory -Force
            }
            $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
        }

        $html = ConvertTo-CodexTranscriptHtml -Transcript $items -Title $Title
        Set-Content -LiteralPath $OutputPath -Value $html -Encoding utf8

        if (-not $NoOpen) {
            Start-Process -FilePath $OutputPath
        }

        if ($PassThru -or $NoOpen) {
            $page = [PSCustomObject]@{
                Path        = $OutputPath
                Title       = if ([string]::IsNullOrWhiteSpace($Title)) { $null } else { $Title }
                ThreadCount = @($items | Group-Object ThreadId).Count
                ItemCount   = $items.Count
                Opened      = (-not $NoOpen)
            }
            $page.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTranscriptPage')
            return $page
        }
    }
}

function New-CodexTaskDashboardHtmlPath {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Task = @(),
        [string]$Title
    )

    $Task = @($Task | Where-Object { $null -ne $_ })

    $root = Join-Path (Get-PSUnpluggedDataRoot) 'dashboards'
    if (-not (Test-Path -LiteralPath $root)) {
        $null = New-Item -ItemType Directory -Path $root -Force
    }

    $projectNames = @(
        $Task |
        ForEach-Object { [string](Get-CodexFirstValue -InputObject $_ -PropertyName @('Project', 'project', 'ProjectName', 'projectName')) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    )

    $baseName = if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $Title
    }
    elseif ($projectNames.Count -eq 1) {
        '{0}-codex-dashboard' -f $projectNames[0]
    }
    else {
        'codex-task-dashboard'
    }

    $safeName = Get-CodexSafeFileName -Name $baseName
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    return (Join-Path $root "$stamp-$safeName.html")
}

function New-CodexTaskDashboardData {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Task = @(),
        [string]$Title
    )

    $Task = @($Task | Where-Object { $null -ne $_ })

    $pageTitle = if ([string]::IsNullOrWhiteSpace($Title)) { 'Codex Task Dashboard' } else { $Title }
    $taskCount = $Task.Count
    $activeCount = @($Task | Where-Object { [string]$_.status -in @('active', 'starting', 'running') }).Count
    $failedCount = @($Task | Where-Object { [string]$_.status -in @('failed', 'error', 'canceled') }).Count
    $attentionCount = @($Task | Where-Object { ([int]$_.approvalCount -gt 0) -or -not [string]::IsNullOrWhiteSpace([string]$_.lastErrorMessage) }).Count

    $data = [PSCustomObject]@{
        title          = $pageTitle
        generatedAt    = (Get-Date).ToString('o')
        taskCount      = $taskCount
        activeCount    = $activeCount
        failedCount    = $failedCount
        attentionCount = $attentionCount
        projects       = @($Task.project | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        statuses       = @($Task.status | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        tasks          = @($Task)
    }

    $data.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTaskDashboardData')
    return $data
}

function ConvertTo-CodexTaskDashboardHtml {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Task = @(),
        [AllowNull()]$Data,
        [string]$Title
    )

    $dashboardData = if ($null -ne $Data) {
        $Data
    }
    else {
        New-CodexTaskDashboardData -Task @($Task) -Title $Title
    }

    $pageTitle = [string](Get-CodexFirstValue -InputObject $dashboardData -PropertyName @('title', 'Title'))
    if ([string]::IsNullOrWhiteSpace($pageTitle)) {
        $pageTitle = if ([string]::IsNullOrWhiteSpace($Title)) { 'Codex Task Dashboard' } else { $Title }
    }

    $json = ($dashboardData | ConvertTo-Json -Depth 12)
    $json = $json -replace '</script>', '<\/script>'
    $encodedTitle = [System.Net.WebUtility]::HtmlEncode($pageTitle)

    return @"
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>$encodedTitle</title>
  <style>
    :root {
      --bg: #f3f5f4;
      --surface: #ffffff;
      --surface-soft: #edf0ee;
      --ink: #151e1b;
      --muted: #5f6d6a;
      --line: #d5dbd8;
      --accent: #0b7f8d;
      --accent-soft: #e0f4f6;
      --ok: #2e7a31;
      --ok-bg: #e8f5e9; --ok-bd: #c6e6c8;
      --warn: #975f05;
      --warn-bg: #fff8e1; --warn-bd: #f8d97a;
      --danger: #b61b1b;
      --danger-bg: #fef2f2; --danger-bd: #fbbfbf;
      --info: #1a4fd6;
      --info-bg: #eff6ff; --info-bd: #bcd4fe;
      --mono: "Cascadia Code","SFMono-Regular",Consolas,monospace;
      --r: 8px;
      --tr: 120ms ease;
    }
    [data-theme="dark"] {
      --bg: #0d1311;
      --surface: #141c19;
      --surface-soft: #1b2421;
      --ink: #dce8e4;
      --muted: #7a9590;
      --line: #253330;
      --accent: #1fb3c2;
      --accent-soft: #0b3039;
      --ok: #43a047;
      --ok-bg: #162318; --ok-bd: #2a5c2d;
      --warn: #f59e0b;
      --warn-bg: #1c1600; --warn-bd: #5c440f;
      --danger: #f87171;
      --danger-bg: #260f0f; --danger-bd: #6b1c1c;
      --info: #60a5fa;
      --info-bg: #0d1a35; --info-bd: #1e3d7a;
    }
    *, *::before, *::after { box-sizing: border-box; }
    body {
      margin: 0; min-height: 100vh;
      background: var(--bg); color: var(--ink);
      font-family: "Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;
      font-size: 14px;
      transition: background var(--tr), color var(--tr);
    }
    button, input, select { font: inherit; }
    ::-webkit-scrollbar { width: 6px; height: 6px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: var(--line); border-radius: 3px; }
    ::-webkit-scrollbar-thumb:hover { background: var(--muted); }
    .app {
      display: grid;
      grid-template-columns: 380px minmax(0,1fr);
      min-height: 100vh;
    }
    .sidebar {
      border-right: 1px solid var(--line);
      background: var(--surface);
      min-width: 0;
      display: grid;
      grid-template-rows: auto auto auto minmax(0,1fr);
      overflow: hidden;
    }
    .brand {
      padding: 14px 16px;
      border-bottom: 1px solid var(--line);
      display: flex;
      align-items: flex-start;
      gap: 10px;
    }
    .brand-text { flex: 1; min-width: 0; }
    .brand h1 {
      margin: 0; font-size: 16px; line-height: 1.25;
      color: var(--accent);
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .generated { color: var(--muted); margin-top: 4px; font-size: 12px; }
    .theme-btn {
      flex-shrink: 0;
      background: var(--surface-soft);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 4px 9px;
      cursor: pointer; font-size: 14px; line-height: 1;
      color: var(--ink);
      transition: background var(--tr);
      user-select: none;
    }
    .theme-btn:hover { background: var(--accent-soft); }
    .metrics {
      display: grid;
      grid-template-columns: repeat(4,minmax(0,1fr));
      gap: 1px; background: var(--line);
      border-bottom: 1px solid var(--line);
    }
    .metric {
      background: var(--surface);
      padding: 10px 10px; min-width: 0;
      cursor: pointer;
      transition: background var(--tr);
    }
    .metric:hover { background: var(--surface-soft); }
    .metric.active-filter { background: var(--accent-soft); }
    .metric span {
      display: block; color: var(--muted);
      font-size: 11px; line-height: 1.2;
      text-transform: uppercase; letter-spacing: .04em;
    }
    .metric strong {
      display: block; margin-top: 5px;
      font-size: 22px; line-height: 1;
      font-variant-numeric: tabular-nums;
    }
    .metric.m-active strong { color: var(--info); }
    .metric.m-failed strong { color: var(--danger); }
    .metric.m-attn strong { color: var(--warn); }
    .filters {
      padding: 10px 12px;
      display: grid; grid-template-columns: 1fr 1fr; gap: 7px;
      border-bottom: 1px solid var(--line);
      background: var(--surface-soft);
      min-height: 0;
    }
    .nlp-row {
      grid-column: 1 / -1;
      display: grid; grid-template-columns: minmax(0,1fr) 58px; gap: 7px;
    }
    .search-row { grid-column: 1 / -1; }
    .filters input, .filters select, .filters button {
      width: 100%; min-width: 0;
      border: 1px solid var(--line);
      background: var(--surface); color: var(--ink);
      border-radius: 6px; padding: 7px 10px; outline: none;
      transition: border-color var(--tr), box-shadow var(--tr);
    }
    .filters button {
      cursor: pointer; font-weight: 650;
      background: var(--accent); color: white; border-color: var(--accent);
    }
    .filters button:hover { opacity: .88; }
    .filters input:focus, .filters select:focus {
      border-color: var(--accent);
      box-shadow: 0 0 0 3px var(--accent-soft);
    }
    .task-list {
      overflow-y: auto; padding: 8px;
      display: flex; flex-direction: column; gap: 6px;
      min-height: 0;
    }
    .task-card {
      width: 100%; text-align: left;
      border: 1px solid var(--line);
      background: var(--surface); color: var(--ink);
      border-radius: var(--r); padding: 11px 12px;
      cursor: pointer; outline: none;
      transition: border-color var(--tr), box-shadow var(--tr), background var(--tr);
    }
    .task-card:hover { border-color: #9db6b0; box-shadow: 0 1px 4px rgba(0,0,0,.06); }
    .task-card:focus-visible { box-shadow: 0 0 0 3px var(--accent-soft); border-color: var(--accent); }
    .task-card.selected {
      border-color: var(--accent);
      background: var(--accent-soft);
      box-shadow: inset 3px 0 0 var(--accent);
    }
    .task-title-row { display: flex; gap: 7px; align-items: center; min-width: 0; }
    .task-title {
      min-width: 0; flex: 1;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      font-weight: 650; font-size: 13px;
    }
    .task-meta {
      display: flex; gap: 6px; flex-wrap: wrap;
      color: var(--muted); margin-top: 7px; font-size: 12px;
    }
    .task-meta-sep { opacity: .35; }
    .preview {
      margin-top: 9px; padding: 8px 10px;
      border-radius: 6px;
      background: #1a201e; color: #d4e8e3;
      font-family: var(--mono); font-size: 11.5px; line-height: 1.45;
      max-height: 50px; overflow: hidden; white-space: pre-wrap;
    }
    [data-theme="dark"] .preview { background: #0b1210; color: #b8d4cf; }
    .pill {
      display: inline-flex; align-items: center; gap: 4px;
      min-height: 20px; border-radius: 999px;
      padding: 2px 8px; font-size: 11px; font-weight: 700;
      line-height: 1.3; border: 1px solid transparent; white-space: nowrap;
    }
    .pill-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
    .pill.completed { color: var(--ok); background: var(--ok-bg); border-color: var(--ok-bd); }
    .pill.completed .pill-dot { background: var(--ok); }
    .pill.active, .pill.starting, .pill.running {
      color: var(--info); background: var(--info-bg); border-color: var(--info-bd);
    }
    .pill.active .pill-dot, .pill.starting .pill-dot, .pill.running .pill-dot {
      background: var(--info);
      animation: blink 1.8s ease-in-out infinite;
    }
    .pill.failed, .pill.error, .pill.canceled {
      color: var(--danger); background: var(--danger-bg); border-color: var(--danger-bd);
    }
    .pill.failed .pill-dot, .pill.error .pill-dot, .pill.canceled .pill-dot { background: var(--danger); }
    .pill.archived { color: var(--muted); background: var(--surface-soft); border-color: var(--line); }
    .pill.archived .pill-dot { background: var(--muted); }
    .pill.attention { color: var(--warn); background: var(--warn-bg); border-color: var(--warn-bd); }
    .pill.attention .pill-dot { background: var(--warn); animation: blink 1.2s ease-in-out infinite; }
    @keyframes blink { 0%,100% { opacity:1; } 50% { opacity:.2; } }
    .content {
      min-width: 0;
      display: grid; grid-template-rows: auto auto 1fr;
      overflow: hidden;
    }
    .topbar {
      padding: 14px 20px;
      border-bottom: 1px solid var(--line);
      background: var(--surface);
      display: grid; grid-template-columns: minmax(0,1fr) auto;
      gap: 16px; align-items: center;
    }
    .selected-title { margin: 0; font-size: 19px; line-height: 1.25; overflow-wrap: anywhere; }
    .selected-subtitle {
      margin-top: 4px; color: var(--muted); font-size: 12px;
      overflow-wrap: anywhere; display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
    }
    .copy-id-btn {
      background: var(--surface-soft); border: 1px solid var(--line);
      border-radius: 5px; padding: 2px 8px; cursor: pointer;
      font-size: 11px; color: var(--muted);
      transition: background var(--tr), color var(--tr);
    }
    .copy-id-btn:hover { background: var(--accent-soft); color: var(--accent); }
    .segmented {
      display: inline-flex;
      border: 1px solid var(--line); border-radius: var(--r);
      overflow: hidden; background: var(--surface-soft);
    }
    .segmented button {
      border: 0; border-right: 1px solid var(--line);
      background: transparent; color: var(--ink);
      padding: 7px 12px; cursor: pointer; min-width: 74px;
      transition: background var(--tr), color var(--tr); font-size: 13px;
    }
    .segmented button:last-child { border-right: 0; }
    .segmented button:hover { background: var(--accent-soft); }
    .segmented button.active { background: var(--accent); color: white; }
    .summary-strip {
      display: grid; grid-template-columns: repeat(5,minmax(0,1fr));
      border-bottom: 1px solid var(--line); background: var(--surface);
    }
    .summary-cell { border-right: 1px solid var(--line); padding: 10px 14px; min-width: 0; }
    .summary-cell:last-child { border-right: 0; }
    .summary-cell span {
      display: block; color: var(--muted); font-size: 11px;
      text-transform: uppercase; letter-spacing: .04em; margin-bottom: 4px;
    }
    .summary-cell strong {
      display: block; overflow: hidden; text-overflow: ellipsis;
      white-space: nowrap; font-size: 13px;
    }
    .view { min-height: 0; overflow-y: auto; padding: 16px 20px; }
    .detail-grid {
      display: grid;
      grid-template-columns: minmax(0,1.35fr) minmax(300px,.65fr);
      gap: 14px; align-items: start;
    }
    .section {
      border: 1px solid var(--line); border-radius: var(--r);
      background: var(--surface); overflow: hidden; margin-bottom: 14px;
    }
    .section-header {
      padding: 9px 12px;
      border-bottom: 1px solid var(--line);
      background: var(--surface-soft);
      display: flex; justify-content: space-between; gap: 10px; align-items: center;
      cursor: pointer; user-select: none;
      transition: background var(--tr);
    }
    .section-header:hover { background: var(--accent-soft); }
    .section-header h2 {
      margin: 0; font-size: 11px; line-height: 1.2;
      text-transform: uppercase; letter-spacing: .06em; color: var(--muted);
    }
    .section-hdr-right { display: flex; align-items: center; gap: 8px; }
    .count { color: var(--muted); font-size: 12px; }
    .chevron { color: var(--muted); font-size: 10px; transition: transform var(--tr); display: inline-block; }
    .section.collapsed .chevron { transform: rotate(-90deg); }
    .section.collapsed .rows { display: none; }
    .section.collapsed { border-bottom: none; }
    .rows { display: flex; flex-direction: column; }
    .row { padding: 10px 12px; border-bottom: 1px solid var(--line); transition: background var(--tr); }
    .row:last-child { border-bottom: 0; }
    .row:hover { background: var(--surface-soft); }
    .row-head {
      display: flex; gap: 8px; align-items: center;
      color: var(--muted); font-size: 11.5px; margin-bottom: 6px;
    }
    .row-kind { font-family: var(--mono); color: var(--ink); font-weight: 650; font-size: 12px; }
    .row-time { margin-left: auto; font-size: 11px; color: var(--muted); white-space: nowrap; }
    .row-text { margin: 0; white-space: pre-wrap; line-height: 1.5; overflow-wrap: anywhere; font-size: 13px; }
    .row-text.mono { font-family: var(--mono); font-size: 12px; }
    .empty { padding: 28px 12px; color: var(--muted); text-align: center; font-size: 13px; }
    @media (max-width: 1100px) {
      .app { grid-template-columns: 320px minmax(0,1fr); }
      .summary-strip { grid-template-columns: repeat(3,minmax(0,1fr)); }
      .detail-grid { grid-template-columns: 1fr; }
    }
    @media (max-width: 820px) {
      .app { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
      .sidebar { min-height: 46vh; border-right: 0; border-bottom: 1px solid var(--line); }
      .content { min-height: 54vh; }
      .topbar { grid-template-columns: 1fr; }
      .segmented { width: 100%; }
      .segmented button { flex: 1; min-width: 0; }
      .summary-strip { grid-template-columns: repeat(2,minmax(0,1fr)); }
    }
  </style>
</head>
<body>
  <div class="app">
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-text">
          <h1>$encodedTitle</h1>
          <div class="generated" id="generatedAt"></div>
        </div>
        <button class="theme-btn" id="themeBtn" title="Toggle color theme" aria-label="Toggle color theme">Dark</button>
      </div>
      <div class="metrics">
        <div class="metric" id="mTotal" title="Show all tasks"><span>Tasks</span><strong id="metricTasks"></strong></div>
        <div class="metric m-active" id="mActive" title="Filter active tasks"><span>Active</span><strong id="metricActive"></strong></div>
        <div class="metric m-failed" id="mFailed" title="Filter failed tasks"><span>Failed</span><strong id="metricFailed"></strong></div>
        <div class="metric m-attn" id="mAttn" title="Filter tasks needing attention"><span>Attn</span><strong id="metricAttention"></strong></div>
      </div>
      <div class="filters">
        <div class="nlp-row">
          <input id="nlpBox" type="text" placeholder="Natural language filter&hellip;" />
          <button id="nlpRun" type="button">Ask</button>
        </div>
        <div class="search-row">
          <input id="searchBox" type="search" placeholder="Search tasks and output&hellip;" />
        </div>
        <select id="statusFilter"></select>
        <select id="projectFilter"></select>
      </div>
      <div class="task-list" id="taskList" role="listbox" aria-label="Task list"></div>
    </aside>
    <main class="content">
      <div class="topbar">
        <div>
          <h2 class="selected-title" id="selectedTitle"></h2>
          <div class="selected-subtitle" id="selectedSubtitle"></div>
        </div>
        <div class="segmented" role="group" aria-label="Detail view">
          <button type="button" data-view="focused" class="active">Focused</button>
          <button type="button" data-view="verbose">Verbose</button>
        </div>
      </div>
      <div class="summary-strip">
        <div class="summary-cell"><span>Status</span><strong id="summaryStatus"></strong></div>
        <div class="summary-cell"><span>Events</span><strong id="summaryEvents"></strong></div>
        <div class="summary-cell"><span>Artifacts</span><strong id="summaryArtifacts"></strong></div>
        <div class="summary-cell"><span>Approvals</span><strong id="summaryApprovals"></strong></div>
        <div class="summary-cell"><span>Session</span><strong id="summarySession"></strong></div>
      </div>
      <div class="view" id="detailView"></div>
    </main>
  </div>
  <script id="dashboard-data" type="application/json">$json</script>
  <script>
    const data = JSON.parse(document.getElementById('dashboard-data').textContent);
    const state = { selectedId: null, search: '', status: 'all', project: 'all', view: 'focused', attentionOnly: false, topic: 'all' };

    const taskList = document.getElementById('taskList');
    const detailView = document.getElementById('detailView');
    const searchBox = document.getElementById('searchBox');
    const nlpBox = document.getElementById('nlpBox');
    const nlpRun = document.getElementById('nlpRun');
    const statusFilter = document.getElementById('statusFilter');
    const projectFilter = document.getElementById('projectFilter');
    const themeBtn = document.getElementById('themeBtn');

    // Theme toggle (persisted in localStorage)
    function applyTheme(theme) {
      document.documentElement.dataset.theme = theme;
      themeBtn.textContent = theme === 'dark' ? 'Light' : 'Dark';
      try { localStorage.setItem('cdx-theme', theme); } catch(_) {}
    }
    const savedTheme = (() => { try { return localStorage.getItem('cdx-theme'); } catch(_) { return null; } })();
    applyTheme(savedTheme === 'dark' ? 'dark' : 'light');
    themeBtn.addEventListener('click', () => {
      applyTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
    });

    document.getElementById('generatedAt').textContent = 'Generated ' + new Date(data.generatedAt).toLocaleString();
    document.getElementById('metricTasks').textContent = String(data.taskCount);
    document.getElementById('metricActive').textContent = String(data.activeCount);
    document.getElementById('metricFailed').textContent = String(data.failedCount);
    document.getElementById('metricAttention').textContent = String(data.attentionCount);

    function escapeHtml(value) {
      return String(value ?? '')
        .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;').replaceAll("'", '&#039;');
    }
    function compact(value, fallback = '') {
      const text = String(value ?? '').replace(/\s+/g, ' ').trim();
      return text || fallback;
    }
    function timeAgo(isoString) {
      if (!isoString) { return ''; }
      const diff = Date.now() - new Date(isoString).getTime();
      if (isNaN(diff) || diff < 0) { return ''; }
      if (diff < 60000) { return 'just now'; }
      if (diff < 3600000) { return Math.floor(diff / 60000) + 'm ago'; }
      if (diff < 86400000) { return Math.floor(diff / 3600000) + 'h ago'; }
      return Math.floor(diff / 86400000) + 'd ago';
    }
    function fillSelect(select, values, allLabel) {
      select.innerHTML = '';
      const all = document.createElement('option');
      all.value = 'all'; all.textContent = allLabel;
      select.appendChild(all);
      values.forEach((value) => {
        const option = document.createElement('option');
        option.value = value; option.textContent = value;
        select.appendChild(option);
      });
    }
    function statusClass(status) {
      const n = compact(status, 'active').toLowerCase();
      if (['failed','error','canceled'].includes(n)) { return n; }
      if (['completed','active','starting','running','archived'].includes(n)) { return n; }
      return 'active';
    }
    function pillHtml(status, showAttn) {
      const cls = statusClass(status);
      const label = escapeHtml(compact(status, 'active'));
      const attnPill = showAttn ? ' <span class="pill attention"><span class="pill-dot"></span>attn</span>' : '';
      return '<span class="pill ' + cls + '"><span class="pill-dot"></span>' + label + '</span>' + attnPill;
    }

    function filteredTasks() {
      const search = state.search.toLowerCase().trim();
      return data.tasks.filter((task) => {
        if (state.status !== 'all' && task.status !== state.status) { return false; }
        if (state.project !== 'all' && task.project !== state.project) { return false; }
        if (state.attentionOnly && !(task.approvalCount > 0 || compact(task.lastErrorMessage))) { return false; }
        if (search) {
          const haystack = [task.name, task.project, task.status, task.shortId, task.path,
            task.latest?.summary, task.latest?.text, task.lastErrorMessage].join(' ').toLowerCase();
          if (!haystack.includes(search)) { return false; }
        }
        return true;
      });
    }
    function selectedTask() {
      const visible = filteredTasks();
      if (!visible.length) { return null; }
      if (!state.selectedId || !visible.some((t) => t.id === state.selectedId)) {
        state.selectedId = visible[0].id;
      }
      return visible.find((t) => t.id === state.selectedId) || visible[0];
    }
    function chooseProject(text) {
      const needle = text.toLowerCase().trim();
      if (!needle) { return false; }
      const match = data.projects.find((p) => p.toLowerCase() === needle)
        || data.projects.find((p) => p.toLowerCase().includes(needle));
      if (!match) { return false; }
      state.project = match; return true;
    }
    function chooseTask(text) {
      const needle = text.toLowerCase().trim();
      if (!needle) { return false; }
      const task = data.tasks.find((c) =>
        [c.id, c.shortId, c.name, c.project].filter(Boolean)
          .some((v) => String(v).toLowerCase().includes(needle))
      );
      if (!task) { return false; }
      state.selectedId = task.id; return true;
    }
    function syncControls() {
      searchBox.value = state.search;
      statusFilter.value = state.status;
      projectFilter.value = state.project;
      document.querySelectorAll('.segmented button').forEach((b) => {
        b.classList.toggle('active', b.dataset.view === state.view);
      });
    }
    function resetNaturalFilters() {
      state.search = ''; state.status = 'all'; state.project = 'all';
      state.attentionOnly = false; state.topic = 'all'; state.view = 'focused';
    }
    function applyNaturalCommand(rawText) {
      const command = compact(rawText).toLowerCase();
      if (!command) { return; }
      if (/^(all|clear|reset|show all|all tasks|show everything)$/.test(command)) {
        resetNaturalFilters(); syncControls(); renderDetail(); return;
      }
      let consumed = false;
      for (const term of ['failed','error','canceled','completed','active','starting','running','archived']) {
        if (new RegExp('\\b' + term + '\\b').test(command) && data.statuses.includes(term)) {
          state.status = term; consumed = true; break;
        }
      }
      if (/\b(attention|stuck|blocked|approval|approvals|needs)\b/.test(command)) {
        state.attentionOnly = true;
        const t = data.tasks.find((c) => c.approvalCount > 0 || compact(c.lastErrorMessage));
        if (t) { state.selectedId = t.id; }
        consumed = true;
      }
      if (/\b(verbose|everything|all events|all output)\b/.test(command)) { state.view = 'verbose'; consumed = true; }
      if (/\b(focused|focus|summary)\b/.test(command)) { state.view = 'focused'; consumed = true; }
      const projectMatch = command.match(/\b(project|repo|repository)\s+(.+)$/);
      if (projectMatch && chooseProject(projectMatch[2])) { consumed = true; }
      const taskMatch = command.match(/\b(task|session|thread)\s+(.+)$/);
      if (taskMatch && chooseTask(taskMatch[2])) { consumed = true; }
      if (/\bartifacts?\b/.test(command)) {
        const t = data.tasks.find((c) => c.artifactCount > 0);
        if (t) { state.selectedId = t.id; }
        state.topic = 'artifacts'; consumed = true;
      }
      if (/\bevents?\b/.test(command)) {
        const t = data.tasks.find((c) => c.eventCount > 0);
        if (t) { state.selectedId = t.id; }
        state.topic = 'events'; consumed = true;
      }
      if (/\btranscript|output|reply\b/.test(command)) { state.topic = 'transcript'; consumed = true; }
      if (!consumed) { state.search = command; }
      syncControls(); renderDetail();
    }

    function renderTaskList() {
      const visible = filteredTasks();
      if (!visible.length) {
        taskList.innerHTML = '<div class="empty">No tasks match the current filters.</div>';
        return;
      }
      taskList.innerHTML = visible.map((task, idx) => {
        const title = compact(task.name, task.shortId || task.id);
        const status = compact(task.status, 'active');
        const latest = compact(task.latest?.summary || task.latest?.text, 'Waiting for output…');
        const attention = task.approvalCount > 0 || compact(task.lastErrorMessage);
        const ago = timeAgo(task.timestamp);
        const metaParts = [task.project, ago, task.shortId].filter(Boolean);
        const meta = metaParts.map(escapeHtml).join('<span class="task-meta-sep"> | </span>');
        const isSelected = task.id === state.selectedId;
        return [
          '<button class="task-card' + (isSelected ? ' selected' : '') + '"',
          ' data-id="' + escapeHtml(task.id) + '"',
          ' role="option" aria-selected="' + isSelected + '"',
          ' tabindex="' + (idx === 0 || isSelected ? '0' : '-1') + '">',
          '<div class="task-title-row">',
          '<span class="task-title">' + escapeHtml(title) + '</span>',
          pillHtml(status, attention),
          '</div>',
          meta ? '<div class="task-meta">' + meta + '</div>' : '',
          '<div class="preview">' + escapeHtml(latest) + '</div>',
          '</button>'
        ].join('');
      }).join('');
    }

    function rowHtml(kind, when, text, options = {}) {
      const meta = [options.phase, options.name].filter(Boolean).map(escapeHtml).join(' · ');
      const ago = timeAgo(when);
      return [
        '<div class="row">',
        '<div class="row-head">',
        '<span class="row-kind">' + escapeHtml(kind) + '</span>',
        meta ? '<span>' + meta + '</span>' : '',
        ago ? '<span class="row-time">' + escapeHtml(ago) + '</span>' : '',
        '</div>',
        '<pre class="row-text' + (options.mono ? ' mono' : '') + '">' + escapeHtml(text) + '</pre>',
        '</div>'
      ].join('');
    }
    function sectionHtml(title, countLabel, body) {
      return [
        '<section class="section">',
        '<div class="section-header">',
        '<h2>' + escapeHtml(title) + '</h2>',
        '<div class="section-hdr-right">',
        '<span class="count">' + escapeHtml(countLabel) + '</span>',
        '<span class="chevron">&#9660;</span>',
        '</div></div>',
        '<div class="rows">' + body + '</div>',
        '</section>'
      ].join('');
    }

    function renderDetail() {
      const task = selectedTask();
      renderTaskList();
      if (!task) {
        document.getElementById('selectedTitle').textContent = 'No tasks';
        document.getElementById('selectedSubtitle').innerHTML = '';
        detailView.innerHTML = '<div class="empty">No tasks match the current filters.</div>';
        return;
      }

      document.getElementById('selectedTitle').textContent = compact(task.name, task.shortId || task.id);
      const subtitleParts = [task.project, task.path, task.branch].filter(Boolean).map(escapeHtml).join(' · ');
      const copyBtn = '<button class="copy-id-btn" id="copyIdBtn">' + escapeHtml(task.shortId || task.id) + '</button>';
      document.getElementById('selectedSubtitle').innerHTML = (subtitleParts ? subtitleParts + ' ' : '') + copyBtn;
      document.getElementById('copyIdBtn').addEventListener('click', () => {
        navigator.clipboard?.writeText(task.id).then(() => {
          const btn = document.getElementById('copyIdBtn');
          if (btn) { const orig = btn.textContent; btn.textContent = 'Copied!'; setTimeout(() => { btn.textContent = orig; }, 1200); }
        });
      });

      document.getElementById('summaryStatus').innerHTML = pillHtml(task.status, false);
      document.getElementById('summaryEvents').textContent = String(task.eventCount || 0);
      document.getElementById('summaryArtifacts').textContent = String(task.artifactCount || 0);
      document.getElementById('summaryApprovals').textContent = String(task.approvalCount || 0);
      document.getElementById('summarySession').textContent = compact(task.sessionPath ? task.sessionPath.split(/[\\/]/).pop() : '', 'none');

      const transcriptItems = (task.transcript || []).filter((item) => {
        if (state.view === 'verbose') { return true; }
        const phase = compact(item.phase).toLowerCase();
        const role = compact(item.role).toLowerCase();
        return role !== 'user' && !['reasoning','tool','command'].includes(phase);
      });
      const transcriptBody = transcriptItems.length
        ? transcriptItems.map((item) => rowHtml(item.role || item.itemType || 'item', item.when || item.timestamp, item.text, { phase: item.phase })).join('')
        : '<div class="empty">No transcript items in this view.</div>';

      const eventItems = state.view === 'verbose'
        ? (task.events || [])
        : (task.events || []).filter((item) => !['Reasoning','ToolResult'].includes(item.kind));
      const eventBody = eventItems.length
        ? eventItems.map((item) => rowHtml(item.kind || 'Event', item.when || item.timestamp, item.summary || item.text || item.type, { name: item.name, phase: item.phase, mono: item.kind === 'Command' })).join('')
        : '<div class="empty">No events in this view.</div>';

      const artifactBody = (task.artifacts || []).length
        ? task.artifacts.map((item) => rowHtml(item.kind || 'Artifact', item.when || item.timestamp, item.summary || item.name, { name: item.name })).join('')
        : '<div class="empty">No artifacts discovered.</div>';

      const approvalBody = (task.approvals || []).length
        ? task.approvals.map((item) => rowHtml(item.approvalType || 'Approval', item.when, item.target || item.summary || item.status, { name: item.status })).join('')
        : '<div class="empty">No observed approvals.</div>';

      const latestBody = task.latest?.text
        ? rowHtml(task.latest.status || 'latest', task.latest.when || task.latest.timestamp, task.latest.text)
        : '<div class="empty">No latest output.</div>';

      const sections = {
        output: sectionHtml('Latest Output', task.latest?.status || '', latestBody),
        transcript: sectionHtml('Transcript', transcriptItems.length + ' visible', transcriptBody),
        events: sectionHtml('Events', eventItems.length + ' visible', eventBody),
        artifacts: sectionHtml('Artifacts', (task.artifacts || []).length + ' items', artifactBody),
        approvals: sectionHtml('Approvals', (task.approvals || []).length + ' items', approvalBody)
      };

      const left = state.topic === 'events' || state.topic === 'artifacts'
        ? [sections[state.topic], sections.output, sections.transcript].join('')
        : [sections.output, sections.transcript].join('');
      const right = state.topic === 'events' || state.topic === 'artifacts'
        ? [sections.approvals].join('')
        : [sections.events, sections.artifacts, sections.approvals].join('');

      detailView.innerHTML = '<div class="detail-grid"><div>' + left + '</div><div>' + right + '</div></div>';

      // Collapsible sections
      detailView.querySelectorAll('.section-header').forEach((header) => {
        header.addEventListener('click', () => header.closest('.section').classList.toggle('collapsed'));
      });
    }

    fillSelect(statusFilter, data.statuses, 'All statuses');
    fillSelect(projectFilter, data.projects, 'All projects');
    renderDetail();

    taskList.addEventListener('click', (event) => {
      const card = event.target.closest('.task-card');
      if (!card) { return; }
      state.selectedId = card.dataset.id;
      renderDetail();
    });

    // Arrow-key navigation in the task list
    taskList.addEventListener('keydown', (event) => {
      if (!['ArrowDown','ArrowUp','Enter',' '].includes(event.key)) { return; }
      event.preventDefault();
      const cards = Array.from(taskList.querySelectorAll('.task-card'));
      if (!cards.length) { return; }
      const curIdx = cards.findIndex((c) => c.dataset.id === state.selectedId);
      if (event.key === 'ArrowDown') {
        const next = cards[Math.min(curIdx + 1, cards.length - 1)];
        state.selectedId = next.dataset.id; renderDetail(); next.focus();
      } else if (event.key === 'ArrowUp') {
        const prev = cards[Math.max(curIdx - 1, 0)];
        state.selectedId = prev.dataset.id; renderDetail(); prev.focus();
      } else {
        const focused = document.activeElement?.closest('.task-card');
        if (focused) { state.selectedId = focused.dataset.id; renderDetail(); }
      }
    });

    searchBox.addEventListener('input', (event) => {
      state.search = event.target.value; state.attentionOnly = false; renderDetail();
    });
    nlpRun.addEventListener('click', () => applyNaturalCommand(nlpBox.value));
    nlpBox.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') { event.preventDefault(); applyNaturalCommand(nlpBox.value); }
    });
    statusFilter.addEventListener('change', (event) => {
      state.status = event.target.value; state.attentionOnly = false; renderDetail();
    });
    projectFilter.addEventListener('change', (event) => {
      state.project = event.target.value; state.attentionOnly = false; renderDetail();
    });

    // Metric tiles as filter shortcuts
    document.getElementById('mTotal').addEventListener('click', () => { resetNaturalFilters(); syncControls(); renderDetail(); });
    document.getElementById('mActive').addEventListener('click', () => {
      state.status = state.status === 'active' ? 'all' : 'active'; syncControls(); renderDetail();
    });
    document.getElementById('mFailed').addEventListener('click', () => {
      state.status = state.status === 'failed' ? 'all' : 'failed'; syncControls(); renderDetail();
    });
    document.getElementById('mAttn').addEventListener('click', () => {
      state.attentionOnly = !state.attentionOnly; syncControls(); renderDetail();
    });

    document.querySelectorAll('.segmented button').forEach((button) => {
      button.addEventListener('click', () => {
        state.view = button.dataset.view;
        document.querySelectorAll('.segmented button').forEach((b) => {
          b.classList.toggle('active', b.dataset.view === state.view);
        });
        renderDetail();
      });
    });
    </script>
</body>
</html>
"@
}

function ConvertTo-CodexTaskDashboardData {
    <#
    .SYNOPSIS
        Converts Codex tasks into the dashboard data contract.
    .DESCRIPTION
        ConvertTo-CodexTaskDashboardData returns the JSON-ready object consumed
        by Show-CodexTaskDashboard. Use this when a separate frontend should own
        the UI while PSUnplugged owns task/session state collection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('TaskId', 'ThreadId')][string[]]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [string]$Title,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [int]$Limit = 25,
        [int]$TranscriptLimit = 80,
        [int]$EventLimit = 120,
        [int]$ArtifactLimit = 40,
        [PSCustomObject]$Session
    )

    begin {
        $inputs = [System.Collections.Generic.List[object]]::new()
        $ids = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $inputs.Add($InputObject)
            return
        }

        foreach ($threadId in @($Id)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$threadId)) {
                $ids.Add([string]$threadId)
            }
        }
    }

    end {
        $taskLookup = [ordered]@{}

        foreach ($taskId in @($ids | Select-Object -Unique)) {
            $resolvedId = Resolve-CodexTaskIdentifierText -Id $taskId
            if ([string]::IsNullOrWhiteSpace($resolvedId)) {
                continue
            }

            $task = Get-CodexTask -Id $resolvedId -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 1 -Session $Session -SpinnerStatus $null |
            Select-Object -First 1
            if (-not $task) {
                $task = [PSCustomObject]@{
                    TaskId   = $resolvedId
                    ThreadId = $resolvedId
                    Status   = 'active'
                }
            }

            $taskLookup[$resolvedId] = $task
        }

        foreach ($item in @($inputs)) {
            if ($null -eq $item) {
                continue
            }

            $taskId = Resolve-CodexTaskIdentifier -InputObject $item
            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                $taskLookup[$taskId] = $item
            }
        }

        if ($taskLookup.Count -eq 0) {
            $effectiveProject = if ([string]::IsNullOrWhiteSpace($Project)) { (Get-Location).Path } else { $Project }
            foreach ($task in @(Get-CodexTask -Project $effectiveProject -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit $Limit -Session $Session -SpinnerStatus $null)) {
                $taskId = Resolve-CodexTaskIdentifier -InputObject $task
                if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                    $taskLookup[$taskId] = $task
                }
            }
        }

        $dashboardTasks = [System.Collections.Generic.List[object]]::new()
        foreach ($taskEntry in @($taskLookup.Values)) {
            $taskId = Resolve-CodexTaskIdentifier -InputObject $taskEntry
            if ([string]::IsNullOrWhiteSpace($taskId)) {
                continue
            }

            $task = if ($taskEntry.PSObject.TypeNames -contains 'PSUnplugged.CodexTask') {
                $taskEntry
            }
            else {
                Get-CodexTask -Id $taskId -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 1 -Session $Session -SpinnerStatus $null |
                Select-Object -First 1
            }
            if (-not $task) {
                $task = $taskEntry
            }

            $receiveParams = @{ Limit = 25 }
            if ($IncludeArchived) { $receiveParams.IncludeArchived = $true }
            if ($LocalOnly) { $receiveParams.LocalOnly = $true }
            if ($Session) { $receiveParams.Session = $Session }
            $latestOutput = @($task | Receive-CodexTask @receiveParams) | Select-Object -First 1

            $transcriptParams = @{
                Id               = $taskId
                IncludeTelemetry = $true
                TelemetryType    = @('all')
                SpinnerStatus    = $null
            }
            if ($IncludeArchived) { $transcriptParams.IncludeArchived = $true }
            if ($LocalOnly) { $transcriptParams.LocalOnly = $true }
            if ($Session) { $transcriptParams.Session = $Session }
            $transcript = @(
                Get-CodexTranscript @transcriptParams |
                Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } }
            )
            if ($TranscriptLimit -gt 0 -and $transcript.Count -gt $TranscriptLimit) {
                $transcript = @($transcript | Select-Object -Last $TranscriptLimit)
            }

            $eventParams = @{
                Id            = $taskId
                Limit         = $EventLimit
                SpinnerStatus = $null
            }
            if ($IncludeArchived) { $eventParams.IncludeArchived = $true }
            if ($LocalOnly) { $eventParams.LocalOnly = $true }
            if ($Session) { $eventParams.Session = $Session }
            $events = @(Get-CodexEvent @eventParams)

            $artifactParams = @{
                Id            = $taskId
                Limit         = $ArtifactLimit
                SpinnerStatus = $null
            }
            if ($IncludeArchived) { $artifactParams.IncludeArchived = $true }
            if ($LocalOnly) { $artifactParams.LocalOnly = $true }
            if ($Session) { $artifactParams.Session = $Session }
            $artifacts = @(Get-CodexArtifact @artifactParams)

            $approvalParams = @{
                Id            = $taskId
                Limit         = 40
                SpinnerStatus = $null
            }
            if ($IncludeArchived) { $approvalParams.IncludeArchived = $true }
            if ($LocalOnly) { $approvalParams.LocalOnly = $true }
            if ($Session) { $approvalParams.Session = $Session }
            $approvals = @(Get-CodexApproval @approvalParams)

            $sessionPath = Resolve-CodexTaskSessionPath -InputObject $task
            $latestText = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Text', 'text'))
            $latestSummary = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Summary', 'summary'))
            if ([string]::IsNullOrWhiteSpace($latestSummary)) {
                $latestSummary = if (-not [string]::IsNullOrWhiteSpace($latestText)) {
                    Get-CodexTaskReceiveSummary -Text $latestText
                }
                else {
                    [string](Get-CodexFirstValue -InputObject $task -PropertyName @('LastErrorMessage', 'lastErrorMessage'))
                }
            }

            $status = Get-CodexTaskEffectiveStatus -InputObject $task
            $eventKindCounts = @{}
            foreach ($group in @($events | Group-Object Kind)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$group.Name)) {
                    $eventKindCounts[[string]$group.Name] = $group.Count
                }
            }

            $artifactKindCounts = @{}
            foreach ($group in @($artifacts | Group-Object Kind)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$group.Name)) {
                    $artifactKindCounts[[string]$group.Name] = $group.Count
                }
            }

            $dashboardTasks.Add([PSCustomObject]@{
                    id               = $taskId
                    shortId          = Get-CodexCompactId -Id $taskId
                    name             = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Name', 'name', 'ThreadName', 'threadName'))
                    project          = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Project', 'project', 'ProjectName', 'projectName'))
                    path             = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Path', 'path', 'ProjectPath', 'projectPath'))
                    status           = if ([string]::IsNullOrWhiteSpace($status)) { 'active' } else { $status }
                    when             = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('When', 'when'))
                    timestamp        = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('LastActivityAt', 'lastActivityAt', 'Timestamp', 'timestamp'))
                    branch           = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Branch', 'branch', 'GitBranch', 'gitBranch'))
                    model            = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Model', 'model'))
                    source           = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Source', 'source'))
                    workerProcessId  = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('WorkerProcessId', 'workerProcessId'))
                    lastErrorMessage = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('LastErrorMessage', 'lastErrorMessage'))
                    sessionPath      = $sessionPath
                    latest           = [PSCustomObject]@{
                        status    = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Status', 'status'))
                        phase     = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Phase', 'phase'))
                        when      = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('When', 'when'))
                        timestamp = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Timestamp', 'timestamp'))
                        summary   = $latestSummary
                        text      = $latestText
                    }
                    eventCount       = $events.Count
                    eventKindCounts  = $eventKindCounts
                    artifactCount    = $artifacts.Count
                    artifactKinds    = $artifactKindCounts
                    approvalCount    = $approvals.Count
                    transcript       = @(
                        foreach ($item in $transcript) {
                            [PSCustomObject]@{
                                role      = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Role', 'role'))
                                itemType  = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('ItemType', 'itemType'))
                                phase     = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Phase', 'phase'))
                                when      = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('When', 'when'))
                                timestamp = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Timestamp', 'timestamp'))
                                text      = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Text', 'text'))
                            }
                        }
                    )
                    events           = @(
                        foreach ($event in $events) {
                            [PSCustomObject]@{
                                kind      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Kind', 'kind'))
                                type      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Type', 'type'))
                                name      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Name', 'name'))
                                phase     = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Phase', 'phase'))
                                when      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('When', 'when'))
                                timestamp = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Timestamp', 'timestamp'))
                                summary   = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Summary', 'summary'))
                                text      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Text', 'text'))
                            }
                        }
                    )
                    artifacts        = @(
                        foreach ($artifact in $artifacts) {
                            [PSCustomObject]@{
                                kind      = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Kind', 'kind'))
                                name      = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Name', 'name'))
                                path      = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Path', 'path'))
                                when      = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('When', 'when'))
                                timestamp = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Timestamp', 'timestamp'))
                                summary   = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Summary', 'summary'))
                                size      = Get-CodexFirstValue -InputObject $artifact -PropertyName @('Size', 'size')
                                itemCount = Get-CodexFirstValue -InputObject $artifact -PropertyName @('ItemCount', 'itemCount')
                            }
                        }
                    )
                    approvals        = @(
                        foreach ($approval in $approvals) {
                            [PSCustomObject]@{
                                status       = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('Status', 'status'))
                                approvalType = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('ApprovalType', 'approvalType'))
                                target       = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('Target', 'target'))
                                when         = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('When', 'when'))
                                summary      = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('Summary', 'summary'))
                            }
                        }
                    )
                })
        }

        $tasks = @(
            $dashboardTasks |
            Sort-Object -Property @{ Expression = { $_.timestamp }; Descending = $true }, @{ Expression = { $_.name } }
        )

        return (New-CodexTaskDashboardData -Task $tasks -Title $Title)
    }
}

function Show-CodexTaskDashboard {
    <#
    .SYNOPSIS
        Builds a local dashboard snapshot for one or more Codex tasks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('TaskId', 'ThreadId')][string[]]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [string]$OutputPath,
        [string]$Title,
        [switch]$NoOpen,
        [switch]$PassThru,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [int]$Limit = 25,
        [int]$TranscriptLimit = 80,
        [int]$EventLimit = 120,
        [int]$ArtifactLimit = 40,
        [PSCustomObject]$Session
    )

    begin {
        $inputs = [System.Collections.Generic.List[object]]::new()
        $ids = [System.Collections.Generic.List[string]]::new()
        $dashboardDataInputs = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            if ($InputObject.PSObject.TypeNames -contains 'PSUnplugged.CodexTaskDashboardData') {
                $dashboardDataInputs.Add($InputObject)
                return
            }

            $inputs.Add($InputObject)
            return
        }

        foreach ($threadId in @($Id)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$threadId)) {
                $ids.Add([string]$threadId)
            }
        }
    }

    end {
        if ($dashboardDataInputs.Count -gt 0) {
            $dashboardData = $dashboardDataInputs[0]
            $dashboardTasks = @($dashboardData.tasks | Where-Object { $null -ne $_ })

            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $OutputPath = New-CodexTaskDashboardHtmlPath -Task $dashboardTasks -Title $Title
            }
            else {
                $directory = Split-Path -Parent $OutputPath
                if ($directory -and -not (Test-Path -LiteralPath $directory)) {
                    $null = New-Item -ItemType Directory -Path $directory -Force
                }
                $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
            }

            $html = ConvertTo-CodexTaskDashboardHtml -Data $dashboardData -Title $Title
            Set-Content -LiteralPath $OutputPath -Value $html -Encoding utf8

            if (-not $NoOpen) {
                Start-Process -FilePath $OutputPath
            }

            if ($PassThru -or $NoOpen) {
                $page = [PSCustomObject]@{
                    Path      = $OutputPath
                    Title     = if ([string]::IsNullOrWhiteSpace($Title)) { [string](Get-CodexFirstValue -InputObject $dashboardData -PropertyName @('title', 'Title')) } else { $Title }
                    TaskCount = $dashboardTasks.Count
                    Opened    = (-not $NoOpen)
                }
                $page.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTaskDashboardPage')
                return $page
            }

            return
        }

        $taskLookup = [ordered]@{}

        foreach ($taskId in @($ids | Select-Object -Unique)) {
            $resolvedId = Resolve-CodexTaskIdentifierText -Id $taskId
            if ([string]::IsNullOrWhiteSpace($resolvedId)) {
                continue
            }

            $task = Get-CodexTask -Id $resolvedId -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 1 -Session $Session -SpinnerStatus $null |
            Select-Object -First 1
            if (-not $task) {
                $task = [PSCustomObject]@{
                    TaskId   = $resolvedId
                    ThreadId = $resolvedId
                    Status   = 'active'
                }
            }

            $taskLookup[$resolvedId] = $task
        }

        foreach ($item in @($inputs)) {
            if ($null -eq $item) {
                continue
            }

            $taskId = Resolve-CodexTaskIdentifier -InputObject $item
            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                $taskLookup[$taskId] = $item
            }
        }

        if ($taskLookup.Count -eq 0) {
            $effectiveProject = if ([string]::IsNullOrWhiteSpace($Project)) { (Get-Location).Path } else { $Project }
            foreach ($task in @(Get-CodexTask -Project $effectiveProject -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit $Limit -Session $Session -SpinnerStatus $null)) {
                $taskId = Resolve-CodexTaskIdentifier -InputObject $task
                if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                    $taskLookup[$taskId] = $task
                }
            }
        }

        $dashboardTasks = [System.Collections.Generic.List[object]]::new()
        foreach ($taskEntry in @($taskLookup.Values)) {
            $taskId = Resolve-CodexTaskIdentifier -InputObject $taskEntry
            if ([string]::IsNullOrWhiteSpace($taskId)) {
                continue
            }

            $task = if ($taskEntry.PSObject.TypeNames -contains 'PSUnplugged.CodexTask') {
                $taskEntry
            }
            else {
                Get-CodexTask -Id $taskId -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 1 -Session $Session -SpinnerStatus $null |
                Select-Object -First 1
            }
            if (-not $task) {
                $task = $taskEntry
            }

            $receiveParams = @{ Limit = 25 }
            if ($IncludeArchived) { $receiveParams.IncludeArchived = $true }
            if ($LocalOnly) { $receiveParams.LocalOnly = $true }
            if ($Session) { $receiveParams.Session = $Session }
            $latestOutput = @($task | Receive-CodexTask @receiveParams) | Select-Object -First 1

            $transcriptParams = @{
                Id               = $taskId
                IncludeTelemetry = $true
                TelemetryType    = @('all')
                SpinnerStatus    = $null
            }
            if ($IncludeArchived) { $transcriptParams.IncludeArchived = $true }
            if ($LocalOnly) { $transcriptParams.LocalOnly = $true }
            if ($Session) { $transcriptParams.Session = $Session }
            $transcript = @(
                Get-CodexTranscript @transcriptParams |
                Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } }
            )
            if ($TranscriptLimit -gt 0 -and $transcript.Count -gt $TranscriptLimit) {
                $transcript = @($transcript | Select-Object -Last $TranscriptLimit)
            }

            $eventParams = @{
                Id            = $taskId
                Limit         = $EventLimit
                SpinnerStatus = $null
            }
            if ($IncludeArchived) { $eventParams.IncludeArchived = $true }
            if ($LocalOnly) { $eventParams.LocalOnly = $true }
            if ($Session) { $eventParams.Session = $Session }
            $events = @(Get-CodexEvent @eventParams)

            $artifactParams = @{
                Id            = $taskId
                Limit         = $ArtifactLimit
                SpinnerStatus = $null
            }
            if ($IncludeArchived) { $artifactParams.IncludeArchived = $true }
            if ($LocalOnly) { $artifactParams.LocalOnly = $true }
            if ($Session) { $artifactParams.Session = $Session }
            $artifacts = @(Get-CodexArtifact @artifactParams)

            $approvalParams = @{
                Id            = $taskId
                Limit         = 40
                SpinnerStatus = $null
            }
            if ($IncludeArchived) { $approvalParams.IncludeArchived = $true }
            if ($LocalOnly) { $approvalParams.LocalOnly = $true }
            if ($Session) { $approvalParams.Session = $Session }
            $approvals = @(Get-CodexApproval @approvalParams)

            $sessionPath = Resolve-CodexTaskSessionPath -InputObject $task
            $latestText = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Text', 'text'))
            $latestSummary = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Summary', 'summary'))
            if ([string]::IsNullOrWhiteSpace($latestSummary)) {
                $latestSummary = if (-not [string]::IsNullOrWhiteSpace($latestText)) {
                    Get-CodexTaskReceiveSummary -Text $latestText
                }
                else {
                    [string](Get-CodexFirstValue -InputObject $task -PropertyName @('LastErrorMessage', 'lastErrorMessage'))
                }
            }

            $status = Get-CodexTaskEffectiveStatus -InputObject $task
            $eventKindCounts = @{}
            foreach ($group in @($events | Group-Object Kind)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$group.Name)) {
                    $eventKindCounts[[string]$group.Name] = $group.Count
                }
            }

            $artifactKindCounts = @{}
            foreach ($group in @($artifacts | Group-Object Kind)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$group.Name)) {
                    $artifactKindCounts[[string]$group.Name] = $group.Count
                }
            }

            $dashboardTasks.Add([PSCustomObject]@{
                    id               = $taskId
                    shortId          = Get-CodexCompactId -Id $taskId
                    name             = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Name', 'name', 'ThreadName', 'threadName'))
                    project          = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Project', 'project', 'ProjectName', 'projectName'))
                    path             = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Path', 'path', 'ProjectPath', 'projectPath'))
                    status           = if ([string]::IsNullOrWhiteSpace($status)) { 'active' } else { $status }
                    when             = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('When', 'when'))
                    timestamp        = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('LastActivityAt', 'lastActivityAt', 'Timestamp', 'timestamp'))
                    branch           = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Branch', 'branch', 'GitBranch', 'gitBranch'))
                    model            = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Model', 'model'))
                    source           = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('Source', 'source'))
                    workerProcessId  = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('WorkerProcessId', 'workerProcessId'))
                    lastErrorMessage = [string](Get-CodexFirstValue -InputObject $task -PropertyName @('LastErrorMessage', 'lastErrorMessage'))
                    sessionPath      = $sessionPath
                    latest           = [PSCustomObject]@{
                        status    = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Status', 'status'))
                        phase     = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Phase', 'phase'))
                        when      = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('When', 'when'))
                        timestamp = [string](Get-CodexFirstValue -InputObject $latestOutput -PropertyName @('Timestamp', 'timestamp'))
                        summary   = $latestSummary
                        text      = $latestText
                    }
                    eventCount       = $events.Count
                    eventKindCounts  = $eventKindCounts
                    artifactCount    = $artifacts.Count
                    artifactKinds    = $artifactKindCounts
                    approvalCount    = $approvals.Count
                    transcript       = @(
                        foreach ($item in $transcript) {
                            [PSCustomObject]@{
                                role      = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Role', 'role'))
                                itemType  = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('ItemType', 'itemType'))
                                phase     = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Phase', 'phase'))
                                when      = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('When', 'when'))
                                timestamp = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Timestamp', 'timestamp'))
                                text      = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Text', 'text'))
                            }
                        }
                    )
                    events           = @(
                        foreach ($event in $events) {
                            [PSCustomObject]@{
                                kind      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Kind', 'kind'))
                                type      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Type', 'type'))
                                name      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Name', 'name'))
                                phase     = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Phase', 'phase'))
                                when      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('When', 'when'))
                                timestamp = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Timestamp', 'timestamp'))
                                summary   = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Summary', 'summary'))
                                text      = [string](Get-CodexFirstValue -InputObject $event -PropertyName @('Text', 'text'))
                            }
                        }
                    )
                    artifacts        = @(
                        foreach ($artifact in $artifacts) {
                            [PSCustomObject]@{
                                kind      = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Kind', 'kind'))
                                name      = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Name', 'name'))
                                path      = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Path', 'path'))
                                when      = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('When', 'when'))
                                timestamp = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Timestamp', 'timestamp'))
                                summary   = [string](Get-CodexFirstValue -InputObject $artifact -PropertyName @('Summary', 'summary'))
                                size      = Get-CodexFirstValue -InputObject $artifact -PropertyName @('Size', 'size')
                                itemCount = Get-CodexFirstValue -InputObject $artifact -PropertyName @('ItemCount', 'itemCount')
                            }
                        }
                    )
                    approvals        = @(
                        foreach ($approval in $approvals) {
                            [PSCustomObject]@{
                                status       = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('Status', 'status'))
                                approvalType = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('ApprovalType', 'approvalType'))
                                target       = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('Target', 'target'))
                                when         = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('When', 'when'))
                                summary      = [string](Get-CodexFirstValue -InputObject $approval -PropertyName @('Summary', 'summary'))
                            }
                        }
                    )
                })
        }

        $tasks = @(
            $dashboardTasks |
            Sort-Object -Property @{ Expression = { $_.timestamp }; Descending = $true }, @{ Expression = { $_.name } }
        )

        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $OutputPath = New-CodexTaskDashboardHtmlPath -Task $tasks -Title $Title
        }
        else {
            $directory = Split-Path -Parent $OutputPath
            if ($directory -and -not (Test-Path -LiteralPath $directory)) {
                $null = New-Item -ItemType Directory -Path $directory -Force
            }
            $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
        }

        $dashboardData = New-CodexTaskDashboardData -Task $tasks -Title $Title
        $html = ConvertTo-CodexTaskDashboardHtml -Data $dashboardData -Title $Title
        Set-Content -LiteralPath $OutputPath -Value $html -Encoding utf8

        if (-not $NoOpen) {
            Start-Process -FilePath $OutputPath
        }

        if ($PassThru -or $NoOpen) {
            $page = [PSCustomObject]@{
                Path      = $OutputPath
                Title     = if ([string]::IsNullOrWhiteSpace($Title)) { $null } else { $Title }
                TaskCount = $tasks.Count
                Opened    = (-not $NoOpen)
            }
            $page.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTaskDashboardPage')
            return $page
        }
    }
}

function Set-CodexThread {
    <#
    .SYNOPSIS
        Updates local metadata for a Codex thread.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName = $true)][Alias('Id')][string]$ThreadId,
        [string]$Name,
        [string[]]$Tags,
        [string]$ProjectPath,
        [string]$ProjectName,
        [switch]$Pin,
        [switch]$Unpin,
        [switch]$Archive,
        [switch]$Restore
    )

    process {
        $catalog = Import-PSUnpluggedCatalog
        $properties = @{
            ThreadId = $ThreadId
        }

        if ($PSBoundParameters.ContainsKey('Name')) {
            $properties.Name = $Name
        }
        if ($PSBoundParameters.ContainsKey('Tags')) {
            $properties.Tags = @($Tags)
        }
        if ($Pin) {
            $properties.Pinned = $true
        }
        if ($Unpin) {
            $properties.Pinned = $false
        }
        if ($Archive) {
            $properties.Archived = $true
        }
        if ($Restore) {
            $properties.Archived = $false
        }

        if ($ProjectPath) {
            $identity = Get-CodexProjectIdentity -Path $ProjectPath -Name $ProjectName
            $projectRecord = Set-CodexCatalogProjectRecord -Catalog $catalog -ProjectIdentity $identity
            $properties.ProjectKey = $projectRecord.ProjectKey
            $properties.ProjectName = $projectRecord.Name
            $properties.Path = $projectRecord.Path
        }
        elseif ($ProjectName) {
            $properties.ProjectName = $ProjectName
        }

        if ($PSCmdlet.ShouldProcess($ThreadId, 'Update Codex thread metadata')) {
            $null = Set-CodexCatalogThreadRecord -Catalog $catalog -Properties $properties
            Export-PSUnpluggedCatalog -Catalog $catalog
            if ($Archive) { Set-PSUnpluggedThreadArchivedState -ThreadId $ThreadId -Archived $true }
            if ($Restore) { Set-PSUnpluggedThreadArchivedState -ThreadId $ThreadId -Archived $false }
        }

        return (Get-CodexThread -Id $ThreadId -IncludeArchived -LocalOnly | Select-Object -First 1)
    }
}

function Remove-CodexThread {
    <#
    .SYNOPSIS
        Archives a thread locally or removes its local metadata entry.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName = $true)][Alias('Id')][string]$ThreadId,
        [switch]$Purge
    )

    process {
        $catalog = Import-PSUnpluggedCatalog
        if ($Purge) {
            if ($PSCmdlet.ShouldProcess($ThreadId, 'Remove local Codex thread metadata')) {
                $normalizedThreadId = Get-CodexNormalizedThreadId -ThreadId $ThreadId
                $catalog.threads = @(
                    $catalog.threads | Where-Object {
                        (Get-CodexNormalizedThreadId -ThreadId ([string]$_.ThreadId)) -ne $normalizedThreadId
                    }
                )
                Export-PSUnpluggedCatalog -Catalog $catalog
                Set-PSUnpluggedThreadArchivedState -ThreadId $ThreadId -Archived $false
            }

            return
        }

        if ($PSCmdlet.ShouldProcess($ThreadId, 'Archive Codex thread metadata')) {
            $null = Set-CodexCatalogThreadRecord -Catalog $catalog -Properties @{
                ThreadId = $ThreadId
                Archived = $true
            }
            Export-PSUnpluggedCatalog -Catalog $catalog
            Set-PSUnpluggedThreadArchivedState -ThreadId $ThreadId -Archived $true
        }

        return (Get-CodexThread -Id $ThreadId -IncludeArchived -LocalOnly | Select-Object -First 1)
    }
}

function Enter-CodexThread {
    <#
    .SYNOPSIS
        Resumes a thread and either opens the interactive chat or sends a prompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('ThreadId')][string]$Id,
        [Alias('Path', 'Project')][string]$ProjectPath,
        [string]$Prompt,
        [string]$Model = 'gpt-5.2',
        [PSCustomObject]$Session
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
            $ProjectPath = (Get-Location).Path
        }

        $candidate = Get-CodexThread -Project $ProjectPath -IncludeArchived:$false -Limit 100 |
        Select-Object -First 1
        if (-not $candidate) {
            throw "No Codex thread found for project '$ProjectPath'."
        }

        $Id = $candidate.ThreadId
        if ($candidate.Path) {
            $ProjectPath = $candidate.Path
        }
        if ($candidate.Model) {
            $Model = $candidate.Model
        }
    }

    $threadRecord = Get-CodexThread -Id $Id -IncludeArchived -Limit 100 | Select-Object -First 1
    if ($threadRecord -and $threadRecord.Path) {
        $ProjectPath = $threadRecord.Path
    }

    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        $chatScript = Join-Path (Get-PSUnpluggedModuleRoot) 'Examples\Start-AgentChat.ps1'
        if (-not (Test-Path -LiteralPath $chatScript)) {
            throw "Interactive chat script not found at $chatScript"
        }

        $chatArgs = @{
            ThreadId = $Id
            Model    = $Model
        }
        if ($ProjectPath) {
            $chatArgs.Cwd = $ProjectPath
        }

        & $chatScript @chatArgs
        return
    }

    $createdSession = $false
    if (-not $Session) {
        $Session = Start-CodexSession
        $createdSession = $true
    }

    $turnModel = if ($PSBoundParameters.ContainsKey('Model')) {
        $Model
    }
    elseif ($threadRecord -and -not [string]::IsNullOrWhiteSpace([string]$threadRecord.Model)) {
        [string]$threadRecord.Model
    }
    else {
        $null
    }

    try {
        $thread = Resume-CodexThread -Session $Session -ThreadId $Id
        $turnParams = @{
            Session  = $Session
            ThreadId = $Id
            Text     = $Prompt
        }
        if (-not [string]::IsNullOrWhiteSpace($turnModel)) {
            $turnParams.Model = $turnModel
        }

        try {
            $turn = Invoke-CodexTurn @turnParams
        }
        catch {
            Update-CodexThreadTurnMetadata -ThreadId $Id -Status 'failed' -ErrorMessage ([string]$_.Exception.Message)
            throw
        }

        $turnStatus = ConvertTo-CodexTaskTerminalStatus -Status ([string](Get-CodexFirstValue -InputObject $turn -PropertyName @('Status', 'status')))
        $turnErrorMessage = Get-CodexTurnErrorMessage -TurnResult $turn

        Update-CodexThreadTurnMetadata -ThreadId $Id -Status $turnStatus -ErrorMessage $turnErrorMessage

        $catalog = Import-PSUnpluggedCatalog
        $properties = @{
            ThreadId         = $Id
            LastOpenedAt     = Get-PSUnpluggedUtcNowString
            LastActivityAt   = Get-PSUnpluggedUtcNowString
            LastTurnStatus   = $turnStatus
            LastErrorMessage = $turnErrorMessage
        }

        if ($ProjectPath) {
            $projectRecord = New-CodexProject -Path $ProjectPath
            $properties.ProjectKey = $projectRecord.ProjectKey
            $properties.ProjectName = $projectRecord.Name
            $properties.Path = $projectRecord.Path
        }

        $null = Set-CodexCatalogThreadRecord -Catalog $catalog -Properties $properties
        Export-PSUnpluggedCatalog -Catalog $catalog

        return [PSCustomObject]@{
            PSTypeName = 'PSUnplugged.CodexThreadTurn'
            ThreadId   = $Id
            Thread     = $thread
            Prompt     = $Prompt
            Result     = $turn
        }
    }
    finally {
        if ($createdSession) {
            Stop-CodexSession -Session $Session
        }
    }
}

function ConvertTo-CodexTaskOutput {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]$InputObject,
        [PSCustomObject]$Session
    )

    process {
        if ($null -eq $InputObject) {
            return
        }

        $taskId = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('TaskId', 'ThreadId', 'threadId'))
        if ([string]::IsNullOrWhiteSpace($taskId)) {
            return $InputObject
        }

        $null = $InputObject | Add-Member -NotePropertyName TaskId -NotePropertyValue $taskId -Force
        $sessionPath = Resolve-CodexTaskSessionPath -InputObject $InputObject
        $terminalInfo = Get-CodexTaskTerminalInfoFromSessionFile -Path $sessionPath
        $terminalErrorMessage = [string](Get-CodexFirstValue -InputObject $terminalInfo -PropertyName @('ErrorMessage'))
        if (-not [string]::IsNullOrWhiteSpace($terminalErrorMessage)) {
            $null = $InputObject | Add-Member -NotePropertyName LastErrorMessage -NotePropertyValue $terminalErrorMessage -Force
        }

        $terminalStatus = [string](Get-CodexFirstValue -InputObject $terminalInfo -PropertyName @('Status'))
        if (-not [string]::IsNullOrWhiteSpace($terminalStatus) -and $terminalStatus -in @('completed', 'failed', 'error', 'canceled', 'archived')) {
            $null = $InputObject | Add-Member -NotePropertyName LastTurnStatus -NotePropertyValue $terminalStatus -Force
        }

        $effectiveStatus = Get-CodexTaskEffectiveStatus -InputObject $InputObject
        if (-not [string]::IsNullOrWhiteSpace($effectiveStatus)) {
            $null = $InputObject | Add-Member -NotePropertyName Status -NotePropertyValue $effectiveStatus -Force
        }

        if (
            [string]::IsNullOrWhiteSpace($terminalStatus) -and
            $effectiveStatus -eq 'failed' -and
            (Test-CodexTaskWorkerCompletionApplies -InputObject $InputObject) -and
            (Test-CodexTaskWorkerCompleted -InputObject $InputObject)
        ) {
            $null = $InputObject | Add-Member -NotePropertyName LastErrorMessage -NotePropertyValue 'Task worker stopped before Codex reported task completion.' -Force
        }

        $diagnosticErrorMessage = Get-CodexTaskDiagnosticErrorMessage -Task $InputObject -Session $Session
        if (-not [string]::IsNullOrWhiteSpace($diagnosticErrorMessage)) {
            $null = $InputObject | Add-Member -NotePropertyName LastErrorMessage -NotePropertyValue $diagnosticErrorMessage -Force
        }

        if (-not ($InputObject.PSObject.TypeNames -contains 'PSUnplugged.CodexTask')) {
            $InputObject.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTask')
        }

        return $InputObject
    }
}

function ConvertTo-CodexTaskReceiveOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline = $true)]
        $InputObject
    )

    process {
        if ($null -eq $InputObject) {
            return
        }

        $taskId = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('TaskId', 'ThreadId', 'threadId'))
        if ([string]::IsNullOrWhiteSpace($taskId)) {
            return
        }

        $text = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Text', 'text'))
        $phase = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Phase', 'phase'))

        $output = [PSCustomObject]@{
            Id        = Get-CodexCompactId -Id $taskId
            TaskId    = $taskId
            ThreadId  = $taskId
            Name      = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('ThreadName', 'threadName', 'Name', 'name'))
            Project   = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Project', 'project'))
            Role      = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Role', 'role'))
            Phase     = $phase
            Status    = Get-CodexTaskReceiveStatus -Phase $phase
            When      = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('When', 'when'))
            Timestamp = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Timestamp', 'timestamp'))
            Summary   = Get-CodexTaskReceiveSummary -Text $text -Phase $phase
            Text      = $text
            RawItem   = $InputObject
        }

        $output.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTaskReceive')
        return $output
    }
}

function Get-CodexTaskReceiveStatus {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Phase
    )

    if ([string]::IsNullOrWhiteSpace($Phase)) {
        return 'received'
    }

    $normalized = $Phase.Trim().ToLowerInvariant()
    switch ($normalized) {
        'final_answer' { return 'completed' }
        'failed' { return 'failed' }
        'error' { return 'error' }
        'cancelled' { return 'canceled' }
        'canceled' { return 'canceled' }
        'starting' { return 'starting' }
        'active' { return 'active' }
        default { return $normalized }
    }
}

function Get-CodexTaskReceiveSummary {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$Phase,
        [int]$MaxLength = 260
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $status = Get-CodexTaskReceiveStatus -Phase $Phase
        return "No assistant text available. Status: $status."
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($rawLine in @($Text -split "`r?`n")) {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^```') {
            continue
        }

        $line = $line -replace '^\s{0,3}#{1,6}\s*', ''
        $line = $line -replace '^\s*[-*+]\s+', ''
        $line = $line -replace '^\s*\d+\.\s+', ''
        $line = $line -replace '\s+', ' '
        $line = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $lines.Add($line)
        }

        if ($lines.Count -ge 3) {
            break
        }
    }

    $summary = if ($lines.Count -gt 0) { $lines -join ' | ' } else { ($Text -replace '\s+', ' ').Trim() }
    if ($summary.Length -gt $MaxLength) {
        return ($summary.Substring(0, [Math]::Max(0, $MaxLength - 1)).TrimEnd() + '…')
    }

    return $summary
}

function Resolve-CodexTaskIdentifierText {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $null
    }

    if ($Id -match '^(urn:uuid:)?[0-9a-fA-F-]{32,36}$') {
        return $Id
    }

    $normalizedRequestedId = Get-CodexNormalizedThreadId -ThreadId $Id
    $catalog = Import-PSUnpluggedCatalog
    $catalogMatch = @(
        @($catalog.threads) |
        Where-Object {
            $candidateId = Get-CodexNormalizedThreadId -ThreadId ([string]$_.ThreadId)
            -not [string]::IsNullOrWhiteSpace($candidateId) -and
            $candidateId.StartsWith($normalizedRequestedId, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Sort-Object -Property LastActivityAt -Descending
    ) | Select-Object -First 1
    if ($catalogMatch) {
        return [string]$catalogMatch.ThreadId
    }

    $workerRoot = Join-Path (Get-PSUnpluggedDataRoot) 'task-workers'
    if (Test-Path -LiteralPath $workerRoot) {
        foreach ($readyFile in @(Get-ChildItem -LiteralPath $workerRoot -Filter '*.ready.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            $readyPayload = $null
            try {
                $readyPayload = Get-Content -LiteralPath $readyFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                continue
            }

            $readyThreadId = [string](Get-CodexFirstValue -InputObject $readyPayload -PropertyName @('ThreadId', 'threadId'))
            $normalizedReadyThreadId = Get-CodexNormalizedThreadId -ThreadId $readyThreadId
            if (
                -not [string]::IsNullOrWhiteSpace($normalizedReadyThreadId) -and
                $normalizedReadyThreadId.StartsWith($normalizedRequestedId, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                return $readyThreadId
            }
        }
    }

    $sessionPath = Resolve-CodexSessionPath -ThreadId $Id
    if (-not [string]::IsNullOrWhiteSpace($sessionPath)) {
        $sessionName = [System.IO.Path]::GetFileNameWithoutExtension($sessionPath)
        $sessionMatch = [regex]::Match($sessionName, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
        if ($sessionMatch.Success) {
            return $sessionMatch.Groups[1].Value
        }
    }

    return $Id
}

function Resolve-CodexTaskIdentifier {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string]) {
        return (Resolve-CodexTaskIdentifierText -Id ([string]$InputObject))
    }

    $explicitTaskId = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('TaskId', 'ThreadId', 'threadId'))
    if (-not [string]::IsNullOrWhiteSpace($explicitTaskId)) {
        return $explicitTaskId
    }

    $fallbackId = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Id', 'id'))
    if ($fallbackId -match '^(urn:uuid:)?[0-9a-fA-F-]{32,36}$') {
        return $fallbackId
    }

    $readyPayload = Get-CodexTaskReadyPayload -InputObject $InputObject
    $readyTaskId = [string](Get-CodexFirstValue -InputObject $readyPayload -PropertyName @('ThreadId', 'threadId'))
    if (-not [string]::IsNullOrWhiteSpace($readyTaskId)) {
        return $readyTaskId
    }

    return $null
}

function Get-CodexTaskReadyFilePath {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    return [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('ReadyFilePath', 'readyFilePath'))
}

function Get-CodexTaskReadyPayload {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    $readyFilePath = Get-CodexTaskReadyFilePath -InputObject $InputObject
    if ([string]::IsNullOrWhiteSpace($readyFilePath) -or -not (Test-Path -LiteralPath $readyFilePath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $readyFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Test-CodexTaskHandleInput {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject -or $InputObject -is [string] -or -not $InputObject.PSObject) {
        return $false
    }

    foreach ($typeName in @('PSUnplugged.CodexTask', 'PSUnplugged.CodexTaskTurn', 'PSUnplugged.CodexTaskReceive')) {
        if ($InputObject.PSObject.TypeNames -contains $typeName) {
            return $true
        }
    }

    foreach ($propertyName in @('TaskId', 'ThreadId', 'ReadyFilePath', 'WorkerProcessId', 'WorkerStdOutPath', 'WorkerStdErrPath')) {
        if ($InputObject.PSObject.Properties[$propertyName]) {
            return $true
        }
    }

    return $false
}

function Get-CodexTurnErrorMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]$TurnResult
    )

    if ($null -eq $TurnResult) {
        return $null
    }

    $turn = Get-CodexFirstValue -InputObject $TurnResult -PropertyName @('Turn', 'turn')
    $turnError = Get-CodexFirstValue -InputObject $turn -PropertyName @('error', 'Error')
    foreach ($value in @(
            [string](Get-CodexFirstValue -InputObject $turnError -PropertyName @('message', 'Message')),
            [string](Get-CodexFirstValue -InputObject $TurnResult -PropertyName @('ErrorMessage', 'errorMessage'))
        )) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    foreach ($event in @(Get-CodexFirstValue -InputObject $TurnResult -PropertyName @('Events', 'events'))) {
        if ($null -eq $event -or $event.method -ne 'error') {
            continue
        }

        $eventParams = Get-CodexFirstValue -InputObject $event -PropertyName @('params', 'Params')
        $eventError = Get-CodexFirstValue -InputObject $eventParams -PropertyName @('error', 'Error')
        $message = [string](Get-CodexFirstValue -InputObject $eventError -PropertyName @('message', 'Message'))
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            return $message
        }
    }

    return $null
}

function Update-CodexThreadTurnMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ThreadId,
        [string]$Status,
        [string]$ErrorMessage
    )

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return
    }

    $properties = @{
        ThreadId       = $ThreadId
        LastOpenedAt   = Get-PSUnpluggedUtcNowString
        LastActivityAt = Get-PSUnpluggedUtcNowString
    }

    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        $properties.LastTurnStatus = $Status
    }

    if ($PSBoundParameters.ContainsKey('ErrorMessage')) {
        $properties.LastErrorMessage = $ErrorMessage
    }

    $catalog = Import-PSUnpluggedCatalog
    $null = Set-CodexCatalogThreadRecord -Catalog $catalog -Properties $properties
    Export-PSUnpluggedCatalog -Catalog $catalog
}

function Get-CodexModelLookup {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Session
    )

    if (
        $script:CodexModelLookupCache -and
        $script:CodexModelLookupCache.RetrievedAt -and
        ((Get-Date) - $script:CodexModelLookupCache.RetrievedAt).TotalMinutes -lt 5
    ) {
        return $script:CodexModelLookupCache.Models
    }

    $createdSession = $false
    $effectiveSession = $Session
    try {
        if (-not $effectiveSession) {
            $effectiveSession = Start-CodexSession
            $createdSession = $true
        }

        $modelsResult = Get-CodexModels -Session $effectiveSession
        $lookup = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $modelItems = @()
        foreach ($propertyName in @('data', 'Data', 'items', 'Items', 'results', 'Results')) {
            $property = $modelsResult.PSObject.Properties[$propertyName]
            if ($property) {
                $modelItems = @($property.Value)
                break
            }
        }

        if (
            $modelItems.Count -eq 1 -and
            $null -ne $modelItems[0] -and
            $modelItems[0] -is [System.Collections.IEnumerable] -and
            -not ($modelItems[0] -is [string])
        ) {
            $modelItems = @($modelItems[0])
        }

        foreach ($modelItem in $modelItems) {
            foreach ($value in @(
                    [string](Get-CodexFirstValue -InputObject $modelItem -PropertyName @('id', 'Id')),
                    [string](Get-CodexFirstValue -InputObject $modelItem -PropertyName @('model', 'Model'))
                )) {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $null = $lookup.Add($value)
                }
            }
        }

        $script:CodexModelLookupCache = [PSCustomObject]@{
            RetrievedAt = Get-Date
            Models      = $lookup
        }
        return $lookup
    }
    catch {
        return $null
    }
    finally {
        if ($createdSession -and $effectiveSession) {
            Stop-CodexSession -Session $effectiveSession
        }
    }
}

function Resolve-CodexRequestedModel {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Model,
        [PSCustomObject]$Session
    )

    if ([string]::IsNullOrWhiteSpace($Model)) {
        return $Model
    }

    $requestedModel = $Model.Trim()
    $modelLookup = Get-CodexModelLookup -Session $Session
    if (-not $modelLookup -or $modelLookup.Contains($requestedModel)) {
        return $requestedModel
    }

    $candidateModels = [System.Collections.Generic.List[string]]::new()
    if ($requestedModel -match '^[^:]+:(.+)$') {
        $candidateModels.Add($matches[1])
    }

    foreach ($candidateModel in @($candidateModels | Select-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($candidateModel) -and $modelLookup.Contains($candidateModel)) {
            return $candidateModel
        }
    }

    return $requestedModel
}

function Get-CodexTaskDiagnosticErrorMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]$Task,
        [PSCustomObject]$Session
    )

    if ($null -eq $Task) {
        return $null
    }

    $errorMessage = [string](Get-CodexFirstValue -InputObject $Task -PropertyName @('LastErrorMessage', 'lastErrorMessage'))
    if ([string]::IsNullOrWhiteSpace($errorMessage)) {
        return $null
    }

    if ($errorMessage -ne 'Task completed with no assistant output.') {
        return $errorMessage
    }

    $model = [string](Get-CodexFirstValue -InputObject $Task -PropertyName @('Model', 'model'))
    $modelLookup = $null
    if (-not [string]::IsNullOrWhiteSpace($model)) {
        $modelLookup = Get-CodexModelLookup -Session $Session
        if ($modelLookup -and -not $modelLookup.Contains($model)) {
            $resolvedModel = Resolve-CodexRequestedModel -Session $Session -Model $model
            if (
                -not [string]::IsNullOrWhiteSpace($resolvedModel) -and
                $resolvedModel -ne $model -and
                $modelLookup.Contains($resolvedModel)
            ) {
                return "Model '$model' is not supported by the current Codex runtime. Use '$resolvedModel' instead."
            }

            $sampleModels = @($modelLookup | Sort-Object | Select-Object -First 5)
            $availableText = if ($sampleModels.Count -gt 0) {
                ' Available models: ' + ($sampleModels -join ', ') + '.'
            }
            else {
                ''
            }

            return "Model '$model' is not supported by the current Codex runtime.$availableText"
        }
    }

    $taskId = Resolve-CodexTaskIdentifier -InputObject $Task
    if (-not [string]::IsNullOrWhiteSpace($taskId)) {
        $createdSession = $false
        $effectiveSession = $Session
        try {
            if (-not $effectiveSession) {
                $effectiveSession = Start-CodexSession
                $createdSession = $true
            }

            $threadResult = Send-CodexRequest -Session $effectiveSession -Method 'thread/read' -Params @{
                threadId     = $taskId
                includeTurns = $true
            }
            $turns = @($threadResult.thread.turns)
            $turn = if ($turns.Count -gt 0) { $turns[-1] } else { $null }
            if ($turn) {
                $turnStatus = [string](Get-CodexFirstValue -InputObject $turn -PropertyName @('status', 'Status'))
                $turnError = Get-CodexFirstValue -InputObject $turn -PropertyName @('error', 'Error')
                $turnErrorMessage = [string](Get-CodexFirstValue -InputObject $turnError -PropertyName @('message', 'Message'))
                $itemTypes = @($turn.items | ForEach-Object { [string](Get-CodexFirstValue -InputObject $_ -PropertyName @('type', 'Type')) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

                if (-not [string]::IsNullOrWhiteSpace($turnErrorMessage)) {
                    return $turnErrorMessage
                }

                if (-not [string]::IsNullOrWhiteSpace($turnStatus) -or $itemTypes.Count -gt 0) {
                    $parts = [System.Collections.Generic.List[string]]::new()
                    $parts.Add('Task completed with no assistant output.')
                    if (-not [string]::IsNullOrWhiteSpace($turnStatus)) {
                        $parts.Add("Turn status: $turnStatus.")
                    }
                    else {
                        $parts.Add('Turn status: unknown.')
                    }

                    if ($itemTypes.Count -gt 0) {
                        $parts.Add('Recorded items: ' + ($itemTypes -join ', ') + '.')
                    }
                    else {
                        $parts.Add('Recorded items: none.')
                    }

                    $parts.Add('Codex did not report an explicit error.')
                    return ($parts -join ' ')
                }
            }
        }
        catch {
        }
        finally {
            if ($createdSession -and $effectiveSession) {
                Stop-CodexSession -Session $effectiveSession
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($model)) {
        return $errorMessage
    }

    return $errorMessage
}

function New-CodexTaskFallbackTranscriptItem {
    [CmdletBinding()]
    param(
        [AllowNull()]$Task,
        [PSCustomObject]$Session
    )

    if ($null -eq $Task) {
        return $null
    }

    $taskId = Resolve-CodexTaskIdentifier -InputObject $Task
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        $taskId = [string](Get-CodexFirstValue -InputObject $Task -PropertyName @('Id', 'id'))
        if ([string]::IsNullOrWhiteSpace($taskId)) {
            return $null
        }
    }

    $status = ConvertTo-CodexTaskTerminalStatus -Status ([string](Get-CodexFirstValue -InputObject $Task -PropertyName @('LastTurnStatus', 'lastTurnStatus', 'Status', 'status')))
    $errorMessage = Get-CodexTaskDiagnosticErrorMessage -Task $Task -Session $Session

    $text = $null
    $phase = $null
    if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {
        $text = $errorMessage
        $phase = if ($status -in @('failed', 'error', 'canceled')) { $status } else { 'error' }
    }
    elseif ($status -in @('failed', 'error', 'canceled')) {
        $text = "Task $status."
        $phase = $status
    }
    elseif ($status -in @('starting', 'active')) {
        $parts = [System.Collections.Generic.List[string]]::new()
        $prompt = [string](Get-CodexFirstValue -InputObject $Task -PropertyName @('Prompt', 'prompt', 'Name', 'name', 'ThreadName', 'threadName'))
        $project = [string](Get-CodexFirstValue -InputObject $Task -PropertyName @('Project', 'project'))
        $path = [string](Get-CodexFirstValue -InputObject $Task -PropertyName @('Path', 'path', 'ProjectPath', 'projectPath'))

        if (-not [string]::IsNullOrWhiteSpace($prompt)) {
            $parts.Add("Waiting for first assistant output for: $prompt")
        }
        else {
            $parts.Add('Waiting for first assistant output.')
        }

        if (-not [string]::IsNullOrWhiteSpace($project)) {
            $parts.Add("Project: $project.")
        }
        elseif (-not [string]::IsNullOrWhiteSpace($path)) {
            $parts.Add("Path: $path.")
        }

        $workerProcessId = [string](Get-CodexFirstValue -InputObject $Task -PropertyName @('WorkerProcessId', 'workerProcessId'))
        if (-not [string]::IsNullOrWhiteSpace($workerProcessId)) {
            $parts.Add("Worker process id: $workerProcessId.")
        }

        $readyFilePath = [string](Get-CodexTaskReadyFilePath -InputObject $Task)
        if (-not [string]::IsNullOrWhiteSpace($readyFilePath)) {
            if (Test-Path -LiteralPath $readyFilePath) {
                $parts.Add('The task worker has reported a Codex thread id.')
            }
            else {
                $parts.Add('The task worker has not reported a Codex thread id yet.')
            }
        }
        elseif ($status -eq 'active') {
            $parts.Add('The Codex thread is active.')
        }

        $stderrPath = [string](Get-CodexFirstValue -InputObject $Task -PropertyName @('WorkerStdErrPath', 'workerStdErrPath'))
        if (-not [string]::IsNullOrWhiteSpace($stderrPath) -and (Test-Path -LiteralPath $stderrPath)) {
            try {
                $stderrTail = @(
                    Get-Content -LiteralPath $stderrPath -Tail 5 -ErrorAction Stop |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                )
                if ($stderrTail.Count -gt 0) {
                    $parts.Add('Recent worker stderr: ' + (($stderrTail -join ' ') -replace '\s+', ' ').Trim())
                }
            }
            catch {
            }
        }

        $text = ($parts -join ' ')
        $phase = $status
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $timestamp = ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $Task -PropertyName @('LastActivityAt', 'lastActivityAt', 'Timestamp', 'timestamp'))
    return (New-CodexTranscriptItem -ThreadId $taskId -ThreadName ([string](Get-CodexFirstValue -InputObject $Task -PropertyName @('Name', 'name', 'ThreadName', 'threadName'))) -Project ([string](Get-CodexFirstValue -InputObject $Task -PropertyName @('Project', 'project'))) -TurnId $null -Index ([int]::MaxValue) -Role 'assistant' -ItemType 'agentMessage' -Phase $phase -Text $text -Timestamp $timestamp)
}

function Test-CodexEmptyRolloutError {
    [CmdletBinding()]
    param(
        [AllowNull()]$ErrorRecord
    )

    if ($null -eq $ErrorRecord) {
        return $false
    }

    $message = [string]$ErrorRecord
    if ([string]::IsNullOrWhiteSpace($message) -and $ErrorRecord.Exception) {
        $message = [string]$ErrorRecord.Exception.Message
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        return $false
    }

    return (
        $message -like '*failed to load rollout*' -and
        $message -like '*rollout*is empty*'
    )
}

function Test-CodexTranscriptHasAssistantOutput {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Transcript
    )

    foreach ($item in @($Transcript)) {
        $role = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Role', 'role'))
        $text = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Text', 'text'))
        if ($role -eq 'assistant' -and -not [string]::IsNullOrWhiteSpace($text)) {
            return $true
        }
    }

    return $false
}

function Test-CodexTaskWorkerCompleted {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) {
        return $false
    }

    $stdoutPath = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('WorkerStdOutPath', 'workerStdOutPath'))
    if (-not [string]::IsNullOrWhiteSpace($stdoutPath) -and (Test-Path -LiteralPath $stdoutPath)) {
        try {
            if (Select-String -Path $stdoutPath -Pattern 'WORKER_END' -Quiet -ErrorAction Stop) {
                return $true
            }
        }
        catch {
        }
    }

    $threadId = Resolve-CodexTaskIdentifier -InputObject $InputObject
    if (-not [string]::IsNullOrWhiteSpace($threadId)) {
        $workerRoot = Join-Path (Get-PSUnpluggedDataRoot) 'task-workers'
        foreach ($readyFile in @(Get-ChildItem -LiteralPath $workerRoot -Filter '*.ready.json' -File -ErrorAction SilentlyContinue)) {
            $readyPayload = $null
            try {
                $readyPayload = Get-Content -LiteralPath $readyFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                continue
            }

            $readyThreadId = [string](Get-CodexFirstValue -InputObject $readyPayload -PropertyName @('ThreadId', 'threadId'))
            if (
                (Get-CodexNormalizedThreadId -ThreadId $readyThreadId) -ne
                (Get-CodexNormalizedThreadId -ThreadId $threadId)
            ) {
                continue
            }

            $workerId = [System.IO.Path]::GetFileNameWithoutExtension($readyFile.BaseName)
            $stdoutPath = Join-Path $workerRoot "$workerId.stdout.log"
            if (-not [string]::IsNullOrWhiteSpace($stdoutPath) -and (Test-Path -LiteralPath $stdoutPath)) {
                try {
                    if (Select-String -Path $stdoutPath -Pattern 'WORKER_END' -Quiet -ErrorAction Stop) {
                        return $true
                    }
                }
                catch {
                }
            }

            $paramsPath = Join-Path $workerRoot "$workerId.params.json"
            if (Test-Path -LiteralPath $paramsPath) {
                try {
                    $paramsPayload = Get-Content -LiteralPath $paramsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $workerProcessId = Get-CodexFirstValue -InputObject $paramsPayload -PropertyName @('WorkerProcessId', 'workerProcessId')
                    $workerProcessIdValue = 0
                    if (
                        $null -ne $workerProcessId -and
                        [int]::TryParse([string]$workerProcessId, [ref]$workerProcessIdValue) -and
                        $null -eq (Get-Process -Id $workerProcessIdValue -ErrorAction Ignore)
                    ) {
                        return $true
                    }
                }
                catch {
                }
            }
        }
    }

    $processId = Get-CodexFirstValue -InputObject $InputObject -PropertyName @('WorkerProcessId', 'workerProcessId')
    if ($null -eq $processId) {
        return $false
    }

    $processIdText = [string]$processId
    if ([string]::IsNullOrWhiteSpace($processIdText)) {
        return $false
    }

    $processIdValue = 0
    if (-not [int]::TryParse($processIdText, [ref]$processIdValue)) {
        return $false
    }

    return ($null -eq (Get-Process -Id $processIdValue -ErrorAction Ignore))
}

function Test-CodexTaskWorkerCompletionApplies {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) {
        return $false
    }

    foreach ($propertyName in @(
            'WorkerProcessId', 'workerProcessId',
            'WorkerStdOutPath', 'workerStdOutPath',
            'WorkerStdErrPath', 'workerStdErrPath',
            'ReadyFilePath', 'readyFilePath'
        )) {
        $value = Get-CodexFirstValue -InputObject $InputObject -PropertyName @($propertyName)
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return $true
        }
    }

    return $false
}

function Test-CodexTaskCompletion {
    [CmdletBinding()]
    param(
        [AllowNull()]$Task,
        [AllowNull()][object[]]$Transcript
    )

    if ($null -eq $Task) {
        return $false
    }

    $status = [string](Get-CodexFirstValue -InputObject $Task -PropertyName @('Status', 'status'))
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        $normalizedStatus = $status.Trim().ToLowerInvariant()
        if ($normalizedStatus -in @('completed', 'complete', 'failed', 'error', 'cancelled', 'canceled', 'archived')) {
            return $true
        }
    }

    $terminalTranscriptItem = @(
        @($Transcript) |
        Where-Object {
            $phase = [string](Get-CodexFirstValue -InputObject $_ -PropertyName @('Phase', 'phase'))
            if ([string]::IsNullOrWhiteSpace($phase)) {
                return $false
            }

            $phase.Trim().ToLowerInvariant() -in @('final_answer', 'completed', 'failed', 'error', 'cancelled', 'canceled')
        } |
        Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } }
    ) | Select-Object -Last 1

    return ($null -ne $terminalTranscriptItem)
}

function ConvertTo-CodexTaskTerminalStatus {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Status
    )

    if ([string]::IsNullOrWhiteSpace($Status)) {
        return $null
    }

    switch ($Status.Trim().ToLowerInvariant()) {
        'final_answer' { return 'completed' }
        'complete' { return 'completed' }
        'completed' { return 'completed' }
        'failed' { return 'failed' }
        'error' { return 'error' }
        'cancelled' { return 'canceled' }
        'canceled' { return 'canceled' }
        'archived' { return 'archived' }
        default { return $Status.Trim().ToLowerInvariant() }
    }
}

function Resolve-CodexTaskSessionPath {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $hintPath = [string](Get-CodexFirstValue -InputObject (Get-CodexFirstValue -InputObject $InputObject -PropertyName @('RawThread', 'rawThread')) -PropertyName @('path', 'Path'))
    if (-not [string]::IsNullOrWhiteSpace($hintPath) -and (Test-Path -LiteralPath $hintPath)) {
        $taskId = Resolve-CodexTaskIdentifier -InputObject $InputObject
        if (-not [string]::IsNullOrWhiteSpace($taskId)) {
            $script:CodexTaskSessionPathCache[$taskId] = $hintPath
        }

        return $hintPath
    }

    $taskId = Resolve-CodexTaskIdentifier -InputObject $InputObject
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        return $null
    }

    if ($script:CodexTaskSessionPathCache.ContainsKey($taskId)) {
        $cachedPath = [string]$script:CodexTaskSessionPathCache[$taskId]
        if (-not [string]::IsNullOrWhiteSpace($cachedPath) -and (Test-Path -LiteralPath $cachedPath)) {
            return $cachedPath
        }

        $null = $script:CodexTaskSessionPathCache.Remove($taskId)
    }

    $resolvedPath = Resolve-CodexSessionPath -ThreadId $taskId
    if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path -LiteralPath $resolvedPath)) {
        $script:CodexTaskSessionPathCache[$taskId] = $resolvedPath
        return $resolvedPath
    }

    return $null
}

function Get-CodexTaskTerminalStatusFromSessionFile {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Path
    )

    return [string](Get-CodexFirstValue -InputObject (Get-CodexTaskTerminalInfoFromSessionFile -Path $Path) -PropertyName @('Status'))
}

function Get-CodexTaskTerminalInfoFromSessionFile {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Path
    )

    $emptyResult = [PSCustomObject]@{
        Status       = $null
        ErrorMessage = $null
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $emptyResult
    }

    $fileInfo = Get-Item -LiteralPath $Path -ErrorAction Ignore
    if ($null -eq $fileInfo) {
        return $emptyResult
    }

    $cacheKey = '{0}|{1}|{2}' -f $fileInfo.FullName, $fileInfo.Length, $fileInfo.LastWriteTimeUtc.Ticks
    if ($script:CodexTaskTerminalStatusCache.ContainsKey($cacheKey)) {
        return $script:CodexTaskTerminalStatusCache[$cacheKey]
    }

    $taskCompleted = $false
    $assistantOutputSeen = $false
    foreach ($line in @(Get-Content -LiteralPath $fileInfo.FullName -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        if ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'task_complete') {
            $taskCompleted = $true
        }
        elseif ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'agent_message') {
            $message = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('message', 'Message'))
            if (-not [string]::IsNullOrWhiteSpace($message)) {
                $assistantOutputSeen = $true
            }
        }
        elseif ($entry.type -eq 'response_item' -and $entry.payload.type -eq 'message' -and $entry.payload.role -eq 'assistant') {
            $message = Get-CodexTranscriptText -InputObject $entry.payload
            if (-not [string]::IsNullOrWhiteSpace($message)) {
                $assistantOutputSeen = $true
            }
        }
    }

    $terminalItem = @(
        @(ConvertTo-CodexTranscriptItemsFromSessionFile -Path $fileInfo.FullName) |
        Where-Object {
            $phase = [string](Get-CodexFirstValue -InputObject $_ -PropertyName @('Phase', 'phase'))
            if ([string]::IsNullOrWhiteSpace($phase)) {
                return $false
            }

            $phase.Trim().ToLowerInvariant() -in @('final_answer', 'failed', 'error', 'cancelled', 'canceled')
        } |
        Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } }
    ) | Select-Object -Last 1

    $result = $emptyResult
    if ($terminalItem) {
        $terminalStatus = ConvertTo-CodexTaskTerminalStatus -Status ([string](Get-CodexFirstValue -InputObject $terminalItem -PropertyName @('Phase', 'phase')))
        $terminalText = [string](Get-CodexFirstValue -InputObject $terminalItem -PropertyName @('Text', 'text'))
        $result = [PSCustomObject]@{
            Status       = $terminalStatus
            ErrorMessage = if ($terminalStatus -in @('failed', 'error', 'canceled')) { $terminalText } else { $null }
        }
    }
    elseif ($taskCompleted -and -not $assistantOutputSeen) {
        $result = [PSCustomObject]@{
            Status       = 'failed'
            ErrorMessage = 'Task completed with no assistant output.'
        }
    }
    elseif ($taskCompleted) {
        $result = [PSCustomObject]@{
            Status       = 'completed'
            ErrorMessage = $null
        }
    }

    if ($script:CodexTaskTerminalStatusCache.Count -ge 512) {
        $script:CodexTaskTerminalStatusCache = @{}
    }

    $script:CodexTaskTerminalStatusCache[$cacheKey] = $result
    return $result
}

function Get-CodexTaskEffectiveStatus {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $isArchived = [bool](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Archived', 'archived'))
    if ($isArchived) {
        return 'archived'
    }

    $lastTurnStatus = ConvertTo-CodexTaskTerminalStatus -Status ([string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('LastTurnStatus', 'lastTurnStatus')))
    if ($lastTurnStatus -in @('completed', 'failed', 'error', 'canceled', 'archived')) {
        return $lastTurnStatus
    }

    $status = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Status', 'status'))
    $normalizedStatus = ConvertTo-CodexTaskTerminalStatus -Status $status
    if ($normalizedStatus -in @('completed', 'failed', 'error', 'canceled', 'archived')) {
        return $normalizedStatus
    }

    $sessionPath = Resolve-CodexTaskSessionPath -InputObject $InputObject
    $terminalStatus = Get-CodexTaskTerminalStatusFromSessionFile -Path $sessionPath
    if (-not [string]::IsNullOrWhiteSpace($terminalStatus)) {
        return $terminalStatus
    }

    if (
        (Test-CodexTaskWorkerCompletionApplies -InputObject $InputObject) -and
        (Test-CodexTaskWorkerCompleted -InputObject $InputObject)
    ) {
        return 'failed'
    }

    if ($normalizedStatus -eq 'notloaded') {
        return 'active'
    }

    if (-not [string]::IsNullOrWhiteSpace($status)) {
        return $status.Trim()
    }

    return 'active'
}

function Get-CodexTaskTranscriptItemKey {
    [CmdletBinding()]
    param(
        [AllowNull()]$Item
    )

    if ($null -eq $Item) {
        return $null
    }

    $threadId = [string](Get-CodexFirstValue -InputObject $Item -PropertyName @('ThreadId', 'threadId'))
    $turnId = [string](Get-CodexFirstValue -InputObject $Item -PropertyName @('TurnId', 'turnId'))
    $index = [string](Get-CodexFirstValue -InputObject $Item -PropertyName @('Index', 'index'))
    $role = [string](Get-CodexFirstValue -InputObject $Item -PropertyName @('Role', 'role'))
    $phase = [string](Get-CodexFirstValue -InputObject $Item -PropertyName @('Phase', 'phase'))
    $timestamp = [string](Get-CodexFirstValue -InputObject $Item -PropertyName @('Timestamp', 'timestamp'))
    $text = [string](Get-CodexFirstValue -InputObject $Item -PropertyName @('Text', 'text'))

    return '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $threadId, $turnId, $index, $role, $phase, $timestamp, $text
}

function Write-CodexTaskTailItems {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$TranscriptItem
    )

    $lastRenderedByThread = @{}

    foreach ($item in @($TranscriptItem)) {
        if ($null -eq $item) {
            continue
        }

        $threadId = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('ThreadId', 'threadId'))
        $text = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Text', 'text'))
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $role = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Role', 'role'))
        $phase = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Phase', 'phase'))

        if (-not [string]::IsNullOrWhiteSpace($threadId) -and $lastRenderedByThread.ContainsKey($threadId)) {
            $previous = $lastRenderedByThread[$threadId]
            if (
                $role -eq 'assistant' -and
                $previous.Role -eq 'assistant' -and
                $previous.Text -eq $text
            ) {
                continue
            }
        }

        $when = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('When', 'when'))
        $labelParts = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($when)) {
            $labelParts.Add($when)
        }

        switch ($phase) {
            'reasoning' {
                $labelParts.Add('thinking')
                break
            }
            'tool' {
                $labelParts.Add('tool')
                break
            }
            'command' {
                $labelParts.Add('command')
                break
            }
            default {
                foreach ($part in @($role, $phase)) {
                    if (-not [string]::IsNullOrWhiteSpace($part)) {
                        $labelParts.Add($part)
                    }
                }
                break
            }
        }

        $label = if ($labelParts.Count -gt 0) { '[' + ($labelParts -join ' | ') + ']' } else { '[task]' }

        Write-Host "$label $text" -ForegroundColor DarkGray
        if (-not [string]::IsNullOrWhiteSpace($threadId)) {
            $lastRenderedByThread[$threadId] = @{
                Role = $role
                Text = $text
            }
        }
    }
}

function Write-PSUnpluggedTaskReadyFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ThreadId,
        [string]$ProjectPath
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    $payload = [ordered]@{
        ThreadId    = $ThreadId
        ProjectPath = $ProjectPath
        ReadyAt     = (Get-Date).ToString('o')
    }

    Set-Content -LiteralPath $Path -Value ($payload | ConvertTo-Json -Depth 4 -Compress) -Encoding utf8
}

function Start-PSUnpluggedTaskWorkerProcess {
    [CmdletBinding()]
    param(
        [string]$Model = 'gpt-5.2',
        [string]$Cwd,
        [string]$ApprovalPolicy = 'never',
        [string]$SandboxType = 'workspace-write',
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Name,
        [string[]]$Tags,
        [int]$TurnTimeoutSec = 900,
        [switch]$CreateCwd
    )

    $effectiveCwd = $Cwd
    if (-not [string]::IsNullOrWhiteSpace($effectiveCwd)) {
        $effectiveCwd = Resolve-CodexProjectLocation -Path $effectiveCwd -AllowMissing:$CreateCwd
        if (-not $CreateCwd -and -not (Test-Path -LiteralPath $effectiveCwd)) {
            throw "Path not found: $Cwd"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $candidate = ($Prompt -replace '\s+', ' ').Trim()
        if ($candidate.Length -gt 120) {
            $candidate = $candidate.Substring(0, 120).Trim()
        }
        $Name = $candidate
    }

    $modulePath = Join-Path (Get-PSUnpluggedModuleRoot) 'PSUnplugged.psd1'
    $workerRoot = Join-Path (Get-PSUnpluggedDataRoot) 'task-workers'
    if (-not (Test-Path -LiteralPath $workerRoot)) {
        $null = New-Item -ItemType Directory -Path $workerRoot -Force
    }

    $workerId = [guid]::NewGuid().ToString('N')
    $paramsPath = Join-Path $workerRoot "$workerId.params.json"
    $readyPath = Join-Path $workerRoot "$workerId.ready.json"
    $scriptPath = Join-Path $workerRoot "$workerId.worker.ps1"
    $stdoutPath = Join-Path $workerRoot "$workerId.stdout.log"
    $stderrPath = Join-Path $workerRoot "$workerId.stderr.log"

    $payload = [ordered]@{
        WorkerId       = $workerId
        Model          = $Model
        Cwd            = $effectiveCwd
        ApprovalPolicy = $ApprovalPolicy
        SandboxType    = $SandboxType
        Prompt         = $Prompt
        Name           = $Name
        Tags           = @($Tags)
        TurnTimeoutSec = $TurnTimeoutSec
        CreateCwd      = [bool]$CreateCwd
        ReadyFilePath  = $readyPath
    }
    Set-Content -LiteralPath $paramsPath -Value ($payload | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8

    $runner = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    }
    elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
        (Get-Command powershell -ErrorAction SilentlyContinue).Source
    }
    else {
        throw 'Unable to find pwsh or powershell to launch the Codex task worker process.'
    }

    $escapedModulePath = $modulePath.Replace("'", "''")
    $escapedParamsPath = $paramsPath.Replace("'", "''")
    $workerScript = @"
Import-Module -Name '$escapedModulePath' -Force
`$payload = Get-Content -LiteralPath '$escapedParamsPath' -Raw | ConvertFrom-Json
Write-Output 'WORKER_START'
`$detachedParams = @{
    Model          = [string]`$payload.Model
    Cwd            = [string]`$payload.Cwd
    ApprovalPolicy = [string]`$payload.ApprovalPolicy
    SandboxType    = [string]`$payload.SandboxType
    Prompt         = [string]`$payload.Prompt
    Name           = [string]`$payload.Name
    TurnTimeoutSec = [int]`$payload.TurnTimeoutSec
    ReadyFilePath  = [string]`$payload.ReadyFilePath
}
if (`$payload.Tags) { `$detachedParams.Tags = @(`$payload.Tags | Where-Object { `$null -ne `$_ }) }
if ([bool]`$payload.CreateCwd) { `$detachedParams.CreateCwd = `$true }
`$expectedModulePath = [System.IO.Path]::ChangeExtension('$escapedModulePath', '.psm1')
`$module = Get-Module PSUnplugged | Where-Object { `$_.Path -eq `$expectedModulePath } | Select-Object -First 1
if (`$null -eq `$module) {
    `$module = Get-Module PSUnplugged | Select-Object -Last 1
}
if (`$null -eq `$module) { throw 'PSUnplugged module is not loaded in worker process.' }
`$invokeManagedThread = `$module.NewBoundScriptBlock({ param(`$p) New-PSUnpluggedManagedThread @p | Out-Null })
& `$invokeManagedThread `$detachedParams
Write-Output 'WORKER_END'
"@
    Set-Content -LiteralPath $scriptPath -Value $workerScript -Encoding utf8

    $startParams = @{
        FilePath               = $runner
        ArgumentList           = @('-NoProfile', '-File', $scriptPath)
        PassThru               = $true
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError  = $stderrPath
    }

    if ($IsWindows) {
        $startParams.WindowStyle = 'Hidden'
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveCwd) -and (Test-Path -LiteralPath $effectiveCwd)) {
        $startParams.WorkingDirectory = $effectiveCwd
    }

    $process = Start-Process @startParams
    try {
        $payload.WorkerProcessId = $process.Id
        $payload.WorkerStartedAt = (Get-Date).ToString('o')
        Set-Content -LiteralPath $paramsPath -Value ($payload | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8
    }
    catch {
        # Best effort only; worker listing uses this when available.
    }

    return [PSCustomObject]@{
        Process    = $process
        ParamsPath = $paramsPath
        ReadyPath  = $readyPath
        ScriptPath = $scriptPath
        StdOutPath = $stdoutPath
        StdErrPath = $stderrPath
    }
}

function Get-PSUnpluggedTaskWorkerHandles {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ProjectPath,
        [int]$MaxAgeHours = 24
    )

    $workerRoot = Join-Path (Get-PSUnpluggedDataRoot) 'task-workers'
    if (-not (Test-Path -LiteralPath $workerRoot)) {
        return @()
    }

    $now = Get-Date
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($paramsFile in @(Get-ChildItem -LiteralPath $workerRoot -Filter '*.params.json' -File -ErrorAction SilentlyContinue)) {
        if ($MaxAgeHours -gt 0) {
            $ageHours = ($now - $paramsFile.LastWriteTime).TotalHours
            if ($ageHours -gt $MaxAgeHours) {
                continue
            }
        }

        $payload = $null
        try {
            $payload = Get-Content -LiteralPath $paramsFile.FullName -Raw | ConvertFrom-Json
        }
        catch {
            continue
        }
        if ($null -eq $payload) {
            continue
        }

        $readyFilePath = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('ReadyFilePath', 'readyFilePath'))
        if (-not [string]::IsNullOrWhiteSpace($readyFilePath) -and (Test-Path -LiteralPath $readyFilePath)) {
            continue
        }

        $cwd = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('Cwd', 'cwd'))
        if ([string]::IsNullOrWhiteSpace($cwd)) {
            continue
        }

        $projectIdentity = $null
        try {
            $projectIdentity = Get-CodexProjectIdentity -Path $cwd
        }
        catch {
            $projectIdentity = $null
        }

        $effectiveProjectPath = if ($projectIdentity -and $projectIdentity.Path) { [string]$projectIdentity.Path } else { $cwd }
        if (-not [string]::IsNullOrWhiteSpace($ProjectPath) -and $effectiveProjectPath -ne $ProjectPath) {
            continue
        }

        $workerId = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('WorkerId', 'workerId'))
        if ([string]::IsNullOrWhiteSpace($workerId)) {
            $workerId = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileNameWithoutExtension($paramsFile.Name))
        }

        $workerProcessId = $null
        $workerProcessIdValue = Get-CodexFirstValue -InputObject $payload -PropertyName @('WorkerProcessId', 'workerProcessId')
        if ($null -ne $workerProcessIdValue) {
            try { $workerProcessId = [int]$workerProcessIdValue } catch { $workerProcessId = $null }
        }

        $isAlive = $false
        $workerProcessName = $null
        if ($workerProcessId) {
            try {
                $process = Get-Process -Id $workerProcessId -ErrorAction Stop
                $isAlive = $true
                $workerProcessName = $process.ProcessName
            }
            catch {
                $isAlive = $false
            }
        }

        if (-not $isAlive -and $workerProcessId) {
            continue
        }

        $name = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('Name', 'name'))
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = [string](Get-CodexFirstValue -InputObject $payload -PropertyName @('Prompt', 'prompt'))
        }

        $stdoutPath = Join-Path $workerRoot "$workerId.stdout.log"
        $stderrPath = Join-Path $workerRoot "$workerId.stderr.log"

        $task = [PSCustomObject]@{
            Id                = if ($workerProcessId) { 'pending-' + [string]$workerProcessId } else { 'pending' }
            TaskId            = $null
            ThreadId          = $null
            Name              = $name
            Project           = if ($projectIdentity -and $projectIdentity.Name) { [string]$projectIdentity.Name } else { (Split-Path -Leaf $effectiveProjectPath) }
            Path              = $effectiveProjectPath
            Status            = 'starting'
            ReadyFilePath     = $readyFilePath
            WorkerProcessId   = $workerProcessId
            WorkerProcessName = $workerProcessName
            WorkerStdOutPath  = [string]$stdoutPath
            WorkerStdErrPath  = [string]$stderrPath
        }
        $task.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTask')
        $results.Add($task)
    }

    return @($results)
}

function Start-CodexTask {
    <#
    .SYNOPSIS
        Starts a managed Codex task using the thread runtime under the covers.
    .DESCRIPTION
        This is the task-oriented wrapper for New-CodexThread. It always uses the
        managed thread flow so the resulting task is cataloged and can be inspected
        later with Get-CodexTask and Receive-CodexTask.
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Session,
        [string]$Model = 'gpt-5.2',
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]
        $InputObject,
        [Alias('Path')]
        [string]$Cwd,
        [string]$ApprovalPolicy = 'never',
        [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
        [string]$SandboxType = 'workspace-write',
        [Parameter(Position = 0)]
        [Alias('Task', 'Instruction', 'Text')]
        [string]$Prompt,
        [string]$Name,
        [string[]]$Tags,
        [switch]$CreateCwd,
        [int]$TurnTimeoutSec = 900,
        [switch]$PassThruSession
    )

    process {
        $effectivePrompt = $Prompt
        $effectiveCwd = $Cwd
        if ($null -ne $InputObject) {
            if ($InputObject -is [string]) {
                $inputText = [string]$InputObject
                if ([string]::IsNullOrWhiteSpace($effectivePrompt)) {
                    if (-not [string]::IsNullOrWhiteSpace($effectiveCwd)) {
                        $effectivePrompt = $inputText
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($inputText) -and (Test-Path -LiteralPath $inputText)) {
                        $effectiveCwd = $inputText
                    }
                    else {
                        $effectivePrompt = $inputText
                    }
                }
                elseif ([string]::IsNullOrWhiteSpace($effectiveCwd) -and -not [string]::IsNullOrWhiteSpace($inputText) -and (Test-Path -LiteralPath $inputText)) {
                    $effectiveCwd = $inputText
                }
            }
            elseif ($InputObject.PSObject) {
                if ([string]::IsNullOrWhiteSpace($effectivePrompt)) {
                    foreach ($propertyName in 'Prompt', 'prompt', 'Task', 'task', 'Instruction', 'instruction', 'Text', 'text') {
                        $property = $InputObject.PSObject.Properties[$propertyName]
                        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                            $effectivePrompt = [string]$property.Value
                            break
                        }
                    }
                }

                foreach ($propertyName in 'Path', 'path', 'ProjectPath', 'projectPath', 'Cwd', 'cwd') {
                    $property = $InputObject.PSObject.Properties[$propertyName]
                    if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                        $effectiveCwd = [string]$property.Value
                        break
                    }
                }
            }
        }

        if ($PSBoundParameters.ContainsKey('Prompt') -and [string]::IsNullOrWhiteSpace($effectivePrompt)) {
            throw 'Start-CodexTask: -Prompt was provided but resolved to an empty value.'
        }

        $taskParams = @{}
        foreach ($entry in $PSBoundParameters.GetEnumerator()) {
            if ($entry.Key -eq 'InputObject') {
                continue
            }

            $taskParams[$entry.Key] = $entry.Value
        }

        if (-not [string]::IsNullOrWhiteSpace($effectiveCwd)) {
            $taskParams.Cwd = $effectiveCwd
        }
        elseif ($taskParams.ContainsKey('Cwd')) {
            $taskParams.Remove('Cwd')
        }

        if (-not [string]::IsNullOrWhiteSpace($effectivePrompt)) {
            $taskParams.Prompt = $effectivePrompt
        }
        elseif ($taskParams.ContainsKey('Prompt')) {
            $taskParams.Remove('Prompt')
        }

        $task = $null
        if ($taskParams.ContainsKey('Prompt')) {
            $workerParams = @{}
            foreach ($workerKey in 'Model', 'Cwd', 'ApprovalPolicy', 'SandboxType', 'Prompt', 'Name', 'Tags', 'CreateCwd', 'TurnTimeoutSec') {
                if ($taskParams.ContainsKey($workerKey)) {
                    $workerParams[$workerKey] = $taskParams[$workerKey]
                }
            }

            $worker = Start-PSUnpluggedTaskWorkerProcess @workerParams
            $projectName = if (-not [string]::IsNullOrWhiteSpace($Name)) {
                $Name
            }
            elseif (-not [string]::IsNullOrWhiteSpace($effectiveCwd)) {
                Split-Path -Leaf $effectiveCwd
            }
            else {
                'Pending Codex task'
            }

            $task = [PSCustomObject]@{
                Id                = if ($worker.Process) { 'pending-' + [string]$worker.Process.Id } else { 'pending' }
                TaskId            = $null
                ThreadId          = $null
                Name              = if (-not [string]::IsNullOrWhiteSpace($effectivePrompt)) { $effectivePrompt } else { $projectName }
                Project           = $projectName
                Path              = $effectiveCwd
                Status            = 'starting'
                ReadyFilePath     = [string]$worker.ReadyPath
                WorkerProcessId   = if ($worker.Process) { $worker.Process.Id } else { $null }
                WorkerProcessName = if ($worker.Process) { $worker.Process.ProcessName } else { $null }
                WorkerStdOutPath  = [string]$worker.StdOutPath
                WorkerStdErrPath  = [string]$worker.StdErrPath
            }
            $task.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTask')
        }
        else {
            $task = New-PSUnpluggedManagedThread @taskParams
        }

        if ($task) {
            return ($task | ConvertTo-CodexTaskOutput -Session $Session)
        }
    }
}

function Get-CodexTask {
    <#
    .SYNOPSIS
        Returns managed Codex tasks using task-first terminology.
    .DESCRIPTION
        By default, returns an operator view across projects, similar to Get-Job:
        tasks that are active or need attention, plus completed tasks from the
        recent work window.

        Pass -Project to scope the view to a specific project or project path, and
        -IncludeArchived when you want archived task records included.

        Use -ActiveOnly to focus on tasks that are still in play, -RecentHours or
        -Since to tune the completed-task window, -All to include older completed
        tasks, and -LocalOnly when you want to skip the Codex app-server refresh.
    #>
    [CmdletBinding()]
    param(
        [Alias('TaskId', 'ThreadId')][string]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [Parameter(ValueFromPipelineByPropertyName = $true, DontShow = $true)][string]$ProjectKey,
        [Parameter(ValueFromPipelineByPropertyName = $true, DontShow = $true)][Alias('Name')][string]$ProjectName,
        [Parameter(ValueFromPipelineByPropertyName = $true, DontShow = $true)][Alias('Path')][string]$ProjectPathInput,
        [switch]$IncludeArchived,
        [switch]$ActiveOnly,
        [switch]$All,
        [switch]$Refresh,
        [ValidateRange(0, 8760)]
        [double]$RecentHours = 4,
        [DateTimeOffset]$Since,
        [switch]$LocalOnly,
        [int]$Limit = 25,
        [PSCustomObject]$Session,
        [Parameter(DontShow = $true)][string]$SpinnerStatus = 'Loading Codex tasks...'
    )

    process {
        if ($ActiveOnly -and $IncludeArchived) {
            throw 'Get-CodexTask accepts either -IncludeArchived or -ActiveOnly, not both.'
        }

        $threadParams = @{}
        foreach ($entry in $PSBoundParameters.GetEnumerator()) {
            if ($entry.Key -in @('ActiveOnly', 'All', 'Refresh', 'RecentHours', 'Since', 'IncludeArchived')) {
                continue
            }

            $threadParams[$entry.Key] = $entry.Value
        }

        $isTaskHandleInput = Test-CodexTaskHandleInput -InputObject $InputObject
        $effectiveId = if (-not [string]::IsNullOrWhiteSpace($Id)) {
            Resolve-CodexTaskIdentifierText -Id $Id
        }
        else {
            Resolve-CodexTaskIdentifier -InputObject $InputObject
        }

        if (-not [string]::IsNullOrWhiteSpace($effectiveId)) {
            $threadParams.Id = $effectiveId
            foreach ($parameterName in @('InputObject', 'ProjectKey', 'ProjectName', 'ProjectPathInput')) {
                if ($threadParams.ContainsKey($parameterName)) {
                    $threadParams.Remove($parameterName)
                }
            }
        }
        elseif ($isTaskHandleInput) {
            return ($InputObject | ConvertTo-CodexTaskOutput -Session $Session)
        }

        if (-not $PSBoundParameters.ContainsKey('SpinnerStatus')) {
            $SpinnerStatus = if ($LocalOnly) {
                'Loading Codex tasks: reading local catalog and worker handles...'
            }
            else {
                'Loading Codex tasks: reading catalog, refreshing app-server, preparing view...'
            }
        }

        $threadParams.SpinnerStatus = $null
        $hasSince = $PSBoundParameters.ContainsKey('Since')
        $hasLocalOnly = $PSBoundParameters.ContainsKey('LocalOnly')

        return Invoke-PSUnpluggedWithSpinner -Status $SpinnerStatus -ScriptBlock {
        if ($PSBoundParameters.ContainsKey('IncludeArchived')) {
            if ($IncludeArchived) {
                $threadParams.IncludeArchived = $true
            }
        }

        $archivedThreadIds = $null
        if (-not $IncludeArchived) {
            $catalog = Import-PSUnpluggedCatalog
            $archivedThreadIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($archivedThreadId in @(Import-PSUnpluggedArchivedThreadIndex)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$archivedThreadId)) {
                    $null = $archivedThreadIds.Add([string]$archivedThreadId)
                }
            }
            foreach ($record in @($catalog.threads)) {
                if ($null -eq $record -or -not $record.Archived) {
                    continue
                }

                $recordThreadId = Get-CodexNormalizedThreadId -ThreadId ([string]$record.ThreadId)
                if (-not [string]::IsNullOrWhiteSpace($recordThreadId)) {
                    $null = $archivedThreadIds.Add($recordThreadId)
                }
            }
        }

        $pendingWorkerTasks = @()
        if (-not $threadParams.ContainsKey('Id')) {
            $workerProjectPath = $null
            if ($threadParams.ContainsKey('Project')) {
                $workerProjectTerm = [string]$threadParams.Project
                $hasWildcard = $workerProjectTerm.Contains('*') -or $workerProjectTerm.Contains('?') -or $workerProjectTerm.Contains('[')
                if ((-not $hasWildcard) -and (Test-Path -LiteralPath $workerProjectTerm)) {
                    try {
                        $workerProjectIdentity = Get-CodexProjectIdentity -Path $workerProjectTerm
                        $workerProjectPath = [string]$workerProjectIdentity.Path
                    }
                    catch {
                        $workerProjectPath = $null
                    }
                }
            }

            $pendingWorkerTasks = @(Get-PSUnpluggedTaskWorkerHandles -ProjectPath $workerProjectPath)
        }

        $tasks = @($pendingWorkerTasks + @(Get-CodexThread @threadParams | ConvertTo-CodexTaskOutput -Session $Session))
        if ($archivedThreadIds -and $archivedThreadIds.Count -gt 0) {
            $tasks = @(
                $tasks | Where-Object {
                    $taskId = Get-CodexNormalizedThreadId -ThreadId (Resolve-CodexTaskIdentifier -InputObject $_)
                    if ([string]::IsNullOrWhiteSpace($taskId)) {
                        return $true
                    }

                    return (-not $archivedThreadIds.Contains($taskId))
                }
            )
        }

        $filterTaskView = {
            param([AllowNull()][object[]]$InputTask)

            $filteredTasks = @($InputTask)
            if ($ActiveOnly) {
                return @(
                    $filteredTasks | Where-Object {
                        $status = ConvertTo-CodexTaskTerminalStatus -Status ([string](Get-CodexFirstValue -InputObject $_ -PropertyName @('Status', 'status')))
                        -not ($status -in @('completed', 'failed', 'error', 'canceled', 'archived'))
                    }
                )
            }

            if ((-not $All) -and (-not $threadParams.ContainsKey('Id'))) {
                $recentThreshold = if ($hasSince) {
                    [DateTimeOffset]$Since
                }
                else {
                    [DateTimeOffset]::Now.AddHours(-1 * $RecentHours)
                }

                return @(
                    $filteredTasks | Where-Object {
                        $status = ConvertTo-CodexTaskTerminalStatus -Status ([string](Get-CodexFirstValue -InputObject $_ -PropertyName @('Status', 'status')))
                        if ([string]::IsNullOrWhiteSpace($status)) {
                            return $true
                        }

                        if ($status -ne 'completed') {
                            return $true
                        }

                        $timestamp = ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $_ -PropertyName @('LastActivityAt', 'lastActivityAt', 'UpdatedAt', 'updatedAt', 'Timestamp', 'timestamp'))
                        if ($null -eq $timestamp) {
                            return $false
                        }

                        return ($timestamp -ge $recentThreshold)
                    }
                )
            }

            return @($filteredTasks)
        }

        $tasks = @(& $filterTaskView $tasks)

        if ($Limit -gt 0) {
            $tasks = @($tasks | Select-Object -First $Limit)
        }

        if (
            ($tasks.Count -eq 0) -and
            (-not $threadParams.ContainsKey('Id')) -and
            (-not $isTaskHandleInput)
        ) {
            $hint = if ($Refresh) {
                'No Codex tasks match the current operator view after refresh. Use Get-CodexTask -All for older completed tasks, or widen the window with -RecentHours.'
            }
            elseif ($hasLocalOnly) {
                'No local Codex tasks match the current operator view. Use Get-CodexTask -All for older completed tasks.'
            }
            else {
                'No Codex tasks match the current operator view. Use Get-CodexTask -All for older completed tasks, or widen the window with -RecentHours.'
            }

            Write-Warning $hint
        }

        foreach ($task in @($tasks)) {
            if ($task -and $task.PSObject.TypeNames -contains 'PSUnplugged.CodexTask') {
                $null = $task.PSObject.TypeNames.Remove('PSUnplugged.CodexTask')
                $task.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTask')
            }
        }

        return $tasks
        }
    }
}

function Receive-CodexTask {
    <#
    .SYNOPSIS
        Receives the latest useful output for one or more Codex tasks.
    .DESCRIPTION
        By default, returns the latest assistant message with text for each task.
        Use -Transcript to return the full transcript stream, or -Text for plain text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('TaskId', 'ThreadId')][string[]]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [switch]$Details,
        [switch]$Transcript,
        [switch]$ShowAll,
        [switch]$ShowTelemetry,
        [switch]$ShowReasoning,
        [switch]$ShowTools,
        [switch]$ShowCommands,
        [switch]$Text,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [int]$Limit = 25,
        [PSCustomObject]$Session
    )

    begin {
        $items = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $items.Add($InputObject)
        }
    }

    end {
        if ($Details) {
            $Transcript = $true
            $ShowAll = $true
        }

        $telemetryTypes = [System.Collections.Generic.List[string]]::new()
        $shouldIncludeTelemetry = $Transcript -or $Text
        if ($shouldIncludeTelemetry -and ($ShowAll -or $ShowTelemetry -or $ShowReasoning)) { $telemetryTypes.Add('reasoning') }
        if ($shouldIncludeTelemetry -and ($ShowAll -or $ShowTelemetry -or $ShowTools)) { $telemetryTypes.Add('tools') }
        if ($shouldIncludeTelemetry -and ($ShowAll -or $ShowTelemetry -or $ShowCommands)) { $telemetryTypes.Add('commands') }
        $telemetryTypes = [System.Collections.Generic.List[string]]@(@($telemetryTypes | Select-Object -Unique))

        $transcriptParams = @{
            Limit         = $Limit
            SpinnerStatus = 'Receiving Codex task output...'
        }
        if ($Id) { $transcriptParams.Id = $Id }
        if ($Project) { $transcriptParams.Project = $Project }
        if ($IncludeArchived) { $transcriptParams.IncludeArchived = $true }
        if ($LocalOnly) { $transcriptParams.LocalOnly = $true }
        if ($Session) { $transcriptParams.Session = $Session }
        if ($telemetryTypes.Count -gt 0) {
            $transcriptParams.IncludeTelemetry = $true
            $transcriptParams.TelemetryType = @($telemetryTypes)
        }

        $taskLookup = @{}
        $pipelineTranscriptInputs = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($items)) {
            if ($null -eq $item) {
                continue
            }

            $taskId = Resolve-CodexTaskIdentifier -InputObject $item
            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                $pipelineTranscriptInputs.Add([string]$taskId)

                $task = Get-CodexTask -Id ([string]$taskId) -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 1 -Session $Session -SpinnerStatus $null |
                Select-Object -First 1
                if ($task) {
                    $taskLookup[[string]$taskId] = $task
                }
                else {
                    $taskLookup[[string]$taskId] = $item
                }

                continue
            }

            $fallbackTaskId = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Id', 'id'))
            if (-not [string]::IsNullOrWhiteSpace($fallbackTaskId)) {
                $taskLookup[$fallbackTaskId] = $item
            }

            $pipelineTranscriptInputs.Add($item)
        }

        $transcriptItems = if ($items.Count -gt 0) {
            $pipelineTranscriptParams = @{
                Limit         = $Limit
                SpinnerStatus = 'Receiving Codex task output...'
            }
            if ($IncludeArchived) { $pipelineTranscriptParams.IncludeArchived = $true }
            if ($LocalOnly) { $pipelineTranscriptParams.LocalOnly = $true }
            if ($Session) { $pipelineTranscriptParams.Session = $Session }
            if ($telemetryTypes.Count -gt 0) {
                $pipelineTranscriptParams.IncludeTelemetry = $true
                $pipelineTranscriptParams.TelemetryType = @($telemetryTypes)
            }

            @($pipelineTranscriptInputs | Get-CodexTranscript @pipelineTranscriptParams)
        }
        else {
            @(
                Get-CodexTranscript @transcriptParams
            )
        }

        if ($taskLookup.Count -eq 0) {
            if ($Id) {
                foreach ($taskId in @($Id | Select-Object -Unique)) {
                    if ([string]::IsNullOrWhiteSpace([string]$taskId)) {
                        continue
                    }

                    $task = Get-CodexTask -Id ([string]$taskId) -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit 1 -Session $Session -SpinnerStatus $null |
                    Select-Object -First 1
                    if ($task) {
                        $taskLookup[[string]$taskId] = $task
                    }
                }
            }
            elseif ($Project) {
                foreach ($task in @(Get-CodexTask -Project $Project -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit $Limit -Session $Session -SpinnerStatus $null)) {
                    $taskId = Resolve-CodexTaskIdentifier -InputObject $task
                    if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                        $taskLookup[[string]$taskId] = $task
                    }
                }
            }
        }

        $latestItems = [System.Collections.Generic.List[object]]::new()
        $processedThreadIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($group in @($transcriptItems | Group-Object ThreadId)) {
            $threadId = [string]$group.Name
            if (-not [string]::IsNullOrWhiteSpace($threadId)) {
                $null = $processedThreadIds.Add($threadId)
            }

            $ordered = @(
                $group.Group |
                Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } }
            )

            $fallbackItem = $null
            if (-not [string]::IsNullOrWhiteSpace($threadId) -and $taskLookup.ContainsKey($threadId)) {
                $fallbackItem = New-CodexTaskFallbackTranscriptItem -Task $taskLookup[$threadId] -Session $Session
            }

            $terminalAssistant = @(
                $ordered |
                Where-Object {
                    $phase = [string](Get-CodexFirstValue -InputObject $_ -PropertyName @('Phase', 'phase'))
                    $_.Role -eq 'assistant' -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.Text) -and
                    -not [string]::IsNullOrWhiteSpace($phase) -and
                    $phase.Trim().ToLowerInvariant() -in @('final_answer', 'failed', 'error', 'cancelled', 'canceled')
                }
            ) | Select-Object -Last 1

            if (
                $fallbackItem -and
                $terminalAssistant -and
                [string](Get-CodexFirstValue -InputObject $terminalAssistant -PropertyName @('Text', 'text')) -eq 'Task completed with no assistant output.' -and
                [string](Get-CodexFirstValue -InputObject $fallbackItem -PropertyName @('Text', 'text')) -ne [string](Get-CodexFirstValue -InputObject $terminalAssistant -PropertyName @('Text', 'text'))
            ) {
                $latestItems.Add($fallbackItem)
                continue
            }

            if ($fallbackItem -and -not $terminalAssistant) {
                $fallbackPhase = [string](Get-CodexFirstValue -InputObject $fallbackItem -PropertyName @('Phase', 'phase'))
                if ($fallbackPhase -in @('failed', 'error', 'canceled')) {
                    $latestItems.Add($fallbackItem)
                    continue
                }
            }

            if ($terminalAssistant) {
                $latestItems.Add($terminalAssistant)
                continue
            }

            $latestAssistant = @(
                $ordered |
                Where-Object {
                    $_.Role -eq 'assistant' -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.Text)
                }
            ) | Select-Object -Last 1

            if ($latestAssistant) {
                $latestItems.Add($latestAssistant)
                continue
            }

            $latestTextItem = @(
                $ordered |
                Where-Object {
                    $_.Role -ne 'user' -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.Text)
                }
            ) | Select-Object -Last 1

            if ($latestTextItem) {
                $latestItems.Add($latestTextItem)
                continue
            }

            if ($fallbackItem) {
                $latestItems.Add($fallbackItem)
            }
        }

        foreach ($taskEntry in @($taskLookup.GetEnumerator())) {
            if ($processedThreadIds.Contains([string]$taskEntry.Key)) {
                continue
            }

            $fallbackItem = New-CodexTaskFallbackTranscriptItem -Task $taskEntry.Value -Session $Session
            if ($fallbackItem) {
                $latestItems.Add($fallbackItem)
            }
        }

        if ($Transcript) {
            $transcriptToReturn = @(
                foreach ($item in @($transcriptItems)) {
                    $threadId = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('ThreadId', 'threadId'))
                    $phase = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Phase', 'phase'))
                    $itemText = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('Text', 'text'))

                    if (
                        -not [string]::IsNullOrWhiteSpace($threadId) -and
                        $taskLookup.ContainsKey($threadId) -and
                        $phase -eq 'failed' -and
                        $itemText -eq 'Task completed with no assistant output.'
                    ) {
                        $fallbackItem = New-CodexTaskFallbackTranscriptItem -Task $taskLookup[$threadId] -Session $Session
                        if ($fallbackItem -and [string](Get-CodexFirstValue -InputObject $fallbackItem -PropertyName @('Text', 'text')) -ne $itemText) {
                            $fallbackItem
                            continue
                        }
                    }

                    $item
                }

                $transcriptThreadIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                foreach ($item in @($transcriptItems)) {
                    $threadId = [string](Get-CodexFirstValue -InputObject $item -PropertyName @('ThreadId', 'threadId'))
                    if (-not [string]::IsNullOrWhiteSpace($threadId)) {
                        $null = $transcriptThreadIds.Add($threadId)
                    }
                }

                foreach ($taskEntry in @($taskLookup.GetEnumerator())) {
                    if ($transcriptThreadIds.Contains([string]$taskEntry.Key)) {
                        continue
                    }

                    $fallbackItem = New-CodexTaskFallbackTranscriptItem -Task $taskEntry.Value -Session $Session
                    if ($fallbackItem) {
                        $fallbackItem
                    }
                }
            )

            if ($Text) {
                return @($transcriptToReturn | ForEach-Object { [string]$_.Text })
            }

            return @($transcriptToReturn)
        }

        if ($Text) {
            return @($latestItems | ForEach-Object { [string]$_.Text })
        }

        return @($latestItems | ConvertTo-CodexTaskReceiveOutput)
    }
}

function Resume-CodexTask {
    <#
    .SYNOPSIS
        Resumes a managed Codex task by task ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('TaskId', 'ThreadId')][string]$Id,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [Alias('Path', 'Project')][string]$ProjectPath,
        [string]$Prompt,
        [string]$Model = 'gpt-5.2',
        [PSCustomObject]$Session
    )

    process {
        $resolvedId = if ($null -ne $InputObject) {
            Resolve-CodexTaskIdentifier -InputObject $InputObject
        }
        else {
            $Id
        }

        if ([string]::IsNullOrWhiteSpace($resolvedId)) {
            $resolvedId = $Id
        }

        $resumeParams = @{
            Id     = $resolvedId
            Prompt = $Prompt
            Model  = $Model
        }
        if ($ProjectPath) { $resumeParams.ProjectPath = $ProjectPath }
        if ($Session) { $resumeParams.Session = $Session }

        $result = Enter-CodexThread @resumeParams
        if ($result -and $result.PSObject.Properties['ThreadId']) {
            $null = $result | Add-Member -NotePropertyName TaskId -NotePropertyValue ([string]$result.ThreadId) -Force
            if (-not ($result.PSObject.TypeNames -contains 'PSUnplugged.CodexTaskTurn')) {
                $result.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTaskTurn')
            }
        }

        return $result
    }
}

function Wait-CodexTask {
    <#
    .SYNOPSIS
        Waits for one or more Codex tasks to reach a terminal state.
    .DESCRIPTION
        A task is treated as complete when its status is terminal or when its
        transcript contains a terminal assistant phase such as final_answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('TaskId', 'ThreadId')][string[]]$Id,
        [Parameter(Position = 0)][string]$Project,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [switch]$Any,
        [switch]$Tail,
        [switch]$Details,
        [switch]$ShowAll,
        [switch]$ShowTelemetry,
        [switch]$ShowReasoning,
        [switch]$ShowTools,
        [switch]$ShowCommands,
        [switch]$Receive,
        [switch]$Text,
        [switch]$Transcript,
        [switch]$IncludeArchived,
        [switch]$LocalOnly,
        [int]$Limit = 25,
        [int]$TimeoutSec = 0,
        [int]$PollIntervalMs = 1000,
        [int]$HeartbeatSec = 15,
        [PSCustomObject]$Session
    )

    begin {
        $inputs = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $inputs.Add($InputObject)
        }
    }

    end {
        if ($Details) {
            $Transcript = $true
            $ShowAll = $true
        }

        $taskLookup = [ordered]@{}
        $seenTranscriptKeysByTask = @{}
        $lastHeartbeatAt = Get-Date
        $tailTelemetryTypes = [System.Collections.Generic.List[string]]::new()
        if ($ShowAll -or $ShowTelemetry -or $ShowReasoning) { $tailTelemetryTypes.Add('reasoning') }
        if ($ShowAll -or $ShowTelemetry -or $ShowTools) { $tailTelemetryTypes.Add('tools') }
        if ($ShowAll -or $ShowTelemetry -or $ShowCommands) { $tailTelemetryTypes.Add('commands') }
        $tailTelemetryTypes = [System.Collections.Generic.List[string]]@(@($tailTelemetryTypes | Select-Object -Unique))

        if ($inputs.Count -eq 0) {
            foreach ($taskId in @($Id)) {
                if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                    $taskLookup[[string]$taskId] = [PSCustomObject]@{ TaskId = [string]$taskId }
                }
            }
        }

        foreach ($item in @($inputs)) {
            if ($null -eq $item) {
                continue
            }

            $taskId = Resolve-CodexTaskIdentifier -InputObject $item
            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                if ($item -is [string]) {
                    $taskLookup[[string]$taskId] = [PSCustomObject]@{ TaskId = [string]$taskId }
                }
                else {
                    $taskLookup[$taskId] = $item
                }
                continue
            }

            $readyFilePath = Get-CodexTaskReadyFilePath -InputObject $item
            if (-not [string]::IsNullOrWhiteSpace($readyFilePath)) {
                $taskLookup["pending::$readyFilePath"] = $item
            }
        }

        if (($taskLookup.Count -eq 0) -and -not [string]::IsNullOrWhiteSpace($Project)) {
            foreach ($task in @(Get-CodexTask -Project $Project -IncludeArchived:$IncludeArchived -LocalOnly:$LocalOnly -Limit $Limit -Session $Session)) {
                if ($task -and -not [string]::IsNullOrWhiteSpace([string]$task.TaskId)) {
                    $taskLookup[[string]$task.TaskId] = $task
                }
            }
        }

        if ($taskLookup.Count -eq 0) {
            return
        }

        $deadline = if ($TimeoutSec -gt 0) { (Get-Date).AddSeconds($TimeoutSec) } else { $null }

        if ($Tail) {
            foreach ($taskId in @($taskLookup.Keys)) {
                $taskHandle = $taskLookup[$taskId]
                $resolvedTaskId = Resolve-CodexTaskIdentifier -InputObject $taskHandle
                if ([string]::IsNullOrWhiteSpace($resolvedTaskId)) {
                    continue
                }

                $seenTranscriptKeysByTask[$resolvedTaskId] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

                $baselineTranscriptParams = @{
                    Id            = $resolvedTaskId
                    Limit         = $Limit
                    SpinnerStatus = $null
                }
                if ($IncludeArchived) { $baselineTranscriptParams.IncludeArchived = $true }
                if ($LocalOnly) { $baselineTranscriptParams.LocalOnly = $true }
                if ($Session) { $baselineTranscriptParams.Session = $Session }
                if ($tailTelemetryTypes.Count -gt 0) {
                    $baselineTranscriptParams.IncludeTelemetry = $true
                    $baselineTranscriptParams.TelemetryType = @($tailTelemetryTypes)
                }

                foreach ($item in @(Get-CodexTranscript @baselineTranscriptParams)) {
                    $key = Get-CodexTaskTranscriptItemKey -Item $item
                    if (-not [string]::IsNullOrWhiteSpace($key)) {
                        $null = $seenTranscriptKeysByTask[$resolvedTaskId].Add($key)
                    }
                }
            }
        }

        while ($true) {
            $completed = [System.Collections.Generic.List[object]]::new()
            $sawNewTailOutput = $false
            $latestTaskSnapshot = [System.Collections.Generic.List[object]]::new()
            $latestTranscriptByTaskId = @{}

            foreach ($taskId in @($taskLookup.Keys)) {
                $taskHandle = $taskLookup[$taskId]
                $resolvedTaskId = Resolve-CodexTaskIdentifier -InputObject $taskHandle
                if ([string]::IsNullOrWhiteSpace($resolvedTaskId)) {
                    $readyFilePath = Get-CodexTaskReadyFilePath -InputObject $taskHandle
                    if (-not [string]::IsNullOrWhiteSpace($readyFilePath) -and (Test-Path -LiteralPath $readyFilePath)) {
                        try {
                            $readyPayload = Get-Content -LiteralPath $readyFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        }
                        catch {
                            $readyPayload = $null
                        }

                        if ($readyPayload -and -not [string]::IsNullOrWhiteSpace([string]$readyPayload.ThreadId)) {
                            $resolvedTaskId = [string]$readyPayload.ThreadId
                            $taskLookup.Remove($taskId)
                            $taskLookup[$resolvedTaskId] = $taskHandle
                        }
                    }
                }

                if ([string]::IsNullOrWhiteSpace($resolvedTaskId)) {
                    $latestTaskSnapshot.Add($taskHandle)
                    continue
                }

                $getLocalTaskParams = @{
                    Id            = $resolvedTaskId
                    Limit         = 1
                    SpinnerStatus = $null
                    LocalOnly     = $true
                }
                if ($IncludeArchived) { $getLocalTaskParams.IncludeArchived = $true }

                $task = Get-CodexTask @getLocalTaskParams |
                Select-Object -First 1
                if ((-not $task) -and -not $LocalOnly) {
                    $getTaskParams = @{
                        Id            = $resolvedTaskId
                        Limit         = 1
                        SpinnerStatus = $null
                    }
                    if ($IncludeArchived) { $getTaskParams.IncludeArchived = $true }
                    if ($Session) { $getTaskParams.Session = $Session }

                    $task = Get-CodexTask @getTaskParams |
                    Select-Object -First 1
                }

                if (-not $task) {
                    $task = [PSCustomObject]@{
                        TaskId = $resolvedTaskId
                        Id     = Get-CodexCompactId -Id $resolvedTaskId
                        Status = 'missing'
                    }
                    $task.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTask')
                }
                $latestTaskSnapshot.Add($task)

                $localTranscriptParams = @{
                    Id            = $resolvedTaskId
                    Limit         = $Limit
                    SpinnerStatus = $null
                    LocalOnly     = $true
                }
                if ($IncludeArchived) { $localTranscriptParams.IncludeArchived = $true }
                if ($tailTelemetryTypes.Count -gt 0) {
                    $localTranscriptParams.IncludeTelemetry = $true
                    $localTranscriptParams.TelemetryType = @($tailTelemetryTypes)
                }

                $transcriptItems = @(Get-CodexTranscript @localTranscriptParams)
                if (($transcriptItems.Count -eq 0) -and -not $LocalOnly) {
                    $transcriptParams = @{
                        Id            = $resolvedTaskId
                        Limit         = $Limit
                        SpinnerStatus = $null
                    }
                    if ($IncludeArchived) { $transcriptParams.IncludeArchived = $true }
                    if ($Session) { $transcriptParams.Session = $Session }
                    if ($tailTelemetryTypes.Count -gt 0) {
                        $transcriptParams.IncludeTelemetry = $true
                        $transcriptParams.TelemetryType = @($tailTelemetryTypes)
                    }

                    $transcriptItems = @(Get-CodexTranscript @transcriptParams)
                }

                $latestTranscriptByTaskId[$resolvedTaskId] = @($transcriptItems)

                if ($Tail) {
                    if (-not $seenTranscriptKeysByTask.ContainsKey($resolvedTaskId)) {
                        $seenTranscriptKeysByTask[$resolvedTaskId] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                    }

                    $newItems = [System.Collections.Generic.List[object]]::new()
                    foreach ($item in @($transcriptItems | Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } })) {
                        $key = Get-CodexTaskTranscriptItemKey -Item $item
                        if ([string]::IsNullOrWhiteSpace($key)) {
                            continue
                        }

                        if ($seenTranscriptKeysByTask[$resolvedTaskId].Add($key)) {
                            $newItems.Add($item)
                        }
                    }

                    if ($newItems.Count -gt 0) {
                        Write-CodexTaskTailItems -TranscriptItem @($newItems)
                        $sawNewTailOutput = $true
                    }
                }

                if (Test-CodexTaskCompletion -Task $task -Transcript $transcriptItems) {
                    $terminalTaskStatus = Get-CodexTaskEffectiveStatus -InputObject $task
                    if ([string]::IsNullOrWhiteSpace($terminalTaskStatus) -or $terminalTaskStatus -in @('active', 'starting')) {
                        $terminalTaskStatus = 'completed'
                    }

                    $task | Add-Member -NotePropertyName Status -NotePropertyValue $terminalTaskStatus -Force
                    $completed.Add($task)
                }
                elseif (
                    (Test-CodexTaskWorkerCompletionApplies -InputObject $taskHandle) -and
                    (Test-CodexTaskWorkerCompleted -InputObject $taskHandle)
                ) {
                    $workerTerminalStatus = Get-CodexTaskEffectiveStatus -InputObject $task
                    if ([string]::IsNullOrWhiteSpace($workerTerminalStatus) -or $workerTerminalStatus -in @('active', 'starting')) {
                        $workerTerminalStatus = 'failed'
                        $task | Add-Member -NotePropertyName LastErrorMessage -NotePropertyValue 'Task worker stopped before Codex reported task completion.' -Force
                    }

                    $task | Add-Member -NotePropertyName Status -NotePropertyValue $workerTerminalStatus -Force
                    $completed.Add($task)
                }
            }

            if ($completed.Count -gt 0) {
                $tasksToReturn = if ($Any) { @($completed | Select-Object -First 1) } else { @($completed) }
                if ($Receive) {
                    $receiveParams = @{
                        Limit = $Limit
                    }
                    if ($Transcript) { $receiveParams.Transcript = $true }
                    if ($Text) { $receiveParams.Text = $true }
                    if ($Details) { $receiveParams.Details = $true }
                    if ($ShowAll) { $receiveParams.ShowAll = $true }
                    if ($IncludeArchived) { $receiveParams.IncludeArchived = $true }
                    if ($LocalOnly) { $receiveParams.LocalOnly = $true }
                    if ($Session) { $receiveParams.Session = $Session }

                    return @($tasksToReturn | Receive-CodexTask @receiveParams)
                }

                return @($tasksToReturn)
            }

            if ($deadline -and ((Get-Date) -ge $deadline)) {
                Write-Warning "Timed out after $TimeoutSec second(s) while waiting for Codex task completion."
                if ($Receive) {
                    $receiveParams = @{
                        Limit = $Limit
                    }
                    if ($Transcript) { $receiveParams.Transcript = $true }
                    if ($Text) { $receiveParams.Text = $true }
                    if ($Details) { $receiveParams.Details = $true }
                    if ($ShowAll) { $receiveParams.ShowAll = $true }
                    if ($IncludeArchived) { $receiveParams.IncludeArchived = $true }
                    if ($LocalOnly) { $receiveParams.LocalOnly = $true }
                    if ($Session) { $receiveParams.Session = $Session }

                    return @($latestTaskSnapshot | Receive-CodexTask @receiveParams)
                }

                return @($latestTaskSnapshot)
            }

            if ($Tail -and (-not $sawNewTailOutput) -and ($HeartbeatSec -gt 0)) {
                $now = Get-Date
                if (($now - $lastHeartbeatAt).TotalSeconds -ge $HeartbeatSec) {
                    $heartbeatPrefix = if ($deadline) {
                        $elapsedSeconds = [int]($TimeoutSec - ($deadline - $now).TotalSeconds)
                        if ($elapsedSeconds -lt 0) { $elapsedSeconds = $TimeoutSec }
                        "[working | ${elapsedSeconds}s]"
                    }
                    else {
                        '[working]'
                    }

                    Write-Host "$heartbeatPrefix No new task updates yet." -ForegroundColor DarkGray

                    foreach ($task in @($latestTaskSnapshot)) {
                        if ($null -eq $task) { continue }

                        $resolvedTaskId = Resolve-CodexTaskIdentifier -InputObject $task
                        $transcriptForTask = if (-not [string]::IsNullOrWhiteSpace($resolvedTaskId) -and $latestTranscriptByTaskId.ContainsKey($resolvedTaskId)) {
                            @($latestTranscriptByTaskId[$resolvedTaskId])
                        }
                        else {
                            @()
                        }

                        $lastTranscriptItemWithText = @(
                            $transcriptForTask |
                            Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-CodexFirstValue -InputObject $_ -PropertyName @('Text', 'text'))) } |
                            Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } }
                        ) | Select-Object -Last 1

                        if ($lastTranscriptItemWithText) {
                            $role = [string](Get-CodexFirstValue -InputObject $lastTranscriptItemWithText -PropertyName @('Role', 'role'))
                            $phase = [string](Get-CodexFirstValue -InputObject $lastTranscriptItemWithText -PropertyName @('Phase', 'phase'))
                            $transcriptText = [string](Get-CodexFirstValue -InputObject $lastTranscriptItemWithText -PropertyName @('Text', 'text'))
                            $timestamp = ConvertTo-CodexDateTimeOffset -Value (Get-CodexFirstValue -InputObject $lastTranscriptItemWithText -PropertyName @('Timestamp', 'timestamp'))
                            $when = if ($timestamp) { $timestamp.LocalDateTime.ToString('HH:mm') } else { $null }

                            $summaryParts = [System.Collections.Generic.List[string]]::new()
                            if (-not [string]::IsNullOrWhiteSpace($when)) { $summaryParts.Add($when) }
                            foreach ($part in @($role, $phase)) {
                                if (-not [string]::IsNullOrWhiteSpace($part)) { $summaryParts.Add($part) }
                            }

                            $label = if ($summaryParts.Count -gt 0) { '[' + ($summaryParts -join ' | ') + ']' } else { $null }
                            $singleLineText = ($transcriptText -replace '\s+', ' ').Trim()
                            if (-not [string]::IsNullOrWhiteSpace($singleLineText)) {
                                if (-not [string]::IsNullOrWhiteSpace($label)) {
                                    Write-Host ("{0} {1} {2}" -f $heartbeatPrefix, $label, $singleLineText) -ForegroundColor DarkGray
                                }
                                else {
                                    Write-Host ("{0} {1}" -f $heartbeatPrefix, $singleLineText) -ForegroundColor DarkGray
                                }
                                continue
                            }
                        }

                        $fallbackItem = $null
                        try {
                            $fallbackItem = New-CodexTaskFallbackTranscriptItem -Task $task -Session $Session
                        }
                        catch {
                            $fallbackItem = $null
                        }

                        $fallbackText = if ($fallbackItem) { [string](Get-CodexFirstValue -InputObject $fallbackItem -PropertyName @('Text', 'text')) } else { $null }
                        if (-not [string]::IsNullOrWhiteSpace($fallbackText)) {
                            Write-Host ("{0} {1}" -f $heartbeatPrefix, $fallbackText) -ForegroundColor DarkGray
                        }
                    }

                    $lastHeartbeatAt = $now
                }
            }

            Start-Sleep -Milliseconds ([Math]::Max(100, $PollIntervalMs))
        }
    }
}

function Remove-CodexTask {
    <#
    .SYNOPSIS
        Archives or purges local metadata for a managed Codex task.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)][Alias('Id', 'ThreadId')][string]$TaskId,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]$InputObject,
        [switch]$Purge
    )

    process {
        $resolvedTaskId = if ($null -ne $InputObject) {
            Resolve-CodexTaskIdentifier -InputObject $InputObject
        }
        else {
            $TaskId
        }

        if ([string]::IsNullOrWhiteSpace($resolvedTaskId)) {
            throw 'TaskId is required.'
        }

        if ($Purge) {
            Remove-CodexThread -ThreadId $resolvedTaskId -Purge
            return
        }

        $archiveParams = @{
            ThreadId = $resolvedTaskId
            Archive  = $true
        }

        if ($null -ne $InputObject) {
            $taskName = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Name', 'name'))
            if (-not [string]::IsNullOrWhiteSpace($taskName) -and $taskName -ne 'Untitled thread') {
                $archiveParams.Name = $taskName
            }

            $taskPath = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Path', 'path', 'ProjectPath', 'projectPath'))
            if (-not [string]::IsNullOrWhiteSpace($taskPath)) {
                $archiveParams.ProjectPath = $taskPath
            }
            else {
                $taskProject = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Project', 'project', 'ProjectName', 'projectName'))
                if (-not [string]::IsNullOrWhiteSpace($taskProject)) {
                    $archiveParams.ProjectName = $taskProject
                }
            }
        }

        Set-CodexThread @archiveParams
    }
}

Update-TypeData -TypeName 'PSUnplugged.CodexProject' -DefaultDisplayPropertySet Name, Kind, LastActive -Force
Update-TypeData -TypeName 'PSUnplugged.CodexProject.Details' -DefaultDisplayPropertySet Name, Kind, ThreadSummary, LastActive -Force
Update-TypeData -TypeName 'PSUnplugged.CodexThread' -DefaultDisplayPropertySet Id, Name, Project, Status, When -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTask' -DefaultDisplayPropertySet Id, Name, Project, Status, LastErrorMessage, When -Force
Update-TypeData -TypeName 'PSUnplugged.CodexEvent' -DefaultDisplayPropertySet When, Kind, Project, Summary -Force
Update-TypeData -TypeName 'PSUnplugged.CodexEvent.Raw' -DefaultDisplayPropertySet When, Kind, Project, Summary, RawEvent -Force
Update-TypeData -TypeName 'PSUnplugged.CodexApproval' -DefaultDisplayPropertySet When, Status, ApprovalType, Project, Target -Force
Update-TypeData -TypeName 'PSUnplugged.CodexApproval.Raw' -DefaultDisplayPropertySet When, Status, ApprovalType, Project, Target, RawEvent -Force
Update-TypeData -TypeName 'PSUnplugged.CodexArtifact' -DefaultDisplayPropertySet When, Kind, Project, Name, Summary -Force
Update-TypeData -TypeName 'PSUnplugged.CodexArtifact.Content' -DefaultDisplayPropertySet When, Kind, Project, Name, Summary, Content -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTranscriptItem' -DefaultDisplayPropertySet Role, Phase, When, Text -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTaskReceive' -DefaultDisplayPropertySet Id, Name, Project, Status, Summary, When -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTaskTurn' -DefaultDisplayPropertySet TaskId, Prompt, Result -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTaskDashboardData' -DefaultDisplayPropertySet title, taskCount, activeCount, failedCount, attentionCount, generatedAt -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTranscriptPage' -DefaultDisplayPropertySet Path, ThreadCount, ItemCount, Opened -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTaskDashboardPage' -DefaultDisplayPropertySet Path, TaskCount, Opened -Force

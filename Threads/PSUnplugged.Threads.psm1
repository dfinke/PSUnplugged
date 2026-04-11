.$(Join-Path $PSScriptRoot 'Private\PowerShellRich.Status.ps1')

$threadFormatPath = Join-Path $PSScriptRoot 'PSUnplugged.Threads.Format.ps1xml'
if (Test-Path -LiteralPath $threadFormatPath) {
    Update-FormatData -PrependPath $threadFormatPath -ErrorAction SilentlyContinue
}

if (-not (Get-Command -Name Start-CodexSession -CommandType Function -ErrorAction Ignore)) {
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

    if (-not $catalog.projects) { $catalog | Add-Member -NotePropertyName projects -NotePropertyValue @() -Force }
    if (-not $catalog.threads) { $catalog | Add-Member -NotePropertyName threads -NotePropertyValue @() -Force }
    if (-not $catalog.version) { $catalog | Add-Member -NotePropertyName version -NotePropertyValue 1 -Force }

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

    $catalog.projects = @($Catalog.projects)
    $catalog.threads = @($Catalog.threads)

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
        [AllowNull()][DateTimeOffset]$Timestamp
    )

    $item = [PSCustomObject]@{
        ThreadId   = $ThreadId
        ThreadName = $ThreadName
        TurnId     = $TurnId
        Index      = $Index
        Role       = $Role
        Project    = $Project
        ItemType   = $ItemType
        Phase      = $Phase
        Timestamp  = if ($Timestamp) { $Timestamp.ToString('o') } else { $null }
        When       = if ($Timestamp) { Get-CodexDisplayTimestamp -Timestamp $Timestamp } else { $null }
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
            $role = 'assistant'
            $itemType = 'agentMessage'
            $phase = 'final_answer'
            $text = [string](Get-CodexFirstValue -InputObject $entry.payload -PropertyName @('last_agent_message', 'lastAgentMessage'))
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

    return [System.IO.Path]::GetFullPath($Path)
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
    $Catalog.projects = $projects

    return $record
}

function Find-CodexCatalogThreadRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog,
        [Parameter(Mandatory)][string]$ThreadId
    )

    return @($Catalog.threads) | Where-Object { $_.ThreadId -eq $ThreadId } | Select-Object -First 1
}

function Set-CodexCatalogThreadRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Catalog,
        [Parameter(Mandatory)][hashtable]$Properties
    )

    $threadId = $Properties.ThreadId
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        throw "ThreadId is required."
    }

    $existing = Find-CodexCatalogThreadRecord -Catalog $Catalog -ThreadId $threadId
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

    $threads = @($Catalog.threads | Where-Object { $_.ThreadId -ne $threadId })
    $threads += [PSCustomObject]$record
    $Catalog.threads = $threads

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
        [int]$Length = 8
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
        Name              = $Record.Name
        ProjectKey        = $Record.ProjectKey
        Path              = $Record.Path
        Kind              = $Record.Kind
        Branch            = $Record.Branch
        RemoteUrl         = $Record.RemoteUrl
        LastThreadAt      = if ($lastThreadAt) { $lastThreadAt.ToString('o') } else { $null }
        LastActive        = if ($lastThreadAt) { Get-CodexDisplayTimestamp -Timestamp $lastThreadAt } else { $null }
        RegisteredAt      = $Record.RegisteredAt
        UpdatedAt         = $Record.UpdatedAt
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

        $properties = @{
            ThreadId = $threadId
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.ProjectKey)) { $properties.ProjectKey = $threadOutput.ProjectKey }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.Project)) { $properties.ProjectName = $threadOutput.Project }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.Path)) { $properties.Path = $threadOutput.Path }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.CreatedAt)) { $properties.CreatedAt = $threadOutput.CreatedAt }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.LastActivityAt)) { $properties.LastActivityAt = $threadOutput.LastActivityAt }
        if (-not [string]::IsNullOrWhiteSpace([string]$threadOutput.Name) -and $threadOutput.Name -ne 'Untitled thread') { $properties.Name = $threadOutput.Name }

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

    $status = if ($Record -and $Record.Archived) {
        'archived'
    }
    else {
        [string]$statusValue
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = 'active'
    }

    $threadOutput = [PSCustomObject]@{
        Id             = Get-CodexCompactId -Id $threadId
        ThreadId       = $threadId
        Name           = Get-CodexThreadTitle -Thread $Thread -Record $Record
        Project        = $projectName
        ProjectKey     = $projectKey
        Path           = $path
        ProjectKind    = $projectKind
        ProjectBranch  = $projectBranch
        ProjectRemoteUrl = $projectRemoteUrl
        ProjectManifestPath = $projectManifestPath
        Model          = if ($Record -and $Record.Model) { $Record.Model } else { [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('model')) }
        Status         = $status
        Pinned         = if ($Record) { [bool]$Record.Pinned } else { $false }
        Archived       = if ($Record) { [bool]$Record.Archived } else { $false }
        Tags           = if ($Record) { @($Record.Tags) } else { @() }
        CreatedAt      = if ($Record -and $Record.CreatedAt) { $Record.CreatedAt } else { [string](Get-CodexFirstValue -InputObject $Thread -PropertyName @('createdAt')) }
        LastActivityAt = if ($timestamp) { $timestamp.ToString('o') } else { $null }
        LastActive     = if ($timestamp) { $timestamp.ToString('g') } else { $null }
        When           = if ($timestamp) { Get-CodexDisplayTimestamp -Timestamp $timestamp } else { $null }
        ApprovalPolicy = if ($Record) { $Record.ApprovalPolicy } else { $null }
        SandboxType    = if ($Record) { $Record.SandboxType } else { $null }
        Source         = if ($Thread -and $Record) { 'Merged' } elseif ($Thread) { 'Remote' } else { 'Local' }
        Metadata       = $Record
        RawThread      = $Thread
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
        [string]$Model = 'gpt-5.1-codex',
        [Alias('Path')][string]$Cwd,
        [string]$ApprovalPolicy = 'never',
        [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
        [string]$SandboxType = 'workspace-write',
        [string]$Prompt,
        [string]$Name,
        [string[]]$Tags,
        [switch]$CreateCwd,
        [switch]$PromptInBackground,
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
                $initialTurn = Invoke-CodexTurn -Session $Session -ThreadId $threadId -Text $Prompt

                $catalog = Import-PSUnpluggedCatalog
                $null = Set-CodexCatalogThreadRecord -Catalog $catalog -Properties @{
                    ThreadId       = $threadId
                    LastOpenedAt   = Get-PSUnpluggedUtcNowString
                    LastActivityAt = Get-PSUnpluggedUtcNowString
                }
                Export-PSUnpluggedCatalog -Catalog $catalog
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
                    $merged[$threadId] = $threadOutput
                }
            }

            foreach ($record in @($catalog.threads)) {
                if (-not $merged.Contains($record.ThreadId)) {
                    $threadOutput = ConvertTo-CodexThreadOutput -Record $record -Catalog $catalog
                    if ($threadOutput) {
                        $merged[$record.ThreadId] = $threadOutput
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
                $results = @($results | Where-Object { $_.ThreadId -eq $Id })
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
                $catalog.threads = @($catalog.threads | Where-Object { $_.ThreadId -ne $ThreadId })
                Export-PSUnpluggedCatalog -Catalog $catalog
            }

            return
        }

        if ($PSCmdlet.ShouldProcess($ThreadId, 'Archive Codex thread metadata')) {
            $null = Set-CodexCatalogThreadRecord -Catalog $catalog -Properties @{
                ThreadId = $ThreadId
                Archived = $true
            }
            Export-PSUnpluggedCatalog -Catalog $catalog
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
        [string]$Model = 'gpt-5.1-codex',
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

    try {
        $thread = Resume-CodexThread -Session $Session -ThreadId $Id
        $turn = Invoke-CodexTurn -Session $Session -ThreadId $Id -Text $Prompt

        $catalog = Import-PSUnpluggedCatalog
        $properties = @{
            ThreadId       = $Id
            LastOpenedAt   = Get-PSUnpluggedUtcNowString
            LastActivityAt = Get-PSUnpluggedUtcNowString
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
        [AllowNull()]$InputObject
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

        $output = [PSCustomObject]@{
            Id        = Get-CodexCompactId -Id $taskId
            TaskId    = $taskId
            ThreadId  = $taskId
            Name      = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('ThreadName', 'threadName', 'Name', 'name'))
            Project   = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Project', 'project'))
            Role      = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Role', 'role'))
            Phase     = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Phase', 'phase'))
            When      = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('When', 'when'))
            Timestamp = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Timestamp', 'timestamp'))
            Text      = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Text', 'text'))
            RawItem   = $InputObject
        }

        $output.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTaskReceive')
        return $output
    }
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
        return [string]$InputObject
    }

    $explicitTaskId = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('TaskId', 'ThreadId', 'threadId'))
    if (-not [string]::IsNullOrWhiteSpace($explicitTaskId)) {
        return $explicitTaskId
    }

    $fallbackId = [string](Get-CodexFirstValue -InputObject $InputObject -PropertyName @('Id', 'id'))
    if ($fallbackId -match '^(urn:uuid:)?[0-9a-fA-F-]{32,36}$') {
        return $fallbackId
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

                $phase.Trim().ToLowerInvariant() -in @('final_answer', 'failed', 'error', 'cancelled', 'canceled')
            } |
            Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } }
    ) | Select-Object -Last 1

    return ($null -ne $terminalTranscriptItem)
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
        [string]$Model = 'gpt-5.1-codex',
        [string]$Cwd,
        [string]$ApprovalPolicy = 'never',
        [string]$SandboxType = 'workspace-write',
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Name,
        [string[]]$Tags,
        [switch]$CreateCwd
    )

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
        Model         = $Model
        Cwd           = $Cwd
        ApprovalPolicy = $ApprovalPolicy
        SandboxType   = $SandboxType
        Prompt        = $Prompt
        Name          = $Name
        Tags          = @($Tags)
        CreateCwd     = [bool]$CreateCwd
        ReadyFilePath = $readyPath
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
    ReadyFilePath  = [string]`$payload.ReadyFilePath
}
if (`$payload.Tags) { `$detachedParams.Tags = @(`$payload.Tags | Where-Object { `$null -ne `$_ }) }
if ([bool]`$payload.CreateCwd) { `$detachedParams.CreateCwd = `$true }
`$module = Get-Module PSUnplugged
if (`$null -eq `$module) { throw 'PSUnplugged module is not loaded in worker process.' }
& `$module { param(`$p) New-PSUnpluggedManagedThread @p | Out-Null } `$detachedParams
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
    if (-not [string]::IsNullOrWhiteSpace($ProjectPath) -and (Test-Path -LiteralPath $ProjectPath)) {
        $startParams.WorkingDirectory = $ProjectPath
    }

    $process = Start-Process @startParams
    return [PSCustomObject]@{
        Process    = $process
        ParamsPath = $paramsPath
        ReadyPath  = $readyPath
        ScriptPath = $scriptPath
        StdOutPath = $stdoutPath
        StdErrPath = $stderrPath
    }
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
        [string]$Model = 'gpt-5.1-codex',
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
        [switch]$PassThruSession
    )

    process {
        $effectiveCwd = $Cwd
        if ([string]::IsNullOrWhiteSpace($effectiveCwd) -and $null -ne $InputObject) {
            if ($InputObject -is [string]) {
                $effectiveCwd = [string]$InputObject
            }
            elseif ($InputObject.PSObject) {
                foreach ($propertyName in 'Path', 'path', 'ProjectPath', 'projectPath', 'Cwd', 'cwd') {
                    $property = $InputObject.PSObject.Properties[$propertyName]
                    if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                        $effectiveCwd = [string]$property.Value
                        break
                    }
                }
            }
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

        $task = $null
        if ($taskParams.ContainsKey('Prompt')) {
            $workerParams = @{}
            foreach ($workerKey in 'Model', 'Cwd', 'ApprovalPolicy', 'SandboxType', 'Prompt', 'Name', 'Tags', 'CreateCwd') {
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
                Id              = if ($worker.Process) { 'pending-' + [string]$worker.Process.Id } else { 'pending' }
                TaskId          = $null
                ThreadId        = $null
                Name            = if (-not [string]::IsNullOrWhiteSpace($prompt)) { $prompt } else { $projectName }
                Project         = $projectName
                Path            = $effectiveCwd
                Status          = 'starting'
                ReadyFilePath   = [string]$worker.ReadyPath
                WorkerProcessId = if ($worker.Process) { $worker.Process.Id } else { $null }
                WorkerProcessName = if ($worker.Process) { $worker.Process.ProcessName } else { $null }
                WorkerStdOutPath = [string]$worker.StdOutPath
                WorkerStdErrPath = [string]$worker.StdErrPath
            }
            $task.PSObject.TypeNames.Insert(0, 'PSUnplugged.CodexTask')
        }
        else {
            $task = New-PSUnpluggedManagedThread @taskParams
        }

        if ($task) {
            return ($task | ConvertTo-CodexTaskOutput)
        }
    }
}

function Get-CodexTask {
    <#
    .SYNOPSIS
        Returns managed Codex tasks using task-first terminology.
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
        [switch]$LocalOnly,
        [int]$Limit = 25,
        [PSCustomObject]$Session,
        [Parameter(DontShow = $true)][string]$SpinnerStatus = 'Loading Codex tasks...'
    )

    process {
        Get-CodexThread @PSBoundParameters | ConvertTo-CodexTaskOutput
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
        [switch]$Transcript,
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
        $telemetryTypes = [System.Collections.Generic.List[string]]::new()
        if ($ShowTelemetry -or $ShowReasoning) { $telemetryTypes.Add('reasoning') }
        if ($ShowTelemetry -or $ShowTools) { $telemetryTypes.Add('tools') }
        if ($ShowTelemetry -or $ShowCommands) { $telemetryTypes.Add('commands') }
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

            @($items | Get-CodexTranscript @pipelineTranscriptParams)
        }
        else {
            @(
                Get-CodexTranscript @transcriptParams
            )
        }

        if ($Transcript) {
            if ($Text) {
                return @($transcriptItems | ForEach-Object { [string]$_.Text })
            }

            return @($transcriptItems)
        }

        $latestItems = foreach ($group in @($transcriptItems | Group-Object ThreadId)) {
            $ordered = @(
                $group.Group |
                    Sort-Object -Property @{ Expression = { $_.Timestamp } }, @{ Expression = { $_.Index } }
            )

            $latestAssistant = @(
                $ordered |
                    Where-Object {
                        $_.Role -eq 'assistant' -and
                        -not [string]::IsNullOrWhiteSpace([string]$_.Text)
                    }
            ) | Select-Object -Last 1

            if ($latestAssistant) {
                $latestAssistant
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
                $latestTextItem
                continue
            }
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
        [string]$Model = 'gpt-5.1-codex',
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
            Id      = $resolvedId
            Prompt  = $Prompt
            Model   = $Model
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
        $taskLookup = [ordered]@{}
        $seenTranscriptKeysByTask = @{}
        $lastHeartbeatAt = Get-Date
        $tailTelemetryTypes = [System.Collections.Generic.List[string]]::new()
        if ($ShowTelemetry -or $ShowReasoning) { $tailTelemetryTypes.Add('reasoning') }
        if ($ShowTelemetry -or $ShowTools) { $tailTelemetryTypes.Add('tools') }
        if ($ShowTelemetry -or $ShowCommands) { $tailTelemetryTypes.Add('commands') }
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

                $hasAssistantOutput = Test-CodexTranscriptHasAssistantOutput -Transcript $transcriptItems
                if (Test-CodexTaskCompletion -Task $task -Transcript $transcriptItems) {
                    $task | Add-Member -NotePropertyName Status -NotePropertyValue 'completed' -Force
                    $completed.Add($task)
                }
                elseif ((-not $hasAssistantOutput) -and (Test-CodexTaskWorkerCompleted -InputObject $taskHandle)) {
                    $task | Add-Member -NotePropertyName Status -NotePropertyValue 'completed' -Force
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
                    if ($deadline) {
                        $elapsedSeconds = [int]($TimeoutSec - ($deadline - $now).TotalSeconds)
                        if ($elapsedSeconds -lt 0) { $elapsedSeconds = $TimeoutSec }
                        Write-Host "[working | ${elapsedSeconds}s] No new task updates yet." -ForegroundColor DarkGray
                    }
                    else {
                        Write-Host '[working] No new task updates yet.' -ForegroundColor DarkGray
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

        Remove-CodexThread -ThreadId $resolvedTaskId -Purge:$Purge
    }
}

Update-TypeData -TypeName 'PSUnplugged.CodexProject' -DefaultDisplayPropertySet Name, Kind, LastActive -Force
Update-TypeData -TypeName 'PSUnplugged.CodexProject.Details' -DefaultDisplayPropertySet Name, Kind, ThreadSummary, LastActive -Force
Update-TypeData -TypeName 'PSUnplugged.CodexThread' -DefaultDisplayPropertySet Id, Name, Project, Status, When -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTask' -DefaultDisplayPropertySet Id, Name, Project, Status, When -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTranscriptItem' -DefaultDisplayPropertySet Role, Phase, When, Text -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTaskReceive' -DefaultDisplayPropertySet Id, Name, Project, Role, When, Text -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTaskTurn' -DefaultDisplayPropertySet TaskId, Prompt, Result -Force
Update-TypeData -TypeName 'PSUnplugged.CodexTranscriptPage' -DefaultDisplayPropertySet Path, ThreadCount, ItemCount, Opened -Force

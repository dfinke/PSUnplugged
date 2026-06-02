<#
.SYNOPSIS
    PowerShell client for the OpenAI Codex App Server (JSON-RPC over stdio).

.DESCRIPTION
    Spawns the native codex.exe app-server as a child process and communicates
    via newline-delimited JSON-RPC over stdin/stdout.

    Prerequisites:
      - npm i -g @openai/codex       (installs the native Rust binary)
      - codex login                   (authenticate once, OR pass -ApiKey)

    On Windows the npm package installs a .ps1/.cmd wrapper that delegates to
    the native binary buried inside node_modules. This module auto-discovers
    the real codex.exe so Process.Start works correctly.

    If auto-discovery fails you can:
      - Set $env:CODEX_EXE to the full path of codex.exe
      - Pass -CodexPath to Start-CodexSession
      - Find it manually:
          Get-ChildItem (npm root -g) -Recurse -Filter codex.exe |
            Where-Object { $_.Length -gt 1MB }

.EXAMPLE
    # Basic interactive usage
    $session = Start-CodexSession
    $thread  = New-CodexThread -Session $session -Cwd "C:\myproject"
    $result  = Invoke-CodexTurn -Session $session -ThreadId $thread.id -Text "Summarize this repo."
    Write-Host $result.AgentText
    Stop-CodexSession -Session $session

.EXAMPLE
    # One-liner: ask a question and get the answer
    $session = Start-CodexSession
    $answer  = Invoke-CodexQuestion -Session $session -Text "What does main.py do?"
    Write-Host $answer
    Stop-CodexSession -Session $session
#>

# Load the higher-level thread/project helpers before public functions are defined.
$threadModulePath = Join-Path $PSScriptRoot 'Threads\PSUnplugged.Threads.psm1'
if (Test-Path -LiteralPath $threadModulePath) {
    Import-Module -Name $threadModulePath -Scope Local -DisableNameChecking -Force
}

$threadFormatPath = Join-Path $PSScriptRoot 'Threads\PSUnplugged.Threads.Format.ps1xml'
if (Test-Path -LiteralPath $threadFormatPath) {
    Update-FormatData -PrependPath $threadFormatPath -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────
# Session management
# ─────────────────────────────────────────────────────────────

function New-CodexMessageRouter {
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        Sync                     = [object]::new()
        ResponseWaiters          = [hashtable]::Synchronized(@{})
        TurnQueues               = [hashtable]::Synchronized(@{})
        PendingTurnNotifications = [hashtable]::Synchronized(@{})
        LoginQueues              = [hashtable]::Synchronized(@{})
        PendingLoginNotifications = [hashtable]::Synchronized(@{})
        GlobalNotifications      = [System.Collections.Concurrent.BlockingCollection[object]]::new()
        TransportError           = $null
    }
}

function Get-CodexMessageTurnId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Message
    )

    $params = $Message.params
    if (-not $params) { return $null }

    foreach ($propertyName in 'turnId', 'turn_id') {
        $property = $params.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    $turnProperty = $params.PSObject.Properties['turn']
    if ($turnProperty -and $turnProperty.Value) {
        foreach ($propertyName in 'id', 'Id') {
            $property = $turnProperty.Value.PSObject.Properties[$propertyName]
            if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                return [string]$property.Value
            }
        }
    }

    return $null
}

function Get-CodexMessageLoginId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Message
    )

    if ($Message.method -ne 'account/login/completed') {
        return $null
    }

    $params = $Message.params
    if (-not $params) { return $null }

    foreach ($propertyName in 'loginId', 'login_id') {
        $property = $params.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return $null
}

function Write-CodexRouterQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Queue,
        [Parameter(Mandatory)]$Item
    )

    if ($Queue -is [System.Collections.Concurrent.BlockingCollection[object]]) {
        $Queue.Add($Item)
        return
    }

    throw "Unsupported Codex router queue type: $($Queue.GetType().FullName)"
}

function Register-CodexTurnQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)][string]$TurnId
    )

    if (-not $Session.Router) { return }

    $router = $Session.Router
    [System.Threading.Monitor]::Enter($router.Sync)
    try {
        if (-not $router.TurnQueues.ContainsKey($TurnId)) {
            $router.TurnQueues[$TurnId] = [System.Collections.Concurrent.BlockingCollection[object]]::new()
        }

        $queue = $router.TurnQueues[$TurnId]
        if ($router.PendingTurnNotifications.ContainsKey($TurnId)) {
            $pending = @($router.PendingTurnNotifications[$TurnId])
            $router.PendingTurnNotifications.Remove($TurnId)
            foreach ($notification in $pending) {
                Write-CodexRouterQueue -Queue $queue -Item $notification
            }
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($router.Sync)
    }
}

function Unregister-CodexTurnQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)][string]$TurnId
    )

    if (-not $Session.Router) { return }

    $router = $Session.Router
    [System.Threading.Monitor]::Enter($router.Sync)
    try {
        if ($router.TurnQueues.ContainsKey($TurnId)) {
            $router.TurnQueues[$TurnId].CompleteAdding()
            $router.TurnQueues.Remove($TurnId)
        }
        if ($router.PendingTurnNotifications.ContainsKey($TurnId)) {
            $router.PendingTurnNotifications.Remove($TurnId)
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($router.Sync)
    }
}

function Add-CodexRouterNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)]$Message
    )

    $router = $Session.Router
    if (-not $router) { return }

    $loginId = Get-CodexMessageLoginId -Message $Message
    if ($loginId) {
        [System.Threading.Monitor]::Enter($router.Sync)
        try {
            if ($router.LoginQueues.ContainsKey($loginId)) {
                Write-CodexRouterQueue -Queue $router.LoginQueues[$loginId] -Item $Message
                return
            }

            if (-not $router.PendingLoginNotifications.ContainsKey($loginId)) {
                $router.PendingLoginNotifications[$loginId] = [System.Collections.Generic.List[object]]::new()
            }
            $router.PendingLoginNotifications[$loginId].Add($Message)
            return
        }
        finally {
            [System.Threading.Monitor]::Exit($router.Sync)
        }
    }

    $turnId = Get-CodexMessageTurnId -Message $Message
    if ($turnId) {
        [System.Threading.Monitor]::Enter($router.Sync)
        try {
            if ($router.TurnQueues.ContainsKey($turnId)) {
                Write-CodexRouterQueue -Queue $router.TurnQueues[$turnId] -Item $Message
                return
            }

            if (-not $router.PendingTurnNotifications.ContainsKey($turnId)) {
                $router.PendingTurnNotifications[$turnId] = [System.Collections.Generic.List[object]]::new()
            }
            $router.PendingTurnNotifications[$turnId].Add($Message)
            return
        }
        finally {
            [System.Threading.Monitor]::Exit($router.Sync)
        }
    }

    Write-CodexRouterQueue -Queue $router.GlobalNotifications -Item $Message
}

function Complete-CodexRouter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Router,
        [Parameter(Mandatory)]$ErrorRecord
    )

    $Router.TransportError = $ErrorRecord
    [System.Threading.Monitor]::Enter($Router.Sync)
    try {
        foreach ($queue in @($Router.ResponseWaiters.Values)) {
            Write-CodexRouterQueue -Queue $queue -Item $ErrorRecord
        }
        $Router.ResponseWaiters.Clear()

        foreach ($queue in @($Router.TurnQueues.Values)) {
            Write-CodexRouterQueue -Queue $queue -Item $ErrorRecord
            $queue.CompleteAdding()
        }
        $Router.TurnQueues.Clear()
        $Router.PendingTurnNotifications.Clear()

        foreach ($queue in @($Router.LoginQueues.Values)) {
            Write-CodexRouterQueue -Queue $queue -Item $ErrorRecord
            $queue.CompleteAdding()
        }
        $Router.LoginQueues.Clear()
        $Router.PendingLoginNotifications.Clear()
    }
    finally {
        [System.Threading.Monitor]::Exit($Router.Sync)
    }

    Write-CodexRouterQueue -Queue $Router.GlobalNotifications -Item $ErrorRecord
}

function Read-CodexTransportMessage {
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
        return [PSCustomObject]@{ HasMessage = $false; Message = $null }
    }

    $line = $Session.PendingReadTask.Result
    $Session.PendingReadTask = $null
    if ($null -eq $line) {
        throw "codex app-server closed unexpectedly"
    }

    if ($Session.Verbose) {
        Write-Verbose "<<< $line"
    }

    return [PSCustomObject]@{ HasMessage = $true; Message = ($line | ConvertFrom-Json) }
}

function Route-CodexTransportMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)]$Message
    )

    $router = $Session.Router
    if (-not $router) { return }

    if ($null -ne $Message.id -and -not $Message.method) {
        $requestId = [string]$Message.id
        $waiter = $null
        [System.Threading.Monitor]::Enter($router.Sync)
        try {
            if ($router.ResponseWaiters.ContainsKey($requestId)) {
                $waiter = $router.ResponseWaiters[$requestId]
                $router.ResponseWaiters.Remove($requestId)
            }
        }
        finally {
            [System.Threading.Monitor]::Exit($router.Sync)
        }

        if ($waiter) {
            Write-CodexRouterQueue -Queue $waiter -Item $Message
        }
        return
    }

    if ($Message.method -and $null -ne $Message.id) {
        $response = @{
            id     = $Message.id
            result = @{ decision = 'accept' }
        }
        $json = $response | ConvertTo-Json -Depth 20 -Compress
        Write-Verbose ">>> $json (server request)"
        $Session.Writer.WriteLine($json)
        $Session.Writer.Flush()
        return
    }

    if ($Message.method) {
        Add-CodexRouterNotification -Session $Session -Message $Message
    }
}

function Receive-CodexQueueItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Queue,
        [int]$TimeoutMs
    )

    $item = $null
    if ($PSBoundParameters.ContainsKey('TimeoutMs')) {
        if (-not $Queue.TryTake([ref]$item, $TimeoutMs)) {
            return [PSCustomObject]@{ HasItem = $false; Item = $null }
        }
    }
    else {
        $item = $Queue.Take()
    }

    if ($item -is [System.Management.Automation.ErrorRecord]) {
        throw $item
    }

    return [PSCustomObject]@{ HasItem = $true; Item = $item }
}

function Resolve-CodexClientPath {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }
    catch {
        try {
            return [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            return $Path
        }
    }
}

function Start-CodexSession {
    <#
    .SYNOPSIS
        Launches codex app-server and performs the initialize handshake.
    .PARAMETER ClientName
        Identifier sent in clientInfo.name (default: "powershell_client").
    .PARAMETER ApiKey
        Optional OpenAI API key. If provided, login is performed after init.
    .PARAMETER CodexPath
        Path to the native codex.exe binary. If omitted, auto-discovered.
    #>
    [CmdletBinding()]
    param(
        [string]$ClientName = "powershell_client",
        [string]$ClientTitle = "PowerShell Codex Client",
        [string]$Version = "0.1.1",
        [string]$ApiKey,
        [string]$CodexPath = "codex"
    )

    # ── Resolve the native codex.exe binary ──
    $resolvedPath = $null

    if ($CodexPath -ne "codex") {
        # Explicit path provided
        if (-not (Test-Path $CodexPath)) {
            throw "Codex binary not found at: $CodexPath"
        }
        $resolvedPath = $CodexPath
    }
    else {
        # Auto-discovery

        # 1. Check CODEX_EXE environment variable
        if ($env:CODEX_EXE -and (Test-Path $env:CODEX_EXE)) {
            $resolvedPath = $env:CODEX_EXE
            Write-Verbose "Found codex via CODEX_EXE env var"
        }

        # 2. Search known npm global locations for the native binary
        if (-not $resolvedPath) {
            $npmRoots = @()
            $npmRoot = & npm root -g 2>$null
            if ($npmRoot) { $npmRoots += $npmRoot }
            if ($env:APPDATA) { $npmRoots += "$env:APPDATA\npm\node_modules" }
            if ($env:ProgramFiles) { $npmRoots += "$env:ProgramFiles\nodejs\node_modules" }

            foreach ($root in ($npmRoots | Select-Object -Unique)) {
                # x64
                $native = Join-Path $root "@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe"
                if (Test-Path $native) { $resolvedPath = $native; break }
                # arm64
                $native = Join-Path $root "@openai\codex\node_modules\@openai\codex-win32-arm64\vendor\aarch64-pc-windows-msvc\codex\codex.exe"
                if (Test-Path $native) { $resolvedPath = $native; break }
            }
        }

        # 3. Fallback: recursive search for the real binary (>1 MB, not a wrapper)
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

        # 4. On non-Windows, try Get-Command directly (the binary is the binary)
        if (-not $resolvedPath -and -not $IsWindows) {
            $cmd = Get-Command codex -ErrorAction SilentlyContinue
            if ($cmd) { $resolvedPath = $cmd.Source }
        }

        if (-not $resolvedPath) {
            throw @"
Cannot find the native codex.exe binary.
  1. Install:  npm i -g @openai/codex
  2. Or set:   `$env:CODEX_EXE = 'C:\path\to\codex.exe'
  3. Or pass:  Start-CodexSession -CodexPath 'C:\path\to\codex.exe'

  The binary is usually at:
    <npm-root>\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe
  Run 'npm root -g' to find your global npm directory.
  Or: Get-ChildItem (npm root -g) -Recurse -Filter codex.exe | Where-Object { `$_.Length -gt 1MB }
"@
        }
    }

    Write-Verbose "Using codex at: $resolvedPath"

    # ── Launch the process ──
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $startDirectory = Resolve-CodexClientPath -Path (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($startDirectory) -and (Test-Path -LiteralPath $startDirectory -PathType Container)) {
        $psi.WorkingDirectory = $startDirectory
    }

    if ($resolvedPath -match '\.ps1$') {
        # .ps1 npm wrapper — launch through pwsh/powershell
        $psi.FileName = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
        $psi.Arguments = "-NoProfile -NonInteractive -File `"$resolvedPath`" app-server --listen stdio://"
    }
    elseif ($resolvedPath -match '\.(cmd|bat)$') {
        # .cmd npm wrapper — launch through cmd
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c `"$resolvedPath`" app-server --listen stdio://"
    }
    else {
        # Native .exe — launch directly
        $psi.FileName = $resolvedPath
        $psi.Arguments = "app-server --listen stdio://"
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        throw "Failed to start codex app-server at '$resolvedPath': $_"
    }
    if (-not $proc) { throw "Failed to start codex app-server" }

    $session = [PSCustomObject]@{
        Process    = $proc
        Writer     = $proc.StandardInput
        Reader     = $proc.StandardOutput
        Router     = New-CodexMessageRouter
        PendingReadTask = $null
        NextId     = 1
        Verbose    = $VerbosePreference -ne 'SilentlyContinue'
    }

    # ── Initialize handshake ──
    $initResult = Send-CodexRequest -Session $session -Method "initialize" -Params @{
        clientInfo = @{
            name    = $ClientName
            title   = $ClientTitle
            version = $Version
        }
        capabilities = @{
            experimentalApi = $true
        }
    }
    Write-Verbose "Initialized: $($initResult | ConvertTo-Json -Depth 5)"

    # Send the required initialized notification
    Send-CodexNotification -Session $session -Method "initialized" -Params @{}

    # ── Optional API-key login ──
    if ($ApiKey) {
        $loginResult = Send-CodexRequest -Session $session -Method "account/login/start" -Params @{
            type   = "apiKey"
            apiKey = $ApiKey
        }
        # Drain the login/completed and account/updated notifications
        Read-CodexNotifications -Session $session -TimeoutMs 3000 | Out-Null
        Write-Verbose "Logged in with API key"
    }

    return $session
}

function Stop-CodexSession {
    <#
    .SYNOPSIS
        Gracefully shuts down the codex app-server process.
    #>
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
    Write-Verbose "Codex session stopped"
}

# ─────────────────────────────────────────────────────────────
# Low-level JSON-RPC helpers
# ─────────────────────────────────────────────────────────────

function Receive-CodexLine {
    <#
    .SYNOPSIS
        Reads one stdout line using a single shared async read task.
    .PARAMETER TimeoutMs
        Optional timeout for waiting on a line. If omitted, waits indefinitely.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [int]$TimeoutMs
    )

    if ($Session.Router) {
        $read = Receive-CodexQueueItem -Queue $Session.Router.GlobalNotifications -TimeoutMs $TimeoutMs
        if (-not $read.HasItem) {
            $readMessage = if ($PSBoundParameters.ContainsKey('TimeoutMs')) {
                Read-CodexTransportMessage -Session $Session -TimeoutMs $TimeoutMs
            }
            else {
                Read-CodexTransportMessage -Session $Session
            }

            if (-not $readMessage.HasMessage) {
                return [PSCustomObject]@{ HasLine = $false; Line = $null }
            }

            Route-CodexTransportMessage -Session $Session -Message $readMessage.Message
            $read = Receive-CodexQueueItem -Queue $Session.Router.GlobalNotifications -TimeoutMs 0
            if (-not $read.HasItem) {
                return [PSCustomObject]@{ HasLine = $false; Line = $null }
            }
        }

        $line = $read.Item | ConvertTo-Json -Depth 20 -Compress
        return [PSCustomObject]@{ HasLine = $true; Line = $line }
    }

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
    <#
    .SYNOPSIS
        Sends a JSON-RPC request and waits for the matching response.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{}
    )

    $id = $Session.NextId++
    $msg = @{ method = $Method; id = $id; params = $Params }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress
    Write-Verbose ">>> $json"

    if ($Session.Router) {
        $requestId = [string]$id
        $waiter = [System.Collections.Concurrent.BlockingCollection[object]]::new(1)
        [System.Threading.Monitor]::Enter($Session.Router.Sync)
        try {
            $Session.Router.ResponseWaiters[$requestId] = $waiter
        }
        finally {
            [System.Threading.Monitor]::Exit($Session.Router.Sync)
        }

        try {
            $Session.Writer.WriteLine($json)
            $Session.Writer.Flush()
        }
        catch {
            [System.Threading.Monitor]::Enter($Session.Router.Sync)
            try {
                $Session.Router.ResponseWaiters.Remove($requestId)
            }
            finally {
                [System.Threading.Monitor]::Exit($Session.Router.Sync)
            }
            throw
        }

        while ($waiter.Count -eq 0) {
            $readMessage = Read-CodexTransportMessage -Session $Session
            Route-CodexTransportMessage -Session $Session -Message $readMessage.Message
        }

        $response = (Receive-CodexQueueItem -Queue $waiter).Item
        if ($response.error) {
            throw "Codex error ($($response.error.code)): $($response.error.message)"
        }
        return $response.result
    }

    $Session.Writer.WriteLine($json)
    $Session.Writer.Flush()

    # Read lines until we get the response with our id
    while ($true) {
        $read = Receive-CodexLine -Session $Session
        $line = $read.Line
        if ($null -eq $line) { throw "codex app-server closed unexpectedly" }
        Write-Verbose "<<< $line"

        $parsed = $line | ConvertFrom-Json
        if ($null -ne $parsed.id -and $parsed.id -eq $id) {
            if ($parsed.error) {
                throw "Codex error ($($parsed.error.code)): $($parsed.error.message)"
            }
            return $parsed.result
        }
        # Otherwise it's a notification — store or ignore
    }
}

function Send-CodexNotification {
    <#
    .SYNOPSIS
        Sends a JSON-RPC notification (no id, no response expected).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{}
    )

    $msg = @{ method = $Method; params = $Params }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress
    Write-Verbose ">>> $json"
    $Session.Writer.WriteLine($json)
    $Session.Writer.Flush()
}

function Read-CodexNotifications {
    <#
    .SYNOPSIS
        Reads notifications/events from stdout until timeout or turn/completed.
    .PARAMETER WaitForTurnComplete
        If set, keeps reading until a turn/completed notification arrives.
    .PARAMETER TimeoutMs
        Maximum time to wait in milliseconds (default: 60000).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [int]$TimeoutMs = 60000,
        [switch]$WaitForTurnComplete,
        [string]$TurnId,
        [int]$PostCompletionDrainMs = 1000
    )

    $events = [System.Collections.Generic.List[PSObject]]::new()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $completionDrain = $null
    $registeredTurnId = $null
    $turnQueue = $null
    $pendingTurnIds = @()

    if ($Session.Router) {
        if (-not [string]::IsNullOrWhiteSpace($TurnId)) {
            $registeredTurnId = [string]$TurnId
        }
        else {
            [System.Threading.Monitor]::Enter($Session.Router.Sync)
            try {
                $pendingTurnIds = @($Session.Router.PendingTurnNotifications.Keys)
            }
            finally {
                [System.Threading.Monitor]::Exit($Session.Router.Sync)
            }
        }

        if ([string]::IsNullOrWhiteSpace($registeredTurnId) -and $pendingTurnIds.Count -gt 0) {
            $registeredTurnId = [string]@($pendingTurnIds)[0]
        }

        if (-not [string]::IsNullOrWhiteSpace($registeredTurnId)) {
            Register-CodexTurnQueue -Session $Session -TurnId $registeredTurnId
            $turnQueue = $Session.Router.TurnQueues[$registeredTurnId]
        }
    }

    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($completionDrain -and $completionDrain.ElapsedMilliseconds -ge $PostCompletionDrainMs) {
            break
        }

        $remaining = $TimeoutMs - [int]$sw.ElapsedMilliseconds
        if ($remaining -le 0) { break }

        # Wait in short slices but keep using a single in-flight read task.
        $slice = if ($completionDrain) { [Math]::Min(100, $remaining) } else { [Math]::Min(500, $remaining) }
        if (($null -ne $Session.Router) -and ($null -ne $turnQueue)) {
            $read = Receive-CodexQueueItem -Queue $turnQueue -TimeoutMs 0
            if (-not $read.HasItem) {
                try {
                    $readMessage = Read-CodexTransportMessage -Session $Session -TimeoutMs $slice
                    if (-not $readMessage.HasMessage) {
                        continue
                    }
                    Route-CodexTransportMessage -Session $Session -Message $readMessage.Message
                }
                catch {
                    throw
                }
                $read = Receive-CodexQueueItem -Queue $turnQueue -TimeoutMs $slice
                if (-not $read.HasItem) {
                    continue
                }
            }
            $parsed = $read.Item
        }
        else {
            $read = Receive-CodexLine -Session $Session -TimeoutMs $slice
            if (-not $read.HasLine) {
                continue
            }

            $line = $read.Line
            if ($null -eq $line) { break }
            Write-Verbose "<<< $line"

            $parsed = $line | ConvertFrom-Json
        }
        $events.Add($parsed)

        # Auto-accept approval requests (customize as needed)
        if ($parsed.method -eq "item/commandExecution/requestApproval" -or
            $parsed.method -eq "item/fileChange/requestApproval") {
            $approvalResponse = @{
                id     = $parsed.id
                result = @{ decision = "accept" }
            }
            $json = $approvalResponse | ConvertTo-Json -Depth 10 -Compress
            Write-Verbose ">>> $json (auto-approve)"
            $Session.Writer.WriteLine($json)
            $Session.Writer.Flush()
        }

        if ($WaitForTurnComplete -and $parsed.method -eq "turn/completed") {
            if (-not $completionDrain) {
                $completionDrain = [System.Diagnostics.Stopwatch]::StartNew()
            }
        }
    }

    if ($Session.Router -and $registeredTurnId) {
        Unregister-CodexTurnQueue -Session $Session -TurnId $registeredTurnId
    }

    return $events
}

# ─────────────────────────────────────────────────────────────
# Thread & Turn helpers
# ─────────────────────────────────────────────────────────────

function New-CodexThread {
    <#
    .SYNOPSIS
        Creates a new Codex conversation thread.
    .PARAMETER Model
        Model to use. If omitted, the Codex runtime default is used.
    .PARAMETER Cwd
        Working directory for the agent.
    .PARAMETER ApprovalPolicy
        When to pause for approval: never, on-request, unless-trusted.
    .PARAMETER SandboxType
        Sandbox policy: read-only, workspace-write, danger-full-access.
    .PARAMETER Prompt
        Optional first prompt to send after the thread is created.
    .PARAMETER Name
        Optional local display name used by the PowerShell thread catalog.
    .PARAMETER Tags
        Optional local tags used by the PowerShell thread catalog.
    .PARAMETER PassThruSession
        Keeps an auto-created session open and returns it on the thread object.
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Session,
        [string]$Model,
        [Parameter(ValueFromPipeline = $true, DontShow = $true)]
        $InputObject,
        [Alias('Path')]
        [string]$Cwd,
        [string]$ApprovalPolicy = "never",
        [ValidateSet("read-only", "workspace-write", "danger-full-access")]
        [string]$SandboxType = "workspace-write",
        [Parameter(Position = 0)]
        [string]$Prompt,
        [string]$Name,
        [string[]]$Tags,
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

        if (-not [string]::IsNullOrWhiteSpace($effectiveCwd)) {
            $effectiveCwd = Resolve-CodexClientPath -Path $effectiveCwd
        }

        $managedParams = @{}
        foreach ($entry in $PSBoundParameters.GetEnumerator()) {
            if ($entry.Key -eq 'InputObject') {
                continue
            }

            $managedParams[$entry.Key] = $entry.Value
        }

        if (-not [string]::IsNullOrWhiteSpace($effectiveCwd)) {
            $managedParams.Cwd = $effectiveCwd
        }
        elseif ($managedParams.ContainsKey('Cwd')) {
            $managedParams.Remove('Cwd')
        }

        $useManagedMode =
        $managedParams.ContainsKey('Prompt') -or
        $managedParams.ContainsKey('Name') -or
        $managedParams.ContainsKey('Tags') -or
        $PassThruSession -or
        ($null -ne $InputObject) -or
        -not $managedParams.ContainsKey('Session')

        if ($useManagedMode) {
            New-PSUnpluggedManagedThread @managedParams
        }
        else {
            $Model = Resolve-CodexRequestedModel -Session $Session -Model $Model
            $params = @{
                model          = $Model
                approvalPolicy = $ApprovalPolicy
                sandbox        = $SandboxType
            }
            if ($effectiveCwd) { $params.cwd = $effectiveCwd }

            $result = Send-CodexRequest -Session $Session -Method "thread/start" -Params $params
            # Drain the thread/started notification
            Read-CodexNotifications -Session $Session -TimeoutMs 1000 | Out-Null

            $result.thread
        }
    }
}

function New-PlaygroundProject {
    <#
    .SYNOPSIS
        Creates a new playground project with a shorter, pipeline-friendly name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [string]$ParentPath
    )

    if ($PSBoundParameters.ContainsKey('ParentPath')) {
        return (New-CodexPlaygroundProject -Name $Name -ParentPath $ParentPath)
    }

    return (New-CodexPlaygroundProject -Name $Name)
}

function Resume-CodexThread {
    <#
    .SYNOPSIS
        Resumes an existing thread by ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)][string]$ThreadId
    )

    $result = Send-CodexRequest -Session $Session -Method "thread/resume" -Params @{
        threadId = $ThreadId
    }
    return $result.thread
}

function Invoke-CodexTurn {
    <#
    .SYNOPSIS
        Sends user input to a thread, streams events, and returns the completed turn.
    .PARAMETER Text
        The user prompt text.
    .PARAMETER ImageUrl
        Optional image URL to include.
    .PARAMETER LocalImagePath
        Optional local image path to include.
    .PARAMETER TimeoutMs
        Max time to wait for turn completion (default: 120s).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)][string]$ThreadId,
        [Parameter(Mandatory)][string]$Text,
        [string]$ImageUrl,
        [string]$LocalImagePath,
        [string]$Model,
        [string]$Effort,
        [int]$TimeoutMs = 120000
    )

    $input = @( @{ type = "text"; text = $Text } )
    if ($ImageUrl) { $input += @{ type = "image"; url = $ImageUrl } }
    if ($LocalImagePath) { $input += @{ type = "localImage"; path = $LocalImagePath } }

    $Model = Resolve-CodexRequestedModel -Session $Session -Model $Model

    $params = @{
        threadId = $ThreadId
        input    = $input
    }
    if ($Model) { $params.model = $Model }
    if ($Effort) { $params.effort = $Effort }

    $turnResult = Send-CodexRequest -Session $Session -Method "turn/start" -Params $params
    $turnId = $turnResult.turn.id

    # Stream events until turn/completed
    $events = Read-CodexNotifications -Session $Session -TimeoutMs $TimeoutMs -WaitForTurnComplete -TurnId $turnId -PostCompletionDrainMs 1500

    # Extract the final turn state and agent text
    $completedEvent = $events | Where-Object { $_.method -eq "turn/completed" } | Select-Object -Last 1
    $agentDeltas = $events | Where-Object { $_.method -eq "item/agentMessage/delta" }
    $agentText = ($agentDeltas | ForEach-Object { $_.params.delta }) -join ""

    $items = $events | Where-Object { $_.method -eq "item/completed" } |
    ForEach-Object { $_.params.item }

    if ($completedEvent) {
        $hasAgentItem = @($items | Where-Object { $_.type -eq 'agentMessage' }).Count -gt 0
        if ((-not $hasAgentItem) -or [string]::IsNullOrWhiteSpace($agentText)) {
            try {
                Start-Sleep -Milliseconds 500
                $threadRecord = Send-CodexRequest -Session $Session -Method "thread/read" -Params @{
                    threadId     = $ThreadId
                    includeTurns = $true
                }

                $turnRecord = @($threadRecord.thread.turns | Where-Object { $_.id -eq $turnId }) | Select-Object -Last 1
                if (-not $turnRecord) {
                    $turnRecord = @($threadRecord.thread.turns) | Select-Object -Last 1
                }

                if ($turnRecord) {
                    $recordItems = @($turnRecord.items)
                    if ($recordItems.Count -gt 0) {
                        $items = $recordItems
                    }

                    $recordAgentMessages = @(
                        $recordItems |
                        Where-Object { $_.type -eq 'agentMessage' } |
                        ForEach-Object { [string]$_.text } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    )
                    if ($recordAgentMessages.Count -gt 0) {
                        $agentText = ($recordAgentMessages -join "`n`n")
                    }
                }
            }
            catch {
            }
        }
    }

    return [PSCustomObject]@{
        TurnId    = $turnId
        Status    = if ($completedEvent) { $completedEvent.params.turn.status } else { "unknown" }
        AgentText = $agentText
        Items     = $items
        Events    = $events
        Turn      = if ($completedEvent) { $completedEvent.params.turn } else { $null }
    }
}

function Invoke-CodexQuestion {
    <#
    .SYNOPSIS
        Convenience: creates a thread, asks a question, returns the answer text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][PSCustomObject]$Session,
        [Parameter(Mandatory)][string]$Text,
        [string]$Model,
        [string]$Cwd
    )

    $thread = New-CodexThread -Session $Session -Model $Model -Cwd $Cwd
    $result = Invoke-CodexTurn -Session $Session -ThreadId $thread.id -Text $Text -Model $Model
    return $result.AgentText
}

# ─────────────────────────────────────────────────────────────
# Utility functions
# ─────────────────────────────────────────────────────────────

function Get-CodexThreads {
    <#
    .SYNOPSIS
        Lists stored threads with optional pagination.
    #>
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

function Get-CodexModels {
    <#
    .SYNOPSIS
        Lists available models.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session
    )

    return Send-CodexRequest -Session $Session -Method "model/list" -Params @{}
}

function Invoke-CodexCommand {
    <#
    .SYNOPSIS
        Runs a command in the Codex sandbox (no thread needed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)][string[]]$Command,
        [string]$Cwd,
        [int]$TimeoutMs = 10000
    )

    $params = @{
        command   = $Command
        timeoutMs = $TimeoutMs
    }
    if ($Cwd) { $params.cwd = Resolve-CodexClientPath -Path $Cwd }

    return Send-CodexRequest -Session $Session -Method "command/exec" -Params $params
}

function Get-CodexAccount {
    <#
    .SYNOPSIS
        Returns current auth state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session
    )

    return Send-CodexRequest -Session $Session -Method "account/read" -Params @{
        refreshToken = $false
    }
}

# ─────────────────────────────────────────────────────────────
# Export
# ─────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Start-CodexSession'
    'Stop-CodexSession'
    'Start-CodexTask'
    'New-CodexThread'
    'Get-CodexApproval'
    'Get-CodexArtifact'
    'Get-CodexEvent'
    'Get-CodexTask'
    'Get-CodexThread'
    'ConvertTo-CodexTaskDashboardData'
    'Receive-CodexTask'
    'Wait-CodexTask'
    'Get-CodexTranscript'
    'Show-CodexTaskDashboard'
    'Show-CodexTranscript'
    'Set-CodexThread'
    'Remove-CodexTask'
    'Remove-CodexThread'
    'Resume-CodexTask'
    'Enter-CodexThread'
    'Resume-CodexThread'
    'Invoke-CodexTurn'
    'Invoke-CodexQuestion'
    'Get-CodexThreads'
    'Get-CodexProject'
    'New-CodexProject'
    'New-PlaygroundProject'
    'New-CodexPlaygroundProject'
    'Get-CodexModels'
    'Invoke-CodexCommand'
    'Get-CodexAccount'
    'Send-CodexRequest'
    'Send-CodexNotification'
    'Read-CodexNotifications'
)

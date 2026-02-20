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

# ─────────────────────────────────────────────────────────────
# Session management
# ─────────────────────────────────────────────────────────────

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
        [string]$Version = "0.1.0",
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
    if ($resolvedPath -match '\.ps1$') {
        # .ps1 npm wrapper — launch through pwsh/powershell
        $psi.FileName = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
        $psi.Arguments = "-NoProfile -NonInteractive -File `"$resolvedPath`" app-server"
    }
    elseif ($resolvedPath -match '\.(cmd|bat)$') {
        # .cmd npm wrapper — launch through cmd
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c `"$resolvedPath`" app-server"
    }
    else {
        # Native .exe — launch directly
        $psi.FileName = $resolvedPath
        $psi.Arguments = "app-server"
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
        Process         = $proc
        Writer          = $proc.StandardInput
        Reader          = $proc.StandardOutput
        PendingReadTask = $null
        NextId          = 1
        Verbose         = $VerbosePreference -ne 'SilentlyContinue'
    }

    # ── Initialize handshake ──
    $initResult = Send-CodexRequest -Session $session -Method "initialize" -Params @{
        clientInfo = @{
            name    = $ClientName
            title   = $ClientTitle
            version = $Version
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
        [switch]$WaitForTurnComplete
    )

    $events = [System.Collections.Generic.List[PSObject]]::new()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $remaining = $TimeoutMs - [int]$sw.ElapsedMilliseconds
        if ($remaining -le 0) { break }

        # Wait in short slices but keep using a single in-flight read task.
        $slice = [Math]::Min(500, $remaining)
        $read = Receive-CodexLine -Session $Session -TimeoutMs $slice
        if (-not $read.HasLine) { continue }

        $line = $read.Line
        if ($null -eq $line) { break }
        Write-Verbose "<<< $line"

        $parsed = $line | ConvertFrom-Json
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
            break
        }
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
        Model to use (default: gpt-5.1-codex).
    .PARAMETER Cwd
        Working directory for the agent.
    .PARAMETER ApprovalPolicy
        When to pause for approval: never, on-request, unless-trusted.
    .PARAMETER SandboxType
        Sandbox policy: read-only, workspace-write, danger-full-access.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [string]$Model = "gpt-5.1-codex",
        [string]$Cwd,
        [string]$ApprovalPolicy = "never",
        [ValidateSet("read-only", "workspace-write", "danger-full-access")]
        [string]$SandboxType = "workspace-write"
    )

    $params = @{
        model          = $Model
        approvalPolicy = $ApprovalPolicy
        sandbox        = $SandboxType
    }
    if ($Cwd) { $params.cwd = $Cwd }

    $result = Send-CodexRequest -Session $Session -Method "thread/start" -Params $params
    # Drain the thread/started notification
    Read-CodexNotifications -Session $Session -TimeoutMs 1000 | Out-Null

    return $result.thread
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

    $params = @{
        threadId = $ThreadId
        input    = $input
    }
    if ($Model) { $params.model = $Model }
    if ($Effort) { $params.effort = $Effort }

    $turnResult = Send-CodexRequest -Session $Session -Method "turn/start" -Params $params
    $turnId = $turnResult.turn.id

    # Stream events until turn/completed
    $events = Read-CodexNotifications -Session $Session -TimeoutMs $TimeoutMs -WaitForTurnComplete

    # Extract the final turn state and agent text
    $completedEvent = $events | Where-Object { $_.method -eq "turn/completed" } | Select-Object -Last 1
    $agentDeltas = $events | Where-Object { $_.method -eq "item/agentMessage/delta" }
    $agentText = ($agentDeltas | ForEach-Object { $_.params.delta }) -join ""

    $items = $events | Where-Object { $_.method -eq "item/completed" } |
    ForEach-Object { $_.params.item }

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
        [string]$Model = "gpt-5.1-codex",
        [string]$Cwd
    )

    $thread = New-CodexThread -Session $Session -Model $Model -Cwd $Cwd
    $result = Invoke-CodexTurn -Session $Session -ThreadId $thread.id -Text $Text
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
    if ($Cwd) { $params.cwd = $Cwd }

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
    'New-CodexThread'
    'Resume-CodexThread'
    'Invoke-CodexTurn'
    'Invoke-CodexQuestion'
    'Get-CodexThreads'
    'Get-CodexModels'
    'Invoke-CodexCommand'
    'Get-CodexAccount'
    'Send-CodexRequest'
    'Send-CodexNotification'
    'Read-CodexNotifications'
)
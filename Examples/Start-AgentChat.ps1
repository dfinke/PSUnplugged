<#
.SYNOPSIS
    Interactive chat with OpenAI Codex App Server from PowerShell.

.DESCRIPTION
    A standalone REPL that connects to the Codex App Server and lets you
    have a multi-turn conversation. Type your messages, get responses,
    and the full conversation history is maintained in a single thread.

    Prerequisites:
      - npm i -g @openai/codex
      - codex.exe login   (authenticate once via the native binary)
      - Set $env:CODEX_EXE to the native binary path (or edit $CodexExe below)

    Usage:
      .\Examples\Start-AgentChat.ps1
      .\Examples\Start-AgentChat.ps1 -Model "gpt-5.1-codex" -Cwd "D:\myproject"
      .\Examples\Start-AgentChat.ps1 -Model "gpt-4.1" -ApiKey $env:OPENAI_API_KEY

    Commands inside the chat:
      /quit, /exit, /q   - end the session
      /new               - start a fresh thread
      /model <name>      - switch model
      /verbose           - toggle verbose JSON-RPC output
#>

param(
    [string]$Model = "gpt-5.1-codex",
    [string]$Cwd = (Get-Location).Path,
    [string]$CodexExe = $env:CODEX_EXE,
    [string]$ApiKey
)


Import-Module $PSScriptRoot\..\ShowMarkdown.psm1 -Force

# ─────────────────────────────────────────────────────────────
# Embedded minimal client (no module dependency)
# ─────────────────────────────────────────────────────────────

$script:Verbose = $false
$script:NextId = 1

function Find-CodexBinary {
    param([string]$Hint)

    if ($Hint -and (Test-Path $Hint)) { return $Hint }

    # Search npm global
    $npmRoot = & npm root -g 2>$null
    if ($npmRoot) {
        $native = Join-Path $npmRoot "@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe"
        if (Test-Path $native) { return $native }
        # arm64
        $native = Join-Path $npmRoot "@openai\codex\node_modules\@openai\codex-win32-arm64\vendor\aarch64-pc-windows-msvc\codex\codex.exe"
        if (Test-Path $native) { return $native }
        # Fallback: recursive
        $found = Get-ChildItem (Join-Path $npmRoot "@openai\codex") -Recurse -Filter "codex.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 1MB } | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    # Non-Windows
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

function Send-Request {
    param($Writer, $Reader, [string]$Method, [hashtable]$Params = @{})

    $id = $script:NextId++
    $msg = @{ method = $Method; id = $id; params = $Params }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress
    if ($script:Verbose) { Write-Host "  >>> $json" -ForegroundColor DarkGray }
    $Writer.WriteLine($json)
    $Writer.Flush()

    while ($true) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) { throw "codex app-server closed unexpectedly" }
        if ($script:Verbose) { Write-Host "  <<< $line" -ForegroundColor DarkGray }

        $parsed = $line | ConvertFrom-Json
        if ($null -ne $parsed.id -and $parsed.id -eq $id) {
            if ($parsed.error) {
                throw "Codex error ($($parsed.error.code)): $($parsed.error.message)"
            }
            return $parsed.result
        }
    }
}

function Send-Notification {
    param($Writer, [string]$Method, [hashtable]$Params = @{})

    $msg = @{ method = $Method; params = $Params }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress
    if ($script:Verbose) { Write-Host "  >>> $json" -ForegroundColor DarkGray }
    $Writer.WriteLine($json)
    $Writer.Flush()
}

function Read-TurnEvents {
    param($Writer, $Reader)

    $agentText = ""

    while ($true) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) { break }
        if ($script:Verbose) { Write-Host "  <<< $line" -ForegroundColor DarkGray }

        $parsed = $line | ConvertFrom-Json

        # Accumulate agent text deltas; rendering happens after completion.
        if ($parsed.method -eq "item/agentMessage/delta") {
            $delta = $parsed.params.delta
            if ($delta) {
                $agentText += $delta
            }
        }

        # Auto-accept approvals
        if ($parsed.method -eq "item/commandExecution/requestApproval" -or
            $parsed.method -eq "item/fileChange/requestApproval") {
            $resp = @{ id = $parsed.id; result = @{ decision = "accept" } }
            $json = $resp | ConvertTo-Json -Depth 10 -Compress
            $Writer.WriteLine($json)
            $Writer.Flush()
        }

        # Show command executions only in verbose mode
        if ($parsed.method -eq "item/started" -and $parsed.params.item.type -eq "commandExecution") {
            $cmd = $parsed.params.item.command
            if ($cmd -and $script:Verbose) {
                Write-Host "`n  > $cmd" -ForegroundColor DarkYellow
            }
        }

        # Show errors
        if ($parsed.method -eq "error" -and $parsed.params.willRetry -eq $false) {
            Write-Host "`n[Error] $($parsed.params.error.message)" -ForegroundColor Red
        }

        # Done
        if ($parsed.method -eq "turn/completed") {
            return $agentText
        }
    }

    Write-Host "`n[Disconnected]" -ForegroundColor Yellow
    return $agentText
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

$binary = Find-CodexBinary -Hint $CodexExe
if (-not $binary) {
    Write-Host "Cannot find codex.exe. Set `$env:CODEX_EXE or install: npm i -g @openai/codex" -ForegroundColor Red
    exit 1
}

Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Codex Chat  -  PowerShell Edition      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Binary:  $binary" -ForegroundColor DarkGray
Write-Host "  Model:   $Model" -ForegroundColor DarkGray
Write-Host "  Cwd:     $Cwd" -ForegroundColor DarkGray
Write-Host "  Commands: /quit /new /model <name> /verbose" -ForegroundColor DarkGray
Write-Host ""

# Launch app-server
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $binary
$psi.Arguments = "app-server"
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

try { $proc = [System.Diagnostics.Process]::Start($psi) }
catch { Write-Host "Failed to start app-server: $_" -ForegroundColor Red; exit 1 }

$w = $proc.StandardInput
$r = [System.IO.StreamReader]::new($proc.StandardOutput.BaseStream, [System.Text.Encoding]::UTF8)

# Ensure console can render UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Initialize
$initResult = Send-Request -Writer $w -Reader $r -Method "initialize" -Params @{
    clientInfo = @{
        name    = "powershell_chat"
        title   = "PowerShell Codex Chat"
        version = "1.0.0"
    }
}
Send-Notification -Writer $w -Method "initialized"

# Log in with API key if provided (overrides any stored ChatGPT account auth)
if ($ApiKey) {
    Send-Request -Writer $w -Reader $r -Method "account/login/start" -Params @{
        type   = "apiKey"
        apiKey = $ApiKey
    } | Out-Null
    # Drain login/completed and account/updated notifications
    $r.ReadLine() | Out-Null
    $r.ReadLine() | Out-Null
    Write-Host "  Auth:    API key" -ForegroundColor DarkGray
}

Write-Host "  Connected!" -ForegroundColor Green
Write-Host ""

# Start first thread
function Start-NewThread {
    $result = Send-Request -Writer $w -Reader $r -Method "thread/start" -Params @{
        model          = $script:Model
        approvalPolicy = "never"
        sandbox        = "workspace-write"
        cwd            = $script:Cwd
    }
    # Drain thread/started and mcp_startup_complete notifications
    $r.ReadLine() | Out-Null
    $r.ReadLine() | Out-Null

    return $result.thread.id
}

$threadId = Start-NewThread
$turnCount = 0

# Chat loop
while ($true) {
    Write-Host "You: " -ForegroundColor Yellow -NoNewline
    $userInput = Read-Host

    if ([string]::IsNullOrWhiteSpace($userInput)) { continue }

    # Handle commands
    switch -Regex ($userInput.Trim()) {
        '^/(quit|exit|q)$' {
            Write-Host "`nGoodbye!" -ForegroundColor Cyan
            try { $w.Close(); $proc.WaitForExit(3000); $proc.Kill() } catch { }
            $proc.Dispose()
            exit 0
        }
        '^/new$' {
            $threadId = Start-NewThread
            $turnCount = 0
            Write-Host "  [New thread started]" -ForegroundColor DarkCyan
            continue
        }
        '^/model\s+(.+)$' {
            $script:Model = $Matches[1]
            $threadId = Start-NewThread
            $turnCount = 0
            Write-Host "  [Model switched to $($script:Model), new thread started]" -ForegroundColor DarkCyan
            continue
        }
        '^/verbose$' {
            $script:Verbose = -not $script:Verbose
            Write-Host "  [Verbose: $($script:Verbose)]" -ForegroundColor DarkCyan
            continue
        }
    }

    # Send turn
    $turnCount++
    Write-Host ""

    try {
        $turnResult = Send-Request -Writer $w -Reader $r -Method "turn/start" -Params @{
            threadId = $threadId
            input    = @( @{ type = "text"; text = $userInput } )
        }

        $response = Read-TurnEvents -Writer $w -Reader $r
        Show-Markdown $response
    }
    catch {
        Write-Host "[Error] $_" -ForegroundColor Red
    }

    Write-Host ""
}

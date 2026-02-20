<#
.SYNOPSIS
    Examples: Talking to Codex App Server from PowerShell

.DESCRIPTION
    Prerequisites:
      1. npm i -g @openai/codex
      2. codex login                    # authenticate once
      3. Import-Module .\PSUnplugged.psm1

    The module auto-discovers the native codex.exe inside node_modules.
    If it fails, set $env:CODEX_EXE or pass -CodexPath:

      $env:CODEX_EXE = "D:\npm-global\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe"

    To find your binary:
      Get-ChildItem (npm root -g) -Recurse -Filter codex.exe | Where-Object { $_.Length -gt 1MB }
#>

Import-Module $PSScriptRoot\..\PSUnplugged.psm1 -Force

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Example 1: Quick question
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n=== Example 1: Quick Question ===" -ForegroundColor Cyan

$session = Start-CodexSession
$answer = Invoke-CodexQuestion -Session $session -Text "What is the capital of France?"
Write-Host "Answer: $answer"
Stop-CodexSession -Session $session

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Example 2: Multi-turn conversation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n=== Example 2: Multi-turn ===" -ForegroundColor Cyan

$session = Start-CodexSession
$thread = New-CodexThread -Session $session -Cwd (Get-Location).Path

$r1 = Invoke-CodexTurn -Session $session -ThreadId $thread.id -Text "List the files in this directory"
Write-Host "Turn 1:`n$($r1.AgentText)"

$r2 = Invoke-CodexTurn -Session $session -ThreadId $thread.id -Text "Now explain what each file does"
Write-Host "Turn 2:`n$($r2.AgentText)"

Stop-CodexSession -Session $session

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Example 3: Run a sandboxed command
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n=== Example 3: Sandboxed Command ===" -ForegroundColor Cyan

$session = Start-CodexSession
$cmdResult = Invoke-CodexCommand -Session $session -Command @("git", "status") -Cwd (Get-Location).Path
Write-Host "Exit code: $($cmdResult.exitCode)"
Write-Host "Output:`n$($cmdResult.stdout)"
Stop-CodexSession -Session $session

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Example 4: API key auth (no prior login needed)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n=== Example 4: API Key Auth ===" -ForegroundColor Cyan
Write-Host "(Uncomment and set OPENAI_API_KEY to run)"

# $session = Start-CodexSession -ApiKey $env:OPENAI_API_KEY
# $answer  = Invoke-CodexQuestion -Session $session -Text "Hello from PowerShell!"
# Write-Host $answer
# Stop-CodexSession -Session $session

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Example 5: Explicit binary path
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n=== Example 5: Explicit Path ===" -ForegroundColor Cyan
Write-Host "(Uncomment and adjust path for your system)"

# $session = Start-CodexSession -CodexPath "D:\npm-global\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe"
# $answer  = Invoke-CodexQuestion -Session $session -Text "Hello!"
# Write-Host $answer
# Stop-CodexSession -Session $session

# Or set once in your $PROFILE:
# $env:CODEX_EXE = "D:\npm-global\...\codex.exe"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Example 6: List threads, models, and account info
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n=== Example 6: List Threads & Models ===" -ForegroundColor Cyan

$session = Start-CodexSession

$models = Get-CodexModels -Session $session
Write-Host "Available models:" ($models | ConvertTo-Json -Depth 10)

$threads = Get-CodexThreads -Session $session -Limit 5
Write-Host "Recent threads:" ($threads | ConvertTo-Json -Depth 10)

$account = Get-CodexAccount -Session $session
Write-Host "Account:" ($account | ConvertTo-Json -Depth 10)

Stop-CodexSession -Session $session

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Example 7: Verbose mode (see all JSON-RPC traffic)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n=== Example 7: Verbose ===" -ForegroundColor Cyan
Write-Host "(Set `$VerbosePreference = 'Continue' to see raw JSON-RPC messages)"

# $VerbosePreference = "Continue"
# $session = Start-CodexSession
# Invoke-CodexQuestion -Session $session -Text "Say hi" | Write-Host
# Stop-CodexSession -Session $session
# $VerbosePreference = "SilentlyContinue"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Example 8: Raw low-level JSON-RPC
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n=== Example 8: Raw JSON-RPC ===" -ForegroundColor Cyan
Write-Host @"

  `$session = Start-CodexSession
  `$result  = Send-CodexRequest -Session `$session -Method "thread/start" -Params @{
      model = "gpt-5.1-codex"
  }
  `$events  = Read-CodexNotifications -Session `$session -TimeoutMs 5000
  Stop-CodexSession -Session `$session
"@

Write-Host "`nDone!" -ForegroundColor Green

<#
.SYNOPSIS
    Boardroom-grade repo brief demo for PSUnplugged.

.DESCRIPTION
    Starts one managed Codex task that inspects the target repository and returns
    an opinionated technical brief. This makes a strong opening demo because it
    shows the Start / Wait / Receive flow without needing any setup files.
#>

[CmdletBinding()]
param(
    [Alias('Path')]
    [string]$Cwd = (Get-Location).Path,
    [string]$Model = 'gpt-5.2',
    [int]$TimeoutSec = 900,
    [switch]$ShowTelemetry
)

Import-Module $PSScriptRoot\..\PSUnplugged.psd1 -Force

$resolvedCwd = (Resolve-Path -LiteralPath $Cwd).Path
$prompt = @'
Read this repository like a CTO and a PowerShell maintainer standing at the same whiteboard.

Return a stage-ready briefing with these exact sections:

1. The One-Liner
   Explain what this project is in one sentence a non-specialist can repeat.
2. The "Why Now" Moment
   Say why a PowerShell-native agent control plane matters.
3. What To Show Live
   Give three commands worth typing on stage and what each proves.
4. Credibility Check
   Name one real limitation or risk you noticed in the repo.
5. Closer
   Give a punchy final line that connects agents to the PowerShell job model.

Keep it concrete. Cite file paths when useful. Do not write marketing fluff.
'@

Write-Host ''
Write-Host 'Boardroom Brief' -ForegroundColor Cyan
Write-Host "Cwd: $resolvedCwd" -ForegroundColor DarkGray
Write-Host ''

$task = Start-CodexTask -Cwd $resolvedCwd -Model $Model -Name 'boardroom-brief' -Tags demo,brief,stage -Prompt $prompt
$task | Format-Table -AutoSize

$waitParams = @{
    TimeoutSec = $TimeoutSec
    Tail       = $true
}
if ($ShowTelemetry) {
    $waitParams.ShowReasoning = $true
    $waitParams.ShowTools = $true
    $waitParams.ShowCommands = $true
}

$done = $task | Wait-CodexTask @waitParams
Write-Host ''
Write-Host 'Latest useful output' -ForegroundColor Cyan
$done | Receive-CodexTask -Text

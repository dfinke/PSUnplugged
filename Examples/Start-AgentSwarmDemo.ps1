<#
.SYNOPSIS
    Fan out several specialist Codex tasks and collect the results.

.DESCRIPTION
    Demonstrates a high-signal task-first workflow with multiple independent
    specialist prompts. This is a stage-ready demo: PowerShell starts governed
    agent work like jobs, then receives each result through the same pipeline.
#>

[CmdletBinding()]
param(
    [Alias('Path')]
    [string]$Cwd = (Get-Location).Path,
    [string]$Model = 'gpt-5.2',
    [int]$TimeoutSec = 900
)

Import-Module $PSScriptRoot\..\PSUnplugged.psd1 -Force

$resolvedCwd = (Resolve-Path -LiteralPath $Cwd).Path
$prompts = @(
    [pscustomobject]@{
        Name   = 'maintainer-risk-scan'
        Tags   = @('demo', 'risk')
        Prompt = 'Act as the maintainer. Inspect the repo for the three risks most likely to embarrass a live demo. Return exact files or commands to check, plus a mitigation for each.'
    }
    [pscustomobject]@{
        Name   = 'operator-story'
        Tags   = @('demo', 'operator')
        Prompt = 'Act as a PowerShell operator. Turn the exported commands into a compelling Start/Inspect/Receive/Resume story. Include a five-command live sequence.'
    }
    [pscustomobject]@{
        Name   = 'skeptic-questions'
        Tags   = @('demo', 'skeptic')
        Prompt = 'Act as a skeptical enterprise engineer. Ask the five hardest questions about this project, then answer each using evidence from the repo where possible.'
    }
    [pscustomobject]@{
        Name   = 'demo-producer'
        Tags   = @('demo', 'stage')
        Prompt = 'Act as a demo producer. Create a 90-second talk track that makes this repo feel urgent and practical. Include exact terminal beats and the point each beat proves.'
    }
)

Write-Host ''
Write-Host 'Agent Swarm' -ForegroundColor Cyan
Write-Host "Cwd: $resolvedCwd" -ForegroundColor DarkGray
Write-Host ''

$tasks = foreach ($item in $prompts) {
    Start-CodexTask -Cwd $resolvedCwd -Model $Model -Name $item.Name -Tags $item.Tags -Prompt $item.Prompt
}

$tasks | Format-Table -AutoSize

Write-Host ''
Write-Host 'Waiting for tasks...' -ForegroundColor DarkGray
$done = $tasks | Wait-CodexTask -Tail -TimeoutSec $TimeoutSec

Write-Host ''
Write-Host 'Results' -ForegroundColor Cyan
foreach ($task in $done) {
    Write-Host ''
    Write-Host "## $($task.Name)" -ForegroundColor Yellow
    $task | Receive-CodexTask -Text
}

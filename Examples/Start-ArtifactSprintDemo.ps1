<#
.SYNOPSIS
    Create a scratch playground and have Codex produce demo artifacts there.

.DESCRIPTION
    Demonstrates the project catalog path for disposable explorations. The
    playground is registered, then Codex gets a focused artifact sprint in that
    folder so the demo produces something concrete without touching the repo.
#>

[CmdletBinding()]
param(
    [string]$Name = ('psu-demo-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),
    [string]$ParentPath,
    [Alias('Path')]
    [string]$Cwd,
    [string]$Model = 'gpt-5.2',
    [int]$TimeoutSec = 900
)

Import-Module $PSScriptRoot\..\PSUnplugged.psd1 -Force

$projectParams = @{ Name = $Name }
if ($ParentPath) {
    $projectParams.ParentPath = $ParentPath
}

$project = New-CodexPlaygroundProject @projectParams
$projectPath = $project.Path

$prompt = @"
This is a fresh PSUnplugged playground named "$Name".

Create two small, useful demo artifacts in this workspace:

1. demo-runbook.md
   A crisp live-demo runbook for PSUnplugged with:
   - 90-second narrative
   - exact commands
   - what each command proves
   - likely audience questions

2. demo-scorecard.json
   A JSON object with:
   - "message"
   - "proofPoints"
   - "risks"
   - "bestNextDemo"

Keep the files short enough to read on stage.
"@

Write-Host ''
Write-Host 'Artifact Sprint' -ForegroundColor Cyan
Write-Host "Name: $($project.Name)" -ForegroundColor DarkGray
Write-Host "Path: $projectPath" -ForegroundColor DarkGray
Write-Host ''

$task = Start-CodexTask -Cwd $projectPath -Model $Model -Name "$Name-artifact-sprint" -Tags demo,artifact,sprint -Prompt $prompt
$done = $task | Wait-CodexTask -Tail -TimeoutSec $TimeoutSec

Write-Host ''
Write-Host 'Sprint output' -ForegroundColor Cyan
$done | Receive-CodexTask -Text

Write-Host ''
Write-Host 'Created files' -ForegroundColor Cyan
Get-ChildItem -LiteralPath $projectPath -File |
    Select-Object Name, Length, LastWriteTime |
    Format-Table -AutoSize |
    Out-Host

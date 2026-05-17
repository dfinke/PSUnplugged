<#
.SYNOPSIS
    A launcher for PSUnplugged stage-ready demos that show real operator workflows.

.DESCRIPTION
    Lists the demo scripts in this folder and shows the exact commands to run.
    Pass -Run <name> to invoke one of them from the current shell.
#>

[CmdletBinding()]
param(
    [ValidateSet('BoardroomBrief', 'AgentSwarm', 'FlightRecorder', 'ArtifactSprint')]
    [string]$Run,
    [string]$Cwd = (Get-Location).Path
)

$demoRoot = $PSScriptRoot
$demos = @(
    [pscustomobject]@{
        Name        = 'BoardroomBrief'
        Script      = 'Start-BoardroomBriefDemo.ps1'
        Description = 'One task turns a repo into an executive-ready technical brief.'
    }
    [pscustomobject]@{
        Name        = 'AgentSwarm'
        Script      = 'Start-AgentSwarmDemo.ps1'
        Description = 'Launch parallel specialist tasks, then collect the answers.'
    }
    [pscustomobject]@{
        Name        = 'FlightRecorder'
        Script      = 'Show-AgentFlightRecorderDemo.ps1'
        Description = 'Show that agent work is recoverable: threads, transcripts, telemetry.'
    }
    [pscustomobject]@{
        Name        = 'ArtifactSprint'
        Script      = 'Start-ArtifactSprintDemo.ps1'
        Description = 'Create a scratch workspace and have Codex produce demo artifacts.'
    }
)

if ($Run) {
    $demo = $demos | Where-Object { $_.Name -eq $Run } | Select-Object -First 1
    & (Join-Path $demoRoot $demo.Script) -Cwd $Cwd
    return
}

Write-Host ''
Write-Host 'PSUnplugged Stage-Ready Demos' -ForegroundColor Cyan
Write-Host ''

$demos |
Select-Object Name, Description, @{ Name = 'Run'; Expression = { ".\Examples\Start-StageReadyDemos.ps1 -Run $($_.Name) -Cwd `"$Cwd`"" } } |
Format-Table -AutoSize |
Out-Host

Write-Host ''
Write-Host 'Launcher examples:' -ForegroundColor DarkGray
Write-Host '  .\Examples\Start-StageReadyDemos.ps1'
Write-Host '  .\Examples\Start-StageReadyDemos.ps1 -Run BoardroomBrief'
Write-Host '  .\Examples\Start-StageReadyDemos.ps1 -Run AgentSwarm -Cwd D:\mygit\PSUnplugged'

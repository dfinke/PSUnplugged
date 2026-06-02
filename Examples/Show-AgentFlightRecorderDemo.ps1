<#
.SYNOPSIS
    Flight recorder view over recent threads, transcripts, and telemetry.

.DESCRIPTION
    Shows what PSUnplugged can do after threads already exist: recover recent
    work, show the latest useful assistant output, and optionally include
    telemetry. By default it reads local catalog data only.
#>

[CmdletBinding()]
param(
    [Alias('Cwd', 'Path')]
    [string]$Project = (Get-Location).Path,
    [int]$Limit = 5,
    [switch]$IncludeArchived,
    [switch]$Remote,
    [switch]$ShowTelemetry
)

Import-Module $PSScriptRoot\..\PSUnplugged.psd1 -Force

$localOnly = -not $Remote

Write-Host ''
Write-Host 'Flight Recorder' -ForegroundColor Cyan
Write-Host "Project: $Project" -ForegroundColor DarkGray
Write-Host "Source:  $(if ($localOnly) { 'local catalog' } else { 'local catalog + app-server' })" -ForegroundColor DarkGray
Write-Host ''

Write-Host 'Recent threads' -ForegroundColor Yellow
$threads = @(
    Get-CodexThread -Project $Project -Limit $Limit -IncludeArchived:$IncludeArchived -LocalOnly:$localOnly |
        Select-Object -First $Limit
)
$threads | Format-Table -AutoSize | Out-Host

if ($threads.Count -eq 0) {
    Write-Host ''
    Write-Host 'No threads found for this project yet. Try Start-BoardroomBriefDemo.ps1 or Start-AgentSwarmDemo.ps1 first.' -ForegroundColor DarkGray
    return
}

Write-Host ''
Write-Host 'Latest useful output' -ForegroundColor Yellow
$threads |
    Get-CodexTranscript -Limit $Limit -IncludeArchived:$IncludeArchived -LocalOnly:$localOnly |
    Where-Object { $_.Role -eq 'assistant' -and -not [string]::IsNullOrWhiteSpace($_.Text) } |
    Group-Object ThreadId |
    ForEach-Object {
        $item = $_.Group | Sort-Object -Property Timestamp, Index | Select-Object -Last 1
        Write-Host ''
        Write-Host "## $($item.ThreadId)" -ForegroundColor DarkGray
        $item.Text
    }

if ($ShowTelemetry) {
    Write-Host ''
    Write-Host 'Telemetry transcript' -ForegroundColor Yellow
    $threads |
        Get-CodexTranscript -IncludeTelemetry -TelemetryType reasoning,tools,commands -Limit $Limit -IncludeArchived:$IncludeArchived -LocalOnly:$localOnly |
        Format-Table -AutoSize |
        Out-Host
}

# PSUnplugged Threads

Project-aware thread management for PSUnplugged.

This folder adds the higher-level PowerShell UX on top of the raw Codex JSON-RPC calls in the root module. The goal is simple: start governed agent work in one place, hop to another shell or machine, and still see which projects and threads are cooking.

## PowerShell Mental Model

If `Start-Job`, `Get-Job`, and `Receive-Job` are already in your fingers, this layer should feel familiar.

- `Start-CodexSession` is the connected runtime context.
- `New-CodexThread` starts a unit of agent work.
- `Get-CodexThread` is the main inspection surface.
- `Receive-CodexTask` receives task output, like `Receive-Job`.
- `Get-CodexTranscript` returns the conversation-shaped history.
- `Get-CodexEvent` returns the operational event stream.
- `Get-CodexApproval` returns observed approval requests.
- `Get-CodexArtifact` returns durable files and materialized task views.
- `ConvertTo-CodexTaskDashboardData` returns the JSON-ready dashboard data contract.
- `Show-CodexTaskDashboard` opens a local dashboard over the task substrate.
- `Enter-CodexThread` and `Resume-CodexThread` are how you pick work back up.

The important difference is that a Codex thread is richer than a background job. It carries state, transcript history, and project metadata, so the workflow is still PowerShell-shaped but more conversational and recoverable.

## What It Adds

- `Get-CodexProject`
- `New-CodexProject`
- `New-CodexPlaygroundProject`
- `Start-CodexTask`
- `Get-CodexTask`
- `Get-CodexApproval`
- `Get-CodexArtifact`
- `Wait-CodexTask`
- `Receive-CodexTask`
- `Resume-CodexTask`
- `Remove-CodexTask`
- `Get-CodexThread`
- `ConvertTo-CodexTaskDashboardData`
- `Get-CodexTranscript`
- `Get-CodexEvent`
- `Show-CodexTaskDashboard`
- `Show-CodexTranscript`
- `Set-CodexThread`
- `Remove-CodexThread`
- `Enter-CodexThread`
- Extended `New-CodexThread`

## Core Flows

The thread surface is designed to read like an operator workflow: start it, inspect it, read the output, resume it.

Task-first workflow:

```powershell
$pending = Start-CodexTask -Cwd . -Name repo-bootstrap -Prompt "Summarize this repo and propose next steps"
$pending | Get-CodexTask
$task = $pending | Wait-CodexTask
Get-CodexTask -ActiveOnly
Receive-CodexTask -Id $task.TaskId
Receive-CodexTask -Id $task.TaskId -Text
Resume-CodexTask -Id $task.TaskId -Prompt "Turn that into a checklist"
```

Pipeline-style task workflow:

```powershell
Start-CodexTask -Cwd . -Prompt "Summarize this repo" |
  Wait-CodexTask |
  Receive-CodexTask -Text
```

Pipe multiple prompts into the same working directory:

```powershell
$tasks = @(
  "Review error handling"
  "Add README examples"
  "Write Pester tests"
) | Start-CodexTask -Cwd .

$tasks | Get-CodexTask
$tasks | Receive-CodexTask
$tasks | Get-CodexEvent -Kind Command,ToolCall,Reasoning
$tasks | Get-CodexApproval
$tasks | Get-CodexArtifact
$tasks | ConvertTo-CodexTaskDashboardData | ConvertTo-Json -Depth 20
$tasks | Show-CodexTaskDashboard
$tasks | ConvertTo-CodexTaskDashboardData | Show-CodexTaskDashboard
```

Live tail for long-running work:

```powershell
Start-CodexTask -Cwd .\scratch\new-work -CreateCwd -Prompt "Read the last 2 issues and summarize" |
  Wait-CodexTask -Tail -TimeoutSec 900 |
  Receive-CodexTask -Text
```

Live operator telemetry:

```powershell
Start-CodexTask -Cwd .\scratch\new-work -CreateCwd -Prompt "Inspect this workspace and explain what you're doing" |
  Wait-CodexTask -Tail -ShowAll -TimeoutSec 900 |
  Receive-CodexTask -Text
```

```powershell
Receive-CodexTask -Id $task.TaskId -Details
```

Create a working folder on demand:

```powershell
Start-CodexTask -Cwd .\scratch\new-investigation -CreateCwd -Prompt "Set up a plan for this workspace"
```

List projects:

```powershell
Get-CodexProject
Get-CodexProject -Details
Get-CodexProject abc
Get-CodexProject *abc
Get-CodexProject *abc*
```

List threads:

```powershell
Get-CodexThread
Get-CodexThread -Project .
Get-CodexThread -Project *abc*
```

Read transcript content:

```powershell
Get-CodexTranscript -Id <thread-id>
Get-CodexThread -Project Research | Get-CodexTranscript
Get-CodexThread -Project PSUnplugged | Select-Object -First 1 | Show-CodexTranscript
Get-CodexTranscript -Id <thread-id> | Show-CodexTranscript -NoOpen -PassThru
```

Open the task dashboard:

```powershell
Get-CodexTask | ConvertTo-CodexTaskDashboardData | ConvertTo-Json -Depth 20
Get-CodexTask | Show-CodexTaskDashboard
Get-CodexTask | ConvertTo-CodexTaskDashboardData | Show-CodexTaskDashboard
Get-CodexTask -ActiveOnly | Show-CodexTaskDashboard -Title "Active Codex Work"
Get-CodexTask | Show-CodexTaskDashboard -NoOpen -PassThru
```

Pipeline from projects to threads:

```powershell
Get-CodexProject *abc* | Get-CodexThread
Get-CodexProject PSUnplugged | Get-CodexThread
```

Default output is table-shaped by design, so these commands should read cleanly without `| Format-Table`.

- `Get-CodexThread` defaults to a compact `Id / Name / Project / Status / When` view.
- `Get-CodexProject` defaults to a lean `Name / Kind / LastActive` view.
- `Get-CodexProject -Details` switches to a wider view with `Threads` and `LastActive`, where `Threads` is `active/total`, and the returned objects still include `Threads`, `TotalThreads`, `ThreadCount`, and `ActiveThreadCount`.

Start a new managed thread:

```powershell
New-CodexThread -Cwd . -Name repo-bootstrap -Prompt "Summarize this repo and propose next steps"
New-PlaygroundProject Research | New-CodexThread "research PowerShell and MCP"
New-CodexPlaygroundProject -Name Research | New-CodexThread "research PowerShell and MCP"
```

Resume or jump into an existing thread:

```powershell
Enter-CodexThread -Id <thread-id>
Enter-CodexThread -ProjectPath .
Enter-CodexThread -Id <thread-id> -Prompt "Pick up where we left off and propose the next task"
```

Create a scratch workspace:

```powershell
New-CodexPlaygroundProject -Name scratch-api
Get-CodexProject scratch-* | Get-CodexThread
```

By default, playground creation now prefers a Codex desktop workspace root already named `Playground` or `Playgrounds`, so those projects are more likely to show up in the app right away. To pin a custom default, set:

```powershell
$env:PSUNPLUGGED_PLAYGROUND_ROOT = 'D:\OneDrive\Documents\Playground'
```

## How It Works

There are two layers of thread data:

- Remote Codex thread data from the app-server
- Local PowerShell metadata for project grouping, names, tags, pinning, and archiving

Remote fetches use a status spinner adapted from `D:\mygit\PowerShellRich\Public\Status.ps1`.
To disable spinners, set:

```powershell
$env:PSUNPLUGGED_NO_SPINNER = '1'
```

The local metadata is stored in `thread-catalog.json` under:

- `$env:PSUNPLUGGED_HOME` if set
- Otherwise `%LOCALAPPDATA%\PSUnplugged` on Windows
- Otherwise `~/.psunplugged` on non-Windows systems

## Project Identity Rules

- If a path is inside a git repo, the project is normalized to the repo root.
- If the repo has an `origin`, the project key is based on that remote URL.
- If there is no git remote, the project key falls back to the normalized path.
- Playground projects get a small `.psunplugged-project.json` manifest.

That means `New-CodexProject -Path .\src` and `New-CodexProject -Path .` resolve to the same project when both live in the same repo.

## Thread Metadata

`Set-CodexThread` updates local metadata such as:

- `Name`
- `Tags`
- `Pinned`
- `Archived`
- project association

Examples:

```powershell
Set-CodexThread -ThreadId <thread-id> -Name "release checklist"
Set-CodexThread -ThreadId <thread-id> -Tags release,ops -Pin
Remove-CodexThread -ThreadId <thread-id>
Remove-CodexThread -ThreadId <thread-id> -Purge
```

`Remove-CodexThread` is conservative by default:

- without `-Purge`, it archives the local metadata entry
- with `-Purge`, it removes the local metadata entry

It does not currently delete the remote Codex thread from the app-server.

## Design Notes

- `Start-CodexTask / Get-CodexTask / Wait-CodexTask / Receive-CodexTask` give you the job-style operator surface.
- `Start-CodexTask` defaults to `gpt-5.2`, matching the minimum supported Codex runtime model.
- `Get-CodexTask` lists active/attention tasks plus recently completed tasks across projects, like an operator board; use `-Project .` for the current project, `-ActiveOnly` for tasks still in play, and `-All` for older completed task history.
- `Get-CodexTask -RecentHours 12` and `Get-CodexTask -Since (Get-Date).Date` tune the completed-task window; the default window is 4 hours.
- `Get-CodexTask -LocalOnly` skips the Codex app-server refresh when you want the fastest local catalog view.
- `Get-CodexTask` also shows `starting` tasks while their worker process is booting.
- `Get-CodexTask` surfaces task errors in the default table when a worker stops before Codex reports completion.
- `Start-CodexTask -CreateCwd` lets task-first workflows create a new working folder without a separate setup step.
- `Start-CodexTask -TurnTimeoutSec <n>` controls the task worker's Codex turn wait; the default is 900 seconds.
- `Wait-CodexTask -Tail` shows new transcript items while the task is still running, and `-TimeoutSec` keeps the wait bounded when you want it.
- `Wait-CodexTask -Tail -ShowAll` surfaces richer live telemetry about what the task is doing.
- `Receive-CodexTask` gives you a compact latest-output summary by default.
- `Receive-CodexTask -Text` returns the full latest assistant text.
- `Receive-CodexTask -Details` returns the full transcript plus reasoning, tools, and commands after the task completes.
- `Receive-CodexTask -Transcript -ShowAll` is still supported when you prefer explicit switches.
- `-ShowReasoning`, `-ShowTools`, and `-ShowCommands` remain available when you only want one telemetry slice.
- In the default summary view, telemetry switches are ignored so the summary stays focused on the latest assistant output or task state.
- `Get-CodexEvent` gives you the operational event stream for task telemetry, including commands, tools, reasoning, approvals, messages, and lifecycle events.
- `Get-CodexApproval` gives you a read-only approval request view. It does not approve or deny requests yet.
- `Get-CodexArtifact` gives you artifact-shaped task outputs from the existing durable store: session JSONL, latest result text, transcript, and event log.
- `ConvertTo-CodexTaskDashboardData` is the handoff point for custom frontends: PowerShell owns the task object flow, and the UI can own rendering.
- `Show-CodexTaskDashboard` gives you an Argus-style local dashboard snapshot with focused/verbose views and natural-language filtering over task state.
- `Get-CodexProject` always returns project objects.
- `Get-CodexThread` always returns thread objects.
- Wildcards are supported for project selection.
- Pipeline composition is preferred over overloaded return types.

That keeps the command surface idiomatic:

```powershell
Get-CodexProject *demo* | Get-CodexThread | Select-Object ThreadId, Name, LastActivityAt
```

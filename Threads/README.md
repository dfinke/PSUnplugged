# PSUnplugged Threads

Project-aware thread management for PSUnplugged.

This folder adds the higher-level PowerShell UX on top of the raw Codex JSON-RPC calls in the root module. The goal is simple: start governed agent work in one place, hop to another shell or machine, and still see which projects and threads are cooking.

## PowerShell Mental Model

If `Start-Job`, `Get-Job`, and `Receive-Job` are already in your fingers, this layer should feel familiar.

- `Start-CodexSession` is the connected runtime context.
- `New-CodexThread` starts a unit of agent work.
- `Get-CodexThread` is the main inspection surface.
- `Get-CodexTranscript` is today's closest analogue to "receive the latest useful output."
- `Enter-CodexThread` and `Resume-CodexThread` are how you pick work back up.

The important difference is that a Codex thread is richer than a background job. It carries state, transcript history, and project metadata, so the workflow is still PowerShell-shaped but more conversational and recoverable.

## What It Adds

- `Get-CodexProject`
- `New-CodexProject`
- `New-CodexPlaygroundProject`
- `Start-CodexTask`
- `Get-CodexTask`
- `Wait-CodexTask`
- `Receive-CodexTask`
- `Resume-CodexTask`
- `Remove-CodexTask`
- `Get-CodexThread`
- `Get-CodexTranscript`
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

Live tail for long-running work:

```powershell
Start-CodexTask -Cwd .\scratch\new-work -CreateCwd -Prompt "Read the last 2 issues and summarize" |
  Wait-CodexTask -Tail -TimeoutSec 900 |
  Receive-CodexTask -Text
```

Live operator telemetry:

```powershell
Start-CodexTask -Cwd .\scratch\new-work -CreateCwd -Prompt "Inspect this workspace and explain what you're doing" |
  Wait-CodexTask -Tail -ShowReasoning -ShowTools -ShowCommands -TimeoutSec 900 |
  Receive-CodexTask -Text
```

```powershell
Receive-CodexTask -Id $task.TaskId -Transcript -ShowReasoning -ShowTools -ShowCommands
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
- `Get-CodexTask` defaults to the current working directory (`-Project '*'` lists everything), and `-ActiveOnly` keeps the view focused on tasks that are still in play.
- `Get-CodexTask` also shows `starting` tasks while their worker process is booting.
- `Start-CodexTask -CreateCwd` lets task-first workflows create a new working folder without a separate setup step.
- `Wait-CodexTask -Tail` shows new transcript items while the task is still running, and `-TimeoutSec` keeps the wait bounded when you want it.
- `Wait-CodexTask -Tail -ShowReasoning -ShowTools -ShowCommands` surfaces richer live telemetry about what the task is doing.
- `Receive-CodexTask -Transcript -ShowReasoning -ShowTools -ShowCommands` returns that richer telemetry stream after the task completes.
- `Get-CodexProject` always returns project objects.
- `Get-CodexThread` always returns thread objects.
- Wildcards are supported for project selection.
- Pipeline composition is preferred over overloaded return types.

That keeps the command surface idiomatic:

```powershell
Get-CodexProject *demo* | Get-CodexThread | Select-Object ThreadId, Name, LastActivityAt
```

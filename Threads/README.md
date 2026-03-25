# PSUnplugged Threads

Project-aware thread management for PSUnplugged.

This folder adds the higher-level PowerShell UX on top of the raw Codex JSON-RPC calls in the root module. The goal is simple: start work in one place, hop to another shell or machine, and still see which projects and threads are cooking.

## What It Adds

- `Get-CodexProject`
- `New-CodexProject`
- `New-CodexPlaygroundProject`
- `Get-CodexThread`
- `Get-CodexTranscript`
- `Show-CodexTranscript`
- `Set-CodexThread`
- `Remove-CodexThread`
- `Enter-CodexThread`
- Extended `New-CodexThread`

## Core Flows

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

- `Get-CodexProject` always returns project objects.
- `Get-CodexThread` always returns thread objects.
- Wildcards are supported for project selection.
- Pipeline composition is preferred over overloaded return types.

That keeps the command surface idiomatic:

```powershell
Get-CodexProject *demo* | Get-CodexThread | Select-Object ThreadId, Name, LastActivityAt
```

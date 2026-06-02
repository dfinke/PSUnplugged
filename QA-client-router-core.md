# QA Checklist: client-router-core

Branch: `codex/client-router-core`

Goal: verify the router-backed JSON-RPC session layer behaves like the previous public surface while preserving task workflows.

## Setup

- [x] Confirm you are on the branch:

```powershell
git branch --show-current
```

- [x] Import the module:

```powershell
Import-Module .\PSUnplugged.psd1 -Force
```

## Static Checks

- [x] Manifest reads:

```powershell
Import-PowerShellDataFile .\PSUnplugged.psd1 | Select-Object ModuleVersion
```

- [x] Module imports:

```powershell
Import-Module .\PSUnplugged.psd1 -Force
```

- [x] Diff has no whitespace errors:

```powershell
git diff --check
```

- [x] Tests pass:

```powershell
Invoke-Pester .\Tests\PSUnplugged.Threads.Tests.ps1 -CI
```

## Core Session Smoke

- [x] Start a session, read account state, list models, and stop cleanly:

```powershell
$s = Start-CodexSession
Get-CodexAccount -Session $s
Get-CodexModels -Session $s
Stop-CodexSession $s
```

Expected:

- Session starts without hanging.
- Account response returns.
- Model list returns.
- Stop exits cleanly.

## Basic Turn

- [x] Confirm relative `-Cwd` values resolve from the PowerShell location, not the app-server process location:

```powershell
$s = Start-CodexSession
$expected = (Resolve-Path .).Path
$t = New-CodexThread -Session $s -Cwd .
[pscustomobject]@{
    Expected = $expected
    Actual   = $t.cwd
    Matches  = ($t.cwd -eq $expected)
}
Stop-CodexSession $s
```

Expected:

- `Actual` matches the current PowerShell location.
- `Actual` is not `C:\WINDOWS\system32` when PowerShell is in the repository.

- [x] Start a thread and run one turn:

```powershell
$s = Start-CodexSession
$t = New-CodexThread -Session $s -Cwd .
$r = Invoke-CodexTurn -Session $s -ThreadId $t.id -Text "Say OK and nothing else."
$r
Stop-CodexSession $s
```

Expected:

- `Invoke-CodexTurn` completes.
- `Status` is completed or equivalent.
- `AgentText` contains the response.
- No hang while waiting for notifications.

## Operator Flow

- [x] Start a task, wait with tailing, and receive text:

```powershell
Start-CodexTask -Cwd . -Prompt "Say OK and summarize this repo in one sentence." |
    Wait-CodexTask -Tail -TimeoutSec 300 |
    Receive-CodexTask -Text
```

Expected:

- Pending task becomes a real task/thread.
- `Wait-CodexTask -Tail` shows progress and exits.
- `Receive-CodexTask -Text` returns final text.

## Regression Views

- [x] Task listing works:

```powershell
Get-CodexTask -ActiveOnly
Get-CodexTask -LocalOnly
```

- [x] Event view works:

```powershell
Get-CodexTask | Select-Object -First 1 | Get-CodexEvent
```

- [ ] Detailed receive still works:

```powershell
Get-CodexTask | Select-Object -First 1 | Receive-CodexTask -Details
```

## Things To Watch

- [ ] Any hang during `Start-CodexSession`.
- [ ] Any hang during `Invoke-CodexTurn`.
- [ ] Any hang during `Wait-CodexTask -Tail`.
- [ ] Missing final assistant text when the task clearly completed.
- [ ] Approval prompts auto-accepted differently than before.
- [ ] `Get-CodexEvent` missing command/tool/reasoning events that appeared before.

## QA Notes

Use this section to jot results, errors, or command output worth preserving.

- 
